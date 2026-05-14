--------------------------------------------------------------------------------
-- Locale/enUS.lua
-- DragonDice base locale. Workspace convention: enUS values are the boolean
-- `true` sentinel; DragonCore.Locale normalises at the registration boundary
-- so reads of `L["X"]` resolve to "X" without ever observing a `true`.
--
-- Keys are full English sentences. Adding a second locale is a pure data add
-- in a sibling file (no code edits).
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME = ...

local LibStub = LibStub
local DragonCore = LibStub("DragonCore-1.0")
if not DragonCore or not DragonCore.Locale then return end

DragonCore.Locale:Register({ name = ADDON_NAME }, "enUS", {
    -- Slash help / errors.
    ["DragonDice: usage: /dr open <bet> | status | reset | cancel"] = true,
    ["DragonDice: bet must be a positive integer."] = true,
    ["DragonDice: cannot open - host name missing."] = true,
    ["DragonDice: unknown command '%s'. Try /dr for usage."] = true,
    ["DragonDice: cannot start - need an opponent."] = true,
    ["DragonDice: cannot start - no game is open."] = true,
    ["DragonDice: no game in progress."] = true,
    ["DragonDice: only the host (%s) may run that command."] = true,

    -- Lobby / match announcements (broadcast).
    ["DragonDice: %s opens a %dg deathroll. Type !join to accept (lobby expires in %ds)."] = true,
    ["DragonDice: %s vs %s for %dg. %s rolls first: /roll %d"] = true,
    ["DragonDice: %s rolled %d. %s, /roll %d"] = true,
    ["DragonDice: %s rolled 1 and loses. %s wins %dg. Loser pays the bet."] = true,
    ["DragonDice: %s cancelled the deathroll."] = true,
    ["DragonDice: lobby expires in %ds."] = true,

    -- Lobby auto-expiry (host-local; never broadcast).
    ["DragonDice: no one accepted - lobby expired."] = true,

    -- Status (local to host's chat frame).
    ["DragonDice status: state=%s host=%s opponent=%s bet=%dg currentMax=%d turn=%s"] = true,
    ["(none)"] = true,

    -- Local warnings (host's chat frame only; never broadcast, never mutate).
    ["DragonDice: ignored roll from %s (not a participant)."] = true,
    ["DragonDice: %s rolled out of turn (waiting on %s)."] = true,
    ["DragonDice: %s rolled wrong range 1-%d (expected 1-%d) - roll discarded."] = true,
})
