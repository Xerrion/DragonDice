--------------------------------------------------------------------------------
-- Modules/Games/Goldroll.lua
-- The multi-player gold roll game module. FSM
-- (IDLE -> OPEN -> ROLLING -> RESOLVING -> FINISHED) with two timer modes
-- in OPEN (quorum-wait vs start-countdown) sharing one handle, plus
-- tie-break sub-rounds modelled by re-entering ROLLING with a filtered
-- participant list.
--
-- Lifecycle highlights:
--   * Open arms a quorum-wait timer. While the lobby has < 2 joiners the
--     terminal callback at QUORUM_WAIT_SECONDS expires the lobby silently.
--   * The join that brings the participant count from 1 to QUORUM_MIN
--     cancels the quorum-wait handle, advances the lobby epoch, swaps
--     timerMode to START_COUNTDOWN, and arms the five-point countdown
--     plus terminal start handle.
--   * Joins past quorum do NOT reset the countdown; the host-announced
--     timeline is honoured.
--   * Host short-circuit lives on three entry points (SlashVerbs.start,
--     ChatVerbs.start, registry Start) all routing to _StartFromVerb.
--
-- Per-roll rules:
--   * State must be ROLLING.
--   * Roller must be in state.participants.
--   * minRoll == 1 and maxRoll == state.wager.
--   * Each participant rolls exactly once per round; duplicates rejected.
--   * On the final outstanding roll, transition ROLLING -> RESOLVING and
--     either announce a winner/loser pair (FINISHED) or filter to the
--     tied subset and re-enter ROLLING.
--
-- Payout is announcement-only: "<loser> owes <winner> Ng." No trade.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local pairs = pairs
local string_format = string.format
local string_match = string.match
local table_concat = table.concat
local table_sort = table.sort
local tonumber = tonumber
local math_floor = math.floor

local M = {}

M.id = "goldroll"
M.displayName = "Gold Roll"
M.localePrefix = "goldroll"

local shortName = ns.GetShortName

-- Lobby timing. QUORUM_WAIT_SECONDS is the silent-lobby cutoff; once two
-- players are present we swap into START_COUNTDOWN_SECONDS with the same
-- five-tick announcement cadence deathroll uses, so players already know
-- the rhythm.
local QUORUM_WAIT_SECONDS = 60
local START_COUNTDOWN_SECONDS = 15
local QUORUM_MIN = 2
local COUNTDOWN_POINTS = {
    { at = 5,  remaining = 10 },
    { at = 10, remaining = 5  },
    { at = 12, remaining = 3  },
    { at = 13, remaining = 2  },
    { at = 14, remaining = 1  },
}

local TIMER_MODE_QUORUM_WAIT = "QUORUM_WAIT"
local TIMER_MODE_START_COUNTDOWN = "START_COUNTDOWN"

local function announce(template, ...)
    local L = ns.L
    local resolved = (L and L[template]) or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    if ns.Announce and ns.Announce.Send then
        ns.Announce.Send(resolved)
    end
end

-- Host-local sink: aliased from the shared `ns.TellHost` (Core.lua) so
-- both games and the registry share one implementation of "localise +
-- format + print to default chat frame".
local tellHost = ns.TellHost

local warn = tellHost

local TRANSITIONS = {
    IDLE      = { OPEN = true },
    OPEN      = { ROLLING = true, IDLE = true },
    ROLLING   = { RESOLVING = true, IDLE = true },
    RESOLVING = { ROLLING = true, FINISHED = true, IDLE = true },
    FINISHED  = { IDLE = true, OPEN = true },
}

-- Game-wide mutable state. Re-initialised on Reset/Cancel/Open.
local state = {
    fsm = nil,             -- DragonDice.FSM
    host = nil,            -- string (short name)
    wager = 0,             -- positive integer; equals /roll range
    participants = {},     -- map[name]=true
    participantOrder = {}, -- ordered list mirror for stable announces
    participantCount = 0,
    rolls = {},            -- map[name]=integer; one slot per round
    rollCount = 0,
    roundNumber = 1,
    history = {},          -- ordered roll records
    timerMode = nil,       -- "QUORUM_WAIT" | "START_COUNTDOWN" | nil
}

local function clearState()
    state.host = nil
    state.wager = 0
    state.participants = {}
    state.participantOrder = {}
    state.participantCount = 0
    state.rolls = {}
    state.rollCount = 0
    state.roundNumber = 1
    state.history = {}
    state.timerMode = nil
end

-- Lobby-timer fields. The lobby-identity counter is the re-entrancy
-- primitive: every scheduled callback captures the epoch at arming time
-- and bails on mismatch, so a late callback from a cancelled lobby (or a
-- prior timer mode) is inert even if the handle was not cancelled in
-- time.
M._timerHandle = nil
M._countdownHandles = {}
M._lobbyId = 0

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

