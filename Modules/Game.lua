--------------------------------------------------------------------------------
-- Modules/Game.lua
-- The deathroll game: FSM (IDLE -> OPEN -> ACTIVE -> FINISHED) plus the
-- only mutable state in the addon. Slash and Chat call into this module;
-- this module calls Announce. No event subscriptions, no slash registration,
-- no I/O beyond Announce.Send and the host-local warning helper.
--
-- Per-roll rules:
--   * State must be ACTIVE.
--   * Roller must be host or opponent.
--   * Roller must be currentTurn.
--   * minRoll == 1 and maxRoll == currentMax.
--   * Valid roll == 1 -> roller loses, other player wins, FINISHED + payout.
--   * Valid roll > 1 -> currentMax := roll, switch turn, prompt next.
--   * Invalid rolls NEVER mutate state. Severity warnings go to host's chat
--     frame only; never broadcast.
--
-- Payout is announcement-only: "<winner> wins <bet>g. Loser pays the bet."
-- No trade automation.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local print = print
local string_format = string.format

local M = {}

-- Short-form name helper lives on `ns` (see Core.lua) so Slash and Game
-- share a single implementation. Aliased locally for hot-path readability.
local shortName = ns.GetShortName

-- Lobby join-timer constants. `TIMER_SECONDS` is the fixed open-to-start
-- countdown (out-of-scope to make configurable per ADR). `MIN_PLAYERS` names
-- the auto-start floor; in the current 1v1 model it reduces to "opponent
-- slot is filled" but the constant earns its place for the eventual N-player
-- refactor. Countdown announcement schedule (seconds-elapsed -> remaining):
-- {5->10, 10->5, 12->3, 13->2, 14->1}; terminal transition at TIMER_SECONDS.
local TIMER_SECONDS = 15
local MIN_PLAYERS = 2
local COUNTDOWN_POINTS = {
    { at = 5,  remaining = 10 },
    { at = 10, remaining = 5  },
    { at = 12, remaining = 3  },
    { at = 13, remaining = 2  },
    { at = 14, remaining = 1  },
}

-- Internal helper: route a localised, formatted string out via Announce.
local function announce(template, ...)
    local L = ns.L
    local resolved = L and L[template] or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    if ns.Announce and ns.Announce.Send then
        ns.Announce.Send(resolved)
    end
end

-- Internal helper: emit a localised, formatted line to the host's chat frame
-- ONLY. Never broadcast. Single sink via `ns.PrintLocal` (see Core.lua);
-- falls through to `print` only when the seam is missing (defensive - this
-- should never happen at runtime, but keeps headless smoke tests honest).
local function tellHost(template, ...)
    local L = ns.L
    local resolved = L and L[template] or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    if ns.PrintLocal then ns.PrintLocal(resolved) else print(resolved) end
end

-- Alias: `warn` is the legacy name for invalid-roll severity; same routing
-- as `tellHost`, separate name to preserve call-site intent.
local warn = tellHost

-- FSM transitions.
local TRANSITIONS = {
    IDLE     = { OPEN = true },
    OPEN     = { ACTIVE = true, IDLE = true },     -- IDLE on cancel/reset
    ACTIVE   = { FINISHED = true, IDLE = true },   -- IDLE on cancel/reset
    FINISHED = { IDLE = true, OPEN = true },       -- next game
}

local DEFAULT_MULTIPLIER = 10

-- Game-wide mutable state. Re-initialised on Reset/Cancel.
local state = {
    fsm        = nil,    -- DragonDice.FSM
    host       = nil,    -- string (short name)
    opponent   = nil,    -- string (short name) or nil
    bet        = 0,      -- integer (gold)
    multiplier = DEFAULT_MULTIPLIER,
    startMax   = 0,      -- bet * multiplier
    currentMax = 0,      -- shrinks each roll
    currentTurn = nil,   -- "host" | "opponent"
    history    = {},     -- ordered roll records
}

local function clearState()
    state.host = nil
    state.opponent = nil
    state.bet = 0
    state.multiplier = DEFAULT_MULTIPLIER
    state.startMax = 0
    state.currentMax = 0
    state.currentTurn = nil
    state.history = {}
end

