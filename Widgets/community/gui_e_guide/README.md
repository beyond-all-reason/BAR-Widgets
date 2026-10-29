# Energy Guide (`gui_e_guide`)

A tiny, draggable mini-panel that answers one question at a glance:
**which energy building is worth building on this map, for my faction?**

Wind, solar, tidal and geothermal in tier 1; advanced solar, fusion, advanced fusion and advanced geothermal in tier 2. Each one shows its real build picture, its **E/s**, and a gold star on the best pick of the tier.

## What it shows

| Element | Meaning |
|---|---|
| Header `WIND a-b` | The map's minimum and maximum wind |
| Big number | Average E/s per building on **this** map |
| `E/s` line | Unit; wind adds the live value (`now x`), geo adds the vent count (`x3`) |
| `0.13/M` (teal) | E/s per metal of build cost |
| `0.029/M+E` (violet) | E/s per total initial price (metal + energy) |
| Two thin bars | Each metric relative to the best of the tier |
| Gold border and star | Best in tier: highest mean of the two relative efficiencies |
| Faction chip (`ARM`/`COR`/`LEG`) | Faction whose buildings are shown |
| `T2` chip | Show or hide the tier 2 row |

Tidal only appears on maps with water, and geothermal only when the map has vents. Hover any card for a tooltip with name, output, cost, build time and efficiency.

## Controls

- **Drag** anywhere on the panel to move it
- **Mouse wheel** over the panel to resize it
- **Click the faction chip** to preview another faction (cycles auto, Armada, Cortex, Legion)
- **Click the `T2` chip** to collapse or expand tier 2

Position, size, tier-2 visibility and faction override are remembered between games.

## How it works

- Wind range and tidal strength come from the map (`Game.windMin`, `Game.windMax`, `Game.tidal`); live wind from `Spring.GetWind`.
- Average wind is the midpoint of min and max, which is an approximation of the engine's wind behaviour.
- E/s, metal cost, energy cost and build time are read from `UnitDefs` at runtime, so the panel follows balance changes and per-faction differences without hard-coded numbers.
- The faction is detected from your team's start unit (or side). Spectators see the faction of the team they are assigned to; use the chip to preview others.
- Ranking uses two efficiencies, E/s per metal and E/s per (metal + energy) of initial cost. Each is scaled to the best of its tier and the two are averaged; the highest mean is the starred pick. No metal/energy exchange rate is assumed.

## Notes

Only the energy sources listed in the `CATALOG` table at the top of `gui_e_guide.lua` are shown. Names missing from the running game are skipped automatically.
