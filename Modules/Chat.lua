--------------------------------------------------------------------------------
-- Modules/Chat.lua
-- WoW chat-event subscriptions. Subscribes to CHAT_MSG_SYSTEM (route through
-- RollParser -> Registry:DispatchRoll) and to the player-chat events that
-- may carry "!join" (PARTY/PARTY_LEADER/RAID/RAID_LEADER/INSTANCE_CHAT/
-- INSTANCE_CHAT_LEADER/SAY).
--
-- Whisper is intentionally NOT subscribed: chat commands from a whisper
-- are rejected to keep the lobby in-channel.
--
-- !join semantics: forwarded to the active game (if any) via the registry.
-- Out-of-state messages are silently dropped -- public chat noise must
-- never be amplified.
--
-- All event subscription routes through DragonCore.Listener -- a per-
-- instance unnamed Frame, taint-isolated by construction.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local LibStub = LibStub
local DragonCore = LibStub("DragonCore-1.0")

local M = {}

-- Chat events that may legitimately carry "!join". Whisper is excluded.
local GROUP_CHAT_EVENTS = {
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_SAY",
}

-- Internal helper: trim leading/trailing whitespace and lowercase. Used
-- to detect bare-token commands (`!join`) tolerantly (extra spaces /
-- case variants).
local function normalisedToken(text)
    if type(text) ~= "string" then return nil end
    local trimmed = text:match("^%s*(.-)%s*$")
    if not trimmed then return nil end
    return trimmed:lower()
end

---@param addon DragonCore.Addon
function M:Init(addon)
    local listener = DragonCore.Listener:New(addon)

    -- CHAT_MSG_SYSTEM is the source of /roll lines. Parse-then-dispatch
    -- via the registry; the active game decides if the roll applies.
    addon:Track(listener:On("CHAT_MSG_SYSTEM", function(msg)
        local record = ns.RollParser.Parse(msg)
        if record then
            ns.Registry:DispatchRoll(record)
        end
    end))

    -- Player-chat events: detect `!join` and route to the active game via
    -- the registry. Sender (arg2 of CHAT_MSG_*) is the joiner.
    for i = 1, #GROUP_CHAT_EVENTS do
        local ev = GROUP_CHAT_EVENTS[i]
        addon:Track(listener:On(ev, function(msg, sender)
            local token = normalisedToken(msg)
            if token == "!join" then
                ns.Registry:DispatchJoin(sender)
                return
            end
        end))
    end
end

ns.Chat = setmetatable(M, { __index = ns.Chat or {} })

return M