local scheduleQuorumWait
local scheduleStartCountdown
local beginRolling
local resolveRound
local expireQuorum

---@param rest string|nil
---@return { wager: integer }|nil args
---@return string|nil             err   localised error template on failure.
function M.ParseOpenArgs(rest)
    if type(rest) ~= "string" then
        return nil, "DragonDice: wager must be a positive integer."
    end
    local trimmed = string_match(rest, "^%s*(.-)%s*$") or ""
    if trimmed == "" then
        return nil, "DragonDice: wager must be a positive integer."
    end
    local n = tonumber(trimmed)
    if n == nil or n ~= math_floor(n) or n <= 0 then
        return nil, "DragonDice: wager must be a positive integer."
    end
    return { wager = n }, nil
end

---@param _addon DragonCore.Addon
function M:Init(_addon)
    state.fsm = ns.FSM.New("IDLE", TRANSITIONS)
end

---Open a new lobby. Resets any prior game. Validates the parsed args and
---`hostName`; on failure prints a host-local error and does NOT mutate
---state.
---@param args     { wager: integer }
---@param hostName string
---@return boolean
function M:Open(args, hostName)
    if not state.fsm then state.fsm = ns.FSM.New("IDLE", TRANSITIONS) end

    local wager = type(args) == "table" and args.wager or nil
    if type(wager) ~= "number" or wager ~= math_floor(wager) or wager <= 0 then
        tellHost("DragonDice: wager must be a positive integer.")
        return false
    end

    if type(hostName) ~= "string" or hostName == "" then
        tellHost("DragonDice: cannot open - host name missing.")
        return false
    end

    cancelTimers()
    state.fsm:Reset()
    clearState()

    local resolvedHost = shortName and shortName(hostName) or hostName
    state.host = resolvedHost
    state.wager = wager

    state.fsm:To("OPEN")
    state.timerMode = TIMER_MODE_QUORUM_WAIT
    announce("DragonDice: %s opens a %dg gold roll. Type !join to enter.",
        resolvedHost, wager)

    M._lobbyId = M._lobbyId + 1
    scheduleQuorumWait(M._lobbyId)

    return true
end

