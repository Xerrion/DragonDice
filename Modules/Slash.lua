--------------------------------------------------------------------------------
-- Modules/Slash.lua
-- Owns SLASH_DRAGONDICE1 = "/dc" and SLASH_DRAGONDICE2 = "/dragondice". The
-- dispatcher is parse-and-route only: every verb funnels through
-- `ns.Registry`. Slash never reaches into a specific game module.
--
-- Grammar (see ADR-0002 §C):
--   /dc                            -> help
--   /dc help                       -> help
--   /dc <verb>                     -> global verb (status | cancel | reset | start)
--   /dc <game> open <args...>      -> open a lobby for the named game
--   /dc <game> <verb> [args...]    -> any verb declared in <game>.SlashVerbs
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local print = print
local string_lower = string.lower
local string_format = string.format
local table_concat = table.concat

local M = {}

-- Internal helper: surface a host-local message via L (no broadcast).
local function tellHost(template, ...)
    local L = ns.L
    local resolved = L and L[template] or template
    if select("#", ...) > 0 then resolved = string_format(resolved, ...) end
    print(resolved)
end

-- Internal helper: split "verb rest" out of an input string. Empty input
-- yields nil verb (caller prints usage). `rest` is left trimmed.
local function splitVerb(msg)
    if type(msg) ~= "string" then return nil, "" end
    local trimmed = msg:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then return nil, "" end
    local verb, rest = trimmed:match("^(%S+)%s*(.-)$")
    return verb and string_lower(verb) or nil, rest or ""
end

-- Internal helper: short-form name of the local player. Delegates to the
-- shared `ns.GetShortName` so host comparisons line up byte-for-byte.
local function localPlayerShortName()
    local UnitName = _G.UnitName
    return ns.GetShortName(UnitName and UnitName("player") or nil)
end

-- Internal helper: print the help listing. The "registered games" line
-- enumerates via Registry:List + Registry:Get(id).displayName so newly
-- added games surface as their user-facing name without a locale edit.
local function printHelp()
    tellHost("DragonDice: usage: /dc <game> open <args> | status | cancel | reset | start")
    local Registry = ns.Registry
    if Registry == nil then return end
    local ids = Registry:List()
    if #ids == 0 then return end
    local names = {}
    for i = 1, #ids do
        local id = ids[i]
        local game = Registry:Get(id)
        names[i] = (game and game.displayName) or id
    end
    tellHost("DragonDice: registered games: %s.", table_concat(names, ", "))
end

-- Global verbs: routed through Registry, which owns active-game derivation
-- and the host-permission gate.
local GLOBAL_VERBS = {
    help   = function() printHelp() end,
    status = function() ns.Registry:Status() end,
    cancel = function() ns.Registry:Cancel(localPlayerShortName()) end,
    reset  = function() ns.Registry:Reset(localPlayerShortName()) end,
    start  = function() ns.Registry:Start(localPlayerShortName()) end,
}

local function handler(msg)
    local verb, rest = splitVerb(msg)
    if verb == nil then
        printHelp()
        return
    end

    local globalFn = GLOBAL_VERBS[verb]
    if globalFn then
        globalFn(rest)
        return
    end

    -- Otherwise `verb` is interpreted as a game id.
    local game = ns.Registry and ns.Registry:Get(verb) or nil
    if game == nil then
        tellHost("DragonDice: unknown command '%s'. Try /dc for usage.", verb)
        return
    end

    local subVerb, subRest = splitVerb(rest)
    if subVerb == nil then
        tellHost("DragonDice: usage: /dc %s open <args>", verb)
        return
    end

    if subVerb == "open" then
        ns.Registry:Open(verb, subRest, localPlayerShortName())
        return
    end

    local fn = game.SlashVerbs and game.SlashVerbs[subVerb]
    if fn == nil then
        tellHost("DragonDice: unknown verb '%s %s'. Try /dc for usage.", verb, subVerb)
        return
    end
    fn(game, subRest, localPlayerShortName())
end

---@param _addon DragonCore.Addon
function M:Init(_addon)
    -- The two SLASH_<NAME>N globals plus SlashCmdList[<NAME>] are the only
    -- globals this addon writes besides DragonDiceDB.
    _G.SLASH_DRAGONDICE1 = "/dc"
    _G.SLASH_DRAGONDICE2 = "/dragondice"
    _G.SlashCmdList["DRAGONDICE"] = handler
end

-- Test seam: invoke the slash handler directly. NOT used in production.
function M._Handle(msg) handler(msg) end

ns.Slash = setmetatable(M, { __index = ns.Slash or {} })

return M
