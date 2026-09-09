import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "gladimdim.omarchy-ai-watch"

  // ------------------------------------------------------------- Appearance
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  readonly property color cardBg: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color cardBorder: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color cardHover: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)

  // Fixed signal colours, not theme colours: green means answering and red means
  // gone no matter what palette the bar is wearing.
  readonly property color okColor: "#9ECE6A"
  readonly property color alarmColor: "#FF4D4D"
  readonly property color warnColor: "#F59E0B"
  // The watch face is black whatever the desktop is, so the preview is too.
  readonly property color faceColor: "#0B0B0F"

  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property int radiusVal: Style.cornerRadius > 0 ? Math.min(6, Style.cornerRadius) : 6

  // The widget deliberately does not load omarchy.ttf, the pixel typeface the
  // watch face draws its clock with. It matched the wrist, but a bitmap face at
  // UI sizes is simply hard to read, so every label here uses the bar's own font.

  /**
   * The four gauges, in the order they sit around the dial.
   *
   * One row per gauge feeds both the live face preview and the assignment tiles.
   * `start` is the arc's angle from twelve o'clock; each sweeps 80 degrees.
   * `defaultId` mirrors DEFAULT_SLOTS in server.py and GaugeSlot in the watch app.
   */
  readonly property var slotDefs: [
    { key: "top",    label: "⬆ TOP (12h)",  start: 320, color: "#D97757",
      defaultId: "claude:session-5-hour" },
    { key: "right",  label: "➡ RIGHT (3h)", start: 50,  color: "#38BDF8",
      defaultId: "grok:weekly" },
    { key: "bottom", label: "⬇ BTM (6h)",   start: 140, color: "#A855F7",
      defaultId: "antigravity:thinking-models-quota" },
    { key: "left",   label: "⬅ LEFT (9h)",  start: 230, color: "#9ECE6A",
      defaultId: "global:today-tokens" }
  ]

  // ------------------------------------------------------------- State
  property bool popupOpen: false
  property int activeTab: 0 // 0: Pairing, 1: LLM slots, 2: Setup

  property string serverPin: "----"
  property bool pairingOpen: false
  property int pairingSecondsLeft: 0
  property var pendingRequest: null
  property var watchStatus: ({ "connected": false, "device": "Waiting for watch", "battery": 100 })
  property var modelsData: []
  // Which provider panels the user has folded away, keyed by provider id.
  // Everything starts open: this list is also the picker, and hiding a choice
  // behind a click is worse than a long list.
  property var collapsedProviders: ({})
  property var slotsData: ({ "top": "", "right": "", "bottom": "", "left": "" })

  // Unlinking discards the pairing, so the button asks once before doing it.
  property bool confirmForget: false
  // Which gauge is being reassigned, "" when the picker is closed.
  property string editingSlot: ""

  // The bridge decides whether the two halves have drifted; the widget only
  // renders the verdict. "ok"/"unknown" mean there is nothing to say.
  readonly property string protocolState:
    watchStatus && watchStatus.protocolState ? watchStatus.protocolState : "unknown"
  readonly property bool protocolMismatch:
    protocolState === "legacy" || protocolState === "watch_older"
    || protocolState === "watch_newer"

  // "unpaired" nothing linked yet | "linked" paired but quiet | "online" checked in recently
  readonly property string watchState: watchStatus && watchStatus.state ? watchStatus.state : "unpaired"
  readonly property bool watchOnline: watchState === "online"
  readonly property bool watchLinked: watchState !== "unpaired"

  // Setup UI is only interesting until a watch is actually connected, so it
  // starts collapsed once one is. This is a binding, not a fixed value, so it
  // opens itself again if the watch goes away -- and a click still wins, because
  // assigning to it replaces the binding.
  property bool connectExpanded: !watchLinked

  // A slow block cursor, the way a terminal idles.
  property bool caretOn: true
  // Clock for the live preview, ticking just often enough for hh:mm.
  property string previewClock: Qt.formatTime(new Date(), "hh:mm")
  property var facePreview: null

  readonly property string serverScriptPath: pathFromUrl(Qt.resolvedUrl("server.py"))
  readonly property string setupScriptPath: pathFromUrl(Qt.resolvedUrl("setup.sh"))

  // Laptop-side installer. The watch cannot see this machine until the daemon
  // is up and the firewall lets TCP 8765 in. Polled independently of --status
  // so a dead daemon does not stall the checklist.
  property var setupStatus: ({ "ok": true, "steps": [], "tips": [], "lanIp": "", "port": 8765 })
  property bool setupChecked: false
  property bool setupReady: true
  property bool setupAutoOpened: false
  property string setupFixing: ""
  property string setupFixMessage: ""
  readonly property bool setupBusy: setupFixing !== ""
  readonly property var setupSteps: (setupStatus && setupStatus.steps) ? setupStatus.steps : []
  readonly property var setupTips: (setupStatus && setupStatus.tips) ? setupStatus.tips : []
  readonly property bool setupHasFixable: {
    var steps = root.setupSteps
    for (var i = 0; i < steps.length; i++) {
      if (steps[i] && !steps[i].ok && steps[i].fixable) return true
    }
    return false
  }
  readonly property string setupMissingSummary: {
    var steps = root.setupSteps
    var names = []
    for (var i = 0; i < steps.length; i++) {
      if (steps[i] && !steps[i].ok && steps[i].required) names.push(steps[i].title)
    }
    return names.join(" · ")
  }

  // ------------------------------------------------------------- Components

  /**
   * Every label in this widget: the bar's font, at the bar's foreground colour.
   *
   * textFormat is pinned to PlainText, not left on the AutoText default. Several
   * of these render strings that arrive over the network -- the watch's own
   * device name, its app version, the pending request's name -- and AutoText
   * sniffs for markup, so a device calling itself "<img src=...>" would have had
   * its name interpreted as rich text inside the shell process rather than shown.
   */
  component Body: Text {
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: root.foreground
    textFormat: Text.PlainText
  }

  /** A quieter Body, for the sentence under something. */
  component Caption: Text {
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    color: root.muted
    textFormat: Text.PlainText
  }

  /**
   * The shell's plain Button renders as unadorned text, so primary actions get a
   * real filled surface, a border and a hover state. Without those, "Add watch"
   * looked like a heading and simply never got clicked.
   */
  component ActionButton: Rectangle {
    id: actionBtn
    property string label: ""
    property bool primary: false
    property bool active: true
    signal activated()

    implicitHeight: Style.space(34)
    radius: root.radiusVal
    opacity: active ? 1.0 : 0.55
    color: !active ? root.cardBg
                   : primary ? (btnArea.containsMouse ? Qt.lighter(root.accent, 1.15) : root.accent)
                             : (btnArea.containsMouse ? root.cardHover : root.cardBg)
    border.color: active ? root.accent : root.cardBorder

    Body {
      anchors.centerIn: parent
      text: actionBtn.label
      font.bold: actionBtn.primary
      color: actionBtn.primary && actionBtn.active ? root.background : root.foreground
    }

    MouseArea {
      id: btnArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: actionBtn.active
      cursorShape: Qt.PointingHandCursor
      onClicked: actionBtn.activated()
    }
  }

  /** One of the tabs across the top of the panel. */
  component PanelTab: Rectangle {
    id: tab
    property string label: ""
    property int index: 0
    property bool alert: false

    implicitWidth: Style.space(80)
    implicitHeight: Style.space(28)
    Layout.fillWidth: true
    Layout.minimumWidth: Style.space(64)
    radius: root.radiusVal
    color: root.activeTab === tab.index ? root.accent
           : (tab.alert ? Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.18)
                        : root.cardBg)
    border.color: root.activeTab === tab.index ? root.accent
                  : (tab.alert ? root.warnColor : root.cardBorder)

    Body {
      anchors.centerIn: parent
      text: tab.label
      font.bold: true
      color: root.activeTab === tab.index ? Color.background
             : (tab.alert ? root.warnColor : root.foreground)
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.activeTab = tab.index
    }
  }

  /**
   * Runs `server.py` with some arguments and hands back whatever it printed.
   *
   * Every command the widget issues is this same shape, and each one used to
   * carry its own copy of the process, the collector and the wiring between them.
   */
  component ServerCommand: Process {
    id: cmd
    property var args: []
    signal finished(string output)

    command: ["python3", root.serverScriptPath].concat(cmd.args)
    running: false
    stdout: StdioCollector {
      id: collector
      waitForEnd: true
      onStreamFinished: cmd.finished(collector.text)
    }
  }

  /**
   * Runs setup.sh. Firewall / avahi changes go through pkexec from here, which
   * is what pops the system password dialog — there is no TTY in the bar.
   */
  component SetupCommand: Process {
    id: setupCmd
    property var args: []
    signal finished(int exitCode, string output)

    command: ["bash", root.setupScriptPath].concat(setupCmd.args)
    running: false
    stdout: StdioCollector {
      id: setupOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: setupErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var out = String(setupOut.text || "")
      var err = String(setupErr.text || "")
      var combined = (out + (out && err ? "\n" : "") + err).trim()
      setupCmd.finished(exitCode, combined)
    }
  }

  /** One laptop-side installer step: status, explanation, and a fix button. */
  component SetupStep: Rectangle {
    id: stepCard
    property var step: null
    signal fixRequested()

    readonly property bool stepOk: step && step.ok === true
    readonly property bool stepWarn: step && !step.ok && step.required === false
    readonly property color pipColor: !step ? root.muted
                                    : (stepOk ? root.okColor
                                              : (stepWarn ? root.warnColor : root.alarmColor))

    Layout.fillWidth: true
    implicitHeight: stepCol.implicitHeight + Style.space(24)
    radius: root.radiusVal
    color: root.cardBg
    border.color: stepOk ? root.cardBorder : pipColor

    ColumnLayout {
      id: stepCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(12)
      spacing: Style.space(6)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Rectangle {
          implicitWidth: Style.space(10)
          implicitHeight: Style.space(10)
          radius: width / 2
          color: stepCard.pipColor
        }
        Body {
          Layout.fillWidth: true
          text: stepCard.step && stepCard.step.title ? stepCard.step.title : ""
          font.bold: true
        }
        Caption {
          text: !stepCard.step ? ""
                : (stepCard.stepOk ? "Ready"
                                   : (stepCard.step.required ? "Required" : "Optional"))
          color: stepCard.pipColor
          font.bold: true
        }
      }

      Caption {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: stepCard.step && stepCard.step.hint ? stepCard.step.hint : ""
      }

      Body {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: stepCard.step && stepCard.step.detail ? stepCard.step.detail : ""
        color: stepCard.stepOk ? root.muted : root.foreground
      }

      ActionButton {
        visible: stepCard.step && !stepCard.stepOk && stepCard.step.fixable === true
        Layout.fillWidth: true
        primary: stepCard.step && stepCard.step.required === true
        active: !root.setupBusy
        label: {
          if (!stepCard.step) return ""
          if (root.setupFixing === stepCard.step.action)
            return stepCard.step.needsPassword ? "Waiting for password…" : "Working…"
          return stepCard.step.button || "Fix"
        }
        onActivated: stepCard.fixRequested()
      }
    }
  }

  /**
   * One quota, as a row: a colour flag, provider and title, the reading, and a
   * bar that animates to new values and pulses once the quota is nearly gone.
   *
   * While a gauge is being reassigned every row becomes a choice, and the one
   * already assigned to that gauge is marked.
   */
  component LimitRow: Rectangle {
    id: limitRow
    property var limit: null
    property bool picking: false
    property bool isCurrent: false
    signal chosen()

    readonly property color limitColor: (limit && limit.color) ? limit.color : root.okColor
    readonly property real pct:
      limit ? Math.min(1.0, Math.max(0.0, limit.percent || 0.0)) : 0.0

    implicitHeight: Style.space(44)
    radius: 4
    color: isCurrent ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                     : (picking && rowArea.containsMouse ? root.cardHover : root.cardBg)
    border.color: isCurrent ? root.accent : root.cardBorder

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: limitRow.picking
      cursorShape: Qt.PointingHandCursor
      onClicked: limitRow.chosen()
    }

    RowLayout {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(10)

      Rectangle {
        width: 4
        Layout.fillHeight: true
        radius: 2
        color: limitRow.limitColor
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 2

        RowLayout {
          spacing: Style.space(6)
          Body {
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: limitRow.limit ? limitRow.limit.title : ""
            font.bold: true
          }
          Body {
            text: !limitRow.limit ? ""
                  : (limitRow.limit.valueFormatted ? limitRow.limit.valueFormatted
                                                   : (limitRow.limit.percentInt + "%"))
            font.bold: true
            color: limitRow.limitColor
          }
        }

        Rectangle {
          id: track
          Layout.fillWidth: true
          height: Style.space(6)
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

          readonly property bool nearlyGone: limitRow.pct >= 0.9

          Rectangle {
            id: fill
            width: track.width * limitRow.pct
            height: parent.height
            radius: height / 2
            color: limitRow.limitColor

            Behavior on width {
              NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
            }

            SequentialAnimation on opacity {
              running: track.nearlyGone
              loops: Animation.Infinite
              NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutQuad }
            }
          }

          // A bright cap at the leading edge, like the round ends of the arcs on
          // the watch face.
          Rectangle {
            visible: limitRow.pct > 0.02 && limitRow.pct < 0.995
            width: track.height
            height: track.height
            radius: height / 2
            x: Math.max(0, fill.width - width)
            color: Qt.lighter(limitRow.limitColor, 1.4)

            Behavior on x {
              NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
            }
          }
        }
      }
    }
  }

  /**
   * A miniature of the watch face as it looks on the wrist right now: the same
   * four quadrant arcs, the same colours, filled to the same levels.
   *
   * It is the one place the two halves of this project are visible at once, and
   * it turns an otherwise flat status card into something worth glancing at.
   */
  component FacePreview: Canvas {
    id: face
    implicitWidth: Style.space(112)
    implicitHeight: Style.space(112)

    readonly property int arcSweep: 80

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var cx = width / 2, cy = height / 2
      var r = Math.min(width, height) / 2 - 6

      // The face itself
      ctx.beginPath()
      ctx.arc(cx, cy, r + 5, 0, Math.PI * 2)
      ctx.fillStyle = root.faceColor
      ctx.fill()

      ctx.lineCap = "round"
      ctx.lineWidth = 4

      for (var i = 0; i < root.slotDefs.length; i++) {
        var def = root.slotDefs[i]
        var model = root.slotModel(def.key)
        var pct = model ? Math.max(0, Math.min(1, model.percent)) : 0

        // Canvas measures from three o'clock, the face measures from twelve.
        var from = (def.start - 90) * Math.PI / 180
        var full = face.arcSweep * Math.PI / 180

        ctx.beginPath()
        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.10)
        ctx.arc(cx, cy, r, from, from + full)
        ctx.stroke()

        if (pct > 0.01) {
          ctx.beginPath()
          ctx.strokeStyle = (model && model.color) ? model.color : def.color
          ctx.arc(cx, cy, r, from, from + full * pct)
          ctx.stroke()
        }
      }
    }

    Body {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -Style.space(3)
      text: root.previewClock
      font.pixelSize: Style.font.subtitle
      font.bold: true
      color: "#FFFFFF"
    }

    Caption {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.verticalCenter
      anchors.topMargin: Style.space(6)
      visible: root.watchOnline && root.watchStatus && root.watchStatus.battery !== undefined
      text: root.watchStatus ? root.watchStatus.battery + "%" : ""
      color: root.watchStatus && root.watchStatus.battery <= 30 ? root.alarmColor : root.okColor
    }

    Component.onCompleted: root.facePreview = face
  }

  // ------------------------------------------------------------- Functions

  function pathFromUrl(url) {
    var val = String(url || "")
    if (val.indexOf("file://") === 0) return decodeURIComponent(val.substring(7))
    return val
  }

  /**
   * Resolves what a gauge is currently tracking into its live reading.
   * Returns null when the model list has not arrived yet.
   */
  function slotModel(key) {
    if (!root.slotsData || !root.modelsData) return null
    var id = root.slotsData[key]
    if (!id) return null
    for (var i = 0; i < root.modelsData.length; i++) {
      if (root.modelsData[i].id === id) return root.modelsData[i]
    }
    return null
  }

  /** "just now", "12m ago", "3h ago" -- how long since the watch last spoke. */
  function lastSeenText() {
    if (!watchStatus || watchStatus.secondsSinceSync === undefined) return ""
    var secs = watchStatus.secondsSinceSync
    if (secs < 0) return "no data yet"
    if (secs < 90) return "just now"
    if (secs < 3600) return Math.floor(secs / 60) + "m ago"
    if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
    return Math.floor(secs / 86400) + "d ago"
  }

  /**
   * Folds the flat limit list into one panel per provider, keeping the order the
   * bridge sent so the aggregate "Total AI" counters stay at the bottom.
   *
   * `peak` is the fullest limit in the group, which is what the collapsed header
   * reports -- the whole point of folding a provider away is still knowing
   * whether anything inside it is about to run out.
   */
  function groupByProvider(models) {
    var order = []
    var byId = ({})

    for (var i = 0; i < models.length; i++) {
      var m = models[i]
      var id = m.providerId || "other"
      if (byId[id] === undefined) {
        byId[id] = { id: id, name: m.providerName || id,
                     color: m.color || root.okColor, items: [], peak: 0 }
        order.push(id)
      }
      var group = byId[id]
      group.items.push(m)
      var pct = Math.min(1, Math.max(0, m.percent || 0))
      if (pct > group.peak) group.peak = pct
    }

    var out = []
    for (var j = 0; j < order.length; j++) out.push(byId[order[j]])
    return out
  }

  readonly property var limitGroups: groupByProvider(modelsData)

  function providerCollapsed(id) {
    return root.collapsedProviders[id] === true
  }

  readonly property bool allProvidersCollapsed: {
    if (limitGroups.length === 0) return false
    for (var i = 0; i < limitGroups.length; i++) {
      if (!providerCollapsed(limitGroups[i].id)) return false
    }
    return true
  }

  function setAllProvidersCollapsed(collapse) {
    var next = ({})
    if (collapse) {
      for (var i = 0; i < limitGroups.length; i++) next[limitGroups[i].id] = true
    }
    root.collapsedProviders = next
  }

  function toggleProvider(id) {
    // Replaced rather than mutated: assigning a new object is what re-evaluates
    // the bindings that read it.
    var next = ({})
    for (var k in root.collapsedProviders) next[k] = root.collapsedProviders[k]
    next[id] = !next[id]
    root.collapsedProviders = next
  }

  function repaintFace() {
    if (root.facePreview) root.facePreview.requestPaint()
  }

  function toggle() {
    popupOpen = !popupOpen
  }

  function close() {
    popupOpen = false
  }

  function triggerPress(button) {
    if (button === Qt.LeftButton) toggle()
    else if (button === Qt.MiddleButton) refreshData()
  }

  function refreshData() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function applySetupStatus(output) {
    try {
      var res = JSON.parse(output)
      if (!res || !res.steps) return
      root.setupStatus = res
      root.setupChecked = true
      root.setupReady = res.ok === true
      if (root.popupOpen && !root.setupReady && !root.setupAutoOpened) {
        root.activeTab = 2
        root.setupAutoOpened = true
      }
    } catch (e) {
      // Leave the last good checklist on screen.
    }
  }

  function refreshSetup() {
    if (root.setupBusy) return
    if (!setupStatusProcess.running) setupStatusProcess.running = true
  }

  function runSetupFix(action) {
    if (root.setupBusy) return
    var target = action || "all"
    root.setupFixing = target
    root.setupFixMessage = (target === "firewall" || target === "all" || target === "avahi")
                           ? "A system password prompt should appear."
                           : "Starting the background daemon…"
    setupFixProcess.args = ["--fix-" + target]
    setupFixProcess.running = true
  }

  function regeneratePin() {
    if (!regenProcess.running) regenProcess.running = true
  }

  /**
   * Opens a short window during which the next watch that asks can connect with
   * nothing to type. The deliberate action belongs here, on a machine with a
   * mouse, rather than on a four-digit keypad on a watch.
   */
  function addWatch() {
    if (!pairProcess.running) pairProcess.running = true
  }

  function forgetWatch() {
    if (!forgetProcess.running) forgetProcess.running = true
  }

  function answerWatch(approve) {
    if (!root.pendingRequest) return
    decisionProcess.args = [approve ? "--approve" : "--deny", root.pendingRequest.id]
    decisionProcess.running = true
  }

  // A model id is "provider:limit-slug" and reaches argparse as a positional
  // value. One starting with a dash would be read as a flag instead, so ids are
  // checked against the shape the bridge actually produces before being spent
  // as arguments. Both come from the bridge today; this keeps that assumption
  // from being load-bearing.
  readonly property var idPattern: /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/

  function setSlot(slotKey, modelId) {
    if (setSlotProcess.running) return
    if (!root.idPattern.test(String(modelId))) return
    if (["top", "right", "bottom", "left"].indexOf(slotKey) === -1) return
    setSlotProcess.args = ["--set-slot", slotKey, modelId]
    setSlotProcess.running = true
  }

  // ------------------------------------------------------------- Processes

  ServerCommand {
    id: statusProcess
    args: ["--status"]
    onFinished: function(output) {
      try {
        var res = JSON.parse(output)
        if (res.pin) root.serverPin = res.pin
        root.pendingRequest = res.pendingRequest || null
        root.pairingOpen = res.pairingOpen === true
        root.pairingSecondsLeft = res.pairingSecondsRemaining || 0
        if (res.watchStatus) root.watchStatus = res.watchStatus
        if (res.models) root.modelsData = res.models
        if (res.slots) root.slotsData = res.slots
        root.repaintFace()
      } catch (e) {
        // A malformed payload just leaves the last good one on screen.
      }
    }
  }

  ServerCommand {
    id: setSlotProcess
    onFinished: function(output) {
      root.editingSlot = ""
      root.refreshData()
      root.repaintFace()
    }
  }

  ServerCommand {
    id: forgetProcess
    args: ["--forget"]
    onFinished: function(output) {
      root.confirmForget = false
      root.watchStatus = ({ "connected": false, "device": "Waiting for watch", "battery": 100 })
      root.refreshData()
    }
  }

  ServerCommand {
    id: decisionProcess
    onFinished: function(output) {
      // Clear it locally so the prompt goes away at once; the next poll confirms.
      root.pendingRequest = null
      root.refreshData()
    }
  }

  ServerCommand {
    id: pairProcess
    args: ["--pair-mode"]
    onFinished: function(output) {
      try {
        var res = JSON.parse(output)
        root.pairingOpen = res.pairingOpen === true
        root.pairingSecondsLeft = res.secondsRemaining || 0
      } catch (e) {
        // leave state as-is; the next --status poll will correct it
      }
    }
  }

  ServerCommand {
    id: regenProcess
    args: ["--new-pin"]
    onFinished: function(output) {
      var trimmed = output.trim()
      if (trimmed) root.serverPin = trimmed
    }
  }

  ServerCommand {
    id: setupStatusProcess
    args: ["--setup-status"]
    onFinished: function(output) {
      root.applySetupStatus(output)
    }
  }

  SetupCommand {
    id: setupFixProcess
    onFinished: function(exitCode, output) {
      root.setupFixing = ""
      if (exitCode === 0) {
        root.setupFixMessage = ""
      } else {
        var tail = String(output || "").trim()
        var lines = tail.split("\n")
        var last = lines.length ? lines[lines.length - 1] : ""
        root.setupFixMessage = last
                               ? last
                               : "That did not finish. If a password prompt appeared, it may have been cancelled."
      }
      root.refreshSetup()
      root.refreshData()
    }
  }

  // ------------------------------------------------------------- Timers

  Timer {
    interval: 600
    repeat: true
    running: root.popupOpen
    onTriggered: root.caretOn = !root.caretOn
  }

  Timer {
    interval: 10000
    repeat: true
    running: true
    onTriggered: {
      root.previewClock = Qt.formatTime(new Date(), "hh:mm")
      root.repaintFace()
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.pairingSecondsLeft > 0
    onTriggered: {
      root.pairingSecondsLeft -= 1
      if (root.pairingSecondsLeft <= 0) root.pairingOpen = false
    }
  }

  Timer {
    interval: root.popupOpen ? 3000 : 8000
    repeat: true
    running: true
    onTriggered: root.refreshData()
  }

  Timer {
    interval: root.popupOpen ? 4000 : 15000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshSetup()
  }

  Component.onCompleted: root.refreshData()

  // ------------------------------------------------------------- Dock Bar UI
  implicitWidth: dockItem.implicitWidth
  implicitHeight: root.barSize

  Item {
    id: dockItem
    anchors.fill: parent
    implicitWidth: dockContent.implicitWidth + Style.space(14)
    implicitHeight: root.barSize

    // Read by the bar off the registered click target, which is this item.
    property bool pressable: true
    property bool interactive: true
    property var registeredBar: null

    function triggerPress(button) {
      root.triggerPress(button)
    }

    function syncClickRegistration() {
      if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(dockItem)
      registeredBar = root.bar
      if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(dockItem)
    }
    Component.onCompleted: syncClickRegistration()
    Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(dockItem)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        root.triggerPress(mouse.button)
      }
    }

    RowLayout {
      id: dockContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      // The dock icon: a robot head with a smartwatch case standing behind it.
      // Drawn rather than set in a font. The glyph that used to sit here was
      // U+F07DF, commented "Nerd Font watch", but the icon font the bar actually
      // loads has a mushroom at that codepoint, so that is what the dock showed.
      //
      // The eyes and the watch's side button carry the connection state, which
      // is why the separate status dot that used to float over the glyph is
      // gone: green once a watch is online, red while one is paired but out of
      // touch, muted when none is known.
      Item {
        id: dockIcon
        implicitWidth: robot.width
        implicitHeight: robot.height

        // A watch that is paired but out of touch is the state worth noticing,
        // so it gets the alarming colour rather than a cautious amber. Nothing
        // paired yet is not a fault, so that one stays muted.
        readonly property color statusColor: root.watchOnline ? root.okColor
                                           : (root.setupChecked && !root.setupReady ? root.warnColor
                                           : (root.watchLinked ? root.alarmColor : root.muted))
        readonly property color inkColor: root.watchLinked ? root.foreground : root.muted

        onStatusColorChanged: robot.requestPaint()
        onInkColorChanged: robot.requestPaint()

        Canvas {
          id: robot
          anchors.centerIn: parent
          width: Style.space(22)
          height: width

          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)

            // Everything below is laid out on a 24x24 grid and scaled to
            // whatever the bar is actually giving us.
            var s = width / 24
            var ink = dockIcon.inkColor
            var status = dockIcon.statusColor
            // The watch is the status light: it is the biggest shape in the icon
            // and the one the eye lands on. Held a little under full strength so
            // the robot in front of it still reads as the nearer object.
            var behind = Qt.rgba(status.r, status.g, status.b, 0.85)

            ctx.lineJoin = "round"
            ctx.lineCap = "round"

            function rr(x, y, w, h, r) {
              ctx.beginPath()
              ctx.moveTo((x + r) * s, y * s)
              ctx.lineTo((x + w - r) * s, y * s)
              ctx.quadraticCurveTo((x + w) * s, y * s, (x + w) * s, (y + r) * s)
              ctx.lineTo((x + w) * s, (y + h - r) * s)
              ctx.quadraticCurveTo((x + w) * s, (y + h) * s, (x + w - r) * s, (y + h) * s)
              ctx.lineTo((x + r) * s, (y + h) * s)
              ctx.quadraticCurveTo(x * s, (y + h) * s, x * s, (y + h - r) * s)
              ctx.lineTo(x * s, (y + r) * s)
              ctx.quadraticCurveTo(x * s, y * s, (x + r) * s, y * s)
              ctx.closePath()
            }

            function dot(cx, cy, r) {
              ctx.beginPath()
              ctx.arc(cx * s, cy * s, r * s, 0, Math.PI * 2)
              ctx.closePath()
            }

            // --- the watch, behind. A cushion case with a round display and a
            // side button, which is the shape a Galaxy Watch Ultra cuts.
            ctx.fillStyle = behind
            rr(6.5, 0, 6.5, 3, 1)
            ctx.fill()
            rr(6.5, 18, 6.5, 3, 1)
            ctx.fill()

            ctx.strokeStyle = behind
            ctx.lineWidth = 1.7 * s
            rr(2.5, 2, 14.5, 16.5, 5)
            ctx.stroke()

            ctx.lineWidth = 1.1 * s
            dot(9.75, 10.25, 4.4)
            ctx.stroke()

            // The side button sits high on the case, clear of the antenna, and
            // travels with the rest of the watch.
            ctx.fillStyle = behind
            rr(17.0, 4.2, 1.9, 3.2, 0.8)
            ctx.fill()

            // --- punch the head out of the watch, so the head reads as being in
            // front of it without needing to know the bar's background colour.
            // Only the head is punched. Knocking out the antenna too left a notch
            // bitten through the side of the watch case.
            ctx.globalCompositeOperation = "destination-out"
            ctx.fillStyle = "#000000"
            rr(9.7, 11.4, 12.4, 10.2, 3.4)
            ctx.fill()
            ctx.globalCompositeOperation = "source-over"

            // --- the robot, in front. The antenna rises to the right of the
            // watch case, where there is nothing behind it to cut into, and it
            // is drawn before the head so the head covers its root.
            ctx.strokeStyle = ink
            ctx.lineWidth = 1.4 * s
            ctx.lineCap = "butt"
            ctx.beginPath()
            ctx.moveTo(19.4 * s, 12.6 * s)
            ctx.lineTo(19.4 * s, 10.4 * s)
            ctx.stroke()
            ctx.lineCap = "round"

            ctx.fillStyle = status
            dot(19.4, 9.6, 1.15)
            ctx.fill()

            ctx.fillStyle = Qt.rgba(ink.r, ink.g, ink.b, 0.12)
            rr(10.7, 12.4, 10.4, 8.2, 2.6)
            ctx.fill()
            ctx.strokeStyle = ink
            ctx.lineWidth = 1.5 * s
            rr(10.7, 12.4, 10.4, 8.2, 2.6)
            ctx.stroke()

            ctx.fillStyle = status
            dot(13.7, 15.8, 1.25)
            ctx.fill()
            dot(18.1, 15.8, 1.25)
            ctx.fill()

            ctx.fillStyle = Qt.rgba(ink.r, ink.g, ink.b, 0.75)
            rr(13.3, 18.2, 5.2, 1.2, 0.6)
            ctx.fill()
          }
        }
      }

      // Short status label in dock. Once a watch is paired the icon says
      // everything on its own, so the label steps aside entirely and the widget
      // sits in the tray as one icon, like everything around it. The name stays
      // up only while nothing is paired, so the widget is still findable then.
      //
      // The battery percentage used to live here and is gone: it is the watch's
      // own battery, it is already on the watch face, and a number that moves
      // once an hour earns no room in a bar.
      Body {
        visible: text !== ""
        font.pixelSize: Style.font.body
        font.bold: true
        text: (root.setupChecked && !root.setupReady) ? "Setup"
              : (root.watchLinked ? "" : "AI Watch")
      }
    }
  }

  // ------------------------------------------------------------- Popup Dialog
  KeyboardPanel {
    id: panel
    anchorItem: dockItem
    owner: root
    bar: root.bar
    open: root.popupOpen
    onOpenChanged: {
      if (root.popupOpen !== open) {
        root.popupOpen = open
      }
      if (open) {
        root.refreshSetup()
        if (root.setupChecked && !root.setupReady && !root.setupAutoOpened) {
          root.activeTab = 2
          root.setupAutoOpened = true
        }
      }
    }
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(Style.space(520), Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      // A faint scanline wash, the way a CRT reads. Drawn above the content but
      // transparent to input, so nothing below it stops being clickable.
      Canvas {
        anchors.fill: parent
        z: 999
        opacity: 0.05
        enabled: false
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          ctx.strokeStyle = root.foreground
          ctx.lineWidth = 1
          for (var y = 0; y < height; y += 3) {
            ctx.beginPath()
            ctx.moveTo(0, y + 0.5)
            ctx.lineTo(width, y + 0.5)
            ctx.stroke()
          }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(12)

        // Title on its own row so the three tabs never get clipped off the
        // right edge of the panel (PAIRING + LLM SLOTS already filled the old
        // single header line).
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(4)

          Body {
            text: "OMARCHY AI WATCH"
            font.pixelSize: Style.font.heading
            font.letterSpacing: 1
          }
          Rectangle {
            implicitWidth: Style.space(7)
            implicitHeight: Style.font.heading
            color: root.accent
            opacity: root.caretOn ? 0.9 : 0.0
            Behavior on opacity { NumberAnimation { duration: 90 } }
          }
          Item { Layout.fillWidth: true }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          PanelTab {
            Layout.fillWidth: true
            label: "PAIRING"
            index: 0
          }
          PanelTab {
            Layout.fillWidth: true
            label: "LLM SLOTS"
            index: 1
          }
          PanelTab {
            Layout.fillWidth: true
            label: (root.setupChecked && !root.setupReady) ? "SETUP !" : "SETUP"
            index: 2
            alert: root.setupChecked && !root.setupReady
          }
        }

        // ======================== TAB 0: WATCH STATUS & PAIRING ========================
        ColumnLayout {
          visible: root.activeTab === 0
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(12)

          // Laptop-side setup is not done. Pairing a watch will fail until it is,
          // so this sits above the status card the way a pending request does.
          Rectangle {
            visible: root.setupChecked && !root.setupReady
            Layout.fillWidth: true
            implicitHeight: setupBannerCol.implicitHeight + Style.space(24)
            radius: root.radiusVal
            color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.10)
            border.color: root.warnColor

            ColumnLayout {
              id: setupBannerCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Body {
                text: "This laptop is not reachable from a watch yet"
                font.bold: true
                color: root.warnColor
              }
              Caption {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: root.setupMissingSummary !== ""
                      ? ("Missing: " + root.setupMissingSummary + ".")
                      : "Open Setup to finish installing the bridge."
              }
              ActionButton {
                Layout.fillWidth: true
                primary: true
                label: "Open setup"
                onActivated: root.activeTab = 2
              }
            }
          }

          // The two halves have drifted. Shown above the status card because a
          // watch that is talking but misreading the wire format looks perfectly
          // healthy otherwise -- that is the whole reason this check exists.
          Rectangle {
            visible: root.protocolMismatch
            Layout.fillWidth: true
            implicitHeight: protoCol.implicitHeight + Style.space(24)
            radius: root.radiusVal
            color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.10)
            border.color: root.warnColor

            ColumnLayout {
              id: protoCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(4)

              Body {
                text: root.protocolState === "watch_newer"
                      ? "This bridge is out of date"
                      : "Your watch app is out of date"
                font.bold: true
                color: root.warnColor
              }

              Caption {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: root.protocolState === "watch_newer"
                      ? "The watch speaks a newer version of the protocol than this "
                        + "plugin. Update the Omarchy plugin on this machine; some "
                        + "readings may be wrong until you do."
                      : "The watch speaks an older version of the protocol than this "
                        + "plugin. Update Omarchy AI on the watch from the Play Store; "
                        + "some readings may be wrong until you do."
              }

              Caption {
                text: {
                  var watch = root.protocolState === "legacy"
                              ? "none"
                              : "v" + (root.watchStatus.protocolVersion || 0)
                  var app = root.watchStatus && root.watchStatus.appVersion
                            ? "  ·  watch app " + root.watchStatus.appVersion : ""
                  return "watch protocol " + watch + "  ·  bridge protocol v"
                         + (root.watchStatus.bridgeProtocolVersion || 0) + app
                }
                color: root.muted
              }
            }
          }

          // A watch is asking to connect. This is the one thing the user must act
          // on, so it sits above everything else and is styled to draw the eye.
          Rectangle {
            visible: root.pendingRequest !== null
            Layout.fillWidth: true
            implicitHeight: pendingCol.implicitHeight + Style.space(28)
            radius: root.radiusVal
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
            border.color: root.accent
            border.width: 2

            ColumnLayout {
              id: pendingCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(14)
              spacing: Style.space(8)

              Body {
                text: "A watch wants to connect"
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Body {
                text: root.pendingRequest ? root.pendingRequest.device : ""
                color: root.accent
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                ActionButton {
                  Layout.fillWidth: true
                  primary: true
                  label: "Approve"
                  onActivated: root.answerWatch(true)
                }
                ActionButton {
                  implicitWidth: Style.space(90)
                  label: "Deny"
                  onActivated: root.answerWatch(false)
                }
              }
            }
          }

          // Watch Connection Status Card
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: Style.space(132)
            radius: root.radiusVal
            color: root.cardBg
            border.color: root.cardBorder

            RowLayout {
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(14)

              // The watch itself, drawn live, instead of a static glyph.
              Item {
                implicitWidth: Style.space(112)
                implicitHeight: Style.space(112)

                // A soft halo that breathes while the watch is online, so the card
                // has a pulse rather than sitting there inert.
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width + Style.space(8)
                  height: parent.height + Style.space(8)
                  radius: width / 2
                  color: "transparent"
                  border.width: 2
                  border.color: root.watchOnline ? root.okColor : root.warnColor
                  opacity: 0.0

                  SequentialAnimation on opacity {
                    running: root.watchOnline
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.55; duration: 1400; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 0.10; duration: 1400; easing.type: Easing.InOutQuad }
                  }
                }

                FacePreview { anchors.centerIn: parent }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)

                RowLayout {
                  spacing: Style.space(8)
                  Body {
                    text: root.watchStatus && root.watchStatus.device
                          ? root.watchStatus.device : "Galaxy Watch"
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }
                  Rectangle {
                    implicitWidth: Style.space(62)
                    implicitHeight: Style.space(18)
                    radius: 4
                    color: root.watchOnline
                           ? Qt.rgba(root.okColor.r, root.okColor.g, root.okColor.b, 0.2)
                           : Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.2)
                    Caption {
                      anchors.centerIn: parent
                      text: root.watchOnline ? "ONLINE" : (root.watchLinked ? "LINKED" : "WAITING")
                      font.bold: true
                      color: root.watchOnline ? root.okColor : root.warnColor
                    }
                  }
                }

                Body {
                  text: root.watchOnline
                    ? "Battery: " + root.watchStatus.battery + "% • Synced " + root.lastSeenText()
                    : root.watchLinked
                      ? "Linked, but quiet. Last seen " + root.lastSeenText() + "."
                      : "Open Omarchy AI on your Galaxy Watch to connect"
                  color: root.muted
                }

                ActionButton {
                  visible: root.watchLinked
                  implicitWidth: Style.space(150)
                  implicitHeight: Style.space(26)
                  label: root.confirmForget ? "Click again to unlink" : "Unlink this watch"
                  onActivated: {
                    if (!root.confirmForget) root.confirmForget = true
                    else root.forgetWatch()
                  }
                }
              }
            }
          }

          // One-Time Pairing PIN Card. Height follows the content so the card is
          // a single row when collapsed and as tall as it needs when open.
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: connectCol.implicitHeight + Style.space(32)
            radius: root.radiusVal
            color: root.cardBg
            border.color: root.cardBorder

            ColumnLayout {
              id: connectCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(16)
              spacing: Style.space(10)

              // Clickable header. Collapsed, this card is a single row.
              MouseArea {
                Layout.fillWidth: true
                implicitHeight: connectHeader.implicitHeight
                cursorShape: Qt.PointingHandCursor
                onClicked: root.connectExpanded = !root.connectExpanded

                RowLayout {
                  id: connectHeader
                  anchors.fill: parent
                  spacing: Style.space(8)

                  Body {
                    text: root.connectExpanded ? "▾" : "▸"
                    color: root.muted
                  }
                  Body {
                    text: "[ CONNECT A WATCH ]"
                    font.letterSpacing: 1
                    color: root.muted
                  }
                  Item { Layout.fillWidth: true }
                  Caption {
                    visible: !root.connectExpanded
                    text: "Show"
                    color: root.accent
                  }
                }
              }

              // Everything below is setup, hidden unless asked for.
              ColumnLayout {
                Layout.fillWidth: true
                visible: root.connectExpanded
                spacing: Style.space(10)

                // Primary action. While this window is open the watch connects
                // with nothing typed on it at all.
                ActionButton {
                  Layout.fillWidth: true
                  primary: true
                  active: !root.pairingOpen
                  label: root.pairingOpen
                         ? "Ready — open the app on your watch (" + root.pairingSecondsLeft + "s)"
                         : "Add another watch"
                  onActivated: root.addWatch()
                }

                Caption {
                  Layout.fillWidth: true
                  visible: root.pairingOpen
                  wrapMode: Text.WordWrap
                  text: "Open Omarchy AI on your watch and tap Connect."
                  color: root.accent
                }

                Caption { text: "Or use a code:" }

                // Big 4-digit PIN Display
                Rectangle {
                  Layout.fillWidth: true
                  implicitHeight: Style.space(64)
                  radius: root.radiusVal
                  color: Qt.rgba(0, 0, 0, 0.3)
                  border.color: root.accent

                  RowLayout {
                    anchors.centerIn: parent
                    spacing: Style.space(16)

                    Repeater {
                      model: root.serverPin ? root.serverPin.split("") : ["-", "-", "-", "-"]
                      Rectangle {
                        implicitWidth: Style.space(40)
                        implicitHeight: Style.space(48)
                        radius: 6
                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

                        Body {
                          anchors.centerIn: parent
                          text: modelData
                          font.pixelSize: Style.font.display
                          font.bold: true
                          color: root.accent
                        }
                      }
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)

                  Caption { text: "Only needed if the button above isn't handy." }

                  Item { Layout.fillWidth: true }

                  ActionButton {
                    implicitWidth: Style.space(90)
                    label: "New PIN"
                    onActivated: root.regeneratePin()
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  height: 1
                  color: root.cardBorder
                }

                // Instructions
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  Body {
                    text: "How to connect:"
                    font.bold: true
                  }
                  Caption { text: "1. Finish Setup if this panel flagged it — daemon and firewall." }
                  Caption { text: "2. Turn on Wi-Fi on your watch, same network as this laptop." }
                  Caption { text: "3. Open Omarchy AI on the watch and tap Connect." }
                  Caption {
                    text: "4. Approve it here. A notification pops up, or use the prompt above."
                    color: root.accent
                  }
                  Caption { text: "Adding another watch later? Click 'Add another watch' first." }
                }
              }
            }
          }

          // Push the cards to the top instead of spreading them down the tab.
          Item { Layout.fillHeight: true }
        }

        // ======================== TAB 1: DYNAMIC LLMS & SLOTS ========================
        ColumnLayout {
          visible: root.activeTab === 1
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(8)

          // Watch 4 Circular Gauges Summary
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: Style.space(76)
            radius: root.radiusVal
            color: root.cardBg
            border.color: root.cardBorder

            RowLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              Repeater {
                model: root.slotDefs

                Rectangle {
                  id: slotTile
                  readonly property bool picking: root.editingSlot === modelData.key
                  readonly property color slotColor: modelData.color
                  readonly property string assignedId:
                    root.slotsData[modelData.key] || modelData.defaultId

                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  radius: 4
                  color: slotTile.picking
                         ? Qt.rgba(slotTile.slotColor.r, slotTile.slotColor.g,
                                   slotTile.slotColor.b, 0.25)
                         : (slotArea.containsMouse ? root.cardHover : Qt.rgba(0, 0, 0, 0.2))
                  border.color: slotTile.slotColor
                  border.width: slotTile.picking ? 2 : 1

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(4)
                    spacing: 2

                    Caption {
                      text: modelData.label
                      font.bold: true
                      color: slotTile.slotColor
                    }
                    Caption {
                      // Show the readable label when the model is known, rather
                      // than the tail of an identifier.
                      text: {
                        var m = root.slotModel(modelData.key)
                        return m ? (m.detailLabel || m.shortLabel || m.title)
                                 : (slotTile.assignedId.split(":")[1] || slotTile.assignedId)
                      }
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                      color: root.foreground
                    }
                    Caption {
                      text: slotTile.picking ? "picking..." : "click to change"
                      opacity: slotArea.containsMouse || slotTile.picking ? 0.9 : 0.0
                      Behavior on opacity { NumberAnimation { duration: 150 } }
                    }
                  }

                  MouseArea {
                    id: slotArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.editingSlot = slotTile.picking ? "" : modelData.key
                  }
                }
              }
            }
          }

          // While a gauge is being reassigned, the list below becomes the picker.
          Rectangle {
            visible: root.editingSlot !== ""
            Layout.fillWidth: true
            implicitHeight: pickRow.implicitHeight + Style.space(16)
            radius: root.radiusVal
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
            border.color: root.accent

            RowLayout {
              id: pickRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Body {
                  Layout.fillWidth: true
                  text: "Pick a limit for " + root.editingSlot.toUpperCase() + " - choose one below"
                  font.bold: true
                }
                // The watch pulls this on its next check-in rather than being
                // pushed to, so say so instead of letting it look broken.
                Caption {
                  Layout.fillWidth: true
                  wrapMode: Text.WordWrap
                  text: "Saved here at once. Your watch picks it up on its next sync, usually a minute or two."
                }
              }
              ActionButton {
                implicitWidth: Style.space(70)
                implicitHeight: Style.space(24)
                label: "Cancel"
                onActivated: root.editingSlot = ""
              }
            }
          }

          Caption {
            visible: root.editingSlot === ""
            Layout.fillWidth: true
            text: "Click a gauge to change what it tracks. The watch follows on its next sync."
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Body {
              text: root.editingSlot !== ""
                    ? "[ CHOOSE A LIMIT ]"
                    : "[ " + root.modelsData.length + " LIMITS · "
                      + root.limitGroups.length + " PROVIDERS ]"
              font.bold: true
              color: root.muted
            }

            Item { Layout.fillWidth: true }

            // Only worth offering once there is more than one panel to act on.
            Caption {
              visible: root.limitGroups.length > 1
              text: root.allProvidersCollapsed ? "Expand all" : "Collapse all"
              color: root.accent
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setAllProvidersCollapsed(!root.allProvidersCollapsed)
              }
            }
          }

          // One collapsible panel per provider. Grouping is what makes a machine
          // with six agents installed readable: the flat list was thirty rows
          // with no structure, and the provider was buried in every title.
          ScrollView {
            id: limitScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
              width: limitScroll.availableWidth
              spacing: Style.space(6)

              Repeater {
                model: root.limitGroups

                ColumnLayout {
                  id: providerPanel
                  required property var modelData

                  readonly property bool folded: root.providerCollapsed(modelData.id)
                  readonly property color tint: modelData.color

                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  // Panel header: always visible, and carries the fullest limit
                  // inside so folding a provider away never hides a quota that
                  // is about to run out.
                  Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: Style.space(30)
                    radius: 4
                    color: headerArea.containsMouse ? root.cardHover
                                                    : Qt.rgba(0, 0, 0, 0.25)
                    border.color: Qt.rgba(providerPanel.tint.r, providerPanel.tint.g,
                                          providerPanel.tint.b, 0.45)

                    MouseArea {
                      id: headerArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleProvider(providerPanel.modelData.id)
                    }

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(8)

                      Caption {
                        text: providerPanel.folded ? "▸" : "▾"
                        color: root.muted
                      }

                      Rectangle {
                        implicitWidth: 3
                        implicitHeight: Style.space(14)
                        radius: 1.5
                        color: providerPanel.tint
                      }

                      Body {
                        text: providerPanel.modelData.name
                        font.bold: true
                      }

                      Caption {
                        text: providerPanel.modelData.items.length
                              + (providerPanel.modelData.items.length === 1 ? " limit" : " limits")
                      }

                      Item { Layout.fillWidth: true }

                      // The fullest limit in the panel. Red once it is nearly
                      // gone, so a folded panel still raises its hand.
                      Caption {
                        text: "peak " + Math.round(providerPanel.modelData.peak * 100) + "%"
                        font.bold: providerPanel.modelData.peak >= 0.9
                        color: providerPanel.modelData.peak >= 0.9 ? root.alarmColor
                             : providerPanel.modelData.peak >= 0.7 ? root.warnColor
                             : root.muted
                      }
                    }
                  }

                  Repeater {
                    model: providerPanel.folded ? [] : providerPanel.modelData.items

                    LimitRow {
                      required property var modelData
                      Layout.fillWidth: true
                      Layout.leftMargin: Style.space(10)
                      limit: modelData
                      picking: root.editingSlot !== ""
                      isCurrent: root.editingSlot !== ""
                                 && root.slotsData[root.editingSlot] === modelData.id
                      onChosen: root.setSlot(root.editingSlot, modelData.id)
                    }
                  }
                }
              }
            }
          }
        }

        // ======================== TAB 2: LAPTOP SETUP ========================
        Flickable {
          visible: root.activeTab === 2
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          contentWidth: width
          contentHeight: setupCol.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ColumnLayout {
            id: setupCol
            width: parent.width
            spacing: Style.space(10)

            Body {
              text: root.setupReady ? "This laptop is ready" : "Set up this laptop"
              font.pixelSize: Style.font.subtitle
              font.bold: true
              color: root.setupReady ? root.okColor : root.foreground
            }

            Caption {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: root.setupReady
                    ? "The watch can reach this machine. Keep this tab for a re-check if discovery ever fails."
                    : "The watch finds this laptop on Wi-Fi. These three things have to be true on the laptop before Connect on the watch will see anything."
            }

            Caption {
              visible: root.setupStatus && root.setupStatus.lanIp
              text: "This laptop: "
                    + (root.setupStatus.lanIp || "")
                    + ":"
                    + (root.setupStatus.port || 8765)
              color: root.accent
            }

            Caption {
              visible: root.setupFixMessage !== ""
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: root.setupFixMessage
              color: root.warnColor
            }

            ActionButton {
              visible: root.setupHasFixable
              Layout.fillWidth: true
              primary: true
              active: !root.setupBusy
              label: root.setupFixing === "all"
                     ? "Waiting for password…"
                     : "Set up this laptop"
              onActivated: root.runSetupFix("all")
            }

            Caption {
              visible: root.setupHasFixable
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              text: "Unlocking the firewall asks for your password once. The daemon runs as you, not as root."
            }

            Repeater {
              model: root.setupSteps

              SetupStep {
                required property var modelData
                Layout.fillWidth: true
                step: modelData
                onFixRequested: root.runSetupFix(modelData.action)
              }
            }

            Rectangle {
              Layout.fillWidth: true
              height: 1
              color: root.cardBorder
            }

            Body {
              text: "On the watch"
              font.bold: true
            }

            Repeater {
              model: root.setupTips

              ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Style.space(2)

                Body {
                  Layout.fillWidth: true
                  wrapMode: Text.WordWrap
                  text: modelData.title
                  font.bold: true
                }
                Caption {
                  Layout.fillWidth: true
                  wrapMode: Text.WordWrap
                  text: modelData.body
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              ActionButton {
                implicitWidth: Style.space(110)
                active: !root.setupBusy
                label: "Recheck"
                onActivated: root.refreshSetup()
              }

              Item { Layout.fillWidth: true }

              Caption {
                text: root.setupBusy ? "Working…"
                      : (root.setupChecked
                         ? (root.setupReady ? "All required steps are done." : "Fix the red steps, then Recheck.")
                         : "Checking this laptop…")
                color: root.setupReady ? root.okColor : root.muted
              }
            }
          }
        }
      }
    }
  }
}
