# Contributing to DragonDice

Thank you for your interest in contributing to **DragonDice** - a chat-driven dice-game framework for World of Warcraft built on [DragonCore](https://github.com/Xerrion/DragonCore). This guide will help you get started.

## How to Contribute

### Reporting Bugs

- Use the [bug report template](https://github.com/Xerrion/DragonDice/issues/new?template=bug-report.yml)
- Include your WoW version, DragonDice version, DragonCore version, and steps to reproduce

### Suggesting Features

- Use the [feature request template](https://github.com/Xerrion/DragonDice/issues/new?template=feature-request.yml)
- Explain the problem your feature would solve

### Contributing Code

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## Prerequisites

- World of Warcraft client (Retail, MoP Classic, TBC Anniversary, or Classic Era)
- [Lua 5.1](https://www.lua.org/) (for linting and testing - the addon targets 5.1)
- [Luacheck](https://github.com/mpeterv/luacheck) (for static analysis)
- [Busted](https://olivinelabs.com/busted/) (for unit tests)
- [Git](https://git-scm.com/)

## Development Setup

1. **Fork and clone** the repository:

   ```bash
   git clone https://github.com/YOUR_USERNAME/DragonDice.git
   cd DragonDice
   ```

2. **Initialize submodules** (DragonCore is vendored as a submodule for local dev):

   ```bash
   git submodule update --init --recursive
   ```

3. **Link** the addon into your WoW AddOns folder. The link target must be
   the **inner** `DragonDice/` folder (the one containing `DragonDice.toc`),
   not the repo root - WoW expects `DragonDice.toc` to sit directly inside
   the AddOns entry.

   ```cmd
   :: Windows (cmd or PowerShell, Admin) - Junction (recommended)
   cmd /c mklink /J "C:\Path\To\Wow\_retail_\Interface\AddOns\DragonDice" "F:\path\to\DragonDice\DragonDice"
   ```

   ```powershell
   # Windows (PowerShell as Admin) - SymbolicLink alternative
   New-Item -ItemType SymbolicLink -Path "$env:PROGRAMFILES\World of Warcraft\_retail_\Interface\AddOns\DragonDice" -Target "$(Get-Location)\DragonDice"
   ```

4. **Install DragonCore** (or symlink it the same way) - DragonDice will refuse to load without it.

5. **Reload** in-game with `/reload`.

## Code Style

### Formatting

- Indent with **4 spaces** (no tabs)
- Max line length: **120 characters**
- Spaces around operators: `local x = 1 + 2`
- No trailing whitespace

### File Header

Every Lua file should start with:

```lua
--------------------------------------------------------------------------------
-- FileName.lua
-- Brief description of the module.
--
-- Supported versions: Retail, MoP Classic, TBC Anniversary, Classic Era
--------------------------------------------------------------------------------
```

### Naming Conventions

| Element            | Convention   | Example                       |
|--------------------|--------------|-------------------------------|
| Files              | PascalCase   | `Modules/Games/Deathroll.lua` |
| SavedVariables     | PascalCase   | `DragonDiceDB`                |
| Local variables    | camelCase    | `local activeGame`            |
| Functions          | PascalCase   | `local function StartRoll()`  |
| Constants          | UPPER_SNAKE  | `local MAX_PLAYERS = 40`      |

### Namespace

All files share the addon namespace via `local ADDON_NAME, ns = ...` at the top. The only true globals are
`DragonDiceDB` (SavedVariable) and `SLASH_DRAGONDICE1` / `SLASH_DRAGONDICE2`.

### Libraries

DragonDice depends on **DragonCore** exclusively. All inter-module wiring routes through DragonCore primitives -
**no `require` statements, no raw `frame:RegisterEvent`, no direct AceX usage** in the addon itself.

| Primitive               | Purpose                                       |
|-------------------------|-----------------------------------------------|
| `DragonCore.Lifecycle`  | Addon registration and initialization phases  |
| `DragonCore.Listener`   | Per-addon event subscription with cleanup     |
| `DragonCore.Locale`     | AceLocale-3.0-compatible locale registry      |
| `DragonCore.Store`      | SavedVariables with profile support           |
| `DragonCore.Schedule`   | Cancellable timers (taint-safe)               |

## Linting

Run luacheck before submitting changes. CI will reject PRs with new warnings.

```bash
luacheck .
luacheck DragonDice/Modules/Games/Deathroll.lua    # single file for fast feedback
```

## Testing

DragonDice uses [busted](https://olivinelabs.com/busted/) for unit testing. Tests live in `spec/spec/`.

```bash
busted --verbose                       # run all tests
busted spec/spec/FSM_spec.lua          # run a single test file
```

## Submitting Changes

1. **Branch** from `master`:

   ```bash
   git checkout -b feat/<issue-number>-short-desc
   ```

2. **Commit** using [Conventional Commits](https://www.conventionalcommits.org/):

   ```bash
   git commit -m "feat: add gold-roll countdown skip (#42)"
   ```

3. **Push** your branch and open a PR against `master`.

4. **Fill out** the PR template and wait for CI checks.

### Branch Naming

| Prefix       | Purpose             | Example                          |
|--------------|---------------------|----------------------------------|
| `feat/`      | New feature         | `feat/14-tie-rerolls`            |
| `fix/`       | Bug fix             | `fix/15-host-leave-crash`        |
| `docs/`      | Documentation       | `docs/16-update-readme`          |
| `refactor/`  | Code improvement    | `refactor/17-registry-cleanup`   |
| `chore/`     | Tooling / CI / deps | `chore/18-bump-dragoncore`       |

## What Happens After Your PR

1. **CI** runs luacheck and busted tests automatically.
2. **Review** by a maintainer (and CodeRabbit, when configured).
3. **Squash merge** into `master`.
4. **Release-please** creates a release PR when ready.

Thank you for contributing to DragonDice!
