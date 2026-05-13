-------------------------------------------------------------------------------
-- Game_spec.lua
-- DragonDice Game: host-identity contract plus the lobby join-timer
-- mechanics (scheduling, cancellation, re-entrancy guard, insufficient-
-- participants expiry). Broader game flow lives in in-game verification.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

-- Build a fake DragonCore.Schedule that records scheduled callbacks instead
-- of running them. Tests fire individual callbacks manually to exercise
-- timer-expiry, countdown, and re-entrancy paths without real time passing.
local function newFakeSchedule()
    local fake = { records = {} }
    function fake:After(delay, cb)
        local record = { delay = delay, cb = cb, cancelled = false }
        self.records[#self.records + 1] = record
        return {
            Cancel = function() record.cancelled = true end,
            _record = record,
        }
    end
    function fake:Reset() self.records = {} end
    return fake
end

describe("Game", function()
    local Game
    local ns
    local fakeSchedule
    local announceCalls
    local printLocalCalls
    local previousUnitName, previousAmbiguate, previousPrint

    before_each(function()
        previousUnitName = _G.UnitName
        previousAmbiguate = _G.Ambiguate
        previousPrint = _G.print
        _G.UnitName = function() return "LocalPlayer" end
        _G.Ambiguate = function(name) return name end
        _G.print = function() end

        announceCalls = {}
        printLocalCalls = {}
        fakeSchedule = newFakeSchedule()

        ns = {}
        loader.load("Modules/FSM.lua", ns)
        loader.load("Modules/Announce.lua", ns)
        -- Stub announce so the spec does not require SendChatMessage.
        ns.Announce = ns.Announce or {}
        ns.Announce.Send = function(text)
            announceCalls[#announceCalls + 1] = text
        end
        -- Stub Core.lua's short-name helper (Game aliases it at load time).
        ns.GetShortName = function(name)
            if type(name) ~= "string" or name == "" then return nil end
            local Ambiguate = _G.Ambiguate
            if Ambiguate then return Ambiguate(name, "short") end
            return name:match("^([^%-]+)") or name
        end
        -- Stub Core.lua's host-local sink and Schedule injection.
        ns.PrintLocal = function(text)
            printLocalCalls[#printLocalCalls + 1] = text
        end
        ns.Schedule = fakeSchedule

        Game = loader.load("Modules/Game.lua", ns)
        Game:Init({})
    end)

    after_each(function()
        _G.UnitName = previousUnitName
        _G.Ambiguate = previousAmbiguate
        _G.print = previousPrint
    end)

    -- ------------------------------------------------------------------
    -- Host-identity contract (pre-timer behaviour; unchanged)
    -- ------------------------------------------------------------------

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

    -- ------------------------------------------------------------------
    -- Lobby join-timer mechanics
    -- ------------------------------------------------------------------

    describe("join timer", function()
        local function countdownDelays(records)
            local delays = {}
            -- All but the last record (terminal at 15s) are countdowns.
            for i = 1, #records - 1 do delays[i] = records[i].delay end
            return delays
        end

        it("schedules nothing on Open (timer arms on first Join)", function()
            Game:Open(100, "Host")
            assert.equals(0, #fakeSchedule.records)
        end)

        it("schedules five countdowns plus a terminal transition on first Join", function()
            Game:Open(100, "Host")
            assert.is_true(Game:Join("Joiner"))
            assert.equals(6, #fakeSchedule.records)
            assert.same({ 5, 10, 12, 13, 14 }, countdownDelays(fakeSchedule.records))
            assert.equals(15, fakeSchedule.records[6].delay)
        end)

        it("cancels all six handles when Start succeeds", function()
            Game:Open(100, "Host")
            Game:Join("Joiner")
            assert.is_true(Game:Start())
            for i = 1, #fakeSchedule.records do
                assert.is_true(fakeSchedule.records[i].cancelled,
                    "record " .. i .. " should be cancelled")
            end
        end)

        it("schedules nothing and refuses Start when no opponent ever joins", function()
            Game:Open(100, "Host")
            assert.is_false(Game:Start())
            assert.equals(0, #fakeSchedule.records,
                "Open must not schedule; Join was never called")
            assert.equals("OPEN", Game:GetState())
        end)

        it("cancels all six handles and advances the lobby epoch on Cancel", function()
            Game:Open(100, "Host")
            Game:Join("Joiner")
            local epoch = Game._LobbyId()
            assert.is_true(Game:Cancel())
            for i = 1, #fakeSchedule.records do
                assert.is_true(fakeSchedule.records[i].cancelled)
            end
            assert.is_true(Game._LobbyId() > epoch)
        end)

        it("cancels all six handles on Reset", function()
            Game:Open(100, "Host")
            Game:Join("Joiner")
            Game:Reset()
            for i = 1, #fakeSchedule.records do
                assert.is_true(fakeSchedule.records[i].cancelled)
            end
            assert.equals("IDLE", Game:GetState())
        end)

        it("broadcasts the remaining-seconds string when a countdown fires", function()
            Game:Open(100, "Host")
            Game:Join("Joiner")
            announceCalls = {} -- discard the open + join announcements
            -- Fire the third countdown (at=12s, remaining=3).
            fakeSchedule.records[3].cb()
            assert.equals(1, #announceCalls)
            -- announce() formats the template even when L is unbound, so
            -- the resolved string carries the substituted seconds value.
            assert.equals("DragonDice: starting in 3s.", announceCalls[1])
        end)

        it("makes stale countdown callbacks inert across Cancel+Open+Join (re-entrancy)", function()
            Game:Open(100, "Host")
            Game:Join("Joiner")
            local staleCallback = fakeSchedule.records[1].cb
            Game:Cancel()
            Game:Open(200, "Host2")
            Game:Join("Joiner2")
            announceCalls = {} -- discard all prior announcements
            staleCallback() -- belongs to the cancelled lobby's countdown
            assert.equals(0, #announceCalls)
        end)

        -- --------------------------------------------------------------
        -- Terminal callback delegation
        -- --------------------------------------------------------------

        it("delegates to Start when the terminal fires (opponent always set in 1v1)", function()
            Game:Open(100, "Host")
            Game:Join("Joiner")
            announceCalls = {}
            -- Fire the terminal callback (records[6] at 15s).
            fakeSchedule.records[6].cb()
            assert.equals("ACTIVE", Game:GetState())
            -- Opening-turn broadcast goes through Announce.Send.
            assert.equals(1, #announceCalls)
        end)

        it("emits the existing 'need an opponent' notice on manual Start, not the expiry one", function()
            Game:Open(100, "Host")
            printLocalCalls = {}
            assert.is_false(Game:Start())
            assert.equals(1, #printLocalCalls)
            assert.equals("DragonDice: cannot start - need an opponent.",
                printLocalCalls[1])
        end)
    end)
end)
