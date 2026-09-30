import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A power button in the bar. Opens a dropdown with the session actions:
// Lock, Suspend, Hibernate (only when the machine supports it), Logout,
// Reboot, Shutdown, Update System and Screen Saver (starts the screensaver).
//
// The three session-ending actions — Logout, Reboot, Shutdown — are armed:
// the first click highlights the row and restates the consequence, the
// second click (within a few seconds) runs it. Esc or another click on a
// different row disarms, so a stray press is never followed by a stray
// reboot.
//
// "Shutdown Timer" and "Reboot Timer" switch the same dropdown to a timer view
// (Esc/Back to return) that arms a scheduled shutdown or reboot via
// bin/shutdown-timer / bin/reboot-timer in this plugin's own directory and
// shows a live countdown with a cancel option. Both views share the transient
// user units omarchy-shutdown-timer.timer / omarchy-reboot-timer.timer, so the
// standalone timer widgets and the menu can arm and cancel the same schedules.
//
// "Caffeinate" toggles omarchy-toggle-idle (prevent sleep / screen blanking)
// and stays open so the active state is visible; it is refreshed whenever the
// panel opens.
//
// A Settings view lets the user show/hide and reorder buttons via toggle
// switches and up/down arrows. Settings are persisted to a JSON file in
// ~/.local/state/omarchy/settings/power-menu.json.
Panel {
  id: root
  moduleName: "robbie.power-menu"
  ipcTarget: "robbie.power-menu"
  manageIpc: false

  readonly property int confirmSeconds: Math.max(2, Math.min(30, Number(setting("confirmSeconds", 5)) || 5))

  // When true (set by the Omarchy-menu openCenter IPC call), the panel is
  // centered on the screen instead of anchored to the bar button.
  property bool centered: false

  property string view: "actions"
  property var actions: []
  property int cursorIndex: 0
  property string armedId: ""
  property bool suspendAvailable: true
  property bool hibernateAvailable: false
  property bool timerCustom: false
  property string timerCustomError: ""
  readonly property int yearSeconds: 31536000
  property string timerKind: "shutdown"
  property bool caffeinated: false

  property bool timerArmed: false
  property int timerTarget: 0
  property int timerRemaining: 0
  property var timerRows: []
  property int timerCursor: 0
  property real powerPulse: 0.0

  property bool shutdownArmed: false
  property int shutdownTarget: 0
  property int shutdownRemaining: 0
  property bool rebootArmed: false
  property int rebootTarget: 0
  property int rebootRemaining: 0

  readonly property bool anyTimer: root.shutdownArmed || root.rebootArmed

  // Whether the power widget is currently listed in the Omarchy launch menu.
  property bool inOmarchyMenu: false
  property bool menuBusy: false

  // --- Settings state ---
  property var settingsOrder: []
  property var settingsHidden: ({})
  property var settingsRows: []
  property int settingsCursor: 0
  property bool settingsDirty: false
  property int settingsDragIndex: -1
  property int settingsDropIndex: -1
  property var settingsBaseY: []

  readonly property var timerPresets: [
    { seconds: 600, label: "10 minutes" },
    { seconds: 900, label: "15 minutes" },
    { seconds: 1800, label: "30 minutes" },
    { seconds: 3600, label: "1 hour" }
  ]

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color flashColor: root.rebootArmed && !root.shutdownArmed ? "#ffd24a" : "#e5484d"
  readonly property color caffeineColor: "#a2734b"
  // Caffeinate claims the bar button's resting tint as well, so the icon, its
  // pill and the menu row all read brown while it is on. A pending timer still
  // wins, because that state pulses toward flashColor.
  readonly property color barAccent: root.caffeinated && !root.anyTimer ? root.caffeineColor : root.accent

  // Single definition of the armed-timer pulse, shared by the bar dropdown and
  // the centered card: a row breathes from its own resting text color toward
  // flashColor, so both row styles flash in lockstep with the bar button.
  function timerAlert(base) {
    return root.mixColor(base, root.flashColor, root.powerPulse)
  }

  // --- Omarchy launch-menu palette (used when the panel is opened centered
  // from the launch menu so it matches the menu's own format exactly) ---
  readonly property color menuBackground: Color.menu.background
  readonly property color menuText: Color.menu.text
  readonly property color menuScrim: Color.menu.scrim
  readonly property string menuFontFamily: Style.font.menuFamily
  readonly property var menuBorderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property var menuSelectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)
  readonly property int menuRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  readonly property int menuHeaderHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int menuRowSpacing: Style.spacing.xs
  readonly property int menuContentSpacing: Style.spacing.md
  readonly property int menuCardWidth: Math.min(Style.space(300), panel.screenW > 0 ? panel.screenW - Style.gapsOut * 2 : Style.space(300))
  property var menuRows: []

  readonly property var masterActionOrder: [
    "lock", "suspend", "logout", "reboot", "shutdown",
    "reboot-timer", "shutdown-timer",
    "update", "restart-shell", "btop", "caffeinate",
    "screensaver", "add-to-menu"
  ]

  // --- Settings functions ---

  // Normalize the persisted order so it always contains every possible action
  // exactly once: saved order first, then any new actions appended in their
  // canonical order. Guarantees the settings list shows all buttons even on
  // the very first run when no settings file exists yet.
  function normalizeOrder(order) {
    var source = order instanceof Array ? order.slice() : []
    var seen = {}
    var merged = []
    for (var i = 0; i < source.length; i++) {
      if (!seen[source[i]]) { seen[source[i]] = true; merged.push(source[i]) }
    }
    for (var j = 0; j < root.masterActionOrder.length; j++) {
      var id = root.masterActionOrder[j]
      if (!seen[id]) { seen[id] = true; merged.push(id) }
    }
    return merged
  }

  function loadSettings(raw) {
    var data = {}
    try { data = JSON.parse(raw) } catch (e) { data = {} }
    root.settingsOrder = root.normalizeOrder(data.order)
    root.settingsHidden = (data.hidden && typeof data.hidden === "object") ? data.hidden : {}
    root.settingsDirty = false
    root.rebuild()
  }

  function saveSettings() {
    var data = {
      order: root.settingsOrder.slice(),
      hidden: {}
    }
    for (var key in root.settingsHidden) {
      if (root.settingsHidden[key]) data.hidden[key] = true
    }
    settingsFile.setText(JSON.stringify(data, null, 2) + "\n")
    root.settingsDirty = false
    root.syncMenuEntries()
  }

  function toggleSettingsAction(id) {
    var next = {}
    for (var k in root.settingsHidden) next[k] = root.settingsHidden[k]
    if (next[id]) delete next[id]
    else next[id] = true
    root.settingsHidden = next
    root.settingsDirty = true
    root.rebuild()
    // Persist and mirror into the launch menu immediately, so a show/hide
    // toggle takes effect as soon as the menu is summoned again - no waiting
    // for a save on view switch or panel close.
    root.saveSettings()
  }

  // Routes a settings-row interaction: the Omarchy-menu entry toggles via the
  // widget management script, every other row is a show/hide toggle switch.
  function toggleSettingsRow(action) {
    if (!action) return
    if (action.menuToggle) root.toggleMenuEntry()
    else if (!action.settingsOnly) root.toggleSettingsAction(action.id)
  }

  function settingsItemAt(index) {
    if (index < 0 || index >= root.settingsOrder.length) return null
    var id = root.settingsOrder[index]
    var allActions = buildAllActions()
    for (var i = 0; i < allActions.length; i++) {
      if (allActions[i].id === id) return allActions[i]
    }
    return null
  }

  // Action objects for every settings row, used as the model for the
  // menu-styled (centered) settings list so rows look identical to the
  // actions menu.
  function buildSettingsRows() {
    var rows = []
    for (var i = 0; i < root.settingsOrder.length; i++) {
      var a = root.settingsItemAt(i)
      if (a) rows.push(a)
    }
    return rows
  }

  // The settings Repeater that is currently visible: the menu-styled one
  // when opened centered from the launch menu, the bar dropdown one otherwise.
  function activeSettingsRepeater() {
    return root.centered ? settingsMenuRepeater : settingsRepeater
  }

  function isSettingsHidden(id) {
    return !!root.settingsHidden[id]
  }

  // Records each settings row's base (Column-laid) position at drag start.
  function beginSettingsDrag(index) {
    root.settingsDragIndex = index
    root.settingsDropIndex = index
    root.settingsCursor = index
    root.settingsBaseY = []
    var rep = root.activeSettingsRepeater()
    for (var i = 0; i < rep.count; i++) root.settingsBaseY[i] = rep.itemAt(i).y
  }

  // Slides the non-source rows out of the way to open a gap at `newIndex`.
  function updateSettingsDrop(newIndex, step) {
    if (root.settingsDropIndex === newIndex) return
    root.settingsDropIndex = newIndex
    var from = root.settingsDragIndex
    var rep = root.activeSettingsRepeater()
    for (var i = 0; i < rep.count; i++) {
      if (i === from) continue
      var shift = 0
      if (newIndex > from && i > from && i <= newIndex) shift = -step
      else if (newIndex < from && i >= newIndex && i < from) shift = step
      var slot = rep.itemAt(i)
      slot.y = (root.settingsBaseY.length > i ? root.settingsBaseY[i] : 0) + shift
    }
  }

  // Restores every row to its base position and optionally commits the drop.
  function endSettingsDrag(commit) {
    var from = root.settingsDragIndex
    var to = root.settingsDropIndex
    var rep = root.activeSettingsRepeater()
    for (var i = 0; i < rep.count; i++) {
      rep.itemAt(i).y = root.settingsBaseY.length > i ? root.settingsBaseY[i] : 0
    }
    root.settingsBaseY = []
    root.settingsDragIndex = -1
    root.settingsDropIndex = -1
    if (commit && from >= 0 && to >= 0 && from < root.settingsOrder.length && to < root.settingsOrder.length) {
      root.reorderSettings(from, to)
    }
  }

  // Move the action at `from` to the position of `to` (insertion semantics).
  function reorderSettings(from, to) {
    if (from === to || from < 0 || to < 0 || from >= root.settingsOrder.length || to >= root.settingsOrder.length) return
    var arr = root.settingsOrder.slice()
    var item = arr[from]
    arr.splice(from, 1)
    arr.splice(to, 0, item)
    root.settingsOrder = arr
    root.settingsCursor = to
    root.settingsDirty = true
    root.rebuild()
  }

  function toggleSettingsView() {
    if (root.view === "settings") {
      root.view = "actions"
      if (root.settingsDirty) root.saveSettings()
      root.settingsCursor = 0
      root.cursorIndex = 0
    } else {
      if (root.settingsDirty) root.saveSettings()
      root.view = "settings"
      root.disarm()
      if (root.settingsCursor >= root.settingsOrder.length)
        root.settingsCursor = Math.max(0, root.settingsOrder.length - 1)
    }
  }

  function buildAllActions() {
    return [
      { id: "lock", icon: "\uf023", label: "Lock", hint: "Lock the screen", command: ["omarchy-system-lock"], dangerous: false },
      { id: "suspend", icon: "\uf186", label: "Suspend", hint: "Sleep the computer", command: ["systemctl", "suspend"], dangerous: false },
      { id: "logout", icon: "\uf08b", label: "Logout", hint: "End this session", command: ["omarchy-system-logout"], dangerous: true },
      { id: "reboot", icon: "\uf01e", label: "Reboot", hint: "Restart the computer", command: ["omarchy-system-reboot"], dangerous: true },
      { id: "shutdown", icon: "\uf011", label: "Shutdown", hint: "Power off the computer", command: ["omarchy-system-shutdown"], dangerous: true },
      { id: "reboot-timer", icon: "\uf253", label: "Reboot Timer", hint: "Schedule a reboot in a few minutes to hours", command: [], dangerous: false },
      { id: "shutdown-timer", icon: "\uf017", label: "Shutdown Timer", hint: "Schedule a shutdown in a few minutes to hours", command: [], dangerous: false },
      { id: "update", icon: "\uf021", label: "Update System", hint: "Update Omarchy and system packages", command: ["omarchy-launch-terminal", "omarchy-update"], dangerous: false },
      { id: "restart-shell", icon: "\uf085", label: "Restart Shell", hint: "Restart the status bar", command: ["omarchy", "restart", "shell"], dangerous: false },
      { id: "btop", icon: "\uf120", label: "System Activity", hint: "Open the system monitor", command: root.btopCommand(), dangerous: false },
      { id: "caffeinate", icon: "\uf0f4", label: "Caffeinate", hint: "Prevent sleep and screen blanking", command: ["omarchy-toggle-idle", "toggle"], dangerous: false },
      { id: "screensaver", icon: "\uf108", label: "Screen Saver", hint: "Start the screen saver now", command: ["omarchy-launch-screensaver"], dangerous: false },
      { id: "add-to-menu", icon: "\uf0fe", label: "Show in Omarchy Menu", hint: "Add or remove this widget from the launch menu", command: [], dangerous: false, settingsOnly: true, menuToggle: true }
    ]
  }

  function buildActions() {
    var allActions = buildAllActions()
    var allById = {}
    for (var i = 0; i < allActions.length; i++) allById[allActions[i].id] = allActions[i]

    var list = []
    for (var j = 0; j < root.settingsOrder.length; j++) {
      var id = root.settingsOrder[j]
      if (allById[id] && !allById[id].settingsOnly && !root.isSettingsHidden(id)) list.push(allById[id])
    }
    for (var k = 0; k < allActions.length; k++) {
      if (!allActions[k].settingsOnly && !root.settingsHidden[allActions[k].id]) {
        var found = false
        for (var m = 0; m < list.length; m++) {
          if (list[m].id === allActions[k].id) { found = true; break }
        }
        if (!found) list.push(allActions[k])
      }
    }
    return list
  }

  function refreshAvailability() {
    if (!availProc.running) availProc.running = true
  }

  function refreshCaffeine() {
    if (!caffStatusProc.running) caffStatusProc.running = true
  }

  // Optimistically flips the local state so the row reacts instantly to a
  // click anywhere on it, then toggles the daemon and reconciles with the
  // real status once it reports back.
  function toggleCaffeine() {
    root.caffeinated = !root.caffeinated
    Quickshell.execDetached(["omarchy-toggle-idle", "toggle"])
    root.refreshCaffeine()
  }

  function applyCaffeineStatus(raw) {
    var data = {}
    try { data = JSON.parse(raw) } catch (e) { data = {} }
    var was = root.caffeinated
    root.caffeinated = !!data.enabled
    if (was !== root.caffeinated) root.rebuild()
  }

  function refreshMenuStatus() {
    if (!menuStatusProc.running) menuStatusProc.running = true
  }

  function applyMenuStatus(raw) {
    root.inOmarchyMenu = String(raw || "").trim() === "1"
    root.menuBusy = false
  }

  // Adds or removes the widget from the Omarchy launch menu depending on its
  // current presence, then reconciles the toggle with the real result.
  function toggleMenuEntry() {
    if (root.menuBusy) return
    root.menuBusy = true
    menuToggleProc.command = ["bash", "-lc", root.shellQuote(root.scriptPath("add-to-omarchy-menu")) + (root.inOmarchyMenu ? " remove" : " add")]
    if (!menuToggleProc.running) menuToggleProc.running = true
  }

  // The shell command a dropdown row should run when invoked from the Omarchy
  // launch menu. Rows without a drop-in command (the timers) open this panel
  // directly onto their view instead, so the menu never dead-ends.
  function menuActionString(action) {
    var id = action ? String(action.id) : ""
    var direct = {
      "lock": "omarchy-system-lock",
      "suspend": "systemctl suspend",
      "hibernate": "systemctl hibernate",
      "logout": "omarchy-system-logout",
      "reboot": "omarchy-system-reboot",
      "shutdown": "omarchy-system-shutdown",
      "update": "omarchy-launch-terminal omarchy-update",
      "restart-shell": "omarchy restart shell",
      "caffeinate": "omarchy-toggle-idle toggle",
      "screensaver": "omarchy-launch-screensaver",
      "shutdown-timer": "omarchy-shell robbie.power-menu openShutdownTimer",
      "reboot-timer": "omarchy-shell robbie.power-menu openRebootTimer"
    }
    if (id === "btop") {
      var argv = root.btopCommand()
      return "bash -lc " + Util.shellQuote(String(argv[2] || ""))
    }
    return direct[id] || ""
  }

  // Keeps the launch-menu rows in step with which buttons are enabled in the
  // dropdown (settings hides/reorders or machine availability). Only fires when
  // the widget is actually listed in the menu, so it never writes otherwise.
  function syncMenuEntries() {
    if (!root.inOmarchyMenu) return
    if (menuSyncProc.running) return
    menuSyncProc.command = ["bash", "-lc", root.shellQuote(root.scriptPath("add-to-omarchy-menu")) + " add"]
    menuSyncProc.running = true
  }

  // Mirrors the ilyazar.btop tray widget's launch so the menu opens the same
  // monitor instance. Prefers bpytop when installed; btop is the fallback.
  // bpytop cannot take btop's --config, so the runtime config is only passed
  // when launching btop (feeding it to bpytop makes it error out and the
  // terminal would close immediately).
  function btopCommand() {
    return ["bash", "-lc",
      "if command -v bpytop >/dev/null 2>&1; then app=\"bpytop\"; else app=\"btop\"; fi; " +
      "cfg=\"$XDG_RUNTIME_DIR/ilyazar-btop.conf\"; " +
      "cmd=(\"omarchy-launch-or-focus-tui\" \"--app-id=org.omarchy.btop\" \"$app\"); " +
      "if [[ \"$app\" == \"btop\" && -f \"$cfg\" ]]; then cmd+=(\"--config\" \"$cfg\"); fi; " +
      "exec \"${cmd[@]}\""]
  }

  function applyAvailability(raw) {
    var flags = String(raw || "")
    root.suspendAvailable = flags.indexOf("S") >= 0
    root.hibernateAvailable = flags.indexOf("h") >= 0
    root.rebuild()
    root.syncMenuEntries()
  }

  function rebuild() {
    var previous = root.armedId
    root.actions = root.buildActions()
    root.menuRows = root.buildMenuRows()
    root.settingsRows = root.buildSettingsRows()
    var count = root.centered ? root.menuRows.length : root.actions.length
    if (root.cursorIndex >= count) root.cursorIndex = Math.max(0, count - 1)
    if (previous !== "" && !root.hasId(previous)) root.disarm()
  }

  // The menu-format list: every visible action in the settings order, plus a
  // Settings entry. Only rendered when the panel is opened centered as the
  // launch menu.
  function buildMenuRows() {
    var rows = []
    for (var i = 0; i < root.actions.length; i++) rows.push(root.actions[i])
    rows.push({
      id: "settings-entry", icon: "\uf013", label: "Customize Buttons",
      hint: "Show, hide and reorder buttons", command: [], dangerous: false,
      settingsEntry: true
    })
    return rows
  }

  function hasId(id) {
    for (var i = 0; i < root.actions.length; i++) if (root.actions[i].id === id) return true
    return false
  }

  function currentAction() {
    var rows = root.centered ? root.menuRows : root.actions
    return (root.cursorIndex >= 0 && root.cursorIndex < rows.length) ? rows[root.cursorIndex] : null
  }

  function moveCursor(step) {
    var count = root.centered ? root.menuRows.length : root.actions.length
    if (count === 0) return
    root.disarm()
    root.cursorIndex = Math.max(0, Math.min(count - 1, root.cursorIndex + step))
  }

  // First press on a destructive action arms it; the second press runs it.
  function activate(action) {
    if (!action) return
    if (root.centered && action.settingsEntry) {
      root.toggleSettingsView()
      return
    }
    if (action.id === "shutdown-timer") {
      root.openTimer("shutdown")
      return
    }
    if (action.id === "reboot-timer") {
      root.openTimer("reboot")
      return
    }
    if (action.id === "caffeinate") {
      root.toggleCaffeine()
      return
    }
    if (action.dangerous && root.armedId !== action.id) {
      root.arm(action.id)
      return
    }
    root.disarm()
    Quickshell.execDetached(action.command)
    root.close()
  }

  function clickIndex(index) {
    var rows = root.centered ? root.menuRows : root.actions
    if (index < 0 || index >= rows.length) return
    root.cursorIndex = index
    root.activate(rows[index])
  }

  function arm(id) {
    root.armedId = id
    armTimer.restart()
  }

  function disarm() {
    root.armedId = ""
    armTimer.stop()
  }

  // Linear color mix for the armed-timer pulse (accent -> yellow/red).
  function mixColor(a, b, t) {
    t = Math.max(0, Math.min(1, Number(t) || 0))
    return Qt.rgba(
      a.r + (b.r - a.r) * t,
      a.g + (b.g - a.g) * t,
      a.b + (b.b - a.b) * t,
      a.a + (b.a - a.a) * t)
  }

  // ---- shutdown timer ----

  // The helper scripts and the menu-sync script live in this plugin's own
  // directory, so `omarchy plugin add --enable` is the whole install. Deriving
  // the directory from this file's own URL keeps the plugin self-contained: it
  // never has to guess where it was cloned to, and it never writes outside
  // itself. Qt.resolvedUrl resolves relative to Panel.qml.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    var p = u.replace(/^file:\/\//, "").replace(/\/+$/, "")
    // A directory name may legitimately contain a '%' that is not an escape
    // sequence, which decodeURIComponent rejects; fall back to the raw form.
    try { return decodeURIComponent(p) } catch (e) { return p }
  }

  // Paths reach the shell through `bash -lc`, so they must survive spaces.
  function shellQuote(p) {
    return "'" + String(p).replace(/'/g, "'\\''") + "'"
  }

  function scriptPath(name) {
    return root.pluginDir + "/" + name
  }

  function timerScriptById(id) {
    return root.scriptPath("bin/" + (id === "reboot-timer" ? "reboot-timer" : "shutdown-timer"))
  }

  // Every timer invocation goes through here, so the quoting and the verb live
  // in one place instead of at each call site.
  function timerCommand(id, verb, seconds) {
    var cmd = root.shellQuote(root.timerScriptById(id)) + " " + verb
    if (seconds !== undefined) cmd += " " + Number(seconds)
    return cmd
  }

  readonly property string currentTimerId: root.timerKind === "reboot" ? "reboot-timer" : "shutdown-timer"

  function timerNoun() {
    return root.timerKind === "reboot" ? "reboot" : "shutdown"
  }

  function openTimer(kind) {
    root.disarm()
    root.timerKind = kind || "shutdown"
    root.view = "timer"
    root.timerCursor = 0
    root.timerCustom = false
    root.timerCustomError = ""
    root.timerArmed = false
    root.rebuildTimerRows()
    root.refreshTimer()
  }

  // Centered-open straight onto the timer view, for the launch-menu timer rows.
  function openTimerCentered(kind) {
    root.centered = true
    root.open()
    Qt.callLater(function() { root.openTimer(kind) })
  }

  function backToActions() {
    root.view = "actions"
    root.cursorIndex = 0
    root.disarm()
  }

  function refreshTimer() {
    if (!shutdownStatusProc.running) shutdownStatusProc.running = true
    if (!rebootStatusProc.running) rebootStatusProc.running = true
  }

  function applyTimerStatus(raw, kind) {
    var data = {}
    try { data = JSON.parse(raw) } catch (e) { data = {} }
    if (kind === "reboot") {
      if (data.armed !== undefined) root.rebootArmed = !!data.armed
      if (data.target !== undefined) root.rebootTarget = Number(data.target || 0)
    } else {
      if (data.armed !== undefined) root.shutdownArmed = !!data.armed
      if (data.target !== undefined) root.shutdownTarget = Number(data.target || 0)
    }
    root.timerTick()
  }

  function timerTick() {
    var now = Math.floor(Date.now() / 1000)
    root.shutdownRemaining = Math.max(0, root.shutdownTarget - now)
    root.rebootRemaining = Math.max(0, root.rebootTarget - now)
    if (root.shutdownArmed && root.shutdownRemaining <= 0) {
      root.shutdownArmed = false
      root.shutdownTarget = 0
      recheckTimer.restart()
    }
    if (root.rebootArmed && root.rebootRemaining <= 0) {
      root.rebootArmed = false
      root.rebootTarget = 0
      recheckTimer.restart()
    }
    // Collapse the two timers down to whichever one the timer view is showing.
    var prevArmed = root.timerArmed
    var isReboot = root.timerKind === "reboot"
    root.timerArmed = isReboot ? root.rebootArmed : root.shutdownArmed
    root.timerTarget = isReboot ? root.rebootTarget : root.shutdownTarget
    root.timerRemaining = isReboot ? root.rebootRemaining : root.shutdownRemaining
    if (root.timerArmed !== prevArmed && root.view === "timer") root.rebuildTimerRows()
  }

  function armTimer(seconds) {
    timerArmProc.command = ["bash", "-lc", root.timerCommand(root.currentTimerId, "arm", seconds)]
    if (!timerArmProc.running) timerArmProc.running = true
  }

  function cancelTimer() {
    timerCancelProc.command = ["bash", "-lc", root.timerCommand(root.currentTimerId, "cancel")]
    if (!timerCancelProc.running) timerCancelProc.running = true
  }

  function cancelTimerById(id) {
    timerCancelProc.command = ["bash", "-lc", root.timerCommand(id, "cancel")]
    if (!timerCancelProc.running) timerCancelProc.running = true
  }

  function timerItems() {
    var verb = root.timerNoun() === "reboot" ? "reboot" : "shutdown"
    var items = []
    if (!root.centered) items.push({ id: "back", icon: "\uf060", label: "Back", hint: "Return to the power menu" })
    if (root.timerArmed) items.push({ id: "cancel", icon: "\uf05e", label: "Cancel Timer", hint: "Abort the scheduled " + verb, dangerous: true })
    for (var i = 0; i < root.timerPresets.length; i++) {
      items.push({
        id: "preset:" + i,
        icon: "\uf017",
        label: root.timerPresets[i].label,
        hint: "Schedule " + verb + " in " + root.timerPresets[i].label,
        seconds: root.timerPresets[i].seconds
      })
    }
    items.push({
      id: "custom",
      icon: "\uf044",
      label: "Custom time\u2026",
      hint: "Enter any delay from 1 second to 1 year"
    })
    return items
  }

  function rebuildTimerRows() {
    root.timerRows = root.timerItems()
    if (root.timerCursor >= root.timerRows.length) root.timerCursor = Math.max(0, root.timerRows.length - 1)
  }

  function timerActiveRow() {
    return (root.timerCursor >= 0 && root.timerCursor < root.timerRows.length) ? root.timerRows[root.timerCursor] : null
  }

  function moveTimerCursor(step) {
    if (root.timerRows.length === 0) return
    var lo = root.centered ? -1 : 0
    root.timerCursor = Math.max(lo, Math.min(root.timerRows.length - 1, root.timerCursor + step))
  }

  function activateTimerRow(row) {
    if (!row) return
    if (row.id === "back") {
      root.backToActions()
      return
    }
    if (row.id === "cancel") {
      root.cancelTimer()
      return
    }
    if (row.id === "custom") {
      root.openCustomTimer()
      return
    }
    if (row.seconds) root.armTimer(row.seconds)
  }

  function openCustomTimer() {
    root.timerCustom = true
    root.timerCustomError = ""
    Qt.callLater(function() {
      customTimerInput.forceActiveFocus()
    })
  }

  function exitCustomTimer() {
    root.timerCustom = false
    root.timerCustomError = ""
    customTimerInput.text = ""
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
    })
  }

  function parseDuration(text) {
    var t = String(text || "").trim().toLowerCase()
    if (t === "") return 0
    var secs = 0
    var re = /(\d+(?:\.\d+)?)\s*(s|m|h|d|w|y)/g
    var found = false
    var match
    while ((match = re.exec(t)) !== null) {
      found = true
      var v = parseFloat(match[1])
      var unit = match[2]
      if (unit === "m") secs += v * 60
      else if (unit === "h") secs += v * 3600
      else if (unit === "d") secs += v * 86400
      else if (unit === "w") secs += v * 604800
      else if (unit === "y") secs += v * 31536000
      else secs += v
    }
    if (!found && /^\d+$/.test(t)) secs = parseInt(t, 10)
    return Math.floor(secs)
  }

  function armCustomTimer() {
    var secs = root.parseDuration(customTimerInput.text)
    if (secs < 1 || secs > root.yearSeconds) {
      root.timerCustomError = "Enter a time from 1 second to 1 year"
      return
    }
    root.timerCustomError = ""
    root.timerCustom = false
    root.armTimer(secs)
  }

  function clickTimerIndex(index) {
    if (index < 0 || index >= root.timerRows.length) return
    root.timerCursor = index
    root.activateTimerRow(root.timerRows[index])
  }

  // Scrolls the keyboard-cursor row into view when the content overflows the
  // screen-capped panel (e.g. the Cancel Timer row when a timer is armed).
  function revealRow(rowIndex) {
    var list = root.view === "settings"
      ? (root.centered ? settingsMenuRepeater : settingsRepeater)
      : (root.view === "actions")
        ? (root.centered ? menuRepeater : actionsRepeater)
        : (root.centered ? menuTimerRepeater : timerRepeater)
    if (!list || !panelScroll) return
    if (rowIndex < 0) { panelScroll.contentY = 0; return }
    if (rowIndex >= list.count) return
    var item = list.itemAt(rowIndex)
    if (!item) return
    var pos = item.mapToItem(column, 0, 0)
    var pad = Style.space(8)
    var top = panelScroll.contentY
    var bottom = top + panelScroll.height
    if (pos.y < top) panelScroll.contentY = Math.max(0, pos.y - pad)
    else if (pos.y + item.height > bottom) panelScroll.contentY = pos.y + item.height - panelScroll.height + pad
  }

  function formatRemaining(s) {
    var total = Math.max(0, Number(s) || 0)
    var h = Math.floor(total / 3600)
    var m = Math.floor((total % 3600) / 60)
    var sec = total % 60
    function p(v) { return (v < 10 ? "0" + v : "" + v) }
    if (h > 0) return h + ":" + p(m) + ":" + p(sec)
    return p(m) + ":" + p(sec)
  }

  // The row's own name, kept verbatim whether or not a timer is armed.
  function timerRowName(id) {
    return id === "reboot-timer" ? "Reboot Timer" : "Shutdown Timer"
  }

  // Name plus the live countdown, so arming a timer adds information instead
  // of replacing "Shutdown Timer"/"Reboot Timer" with a bare number. Only the
  // dropdown rows have the width for this; the menu-styled rows render the
  // countdown in their own trailing slot.
  function timerRowLabel(id) {
    var remaining = id === "reboot-timer" ? root.rebootRemaining : root.shutdownRemaining
    return root.timerRowName(id) + " \u00b7 " + root.formatRemaining(remaining)
  }

  function caption() {
    if (root.view === "settings") return "CUSTOMIZE BUTTONS"
    if (root.view === "timer") {
      var noun = root.timerNoun().toUpperCase()
      return root.timerArmed ? noun + " IN " + root.formatRemaining(root.timerRemaining) : "SET A " + noun + " TIMER"
    }
    return root.armedId === "" ? "MANAGE SESSION" : "CONFIRM TO CONTINUE"
  }

  function timerTitle() {
    return root.timerKind === "reboot" ? "Reboot Timer" : "Shutdown Timer"
  }

  // Menu-format header title (mirrors the launch menu showing the current
  // submenu name with a trailing ellipsis).
  function menuHeaderTitle() {
    if (root.view === "settings") return "Customize Buttons"
    if (root.view === "timer") return root.timerTitle()
    return "Power"
  }

  function footerHint() {
    if (root.view === "settings") return "drag to reorder · ↑↓ select · Tab toggle · Esc back"
    if (root.view === "timer") {
      if (root.timerCustom) return "type a delay like 90m / 2h / 3d \u00b7 Enter set \u00b7 Esc back"
      return root.timerArmed
        ? "Enter select \u00b7 Esc back \u00b7 cancel stops the timer"
        : "\u2191\u2193 select \u00b7 Enter arm \u00b7 Esc back"
    }
    return root.armedId === "" ? "↑↓ select · Enter run · Esc close · S settings" : "Enter to confirm · Esc to cancel"
  }

  Process {
    id: availProc
    command: ["bash", "-c", "if omarchy-toggle-enabled suspend-off; then echo -n S; else echo -n s; fi; if omarchy-hibernation-available; then echo -n h; else echo -n H; fi"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyAvailability(text) }
  }

  Process {
    id: caffStatusProc
    command: ["bash", "-c", "omarchy-toggle-idle status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyCaffeineStatus(text) }
  }

  Process {
    id: menuStatusProc
    command: ["bash", "-lc", root.shellQuote(root.scriptPath("add-to-omarchy-menu")) + " status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyMenuStatus(text) }
  }

  Process {
    id: menuToggleProc
    command: ["bash", "-lc", root.shellQuote(root.scriptPath("add-to-omarchy-menu")) + " status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyMenuStatus(text) }
  }

  // Quiet background re-sync of the per-action menu rows (settings/availability
  // changed while the widget is already listed in the launch menu).
  Process {
    id: menuSyncProc
    command: ["bash", "-lc", root.shellQuote(root.scriptPath("add-to-omarchy-menu")) + " add"]
    stdout: StdioCollector { waitForEnd: true }
  }

  Process {
    id: shutdownStatusProc
    command: ["bash", "-lc", root.timerCommand("shutdown-timer", "status")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyTimerStatus(text, "shutdown") }
  }

  Process {
    id: rebootStatusProc
    command: ["bash", "-lc", root.timerCommand("reboot-timer", "status")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyTimerStatus(text, "reboot") }
  }

  Process {
    id: timerArmProc
    command: ["bash", "-lc", root.timerCommand(root.currentTimerId, "status")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyTimerStatus(text, root.timerKind) }
  }

  Process {
    id: timerCancelProc
    command: ["bash", "-lc", root.timerCommand(root.currentTimerId, "cancel")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyTimerStatus(text, root.timerKind) }
  }

  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/power-menu.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadSettings(text())
    onLoadFailed: root.loadSettings("")
  }

  Timer { interval: 500; running: true; triggeredOnStart: true; onTriggered: settingsFile.reload() }

  Timer {
    id: armTimer
    interval: root.confirmSeconds * 1000
    onTriggered: root.disarm()
  }

  Timer {
    id: tickTimer
    interval: 1000
    repeat: true
    running: root.anyTimer || root.view === "timer"
    onTriggered: root.timerTick()
  }

  Timer {
    id: recheckTimer
    interval: 2000
    onTriggered: root.refreshTimer()
  }

  // Pulses root.powerPulse 0..1 while a timer is armed so the bar button, its
  // pill and the armed timer rows all flash together between accent and the
  // timer's warning color.
  SequentialAnimation {
    running: root.anyTimer
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "powerPulse"; to: 1.0; duration: 520; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "powerPulse"; to: 0.0; duration: 520; easing.type: Easing.InOutQuad }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Open centered on the screen (used by the Omarchy menu entry).
    function openCenter(): void {
      root.centered = true
      root.open()
    }
    function openCentered(): void { root.openCenter() }


    // Direct session actions for keybinds/scripts, mirroring the menu entries.
    function lock(): void { Quickshell.execDetached(["omarchy-system-lock"]) }
    function suspend(): void { Quickshell.execDetached(["systemctl", "suspend"]) }
    function hibernate(): void { Quickshell.execDetached(["systemctl", "hibernate"]) }
    function logout(): void { Quickshell.execDetached(["omarchy-system-logout"]) }
    function reboot(): void { Quickshell.execDetached(["omarchy-system-reboot"]) }
    function shutdown(): void { Quickshell.execDetached(["omarchy-system-shutdown"]) }

    function shutdownTimer(): void { root.openTimer("shutdown") }
    function shutdownTimerArm(seconds: int): void { root.armTimer(Number(seconds)) }
    function shutdownTimerCancel(): void { root.cancelTimer() }
    function rebootTimer(): void { root.openTimer("reboot") }
    function rebootTimerArm(seconds: int): void { root.armTimer(Number(seconds)) }
    function rebootTimerCancel(): void { root.cancelTimer() }

    function caffeinate(): void { Quickshell.execDetached(["omarchy-toggle-idle", "toggle"]) }
    function btop(): void { Quickshell.execDetached(root.btopCommand()) }
    function screensaver(): void { Quickshell.execDetached(["omarchy-launch-screensaver"]) }
    function settings(): void { root.toggleSettingsView() }

    // Centered timer views for the launch-menu "Shutdown Timer"/"Reboot Timer"
    // rows, so those actions land on the arming screen rather than dead-ending.
    function openShutdownTimer(): void { root.openTimerCentered("shutdown") }
    function openRebootTimer(): void { root.openTimerCentered("reboot") }

    // The currently enabled (non-settings) rows as launch-menu entries: the
    // add-to-omarchy-menu script mirrors these into the menu file verbatim.
    function menuItems(): string {
      var rows = root.buildActions()
      var out = []
      for (var i = 0; i < rows.length; i++) {
        var a = rows[i]
        if (a.settingsOnly) continue
        var cmd = root.menuActionString(a)
        if (!cmd) continue
        out.push({ id: a.id, label: a.label, icon: a.icon, hint: a.hint, action: cmd })
      }
      return JSON.stringify(out)
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.refreshAvailability()
      root.refreshCaffeine()
      root.refreshMenuStatus()
      root.view = "actions"
      root.cursorIndex = 0
      root.disarm()
      root.rebuildTimerRows()
      root.refreshTimer()
    } else {
      root.disarm()
    }
  }

  onTimerCursorChanged: root.revealRow(root.timerCursor)
  onSettingsCursorChanged: if (root.settingsDragIndex < 0) root.revealRow(root.settingsCursor)
  onCursorIndexChanged: root.revealRow(root.cursorIndex)

  Component.onCompleted: {
    root.refreshAvailability()
    root.refreshCaffeine()
    root.refreshMenuStatus()
    root.rebuildTimerRows()
    root.refreshTimer()
    settingsFile.reload()
  }

  // Shared row used by the menu-format lists (actions and timers) when the
  // panel is opened centered from the launch menu. Mirrors the launch menu's
  // own row: rounded chip, icon + label, trailing chevron for submenus, and
  // the menu cursor fill/border.
  Component {
    id: menuRowDelegate
    BorderSurface {
      id: mrow
      required property var modelData
      required property int index

      readonly property bool inSettings: root.view === "settings"
      readonly property bool inActions: root.view === "actions"
      readonly property bool selectedRow: inSettings
        ? (root.settingsCursor === index)
        : (inActions ? (root.cursorIndex === index) : (root.timerCursor === index))
      readonly property bool rowHidden: modelData ? root.isSettingsHidden(modelData.id) && !modelData.settingsOnly && !modelData.menuToggle : false
      readonly property bool rowLocked: modelData ? modelData.settingsOnly === true && !modelData.menuToggle : false
      readonly property bool rowMenuToggle: modelData ? modelData.menuToggle === true : false
      readonly property bool isDragSource: root.settingsDragIndex === index
      readonly property int ladderStep: root.menuRowHeight + root.menuRowSpacing
      readonly property bool rowArmed: root.armedId === modelData.id
      readonly property bool rowCaf: modelData.id === "caffeinate" && root.caffeinated
      readonly property bool rowTimerArmed: (modelData.id === "reboot-timer" && root.rebootArmed)
        || (modelData.id === "shutdown-timer" && root.shutdownArmed)
      readonly property int rowTimerRemaining: modelData && modelData.id === "reboot-timer" ? root.rebootRemaining : root.shutdownRemaining
      // An armed timer row borrows the bar button's pulse, so the list reads
      // as live the same way the icon does: normal text breathing toward
      // flashColor (yellow for a lone reboot timer, red once a shutdown is
      // also pending) for as long as the schedule stands.
      readonly property color rowAlert: inActions && rowTimerArmed
        ? root.timerAlert(root.menuText)
        : root.menuText
      readonly property bool drill: modelData.settingsEntry === true
        || modelData.id === "shutdown-timer"
        || modelData.id === "reboot-timer"
        || modelData.submenu === true
      readonly property int rLeft: Border.left(root.menuSelectedBorderSpec)
      readonly property int rRight: Border.right(root.menuSelectedBorderSpec)
      readonly property string rowLabel: inSettings
        ? (modelData ? String(modelData.label) : "")
        : (rowTimerArmed
            ? root.timerRowName(modelData.id)
            : (rowArmed ? "Confirm " + modelData.label + "?" : (rowCaf ? "\u2713 " + modelData.label : modelData.label)))

      width: parent.width
      height: root.menuRowHeight
      radius: Style.cornerRadius
      color: selectedRow ? Color.menu.selectedBackground : "transparent"
      borderSpec: selectedRow ? root.menuSelectedBorderSpec : Border.none()
      opacity: isDragSource ? 0.5 : 1.0
      z: isDragSource ? 10 : 1

      Behavior on opacity { NumberAnimation { duration: 100 } }
      Behavior on y {
        enabled: !mrowArea.dragging
        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
      }

      Text {
        id: gripSpot
        visible: mrow.inSettings
        anchors.left: parent.left
        anchors.leftMargin: mrow.rLeft + Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "\u283f"
        color: mrow.selectedRow ? Color.menu.selectedText : root.dim
        opacity: (mrow.selectedRow || mrow.isDragSource) ? 1.0 : 0.6
        font.family: root.menuFontFamily
        font.pixelSize: Style.font.heading
      }

      Text {
        id: iconSpot
        visible: String(modelData.icon).length > 0
        anchors.left: parent.left
        anchors.leftMargin: mrow.rLeft + Style.space(8) + (mrow.inSettings ? gripSpot.width + Style.space(4) : 0)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(36)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: modelData.icon
        color: mrow.selectedRow ? Color.menu.selectedText : (mrow.inSettings && mrow.rowHidden ? root.dim : root.menuText)
        opacity: mrow.inSettings && mrow.rowHidden ? 0.5 : 1.0
        font.family: root.menuFontFamily
        font.pixelSize: Style.font.iconLarge
      }

      Text {
        id: label
        anchors.left: String(modelData.icon).length > 0 ? iconSpot.right : parent.left
        anchors.leftMargin: String(modelData.icon).length > 0 ? Style.space(6) : mrow.rLeft + Style.space(18)
        anchors.right: mrow.inSettings
          ? (mrow.rowLocked ? parent.right : settingsToggle.left)
          : (mrow.rowTimerArmed ? timerCountSpot.left : chevronSpot.left)
        anchors.rightMargin: mrow.inSettings ? (mrow.rowLocked ? mrow.rRight + Style.space(8) : Style.space(6)) : Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: mrow.rowLabel
        color: mrow.selectedRow ? Color.menu.selectedText
          : (mrow.inSettings
              ? (mrow.rowHidden ? root.dim : root.menuText)
              : (mrow.rowCaf ? root.caffeineColor : mrow.rowAlert))
        opacity: mrow.inSettings && mrow.rowHidden ? 0.5 : 1.0
        font.family: root.menuFontFamily
        font.pixelSize: Style.font.heading
        font.weight: Font.Medium
        elide: Text.ElideRight
      }

      // The countdown rides in its own trailing slot so the row name never has
      // to give up room to it.
      Text {
        id: timerCountSpot
        visible: mrow.rowTimerArmed && !mrow.inSettings
        anchors.right: timerCancelSpot.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        text: root.formatRemaining(mrow.rowTimerRemaining)
        color: mrow.selectedRow ? Color.menu.selectedText : mrow.rowAlert
        opacity: 1.0
        font.family: root.menuFontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.Medium
      }

      Text {
        id: chevronSpot
        visible: !mrow.inSettings
        width: Style.space(14)
        anchors.right: parent.right
        anchors.rightMargin: mrow.rRight + Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignHCenter
        text: mrow.drill ? "\u203a" : ""
        color: mrow.selectedRow ? Color.menu.selectedText : root.menuText
        opacity: mrow.drill ? 0.36 : 0
        font.family: root.menuFontFamily
        font.pixelSize: Style.font.heading
      }

      ToggleSwitch {
        id: settingsToggle
        visible: mrow.inSettings && !mrow.rowLocked
        checked: mrow.rowMenuToggle ? root.inOmarchyMenu : !mrow.rowHidden
        foreground: root.menuText
        accent: root.accent
        anchors.right: parent.right
        anchors.rightMargin: mrow.rRight + Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        onToggled: {
          root.settingsCursor = index
          if (modelData && !mrow.rowLocked) root.toggleSettingsRow(modelData)
        }
      }

      Item {
        id: timerCancelSpot
        visible: mrow.rowTimerArmed && !mrow.inSettings
        width: Style.space(30)
        height: parent.height
        anchors.right: chevronSpot.left
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        z: 10

        Text {
          anchors.centerIn: parent
          text: "\uf057"
          color: mrow.selectedRow ? Color.menu.selectedText : mrow.rowAlert
          opacity: 1.0
          font.family: root.menuFontFamily
          font.pixelSize: Style.font.title
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.cancelTimerById(modelData.id)
        }
      }

      MouseArea {
        id: mrowArea
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: mrow.inSettings
        cursorShape: mrow.inSettings ? Qt.OpenHandCursor : (mrow.rowArmed ? Qt.ArrowCursor : Qt.PointingHandCursor)
        property bool dragging: false
        property bool moved: false
        property real pressSceneY: 0
        onEntered: function() {
          if (mrow.inSettings) {
            if (index !== root.settingsCursor) root.settingsCursor = index
          } else if (mrow.inActions) {
            if (index !== root.cursorIndex) root.moveCursor(index - root.cursorIndex)
          } else if (index !== root.timerCursor) {
            root.moveTimerCursor(index - root.timerCursor)
          }
        }
        onPressed: function(mouse) {
          if (!mrow.inSettings) return
          root.beginSettingsDrag(index)
          dragging = true
          moved = false
          pressSceneY = mrowArea.mapToItem(null, mouse.x, mouse.y).y
        }
        onPositionChanged: function(mouse) {
          if (mrow.inSettings) {
            if (dragging) {
              var sceneY = mrowArea.mapToItem(null, mouse.x, mouse.y).y
              var cell = Math.round((sceneY - pressSceneY) / mrow.ladderStep)
              cell = Math.max(-index, Math.min(root.settingsOrder.length - 1 - index, cell))
              if (cell !== root.settingsDropIndex - index) moved = true
              root.updateSettingsDrop(index + cell, mrow.ladderStep)
              mrow.y = cell * mrow.ladderStep
            } else if (index !== root.settingsCursor) {
              root.settingsCursor = index
            }
          } else {
            if (mrow.inActions) {
              if (index !== root.cursorIndex) root.moveCursor(index - root.cursorIndex)
            } else if (index !== root.timerCursor) {
              root.moveTimerCursor(index - root.timerCursor)
            }
          }
        }
        onReleased: function() {
          if (!mrow.inSettings) return
          dragging = false
          mrow.y = 0
          if (moved) {
            root.endSettingsDrag(true)
          } else {
            root.endSettingsDrag(false)
            root.settingsCursor = index
            if (modelData && !mrow.rowLocked) root.toggleSettingsRow(modelData)
          }
        }
        onCanceled: function() {
          if (!mrow.inSettings) return
          dragging = false
          mrow.y = 0
          root.endSettingsDrag(false)
        }
        onClicked: {
          if (mrow.inActions) root.clickIndex(index)
          else if (!mrow.inSettings) root.clickTimerIndex(index)
        }
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Eye-catching pill behind the power icon: accent-tinted by default, brown
  // while Caffeinate is on, pulsing toward flashColor while a
  // shutdown/reboot timer is armed. The armed timer rows in the lists ride
  // this same pulse.
  Rectangle {
    id: powerSpot
    anchors.centerIn: parent
    width: Math.max(1, Math.round(button.implicitWidth - Style.space(2)))
    height: Math.max(1, Math.round(button.implicitHeight - Style.space(10)))
    radius: Math.max(1, Math.round(height / 2))
    // Fill and border read one pulsed color, just at different opacities, so
    // they can never disagree about where in the pulse they are.
    readonly property color pulseColor: root.anyTimer ? root.timerAlert(root.accent) : "transparent"
    color: root.anyTimer ? Util.alpha(pulseColor, 0.24) : Util.alpha(root.barAccent, 0.15)
    border.width: Math.max(1, Math.round(Style.space(1)))
    border.color: root.anyTimer ? Util.alpha(pulseColor, 0.55) : Util.alpha(root.barAccent, 0.38)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.anyTimer ? "\uf011" : (root.caffeinated ? "\uf0f4" : "\uf011")
    tooltipText: root.shutdownArmed
    ? "Power \u00b7 shutdown in " + root.formatRemaining(root.shutdownRemaining)
    : (root.rebootArmed
      ? "Power \u00b7 reboot in " + root.formatRemaining(root.rebootRemaining)
      : (root.caffeinated ? "Power \u00b7 Caffeinate active" : "Power"))
    active: true
    activeColor: root.anyTimer ? root.timerAlert(root.accent) : root.barAccent
    onPressed: function(buttonCode) { root.centered = false; root.toggle() }
  }

  // Jumps the cursor by roughly a viewport's worth of rows (used by the
  // PgUp/PgDn keys so long menus can be paged through when the panel is
  // screen-capped and scrolls).
  function jumpCursor(step) {
    var count = 0
    if (root.view === "settings") {
      if (root.settingsOrder.length === 0) return
      count = root.settingsOrder.length
      var slo = root.centered ? -1 : 0
      var too = slo + step
      root.settingsCursor = too < slo ? slo : (too >= count ? count - 1 : too)
    } else if (root.view === "timer") {
      count = root.timerRows.length
      root.moveTimerCursor(count === 0 ? 0 : ((root.timerCursor + step < 0) ? -root.timerCursor : (root.timerCursor + step >= count ? count - 1 - root.timerCursor : step)))
    } else {
      var list = root.centered ? root.menuRows : root.actions
      count = list.length
      if (count === 0) return
      var target = root.cursorIndex + step
      target = target < 0 ? 0 : (target >= count ? count - 1 : target)
      root.moveCursor(target - root.cursorIndex)
    }
  }

  CenterableKeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnScreen: root.centered
    menuStyle: root.centered
    menuColor: root.menuBackground
    menuSurfaceSpec: root.menuBorderSpec
    menuScrim: root.menuScrim
    menuPadding: Style.spacing.panelPadding
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.centered ? root.menuCardWidth : Style.space(280))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, root.centered && panel.screenH > 0 ? panel.screenH - Style.gapsOut * 2 : Style.space(560))

    // PgUp/PgDn page the cursor. PanelKeyCatcher leaves those keys unhandled,
    // so the events bubble up from keyCatcher to this wrapper and are matched
    // here by key code (there are no named Keys signals for PageUp/PageDown).
    Item {
      id: keyWrapper
      anchors.fill: parent

      Keys.onPressed: function(event) {
        if (keyCatcher.blocked) return
        if (event.key === Qt.Key_PageUp) { root.jumpCursor(-6); event.accepted = true }
        else if (event.key === Qt.Key_PageDown) { root.jumpCursor(6); event.accepted = true }
      }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: root.view === "timer" && root.timerCustom && customTimerInput.activeFocus
        onMoveRequested: function(dx, dy) {
        if (root.view === "settings") {
          if (root.settingsOrder.length > 0) {
            var settingsLo = root.centered ? -1 : 0
            root.settingsCursor = Math.max(settingsLo, Math.min(root.settingsOrder.length - 1, root.settingsCursor + (dy !== 0 ? dy : dx)))
          }
        } else if (root.view === "timer") {
          root.moveTimerCursor(dy !== 0 ? dy : dx)
        } else {
          root.moveCursor(dy !== 0 ? dy : dx)
        }
      }
      onActivateRequested: {
        if (root.view === "settings") {
          if (root.centered && root.settingsCursor === -1) { root.toggleSettingsView(); return }
          var action = root.settingsItemAt(root.settingsCursor)
          if (action && (!action.settingsOnly || action.menuToggle)) root.toggleSettingsRow(action)
        } else if (root.view === "timer") {
          if (root.centered && root.timerCursor === -1) { root.backToActions(); return }
          root.activateTimerRow(root.timerActiveRow())
        } else {
          root.activate(root.currentAction())
        }
      }
      onDeleteRequested: {
        if (root.view === "settings") {
          if (root.centered && root.settingsCursor === -1) { root.toggleSettingsView(); return }
          var action = root.settingsItemAt(root.settingsCursor)
          if (action && (!action.settingsOnly || action.menuToggle)) root.toggleSettingsRow(action)
        } else if (root.view === "timer") {
          if (root.centered && root.timerCursor === -1) { root.backToActions(); return }
          root.activateTimerRow(root.timerActiveRow())
        } else {
          root.activate(root.currentAction())
        }
      }
      onCloseRequested: {
        if (root.view === "settings") {
          root.toggleSettingsView()
        } else if (root.view === "timer") {
          root.backToActions()
        } else if (root.armedId !== "") {
          root.disarm()
        } else {
          root.close()
        }
      }
      onTabRequested: function(direction) {
        if (root.view === "settings") {
          var action = root.settingsItemAt(root.settingsCursor)
          if (action && (!action.settingsOnly || action.menuToggle)) root.toggleSettingsRow(action)
        } else {
          root.switchPanel(direction)
        }
      }

      Keys.onEscapePressed: {
        if (root.view === "settings") {
          root.toggleSettingsView()
        } else if (root.view === "timer") {
          root.backToActions()
        } else if (root.armedId !== "") {
          root.disarm()
        } else {
          root.close()
        }
      }
      }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          policy: ScrollBar.AsNeeded
          width: 6
        }

        Column {
          id: column
          width: panelScroll.width
          spacing: root.centered ? root.menuContentSpacing : Style.space(12)

          // When the panel is opened centered from the launch menu the card
          // is dressed exactly like the launch menu: a header line naming the
          // current screen ("Power…"), a Back row on the Settings screen, and
          // the action/timer lists rendered as menu rows. The original bar
          // dropdown content below is hidden for the centered mode.
          Item {
            visible: root.centered
            width: parent.width
            height: root.menuHeaderHeight

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.menuHeaderTitle() + "\u2026"
              color: root.menuText
              opacity: 0.58
              font.family: root.menuFontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }
          }

          Item {
            visible: root.centered && (root.view === "settings" || root.view === "timer")
            width: parent.width
            height: root.menuRowHeight

            readonly property bool backSelected: (root.view === "settings" && root.settingsCursor === -1)
              || (root.view === "timer" && root.timerCursor === -1)

            BorderSurface {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: parent.backSelected ? Color.menu.selectedBackground : "transparent"
              borderSpec: parent.backSelected ? root.menuSelectedBorderSpec : Border.none()

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Border.left(root.menuSelectedBorderSpec) + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "\uf060"
                color: parent.parent.backSelected ? Color.menu.selectedText : root.menuText
                font.family: root.menuFontFamily
                font.pixelSize: Style.font.iconLarge
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Border.left(root.menuSelectedBorderSpec) + Style.space(8) + Style.space(36) + Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "Back"
                color: parent.parent.backSelected ? Color.menu.selectedText : root.menuText
                font.family: root.menuFontFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.Medium
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                  if (root.view === "settings") {
                    if (root.settingsCursor !== -1) root.settingsCursor = -1
                  } else if (root.timerCursor !== -1) {
                    root.timerCursor = -1
                  }
                }
                onClicked: {
                  if (root.view === "timer") root.backToActions()
                  else root.toggleSettingsView()
                }
              }
            }
          }

          Column {
            visible: root.centered && root.view === "actions"
            width: parent.width
            spacing: root.menuRowSpacing
            Repeater {
              id: menuRepeater
              model: root.menuRows
              delegate: menuRowDelegate
            }
          }

          Column {
            visible: root.centered && root.view === "settings"
            width: parent.width
            spacing: root.menuRowSpacing
            Repeater {
              id: settingsMenuRepeater
              model: root.settingsRows
              delegate: menuRowDelegate
            }
          }

          Column {
            visible: root.centered && root.view === "timer" && !root.timerCustom
            width: parent.width
            spacing: root.menuRowSpacing
            Repeater {
              id: menuTimerRepeater
              model: root.timerRows
              delegate: menuRowDelegate
            }
          }

          Item {
            visible: !root.centered
            width: parent.width
            implicitHeight: Math.max(powerIcon.implicitHeight, powerLabels.implicitHeight, cogBtn.implicitHeight)

            Text {
              id: powerIcon
              text: root.view === "settings" ? "\uf013" : (root.view === "timer" ? "\uf017" : "\uf011")
              color: root.view === "settings" ? root.accent : (root.view === "timer" && root.timerArmed ? root.urgent : root.foreground)
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: powerLabels
              anchors.left: powerIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: cogBtn.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: root.view === "settings" ? "Settings" : (root.view === "timer" ? root.timerTitle() : "Power")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: root.caption()
                color: root.view === "timer" && root.timerArmed ? root.urgent : (root.armedId === "" ? root.dim : root.urgent)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Button {
              id: cogBtn
              iconText: root.view === "settings" ? "\uf060" : "\uf013"
              iconSize: Style.font.body
              fontSize: Style.font.body
              foreground: root.view === "settings" ? root.accent : root.dim
              accent: root.accent
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              tooltipText: root.view === "settings" ? "Back to power menu" : "Settings"
              onClicked: root.toggleSettingsView()
            }
          }

          PanelSeparator { visible: !root.centered; foreground: root.foreground }

          // ---- Actions view ----
          Column {
            visible: root.view === "actions" && !root.centered
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              id: actionsRepeater
              model: root.actions

              Button {
                required property var modelData
                required property int index

                readonly property bool timerRow: modelData.id === "shutdown-timer" || modelData.id === "reboot-timer"
                readonly property bool timerRowArmed: timerRow && (modelData.id === "reboot-timer"
                  ? root.rebootArmed : root.shutdownArmed)
                readonly property bool armed: root.armedId === modelData.id
                readonly property bool cafOn: modelData.id === "caffeinate" && root.caffeinated
                // Mirrors the menu-format rows: an armed timer breathes
                // between the resting text color and flashColor, and an active
                // Caffeinate holds a steady brown instead of the urgent red
                // the session-ending rows borrow.
                readonly property color rowAlert: timerRowArmed
                  ? root.timerAlert(root.foreground)
                  : root.urgent

                width: parent.width
                leftAlign: true
                iconText: modelData.icon
                text: timerRowArmed
                  ? root.timerRowLabel(modelData.id)
                  : (armed ? "Confirm " + modelData.label + "?" : (cafOn ? modelData.label + "\u00b7 Active" : modelData.label))
                fontSize: Style.font.body
                iconSize: Style.font.title
                foreground: cafOn
                  ? root.caffeineColor
                  : (armed ? root.urgent : (timerRowArmed ? rowAlert : root.foreground))
                accent: root.urgent
                fontFamily: root.fontFamily
                hasCursor: root.cursorIndex === index
                bordered: armed || timerRowArmed || cafOn
                horizontalPadding: Style.spacing.controlPaddingX + Style.space(4)
                verticalPadding: Style.space(11)
                onClicked: root.clickIndex(index)
                onHovered: function(h) {
                  if (root.view === "actions" && h && index !== root.cursorIndex) root.moveCursor(index - root.cursorIndex)
                }

                Item {
                  visible: timerRowArmed
                  width: Style.space(34)
                  height: parent.height
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.controlPaddingX + Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  z: 10

                  Text {
                    anchors.centerIn: parent
                    text: "\uf057"
                    color: rowAlert
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.cancelTimerById(modelData.id)
                  }
                }
              }
            }
          }

          // ---- Settings view ----
          Column {
            visible: !root.centered && root.view === "settings"
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              id: settingsRepeater
              model: root.view === "settings" ? root.settingsOrder.length : 0

              Item {
                id: rowSlot
                required property int index

                readonly property var actionData: root.settingsItemAt(index)
                readonly property bool isHidden: actionData ? (actionData.settingsOnly ? false : root.isSettingsHidden(actionData.id)) : false
                readonly property bool isCurrent: root.settingsCursor === index
                readonly property bool isDragSource: root.settingsDragIndex === index
                readonly property int ladderStep: rowItem.implicitHeight + Style.space(6)
                readonly property bool menuSel: root.centered && isCurrent

                width: parent.width + (root.centered ? 0 : 20)
                implicitHeight: rowItem.implicitHeight

                Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

                BorderSurface {
                  id: rowItem
                  width: parent.width
                  implicitHeight: Math.max(46, row.implicitHeight + Style.space(6) * 2)
                  radius: Style.cornerRadius
                  color: menuSel ? Color.menu.selectedBackground : "transparent"
                  borderSpec: menuSel ? root.menuSelectedBorderSpec : Border.none()
                opacity: isDragSource ? 0.5 : 1.0
                z: isDragSource ? 10 : 1

                Behavior on opacity { NumberAnimation { duration: 100 } }

                MouseArea {
                  id: rowDragArea
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton
                  preventStealing: true
                  cursorShape: Qt.OpenHandCursor
                  property bool dragging: false
                  property bool moved: false
                  property real pressSceneY: 0
                  onPressed: function(mouse) {
                    root.beginSettingsDrag(index)
                    dragging = true
                    moved = false
                    pressSceneY = rowDragArea.mapToItem(null, mouse.x, mouse.y).y
                  }
                  onPositionChanged: function(mouse) {
                    if (!dragging) return
                    var sceneY = rowDragArea.mapToItem(null, mouse.x, mouse.y).y
                    var cell = Math.round((sceneY - pressSceneY) / ladderStep)
                    cell = Math.max(-index, Math.min(root.settingsOrder.length - 1 - index, cell))
                    if (cell !== root.settingsDropIndex - index) moved = true
                    root.updateSettingsDrop(index + cell, ladderStep)
                    rowItem.y = cell * ladderStep
                  }
                  onReleased: function() {
                    dragging = false
                    rowItem.y = 0
                    if (moved) {
                      root.endSettingsDrag(true)
                    } else {
                      root.endSettingsDrag(false)
                      root.settingsCursor = index
                      if (actionData && (!actionData.settingsOnly || actionData.menuToggle)) root.toggleSettingsRow(actionData)
                    }
                  }
                  onCanceled: {
                    dragging = false
                    rowItem.y = 0
                    root.endSettingsDrag(false)
                  }
                  onContainsMouseChanged: if (containsMouse && !isDragSource) root.settingsCursor = index
                }

                Row {
                  id: row
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(6)

                  // Drag handle / grip
                  Item {
                    id: gripArea
                    width: gripLabel.implicitWidth
                    height: gripLabel.implicitHeight
                    anchors.verticalCenter: parent.verticalCenter
                    transform: Translate { x: -10 }
                    Text {
                      id: gripLabel
                      text: "⠿"
                      color: isDragSource ? root.accent : (menuSel ? Color.menu.selectedText : root.dim)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      anchors.fill: parent
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                      opacity: isDragSource ? 1.0 : 0.6
                    }
                  }

                  Text {
                    id: iconTextItem
                    text: actionData ? actionData.icon : ""
                    color: menuSel ? Color.menu.selectedText : (isHidden ? root.dim : root.foreground)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: isHidden ? 0.5 : 1.0
                  }

                  Text {
                    text: actionData ? actionData.label : ""
                    color: menuSel ? Color.menu.selectedText : (isHidden ? root.dim : root.foreground)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: isCurrent && !root.centered
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: isHidden ? 0.5 : 1.0
                    width: parent.width - gripLabel.implicitWidth - iconTextItem.implicitWidth - (toggleSwitch.visible ? toggleSwitch.implicitWidth : 0) - Style.space(6) * 3
                    elide: Text.ElideRight
                  }

                  ToggleSwitch {
                    id: toggleSwitch
                    visible: actionData ? (!actionData.settingsOnly || actionData.menuToggle) : true
                    checked: actionData && actionData.menuToggle ? root.inOmarchyMenu : !isHidden
                    foreground: root.foreground
                    accent: root.accent
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: {
                      root.settingsCursor = index
                      if (actionData && (!actionData.settingsOnly || actionData.menuToggle)) root.toggleSettingsRow(actionData)
                    }
                  }
                }
                }
              }
            }
          }

          // ---- Timer view ----
          Repeater {
            id: timerRepeater
            model: root.view === "timer" && !root.timerCustom && !root.centered ? root.timerRows : []

            Button {
              required property var modelData
              required property int index

              readonly property bool danger: modelData.id === "cancel"

              width: parent.width
              leftAlign: true
              iconText: modelData.icon
              text: modelData.label
              fontSize: Style.font.body
              iconSize: Style.font.title
              foreground: danger ? root.urgent : root.foreground
              accent: danger ? root.urgent : Color.accent
              fontFamily: root.fontFamily
              hasCursor: root.timerCursor === index
              bordered: danger
              horizontalPadding: Style.spacing.controlPaddingX + Style.space(4)
              verticalPadding: Style.space(11)
              onClicked: root.clickTimerIndex(index)
              onHovered: function(h) {
                if (root.view === "timer" && h && index !== root.timerCursor) root.moveTimerCursor(index - root.timerCursor)
              }
            }
          }

          // ---- Timer custom input ----
          Column {
            visible: root.view === "timer" && root.timerCustom
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "Set a custom " + root.timerNoun() + " delay"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              width: parent.width
            }

            Text {
              text: "Type a duration: 45s \u00b7 5m \u00b7 2h \u00b7 3d \u00b7 1y"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.controlHeight
              radius: Style.cornerRadius
              border.width: Math.max(1, Style.space(2))
              border.color: customTimerInput.activeFocus ? root.accent : root.dim
              color: Util.alpha(customTimerInput.activeFocus ? root.accent : root.foreground, 0.06)

              TextInput {
                id: customTimerInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                verticalAlignment: TextInput.AlignVCenter
                clip: true
                focus: true
                Keys.onEscapePressed: root.exitCustomTimer()
                Keys.onReturnPressed: root.armCustomTimer()
                Keys.onEnterPressed: root.armCustomTimer()
              }

              Text {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                verticalAlignment: TextInput.AlignVCenter
                text: "e.g. 90m  2h  3d  120s  1y"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                visible: customTimerInput.text.length === 0
              }
            }

            Text {
              text: "1 second \u00b7 1 year  \u00b7  s / m / h / d / w / y"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
            }

            Text {
              text: root.timerCustomError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              visible: root.timerCustomError.length > 0
            }

            Button {
              width: parent.width
              iconText: "\uf017"
              text: "Set Timer"
              fontSize: Style.font.body
              iconSize: Style.font.title
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX + Style.space(4)
              verticalPadding: Style.space(11)
              onClicked: root.armCustomTimer()
            }
          }

          Text {
            width: parent.width
            visible: !root.centered
            text: root.footerHint()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
