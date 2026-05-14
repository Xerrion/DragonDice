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
-- starts returning key-as-value until Locale\enUS.lua registers strings later
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

-- OnReady fires once, after PLAYER_LOGIN, with SavedVariables hydrated. We
-- open the Store first (so any module that wants it has it) then drive each
-- module's Init pass in dependency order.
addon:OnReady(function()
    DragonCore.Store:Open(addon, {
        savedVariable = "DragonDiceDB",
        defaults = {
            global = { version = 1, stats = {} },
        },
    })

    -- Stateless modules (FSM, RollParser, Announce, Registry) have
    -- nothing to wire; their tables expose pure functions ready to call.
    -- Each registered game gets its Init pass before the routers wire
    -- chat / slash dispatch.
    for _, game in pairs(ns.Games) do
        if game.Init then game:Init(addon) end
    end
    if ns.Chat.Init then ns.Chat:Init(addon) end
    if ns.Slash.Init then ns.Slash:Init(addon) end
end)
