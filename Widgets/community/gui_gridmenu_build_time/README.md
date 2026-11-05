# Grid Menu Build Time

Adds a third cost line to every icon in the grid menu: the unit's **build time**, in green, above the metal (white) and energy (yellow) cost the menu already shows.

The green matches the build time colour in the Unit Stats panel (`I`), so the menu reads the same as `Cost: metal / energy / build time` there.

It works everywhere the grid menu shows build options:

- a constructor or commander picking a building
- a factory picking a unit to produce
- the pregame start build queue

## Details

- Build time is the unit's raw build cost in build power. Seconds to build = build time ÷ total build power working on it (for example, a factory with 100 build power finishes a 3 000 build time unit in 30 seconds).
- It follows the grid menu's **Show prices** setting: on every icon when prices are shown, otherwise only on the icon under the mouse.
- Units the grid menu greys out (restricted or unavailable) get a grey label too.
- Works with the grid menu on the side or docked at the bottom.

## Requirements

Uses the default **Grid menu**. If you switch to the legacy **Build menu**, this widget draws nothing.

It adds labels on top of the grid menu and doesn't change it. If a future grid menu update moves the icons, the labels hide themselves instead of drawing in the wrong place.
