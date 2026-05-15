-------------------------------------------------------------------------------
-- spec/support/loader.lua
-- Self-contained loader for DragonDice's pure modules. Each module file
-- begins with `local ADDON_NAME, ns = ...` so the chunk only resolves a
-- module when called with both arguments. This helper hides the dance.
-------------------------------------------------------------------------------

local M = {}

---Load a DragonDice module file under a fresh namespace and return the
---module table the chunk yields. Pass an optional shared `ns` to chain
---multi-module loads.
---@param path string  Path relative to repo root, e.g. "DragonDice/Modules/FSM.lua".
---@param ns?  table   Shared namespace; defaults to a fresh table.
---@return any         Whatever the module's `return` yields.
---@return table       The namespace used for the load (so callers can chain).
function M.load(path, ns)
    ns = ns or {}
    local chunk, err = loadfile(path)
    if not chunk then error("loader: failed to load " .. path .. ": " .. tostring(err), 2) end
    local mod = chunk("DragonDice", ns)
    return mod, ns
end

---Install the Core.lua-provided `ns` helpers that production modules
---capture at load time. Specs that load any module aliasing
---`ns.TellHost` must call this BEFORE `loader.load` on that module.
---Mirrors Core.lua's ns.TellHost: localise via `ns.L`, format with the
---supplied args, route to `ns.PrintLocal`. Callers stub `ns.PrintLocal`
---themselves so they can assert on what was printed.
---@param ns table
function M.installCoreHelpers(ns)
    ns.TellHost = function(template, ...)
        if type(template) ~= "string" then return end
        local L = ns.L
        local resolved = (L and L[template]) or template
        if select("#", ...) > 0 then resolved = resolved:format(...) end
        if ns.PrintLocal then ns.PrintLocal(resolved) end
    end
end

return M
