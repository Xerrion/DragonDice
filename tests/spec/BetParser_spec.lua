-------------------------------------------------------------------------------
-- BetParser_spec.lua
-- DragonDice BetParser: parses "!bet <amount>" with tolerant whitespace and
-- case, rejects every form of malformed amount (negative, zero, float,
-- non-numeric, empty, missing argument).
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

describe("BetParser", function()
    local BetParser

    before_each(function()
        BetParser = loader.load("Modules/BetParser.lua")
    end)

    it("parses a well-formed !bet line", function()
        assert.equals(100, BetParser.Parse("!bet 100"))
    end)

    it("tolerates leading and trailing whitespace", function()
        assert.equals(50, BetParser.Parse("   !bet 50   "))
    end)

    it("tolerates extra spaces between token and amount", function()
        assert.equals(7, BetParser.Parse("!bet   7"))
    end)

    it("is case-insensitive on the token", function()
        assert.equals(25, BetParser.Parse("!BET 25"))
        assert.equals(25, BetParser.Parse("!Bet 25"))
    end)

    it("rejects negative numbers", function()
        assert.is_nil(BetParser.Parse("!bet -5"))
    end)

    it("rejects zero", function()
        assert.is_nil(BetParser.Parse("!bet 0"))
    end)

    it("rejects floats", function()
        assert.is_nil(BetParser.Parse("!bet 1.5"))
        assert.is_nil(BetParser.Parse("!bet 100.0001"))
    end)

    it("rejects non-numeric amounts", function()
        assert.is_nil(BetParser.Parse("!bet foo"))
        assert.is_nil(BetParser.Parse("!bet 10g"))
    end)

    it("rejects empty input", function()
        assert.is_nil(BetParser.Parse(""))
        assert.is_nil(BetParser.Parse("   "))
    end)

    it("rejects missing argument", function()
        assert.is_nil(BetParser.Parse("!bet"))
        assert.is_nil(BetParser.Parse("!bet   "))
    end)

    it("rejects trailing junk after a valid amount", function()
        -- Exactly two tokens required: token + amount.
        assert.is_nil(BetParser.Parse("!bet 100 please"))
    end)

    it("rejects non-string input", function()
        assert.is_nil(BetParser.Parse(nil))
        assert.is_nil(BetParser.Parse(42))
    end)

    it("ignores unrelated chat lines", function()
        assert.is_nil(BetParser.Parse("!join"))
        assert.is_nil(BetParser.Parse("hello world"))
        assert.is_nil(BetParser.Parse("!bett 100"))
    end)
end)
