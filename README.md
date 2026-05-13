# DragonDice

Chat-driven 1v1 deathroller for World of Warcraft. The first consumer of
[DragonCore](https://github.com/Xerrion/DragonCore).

## Install

1. Install **DragonCore** (hard dependency).
2. Drop `DragonDice/` into `Interface/AddOns/`.

DragonDice will refuse to load without DragonCore. That's by design - the
addon depends on DragonCore primitives (Lifecycle, Listener, Locale, Store)
and pretending otherwise corrupts the API surface.

## MVP commands

```
/dr open <bet>    open a deathroll lobby for <bet> gold (positive integer)
/dr start         begin the match (requires an opponent who typed !join)
/dr status        print the current game state to your chat frame
/dr reset         clear local state silently
/dr cancel        cancel an open or active game and announce it
```

Opponents join by typing `!join` in `/p`, `/raid`, instance chat, or `/say`.
Whispers are intentionally not accepted.

## How a round plays

1. Host: `/dr open 100`
2. Opponent (in /p, /raid, or /say): `!join`
3. Host: `/dr start`
4. Host rolls: `/roll 1000`
5. Players alternate `/roll <currentMax>` until someone rolls a 1.
6. The roller of the 1 loses; the addon announces the winner and payout.

Payout is announcement-only ("Loser pays the bet") - no trade automation.

## DragonCore consumer

DragonDice is the precedent for the DragonCore consumer file shape: thin
`Core.lua`, per-concern modules under `Modules/`, locale from day one,
hard dependency on DragonCore.

## License

MIT.
