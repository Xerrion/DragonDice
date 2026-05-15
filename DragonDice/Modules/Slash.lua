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

local string_lower = string.lower
local table_concat = table.concat

local M = {}

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
    ns.TellHost("DragonDice: usage: /dc <game> open <args> | status | cancel | reset | start")
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
    ns.TellHost("DragonDice: registered games: %s.", table_concat(names, ", "))
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
        ns.TellHost("DragonDice: unknown command '%s'. Try /dc for usage.", verb)
        return
    end

    local subVerb, subRest = splitVerb(rest)
    if subVerb == nil then
        ns.TellHost("DragonDice: usage: /dc %s open <args>", verb)
        return
    end

    if subVerb == "open" then
        ns.Registry:Open(verb, subRest, localPlayerShortName())
        return
    end

    local fn = game.SlashVerbs and game.SlashVerbs[subVerb]
    if fn == nil then
        ns.TellHost("DragonDice: unknown verb '%s %s'. Try /dc for usage.", verb, subVerb)
        return
    end
    fn(game, subRest, localPlayerShortName())
end

-- Internal helper: write the slash globals. Idempotent (re-runnable) so
-- both the file-load path and Init can call it safely.
local function registerSlash()
    if type(_G.SlashCmdList) ~= "table" then return false end
    _G.SLASH_DRAGONDICE1 = "/dc"
    _G.SLASH_DRAGONDICE2 = "/dragondice"
    _G.SlashCmdList["DRAGONDICE"] = handler
    return true
end

-- Register at file-load time. The slash globals must exist regardless of
-- whether `OnReady` later succeeds; otherwise a failure deeper in the init
-- chain (Store, game Init, Chat) would silently leave `/dc` undefined and
-- the user with no way to inspect state. SlashCmdList is a Blizzard-owned
-- global present from interface load; the guard keeps headless tests (which
-- do not pre-seed it) from blowing up at module load.
registerSlash()

---@param _addon DragonCore.Addon
function M:Init(_addon)
    -- Belt-and-braces: re-run registration in case the file-load path
    -- found SlashCmdList missing (e.g. an unusual harness). Idempotent.
    registerSlash()
end

-- Test seam: invoke the slash handler directly. NOT used in production.
function M._Handle(msg) handler(msg) end

ns.Slash = setmetatable(M, { __index = ns.Slash or {} })

return M
