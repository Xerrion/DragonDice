-------------------------------------------------------------------------------
-- Announce_spec.lua
-- DragonDice Announce.PickChannel: pure channel selector covering every
-- group-state combination. The Send wrapper is impure (calls SendChatMessage)
-- and is exercised lightly via a stub.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

describe("Announce", function()
    local Announce

    before_each(function()
        Announce = loader.load("Modules/Announce.lua")
    end)

    describe("PickChannel", function()
        it("picks INSTANCE_CHAT when in an instance group", function()
            assert.equals("INSTANCE_CHAT", Announce.PickChannel({
                inInstanceGroup = true,
                inRaid = true,
                inParty = true,
            }))
        end)

        it("picks RAID when in a raid but not an instance group", function()
            assert.equals("RAID", Announce.PickChannel({
                inInstanceGroup = false,
                inRaid = true,
                inParty = true,
            }))
        end)

        it("picks PARTY when in a party but not a raid", function()
            assert.equals("PARTY", Announce.PickChannel({
                inInstanceGroup = false,
                inRaid = false,
                inParty = true,
            }))
        end)

        it("picks SAY when solo", function()
            assert.equals("SAY", Announce.PickChannel({
                inInstanceGroup = false,
                inRaid = false,
                inParty = false,
            }))
        end)

        it("treats nil flags as false", function()
            assert.equals("SAY", Announce.PickChannel({}))
        end)

        it("validates groupState type", function()
            assert.has_error(function() Announce.PickChannel(nil) end)
            assert.has_error(function() Announce.PickChannel("party") end)
        end)
    end)

    describe("Send", function()
        local previousSend, previousIsInGroup, previousIsInRaid

        before_each(function()
            previousSend = _G.SendChatMessage
            previousIsInGroup = _G.IsInGroup
            previousIsInRaid = _G.IsInRaid
        end)

        after_each(function()
            _G.SendChatMessage = previousSend
            _G.IsInGroup = previousIsInGroup
            _G.IsInRaid = previousIsInRaid
        end)

        it("routes through SendChatMessage with the picked channel", function()
            -- IsInGroup(LE_PARTY_CATEGORY_INSTANCE) -> false (regular party);
            -- IsInGroup() -> true.
            _G.IsInGroup = function(category) return category == nil end
            _G.IsInRaid = function() return false end
            local captured = {}
            _G.SendChatMessage = function(text, channel)
                captured.text = text
                captured.channel = channel
            end

            Announce.Send("hello")

            assert.equals("hello", captured.text)
            assert.equals("PARTY", captured.channel)
        end)

        it("is a no-op for empty input", function()
            local called = false
            _G.SendChatMessage = function() called = true end
            Announce.Send("")
            Announce.Send(nil)
            assert.is_false(called)
        end)

        it("is a no-op when SendChatMessage is unavailable", function()
            _G.SendChatMessage = nil
            assert.has_no.errors(function() Announce.Send("hello") end)
        end)
    end)
end)
