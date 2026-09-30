# Changelog

## 1.2.1

### Fixed

- The install docs still told people to add `{ "id": "robbie.power-menu" }` to
  `shell.json` by hand, which made a one-command install look like it needed a
  second step. It never did: `omarchy plugin add --enable` places the widget in
  the bar's **right** section on its own, because `barWidget.defaultSection`
  says `right`. Verified by disabling the widget and re-enabling it with no
  section flag — it returned to `right`. The README now says so, and gives the
  one-line recovery command for when the widget is removed on purpose.

## 1.2.0

### Changed

- **Install is a single command.** The panel used to shell out to
  `~/.config/omarchy/bar/scripts/{reboot,shutdown}-timer`, which meant a manual
  `mkdir` + `install` step after every fresh `omarchy plugin add`. Those scripts
  are committed mode `755` and now run from `bin/` inside the plugin directory,
  so `omarchy plugin add <url> --enable` is the whole install and
  `omarchy plugin remove` leaves nothing behind.
- The plugin derives its own directory from `Qt.resolvedUrl` instead of
  hardcoding `~/.config/omarchy/plugins/robbie.power-menu`. It no longer has to
  assume where it was cloned to, which also fixes a latent bug: `add-to-omarchy-menu`
  was hardcoded to that path in five places, so a `omarchy plugin clone` or a
  manual relocation would have broken the "Show in Omarchy Menu" action.

### Added

- Shell-quoting for every path that reaches `bash -lc`, so a plugin directory
  containing spaces no longer splits the command.
- `pluginDir` percent-decodes its own URL and falls back to the raw path if the
  directory name contains a `%` that is not a valid escape, which
  `decodeURIComponent` would otherwise throw on.

### Internal

- Timer invocations go through one `timerCommand(id, verb, seconds)` helper
  instead of concatenating paths and verbs at each of the seven call sites, and
  `currentTimerId` replaces the same `timerKind === "reboot" ? ...` ternary
  repeated three times.
- Dropped the now-unused `expandPath()`; no path is `~`-prefixed any more.

### Note

- The shared copies in `~/.config/omarchy/bar/scripts/` were left in place: the
  `robbie.shutdown-timer` and `robbie.menu` plugins still call them. They are no
  longer used by this plugin.

## 1.1.0

### Added

- **Armed timer rows pulse in the action lists.** A Reboot Timer or Shutdown
  Timer row now breathes between its resting text colour and `flashColor`
  whenever it is armed, in both the bar dropdown and the centred menu card.
  The row's label, countdown and cancel affordance all pulse together, and they
  ride the exact same animation as the bar button, so the lists and the icon
  flash in lockstep.
- **Caffeinate is a steady brown.** An active Caffeinate row no longer borrows
  the urgent red used by the session-ending rows. It holds a calm brown
  (`caffeineColor`) in both layouts.
- **The bar button goes brown too.** While Caffeinate is on and no timer is
  armed, the bar icon and its pill adopt the same brown, so the whole widget
  reads as one state rather than a green pill behind a brown glyph.

### Changed

- A pending timer deliberately outranks Caffeinate for the bar button's colour:
  that state is urgent and already animated, so it keeps pulsing accent to
  `flashColor` instead of turning brown. Caffeinate brown applies to the resting
  state only.
- The bar pill's fill and border are now bound to a single pulsed colour at two
  opacities rather than each recomputing the mix, so they cannot drift out of
  step mid-pulse.
- The armed-timer pulse has one definition, `timerAlert(base)`, shared by the
  dropdown row, the centred row and the bar button. Each caller passes the
  resting colour for its own surface, which is why the two layouts pulse
  correctly against their different backgrounds.

### Removed

- The last-ten-minutes red escalation for timer rows (`criticalPulse`,
  `anyCritical`, `rowTimerCritical()`, `currentTimerCritical()` and its
  `SequentialAnimation`). Rows now flash for the whole time a timer is armed
  rather than only in its final ten minutes, which is what the bar icon has
  always done. Nothing referenced these after the change.

### Fixed

- Reboot Timer rows in the dropdown showed no name and no countdown while a
  timer was armed. The menu-format rows already rendered a label, a live
  countdown and a cancel affordance; the dropdown now matches, and the two
  layouts stay in agreement afterwards.

### Internal

- Dropped dead code: `armedFor()`, `targetFor()`, `remainingFor()` and
  `rowKind()` were each called once with the same argument and are now inlined
  into `timerTick()`; `rowDanger`, the dropdown's `timerRowRemaining` and
  `fireTimeLabel()` were unreferenced and are gone.
- `add-to-omarchy-menu` wrote its IPC failure log to a path left over from an
  interactive session. It now uses `/tmp/omarchy-power-menu-ipc.log`.
