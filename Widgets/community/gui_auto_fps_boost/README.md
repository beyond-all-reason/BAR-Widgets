# Auto FPS Boost

A widget for Beyond All Reason that **automatically reduces graphics effects when your FPS drops**, then restores everything once performance recovers. Built for the big late-game battles where FPS collapses — especially on low-end machines.

Every reduction is measured: the widget lists were built with the in-game Widget Profiler on real 8v8 late-game battles, ordered by actual frame-time cost.

## How it works

The widget samples FPS every second and applies 4 progressive optimization levels (with hysteresis to avoid oscillation):

| Level | Triggered after | Effects |
|-------|-----------------|---------|
| 1 | 3 s below the low threshold | Particles halved (`MaxParticles`, `MaxNanoParticles`) |
| 2 | 3 more seconds below | Units turn into icons sooner (`disticon`), distant wrecks are hidden, expensive widgets disabled (ordered by profiled cost): Picture-in-Picture Minimap, Commands FX, Defense Range GL4, Sensor Ranges Radar/Sonar/Jammer, Contrast Adaptive Sharpen, Decals GL4, Ground AO Plates, Map Edge Extension, Fog Diagonal Lines GL4 |
| 3 | 3 more seconds below | Particles at 25%, icons even sooner, shadows/water/ground detail/decals forced to minimum (if not already), more widgets off: AdvPlayersList (player list disappears), Reclaim Field Highlight, AllyCursors, Airjets GL4, GUI Shader, and Bloom/SSAO/Distortion if they were on |
| 4 | 3 more seconds below | **Survival mode**: particles near zero (200, nano 0), icons almost everywhere, wrecks only up close, Custom Unit Shaders and advanced map shading off (same engine commands as BAR's "lowest" preset), Lups effects engine off, Health Bars GL4, Rank Icons, Orb Effects, Mapmarks FX, Metalspots, Ally Selected Units, Deferred rendering GL4 disabled |

When FPS stays above the high threshold for 10 s, the widget steps back up one level at a time until everything is restored. Original settings are saved at startup and always restored — at recovery, on widget disable, and at game end.

## Usage

- Active by default once installed (visible in the widget list, **F11**).
- `/fpsboost` — toggle the automatic mode (disabling it restores all settings immediately).
- `/fpsboost status` — show/hide a small status window: current FPS, optimization level (green/orange/red stripe), and the FPS gain since the boost triggered.
- `/fpsboost repair` — re-enables every widget from the lists (except ones BAR disables by default); use it if a restore was ever lost (e.g. a crash at the wrong moment).

## Safety

- The widget **never touches a widget you disabled yourself** (it reads the widget selector config at startup).
- Widget disabling is persisted by BAR, so the widget keeps its own persistent restore list: if the game closes or crashes while optimizations are active, everything is re-enabled automatically at the next session (a chat message confirms it).
- Command/UI widgets (build menu, order menu, top bar, minimap...) are never touched.

## Configuration

Thresholds are editable at the top of the file:

```lua
local FPS_LOW      = 45   -- below this FPS: reduce details
local FPS_HIGH     = 70   -- above this FPS: restore details
```

## Manual installation

Copy `gui_auto_fps_boost.lua` into the `data/LuaUI/Widgets/` folder of your Beyond All Reason installation.
