--------------------------------------------------------------------------------
-- Modules/Chat.lua
-- WoW chat-event subscriptions. Subscribes to CHAT_MSG_SYSTEM (route through
-- RollParser -> Game:OnRoll) and to the player-chat events that may carry
-- "!join" or "!bet <amount>" (PARTY/PARTY_LEADER/RAID/RAID_LEADER/
-- INSTANCE_CHAT/INSTANCE_CHAT_LEADER/SAY).
--
-- Whisper is intentionally NOT subscribed: chat commands from a whisper are
-- rejected to keep the lobby in-channel.
--
-- `!bet <amount>` semantics: only processed when Game state is IDLE. The
-- sender becomes the host (even when remote). Malformed amounts and
-- out-of-state messages are silently dropped -- public chat noise must
-- never be amplified.
--
-- All event subscription routes through DragonCore.Listener -- a per-instance
-- unnamed Frame, taint-isolated by construction.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local LibStub = LibStub
local DragonCore = LibStub("DragonCore-1.0")

local M = {}

-- Chat events that may legitimately carry "!join" or "!bet". Whisper is
-- excluded.
local GROUP_CHAT_EVENTS = {
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_SAY",
}

-- Internal helper: trim leading/trailing whitespace and lowercase. Used to
-- detect bare-token commands (`!join`) tolerantly (extra spaces / case
-- variants).
local function normalisedToken(text)
    if type(text) ~= "string" then return nil end
    local trimmed = text:match("^%s*(.-)%s*$")
    if not trimmed then return nil end
    return trimmed:lower()
end

---@param addon DragonCore.Addon
function M:Init(addon)
    local listener = DragonCore.Listener:New(addon)

    -- CHAT_MSG_SYSTEM is the source of /roll lines. Parse-then-dispatch.
    addon:Track(listener:On("CHAT_MSG_SYSTEM", function(msg)
        local record = ns.RollParser.Parse(msg)
        if record then
            ns.Game:OnRoll(record)
        end
    end))

    -- Player-chat events: detect `!join` and `!bet <amount>` and route to
    -- Game:Join / Game:Open. Sender (arg2 of CHAT_MSG_*) is the joiner or
    -- the aspiring host depending on the token. The match auto-starts the
    -- instant Game:Join records its single opponent; there is no separate
    -- start verb.
    for i = 1, #GROUP_CHAT_EVENTS do
        local ev = GROUP_CHAT_EVENTS[i]
        addon:Track(listener:On(ev, function(msg, sender)
            local token = normalisedToken(msg)
            if token == "!join" then
                ns.Game:Join(sender)
                return
            end

            local bet = ns.BetParser and ns.BetParser.Parse(msg) or nil
            if bet == nil then return end
            -- Only the first valid !bet from IDLE may open the lobby; all
            -- subsequent !bet messages are silently ignored until the game
            -- returns to IDLE.
            if ns.Game.GetState and ns.Game:GetState() ~= "IDLE" then return end
            ns.Game:Open(bet, sender)
        end))
    end
end

ns.Chat = setmetatable(M, { __index = ns.Chat or {} })

return M
