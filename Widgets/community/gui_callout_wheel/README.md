# Callout Wheel

Alt+F ping wheel. Looks at nearby units/wrecks and sends allies a system chat line plus a custom map mark.

Based on [Errrrrrr's Ping Wheel](https://github.com/SSJGabraham/Ping-Wheel) / [zxbc](https://github.com/zxbc/BAR_widgets).

## Usage

- Hold **Alt+F**, LMB for a command. Quick tap on the hub is **Look here**; holding LMB opens the wheel without sending that ping.
- Click top-bar **metal** / **energy** to ask for that resource.
- Mouse 4 = command wheel. Mouse 5 = messages if `enable_ping_messages` is true.
- More than 8 callouts in 6 seconds mutes you for 15 seconds.
- Custom bind: `custom_keybind_mode = true`, action `ping_wheel_on`.
- `backward_compat_pings` is off: no extra engine ping for people without the widget.
- All player-facing text is in the `L` table at the top of `gui_callout_wheel.lua`.

## Commands

| Ping      | What it announces                                                                                       |
| --------- | ------------------------------------------------------------------------------------------------------- |
| Danger    | Friendly things are _in danger_; enemy things are _dangerous_                                           |
| On my way | Coming to help friendlies, or moving on an enemy                                                        |
| Assist me | Help at a friendly target, or help pushing an enemy. Unfinished building: help building. Wreck: reclaim |
| Defend    | Defend a building, protect a unit, or defend empty ground                                               |
| Look here | Names the nearby unit, or reclaim on a wreck                                                            |

Look here on an allied nuke silo reports stockpile / time remaining.