---Accept a !join from `player`. Idempotent on duplicate names. Self-join
---by the host is allowed (host plays too). The join that brings the
---count to QUORUM_MIN swaps timerMode from QUORUM_WAIT to
---START_COUNTDOWN; further joins do NOT reset the countdown.
---@param player string
---@return boolean
function M:Join(player)
    if state.fsm == nil or state.fsm:Get() ~= "OPEN" then return false end
    if type(player) ~= "string" or player == "" then return false end

    local who = shortName and shortName(player) or player
    if who == nil or who == "" then return false end
    if state.participants[who] then return false end

    state.participants[who] = true
    state.participantOrder[#state.participantOrder + 1] = who
    state.participantCount = state.participantCount + 1

    announce("DragonDice: %s joined the gold roll. (%d players)",
        who, state.participantCount)

    if state.timerMode == TIMER_MODE_QUORUM_WAIT and state.participantCount >= QUORUM_MIN then
        -- Quorum reached: cancel the silent-wait handle, advance the
        -- epoch so any straggler quorum-wait callback is inert, and arm
        -- the start countdown.
        cancelTimers()
        M._lobbyId = M._lobbyId + 1
        state.timerMode = TIMER_MODE_START_COUNTDOWN
        scheduleStartCountdown(M._lobbyId)
        announce(
            "DragonDice: quorum reached - gold roll starts in %ds " ..
            "(host: !dc goldroll start to begin now, /dc cancel to abort).",
            START_COUNTDOWN_SECONDS)
    end

    return true
end

-- Internal: shared private entry. All three start paths (SlashVerbs,
-- ChatVerbs, Registry:Start global) funnel here.
local function startFromVerb(self, sender)
    if state.fsm == nil or state.fsm:Get() ~= "OPEN" then return false end
    if state.participantCount < QUORUM_MIN then
        tellHost("DragonDice: gold roll needs at least 2 players to start.")
        return false
    end
    local who = (sender and shortName and shortName(sender)) or sender
    if who ~= state.host then return false end

    cancelTimers()
    announce("DragonDice: %s started the gold roll early.", state.host)
    beginRolling()
    return true
end

function M:_StartFromVerb(sender)
    return startFromVerb(self, sender)
end

-- Slash + chat verbs share the same handler shape (game, _, localOrSender
-- + tail). Both call _StartFromVerb with the originating short name; the
-- gate inside refuses non-host sources silently.
M.SlashVerbs = {
    start = function(self, _, localName)
        return self:_StartFromVerb(localName)
    end,
}
M.ChatVerbs = {
    start = function(self, sender, _)
        return self:_StartFromVerb(sender)
    end,
}

---Process a parsed roll record from RollParser. Mutates state only on a
---fully-validated roll. Invalid rolls surface as host-local warnings.
---@param record { player: string, roll: integer, min: integer, max: integer }
---@return boolean
function M:OnRoll(record)
    if state.fsm == nil or state.fsm:Get() ~= "ROLLING" then return false end
    if type(record) ~= "table" then return false end

    local player = record.player
    local rollN = record.roll
    local minN = record.min
    local maxN = record.max
    if not (player and rollN and minN and maxN) then return false end

    local who = shortName and shortName(player) or player
    if not state.participants[who] then
        warn("DragonDice: ignored roll from %s (not a participant).", who)
        return false
    end

    if minN ~= 1 or maxN ~= state.wager then
        warn("DragonDice: %s rolled wrong range 1-%d (expected 1-%d) - roll discarded.",
            who, maxN, state.wager)
        return false
    end

    if state.rolls[who] ~= nil then
        warn("DragonDice: %s already rolled this round - roll discarded.", who)
        return false
    end

    state.rolls[who] = rollN
    state.rollCount = state.rollCount + 1
    state.history[#state.history + 1] = {
        player = who, roll = rollN, min = minN, max = maxN,
        round = state.roundNumber,
    }

    announce("DragonDice: %s rolled %d (%d/%d players done).",
        who, rollN, state.rollCount, state.participantCount)

    if state.rollCount >= state.participantCount then
        state.fsm:To("RESOLVING")
        resolveRound()
    end

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
    tellHost(
        "DragonDice gold roll status: state=%s host=%s wager=%dg participants=%d " ..
        "rolled=%d round=%d timer=%s",
        state.fsm:Get(),
        state.host or none,
        state.wager or 0,
        state.participantCount,
        state.rollCount,
        state.roundNumber,
        state.timerMode or none)
end

---Reset to IDLE silently (host-local; no broadcast).
function M:Reset()
    M._lobbyId = M._lobbyId + 1
    cancelTimers()
    if state.fsm then state.fsm:Reset() end
    clearState()
end

---Cancel the active/open game and broadcast.
---@return boolean
function M:Cancel()
    if state.fsm == nil then return false end
    local current = state.fsm:Get()
    if current == "IDLE" then
        tellHost("DragonDice: no game in progress.")
        return false
    end
    local hostName = state.host
    M._lobbyId = M._lobbyId + 1
    cancelTimers()
    announce("DragonDice: %s cancelled the gold roll.", hostName)
    state.fsm:Reset()
    clearState()
    return true
end

---@return "IDLE" | "OPEN" | "ROLLING" | "RESOLVING" | "FINISHED" | nil
function M:GetState()
    if state.fsm == nil then return nil end
    return state.fsm:Get()
end

---@return string | nil
function M:GetHost()
    return state.host
end

---Test seam: snapshot of current state. NOT used in production.
function M._State()
    local participants = {}
    for i = 1, #state.participantOrder do
        participants[i] = state.participantOrder[i]
    end
    local rolls = {}
    for k, v in pairs(state.rolls) do rolls[k] = v end
    return {
        state = state.fsm and state.fsm:Get() or nil,
        host = state.host,
        wager = state.wager,
        participants = participants,
        participantCount = state.participantCount,
        rolls = rolls,
        rollCount = state.rollCount,
        roundNumber = state.roundNumber,
        timerMode = state.timerMode,
        history = state.history,
    }
end

function M._CountdownHandles() return M._countdownHandles end
function M._LobbyId() return M._lobbyId end
function M._TimerHandle() return M._timerHandle end

-- Schedule the silent quorum-wait terminal callback. No tick announces:
-- the lobby is in a "waiting for players" phase and we do not advertise
-- a countdown for an empty lobby.
scheduleQuorumWait = function(lobbyId)
    local Schedule = ns.Schedule
    if not Schedule or not Schedule.After then return end
    M._timerHandle = Schedule:After(QUORUM_WAIT_SECONDS, function()
        if M._lobbyId ~= lobbyId then return end
        M._timerHandle = nil
        expireQuorum()
    end)
end

-- Schedule the five countdown announces plus the terminal start-rolling
-- callback. Each callback closes over `lobbyId`; the epoch guard makes
-- stragglers inert across cancel/reset/begin-rolling.
scheduleStartCountdown = function(lobbyId)
    local Schedule = ns.Schedule
    if not Schedule or not Schedule.After then return end
    local handles = M._countdownHandles
    for i = 1, #COUNTDOWN_POINTS do
        local point = COUNTDOWN_POINTS[i]
        local remaining = point.remaining
        local handle = Schedule:After(point.at, function()
            if M._lobbyId ~= lobbyId then return end
            announce("DragonDice: gold roll starts in %ds.", remaining)
        end)
        handles[#handles + 1] = handle
    end
    M._timerHandle = Schedule:After(START_COUNTDOWN_SECONDS, function()
        if M._lobbyId ~= lobbyId then return end
        M._timerHandle = nil
        if state.fsm == nil or state.fsm:Get() ~= "OPEN" then return end
        beginRolling()
    end)
end

-- Internal: terminal expiry path for the quorum-wait timer. In the
-- normal flow the quorum-reaching join cancels this handle; the
-- defensive participant-count check covers the race where a join lands
-- after the handle has already been popped from the schedule.
expireQuorum = function()
    if state.fsm == nil or state.fsm:Get() ~= "OPEN" then return end
    if state.participantCount >= QUORUM_MIN then return end
    tellHost("DragonDice: gold roll - no quorum, lobby expired.")
    M._lobbyId = M._lobbyId + 1
    state.fsm:Reset()
    clearState()
end

-- Internal: OPEN -> ROLLING. Shared between the auto-start timer
-- callback and the host-override _StartFromVerb path.
beginRolling = function()
    cancelTimers()
    M._lobbyId = M._lobbyId + 1
    state.fsm:To("ROLLING")
    state.rolls = {}
    state.rollCount = 0
    state.timerMode = nil
    announce("DragonDice: gold roll begins. All %d players: /roll %d",
        state.participantCount, state.wager)
end

-- Internal: choose a winner/loser pair or detect ties. On a clean
-- result transition RESOLVING -> FINISHED. On any tie at either end,
-- filter participants to the union of tied players and re-enter ROLLING.
resolveRound = function()
    local maxRoll, minRoll
    for _, roll in pairs(state.rolls) do
        if maxRoll == nil or roll > maxRoll then maxRoll = roll end
        if minRoll == nil or roll < minRoll then minRoll = roll end
    end
    if maxRoll == nil then
        -- No rolls captured (defensive; resolveRound is only called
        -- after rollCount == participantCount).
        state.fsm:To("IDLE")
        clearState()
        return
    end

    local winners, losers = {}, {}
    for name, roll in pairs(state.rolls) do
        if roll == maxRoll then winners[#winners + 1] = name end
        if roll == minRoll then losers[#losers + 1] = name end
    end
    table_sort(winners)
    table_sort(losers)

    local highTie = #winners > 1
    local lowTie = #losers > 1

    if not highTie and not lowTie then
        local winnerName, loserName = winners[1], losers[1]
        local owed = maxRoll - minRoll
        state.fsm:To("FINISHED")
        announce(
            "DragonDice: gold roll result: %s rolled %d, %s rolled %d. %s owes %s %dg.",
            winnerName, maxRoll, loserName, minRoll, loserName, winnerName, owed)
        return
    end

    -- Tie path: union of tied players re-rolls.
    local tiedSet = {}
    if highTie then
        for i = 1, #winners do tiedSet[winners[i]] = true end
    end
    if lowTie then
        for i = 1, #losers do tiedSet[losers[i]] = true end
    end

    local side
    if highTie and lowTie then side = "high and low"
    elseif highTie then side = "high"
    else side = "low" end

    local tiedList = {}
    for name in pairs(tiedSet) do tiedList[#tiedList + 1] = name end
    table_sort(tiedList)

    announce(
        "DragonDice: tied on the %s end among %s. Tied players re-roll: /roll %d.",
        side, table_concat(tiedList, ", "), state.wager)

    -- Reset participants to the tied subset and clear rolls. Bump the
    -- round counter so Status() and history reflect the sub-round.
    state.participants = {}
    state.participantOrder = {}
    state.participantCount = 0
    for i = 1, #tiedList do
        local name = tiedList[i]
        state.participants[name] = true
        state.participantOrder[#state.participantOrder + 1] = name
        state.participantCount = state.participantCount + 1
    end
    state.rolls = {}
    state.rollCount = 0
    state.roundNumber = state.roundNumber + 1
    state.fsm:To("ROLLING")
end

-- Self-register on the registry. Conditional so a spec that loads this
-- module without a registry does not crash; production TOC orders
-- Registry before this file.
if ns.Registry and ns.Registry.Register then
    ns.Registry:Register(M)
else
    ns.Games = ns.Games or {}
    ns.Games[M.id] = M
end

return M
