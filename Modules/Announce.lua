--------------------------------------------------------------------------------
-- Modules/Announce.lua
-- Channel selection + thin SendChatMessage wrapper. The channel selector is
-- pure: it takes a group-state record and returns the channel name. The
-- Send wrapper is the only impure surface (calls SendChatMessage).
--
-- Selection priority (per ADR): INSTANCE_CHAT > RAID > PARTY > SAY.
--   * INSTANCE_CHAT when in an instance group (LFG / LFR / random BG / etc.)
--   * RAID when in a raid (and not instance group)
--   * PARTY when in a party (and not instance group, not raid)
--   * SAY otherwise (solo / world). SAY has a 40-yard radius which is the
--     correct fallback for a deathroll between two people next to each other.
--
-- Supported versions: Retail
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local M = {}

---Pure channel selector. `groupState` is a flat record so callers control
---the WoW API surface (testability), e.g.:
---  { inInstanceGroup = IsInGroup(LE_PARTY_CATEGORY_INSTANCE),
---    inRaid          = IsInRaid(),
---    inParty         = IsInGroup() }
---@param groupState { inInstanceGroup: boolean, inRaid: boolean, inParty: boolean }
---@return string  one of "INSTANCE_CHAT", "RAID", "PARTY", "SAY".
function M.PickChannel(groupState)
    if type(groupState) ~= "table" then
        error("DragonDice.Announce.PickChannel: groupState must be a table", 2)
    end
    if groupState.inInstanceGroup then return "INSTANCE_CHAT" end
    if groupState.inRaid then return "RAID" end
    if groupState.inParty then return "PARTY" end
    return "SAY"
end

---Probe live WoW group state. Production-only path; specs construct the
---groupState record directly to exercise PickChannel.
---@return { inInstanceGroup: boolean, inRaid: boolean, inParty: boolean }
function M.LiveGroupState()
    local IsInGroup = _G.IsInGroup
    local IsInRaid = _G.IsInRaid
    -- LE_PARTY_CATEGORY_INSTANCE = 2 across every supported flavor; reading
    -- the global keeps us honest if Blizzard ever re-numbers.
    local instanceCat = _G.LE_PARTY_CATEGORY_INSTANCE or 2
    return {
        inInstanceGroup = IsInGroup ~= nil and IsInGroup(instanceCat) and true or false,
        inRaid          = IsInRaid ~= nil and IsInRaid() and true or false,
        inParty         = IsInGroup ~= nil and IsInGroup() and true or false,
    }
end

---Broadcast `text` on the best channel for the current group state.
---No-op in tests where SendChatMessage is absent.
---@param text string
function M.Send(text)
    if type(text) ~= "string" or text == "" then return end
    local channel = M.PickChannel(M.LiveGroupState())
    local SendChatMessage = _G.SendChatMessage
    if SendChatMessage then
        SendChatMessage(text, channel)
    end
end

ns.Announce = M

return M
