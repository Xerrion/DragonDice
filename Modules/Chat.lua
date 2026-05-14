--------------------------------------------------------------------------------
-- Modules/Chat.lua
-- WoW chat-event subscriptions. Subscribes to CHAT_MSG_SYSTEM (route
-- through RollParser -> Registry:DispatchRoll) and to the group-chat
-- events that may carry "!join" or "!dc <game> ..." (PARTY / PARTY_LEADER
-- / RAID / RAID_LEADER / INSTANCE_CHAT / INSTANCE_CHAT_LEADER / SAY).
--
-- Whisper is intentionally NOT subscribed: chat commands from a whisper
-- are rejected to keep the lobby in-channel.
--
-- `!join` -> Registry:DispatchJoin(sender). Active game decides whether
-- to accept; out-of-state joins are silently dropped.
--
-- `!dc <game> <args...>` opens a lobby for the named game via Registry.
-- `!dc <game> <verb> [args...]` invokes a per-game verb declared in
-- `game.ChatVerbs`; an unknown verb falls through to `ParseOpenArgs`
-- (verb-table-lookup disambiguation per ADR-0002 §D).
--
-- Refusal discipline (ADR-0002 §D): never amplify public chat. Host-local
-- diagnostics surface for the LOCAL player typing the command; refusals
-- triggered by remote senders are silent on every path (unknown game,
-- unknown verb, active-game refusal, parse failure).
--
-- All event subscription routes through DragonCore.Listener -- a per-
-- instance unnamed Frame, taint-isolated by construction.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local LibStub = LibStub
local DragonCore = LibStub("DragonCore-1.0")

local string_lower = string.lower

local M = {}

-- Group-chat events that may legitimately carry "!join" or "!dc ...".
-- Whisper is excluded.
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

-- Internal helper: split the leading whitespace-separated token from the
-- trimmed remainder. Returns nil token for empty / non-string input. The
-- token is lowercased so `Goldroll`, `goldroll`, and `GOLDROLL` all
-- resolve to the same game id.
local function splitToken(text)
    if type(text) ~= "string" then return nil, "" end
    local trimmed = text:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then return nil, "" end
    local tok, tail = trimmed:match("^(%S+)%s*(.-)$")
    return tok and string_lower(tok) or nil, tail or ""
end

-- Internal helper: short-form name of the local player. Used to suppress
-- host-local diagnostics when the originating chat sender is remote.
local function localPlayerShortName()
    local UnitName = _G.UnitName
    return ns.GetShortName and ns.GetShortName(UnitName and UnitName("player") or nil) or nil
end

-- Internal helper: is `sender` the local player? Compares already-
-- normalised short names. Returns false on any nil/mismatch so a missing
-- local-player resolution is treated as remote (the safer default - it
-- only suppresses noise, never opens a refusal channel).
local function isLocalSender(sender)
    local me = localPlayerShortName()
    if me == nil then return false end
    local who = ns.GetShortName and ns.GetShortName(sender) or sender
    return who == me
end

-- Internal helper: dispatch a parsed `!dc <game> ...` message. The
-- verb-table-lookup disambiguation rule (§D) hits the named game's
-- `ChatVerbs` first; on miss the entire post-`<game>` tail forwards to
-- ParseOpenArgs via Registry:Open. Unknown-game and bare-`!dc <game>`
-- inputs drop silently to keep chat noise out of public channels.
local function dispatchDc(rest, sender)
    local gameId, tail = splitToken(rest)
    if gameId == nil then return end -- bare `!dc`

    local game = ns.Registry and ns.Registry:Get(gameId) or nil
    if game == nil then return end -- unknown game

    local verbTok, verbTail = splitToken(tail)
    if verbTok == nil then return end -- `!dc <game>` with no further args

    -- Verb-table-lookup against the named game's ChatVerbs. Absent table
    -- or missing entry both count as miss; the original `tail` (with the
    -- candidate verb still attached) flows to ParseOpenArgs.
    local fn = game.ChatVerbs and game.ChatVerbs[verbTok]
    if fn then
        fn(game, sender, verbTail)
        return
    end

    -- Verb miss: treat the whole tail as open-args. Refusal paths are
    -- host-local-noisy when the local player typed the message and
    -- silent on every path when the sender is remote (chat-noise
    -- discipline).
    if not isLocalSender(sender) then
        if ns.Registry:IsActive() then return end
        local args = game.ParseOpenArgs(tail)
        if args == nil then return end
    end
    ns.Registry:Open(gameId, tail, sender)
end

-- Internal helper: process a single group-chat line. Returns nothing; all
-- routing happens via Registry. The first matching token wins; only one
-- handler fires per message.
local function dispatchGroup(msg, sender)
    local token = normalisedToken(msg)
    if token == "!join" then
        ns.Registry:DispatchJoin(sender)
        return
    end

    -- `!dc <...>` shape: `splitToken` on the trimmed message yields the
    -- leading token; on `!dc` we route the remainder into the disambig
    -- helper.
    local leading, rest = splitToken(msg)
    if leading == "!dc" then
        dispatchDc(rest, sender)
        return
    end
end

-- Internal helper: route a CHAT_MSG_SYSTEM line through RollParser to the
-- active game (via the registry).
local function dispatchSystem(msg)
    local record = ns.RollParser.Parse(msg)
    if record then
        ns.Registry:DispatchRoll(record)
    end
end

---@param addon DragonCore.Addon
function M:Init(addon)
    local listener = DragonCore.Listener:New(addon)

    addon:Track(listener:On("CHAT_MSG_SYSTEM", function(msg)
        dispatchSystem(msg)
    end))

    for i = 1, #GROUP_CHAT_EVENTS do
        local ev = GROUP_CHAT_EVENTS[i]
        addon:Track(listener:On(ev, function(msg, sender)
            dispatchGroup(msg, sender)
        end))
    end
end

-- Test seams: invoke the dispatchers directly. NOT used in production.
function M._HandleGroup(msg, sender) dispatchGroup(msg, sender) end
function M._HandleSystem(msg) dispatchSystem(msg) end

ns.Chat = setmetatable(M, { __index = ns.Chat or {} })

return M
