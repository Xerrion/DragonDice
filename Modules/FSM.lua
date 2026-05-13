--------------------------------------------------------------------------------
-- Modules/FSM.lua
-- Tiny generic finite-state-machine helper. Pure Lua, no WoW dependencies,
-- no DragonCore dependencies. Exists so Game.lua reads as game rules instead
-- of table bookkeeping and so transitions are unit-testable in isolation.
--
-- Contract:
--   FSM.New(initial, transitions)
--     initial      : string  starting state.
--     transitions  : { [from] = { [to] = true, ... }, ... }
--                    Permitted (from -> to) edges. Self-loops must be listed
--                    explicitly; absence raises on attempt.
--   fsm:Get()     -> current state
--   fsm:Can(to)   -> boolean (is `to` reachable from current?)
--   fsm:To(to)    -> boolean (transitions if legal; raises if illegal)
--   fsm:Reset()   -> () (snaps back to `initial`)
--
-- Revisit trigger: promote to DragonCore once a second consumer needs an FSM
-- with the same shape (per ADR section "FSM promotion trigger").
--
-- Supported versions: Retail
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...
ns = ns or {}

local M = {}

---@class DragonDice.FSM
---@field private _state string
---@field private _initial string
---@field private _transitions table<string, table<string, boolean>>
local FSM = {}
FSM.__index = FSM

---Construct a new FSM bound to `transitions`. The transitions table is held
---by reference (NOT copied); callers should not mutate it after :New.
---@param initial string
---@param transitions table<string, table<string, boolean>>
---@return DragonDice.FSM
function M.New(initial, transitions)
    if type(initial) ~= "string" or initial == "" then
        error("DragonDice.FSM.New: initial must be a non-empty string", 2)
    end
    if type(transitions) ~= "table" then
        error("DragonDice.FSM.New: transitions must be a table", 2)
    end
    return setmetatable({
        _state = initial,
        _initial = initial,
        _transitions = transitions,
    }, FSM)
end

---@return string
function FSM:Get()
    return self._state
end

---Is `to` reachable from the current state?
---@param to string
---@return boolean
function FSM:Can(to)
    local edges = self._transitions[self._state]
    return edges ~= nil and edges[to] == true
end

---Transition to `to`. Returns true on success. Raises on illegal edge so
---game logic discovers state bugs immediately rather than silently no-oping.
---@param to string
---@return boolean
function FSM:To(to)
    if not self:Can(to) then
        error("DragonDice.FSM:To: illegal transition " ..
            tostring(self._state) .. " -> " .. tostring(to), 2)
    end
    self._state = to
    return true
end

---Snap back to the initial state regardless of legal edges. Used by Reset
---and Cancel paths where the FSM may be in any state.
function FSM:Reset()
    self._state = self._initial
end

ns.FSM = M

-- The chunk return is what `loadfile(path)("DragonDice", {})` yields in
-- busted specs. Production WoW load ignores the return value.
return M
