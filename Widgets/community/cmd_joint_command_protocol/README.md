# Joint Command Protocol

Joint Command Protocol is a tournament-focused Beyond All Reason widget for coordinated allied teams. In its default tournament configuration, it automatically transfers newly completed whitelisted units to the player's allied teammate.

## Intended use

This widget was created for a dedicated tournament game mode, primarily a 2v2 format with one allied teammate. It is not intended for normal matchmaking or general-purpose gameplay.

The widget is intentionally **enabled by default**. Players should only install or enable it when participating in the tournament format that requires it.

## Default behaviour

- The widget starts enabled.
- `SHARE_ALL_UNITS_TO_ALLY` is enabled by default.
- When a unit on the internal whitelist finishes construction, the widget transfers that unit to the only other team in the player's ally team.
- Units not present in the whitelist are never transferred automatically.
- Spectators are ignored and the widget removes itself while spectating.
- Transfers are processed immediately after `UnitFinished`; there is no batching system.
- The widget does not suppress unit-sharing or console messages.

## Whitelisted units

The exact whitelist is defined in `shareWhitelist` inside `cmd_joint_command_protocol.lua`. It contains the tournament-approved mobile combat and support units that may be transferred automatically.

Commanders, factories, static buildings, and any other units not explicitly included in that table are not auto-shared.

## Optional per-factory mode

The widget also contains an optional factory-recipient interface. To use that mode, change:

```lua
local SHARE_ALL_UNITS_TO_ALLY = true
```

to:

```lua
local SHARE_ALL_UNITS_TO_ALLY = false
```

With that alternate mode enabled, select one or more factories and use the **Auto Give To** action-bar command to choose which build options should be transferred and which allied team should receive them.

The public tournament configuration leaves `SHARE_ALL_UNITS_TO_ALLY` set to `true`.

## Text commands

The widget accepts the following commands:

```text
/luaui unitshare on
/luaui unitshare off
/luaui unitshare announce
/luaui unitshare list
/luaui unitshare add <unit> <player-or-teamID> [more targets]
/luaui unitshare remove <unit>
/luaui unitshare clear
```

### Command details

- `on` / `off` enables or disables sharing for the current game.
- `announce` toggles local confirmation messages after successful transfers.
- `list` displays the current runtime unit rules.
- `add` adds or replaces a runtime rule for a unit type.
- `remove` removes a runtime rule for one unit type.
- `clear` removes all runtime rules.

By default, `USE_SAVED_RUNTIME_RULES` is `false`, so runtime rules are not loaded from previous games. The tournament auto-share whitelist remains the primary behaviour.

## Tournament assumptions

The default `ALLY` target resolves to the first other team in the player's ally team. The tournament configuration therefore assumes:

- A 2v2 team format.
- Exactly one allied teammate per player.
- Both teammates knowingly use the tournament ruleset.
- Players enable or install the widget specifically for that event.

It should not be used unchanged in formats where a player has multiple allied teams, because the `ALLY` shortcut is designed for one teammate.

## Installation

Once approved, install and enable Joint Command Protocol through the BAR community widget system for the relevant tournament games.

For local testing, place `cmd_joint_command_protocol.lua` in the appropriate BAR LuaUI Widgets directory and reload LuaUI.

## Source

Development source: <https://github.com/Kiwi-Vdb/JCP>

## License

GNU General Public License, version 2 or later.
