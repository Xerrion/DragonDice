-------------------------------------------------------------------------------
-- Deathroll_spec.lua
-- DragonDice deathroll: host-identity contract plus the lobby expiry-timer
-- mechanics (scheduling on Open, auto-start on Join, re-entrancy guard,
-- zero-joiner expiry), plus ParseOpenArgs coverage. Broader game flow
-- lives in in-game verification.
-------------------------------------------------------------------------------

package.path = package.path .. ";./spec/?.lua;./spec/support/?.lua"
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

describe("Deathroll", function()
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
        loader.load("DragonDice/Modules/FSM.lua", ns)
        loader.load("DragonDice/Modules/Announce.lua", ns)
        loader.load("DragonDice/Modules/Registry.lua", ns)
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
        loader.installCoreHelpers(ns)

        loader.load("DragonDice/Modules/Games/Deathroll.lua", ns)
        Game = ns.Games.deathroll
        Game:Init({})
    end)

    after_each(function()
        _G.UnitName = previousUnitName
        _G.Ambiguate = previousAmbiguate
        _G.print = previousPrint
    end)

    describe("ParseOpenArgs", function()
        it("parses a positive integer into { bet = N }", function()
            local args, err = Game.ParseOpenArgs("100")
            assert.is_nil(err)
            assert.same({ bet = 100 }, args)
        end)

        it("tolerates surrounding whitespace", function()
            local args = Game.ParseOpenArgs("   50   ")
            assert.same({ bet = 50 }, args)
        end)

        it("rejects zero, negative, fractional, and non-numeric input", function()
            for _, input in ipairs({ "0", "-5", "1.5", "foo", "10g", "" }) do
                local args, err = Game.ParseOpenArgs(input)
                assert.is_nil(args)
                assert.equals("DragonDice: amount must be a positive integer.", err)
            end
        end)

        it("rejects non-string input", function()
            local args, err = Game.ParseOpenArgs(nil)
            assert.is_nil(args)
            assert.is_string(err)
            args, err = Game.ParseOpenArgs(42)
            assert.is_nil(args)
            assert.is_string(err)
        end)
    end)

    it("opens with the supplied host name (local-player case)", function()
        assert.is_true(Game:Open({ bet = 100 }, "LocalPlayer"))
        assert.equals("LocalPlayer", Game:GetHost())
        assert.equals("OPEN", Game:GetState())
    end)

    it("opens with an arbitrary remote host when hostName is provided", function()
        assert.is_true(Game:Open({ bet = 250 }, "RemoteHost"))
        assert.equals("RemoteHost", Game:GetHost())
        assert.equals("OPEN", Game:GetState())
    end)

    it("rejects an omitted or empty hostName (no implicit local fallback)", function()
        assert.is_false(Game:Open({ bet = 100 }))
        assert.is_false(Game:Open({ bet = 100 }, ""))
        assert.is_false(Game:Open({ bet = 100 }, 42))
        assert.is_nil(Game:GetHost())
        assert.equals("IDLE", Game:GetState())
    end)

    it("strips realm via Ambiguate on the host name", function()
        _G.Ambiguate = function(name, kind)
            assert.equals("short", kind)
            return name:match("^([^%-]+)") or name
        end
        assert.is_true(Game:Open({ bet = 10 }, "Cross-Tichondrius"))
        assert.equals("Cross", Game:GetHost())
    end)

    it("rejects invalid bets regardless of host", function()
        assert.is_false(Game:Open({ bet = 0 }, "RemoteHost"))
        assert.is_false(Game:Open({ bet = -5 }, "RemoteHost"))
        assert.is_false(Game:Open({ bet = 1.5 }, "RemoteHost"))
        assert.is_false(Game:Open({ bet = "100" }, "RemoteHost"))
        assert.is_nil(Game:GetHost())
    end)

    it("rejects host self-join and leaves the lobby OPEN with timers intact", function()
        Game:Open({ bet = 100 }, "RemoteHost")
        local recordsBefore = #fakeSchedule.records
        local announcesBefore = #announceCalls
        assert.is_false(Game:Join("RemoteHost"))
        assert.equals("OPEN", Game:GetState())
        assert.is_nil(Game._State().opponent)
        -- No new schedule entries, no new announces.
        assert.equals(recordsBefore, #fakeSchedule.records)
        assert.equals(announcesBefore, #announceCalls)
        -- And no handle has been cancelled by the rejected join.
        for i = 1, #fakeSchedule.records do
            assert.is_false(fakeSchedule.records[i].cancelled,
                "record " .. i .. " must not be cancelled by a rejected self-join")
        end
    end)

    it("accepts a different player joining a remote-host game", function()
        Game:Open({ bet = 100 }, "RemoteHost")
        assert.is_true(Game:Join("Joiner"))
    end)

    it("reports nil host when no game is in progress", function()
        assert.is_nil(Game:GetHost())
        assert.equals("IDLE", Game:GetState())
    end)

    describe("lobby timer", function()
        local function countdownDelays(records)
            local delays = {}
            -- All but the last record (terminal at 15s) are countdowns.
            for i = 1, #records - 1 do delays[i] = records[i].delay end
            return delays
        end

        it("schedules five countdowns plus a terminal expiry on Open", function()
            Game:Open({ bet = 100 }, "Host")
            assert.equals(6, #fakeSchedule.records)
            assert.same({ 5, 10, 12, 13, 14 }, countdownDelays(fakeSchedule.records))
            assert.equals(15, fakeSchedule.records[6].delay)
        end)

        it("auto-starts the moment an opponent joins and cancels every handle", function()
            Game:Open({ bet = 100 }, "Host")
            assert.equals("OPEN", Game:GetState())
            local openAnnounceCount = #announceCalls
            assert.is_true(Game:Join("Joiner"))
            assert.equals("ACTIVE", Game:GetState())
            -- Exactly one auto-start announce on top of the open announce.
            assert.equals(openAnnounceCount + 1, #announceCalls)
            assert.equals(
                "DragonDice: Host vs Joiner for 100g. Host rolls first: /roll 1000",
                announceCalls[#announceCalls])
            -- All six handles cancelled (countdown silenced).
            for i = 1, #fakeSchedule.records do
                assert.is_true(fakeSchedule.records[i].cancelled,
                    "record " .. i .. " should be cancelled on auto-start")
            end
        end)

        it("silently rejects a second joiner; opponent and state unchanged", function()
            Game:Open({ bet = 100 }, "Host")
            assert.is_true(Game:Join("Joiner"))
            local stateAfterJoin = Game:GetState()
            local opponentAfterJoin = Game._State().opponent
            local announcesAfterJoin = #announceCalls
            assert.is_false(Game:Join("Third"))
            assert.equals(stateAfterJoin, Game:GetState())
            assert.equals(opponentAfterJoin, Game._State().opponent)
            assert.equals("Joiner", Game._State().opponent)
            assert.equals(announcesAfterJoin, #announceCalls)
        end)

        it("cancels all six handles and advances the lobby epoch on Cancel", function()
            Game:Open({ bet = 100 }, "Host")
            local epoch = Game._LobbyId()
            assert.is_true(Game:Cancel())
            for i = 1, #fakeSchedule.records do
                assert.is_true(fakeSchedule.records[i].cancelled)
            end
            assert.is_true(Game._LobbyId() > epoch)
        end)

        it("cancels all six handles on Reset", function()
            Game:Open({ bet = 100 }, "Host")
            Game:Reset()
            for i = 1, #fakeSchedule.records do
                assert.is_true(fakeSchedule.records[i].cancelled)
            end
            assert.equals("IDLE", Game:GetState())
        end)

        it("broadcasts the remaining-seconds string when a countdown fires", function()
            Game:Open({ bet = 100 }, "Host")
            announceCalls = {} -- discard the open announcement
            -- Fire the third countdown (at=12s, remaining=3).
            fakeSchedule.records[3].cb()
            assert.equals(1, #announceCalls)
            assert.equals("DragonDice: lobby expires in 3s.", announceCalls[1])
        end)

        it("makes stale countdown callbacks inert across Cancel+Open (re-entrancy)", function()
            Game:Open({ bet = 100 }, "Host")
            local staleCallback = fakeSchedule.records[1].cb
            Game:Cancel()
            Game:Open({ bet = 200 }, "Host2")
            announceCalls = {} -- discard all prior announcements
            staleCallback() -- belongs to the cancelled lobby's countdown
            assert.equals(0, #announceCalls)
        end)

        it("cancels the lobby back to IDLE when the terminal expiry fires with no joiner", function()
            Game:Open({ bet = 100 }, "Host")
            announceCalls = {}
            printLocalCalls = {}
            -- Fire the terminal callback (records[6] at 15s) WITHOUT any Join.
            fakeSchedule.records[6].cb()
            assert.equals("IDLE", Game:GetState())
            assert.is_nil(Game:GetHost())
            assert.is_nil(Game._timerHandle)
            -- Exactly one host-local expiry notice, no broadcast.
            assert.equals(0, #announceCalls)
            assert.equals(1, #printLocalCalls)
            assert.equals("DragonDice: no one accepted - lobby expired.",
                printLocalCalls[1])
            -- Lobby is fully reset: a fresh Open succeeds and re-arms the
            -- timer, with no residual handles or stale state leaking in.
            assert.is_true(Game:Open({ bet = 50 }, "NextHost"))
            assert.equals("OPEN", Game:GetState())
            assert.equals("NextHost", Game:GetHost())
        end)

        it("emits the 'need an opponent' notice when Start is called directly without one", function()
            -- Game:Start remains public as the FSM-transition test seam.
            -- The production path reaches it only via Game:Join (which
            -- sets the opponent first). Direct invocation without one
            -- must refuse.
            Game:Open({ bet = 100 }, "Host")
            printLocalCalls = {}
            assert.is_false(Game:Start())
            assert.equals(1, #printLocalCalls)
            assert.equals("DragonDice: cannot start - need an opponent.",
                printLocalCalls[1])
        end)
    end)
end)
