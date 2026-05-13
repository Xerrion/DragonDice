-------------------------------------------------------------------------------
-- Game_spec.lua
-- DragonDice Game: confirms `Open(bet, hostName)` treats hostName as opaque
-- player-name data and exposes it through GetHost / state snapshot. The
-- broader game flow lives in in-game verification; this spec covers only
-- the host-identity contract that the !bet feature relies on.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

describe("Game", function()
    local Game
    local previousUnitName, previousAmbiguate, previousPrint

    before_each(function()
        previousUnitName = _G.UnitName
        previousAmbiguate = _G.Ambiguate
        previousPrint = _G.print
        _G.UnitName = function() return "LocalPlayer" end
        _G.Ambiguate = function(name) return name end
        _G.print = function() end

        local ns = {}
        loader.load("Modules/FSM.lua", ns)
        loader.load("Modules/Announce.lua", ns)
        -- Stub announce so the spec does not require SendChatMessage.
        ns.Announce = ns.Announce or {}
        ns.Announce.Send = function() end
        -- Stub Core.lua's short-name helper (Game aliases it at load time).
        ns.GetShortName = function(name)
            if type(name) ~= "string" or name == "" then return nil end
            local Ambiguate = _G.Ambiguate
            if Ambiguate then return Ambiguate(name, "short") end
            return name:match("^([^%-]+)") or name
        end
        Game = loader.load("Modules/Game.lua", ns)
        Game:Init({})
    end)

    after_each(function()
        _G.UnitName = previousUnitName
        _G.Ambiguate = previousAmbiguate
        _G.print = previousPrint
    end)

    it("opens with the supplied host name (local-player case)", function()
        assert.is_true(Game:Open(100, "LocalPlayer"))
        assert.equals("LocalPlayer", Game:GetHost())
        assert.equals("OPEN", Game:GetState())
    end)

    it("opens with an arbitrary remote host when hostName is provided", function()
        assert.is_true(Game:Open(250, "RemoteHost"))
        assert.equals("RemoteHost", Game:GetHost())
        assert.equals("OPEN", Game:GetState())
    end)

    it("rejects an omitted or empty hostName (no implicit local fallback)", function()
        assert.is_false(Game:Open(100))
        assert.is_false(Game:Open(100, ""))
        assert.is_false(Game:Open(100, 42))
        assert.is_nil(Game:GetHost())
        assert.equals("IDLE", Game:GetState())
    end)

    it("strips realm via Ambiguate on the host name", function()
        _G.Ambiguate = function(name, kind)
            assert.equals("short", kind)
            return name:match("^([^%-]+)") or name
        end
        assert.is_true(Game:Open(10, "Cross-Tichondrius"))
        assert.equals("Cross", Game:GetHost())
    end)

    it("rejects invalid bets regardless of host", function()
        assert.is_false(Game:Open(0, "RemoteHost"))
        assert.is_false(Game:Open(-5, "RemoteHost"))
        assert.is_false(Game:Open(1.5, "RemoteHost"))
        assert.is_false(Game:Open("100", "RemoteHost"))
        assert.is_nil(Game:GetHost())
    end)

    it("rejects host self-join when host is remote", function()
        Game:Open(100, "RemoteHost")
        assert.is_false(Game:Join("RemoteHost"))
    end)

    it("accepts a different player joining a remote-host game", function()
        Game:Open(100, "RemoteHost")
        assert.is_true(Game:Join("Joiner"))
    end)

    it("reports nil host when no game is in progress", function()
        assert.is_nil(Game:GetHost())
        assert.equals("IDLE", Game:GetState())
    end)
end)
