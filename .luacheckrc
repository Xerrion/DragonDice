std = "lua51"
max_line_length = 120
codes = true
exclude_files = {
    "Libs/",
    ".release/",
    ".deliverables/",
}

ignore = {
    "212/self",
    "211/_.*",  -- unused variables prefixed with underscore
    "212/_.*",  -- unused arguments prefixed with underscore
    "213/_.*",  -- unused loop variables prefixed with underscore
    "211/ADDON_NAME",  -- workspace convention: every addon file declares
                       -- `local ADDON_NAME, ns = ...` even when only `ns`
                       -- is referenced.
}

read_globals = {
    -- Libraries (provided by DragonCore as a hard dependency).
    "LibStub",

    -- WoW API surface DragonDice touches at runtime.
    "UnitName",
    "Ambiguate",
    "GetLocale",
    "SendChatMessage",
    "IsInGroup",
    "IsInRaid",
    "LE_PARTY_CATEGORY_INSTANCE",
}

globals = {
    -- The two slash globals + SavedVariables. The only globals DragonDice
    -- writes (per ADR / orchestrator constraint).
    "SLASH_DRAGONDICE1",
    "SLASH_DRAGONDICE2",
    "DragonDiceDB",
    -- SlashCmdList is provided by Blizzard but DragonDice writes a key into
    -- it -- declare as a writable global so 121 is silenced for the index.
    "SlashCmdList",
}

-----------------------------------------------------------------------
-- Tests
-----------------------------------------------------------------------
files["tests/"] = {
    read_globals = {
        -- Busted DSL.
        "describe", "it", "before_each", "after_each", "setup", "teardown",
        "pending", "assert", "spy", "stub", "mock", "match",
    },
}
