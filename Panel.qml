import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Nag: disposable alarms, set from one text field.
//
// Type "15:15 pick up the kids" and it is set. The point is that setting an
// alarm costs one line and leaves nothing behind, which is what a calendar
// entry cannot do: an appointment for picking up the kids at quarter past
// three today survives in perpetuity and syncs to every device you own.
//
// bin/nag owns every bit of the parsing, so this file never has to know what a
// valid time looks like, and the preview under the field is the same code path
// that will run when Enter is pressed.
//
// An OverlayWindow rather than PopupCard, because PopupCard is a PopupWindow
// and those never get keyboard focus on Wayland: a text field inside one can be
// clicked but not typed into, and this panel is a text field and little else.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.nag"
  ipcTarget: "jankeesvw.nag"

  // Panel's own IpcHandler is switched off so this file can add `refresh` to
  // the same target; two handlers on one target is one too many, so the five it
  // would have given us are repeated below. That method is what lets an alarm
  // set from the menu or the command line reach the bar at once, instead of
  // waiting out the poll while the countdown shows the wrong number.
  manageIpc: false

  // The script sits next to this file, so the plugin runs from wherever it was
  // installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/nag").toString().replace(/^file:\/\//, "")

  // nf-md-timer, U+F051F. Deliberately not a bell: the shell already spends
  // that glyph on notifications and on its own reminders, and two bells in one
  // bar is a bar you have to read twice. Past U+FFFF, so it is written as the
  // surrogate pair rather than as a five-digit escape, which \u would silently
  // truncate into a different glyph with a stray character after it.
  readonly property string iconTimer: "\uDB81\uDD1F"
  // The `icon` setting swaps it for any other glyph, Omarchy's reminder bell
  // for one, on a desktop where Nag stands in for the reminder.
  readonly property string barIcon: {
    var icon = plain(setting("icon", "")).trim().slice(0, 4)
    return icon.length > 0 ? icon : iconTimer
  }
  readonly property string iconClose: "\uF00D"
  readonly property string iconSnooze: "\uF186"
  readonly property string iconSettings: "\uF013"
  readonly property string iconBack: "\uF060"
  readonly property string iconPlay: "\uF04B"
  readonly property string iconStop: "\uF04D"
  readonly property string iconEdit: "\uF040"
  readonly property string iconSkip: "\uF051"
  readonly property string iconRepeat: "\uF01E"
  readonly property string iconTrash: "\uF1F8"

  // The sound settings, as bin/nag reads them when an alarm goes off.
  readonly property string defaultSound: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
  // Nag's own sounds folder, where Browse… opens. The first Browse creates it
  // with copies of the default alarm and the phone ring, the only other
  // freedesktop sound long enough to wake anyone (bell.oga is a 0.2 s ding);
  // more sounds are added by dropping files into it.
  readonly property string soundsDir: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/nag/sounds"
  readonly property var seedSounds: [defaultSound,
    "/usr/share/sounds/freedesktop/stereo/phone-incoming-call.oga"]
  readonly property bool soundOn: setting("soundOn", true) !== false
  readonly property bool soundRepeat: setting("soundRepeat", true) !== false
  // Seconds of silence between two plays of a repeating sound.
  readonly property int soundPause: {
    var seconds = Number(setting("soundPause", 0))
    return seconds >= 0 && seconds <= 60 ? Math.floor(seconds) : 0
  }
  readonly property string soundPath: String(setting("sound", "") || "")

  // Off, a ringing alarm can only be dismissed: no snooze button in the
  // panel or the notification.
  readonly property bool snoozeOn: setting("snoozeOn", true) !== false

  // Minutes an alarm rings before bin/nag reports it missed.
  readonly property int ringMinutes: {
    var minutes = Number(setting("ringMinutes", 5))
    return minutes >= 1 && minutes <= 60 ? Math.floor(minutes) : 5
  }

  // Minutes a snooze puts an alarm off, from the panel and the notification.
  readonly property int snoozeMinutes: {
    var minutes = Number(setting("snoozeMinutes", 5))
    return minutes >= 1 && minutes <= 1440 ? Math.floor(minutes) : 5
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // [{ id, at, message, atLabel, remaining, remainingSeconds, ringing }]
  property var alarms: []
  property int ringingCount: 0
  property var nextAlarm: null

  // Seconds since the epoch, ticked locally. The countdown in the bar has to
  // move every second, and running a process every second to find that out
  // would be absurd for a number we can work out from the timestamps we
  // already have.
  property int nowSeconds: Math.floor(Date.now() / 1000)

  property string draft: ""
  // "alarms" or "settings": what the card shows. The gear at its top left
  // swaps one for the other, and every open starts on the alarms.
  property string view: "alarms"
  // The alarm the field is editing, in the "edit" view.
  property var editTarget: null
  // A repeating alarm whose remove button was clicked once: the second click,
  // within a few seconds, deletes every occurrence.
  property string confirmId: ""
  // Set while the file chooser is up, or by a right click on the bar icon, so
  // the next open lands on the settings.
  property bool reopenOnSettings: false
  property var preview: null
  property string actionError: ""
  // Set when Enter finds no time in the draft, cleared by the next keystroke.
  // Only on Enter: while "tomorrow" is being typed it is not a time yet either,
  // and a hint that flickers on every half-word is noise.
  property bool missingTime: false

  // One cursor over the list, with -1 meaning "nowhere, keep typing". The text
  // field keeps the focus the whole time, because typing is what this panel is
  // for and a cursor that steals it would make the arrow keys and the letters
  // fight over the same keyboard. Down walks into the list, typing walks back
  // out of it.
  property int cursor: -1

  // The field accepts far more than the one shape a single placeholder can
  // show, and none of it is guessable: nobody tries "wed 18:15" at a box that
  // only ever said "15:15". So the placeholder is a different one on every
  // open, which teaches the range without anything moving on screen.
  readonly property var examples: [
    "15:15 pick up the kids",
    "5m tea",
    "tomorrow 9:00 dentist",
    "wed 18:15 hockey",
    "1h30 call Paul",
    "2d water the plants"
  ]
  property int exampleIndex: 0

  function moveCursor(step) {
    if (alarms.length === 0) { cursor = -1; return }
    var next = cursor + step
    if (next < -1) next = -1
    if (next >= alarms.length) next = alarms.length - 1
    cursor = next
  }

  function cursorAlarm() {
    if (cursor < 0 || cursor >= alarms.length) return null
    return alarms[cursor]
  }

  // The list is rebuilt on every refresh, so an index that pointed at the last
  // row has to be brought back in range or the cursor lands on nothing.
  onAlarmsChanged: if (cursor >= alarms.length) cursor = alarms.length - 1

  // --- formatting ----------------------------------------------------------

  // Deliberately the same shapes bin/nag prints, because both end up on screen
  // together: the panel's list is rendered here and a notification body comes
  // from the script.
  function formatRemaining(seconds) {
    if (seconds < 0) seconds = 0
    var days = Math.floor(seconds / 86400)
    var hours = Math.floor((seconds % 86400) / 3600)
    var minutes = Math.floor((seconds % 3600) / 60)
    var secs = seconds % 60

    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + (minutes < 10 ? "0" : "") + minutes + "m"
    if (minutes > 0) return minutes + "m"
    return secs + "s"
  }

  function remainingFor(alarm) {
    if (!alarm) return ""
    if (alarm.ringing) return "now"
    return formatRemaining(Number(alarm.at) - root.nowSeconds)
  }

  // Everything that reaches a Text element here is PlainText, but the shared
  // bar tooltip is the shell's own component and its textFormat is not ours to
  // set, so the angle brackets come out before a message gets there.
  function plain(value) {
    return String(value || "")
      // Markup characters first: the bar tooltip, the notification body and
      // the shell's own components render with AutoText and this plugin
      // cannot pin their format. Then C0/C1 and the bidi overrides, which can
      // reorder a label into saying something it does not say.
      .replace(/[<>&]/g, " ")
      .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .slice(0, 200)
  }

  function labelFor(alarm) {
    var message = plain(alarm && alarm.message ? alarm.message : "")
    return message.length > 0 ? message : "Alarm"
  }

  // What the bar says on hover: "Tea at 11:25", "Dentist tomorrow at 09:00".
  // A message is typed in the middle of a sentence and arrives lowercase, so it
  // gets the capital here rather than being stored with one.
  function sentenceFor(alarm) {
    if (!alarm) return "No alarms"
    var label = labelFor(alarm)
    label = label.charAt(0).toUpperCase() + label.slice(1)
    if (alarm.ringing) return label + " now"
    return label + " " + plain(alarm.atPhrase || "")
  }

  // --- the bar -------------------------------------------------------------

  // The last five minutes go red. That is the window where the countdown stops
  // being information and starts being something to act on: it is the point
  // where you still have time to put your shoes on, and the point after which
  // you no longer do.
  readonly property int soonSeconds: 300

  function isSoon(alarm) {
    if (!alarm) return false
    if (alarm.ringing) return true
    return (Number(alarm.at) - root.nowSeconds) <= root.soonSeconds
  }

  readonly property bool nextIsSoon: ringingCount > 0 || isSoon(nextAlarm)

  // The countdown shows from countdownMinutes before the next alarm, or as
  // soon as one is set with 0: an alarm that rings tomorrow, a repeat above
  // all, is nothing to keep in the bar until then.
  readonly property int countdownMinutes: {
    var minutes = Number(setting("countdownMinutes", 60))
    return minutes >= 0 && minutes <= 1440 ? Math.floor(minutes) : 60
  }
  readonly property bool upcoming: !!nextAlarm && (countdownMinutes === 0 || Number(nextAlarm.at) - nowSeconds <= countdownMinutes * 60)

  readonly property string barLabel: {
    if (ringingCount > 0) return "now"
    if (!upcoming) return ""
    return remainingFor(nextAlarm)
  }

  TextMetrics {
    id: barMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: root.barLabel
  }

  // Panel is a bare Item, so it has no size of its own and the bar would give
  // the widget zero width. Set it here from the metrics, never from a child
  // that fills this item: that is a loop where nothing decides the size and
  // everything collapses to zero, which still draws but cannot be clicked.
  readonly property int barSlot:
    Style.bar.iconFont
    + (barLabel !== "" ? Math.ceil(barMetrics.width) + Style.space(5) : 0)
    + Style.space(14)

  // With hideWhenIdle, a Nag with no alarm coming up behaves like Omarchy's
  // indicators: no slot until the pointer comes onto the bar, then a dimmed
  // icon to click.
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property bool idle: ringingCount === 0 && !upcoming && !opened
  readonly property bool barPeek: !!bar && bar.centerSectionRevealHeld === true && bar.centerHoverRevealSuppressed !== true
  readonly property bool shown: !hideWhenIdle || !idle || barPeek
  readonly property int shownSlot: shown ? barSlot : 0

  readonly property bool vertical: !!bar && bar.vertical
  implicitWidth: vertical ? bar.barSize : shownSlot
  implicitHeight: vertical ? shownSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // --- talking to the script -----------------------------------------------

  function refresh() {
    if (!listRun.running) listRun.start(["list"])
  }

  function applyList(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { return }
    if (!data || data.ok !== true) return

    alarms = data.alarms || []
    ringingCount = Number(data.ringingCount || 0)
    nextAlarm = data.next || null

    // Wake up exactly when the next alarm is due rather than polling for it.
    // The poll below is only a safety net for alarms set from the CLI.
    fireTimer.stop()
    if (nextAlarm) {
      var wait = (Number(nextAlarm.at) - Math.floor(Date.now() / 1000)) * 1000 + 1500
      if (wait > 0 && wait < 2147483) {
        fireTimer.interval = wait
        fireTimer.start()
      }
    }
  }

  function runAction(args) {
    if (actionRun.running) return
    actionError = ""
    actionRun.start(args)
  }

  function setAlarm() {
    var text = draft.trim()
    if (text.length === 0) return
    if (preview && preview.ok === false) missingTime = true
    if (!preview || preview.ok !== true) return
    if (view === "edit" && editTarget) {
      runAction(["edit", String(editTarget.id), text])
      showView("alarms")
    } else {
      runAction(["set", text])
    }
    draft = ""
    preview = null
  }

  // Cancels a pending alarm, or stops a ringing one.
  function removeAlarm(id) { runAction(["cancel", String(id)]) }
  function snoozeAlarm(id) { runAction(["snooze", String(id), String(snoozeMinutes)]) }
  function skipAlarm(id) { runAction(["skip", String(id)]) }

  // The remove button and Delete. A repeat goes on the second press, so one
  // slip does not lose every occurrence.
  function removeRow(alarm) {
    if (alarm.repeat && !alarm.ringing && confirmId !== String(alarm.id)) {
      confirmId = String(alarm.id)
      confirmReset.restart()
      return
    }
    confirmId = ""
    removeAlarm(alarm.id)
  }

  // The field, filled with the alarm as text, in a view of its own: Enter
  // replaces the alarm with what it then says. A ringing alarm comes back as
  // a snooze to adjust, since its own time has gone.
  function startEdit(alarm) {
    editTarget = alarm
    cursor = -1
    missingTime = false
    actionError = ""
    draft = alarm.ringing ? snoozeMinutes + "m " + (alarm.message || "") : String(alarm.spec || "")
    showView("edit")
    requestPreview()
  }

  // What Enter on a ringing alarm does: snooze, the only thing worth one key
  // when an alarm is going off in front of you, or dismiss with snooze off.
  function answerAlarm(id) {
    if (snoozeOn) snoozeAlarm(id)
    else removeAlarm(id)
  }

  function expandHome(path) {
    return path.replace(/^~(?=\/)/, Quickshell.env("HOME"))
  }

  // A file chooser, opened on the current sound when it lives in the sounds
  // folder, else on the folder. The panel closes so the chooser gets the
  // keyboard; the pick is saved when it comes back, and the panel reopens on
  // the settings, where the play button can try it. The folder is seeded only
  // when it does not exist yet, so a sound you deleted from it stays deleted.
  function chooseSound() {
    var current = expandHome(soundPath)
    var start = current.indexOf(soundsDir + "/") === 0 ? current : soundsDir + "/"
    soundChooser.command = ["bash", "-c",
      'dir=$1; start=$2; shift 2; if [[ ! -d $dir ]]; then mkdir -p -- "$dir" && cp -n -- "$@" "$dir"/; fi; ' +
      'exec zenity --file-selection --title="Alarm sound" --filename="$start" ' +
      '--file-filter="Audio | *.oga *.ogg *.opus *.wav *.flac *.mp3" --file-filter="All files | *"',
      "nag-sound", soundsDir, start].concat(seedSounds)
    soundPreview.running = false
    soundChooser.running = true
    reopenOnSettings = true
    close()
  }

  // Settings live in this widget's entry in shell.json, like any bar widget's,
  // so the panel writes them the way `omarchy bar set` does from a terminal and
  // reads them back through setting().
  function writeSetting(key, value) {
    Quickshell.execDetached(["omarchy-bar", "set", "jankeesvw.nag", key, JSON.stringify(value), "--json"])
  }

  // Right click on the bar icon: open on the settings, switch to them, or
  // close when they are already showing.
  function toggleSettings() {
    if (opened && view === "settings") { close(); return }
    if (opened) { showView("settings"); return }
    reopenOnSettings = true
    open()
  }

  function showView(next) {
    if (view === "edit" && next !== "edit") {
      editTarget = null
      draft = ""
      preview = null
      missingTime = false
    }
    view = next
    if (next === "settings") keyCatcher.forceActiveFocus()
    else Qt.callLater(function() { inputField.forceActiveFocus() })
  }

  function requestPreview() {
    if (draft.trim().length === 0) { preview = null; return }
    previewDebounce.restart()
  }

  // One run of bin/nag at a time, handing back its exit code and stdout.
  //
  // The output is read deliberately not with StdioCollector: that retains the
  // whole stream before any length check of ours can run, inside the one
  // process that hosts every widget on the desktop. SplitParser with an empty
  // marker hands over raw chunks instead, so the budget is enforced while the
  // bytes arrive. bin/nag already bounds what it prints, but a cap that lives
  // only in the producer is a cap that disappears the day something replaces
  // the producer.
  //
  // Deadline, then TERM, then KILL: a helper that never exits would otherwise
  // hold its Process object forever.
  component ScriptRun: QtObject {
    id: run
    property string script: ""
    readonly property int maxBytes: 131072
    readonly property int deadlineMs: 15000
    readonly property bool running: proc.running
    property string buffer: ""
    property bool overflowed: false
    signal done(int exitCode, string output)

    function start(args) {
      buffer = ""
      overflowed = false
      proc.command = [script].concat(args)
      proc.running = true
    }

    function stop() {
      if (!proc.running) return
      proc.signal(15)
      kill.start()
    }

    property Process proc: Process {
      stdout: SplitParser {
        splitMarker: ""
        onRead: function(chunk) {
          if (run.overflowed) return
          if (run.buffer.length + chunk.length > run.maxBytes) {
            run.overflowed = true
            run.buffer = ""
            run.stop()
            return
          }
          run.buffer += chunk
        }
      }
      onRunningChanged: if (running) deadline.restart(); else { deadline.stop(); kill.stop() }
      onExited: function(exitCode) {
        var output = run.buffer
        run.buffer = ""
        run.done(run.overflowed ? -1 : exitCode, output)
      }
    }
    property Timer deadline: Timer { interval: run.deadlineMs; onTriggered: run.stop() }
    property Timer kill: Timer { interval: 2000; onTriggered: run.proc.signal(9) }
  }

  function parseJson(raw) {
    try { return JSON.parse(raw) } catch (e) { return null }
  }

  ScriptRun {
    id: listRun
    script: root.script
    onDone: function(exitCode, output) { if (exitCode === 0) root.applyList(output) }
  }

  ScriptRun {
    id: parseRun
    script: root.script
    onDone: function(exitCode, output) { root.preview = exitCode === 0 ? root.parseJson(output) : null }
  }

  ScriptRun {
    id: actionRun
    script: root.script
    onDone: function(exitCode, output) {
      var data = root.parseJson(output)
      if (exitCode !== 0) root.actionError = "that did not work"
      else if (data && data.ok === false) root.actionError = root.plain(data.error || "that did not work")
      root.refresh()
    }
  }

  // Nothing of ours should outlive the widget being torn down.
  Component.onDestruction: {
    listRun.stop()
    parseRun.stop()
    actionRun.stop()
  }

  // The play button's preview in the settings. A new file, the chooser opening or the
  // panel closing stops it, so a test never plays on over the next one.
  Process { id: soundPreview }
  onSoundPathChanged: soundPreview.running = false

  // A settings section: its title in the accent, with the section's own
  // on/off switch beside it when it has one and a line saying what that
  // switch does, then the section's cards, which fold away while it is off.
  component SettingsSection: Column {
    id: section
    property string title: ""
    property string description: ""
    property bool checked: true
    property bool hasSwitch: true
    property string fontFamily: Style.font.family
    default property alias content: sectionContent.data
    signal toggled()

    width: parent ? parent.width : 0
    spacing: Style.spacing.lg

    Item {
      width: parent.width
      height: Math.max(sectionHead.implicitHeight, sectionSwitch.height)

      Column {
        id: sectionHead
        anchors.left: parent.left
        anchors.right: sectionSwitch.left
        anchors.rightMargin: Style.spacing.rowPaddingX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: section.title
          color: Commons.Color.accent
          font.family: section.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          width: parent.width
          visible: section.description !== ""
          textFormat: Text.PlainText
          text: section.description
          color: Qt.darker(Commons.Color.foreground, 1.5)
          font.family: section.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ToggleSwitch {
        id: sectionSwitch
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: section.hasSwitch
        width: visible ? implicitWidth : 0
        checked: section.checked
        onToggled: section.toggled()
      }
    }

    Column {
      id: sectionContent
      width: parent.width
      spacing: Style.spacing.lg
      visible: section.checked || !section.hasSwitch
    }
  }

  // A settings card in the look of Toggle: title and description on the
  // left, the control (the default property) on the right, and an optional
  // full-width control under the text.
  component SettingCard: BorderSurface {
    id: card
    property string label: ""
    property string description: ""
    property string fontFamily: Style.font.family
    default property alias side: sideSlot.data
    property alias below: belowSlot.data

    width: parent ? parent.width : 0
    implicitHeight: Math.max(54, body.implicitHeight + Style.spacing.huge)
    radius: Style.cornerRadius
    color: Style.controlFill(false, false, Commons.Color.foreground, Commons.Color.accent)
    borderSpec: Border.controlSpec("normal", Commons.Color.foreground, Commons.Color.accent)

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: card.borderLeft + Style.spacing.rowPaddingX
      anchors.rightMargin: card.borderRight + Style.spacing.rowPaddingX
      spacing: Style.spacing.lg

      Row {
        width: parent.width
        spacing: Style.spacing.rowPaddingX

        Column {
          width: parent.width - sideSlot.width - (sideSlot.width > 0 ? parent.spacing : 0)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: card.label
            color: Commons.Color.foreground
            font.family: card.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            visible: card.description !== ""
            textFormat: Text.PlainText
            text: card.description
            color: Qt.darker(Commons.Color.foreground, 1.5)
            font.family: card.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Item {
          id: sideSlot
          anchors.verticalCenter: parent.verticalCenter
          width: childrenRect.width
          height: childrenRect.height
        }
      }

      Item {
        id: belowSlot
        width: parent.width
        height: childrenRect.height
        visible: children.length > 0
      }
    }
  }

  // zenity prints the chosen path on one line, and nothing on cancel.
  Process {
    id: soundChooser
    stdout: SplitParser {
      onRead: function(line) {
        var path = line.trim()
        if (path.length > 0 && path.length <= 4096) root.writeSetting("sound", path)
      }
    }
    // Picked or cancelled, back to the settings the chooser was opened from.
    onExited: root.open()
  }

  // --- timers --------------------------------------------------------------

  // Only the displayed countdown, no process. Idle when there is nothing to
  // count down to.
  Timer {
    interval: 1000
    repeat: true
    running: root.alarms.length > 0
    onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
  }

  Timer { id: confirmReset; interval: 3000; onTriggered: root.confirmId = "" }

  Timer {
    id: fireTimer
    repeat: false
    onTriggered: root.refresh()
  }

  // Catches alarms set from somewhere else, which for this plugin means the
  // command line.
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: previewDebounce
    interval: 180
    repeat: false
    onTriggered: {
      if (parseRun.running) previewDebounce.restart()
      else parseRun.start(["parse", root.draft])
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Parameterless, and it only re-reads what the widget already re-reads on
    // its own timer. There is nothing here that changes state, deletes
    // anything, or hands back something private.
    function refresh(): void { root.refresh() }
  }

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (!opened) { soundPreview.running = false; return }
    refresh()

    // Open on an empty field. A half-typed alarm you walked away from is not
    // something to hand back later: these are disposable, and the draft is the
    // most disposable part of them.
    draft = ""
    preview = null
    actionError = ""
    missingTime = false
    cursor = -1
    editTarget = null
    confirmId = ""
    view = reopenOnSettings ? "settings" : "alarms"
    reopenOnSettings = false

    // A new example every time the panel opens, rather than on a timer. Over a
    // week you see all of them, and the line never moves while you are reading
    // it, which is what a rotating placeholder does wrong.
    exampleIndex = (exampleIndex + 1) % examples.length
  }

  BarIconButton {
    id: button
    visible: root.shown
    opacity: root.hideWhenIdle && root.idle ? 0.45 : 1
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    tooltipText: root.sentenceFor(root.ringingCount > 0 ? root.alarms[0] : root.nextAlarm)
    // Right click goes straight to the settings.
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleSettings()
      else root.toggle()
    }

    // The countdown belongs in the bar and not only in the panel: the whole
    // reason to set one of these is that you are looking at something else.
    // Not an iconComponent: the shell scales that down to icon size, which
    // would shrink the countdown next to the icon to a smudge.
    hasVisualContent: true

    Item {
      anchors.fill: parent
      Row {
        anchors.centerIn: parent
        spacing: Style.space(5)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.barIcon
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          color: root.nextIsSoon
            ? root.urgent
            : (root.opened || root.upcoming ? root.accent : root.foreground)

          // A ringing alarm has to be visible from across the room, and it
          // keeps pulsing until it is answered. That is the whole product.
          SequentialAnimation on opacity {
            running: root.ringingCount > 0
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: root.barLabel !== ""
          textFormat: Text.PlainText
          text: root.barLabel
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          renderType: Text.NativeRendering
          color: root.nextIsSoon ? root.urgent : root.foreground
        }
      }
    }
  }

  // A card in the middle of the screen, the way Omarchy's own reminder and menu
  // open, rather than a panel hanging off the bar. Anchored to the button, the
  // panel followed the bar's every resize and replayed the popup transitions
  // each time it grew; here it has nothing to follow.
  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "jankeesvw-nag"

    // The panel opens ready to type, or on the settings after the file
    // chooser. The surface maps a moment after `shown`, so the focus waits.
    onVisibleChanged: if (visible) Qt.callLater(function() { root.showView(root.view) })

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(360), panel.width - Style.gapsOut * 2)
      height: Math.min(contentTopInset + content.implicitHeight + contentBottomInset,
                       panel.height - y - Style.gapsOut)
      // Centred across, and pinned at a third of the way down rather than
      // centred: the card grows as alarms are added, and a card centred on its
      // own height would move up by half a row each time.
      x: Math.round((panel.width - width) / 2)
      y: Math.round(panel.height * 0.3)
      radius: Style.cornerRadius
      color: Commons.Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.popupPadding

      // Clicks on the card are not clicks outside it.
      MouseArea { anchors.fill: parent }
    }

    // A plain Item rather than PanelKeyCatcher. That component reads keys
    // before its descendants and turns Tab, Enter and Space into signals of its
    // own, which is right for a panel that is a list of rows and wrong for one
    // that is a form: every button here would be reachable with Tab and none of
    // them pressable, because the catcher ate the Enter first.
    Item {
      id: keyCatcher
      anchors.fill: card
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      clip: true
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          // Out of the settings or the edit first, then out of the panel.
          if (root.view !== "alarms") root.showView("alarms")
          else root.close()
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(8)

        // --- the field ------------------------------------------------------

        // The title on the left, with a way back while in the settings; the
        // gear on the right, where a settings button usually sits.
        Item {
          width: parent.width
          height: gear.height

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.view !== "alarms"
              focusable: false
              iconText: root.iconBack
              tooltipText: "Back"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showView("alarms")
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.view === "settings" ? "Settings" : root.view === "edit" ? "Edit alarm" : "New alarm"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.foreground, 1.5)
            }
          }

          PanelActionButton {
            id: gear
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            iconText: root.iconSettings
            tooltipText: root.view === "settings" ? "Back" : "Settings"
            foreground: root.view === "settings" ? root.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showView(root.view === "settings" ? "alarms" : "settings")
          }
        }

        TextField {
          id: inputField
          visible: root.view !== "settings"
          width: parent.width
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: root.examples[root.exampleIndex]
          text: root.draft
          // The shared TextField does not opt into the Tab ring on its own, so
          // without this you can tab out of the field and never tab back in.
          activeFocusOnTab: true

          onTextChanged: {
            if (text !== root.draft) {
              root.draft = text
              root.missingTime = false
              // Typing is a statement about the field, not about the list, so
              // it takes the cursor back out of the rows.
              root.cursor = -1
              root.requestPreview()
            }
          }

          // The field holds the focus for the whole life of the panel, so this
          // is where the panel's keys live. Up and Down do nothing in a
          // single-line field, which is what leaves them free to drive the list.
          Keys.onPressed: function(event) {
            var onRow = root.cursor >= 0

            switch (event.key) {
            case Qt.Key_Down:
              if (root.view === "alarms") root.moveCursor(1)
              event.accepted = true
              return

            case Qt.Key_Up:
              if (root.view === "alarms") root.moveCursor(-1)
              event.accepted = true
              return

            case Qt.Key_Return:
            case Qt.Key_Enter:
              if (onRow) {
                var alarm = root.cursorAlarm()
                if (alarm && alarm.ringing) root.answerAlarm(alarm.id)
              } else {
                root.setAlarm()
              }
              event.accepted = true
              return

            case Qt.Key_Delete:
              if (onRow) {
                var target = root.cursorAlarm()
                if (target) root.removeRow(target)
                event.accepted = true
              }
              return

            case Qt.Key_Escape:
              // Escape steps back out of the list first and closes the panel
              // second, so it never throws away a half-typed alarm by surprise.
              if (onRow) {
                root.cursor = -1
                event.accepted = true
              }
              return
            }
          }
        }

        // Reads back what the script made of it, live, so a time that will not
        // parse is visible before Enter rather than after.
        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: {
            if (root.actionError !== "" || root.missingTime) return root.urgent
            if (root.draft.trim() !== "" && root.preview && root.preview.ok === true) return root.accent
            return Qt.darker(root.foreground, 1.6)
          }
          // The same sentence the bar gives on hover, so what you are about to
          // get is spelled out in the words you will see afterwards: it reads
          // back both halves of the split, which is the only way to notice that
          // "wed 18:15 hockey" put the Wednesday in the time and not in the
          // message.
          // Nothing recognised means nothing to say. The line still occupies
          // its row under a list, though: a line that appears and disappears
          // would move the whole list up and down on the keystroke that makes a
          // time valid. With no list there is nothing to move, and a blank row
          // would only pad the bottom of the panel.
          visible: root.view === "edit" ? text !== " "
            : root.view === "alarms" && (root.alarms.length > 0 || text !== " ")
          text: {
            if (root.actionError !== "") return root.actionError
            if (root.missingTime) return "No time in that, add one: 5m, 15:15"
            if (!root.preview || root.preview.ok !== true) return " "

            return root.sentenceFor(root.preview)
              + ", in " + root.plain(root.preview.remaining)
          }
        }


        // --- the list -------------------------------------------------------

        PanelSeparator {
          width: parent.width
          visible: root.view === "alarms" && root.alarms.length > 0
        }

        Flickable {
          width: parent.width
          height: Math.min(alarmColumn.implicitHeight, Style.space(360))
          visible: root.view === "alarms" && root.alarms.length > 0
          clip: true
          contentWidth: width
          contentHeight: alarmColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: alarmColumn
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.alarms

              delegate: Rectangle {
                required property var modelData
                required property int index

                readonly property bool hasCursor: root.cursor === index
                readonly property bool soon: root.isSoon(modelData)
                readonly property color rowColor: soon ? root.urgent : root.foreground

                width: alarmColumn.width
                height: Math.max(Style.space(30), rowText.implicitHeight + Style.space(10))
                radius: Style.cornerRadius
                color: {
                  if (modelData.ringing) return Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.16)
                  if (hasCursor) return Style.hoverFill
                  return "transparent"
                }

                Row {
                  id: rowText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.right: rowActions.left
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.plain(modelData.atLabel)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                    color: rowColor
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.remainingFor(modelData)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    renderType: Text.NativeRendering
                    color: soon ? root.urgent : Qt.darker(root.foreground, 1.6)
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!modelData.repeatLabel
                    textFormat: Text.PlainText
                    text: root.iconRepeat + " " + root.plain(modelData.repeatLabel)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    renderType: Text.NativeRendering
                    color: Qt.darker(root.foreground, 1.6)
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, rowText.width - x)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: root.labelFor(modelData)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                    color: rowColor
                  }
                }

                // Declared left to right, because Tab follows the order the
                // children are written in and a ring that walks backwards is
                // one you have to look at to use.
                Row {
                  id: rowActions
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: modelData.ringing && root.snoozeOn
                    focusable: false
                    iconText: root.iconSnooze
                    tooltipText: "Snooze " + root.snoozeMinutes + " minutes"
                    foreground: rowColor
                    fontFamily: root.fontFamily
                    onClicked: root.snoozeAlarm(modelData.id)
                  }

                  // Skip, for a repeat that is not ringing yet.
                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !modelData.ringing && !!modelData.repeat
                    focusable: false
                    iconText: root.iconSkip
                    tooltipText: "Skip this one"
                    foreground: rowColor
                    fontFamily: root.fontFamily
                    onClicked: root.skipAlarm(modelData.id)
                  }

                  // Edit, for every alarm, except a ringing one that offers
                  // a snooze instead: with snooze off, editing is how it is
                  // put off.
                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !(modelData.ringing && root.snoozeOn)
                    focusable: false
                    iconText: root.iconEdit
                    tooltipText: modelData.ringing ? "Put off" : "Edit"
                    foreground: rowColor
                    fontFamily: root.fontFamily
                    onClicked: root.startEdit(modelData)
                  }

                  PanelActionButton {
                    readonly property bool confirming: root.confirmId === String(modelData.id)
                    anchors.verticalCenter: parent.verticalCenter
                    focusable: false
                    iconText: confirming ? root.iconTrash : root.iconClose
                    tooltipText: modelData.ringing ? "Dismiss"
                      : confirming ? "Click again to delete every occurrence"
                      : modelData.repeat ? "Delete the repeat" : "Remove"
                    foreground: confirming ? root.urgent : rowColor
                    fontFamily: root.fontFamily
                    onClicked: root.removeRow(modelData)
                  }
                }
              }
            }
          }
        }

        // --- settings -------------------------------------------------------

        // One card per setting, each written as soon as it changes: there is no
        // Save, the way there is none anywhere else in the shell. Sound and
        // Snooze carry their on/off switch in their title.
        Column {
          width: parent.width
          visible: root.view === "settings"
          spacing: Style.space(14)

          SettingsSection {
            title: "Bar"
            hasSwitch: false
            fontFamily: root.fontFamily

            // The icon is always in the bar; with no alarm set, this says
            // whether it shows all the time or only on hover.
            SettingCard {
              fontFamily: root.fontFamily
              label: "Show the icon"
              description: "With no alarm coming up"

              ButtonGroup {
                value: root.hideWhenIdle ? "hover" : "always"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                options: [
                  { value: "always", label: "Always" },
                  { value: "hover", label: "On hover" }
                ]
                onChanged: function(value) { root.writeSetting("hideWhenIdle", value === "hover") }
              }
            }

            SettingCard {
              fontFamily: root.fontFamily
              label: "Countdown"
              description: "Minutes before the next alarm it shows from, 0 as soon as one is set"

              NumberField {
                from: 0
                to: 1440
                value: root.countdownMinutes
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onModified: function(value) { root.writeSetting("countdownMinutes", value) }
              }
            }

            // A few glyphs that read as "alarm", the timer first because it is
            // the default and is stored as no setting at all.
            SettingCard {
              fontFamily: root.fontFamily
              label: "Icon"
              description: "In the bar and on the notification"

              ButtonGroup {
                value: String(root.setting("icon", "") || "")
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.bar.iconFont
                options: [
                  { value: "", label: root.iconTimer, tooltip: "Timer" },
                  { value: "\uDB82\uDC8C", label: "\uDB82\uDC8C", tooltip: "Omarchy reminder" },
                  { value: "\uDB80\uDC20", label: "\uDB80\uDC20", tooltip: "Alarm clock" },
                  { value: "\uDB80\uDC9A", label: "\uDB80\uDC9A", tooltip: "Bell" }
                ]
                onChanged: function(value) { root.writeSetting("icon", value) }
              }
            }
          }

          SettingsSection {
            title: "Ringing"
            hasSwitch: false
            fontFamily: root.fontFamily

            SettingCard {
              fontFamily: root.fontFamily
              label: "Ring for"
              description: "Minutes an alarm rings before it is reported missed"

              NumberField {
                from: 1
                to: 60
                value: root.ringMinutes
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onModified: function(value) { root.writeSetting("ringMinutes", value) }
              }
            }
          }

          // The file and how often it plays only matter with a sound, so they
          // fold away with it.
          SettingsSection {
            title: "Sound"
            description: root.soundOn ? "Plays when an alarm goes off" : "Alarms ring silently, in the bar and the notification"
            checked: root.soundOn
            fontFamily: root.fontFamily
            onToggled: root.writeSetting("soundOn", !root.soundOn)

            SettingCard {
              fontFamily: root.fontFamily
              label: "Sound file"
              description: "Add your own sounds to " + root.soundsDir.replace(Quickshell.env("HOME"), "~")

              below: Row {
                width: parent.width
                spacing: Style.space(4)

                TextField {
                  id: soundField
                  width: parent.width - browseButton.width - playButton.width - parent.spacing * 2
                  anchors.verticalCenter: parent.verticalCenter
                  foreground: root.foreground
                  accent: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  placeholderText: root.defaultSound.replace(/^\/usr\/share\/sounds\//, "")
                  text: root.soundPath
                  onEditingFinished: if (text.trim() !== root.soundPath) root.writeSetting("sound", text.trim())
                }

                Button {
                  id: browseButton
                  anchors.verticalCenter: parent.verticalCenter
                  bordered: true
                  text: "Browse\u2026"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.chooseSound()
                }

                // Hear it before an alarm does, and stop it again. Plays what
                // is in the field, saved or not, and falls back the way
                // bin/nag does.
                PanelActionButton {
                  id: playButton
                  anchors.verticalCenter: parent.verticalCenter
                  focusable: false
                  iconText: soundPreview.running ? root.iconStop : root.iconPlay
                  tooltipText: soundPreview.running ? "Stop" : "Play"
                  foreground: soundPreview.running ? root.accent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (soundPreview.running) { soundPreview.running = false; return }
                    var path = root.expandHome(soundField.text.trim())
                    soundPreview.command = ["pw-play", "--", path.length > 0 ? path : root.defaultSound]
                    soundPreview.running = true
                  }
                }
              }
            }

            Toggle {
              width: parent.width
              label: "Repeat until answered"
              description: !root.soundRepeat ? "Plays once" : root.snoozeOn ? "Plays again until you snooze or dismiss" : "Plays again until you dismiss"
              checked: root.soundRepeat
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.writeSetting("soundRepeat", !root.soundRepeat)
            }

            SettingCard {
              fontFamily: root.fontFamily
              visible: root.soundRepeat
              label: "Pause between plays"
              description: "Seconds of silence before it plays again"

              NumberField {
                from: 0
                to: 60
                value: root.soundPause
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onModified: function(value) { root.writeSetting("soundPause", value) }
              }
            }
          }

          SettingsSection {
            title: "Snooze"
            description: root.snoozeOn ? "A snooze button in the panel and the notification" : "Ringing alarms can only be dismissed"
            checked: root.snoozeOn
            fontFamily: root.fontFamily
            onToggled: root.writeSetting("snoozeOn", !root.snoozeOn)

            SettingCard {
              fontFamily: root.fontFamily
              label: "Snooze length"
              description: "Minutes a snooze puts the alarm off"

              NumberField {
                from: 1
                to: 1440
                value: root.snoozeMinutes
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onModified: function(value) { root.writeSetting("snoozeMinutes", value) }
              }
            }
          }
        }
      }
    }
  }
}