-- Lobby-timer fields. The lobby-identity counter is the load-bearing
-- re-entrancy guard: every Schedule callback captures the open-time value
-- and bails on mismatch, so a late callback from a cancelled lobby is inert
-- even if its handle was not cancelled in time (epoch / generation counter
-- pattern).
M._timerHandle = nil
M._countdownHandles = {}
M._lobbyId = 0

-- Internal helper: count current participants. In the 1v1 model this is 1
-- (host only) or 2 (host + opponent). Named for the future N-player refactor.
local function countParticipants()
    return state.opponent ~= nil and 2 or 1
end

-- Internal helper: cancel any scheduled countdown announcements and the
-- terminal transition. Idempotent. The lobby-identity guard makes a missed
-- cancel safe-by-default, so this is best-effort cleanup, not the
-- correctness primitive.
local function cancelTimers()
    local handles = M._countdownHandles
    for i = 1, #handles do
        local handle = handles[i]
        if handle and handle.Cancel then handle:Cancel() end
        handles[i] = nil
    end
    if M._timerHandle and M._timerHandle.Cancel then
        M._timerHandle:Cancel()
    end
    M._timerHandle = nil
end

-- Forward declarations: the schedule helper references `Start`, which is
-- attached to `M` below.
local scheduleCountdown
local expireInsufficient

-- Internal helper: who the next roller should be, given currentTurn.
local function nextTurn()
    if state.currentTurn == "host" then return "opponent" end
    return "host"
end

-- Internal helper: resolve a turn slot to its player name.
local function nameForSlot(slot)
    if slot == "host" then return state.host end
    if slot == "opponent" then return state.opponent end
    return nil
end

-- Internal helper: resolve a player name to its turn slot, nil if neither.
local function slotForPlayer(player)
    local p = shortName(player)
    if p == state.host then return "host" end
    if p == state.opponent then return "opponent" end
    return nil
end

---@param _addon DragonCore.Addon
function M:Init(_addon)
    state.fsm = ns.FSM.New("IDLE", TRANSITIONS)
end

---Open a new lobby. Resets any prior game. Validates `bet` is a positive
---integer and `hostName` is a non-empty string; on failure prints a
---host-local error and does NOT mutate state.
---
---`hostName` is REQUIRED and is treated as opaque player-name data. The
---caller is responsible for translating "the local player" (Slash) or the
---chat sender (Chat for `!bet`) into a name before invoking this. Game
---never touches `UnitName` itself - host identity is data, not implicit.
---@param bet number
---@param hostName string  Opaque player-name string; run through Ambiguate.
function M:Open(bet, hostName)
    -- Guard against re-Init missed in tests / reload edge cases.
    if not state.fsm then state.fsm = ns.FSM.New("IDLE", TRANSITIONS) end

    if type(bet) ~= "number" or bet ~= math.floor(bet) or bet <= 0 then
        tellHost("DragonDice: bet must be a positive integer.")
        return false
    end

    if type(hostName) ~= "string" or hostName == "" then
        tellHost("DragonDice: cannot open - host name missing.")
        return false
    end

    -- Best-effort cleanup of any leftover handles from a prior lobby. The
    -- epoch (advanced by Cancel/Reset/Join) is the actual correctness
    -- primitive; this just keeps the schedule queue tidy.
    cancelTimers()

    -- Reset any prior game (legal from any state).
    state.fsm:Reset()
    clearState()

    local resolvedHost = shortName(hostName)
    state.host = resolvedHost
    state.bet = bet
    state.startMax = bet * state.multiplier
    state.currentMax = state.startMax

    state.fsm:To("OPEN")
    -- Open-announce wording is from the joiner's perspective: the 15s
    -- countdown does not arm until someone joins, but at that point the
    -- "!start or wait %ds to begin" line is accurate.
    announce("DragonDice: %s opens a %dg deathroll. Type !join to enter; !start or wait %ds to begin.",
        resolvedHost, bet, TIMER_SECONDS)

    return true
end

