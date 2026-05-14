-------------------------------------------------------------------------------
-- Goldroll_spec.lua
-- DragonDice gold roll: dual-mode lobby timer (quorum-wait vs
-- start-countdown), three-entry host-override start, roll handling,
-- tie-break re-entry, and cancel/reset paths.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

-- Same fake-Schedule shape Deathroll_spec uses: records every After()
-- call so tests fire callbacks manually instead of waiting on real time.
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

describe("Goldroll", function()
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
        _G.UnitName = function() return "Host" end
        _G.Ambiguate = function(name) return name end
        _G.print = function() end

        announceCalls = {}
        printLocalCalls = {}
        fakeSchedule = newFakeSchedule()

        ns = {}
        loader.load("Modules/FSM.lua", ns)
        loader.load("Modules/Announce.lua", ns)
        loader.load("Modules/Registry.lua", ns)
        ns.Announce = ns.Announce or {}
        ns.Announce.Send = function(text)
            announceCalls[#announceCalls + 1] = text
        end
        ns.GetShortName = function(name)
            if type(name) ~= "string" or name == "" then return nil end
            local Ambiguate = _G.Ambiguate
            if Ambiguate then return Ambiguate(name, "short") end
            return name:match("^([^%-]+)") or name
        end
        ns.PrintLocal = function(text)
            printLocalCalls[#printLocalCalls + 1] = text
        end
        ns.Schedule = fakeSchedule
        loader.installCoreHelpers(ns)

        loader.load("Modules/Games/Goldroll.lua", ns)
        Game = ns.Games.goldroll
        Game:Init({})
    end)

    after_each(function()
        _G.UnitName = previousUnitName
        _G.Ambiguate = previousAmbiguate
        _G.print = previousPrint
    end)

    -- Test helper: open a lobby and join `count` distinct players. Pads
    -- with synthetic names ("J1", "J2", ...) when count exceeds the
    -- supplied list. Returns the joined names in order.
    local function openAndJoin(host, wager, joiners)
        Game:Open({ wager = wager }, host)
        local names = {}
        for i = 1, #joiners do
            names[i] = joiners[i]
            Game:Join(joiners[i])
        end
        return names
    end

    describe("ParseOpenArgs", function()
        it("parses a positive integer into { wager = N }", function()
            local args, err = Game.ParseOpenArgs("500")
            assert.is_nil(err)
            assert.same({ wager = 500 }, args)
        end)

        it("tolerates surrounding whitespace", function()
            local args = Game.ParseOpenArgs("   100   ")
            assert.same({ wager = 100 }, args)
        end)

        it("rejects zero, negative, fractional, non-numeric, and empty input", function()
            for _, input in ipairs({ "0", "-5", "1.5", "foo", "10g", "" }) do
                local args, err = Game.ParseOpenArgs(input)
                assert.is_nil(args)
                assert.equals("DragonDice: wager must be a positive integer.", err)
            end
        end)

        it("rejects non-string input", function()
            local args, err = Game.ParseOpenArgs(nil)
            assert.is_nil(args)
            assert.is_string(err)
        end)
    end)

    describe("Open", function()
        it("transitions to OPEN, records wager and host, arms quorum-wait", function()
            assert.is_true(Game:Open({ wager = 500 }, "Host"))
            assert.equals("OPEN", Game:GetState())
            assert.equals("Host", Game:GetHost())
            local snap = Game._State()
            assert.equals(500, snap.wager)
            assert.equals("QUORUM_WAIT", snap.timerMode)
            -- One schedule record: the quorum-wait terminal at 60s. No
            -- countdown ticks while in QUORUM_WAIT mode.
            assert.equals(1, #fakeSchedule.records)
            assert.equals(60, fakeSchedule.records[1].delay)
        end)

        it("rejects an invalid wager", function()
            assert.is_false(Game:Open({ wager = 0 }, "Host"))
            assert.is_false(Game:Open({ wager = -1 }, "Host"))
            assert.is_false(Game:Open({ wager = 1.5 }, "Host"))
            assert.is_false(Game:Open({ wager = "500" }, "Host"))
            assert.equals("IDLE", Game:GetState())
        end)

        it("rejects an omitted hostName", function()
            assert.is_false(Game:Open({ wager = 100 }))
            assert.is_false(Game:Open({ wager = 100 }, ""))
            assert.equals("IDLE", Game:GetState())
        end)
    end)

    describe("Join", function()
        it("accumulates participants", function()
            Game:Open({ wager = 100 }, "Host")
            assert.is_true(Game:Join("A"))
            assert.is_true(Game:Join("B"))
            assert.equals(2, Game._State().participantCount)
            assert.same({ "A", "B" }, Game._State().participants)
        end)

        it("is idempotent on duplicate names", function()
            Game:Open({ wager = 100 }, "Host")
            assert.is_true(Game:Join("A"))
            assert.is_false(Game:Join("A"))
            assert.equals(1, Game._State().participantCount)
        end)

        it("allows host self-join", function()
            Game:Open({ wager = 100 }, "Host")
            assert.is_true(Game:Join("Host"))
            assert.equals(1, Game._State().participantCount)
        end)

        it("is rejected outside OPEN", function()
            assert.is_false(Game:Join("A"))
        end)
    end)

    describe("Quorum and countdown lifecycle", function()
        it("first join below quorum leaves timerMode as QUORUM_WAIT", function()
            Game:Open({ wager = 100 }, "Host")
            local recordsBefore = #fakeSchedule.records
            Game:Join("A")
            assert.equals("QUORUM_WAIT", Game._State().timerMode)
            -- No new schedule records.
            assert.equals(recordsBefore, #fakeSchedule.records)
        end)

        it("second join cancels quorum-wait, arms start countdown, advances epoch", function()
            Game:Open({ wager = 100 }, "Host")
            local quorumWaitRecord = fakeSchedule.records[1]
            local epoch = Game._LobbyId()
            Game:Join("A")
            Game:Join("B")
            assert.equals("START_COUNTDOWN", Game._State().timerMode)
            assert.is_true(quorumWaitRecord.cancelled)
            assert.equals(epoch + 1, Game._LobbyId())
            -- Six new records: five tick callbacks at 5/10/12/13/14 plus
            -- the terminal at 15.
            assert.equals(7, #fakeSchedule.records)
            assert.equals(5,  fakeSchedule.records[2].delay)
            assert.equals(10, fakeSchedule.records[3].delay)
            assert.equals(12, fakeSchedule.records[4].delay)
            assert.equals(13, fakeSchedule.records[5].delay)
            assert.equals(14, fakeSchedule.records[6].delay)
            assert.equals(15, fakeSchedule.records[7].delay)
        end)

        it("third join during start-countdown does NOT reset countdown", function()
            openAndJoin("Host", 100, { "A", "B" })
            local recordsBefore = #fakeSchedule.records
            local epoch = Game._LobbyId()
            -- Capture cancellation state of every existing record.
            local cancelledBefore = {}
            for i = 1, recordsBefore do
                cancelledBefore[i] = fakeSchedule.records[i].cancelled
            end
            Game:Join("C")
            assert.equals(epoch, Game._LobbyId())
            assert.equals(recordsBefore, #fakeSchedule.records)
            for i = 1, recordsBefore do
                assert.equals(cancelledBefore[i], fakeSchedule.records[i].cancelled,
                    "record " .. i .. " cancellation must be unchanged by post-quorum join")
            end
            assert.equals(3, Game._State().participantCount)
        end)

        it("start-countdown expiry transitions to ROLLING and cancels ticks", function()
            openAndJoin("Host", 100, { "A", "B" })
            announceCalls = {}
            -- records[7] is the terminal start-countdown callback.
            fakeSchedule.records[7].cb()
            assert.equals("ROLLING", Game:GetState())
            assert.equals(1, #announceCalls)
            assert.equals("DragonDice: gold roll begins. All 2 players: /roll 100",
                announceCalls[1])
            -- All five tick handles cancelled.
            for i = 2, 6 do
                assert.is_true(fakeSchedule.records[i].cancelled,
                    "tick handle " .. i .. " should be cancelled on begin")
            end
        end)

        it("countdown tick announces the remaining-seconds string", function()
            openAndJoin("Host", 100, { "A", "B" })
            announceCalls = {}
            -- records[4] is the third tick (at=12s, remaining=3).
            fakeSchedule.records[4].cb()
            assert.equals(1, #announceCalls)
            assert.equals("DragonDice: gold roll starts in 3s.", announceCalls[1])
        end)

        it("quorum-wait expiry with <2 joiners cancels lobby silently", function()
            Game:Open({ wager = 100 }, "Host")
            -- Drop the open announce so we can assert on what fires next.
            announceCalls = {}
            printLocalCalls = {}
            fakeSchedule.records[1].cb()
            assert.equals("IDLE", Game:GetState())
            assert.is_nil(Game:GetHost())
            assert.equals(0, #announceCalls)
            assert.equals(1, #printLocalCalls)
            assert.equals("DragonDice: gold roll - no quorum, lobby expired.",
                printLocalCalls[1])
        end)

        it("stale countdown callbacks are inert across cancel+open", function()
            openAndJoin("Host", 100, { "A", "B" })
            local staleTick = fakeSchedule.records[2].cb
            Game:Cancel()
            Game:Open({ wager = 200 }, "Host2")
            announceCalls = {}
            staleTick()
            assert.equals(0, #announceCalls)
        end)
    end)

    describe("Host short-circuit start (three entry points)", function()
        it("ChatVerbs.start from host with quorum begins rolling", function()
            openAndJoin("Host", 100, { "A", "B" })
            announceCalls = {}
            Game.ChatVerbs.start(Game, "Host", "")
            assert.equals("ROLLING", Game:GetState())
            -- Two announces: "started early" + "begins".
            assert.equals(2, #announceCalls)
            assert.equals("DragonDice: Host started the gold roll early.", announceCalls[1])
            -- All six countdown handles cancelled.
            for i = 2, 7 do
                assert.is_true(fakeSchedule.records[i].cancelled)
            end
        end)

        it("SlashVerbs.start from host with quorum begins rolling", function()
            openAndJoin("Host", 100, { "A", "B" })
            announceCalls = {}
            Game.SlashVerbs.start(Game, "", "Host")
            assert.equals("ROLLING", Game:GetState())
            assert.equals("DragonDice: Host started the gold roll early.", announceCalls[1])
        end)

        it("pre-quorum start prints host-local refusal and does not transition", function()
            Game:Open({ wager = 100 }, "Host")
            Game:Join("A")
            announceCalls = {}
            printLocalCalls = {}
            local ok = Game:_StartFromVerb("Host")
            assert.is_false(ok)
            assert.equals("OPEN", Game:GetState())
            assert.equals(0, #announceCalls)
            assert.equals(1, #printLocalCalls)
            assert.equals("DragonDice: gold roll needs at least 2 players to start.",
                printLocalCalls[1])
        end)

        it("non-host sender is silently dropped", function()
            openAndJoin("Host", 100, { "A", "B" })
            announceCalls = {}
            printLocalCalls = {}
            local ok = Game.ChatVerbs.start(Game, "NotHost", "")
            assert.is_false(ok)
            assert.equals("OPEN", Game:GetState())
            assert.equals(0, #announceCalls)
            assert.equals(0, #printLocalCalls)
        end)

        it("invocation outside OPEN is silently dropped", function()
            openAndJoin("Host", 100, { "A", "B" })
            fakeSchedule.records[7].cb() -- begin
            announceCalls = {}
            printLocalCalls = {}
            local ok = Game:_StartFromVerb("Host")
            assert.is_false(ok)
            assert.equals("ROLLING", Game:GetState())
            assert.equals(0, #announceCalls)
            assert.equals(0, #printLocalCalls)
        end)
    end)

    describe("OnRoll", function()
        local function startRolling(host, wager, joiners)
            openAndJoin(host, wager, joiners)
            Game:_StartFromVerb(host)
        end

        it("records valid rolls and announces progress", function()
            startRolling("Host", 100, { "A", "B" })
            announceCalls = {}
            assert.is_true(Game:OnRoll({ player = "A", roll = 73, min = 1, max = 100 }))
            assert.equals("DragonDice: A rolled 73 (1/2 players done).", announceCalls[1])
            assert.equals(73, Game._State().rolls.A)
        end)

        it("rejects out-of-range with host-local warn; no state change", function()
            startRolling("Host", 100, { "A", "B" })
            printLocalCalls = {}
            assert.is_false(Game:OnRoll({ player = "A", roll = 30, min = 1, max = 50 }))
            assert.equals(1, #printLocalCalls)
            assert.is_nil(Game._State().rolls.A)
        end)

        it("rejects non-participant with host-local warn", function()
            startRolling("Host", 100, { "A", "B" })
            printLocalCalls = {}
            assert.is_false(Game:OnRoll({ player = "Stranger", roll = 50, min = 1, max = 100 }))
            assert.equals(1, #printLocalCalls)
            assert.equals("DragonDice: ignored roll from Stranger (not a participant).",
                printLocalCalls[1])
        end)

        it("rejects a double roll with host-local warn", function()
            startRolling("Host", 100, { "A", "B" })
            Game:OnRoll({ player = "A", roll = 50, min = 1, max = 100 })
            printLocalCalls = {}
            assert.is_false(Game:OnRoll({ player = "A", roll = 90, min = 1, max = 100 }))
            assert.equals(1, #printLocalCalls)
            assert.equals("DragonDice: A already rolled this round - roll discarded.",
                printLocalCalls[1])
            assert.equals(50, Game._State().rolls.A)
        end)

        it("transitions to FINISHED on a clean result", function()
            startRolling("Host", 100, { "A", "B" })
            Game:OnRoll({ player = "A", roll = 80, min = 1, max = 100 })
            announceCalls = {}
            Game:OnRoll({ player = "B", roll = 20, min = 1, max = 100 })
            assert.equals("FINISHED", Game:GetState())
            -- Last announce is the result line.
            local last = announceCalls[#announceCalls]
            assert.equals("DragonDice: gold roll result: A rolled 80, B rolled 20. B owes A 60g.",
                last)
        end)
    end)

    describe("Tie-break", function()
        it("re-enters ROLLING with the tied subset on a high-end tie", function()
            openAndJoin("Host", 100, { "A", "B", "C" })
            Game:_StartFromVerb("Host")
            Game:OnRoll({ player = "A", roll = 90, min = 1, max = 100 })
            Game:OnRoll({ player = "B", roll = 90, min = 1, max = 100 })
            announceCalls = {}
            Game:OnRoll({ player = "C", roll = 10, min = 1, max = 100 })
            -- Tie path: announce tie, transition back to ROLLING with
            -- A and B (C is single low, not in the tied set).
            assert.equals("ROLLING", Game:GetState())
            assert.same({ "A", "B" }, Game._State().participants)
            assert.equals(0, Game._State().rollCount)
            assert.equals(2, Game._State().roundNumber)
            assert.equals(
                "DragonDice: tied on the high end among A, B. Tied players re-roll: /roll 100.",
                announceCalls[#announceCalls])
        end)

        it("re-enters ROLLING with the tied subset on a low-end tie", function()
            openAndJoin("Host", 100, { "A", "B", "C" })
            Game:_StartFromVerb("Host")
            Game:OnRoll({ player = "A", roll = 90, min = 1, max = 100 })
            Game:OnRoll({ player = "B", roll = 10, min = 1, max = 100 })
            announceCalls = {}
            Game:OnRoll({ player = "C", roll = 10, min = 1, max = 100 })
            assert.equals("ROLLING", Game:GetState())
            assert.same({ "B", "C" }, Game._State().participants)
            assert.matches("tied on the low end among B, C", announceCalls[#announceCalls])
        end)

        it("unions both ends when high and low both tie", function()
            openAndJoin("Host", 100, { "A", "B", "C", "D" })
            Game:_StartFromVerb("Host")
            Game:OnRoll({ player = "A", roll = 90, min = 1, max = 100 })
            Game:OnRoll({ player = "B", roll = 90, min = 1, max = 100 })
            Game:OnRoll({ player = "C", roll = 10, min = 1, max = 100 })
            announceCalls = {}
            Game:OnRoll({ player = "D", roll = 10, min = 1, max = 100 })
            assert.equals("ROLLING", Game:GetState())
            assert.same({ "A", "B", "C", "D" }, Game._State().participants)
            assert.matches("tied on the high and low end", announceCalls[#announceCalls])
        end)
    end)

    describe("Cancel and Reset", function()
        it("Cancel during quorum-wait broadcasts and resets state", function()
            Game:Open({ wager = 100 }, "Host")
            announceCalls = {}
            assert.is_true(Game:Cancel())
            assert.equals("IDLE", Game:GetState())
            assert.equals("DragonDice: Host cancelled the gold roll.", announceCalls[1])
            assert.is_true(fakeSchedule.records[1].cancelled)
        end)

        it("Cancel during start-countdown cancels every handle and advances epoch", function()
            openAndJoin("Host", 100, { "A", "B" })
            local epoch = Game._LobbyId()
            announceCalls = {}
            assert.is_true(Game:Cancel())
            assert.equals("IDLE", Game:GetState())
            assert.is_true(Game._LobbyId() > epoch)
            for i = 1, #fakeSchedule.records do
                assert.is_true(fakeSchedule.records[i].cancelled,
                    "record " .. i .. " should be cancelled on Cancel")
            end
        end)

        it("Cancel during ROLLING broadcasts cancel and returns to IDLE", function()
            openAndJoin("Host", 100, { "A", "B" })
            Game:_StartFromVerb("Host")
            Game:OnRoll({ player = "A", roll = 50, min = 1, max = 100 })
            announceCalls = {}
            assert.is_true(Game:Cancel())
            assert.equals("IDLE", Game:GetState())
            assert.equals("DragonDice: Host cancelled the gold roll.", announceCalls[1])
        end)

        it("Reset is silent and snaps to IDLE", function()
            openAndJoin("Host", 100, { "A", "B" })
            announceCalls = {}
            Game:Reset()
            assert.equals("IDLE", Game:GetState())
            assert.equals(0, #announceCalls)
        end)

        it("Cancel from IDLE prints 'no game in progress' and returns false", function()
            printLocalCalls = {}
            assert.is_false(Game:Cancel())
            assert.equals(1, #printLocalCalls)
        end)
    end)

    it("self-registers with the registry under id 'goldroll'", function()
        assert.equals(Game, ns.Registry:Get("goldroll"))
    end)
end)
