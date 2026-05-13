--------------------------------------------------------------------------------
-- Modules/Game.lua
-- The deathroll game: FSM (IDLE -> OPEN -> ACTIVE -> FINISHED) plus the
-- only mutable state in the addon. Slash and Chat call into this module;
-- this module calls Announce. No event subscriptions, no slash registration,
-- no I/O beyond Announce.Send and the host-local warning helper.
--
-- Per-roll rules (orchestrator-confirmed):
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
-- Supported versions: Retail
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local print = print
local string_format = string.format

local M = {}

-- Short-form name helper lives on `ns` (see Core.lua) so Slash and Game
-- share a single implementation. Aliased locally for hot-path readability.
local shortName = ns.GetShortName

-- Internal helper: route a localised, formatted string out via Announce.
local function announce(template, ...)
    local L = ns.L
    local resolved = L and L[template] or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    if ns.Announce and ns.Announce.Send then
        ns.Announce.Send(resolved)
    end
end

-- Internal helper: print a warning to the host's chat frame ONLY. Never
-- broadcast. Used for invalid-roll warnings that still need surfacing so the
-- host knows why the game did not advance.
local function warn(template, ...)
    local L = ns.L
    local resolved = L and L[template] or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    print(resolved)
end

-- Internal helper: print a localised line to the host's chat frame (status,
-- usage, errors). Same routing as warn(); separate name for intent.
local function tellHost(template, ...)
    warn(template, ...)
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

-- FSM transitions. Keep in sync with the state diagram in the ADR.
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

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

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

    -- Reset any prior game (legal from any state).
    state.fsm:Reset()
    clearState()

    local resolvedHost = shortName(hostName)
    state.host = resolvedHost
    state.bet = bet
    state.startMax = bet * state.multiplier
    state.currentMax = state.startMax

    state.fsm:To("OPEN")
    announce("DragonDice: %s is hosting a deathroll for %dg. Type !join to play.",
        resolvedHost, bet)
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
    if state.opponent ~= nil then return false end

    state.opponent = who
    announce("DragonDice: %s has joined the deathroll vs %s. Host: /dr start to begin.",
        who, state.host)
    return true
end

---Begin the match. Requires OPEN + opponent set.
function M:Start()
    if state.fsm == nil or state.fsm:Get() ~= "OPEN" then
        tellHost("DragonDice: cannot start - no game is open.")
        return false
    end
    if state.opponent == nil then
        tellHost("DragonDice: cannot start - need an opponent.")
        return false
    end

    state.fsm:To("ACTIVE")
    state.currentTurn = "host"
    announce("DragonDice: %s vs %s for %dg. %s rolls first: /roll 1-%d",
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
    announce("DragonDice: %s rolled %d. %s, /roll 1-%d",
        shortName(player), rollN, nextName, state.currentMax)
    return true
end

---Print the current game state to the host's chat frame.
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

---Reset to IDLE silently (host-local; no broadcast).
function M:Reset()
    if state.fsm then state.fsm:Reset() end
    clearState()
end

---Cancel the active/open game and broadcast the cancellation.
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

ns.Game = setmetatable(M, { __index = ns.Game or {} })

return M
