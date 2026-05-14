-------------------------------------------------------------------------------
-- Slash_spec.lua
-- DragonDice Slash: the `/dc` dispatcher. The router itself is parse-and-
-- forward; this spec stubs `ns.Registry` and verifies which Registry call
-- (and with what arguments) every grammar shape resolves to.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

-- Build a Registry stub that records every call. Each call is a flat
-- table so the spec can assert on the method name and the captured args.
local function newRegistryStub()
    local stub = { calls = {}, games = {}, list = {} }
    function stub:Register(_) end
    function stub:Get(id) return self.games[id] end
    function stub:List() return self.list end
    function stub:Open(id, rest, host)
        self.calls[#self.calls + 1] = { method = "Open", id = id, rest = rest, host = host }
        return true
    end
    function stub:Status() self.calls[#self.calls + 1] = { method = "Status" } end
    function stub:Cancel(name) self.calls[#self.calls + 1] = { method = "Cancel", name = name } end
    function stub:Reset(name) self.calls[#self.calls + 1] = { method = "Reset", name = name } end
    function stub:Start(name) self.calls[#self.calls + 1] = { method = "Start", name = name } end
    return stub
end

describe("Slash dispatcher", function()
    local Slash, ns, registry
    local prints
    local previousUnitName, previousPrint

    before_each(function()
        previousUnitName = _G.UnitName
        previousPrint = _G.print
        _G.UnitName = function() return "Me" end
        prints = {}
        _G.print = function(text) prints[#prints + 1] = text end

        ns = {}
        ns.GetShortName = function(name) return name end
        registry = newRegistryStub()
        ns.Registry = registry
        Slash = loader.load("Modules/Slash.lua", ns)
    end)

    after_each(function()
        _G.UnitName = previousUnitName
        _G.print = previousPrint
    end)

    it("prints help on bare /dc", function()
        Slash._Handle("")
        assert.is_true(#prints >= 1)
        assert.matches("usage: /dc", prints[1])
    end)

    it("prints help on /dc help", function()
        Slash._Handle("help")
        assert.matches("usage: /dc", prints[1])
    end)

    it("routes /dc status to Registry:Status", function()
        Slash._Handle("status")
        assert.equals(1, #registry.calls)
        assert.equals("Status", registry.calls[1].method)
    end)

    it("routes /dc cancel to Registry:Cancel with local player name", function()
        Slash._Handle("cancel")
        assert.equals("Cancel", registry.calls[1].method)
        assert.equals("Me", registry.calls[1].name)
    end)

    it("routes /dc reset to Registry:Reset with local player name", function()
        Slash._Handle("reset")
        assert.equals("Reset", registry.calls[1].method)
        assert.equals("Me", registry.calls[1].name)
    end)

    it("routes /dc start to Registry:Start with local player name", function()
        Slash._Handle("start")
        assert.equals("Start", registry.calls[1].method)
        assert.equals("Me", registry.calls[1].name)
    end)

    it("routes /dc <game> open <args> to Registry:Open(game, args, hostName)", function()
        registry.games.deathroll = { SlashVerbs = nil }
        Slash._Handle("deathroll open 100")
        assert.equals(1, #registry.calls)
        local call = registry.calls[1]
        assert.equals("Open", call.method)
        assert.equals("deathroll", call.id)
        assert.equals("100", call.rest)
        assert.equals("Me", call.host)
    end)

    it("rejects /dc <unknownGame> with a host-local notice", function()
        registry.games.deathroll = {}
        Slash._Handle("notagame open 100")
        assert.equals(0, #registry.calls)
        assert.matches("unknown command 'notagame'", prints[1])
    end)

    it("dispatches /dc <game> <verb> to game.SlashVerbs[verb]", function()
        local seen
        local game = { SlashVerbs = {
            start = function(self, rest, name)
                seen = { self = self, rest = rest, name = name }
            end,
        } }
        registry.games.goldroll = game
        Slash._Handle("goldroll start")
        assert.is_not_nil(seen)
        assert.equals(game, seen.self)
        assert.equals("", seen.rest)
        assert.equals("Me", seen.name)
    end)

    it("rejects /dc <game> <unknownVerb> with a host-local notice", function()
        registry.games.deathroll = { SlashVerbs = {} }
        Slash._Handle("deathroll bogus")
        assert.equals(0, #registry.calls)
        assert.matches("unknown verb", prints[1])
    end)

    it("prints a usage hint when /dc <game> has no subverb", function()
        registry.games.deathroll = {}
        Slash._Handle("deathroll")
        assert.equals(0, #registry.calls)
        assert.matches("usage: /dc deathroll open", prints[1])
    end)

    it("registers /dc and /dragondice globals on Init", function()
        local slashCmdList = {}
        _G.SlashCmdList = slashCmdList
        Slash:Init({})
        assert.equals("/dc", _G.SLASH_DRAGONDICE1)
        assert.equals("/dragondice", _G.SLASH_DRAGONDICE2)
        assert.is_function(slashCmdList["DRAGONDICE"])
    end)
end)
