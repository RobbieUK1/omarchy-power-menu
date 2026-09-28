# Power Menu

A power button in the Omarchy shell bar that opens a dropdown of session
actions, instead of making you hunt through a menu for Lock or Reboot.

## Actions

| Action              | Notes                                                     |
|---------------------|-----------------------------------------------------------|
| Lock                |                                                            |
| Suspend             | `systemctl suspend`                                        |
| Hibernate           | Only offered when the machine actually supports it        |
| Logout              | Destructive, needs a second click                         |
| Reboot              | Destructive, needs a second click                         |
| Shutdown            | Destructive, needs a second click                         |
| Reboot Timer        | Arms a scheduled reboot with a live countdown             |
| Shutdown Timer      | Arms a scheduled shutdown with a live countdown            |
| Update System       | Opens a terminal running `omarchy-update`                 |
| Restart Shell       | Restarts the status bar                                    |
| System Activity     | `bpytop` or `btop`, whichever is installed                |
| Caffeinate          | Toggle; prevents sleep and screen blanking                |
| Screen Saver        |                                                            |
| Show in Omarchy Menu| Adds this widget and its actions to the launch menu       |

Actions can be hidden and reordered from the panel's settings. Destructive ones
ask for a second click to confirm, and the confirm window is configurable
(`confirmSeconds`, default 5, clamped to 2-30).

## Requirements

- Omarchy shell
- `systemd` with user-level transient timers, for the Reboot/Shutdown Timer rows

## Install

```sh
omarchy plugin add https://github.com/RobbieUK1/omarchy-power-menu.git --enable
omarchy restart shell
```

The two timer actions shell out to helper scripts that ship in `bin/` but have
to live outside the plugin directory:

```sh
mkdir -p ~/.config/omarchy/bar/scripts
install -m 755 bin/reboot-timer   ~/.config/omarchy/bar/scripts/reboot-timer
install -m 755 bin/shutdown-timer ~/.config/omarchy/bar/scripts/shutdown-timer
```

Then right-click your bar -> **Configure bar** (or edit
`~/.config/omarchy/shell.json`) and add the widget to a section:

```json
"right": [
  { "id": "robbie.power-menu" }
]
```

## How it works

The widget is the source of truth for which actions exist. It exposes them over
`omarchy-shell robbie.power-menu menuItems`, and `add-to-omarchy-menu` reads
that answer to keep `~/.config/omarchy/extensions/omarchy-menu.jsonc` in sync.

That script is deliberately conservative:

- It only ever adds rows the **default** menu does not already define, so
  `system.lock`, `system.suspend` and friends are never rewritten.
- It only ever removes rows **it** added (tracked by key), so hand-written menu
  entries survive.
- Stale pruning only runs when the live widget answered over IPC, so a brief
  IPC hiccup can never delete your menu.
- If the IPC call fails it falls back to a static palette, so the script still
  works standalone.

```sh
./add-to-omarchy-menu          # ensure present (default)
./add-to-omarchy-menu remove   # undo
./add-to-omarchy-menu status   # prints 1 if present, 0 if not
```

Both timer actions schedule `omarchy-system-reboot` / `omarchy-system-shutdown`
on transient user timers with stable unit names, so an armed timer survives a
shell restart and can be cancelled from any later session.

`CenterableKeyboardPanel.qml` is a variant of the stock panel that can be
centred on screen, used where a bottom-anchored dropdown would sit awkwardly.

## License

MIT
