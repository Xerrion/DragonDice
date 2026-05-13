-------------------------------------------------------------------------------
-- Slash_spec.lua
-- DragonDice Slash: covers `M.CanPlayerAct(localPlayerName, hostName)` -- the
-- pure name-comparison gate extracted from the destructive-verb closure. The
-- closure itself (and the IDLE-state bypass) requires WoW globals and the
-- live Game module; this spec stays in the pure layer.
--
-- The module writes SLASH_* globals and into SlashCmdList from `Init`, so
-- this spec only loads the module and calls `M.CanPlayerAct` directly.
-------------------------------------------------------------------------------

package.path = package.path .. ";./tests/?.lua;./tests/support/?.lua"
local loader = require("support.loader")

describe("Slash.CanPlayerAct", function()
    local Slash

    before_each(function()
        local ns = {}
        -- Slash.lua only references `ns.GetShortName` from within the closure
        -- gate, not at module-load time, so a stub is not strictly required.
        -- Provided anyway so future module-level use does not surprise us.
        ns.GetShortName = function(name) return name end
        Slash = loader.load("Modules/Slash.lua", ns)
    end)

    it("returns false when both names are nil (defensive)", function()
        assert.is_false(Slash.CanPlayerAct(nil, nil))
    end)

    it("returns false when hostName is nil", function()
        assert.is_false(Slash.CanPlayerAct("LocalPlayer", nil))
    end)

    it("returns false when localPlayerName is nil", function()
        assert.is_false(Slash.CanPlayerAct(nil, "RemoteHost"))
    end)

    it("returns true when both names match exactly", function()
        assert.is_true(Slash.CanPlayerAct("Hostname", "Hostname"))
    end)

    it("returns false when names differ", function()
        assert.is_false(Slash.CanPlayerAct("Joiner", "Hostname"))
    end)

    it("is case-sensitive (mirrors raw `==` semantics)", function()
        -- WoW player names are case-stable; the gate uses `==` so callers
        -- must pass byte-identical short names. Verified here so a future
        -- "be helpful" lowercase fold does not slip in unnoticed.
        assert.is_false(Slash.CanPlayerAct("hostname", "Hostname"))
        assert.is_false(Slash.CanPlayerAct("HOSTNAME", "Hostname"))
    end)

    it("treats whitespace as significant (names are pre-normalised)", function()
        -- The closure feeds already-trimmed short names via `ns.GetShortName`;
        -- the pure function never re-trims. A stray space means a different
        -- player, full stop.
        assert.is_false(Slash.CanPlayerAct("Hostname ", "Hostname"))
        assert.is_false(Slash.CanPlayerAct("Hostname", " Hostname"))
    end)

    it("returns false when either name is an empty string", function()
        -- Empty strings should not satisfy the gate even if both sides happen
        -- to be empty; an unset host must never grant permission.
        assert.is_false(Slash.CanPlayerAct("", ""))
        assert.is_false(Slash.CanPlayerAct("", "Hostname"))
        assert.is_false(Slash.CanPlayerAct("Hostname", ""))
    end)
end)
