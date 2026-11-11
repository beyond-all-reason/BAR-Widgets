# Stall Timer

A Beyond All Reason widget that writes a time-to-stall clock under the metal and energy sliders on the top bar.

## What it shows

Each slider gets its own `M:SS` label, centered directly under the track:

| Display | Meaning |
|---|---|
| `1:23` | That resource is falling, and storage will hit zero in 1 minute 23 seconds at the current drain. |
| `0:00` | Storage is already empty while still draining. |
| `9:59` | Time remaining is 10 minutes or more. |
| `-:--` | The bar is not decreasing (income covers expense, or current went up/held this second). |

The labels use the same typeface, size, outline, and colors as the current-amount numbers drawn over the sliders in `gui_top_bar.lua`:

- Metal: Exo2 SemiBold, light grey `{0.95, 0.95, 0.95}`
- Energy: Exo2 SemiBold, pale yellow `{1, 1, 0.74}`

They refresh once per second.

## How drain is measured

Every second the widget reads `Spring.GetTeamResources` for the local (or spectated) team:

- Drain rate = expense − income
- If drain is at or below a tiny epsilon, the bar is treated as not decreasing and the label is `-:--`
- Otherwise time = current / drain, capped at 9 minutes 59 seconds

Display-only. It does not change sharing, conversion, or unit orders.

## Install

Copy the `gui_stall_timer` folder into your BAR widgets directory:

- `data/LuaUI/Widgets/gui_stall_timer/` (user widgets), or
- enable it from the Workshop once published

Then open the widget list with **F11** and enable **Stall Timer**. It depends on the stock **Top Bar** widget.

## Safety

Reads team resource stats and draws two labels. No commands are sent.
