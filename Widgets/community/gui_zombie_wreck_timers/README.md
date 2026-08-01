# Zombie Wreck Timers

For games with the **Zombies** modoption enabled: every wreck gets a floating countdown showing when it will reanimate. The widget removes itself in games without zombies.

## What you see

A timer that changes from white to violet based on how soon the zombie will spawn.
- ? for a wreck you first saw some time after it was created — its age is unknown, so no fake countdown is shown.
- '~' prefix for the wreck that spent time out of your vision, so the timer may have been reset while you couldn't see it. Treat it as "at most this much".

## How it works

The zombie gadget revives a wreck after `metalcost / 16` seconds, clamped between 60 and 180. The widget applies the same formula per wreck type and counts down from the moment the wreck appears.

Any reclaim or resurrect progress on a wreck resets the gadget's timer, the widget watches for that (metal or reclaim fraction dropping) and resets its countdown to match. If a fully-visible timer runs over without a spawn, it re-arms as an upper bound instead of showing nonsense.

Timers only count down honestly for wrecks whose creation you saw. Everything else is marked with `?` or `~` rather than guessed.