---Accept a !join from `player`. Only legal in OPEN state, ignores host
---self-join, rejects any further joiners after the first.
---@param player string
function M:Join(player)
    if state.fsm == nil or state.fsm:Get() ~= "OPEN" then return false end
    if not player or player == "" then return false end

    local who = shortName(player)
    if who == state.host then return false end
    local previousOpponent = state.opponent
    if previousOpponent ~= nil then return false end

    state.opponent = who
    announce("DragonDice: %s has joined the deathroll vs %s. Host: /dr start to begin.",
        who, state.host)

    -- Arm the lobby countdown on the FIRST successful join. In the current
    -- 1v1 model every accepted Join IS the first (Join rejects when the
    -- opponent slot is already filled), so this guard is forward-compatible
    -- scaffolding for an eventual N-player refactor. The epoch lives on the
    -- countdown, not the lobby: bumping it here ensures any straggler
    -- callbacks from a prior countdown are inert.
    if not previousOpponent then
        M._lobbyId = M._lobbyId + 1
        local lobbyId = M._lobbyId
        scheduleCountdown(lobbyId)

        local Schedule = ns.Schedule
        if Schedule and Schedule.After then
            M._timerHandle = Schedule:After(TIMER_SECONDS, function()
                if M._lobbyId ~= lobbyId then return end
                M._timerHandle = nil
                if countParticipants() >= MIN_PLAYERS then
                    M:Start()
                else
                    expireInsufficient()
                end
            end)
        end
    end

    return true
end

---Begin the match. Requires OPEN + opponent set.
function M:Start()
    if state.fsm == nil or state.fsm:Get() ~= "OPEN" then
        tellHost("DragonDice: cannot start - no game is open.")
        return false
    end
    if state.opponent == nil then
        -- Manual-start refusal: keep the lobby OPEN and the join timer
        -- running. The host can wait for a joiner or `/dr cancel`.
        tellHost("DragonDice: cannot start - need an opponent.")
        return false
    end

    -- Successful manual start (or terminal-callback delegation): silence the
    -- countdown before announcing the match. The epoch guard would make
    -- stragglers inert anyway, but explicit cancel keeps chat quiet.
    cancelTimers()

    state.fsm:To("ACTIVE")
    state.currentTurn = "host"
    announce("DragonDice: %s vs %s for %dg. %s rolls first: /roll %d",
        state.host, state.opponent, state.bet, state.host, state.currentMax)
    return true
end

---Process a parsed roll record from RollParser. Mutates state only on a
---fully-validated roll. Invalid rolls surface as host-local warnings.
---@param record { player: string, roll: integer, min: integer, max: integer }
function M:OnRoll(record)
    if state.fsm == nil or state.fsm:Get() ~= "ACTIVE" then return false end
    if type(record) ~= "table" then return false end

    local player = record.player
    local rollN = record.roll
    local minN = record.min
    local maxN = record.max
    if not (player and rollN and minN and maxN) then return false end

    local slot = slotForPlayer(player)
    if slot == nil then
        -- Wrong-player: not a participant. Minor severity, host-local only.
        warn("DragonDice: ignored roll from %s (not a participant).", shortName(player))
        return false
    end

    if slot ~= state.currentTurn then
        warn("DragonDice: %s rolled out of turn (waiting on %s).",
            shortName(player), nameForSlot(state.currentTurn))
        return false
    end

    if minN ~= 1 or maxN ~= state.currentMax then
        -- Range mismatch: obvious game-impact (player rolled a wrong /roll
        -- range). Surface to the host. State NOT mutated.
        warn("DragonDice: %s rolled wrong range 1-%d (expected 1-%d) - roll discarded.",
            shortName(player), maxN, state.currentMax)
        return false
    end

    -- Valid roll: record it.
    state.history[#state.history + 1] = {
        player = shortName(player),
        roll = rollN,
        min = minN,
        max = maxN,
    }

    if rollN == 1 then
        local loserSlot = slot
        local winnerSlot = (loserSlot == "host") and "opponent" or "host"
        local loserName = nameForSlot(loserSlot)
        local winnerName = nameForSlot(winnerSlot)
        local bet = state.bet
        state.fsm:To("FINISHED")
        announce("DragonDice: %s rolled 1 and loses. %s wins %dg. Loser pays the bet.",
            loserName, winnerName, bet)
        return true
    end

    -- Continue: shrink ceiling, switch turn, prompt the next roller.
    state.currentMax = rollN
    state.currentTurn = nextTurn()
    local nextName = nameForSlot(state.currentTurn)
    announce("DragonDice: %s rolled %d. %s, /roll %d",
        shortName(player), rollN, nextName, state.currentMax)
    return true
