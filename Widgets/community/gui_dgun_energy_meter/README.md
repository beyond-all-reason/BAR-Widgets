# D-Gun Energy Meter

A small gas-tank-shaped meter that appears next to your commander whenever
its D-Gun (Disintegrator) is armed.

Select your commander and press **D** to bring up the D-Gun crosshair -- the
meter appears and fills toward the shot's exact energy cost:

- **Red** -- you can't afford to fire yet.
- **Amber** -- over halfway there.
- **Green** -- fully charged and ready to fire.

Once you actually queue a shot (click a target), the tank plays a pulsing
glow, a traveling scanline, and crackling lightning around it so it's
obvious a shot is charging, not just sitting idle. It stays on screen while
you're still selected and short on energy (the moment you most need the
warning), and fades out over a few seconds once you're topped up, fire, or
deselect.

## Why

The stock game gives no feedback on D-Gun energy cost versus your current
stockpile -- you either guess, or watch the resource bar and do the math
yourself. This puts the answer right next to the unit that needs it.

## Notes

- Only tracks your own commander(s) -- "can I afford this" only means
  anything for units you actually control.
- Works with any commander/D-Gun combination the engine reports a
  `manualFire` weapon and `energyCost` for, not a hardcoded unit list.
- Size is adjustable via two variables near the top of the file
  (`userBarWidthPercent` / `userBarHeightPercent`, 0-100).
- No external assets or dependencies -- pure Lua/OpenGL, drawn each frame.

## Install

Drop `gui_dgun_energy_meter.lua` into your `LuaUI/Widgets/` folder and
enable it from the in-game widget list (or via BAR's Plugins tab, once
installed from there).

## License

GPL
