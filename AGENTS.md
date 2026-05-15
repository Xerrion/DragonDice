# DragonDice - Agent Guidelines

Project-specific rules for the DragonDice addon. See the workspace `AGENTS.md`
(at `F:\wow-addons\AGENTS.md`) for cross-addon conventions (Lua 5.1, no `require`,
locale pattern, TOC version-gating, CI conventions, branch naming, etc.) that
apply to every Dragon* addon.

---

## What DragonDice Is

A chat-driven dice-game framework. Two games ship today (deathroll, gold roll)
and the registry shape supports more without Core changes. DragonDice is the
**first DragonCore consumer** and the reference implementation for the
DragonCore consumer file shape.

---

## Architecture

| Layer       | Directory           | Rule                                                                       |
|-------------|---------------------|----------------------------------------------------------------------------|
| Shell       | `Core.lua`          | Wires DragonCore Lifecycle, resolves the locale proxy, opens the Store    |
| Locale      | `Locales/`          | Locale registration via `DragonCore.Locale` (AceLocale-3.0 compatible)    |
| Pure        | `Modules/FSM.lua`, `Modules/RollParser.lua`, `Modules/Announce.lua` | No DragonCore deps; testable in plain Lua |
| Registry    | `Modules/Registry.lua` | Game registration table; games self-register on load                   |
| Games       | `Modules/Games/`    | Self-register into the registry; one file per game                        |
| Routers     | `Modules/Chat.lua`, `Modules/Slash.lua` | Depend on Registry; route slash + chat verbs to games |

### Adding a Game

1. Create `Modules/Games/<GameName>.lua`. The file must self-register on load
   into `ns.Registry` (see `Deathroll.lua` and `Goldroll.lua` for the shape).
2. Add the file path to `DragonDice.toc` under the `# Games` section.
3. Add any new strings to `Locales/enUS.lua` using full-English-sentence keys.
4. No changes required to `Core.lua`, the routers, or the FSM helper.

---

## DragonCore Dependency

DragonDice has a **hard dependency on DragonCore** (`## Dependencies: DragonCore`
in the TOC). DragonDice will refuse to load without it, by design - the addon
depends on DragonCore primitives end-to-end and pretending otherwise would
silently corrupt the API surface.

| Primitive                       | Used For                                              |
|---------------------------------|-------------------------------------------------------|
| `DragonCore.Lifecycle:Register` | Addon registration + ordered init phases              |
| `DragonCore.Listener:New`       | Per-addon event subscription with automatic cleanup   |
| `DragonCore.Locale:Get/Register`| Locale proxy + sentinel-normalised string registry    |
| `DragonCore.Store:Open`         | SavedVariables (`DragonDiceDB`) with profile support  |
| `DragonCore.Schedule`           | Cancellable timers (exposed as `ns.Schedule`)         |

All access goes through `LibStub("DragonCore-1.0")` - there is no `DragonCore`
global.

---

## Namespace Convention

All files share the addon namespace via `local ADDON_NAME, ns = ...` at the
top. Sub-namespaces:

- `ns.L` - locale proxy resolved through `DragonCore.Locale`
- `ns.Schedule` - re-export of `DragonCore.Schedule`
- `ns.Registry` - game registry (populated by `Modules/Registry.lua`)
- `ns.FSM` - finite-state-machine helper
- `ns.RollParser` - parses `/roll` chat lines into structured events
- `ns.Announce` - emits announcements to the active chat channel

The only true globals DragonDice writes:

- `DragonDiceDB` - SavedVariable (per the TOC)
- `SLASH_DRAGONDICE1`, `SLASH_DRAGONDICE2` - slash command bindings

---

## Slash + Chat Duality

Every host verb works both as `/dc <verb>` (slash) and as `!dc <verb>` in
`/p`, `/raid`, instance chat, or `/say`. Whispers are intentionally **not**
accepted - the lobby and join model assumes a shared channel.

| Slash Command                | Description                                              |
|------------------------------|----------------------------------------------------------|
| `/dc`                        | Usage + registered-games list                            |
| `/dc deathroll open <bet>`   | Open a deathroll lobby                                   |
| `/dc goldroll open <wager>`  | Open a gold-roll lobby                                   |
| `/dc goldroll start`         | Host short-circuit (skip the 15s countdown)              |
| `/dc status`                 | Print active game state to chat frame                    |
| `/dc cancel`                 | Cancel the active game (host only, announced)            |
| `/dc reset`                  | Clear local state silently (host only)                   |
| `/dc start`                  | Delegate to active game's start verb                     |

`/dragondice` is the long-form alias.

---

## Locale

Uses **DragonCore.Locale** (AceLocale-3.0 compatible). Workspace convention:

- Keys are **full English sentences**, not codes.
- Base locale (`enUS`) registers values as the boolean sentinel `true`;
  the locale layer normalises this so `L["X"]` reads as `"X"`.
- Missing translations fall back to enUS silently.

DragonDice ships only `enUS` today. Add a new locale by creating
`Locales/<locale>.lua` and listing it in `DragonDice.toc` under the
`# Locale content` block. See `F:\wow-addons\AGENTS.md` for the full pattern.

---

## Testing

- `luacheck .` from the repo root - must pass with **0 new warnings** (the
  `Libs/` directory is excluded in `.luacheckrc`).
- `busted --verbose` runs the spec suite in `spec/spec/`. Tests cover the
  pure modules (FSM, RollParser, Announce) and the game / registry / router
  layers under a mock loader (`spec/support/loader.lua`).

---

## Known Gotchas

1. **DragonCore must load first.** TOC lists the DragonCore source files
   inline (WoW does not support TOC-of-TOC includes), so the load order is
   fixed at the top of `DragonDice.toc`. Do not reorder.
2. **Locale registration is post-Core.** `Locales/enUS.lua` loads after
   `Core.lua` because `Core.lua` resolves the locale proxy first. Keep the
   ordering in the TOC.
3. **`DragonDice_Icon.tga` is referenced by the TOC but not yet generated.**
   The TOC `## IconTexture` line points at `Interface\AddOns\DragonDice\DragonDice_Icon`
   (no extension; WoW resolves `.tga` automatically). A 64x64 TGA is the
   expected format; the PNG logos in `assets/` are for the README only.
4. **No trade automation.** Payouts are announcement-only by design - do not
   add `InitiateTrade` or `PickupContainerItem` calls.