end

---Print the current game state to the host's chat frame. Host-local only;
---never broadcast.
---@return nil
function M:Status()
    if state.fsm == nil then
        tellHost("DragonDice: no game in progress.")
        return
    end
    local L = ns.L
    local none = (L and L["(none)"]) or "(none)"
    tellHost("DragonDice status: state=%s host=%s opponent=%s bet=%dg currentMax=%d turn=%s",
        state.fsm:Get(),
        state.host or none,
        state.opponent or none,
        state.bet or 0,
        state.currentMax or 0,
        state.currentTurn or none)
end

---Reset to IDLE silently (host-local; no broadcast). Advances the lobby
---epoch so any in-flight scheduled callbacks observe a stale id and no-op.
---@return nil
function M:Reset()
    M._lobbyId = M._lobbyId + 1
    cancelTimers()
    if state.fsm then state.fsm:Reset() end
    clearState()
end

---Cancel the active/open game and broadcast the cancellation. No-ops (and
---emits a host-local "no game in progress") when already IDLE.
---@return boolean  true if a game was cancelled; false if there was nothing to cancel.
function M:Cancel()
    if state.fsm == nil then return false end
    local current = state.fsm:Get()
    if current == "IDLE" then
        tellHost("DragonDice: no game in progress.")
        return false
    end
    -- `state.host` is always set in non-IDLE states (set by :Open). Treated
    -- as opaque player-name data; never substituted with UnitName("player").
    local hostName = state.host
    M._lobbyId = M._lobbyId + 1
    cancelTimers()
    announce("DragonDice: %s cancelled the deathroll.", hostName)
    state.fsm:Reset()
    clearState()
    return true
end

---Return the current FSM state ("IDLE" | "OPEN" | "ACTIVE" | "FINISHED"),
---or nil if Init has not yet run. Callers use this to gate inputs (e.g.
---Chat silently drops "!bet" outside IDLE).
function M:GetState()
    if state.fsm == nil then return nil end
    return state.fsm:Get()
end

---Return the current host name (short form), or nil if no game is in
---progress. Callers use this to authorise destructive slash verbs (only
---the host may /dr start | cancel | reset a non-IDLE game).
function M:GetHost()
    return state.host
end

---Test seam: snapshot of current state. NOT used in production.
function M._State()
    return {
        state = state.fsm and state.fsm:Get() or nil,
        host = state.host,
        opponent = state.opponent,
        bet = state.bet,
        currentMax = state.currentMax,
        currentTurn = state.currentTurn,
        history = state.history,
    }
end

-- Schedule the five countdown announcements for this lobby. Each callback
-- closes over `lobbyId` (captured at Open time) and refuses to fire if the
-- epoch has advanced. The handles are stored in `M._countdownHandles` so
-- cancelTimers() can sweep them on manual start / cancel / reset.
scheduleCountdown = function(lobbyId)
    local Schedule = ns.Schedule
    if not Schedule or not Schedule.After then return end

    local handles = M._countdownHandles
    for i = 1, #COUNTDOWN_POINTS do
        local point = COUNTDOWN_POINTS[i]
        local remaining = point.remaining
        local handle = Schedule:After(point.at, function()
            if M._lobbyId ~= lobbyId then return end
            announce("DragonDice: starting in %ds.", remaining)
        end)
        handles[#handles + 1] = handle
    end
end

-- Terminal timer expiry path: insufficient participants. Host-local notice
-- only, then return to IDLE. The new epoch from Reset() prevents any
-- straggler countdown from firing into the dead lobby.
-- Defensive: only reached if a future N-player refactor arms the timer
-- before MIN_PLAYERS is met. In the current 1v1 model the timer only arms
-- after a successful Join, so at terminal time an opponent always exists
-- and the terminal callback delegates to Start instead.
expireInsufficient = function()
    tellHost("DragonDice: not enough players - lobby expired.")
    M:Reset()
end

-- Test seams (NOT used in production): introspect the internal countdown
-- table and trigger the expiry path directly for spec coverage.
function M._CountdownHandles() return M._countdownHandles end
function M._LobbyId() return M._lobbyId end

ns.Game = setmetatable(M, { __index = ns.Game or {} })

return M
