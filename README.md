# DragonDice

Chat-driven dice games for World of Warcraft - deathroll today, gold roll
beside it, and a registry shape that takes more. The first consumer of
[DragonCore](https://github.com/Xerrion/DragonCore).

## Install

1. Install **DragonCore** (hard dependency).
2. Drop `DragonDice/` into `Interface/AddOns/`.

DragonDice will refuse to load without DragonCore. That's by design - the
addon depends on DragonCore primitives (Lifecycle, Listener, Locale, Store)
and pretending otherwise corrupts the API surface.

## Commands

```
/dc                              show usage and the registered-games list
/dc deathroll open <bet>         open a deathroll lobby for <bet> gold
/dc goldroll open <wager>        open a multi-player gold roll for <wager> gold
/dc goldroll start               host short-circuit: begin rolling now
/dc status                       print the active game's state to your chat frame
/dc cancel                       cancel the active game and announce it (host only)
/dc reset                        clear local state silently (host only)
/dc start                        delegate to the active game's start verb, if any
```

`/dragondice` is the long-form alias of `/dc`. The host can also start a
gold roll from group chat with `!dc goldroll start`; opening a lobby from
chat uses the same shape, e.g. `!dc deathroll 100` or `!dc goldroll 500`.

Players join by typing `!join` in `/p`, `/raid`, instance chat, or `/say`.
Deathroll auto-starts on the first joiner. Gold roll auto-starts on a
15-second countdown once two or more players have joined; the host can
short-circuit early with `/dc goldroll start` (or its chat twin) or wait
for the timer. Whispers are intentionally not accepted.

## How a deathroll plays

1. Host: `/dc deathroll open 100`
2. Opponent (in /p, /raid, or /say): `!join`
3. Match starts: the host rolls `/roll 1000` automatically.
4. Players alternate `/roll <currentMax>` until someone rolls a 1.
5. The roller of the 1 loses; the addon announces the winner and payout.

## How a gold roll plays

1. Host: `/dc goldroll open 500`
2. Players (in /p, /raid, or /say): `!join`. Host may self-join.
3. Quorum (2+) reached: a 15s countdown starts; the host may begin
   immediately with `/dc goldroll start` or `!dc goldroll start`.
4. Every participant rolls `/roll <wager>` exactly once.
5. Highest and lowest rolls determine the result; the difference is the
   amount the lowest owes the highest. Ties at either end trigger a
   re-roll among the tied players.

Payout is announcement-only ("Loser pays the bet" / "X owes Y Ng") - no
trade automation in either game.

## DragonCore consumer

DragonDice is the precedent for the DragonCore consumer file shape: thin
`Core.lua`, per-concern modules under `Modules/`, locale from day one,
hard dependency on DragonCore. Game modules live in `Modules/Games/` and
self-register on a per-addon registry; adding a third game is a new file
under that directory plus locale entries.

## License

MIT.
