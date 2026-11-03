# Zombie Wreck Timers

## Introduction
In Zombie mode every wreck is a threat on a timer. This widget shows that timer: a countdown floats over each corpse telling you exactly when it will rise again, so you can decide what to reclaim, what to defend and what to run from.

## What it shows
- A **countdown** over every wreck that will reanimate (`2:45`, `1:10`, `43`, ...).
- Colors escalate as the rise nears: **white** with more than 2 minutes, **light purple** under 2 minutes, **deep purple** under 1 minute, and a **pulsing purple** in the final 15 seconds.
- **Reacts the moment a corpse is touched**: reclaiming or resurrecting resets the game's timer, and the countdown jumps to the new value instantly instead of waiting for the old one to run out.
- A purple **?** marks wrecks that slipped into the fog: their timer may have been reset unseen, so the widget is honest about not knowing instead of showing a stale number.
- Timers fade slightly for wrecks outside your line of sight but still readable on radar-known ground.

## Game state panel
A small panel in the top bar, next to the resource bars, shows how dangerous the zombies currently are. Pick what you want in Settings, under the widget's name:
- **None**: no panel, only the wreck timers.
- **Basic**: a skull and two bars. **Rising** is how fast wrecks come back to life, **Labs** is how fast zombie factories build. Both fill, and shift from light to deep purple, as the strongest team techs up.
- **Advanced**: adds a **Tech** bar for the zombies' tech estimate and the exact numbers next to each bar, including the wreck timer window every corpse is clamped into.
Hover the panel for a tooltip with the numbers and their caps. Hold Ctrl and drag it with the left mouse button to move it, it remembers where you put it.

## Fair play
The widget reads only the public `zombie_rez_frame` feature rules param that the game itself publishes since the Zombie Mode Update ([PR #8582](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/8582)). Spawn timing was deliberately made transparent to all players there and this widget just puts that number on screen. The instant reaction to reclaim and resurrect comes from the same visible progress the health bars already draw over the wreck, combined with that published timer. The game state panel reads the `zombie_tech_level`, `zombie_rez_power_speed` and `zombie_factory_buildpower_multiplier` game rules params the zombie gadget publishes for exactly this purpose ([PR #9887](https://github.com/beyond-all-reason/Beyond-All-Reason/pull/9887)); on game versions without them the panel simply stays hidden. No hidden information, no unit control, spectator-safe, display only.

## Credits
Created by Egzothicki together with SethDGamre, the author of Zombie mode. The spawn-timing rework that made this widget possible grew out of the same collaboration.