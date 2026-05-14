--------------------------------------------------------------------------------
-- Modules/Registry.lua
-- The game registry. Owns the games map, the active-game derivation, the
-- refusal-when-active gate, and the host-permission gate for destructive
-- verbs. The routers (Slash, Chat) talk to Registry; Registry never
-- references a specific game module by id.
--
-- "Active" is derived from each game's own FSM state -- a game is active
-- when its `GetState()` is neither nil nor "IDLE". No mirrored is-active
-- flag exists anywhere; Open is the only writer that flips a game out of
-- IDLE and it is gated through Registry:Open against the derived state.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local print = print
local pairs = pairs
local type = type
local string_format = string.format
local table_concat = table.concat
local table_sort = table.sort

local M = {}

-- Game-id -> game module table. Modules self-register via Register at load.
local _games = {}

-- Internal helper: route a localised, formatted line to the host's chat
-- frame. Mirrors the per-module `tellHost` shape; never broadcast.
local function tellHost(template, ...)
    local L = ns.L
    local resolved = (L and L[template]) or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    if ns.PrintLocal then ns.PrintLocal(resolved) else print(resolved) end
end

-- The fixed contract every game module must satisfy. Validated by Register.
local CONTRACT_KEYS = {
    "id", "displayName", "ParseOpenArgs",
    "Open", "Join", "OnRoll", "Cancel", "Reset",
    "Status", "GetState", "GetHost",
}

---Pure name-comparison gate for destructive verbs (cancel | reset). Takes
---already-normalised short names. Returns false when either side is
---missing so an absent host is never silently treated as a permission
---grant. Lifted out of `Modules/Slash.lua` so Chat and Slash share one
---owner of "is this local player the host?".
---@param localPlayerName string|nil
---@param hostName        string|nil
---@return boolean
function M.CanPlayerAct(localPlayerName, hostName)
    if type(localPlayerName) ~= "string" or localPlayerName == "" then return false end
    if type(hostName) ~= "string" or hostName == "" then return false end
    return localPlayerName == hostName
end

---Register a game module. Validates the duck-typed contract; raises on a
---missing key so a misshapen game fails loudly at load time. Idempotent
---re-registration is intentionally NOT supported -- the registry treats
---two games claiming the same id as a code bug.
---@param game table
function M:Register(game)
    if type(game) ~= "table" then
        error("DragonDice.Registry:Register: game must be a table", 2)
    end
    for i = 1, #CONTRACT_KEYS do
        local key = CONTRACT_KEYS[i]
        if game[key] == nil then
            error("DragonDice.Registry:Register: game missing '" .. key .. "'", 2)
        end
    end
    _games[game.id] = game
    ns.Games = ns.Games or {}
    ns.Games[game.id] = game
end

---@param id string
---@return table|nil
function M:Get(id)
    if type(id) ~= "string" then return nil end
    return _games[id]
end

---Sorted list of registered game ids. Stable order so help text and
---refusal messages are deterministic across reloads.
---@return string[]
function M:List()
    local ids = {}
    for id in pairs(_games) do ids[#ids + 1] = id end
    table_sort(ids)
    return ids
end

---Resolve the active game by scanning every registered game's FSM. Two
---games are never simultaneously non-IDLE because :Open is gated.
---@return table|nil
function M:GetActive()
    for _, game in pairs(_games) do
        local s = game:GetState()
        if s ~= nil and s ~= "IDLE" then return game end
    end
    return nil
end

---@return boolean
function M:IsActive()
    return self:GetActive() ~= nil
end

---Open a lobby for the named game. Refuses if any game is already active
---(host-local print, returns false). Parses the open-args tail via the
---named game's ParseOpenArgs; the game's err string is the diagnostic.
---@param id        string
---@param rest      string
---@param hostName  string
---@return boolean
function M:Open(id, rest, hostName)
    local active = self:GetActive()
    if active then
        tellHost("DragonDice: a %s game is already in progress; /dc cancel first.",
            active.displayName)
        return false
    end

    local game = self:Get(id)
    if game == nil then
        tellHost("DragonDice: unknown game '%s'. Registered: %s.",
            tostring(id), table_concat(self:List(), ", "))
        return false
    end

    local args, err = game.ParseOpenArgs(rest)
    if args == nil then
        if type(err) == "string" and err ~= "" then tellHost(err) end
        return false
    end

    return game:Open(args, hostName)
end

---Forward a parsed roll record to the active game. Drops when no game is
---active (silent; rolls during IDLE are not our event to act on).
function M:DispatchRoll(record)
    local active = self:GetActive()
    if active then active:OnRoll(record) end
end

---Forward a !join from `player` to the active game. Drops silently when
---no game is active (the player typed !join into an empty lobby).
function M:DispatchJoin(player)
    local active = self:GetActive()
    if active then active:Join(player) end
end

-- Internal helper: gate destructive verbs against the active game's host.
-- Returns true when the caller may proceed; emits the host-local warning
-- and returns false when blocked. With no active game, the gate opens
-- (there is nothing to protect).
local function canActOnHostGame(self, localName)
    local active = self:GetActive()
    if active == nil then return true end
    local host = active:GetHost()
    if M.CanPlayerAct(localName, host) then return true end
    tellHost("DragonDice: only the host (%s) may run that command.", host or "?")
    return false
end

---Cancel the active game (host-only).
---@param localName string|nil  Short-form name of the local player.
---@return boolean
function M:Cancel(localName)
    local active = self:GetActive()
    if active == nil then
        tellHost("DragonDice: no game in progress.")
        return false
    end
    if not canActOnHostGame(self, localName) then return false end
    return active:Cancel()
end

---Silent reset of the active game (host-only).
---@param localName string|nil
---@return boolean
function M:Reset(localName)
    local active = self:GetActive()
    if active == nil then return false end
    if not canActOnHostGame(self, localName) then return false end
    active:Reset()
    return true
end

---Print the active game's status, or "no game in progress" host-locally.
function M:Status()
    local active = self:GetActive()
    if active then
        active:Status()
        return
    end
    tellHost("DragonDice: no game in progress.")
end

---Global `/dc start` -- delegate to the active game's SlashVerbs.start if
---it declares one. Host-local diagnostics when no game is active or the
---active game has no start verb (e.g. deathroll auto-starts on join).
---@param localName string|nil
function M:Start(localName)
    local active = self:GetActive()
    if active == nil then
        tellHost("DragonDice: no game in progress.")
        return false
    end
    local fn = active.SlashVerbs and active.SlashVerbs.start
    if fn == nil then
        tellHost("DragonDice: nothing to start.")
        return false
    end
    return fn(active, "", localName)
end

-- Test seam: clear the games map. NOT used in production.
function M._Reset()
    _games = {}
    if ns.Games then
        for k in pairs(ns.Games) do ns.Games[k] = nil end
    end
end

ns.Registry = setmetatable(M, { __index = ns.Registry or {} })

return M
