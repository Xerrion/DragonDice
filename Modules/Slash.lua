--------------------------------------------------------------------------------
-- Modules/Slash.lua
-- Owns SLASH_DRAGONDICE1 = "/dr" and a small verb dispatch table. Per ADR
-- decision D1 we roll our own dispatcher rather than ride DragonCore.Settings'
-- built-in `open`/`reset` verbs (semantic collision: our `open` opens a
-- lobby, not a panel).
--
-- Verbs (orchestrator-confirmed): open <bet>, start, status, reset, cancel.
-- The eventual options panel will get a sibling slash (e.g. /dropts) post-
-- MVP; we do not retrofit /dr to dual-purpose.
--
-- Supported versions: Retail
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local print = print
local string_lower = string.lower
local string_format = string.format
local tonumber = tonumber

local M = {}

-- Internal helper: surface a host-local message via L (no broadcast).
local function tellHost(template, ...)
    local L = ns.L
    local resolved = L and L[template] or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    print(resolved)
end

-- Internal helper: split "verb rest" out of a slash invocation. Empty input
-- yields nil verb (caller prints usage).
local function splitVerb(msg)
    if type(msg) ~= "string" then return nil, "" end
    local trimmed = msg:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then return nil, "" end
    local verb, rest = trimmed:match("^(%S+)%s*(.-)$")
    return verb and string_lower(verb) or nil, rest or ""
end

-- Internal helper: short-form name of the local player. Delegates to the
-- shared `ns.GetShortName` (see Core.lua) so host comparisons line up
-- byte-for-byte across modules.
local function localPlayerShortName()
    local UnitName = _G.UnitName
    return ns.GetShortName(UnitName and UnitName("player") or nil)
end

-- Pure name-comparison gate for destructive verbs (start | cancel | reset).
-- Takes already-normalised short names. The IDLE-state bypass lives in the
-- closure below; this function strictly answers "are these two names the
-- same player?" Returns false when either name is nil so a missing host or
-- a missing local player is never silently treated as a permission grant.
---@param localPlayerName string|nil  Short-form name of the local player.
---@param hostName        string|nil  Short-form name of the current host.
---@return boolean
function M.CanPlayerAct(localPlayerName, hostName)
    if type(localPlayerName) ~= "string" or localPlayerName == "" then return false end
    if type(hostName) ~= "string" or hostName == "" then return false end
    return localPlayerName == hostName
end

-- Internal helper: gate destructive verbs (start | cancel | reset) when a
-- game is in progress and the local player is not the host. Returns true
-- when the caller may proceed; emits a host-local warning and returns
-- false when blocked. IDLE (and pre-Init nil) games have no host yet, so
-- the gate opens.
local function localPlayerMayActOnHostGame()
    local Game = ns.Game
    local fsmState = Game and Game.GetState and Game:GetState() or nil
    if fsmState == nil or fsmState == "IDLE" then return true end
    local host = Game and Game.GetHost and Game:GetHost() or nil
    local me = localPlayerShortName()
    if M.CanPlayerAct(me, host) then return true end
    tellHost("DragonDice: only the host (%s) may run that command.", host or "?")
    return false
end

-- Verb dispatch table. Each handler receives the trimmed argument tail.
-- Closures capture `ns.Game` lazily (via the function call) so module load
-- order between Slash and Game does not matter.
local DISPATCH = {
    open = function(arg)
        local bet = tonumber(arg)
        if bet == nil then
            tellHost("DragonDice: bet must be a positive integer.")
            return
        end
        ns.Game:Open(bet, localPlayerShortName())
    end,
    start = function()
        if not localPlayerMayActOnHostGame() then return end
        ns.Game:Start()
    end,
    status = function() ns.Game:Status() end,
    reset = function()
        if not localPlayerMayActOnHostGame() then return end
        ns.Game:Reset()
    end,
    cancel = function()
        if not localPlayerMayActOnHostGame() then return end
        ns.Game:Cancel()
    end,
}

local function handler(msg)
    local verb, rest = splitVerb(msg)
    if verb == nil then
        tellHost("DragonDice: usage: /dr open <bet> | start | status | reset | cancel")
        return
    end
    local fn = DISPATCH[verb]
    if fn == nil then
        tellHost("DragonDice: unknown command '%s'. Try /dr for usage.", verb)
        return
    end
    fn(rest)
end

---@param _addon DragonCore.Addon
function M:Init(_addon)
    -- The two SLASH_<NAME>N globals plus SlashCmdList[<NAME>] are the only
    -- globals this addon writes besides DragonDiceDB.
    _G.SLASH_DRAGONDICE1 = "/dr"
    _G.SLASH_DRAGONDICE2 = "/dragondice"
    _G.SlashCmdList["DRAGONDICE"] = handler
end

-- Test seam: invoke the slash handler directly. NOT used in production.
function M._Handle(msg) handler(msg) end

ns.Slash = setmetatable(M, { __index = ns.Slash or {} })

return M
