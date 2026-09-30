# Changelog

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
