-------------------------------------------------------------------------------
-- FSM_spec.lua
-- DragonDice FSM helper: legal/illegal transitions, reset, can-checks.
-------------------------------------------------------------------------------

package.path = package.path .. ";./spec/?.lua;./spec/support/?.lua"
local loader = require("support.loader")

describe("FSM", function()
    local FSM

    before_each(function()
        FSM = loader.load("DragonDice/Modules/FSM.lua")
    end)

    local function newDeathrollFSM()
        return FSM.New("IDLE", {
            IDLE     = { OPEN = true },
            OPEN     = { ACTIVE = true, IDLE = true },
            ACTIVE   = { FINISHED = true, IDLE = true },
            FINISHED = { IDLE = true, OPEN = true },
        })
    end

    it("starts in the initial state", function()
        local fsm = newDeathrollFSM()
        assert.equals("IDLE", fsm:Get())
    end)

    it("reports legal edges via :Can", function()
        local fsm = newDeathrollFSM()
        assert.is_true(fsm:Can("OPEN"))
        assert.is_false(fsm:Can("ACTIVE"))
        assert.is_false(fsm:Can("FINISHED"))
    end)

    it("transitions on legal edges", function()
        local fsm = newDeathrollFSM()
        fsm:To("OPEN")
        assert.equals("OPEN", fsm:Get())
        fsm:To("ACTIVE")
        assert.equals("ACTIVE", fsm:Get())
        fsm:To("FINISHED")
        assert.equals("FINISHED", fsm:Get())
    end)

    it("raises on illegal edges and leaves state untouched", function()
        local fsm = newDeathrollFSM()
        assert.has_error(function() fsm:To("FINISHED") end)
        assert.equals("IDLE", fsm:Get())
    end)

    it("snaps back to initial on Reset from any state", function()
        local fsm = newDeathrollFSM()
        fsm:To("OPEN")
        fsm:To("ACTIVE")
        fsm:Reset()
        assert.equals("IDLE", fsm:Get())
    end)

    it("validates constructor inputs", function()
        assert.has_error(function() FSM.New(nil, {}) end)
        assert.has_error(function() FSM.New("", {}) end)
        assert.has_error(function() FSM.New("IDLE", nil) end)
    end)
end)
