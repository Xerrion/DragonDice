--------------------------------------------------------------------------------
-- Core.lua
-- DragonDice bootstrap. Wires the addon into DragonCore (Lifecycle, Locale,
-- Store) and resolves the per-module Init pass on OnReady.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local LibStub = LibStub
local DragonCore = LibStub("DragonCore-1.0")

local Ambiguate = Ambiguate
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME

ns.ADDON_NAME = ADDON_NAME

-- Public helper: route a host-local string to the player's default chat
-- frame. Single sink so future routing (toast frame, options-panel log) is a
-- one-line change. Modules call this for all non-broadcast user messages.
---@param text string
function ns.PrintLocal(text)
    if type(text) ~= "string" or text == "" then return end
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    end
end

-- Public helper: localised + formatted host-local print. The template is
-- resolved through `ns.L` (DragonCore.Locale proxy) so callers pass the
-- English sentence as the key and trust the proxy to substitute the
-- active-locale value. Falls back to the literal template when the
-- proxy is missing or has not yet registered the key. Routes through
-- `ns.PrintLocal` so the same single sink owns delivery.
---@param template string
function ns.TellHost(template, ...)
    if type(template) ~= "string" then return end
    local L = ns.L
    local resolved = (L and L[template]) or template
    if select("#", ...) > 0 then resolved = resolved:format(...) end
    ns.PrintLocal(resolved)
end

-- Expose DragonCore.Schedule on the private namespace so modules can call it
-- without re-resolving LibStub. Keeps Modules/ load-order independent of the
-- LibStub global presence (notably: pure-Lua headless tests inject their own
-- stub on `ns.Schedule` before loading Game.lua).
ns.Schedule = DragonCore.Schedule

-- Public helper: short-form player name (strip realm) for cross-realm hosts.
-- Uses Ambiguate(name, "short") only; no further normalisation, so callers
-- can compare names byte-for-byte across modules. Returns nil for nil,
-- non-string, or empty input so callers get a single sentinel to check.
---@param name any
---@return string|nil
function ns.GetShortName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if Ambiguate then return Ambiguate(name, "short") end
    -- Stub fallback for tests / non-WoW environments: strip the first '-'
    -- and everything after.
    return name:match("^([^%-]+)") or name
end

-- Register with DragonCore Lifecycle. The handle is exposed on `ns` so the
-- Modules/* layer can reach it without re-querying the registry.
local addon = DragonCore.Lifecycle:Register(ADDON_NAME)
ns.addon = addon

-- Resolve the locale proxy eagerly. The proxy is stable across calls and
-- starts returning key-as-value until Locales/enUS.lua registers strings later
-- in the TOC -- both states are safe to read.
ns.L = DragonCore.Locale:Get({ name = ADDON_NAME })

-- Hold a private slot on `ns` for each module. They self-attach during their
-- own file load below; Core.lua only declares the namespace shape.
ns.FSM = ns.FSM or {}
ns.RollParser = ns.RollParser or {}
ns.Announce = ns.Announce or {}
ns.Registry = ns.Registry or {}
ns.Games = ns.Games or {}
ns.Chat = ns.Chat or {}
ns.Slash = ns.Slash or {}

-- Internal helper: surface an init-time error to the player and the
-- standard WoW error handler. We never swallow silently -- a failure in
-- one phase must not leave the user staring at an unresponsive `/dc`
-- with no diagnostic. The `geterrorhandler()` indirection routes through
-- BugSack / Swatter / Blizzard's default UI error frame uniformly.
local function reportInitError(phase, err)
    local message = "DragonDice: init error in " .. phase .. ": " .. tostring(err)
    ns.PrintLocal(message)
    local handler = _G.geterrorhandler and _G.geterrorhandler() or nil
    if type(handler) == "function" then handler(message) end
end

-- OnReady fires once, after PLAYER_LOGIN, with SavedVariables hydrated. We
-- register the slash command first (so `/dc` always works as a diagnostic
-- channel even if a later phase blows up), then open the Store, then drive
-- each module's Init pass in dependency order. Every fallible phase is
-- pcall-wrapped so one module's failure does not block the rest.
addon:OnReady(function()
    -- Slash first: it is the user's only inspection lever if everything
    -- else collapses. `Modules/Slash.lua` also registers at file-load
    -- time; this call is a no-op safety net.
    if ns.Slash.Init then
        local ok, err = pcall(ns.Slash.Init, ns.Slash, addon)
        if not ok then reportInitError("Slash:Init", err) end
    end

    local ok, err = pcall(function()
        DragonCore.Store:Open(addon, {
            savedVariable = "DragonDiceDB",
            defaults = {
                global = { version = 1, stats = {} },
            },
        })
    end)
    if not ok then reportInitError("Store:Open", err) end

    -- Stateless modules (FSM, RollParser, Announce, Registry) have
    -- nothing to wire; their tables expose pure functions ready to call.
    -- Each registered game gets its Init pass before the routers wire
    -- chat dispatch. Per-game pcall isolation: one broken game must not
    -- prevent the rest from initialising.
    for id, game in pairs(ns.Games) do
        if game.Init then
            local gok, gerr = pcall(game.Init, game, addon)
            if not gok then reportInitError("Games[" .. tostring(id) .. "]:Init", gerr) end
        end
    end

    if ns.Chat.Init then
        local cok, cerr = pcall(ns.Chat.Init, ns.Chat, addon)
        if not cok then reportInitError("Chat:Init", cerr) end
    end
end)
