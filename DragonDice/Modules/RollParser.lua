--------------------------------------------------------------------------------
-- Modules/RollParser.lua
-- Pure: a CHAT_MSG_SYSTEM line -> { player, roll, min, max } | nil. The only
-- impure surface is `GetLocale()` consulted at module-load time to pick the
-- right pattern entry; that lookup is cached so per-message parsing is
-- string-only.
--
-- Locale seam: the `PATTERNS` table is keyed by WoW client locale. Adding a
-- second locale is one entry; the function signature is the seam, the table
-- is the implementation. MVP populates only enUS.
--
-- Supported clients: Retail, MoP Classic, Wrath Classic, Classic Era.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local string_match = string.match
local tonumber = tonumber

local M = {}

-- Locale-keyed regex table. Each pattern must capture (player, roll, min, max)
-- in that order, all as strings. Anchored at both ends so trailing junk does
-- not silently parse.
M.PATTERNS = {
    enUS = "^(%S+) rolls (%d+) %((%d+)%-(%d+)%)$",
}

-- Resolved at first :Parse call so module load order vs. mock setup in tests
-- does not matter. Production load: GetLocale is always present by the time
-- a CHAT_MSG_SYSTEM fires.
local resolvedPattern

local function resolvePattern()
    local locale = (_G.GetLocale and _G.GetLocale()) or "enUS"
    return M.PATTERNS[locale] or M.PATTERNS.enUS
end

---Parse a system chat line. Returns nil for any non-roll line; returns a
---record for a well-formed roll. The record fields are documented below.
---@param line string
---@return { player: string, roll: integer, min: integer, max: integer } | nil
function M.Parse(line)
    if type(line) ~= "string" or line == "" then return nil end
    if resolvedPattern == nil then resolvedPattern = resolvePattern() end

    local player, roll, minR, maxR = string_match(line, resolvedPattern)
    if not player then return nil end

    local rollN = tonumber(roll)
    local minN = tonumber(minR)
    local maxN = tonumber(maxR)
    if not (rollN and minN and maxN) then return nil end

    return { player = player, roll = rollN, min = minN, max = maxN }
end

---Test seam: clear the cached pattern so a spec that swaps `_G.GetLocale`
---can re-resolve. Not used in production.
function M._ResetCache()
    resolvedPattern = nil
end

ns.RollParser = M

return M
