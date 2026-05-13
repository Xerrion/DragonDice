-------------------------------------------------------------------------------
-- RollParser_spec.lua
-- DragonDice RollParser: parses well-formed enUS /roll system lines, rejects
-- malformed input, and routes through the locale-keyed PATTERNS table.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

describe("RollParser", function()
    local RollParser
    local previousGetLocale

    before_each(function()
        previousGetLocale = _G.GetLocale
        _G.GetLocale = function() return "enUS" end
        RollParser = loader.load("Modules/RollParser.lua")
        RollParser._ResetCache()
    end)

    after_each(function()
        _G.GetLocale = previousGetLocale
    end)

    it("parses a well-formed enUS roll line", function()
        local r = RollParser.Parse("Bob rolls 42 (1-100)")
        assert.is_table(r)
        assert.equals("Bob", r.player)
        assert.equals(42, r.roll)
        assert.equals(1, r.min)
        assert.equals(100, r.max)
    end)

    it("parses the deathroll-loss line (roll == 1)", function()
        local r = RollParser.Parse("Alice rolls 1 (1-7)")
        assert.equals(1, r.roll)
        assert.equals(7, r.max)
    end)

    it("returns nil for non-roll system lines", function()
        assert.is_nil(RollParser.Parse("Bob has joined the raid group."))
        assert.is_nil(RollParser.Parse(""))
        assert.is_nil(RollParser.Parse("random chatter"))
    end)

    it("returns nil for trailing junk (anchored regex)", function()
        assert.is_nil(RollParser.Parse("Bob rolls 42 (1-100) trailing"))
    end)

    it("returns nil for leading junk", function()
        assert.is_nil(RollParser.Parse("[Group] Bob rolls 42 (1-100)"))
    end)

    it("returns nil for non-string input", function()
        assert.is_nil(RollParser.Parse(nil))
        assert.is_nil(RollParser.Parse(42))
    end)

    it("exposes a locale-keyed PATTERNS table as the seam", function()
        assert.is_string(RollParser.PATTERNS.enUS)
    end)

    it("falls back to enUS pattern for an unsupported client locale", function()
        _G.GetLocale = function() return "frFR" end
        RollParser._ResetCache()
        local r = RollParser.Parse("Bob rolls 5 (1-10)")
        assert.is_table(r)
        assert.equals(5, r.roll)
    end)
end)
