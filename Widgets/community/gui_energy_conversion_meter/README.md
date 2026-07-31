# Energy Conversion Meter

## Introduction
Are your converters starving, or is your energy silently going to waste?
This meter tells you whether your **energy production and energy conversion are balanced** at a glance, and loudly when it really matters.

## What it shows
A compact 9-bar meter next to the top bar:
- **Green center bar** = Most of your converters are working and you're not overflowing energy. Solid balance.
- **Bars fill to the RIGHT (OVERFLOWING)** = Your energy increased, but you're not converting all of it. You're overflowing, potentially leaving extra metal on the table.
- **Bars fill to the LEFT (IDLE CONVERTERS)** = Your converters are sitting unused. You could be converting to metal, but you don't have enough energy.
- Bars ramp **yellow → orange → red** as the imbalance grows. Left indicates Energy deficit, Right indicates Converter deficit.
- The E/s value of the imbalance is shown next to the bars, with a hint label underneath.

## Smart severity
- Severity is **relative to your income** (3k excess on 5k income is huge; on 100k it's mild), with absolute floors so a large absolute waste still maxes the meter on a big economy.
- **Construction-aware**: energy and converters you are *actively building* already count as fixed, so it won't nag you about a problem you're already solving. Untouched blueprints don't count.
- Values are smoothed (~2s) with display hysteresis, so it doesn't flicker during build bursts.

## Alerts
- Holding **3+ bars for ~5s** pops an on-screen message with a soft beep (once per episode, 30s cooldown).
- **Pinned at 4 bars**: a stronger pulsing message repeats every 20s, and the meter's side icon + label pulse red until solved.

## Extras
- **Ctrl + left-click drag** moves the meter anywhere; the position is saved. Plain clicks pass through, so it never blocks orders.
- Reads the same team rules params as the game's conversion gadget (`mmUse`/`mmCapacity`) — spectator-safe, no unit control, display only.
