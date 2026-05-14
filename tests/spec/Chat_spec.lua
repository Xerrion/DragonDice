-------------------------------------------------------------------------------
-- Chat_spec.lua
-- DragonDice Chat: the group-chat dispatcher (`!join`, `!dc <...>`) and
-- the CHAT_MSG_SYSTEM -> Registry:DispatchRoll forward. The dispatcher
-- is exposed via the `_HandleGroup` / `_HandleSystem` test seams; the
-- DragonCore Listener / addon-track wiring is exercised only in the
-- live addon, not in busted.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

local function newRegistryStub()
    local stub = { calls = {}, games = {}, active = nil }
    function stub:Get(id) return self.games[id] end
    function stub:IsActive() return self.active ~= nil end
    function stub:Open(id, rest, sender)
        self.calls[#self.calls + 1] = { method = "Open", id = id, rest = rest, sender = sender }
        return true
    end
    function stub:DispatchJoin(sender)
        self.calls[#self.calls + 1] = { method = "DispatchJoin", sender = sender }
    end
    function stub:DispatchRoll(record)
        self.calls[#self.calls + 1] = { method = "DispatchRoll", record = record }
    end
    return stub
end

describe("Chat dispatcher", function()
    local Chat, ns, registry
    local previousUnitName

    before_each(function()
        previousUnitName = _G.UnitName
        _G.UnitName = function() return "Me" end

        ns = {}
        ns.GetShortName = function(name) return name end
        registry = newRegistryStub()
        ns.Registry = registry
        ns.RollParser = { Parse = function(line)
            if line == "Foo rolls 7 (1-100)" then
                return { player = "Foo", roll = 7, min = 1, max = 100 }
            end
            return nil
        end }
        -- Stub LibStub since Chat.lua references it at module load even
        -- though Init is never called here.
        _G.LibStub = function() return { Listener = { New = function() return {} end } } end
        Chat = loader.load("Modules/Chat.lua", ns)
    end)

    after_each(function()
        _G.UnitName = previousUnitName
        _G.LibStub = nil
    end)

    describe("!join", function()
        it("forwards to Registry:DispatchJoin(sender)", function()
            Chat._HandleGroup("!join", "Joiner")
            assert.equals(1, #registry.calls)
            assert.equals("DispatchJoin", registry.calls[1].method)
            assert.equals("Joiner", registry.calls[1].sender)
        end)

        it("tolerates whitespace and case variants", function()
            Chat._HandleGroup("  !JOIN  ", "X")
            assert.equals(1, #registry.calls)
            assert.equals("DispatchJoin", registry.calls[1].method)
        end)
    end)

    describe("CHAT_MSG_SYSTEM", function()
        it("forwards a parsed roll record to Registry:DispatchRoll", function()
            Chat._HandleSystem("Foo rolls 7 (1-100)")
            assert.equals(1, #registry.calls)
            assert.equals("DispatchRoll", registry.calls[1].method)
            assert.equals(7, registry.calls[1].record.roll)
        end)

        it("drops non-roll system messages silently", function()
            Chat._HandleSystem("some unrelated system line")
            assert.equals(0, #registry.calls)
        end)
    end)

    describe("!dc dispatch", function()
        it("opens a lobby on !dc <game> <args>", function()
            registry.games.deathroll = {}
            Chat._HandleGroup("!dc deathroll 100", "Me")
            assert.equals(1, #registry.calls)
            local call = registry.calls[1]
            assert.equals("Open", call.method)
            assert.equals("deathroll", call.id)
            assert.equals("100", call.rest)
            assert.equals("Me", call.sender)
        end)

        it("forwards from a remote sender when no game is active and parse succeeds", function()
            registry.games.deathroll = {
                ParseOpenArgs = function(rest) return { rest = rest } end,
            }
            Chat._HandleGroup("!dc deathroll 100", "RemoteHost")
            assert.equals(1, #registry.calls)
            assert.equals("RemoteHost", registry.calls[1].sender)
        end)

        it("drops a remote-sender open silently when a game is already active", function()
            registry.games.deathroll = {
                ParseOpenArgs = function(rest) return { rest = rest } end,
            }
            registry.active = true
            Chat._HandleGroup("!dc deathroll 100", "RemoteHost")
            assert.equals(0, #registry.calls)
        end)

        it("drops a remote-sender open silently when ParseOpenArgs fails", function()
            registry.games.deathroll = {
                ParseOpenArgs = function() return nil, "bad" end,
            }
            Chat._HandleGroup("!dc deathroll junk", "RemoteHost")
            assert.equals(0, #registry.calls)
        end)

        it("still calls Registry:Open for a local sender (refusal is host-local)", function()
            registry.games.deathroll = {
                ParseOpenArgs = function() return nil, "bad" end,
            }
            registry.active = true
            Chat._HandleGroup("!dc deathroll 100", "Me")
            -- Local sender: Registry is called and prints host-local diag itself.
            assert.equals(1, #registry.calls)
            assert.equals("Open", registry.calls[1].method)
        end)

        it("dispatches a ChatVerbs hit instead of opening", function()
            local seen
            local game = { ChatVerbs = { start = function(self, sender, tail)
                seen = { self = self, sender = sender, tail = tail }
            end } }
            registry.games.goldroll = game
            Chat._HandleGroup("!dc goldroll start", "Me")
            assert.is_not_nil(seen)
            assert.equals(game, seen.self)
            assert.equals("Me", seen.sender)
            assert.equals("", seen.tail)
            assert.equals(0, #registry.calls)
        end)

        it("falls through to ParseOpenArgs on a ChatVerbs miss", function()
            -- Deathroll declares no ChatVerbs; `!dc deathroll start` is
            -- treated as open-args ("start"), the parser fails, and the
            -- entire flow is silent for the remote sender.
            registry.games.deathroll = {
                ParseOpenArgs = function(rest)
                    if rest == "start" then return nil, "bad" end
                    return { rest = rest }
                end,
            }
            Chat._HandleGroup("!dc deathroll start", "RemoteSender")
            assert.equals(0, #registry.calls)
        end)

        it("falls through to Registry:Open on a verb-table miss for the local sender", function()
            registry.games.deathroll = {
                ParseOpenArgs = function(rest) return { rest = rest } end,
            }
            Chat._HandleGroup("!dc deathroll 250", "Me")
            assert.equals(1, #registry.calls)
            assert.equals("250", registry.calls[1].rest)
        end)

        it("drops !dc with no game token silently", function()
            registry.games.deathroll = {}
            Chat._HandleGroup("!dc", "Me")
            Chat._HandleGroup("  !dc   ", "Me")
            assert.equals(0, #registry.calls)
        end)

        it("drops !dc <game> with no further args silently", function()
            registry.games.deathroll = {}
            Chat._HandleGroup("!dc deathroll", "Me")
            assert.equals(0, #registry.calls)
        end)

        it("drops !dc <unknownGame> ... silently", function()
            Chat._HandleGroup("!dc notagame 100", "Me")
            assert.equals(0, #registry.calls)
        end)

        it("is case-insensitive on the game token", function()
            registry.games.deathroll = {}
            Chat._HandleGroup("!dc DEATHROLL 100", "Me")
            assert.equals(1, #registry.calls)
            assert.equals("deathroll", registry.calls[1].id)
        end)
    end)
end)
