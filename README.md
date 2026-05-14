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
/dc deathroll open <bet>  open a deathroll lobby for <bet> gold (positive integer)
/dc status                print the current game state to your chat frame
/dc reset                 clear local state silently (host only when a game is active)
/dc cancel                cancel an open or active game and announce it (host only)
```

`/dragondice` is the long-form alias of `/dc`.

Opponents join by typing `!join` in `/p`, `/raid`, instance chat, or `/say`.
The deathroll starts automatically as soon as an opponent joins. Whispers
are intentionally not accepted.

## How a round plays

1. Host: `/dc deathroll open 100`
2. Opponent (in /p, /raid, or /say): `!join`
3. Match starts: the host rolls `/roll 1000` automatically.
4. Players alternate `/roll <currentMax>` until someone rolls a 1.
5. The roller of the 1 loses; the addon announces the winner and payout.

Payout is announcement-only ("Loser pays the bet") - no trade automation.

## DragonCore consumer

DragonDice is the precedent for the DragonCore consumer file shape: thin
`Core.lua`, per-concern modules under `Modules/`, locale from day one,
hard dependency on DragonCore.

## License

MIT.
