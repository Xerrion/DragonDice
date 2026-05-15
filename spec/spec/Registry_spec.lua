-------------------------------------------------------------------------------
-- Registry_spec.lua
-- DragonDice Registry: the contract validator, the active-game derivation,
-- the refusal-when-active gate, the host-permission gate (lifted from
-- Slash), and the Open/Dispatch/Status routing surface.
-------------------------------------------------------------------------------

package.path = package.path .. ";./spec/?.lua;./spec/support/?.lua"
local loader = require("support.loader")

-- Minimal contract-conforming stub. State lives on the table itself so
-- specs can flip it directly to exercise GetActive / IsActive paths.
local function newStub(opts)
    opts = opts or {}
    local stub = {
        id = opts.id or "stubgame",
        displayName = opts.displayName or "StubGame",
        localePrefix = opts.id or "stubgame",
        _state = opts.state or "IDLE",
        _host = opts.host or nil,
        calls = {},
    }
    function stub:GetState() return self._state end
    function stub:GetHost() return self._host end
    function stub.ParseOpenArgs(rest)
        if opts.parseFails then return nil, "stub: parse failed" end
        return { rest = rest }, nil
    end
    function stub:Open(args, host)
        self.calls[#self.calls + 1] = { method = "Open", args = args, host = host }
        self._state = "OPEN"
        self._host = host
        return true
    end
    function stub:Join(player)
        self.calls[#self.calls + 1] = { method = "Join", player = player }
        return true
    end
    function stub:OnRoll(record)
        self.calls[#self.calls + 1] = { method = "OnRoll", record = record }
        return true
    end
    function stub:Cancel()
        self.calls[#self.calls + 1] = { method = "Cancel" }
        self._state = "IDLE"
        self._host = nil
        return true
    end
    function stub:Reset()
        self.calls[#self.calls + 1] = { method = "Reset" }
        self._state = "IDLE"
        self._host = nil
    end
    function stub:Status()
        self.calls[#self.calls + 1] = { method = "Status" }
    end
    return stub
end

describe("Registry", function()
    local Registry, ns
    local prints

    before_each(function()
        prints = {}
        ns = {}
        ns.L = setmetatable({}, { __index = function(_, k) return k end })
        ns.PrintLocal = function(text) prints[#prints + 1] = text end
        loader.installCoreHelpers(ns)
        Registry = loader.load("DragonDice/Modules/Registry.lua", ns)
    end)

    describe("CanPlayerAct", function()
        it("returns false when both names are nil", function()
            assert.is_false(Registry.CanPlayerAct(nil, nil))
        end)
        it("returns true when both names match exactly", function()
            assert.is_true(Registry.CanPlayerAct("Hostname", "Hostname"))
        end)
        it("returns false when names differ", function()
            assert.is_false(Registry.CanPlayerAct("Joiner", "Hostname"))
        end)
        it("is case-sensitive", function()
            assert.is_false(Registry.CanPlayerAct("hostname", "Hostname"))
        end)
        it("returns false when either name is empty", function()
            assert.is_false(Registry.CanPlayerAct("", "Hostname"))
            assert.is_false(Registry.CanPlayerAct("Hostname", ""))
            assert.is_false(Registry.CanPlayerAct("", ""))
        end)
    end)

    describe("Register", function()
        it("registers a contract-conforming game", function()
            local game = newStub({ id = "alpha" })
            Registry:Register(game)
            assert.equals(game, Registry:Get("alpha"))
            assert.same({ "alpha" }, Registry:List())
        end)

        it("raises when a required key is missing", function()
            local game = newStub()
            game.Open = nil
            assert.has_error(function() Registry:Register(game) end)
        end)

        it("raises when called with a non-table", function()
            assert.has_error(function() Registry:Register(nil) end)
            assert.has_error(function() Registry:Register(42) end)
        end)

        it("populates ns.Games[id] alongside the internal map", function()
            local game = newStub({ id = "alpha" })
            Registry:Register(game)
            assert.equals(game, ns.Games.alpha)
        end)
    end)

    describe("GetActive / IsActive", function()
        it("returns nil when every game is IDLE", function()
            Registry:Register(newStub({ id = "a", state = "IDLE" }))
            Registry:Register(newStub({ id = "b", state = "IDLE" }))
            assert.is_nil(Registry:GetActive())
            assert.is_false(Registry:IsActive())
        end)

        it("returns the non-IDLE game when one is active", function()
            Registry:Register(newStub({ id = "a", state = "IDLE" }))
            local active = newStub({ id = "b", state = "OPEN" })
            Registry:Register(active)
            assert.equals(active, Registry:GetActive())
            assert.is_true(Registry:IsActive())
        end)
    end)

    describe("Open routing", function()
        it("delegates to game.ParseOpenArgs and game:Open", function()
            local game = newStub({ id = "alpha" })
            Registry:Register(game)
            assert.is_true(Registry:Open("alpha", "rest-tail", "HostName"))
            assert.equals(1, #game.calls)
            assert.equals("Open", game.calls[1].method)
            assert.equals("HostName", game.calls[1].host)
            assert.same({ rest = "rest-tail" }, game.calls[1].args)
        end)

        it("refuses when another game is active", function()
            local active = newStub({ id = "a", displayName = "Alpha", state = "OPEN" })
            Registry:Register(active)
            Registry:Register(newStub({ id = "b" }))
            local ok = Registry:Open("b", "100", "HostName")
            assert.is_false(ok)
            assert.equals(1, #prints)
            assert.matches("Alpha", prints[1])
        end)

        it("refuses for an unknown game id", function()
            Registry:Register(newStub({ id = "alpha" }))
            local ok = Registry:Open("notagame", "100", "HostName")
            assert.is_false(ok)
            assert.equals(1, #prints)
            assert.matches("unknown game 'notagame'", prints[1])
        end)

        it("surfaces ParseOpenArgs's err string when args is nil", function()
            Registry:Register(newStub({ id = "alpha", parseFails = true }))
            local ok = Registry:Open("alpha", "junk", "HostName")
            assert.is_false(ok)
            assert.equals(1, #prints)
            assert.equals("stub: parse failed", prints[1])
        end)
    end)

    describe("DispatchRoll / DispatchJoin", function()
        it("forwards rolls only when a game is active", function()
            local game = newStub({ id = "a", state = "ACTIVE" })
            Registry:Register(game)
            Registry:DispatchRoll({ player = "x", roll = 5, min = 1, max = 10 })
            assert.equals(1, #game.calls)
            assert.equals("OnRoll", game.calls[1].method)
        end)

        it("drops rolls when no game is active", function()
            local game = newStub({ id = "a", state = "IDLE" })
            Registry:Register(game)
            Registry:DispatchRoll({ player = "x", roll = 5, min = 1, max = 10 })
            assert.equals(0, #game.calls)
        end)

        it("forwards joins to the active game", function()
            local game = newStub({ id = "a", state = "OPEN" })
            Registry:Register(game)
            Registry:DispatchJoin("Joiner")
            assert.equals(1, #game.calls)
            assert.equals("Joiner", game.calls[1].player)
        end)
    end)

    describe("Cancel / Reset host-permission gate", function()
        it("allows the host to cancel an active game", function()
            local game = newStub({ id = "a", state = "OPEN", host = "Host" })
            Registry:Register(game)
            assert.is_true(Registry:Cancel("Host"))
            assert.equals("Cancel", game.calls[1].method)
        end)

        it("refuses cancel from a non-host", function()
            local game = newStub({ id = "a", state = "OPEN", host = "Host" })
            Registry:Register(game)
            assert.is_false(Registry:Cancel("NotHost"))
            assert.equals(0, #game.calls)
            assert.matches("only the host", prints[1])
        end)

        it("emits 'no game in progress' when cancel hits no active game", function()
            Registry:Register(newStub({ id = "a", state = "IDLE" }))
            assert.is_false(Registry:Cancel("Anyone"))
            assert.matches("no game in progress", prints[1])
        end)
    end)

    describe("Start global verb", function()
        it("prints 'no game in progress' when nothing is active", function()
            Registry:Register(newStub({ id = "a", state = "IDLE" }))
            Registry:Start("Anyone")
            assert.matches("no game in progress", prints[1])
        end)

        it("prints 'nothing to start' when the active game has no SlashVerbs.start", function()
            Registry:Register(newStub({ id = "a", state = "OPEN", host = "Host" }))
            Registry:Start("Host")
            assert.matches("nothing to start", prints[1])
        end)

        it("invokes SlashVerbs.start on the active game when declared", function()
            local game = newStub({ id = "g", state = "OPEN", host = "Host" })
            local invoked = false
            game.SlashVerbs = { start = function(self, _, who)
                assert.equals(game, self)
                assert.equals("Host", who)
                invoked = true
            end }
            Registry:Register(game)
            Registry:Start("Host")
            assert.is_true(invoked)
        end)
    end)
end)
