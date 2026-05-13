--------------------------------------------------------------------------------
-- Modules/BetParser.lua
-- Pure: a chat line -> bet integer | nil. Recognises "!bet <amount>" with
-- tolerant whitespace and case. Returns the parsed positive integer or nil
-- for any malformed input. Mirrors `RollParser.lua` in shape (data table +
-- pure `Parse`) so a future locale or alias variation is a one-line add.
--
-- Validation rules (orchestrator spec):
--   * Amount must parse to a positive integer.
--   * "!bet 0", "!bet -5", "!bet 1.5", "!bet foo", "!bet", "!bet  " all
--     return nil. No public warning, no host-local warning -- callers are
--     responsible for silent ignore.
--
-- Supported versions: Retail
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local string_match = string.match
local string_lower = string.lower
local tonumber = tonumber
local math_floor = math.floor

local M = {}

-- Trigger token. Lowercased compare so "!Bet", "!BET" still match.
M.TOKEN = "!bet"

---Parse a chat line. Returns the positive integer bet, or nil for any input
---that is not exactly "!bet <positive-integer>" (whitespace tolerated at
---both ends and around the amount).
---@param line string
---@return integer | nil
function M.Parse(line)
    if type(line) ~= "string" or line == "" then return nil end

    local trimmed = string_match(line, "^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then return nil end

    local token, amount = string_match(trimmed, "^(%S+)%s+(%S+)$")
    if not token or not amount then return nil end
    if string_lower(token) ~= M.TOKEN then return nil end

    local n = tonumber(amount)
    if n == nil then return nil end
    if n ~= math_floor(n) then return nil end
    if n <= 0 then return nil end

    return n
end

ns.BetParser = M

return M
