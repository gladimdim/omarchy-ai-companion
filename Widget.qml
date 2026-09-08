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

  property bool pressable: true
  property bool interactive: true
  property bool popupOpen: false
  property int activeTab: 0 // 0: Watch & Pairing, 1: LLM Providers & Slots
  property bool refreshing: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: Color.popups.background
  readonly property color border: Color.popups.border
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  readonly property color cardBg: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color cardBorder: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  // The widget deliberately does not load omarchy.ttf, the pixel typeface the
  // watch face draws its clock with. It matched the wrist, but a bitmap face at
  // UI sizes is simply hard to read, so every label here uses the bar's own font.

  // A slow block cursor, the way a terminal idles.
  property bool caretOn: true
  Timer {
    interval: 600
    repeat: true
    running: root.popupOpen
    onTriggered: root.caretOn = !root.caretOn
  }

  readonly property color cardHover: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)

  // The shell's plain Button renders as unadorned text, so primary actions get a
  // real filled surface, a border and a hover state. Without those, "Add watch"
  // looked like a heading and simply never got clicked.
  // Clock for the live preview, ticking just often enough for hh:mm.
  property string previewClock: Qt.formatTime(new Date(), "hh:mm")
  Timer {
    interval: 10000
    repeat: true
    running: true
    onTriggered: {
      root.previewClock = Qt.formatTime(new Date(), "hh:mm")
      if (root.facePreview) root.facePreview.requestPaint()
    }
  }
  property var facePreview: null

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

    // Quadrant geometry, mirrored from the watch face: start angle measured from
    // twelve o'clock, each sweeping 80 degrees.
    readonly property var arcs: [
      { key: "top",    start: 320, color: "#D97757" },
      { key: "right",  start: 50,  color: "#38BDF8" },
      { key: "bottom", start: 140, color: "#A855F7" },
      { key: "left",   start: 230, color: "#9ECE6A" }
    ]

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      ctx.reset()

      var cx = w / 2, cy = h / 2
      var r = Math.min(w, h) / 2 - 6

      // The face itself
      ctx.beginPath()
      ctx.arc(cx, cy, r + 5, 0, Math.PI * 2)
      ctx.fillStyle = "#0B0B0F"
      ctx.fill()

      for (var i = 0; i < arcs.length; i++) {
        var a = arcs[i]
        var m = root.slotModel(a.key)
        var pct = m ? Math.max(0, Math.min(1, m.percent)) : 0
        var colour = (m && m.color) ? m.color : a.color

        // Canvas measures from three o'clock, the face measures from twelve.
        var from = (a.start - 90) * Math.PI / 180
        var full = 80 * Math.PI / 180

        ctx.lineCap = "round"
        ctx.lineWidth = 4

        ctx.beginPath()
        ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.10)
        ctx.arc(cx, cy, r, from, from + full)
        ctx.stroke()

        if (pct > 0.01) {
          ctx.beginPath()
          ctx.strokeStyle = colour
          ctx.arc(cx, cy, r, from, from + full * pct)
          ctx.stroke()
        }
      }
    }

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -Style.space(3)
      text: root.previewClock
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      color: "#FFFFFF"
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.verticalCenter
      anchors.topMargin: Style.space(6)
      visible: root.watchOnline && root.watchStatus && root.watchStatus.battery !== undefined
      text: root.watchStatus ? root.watchStatus.battery + "%" : ""
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.watchStatus && root.watchStatus.battery <= 30 ? "#FF4D4D" : "#9ECE6A"
    }

    Component.onCompleted: root.facePreview = face
  }

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

    Text {
      anchors.centerIn: parent
      text: actionBtn.label
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
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
  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property int radiusVal: Style.cornerRadius > 0 ? Math.min(6, Style.cornerRadius) : 6

  property string serverPin: "----"
  property bool pairingOpen: false
  property var pendingRequest: null

  // "unpaired" nothing linked yet | "linked" paired but quiet | "online" checked in recently
  readonly property string watchState: watchStatus && watchStatus.state ? watchStatus.state : "unpaired"
  readonly property bool watchOnline: watchState === "online"
  readonly property bool watchLinked: watchState !== "unpaired"

  function lastSeenText() {
    if (!watchStatus || watchStatus.secondsSinceSync === undefined) return ""
    var secs = watchStatus.secondsSinceSync
    if (secs < 0) return "no data yet"
    if (secs < 90) return "just now"
    if (secs < 3600) return Math.floor(secs / 60) + "m ago"
    if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
    return Math.floor(secs / 86400) + "d ago"
  }

  // Setup UI is only interesting until a watch is actually connected, so it
  // starts collapsed once one is. This is a binding, not a fixed value, so it
  // opens itself again if the watch goes away -- and a click still wins, because
  // assigning to it replaces the binding.
  property bool connectExpanded: !watchLinked
  property int pairingSecondsLeft: 0
  property var watchStatus: ({ "connected": false, "device": "Waiting for watch", "battery": 100 })
  property var modelsData: []
  property var providersData: []
  property var slotsData: ({ "top": "", "right": "", "bottom": "", "left": "" })
  property string localIp: "127.0.0.1"

  readonly property string serverScriptPath: pathFromUrl(Qt.resolvedUrl("server.py"))

  function pathFromUrl(url) {
    var val = String(url || "")
    if (val.indexOf("file://") === 0) return decodeURIComponent(val.substring(7))
    return val
  }

  function toggle() {
    popupOpen = !popupOpen
  }

  function close() {
    popupOpen = false
  }

  function triggerPress(button) {
    if (button === Qt.LeftButton) {
      toggle()
    } else if (button === Qt.MiddleButton) {
      refreshData()
    }
  }

  // Refresh data by executing python3 server.py --status
  function refreshData() {
    if (statusProcess.running) return
    statusProcess.running = true
  }

  function regeneratePin() {
    if (regenProcess.running) return
    regenProcess.running = true
  }

  // Opens a short window during which the next watch that asks can connect with
  // nothing to type. The deliberate action belongs here, on a machine with a
  // mouse, rather than on a four-digit keypad on a watch.
  function addWatch() {
    if (pairProcess.running) return
    pairProcess.running = true
  }

  Process {
    id: statusProcess
    command: ["python3", root.serverScriptPath, "--status"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(text)
          if (res.pin) root.serverPin = res.pin
          root.pendingRequest = res.pendingRequest || null
          root.pairingOpen = res.pairingOpen === true
          root.pairingSecondsLeft = res.pairingSecondsRemaining || 0
          if (res.watchStatus) root.watchStatus = res.watchStatus
          if (res.models) root.modelsData = res.models
          if (root.facePreview) root.facePreview.requestPaint()
          if (res.providers) root.providersData = res.providers
          if (res.slots) root.slotsData = res.slots
        } catch (e) {
          // ignore parsing error
        }
      }
    }
  }

  function approveWatch() {
    if (!root.pendingRequest) return
    approveProcess.command = ["python3", root.serverScriptPath, "--approve", root.pendingRequest.id]
    approveProcess.running = true
  }

  function denyWatch() {
    if (!root.pendingRequest) return
    approveProcess.command = ["python3", root.serverScriptPath, "--deny", root.pendingRequest.id]
    approveProcess.running = true
  }

  // Unlinking discards the pairing, so the button asks once before doing it.
  property bool confirmForget: false

  // Which gauge is being reassigned, "" when the picker is closed.
  property string editingSlot: ""

  function setSlot(slotKey, modelId) {
    if (setSlotProcess.running) return
    setSlotProcess.command = ["python3", root.serverScriptPath, "--set-slot", slotKey, modelId]
    setSlotProcess.running = true
  }

  Process {
    id: setSlotProcess
    command: ["python3", root.serverScriptPath, "--set-slot", "top", ""]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.editingSlot = ""
        root.refreshData()
        if (root.facePreview) root.facePreview.requestPaint()
      }
    }
  }

  function forgetWatch() {
    if (forgetProcess.running) return
    forgetProcess.running = true
  }

  Process {
    id: forgetProcess
    command: ["python3", root.serverScriptPath, "--forget"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.confirmForget = false
        root.watchStatus = ({ "connected": false, "device": "Waiting for watch", "battery": 100 })
        root.refreshData()
      }
    }
  }

  Process {
    id: approveProcess
    command: ["python3", root.serverScriptPath, "--approve", ""]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Clear it locally so the prompt goes away at once; the next poll confirms.
        root.pendingRequest = null
        root.refreshData()
      }
    }
  }

  Process {
    id: pairProcess
    command: ["python3", root.serverScriptPath, "--pair-mode"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var res = JSON.parse(text)
          root.pairingOpen = res.pairingOpen === true
          root.pairingSecondsLeft = res.secondsRemaining || 0
        } catch (e) {
          // leave state as-is; the next --status poll will correct it
        }
      }
    }
  }

  Timer {
    id: pairCountdown
    interval: 1000
    repeat: true
    running: root.pairingSecondsLeft > 0
    onTriggered: {
      root.pairingSecondsLeft -= 1
      if (root.pairingSecondsLeft <= 0) root.pairingOpen = false
    }
  }

  Process {
    id: regenProcess
    command: ["python3", root.serverScriptPath, "--new-pin"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var trimmed = text.trim()
        if (trimmed) root.serverPin = trimmed
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.popupOpen ? 3000 : 8000
    repeat: true
    running: true
    onTriggered: root.refreshData()
  }

  Component.onCompleted: {
    root.refreshData()
  }

  // ------------------------------------------------------------- Dock Bar UI
  implicitWidth: dockItem.implicitWidth
  implicitHeight: root.barSize

  Item {
    id: dockItem
    anchors.fill: parent
    implicitWidth: dockContent.implicitWidth + Style.space(14)
    implicitHeight: root.barSize

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
      // gone: green once a watch is online, amber while one is paired but out of
      // touch, muted when none is known.
      Item {
        id: dockIcon
        implicitWidth: robot.width
        implicitHeight: robot.height

        // Green when the watch is answering, red once it stops. A watch that is
        // paired but out of touch is the state worth noticing, so it gets the
        // alarming colour rather than a cautious amber. Nothing paired yet is
        // not a fault, so that one stays muted.
        readonly property color statusColor: root.watchOnline ? "#9ECE6A"
                                           : (root.watchLinked ? "#FF4D4D" : root.muted)
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
      Text {
        visible: text !== ""
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        color: root.foreground
        text: root.watchLinked ? "" : "AI Watch"
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

        // Header with Title and Tabs
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          RowLayout {
            spacing: Style.space(4)

            Text {
              text: "OMARCHY AI WATCH"
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.letterSpacing: 1
              color: root.foreground
            }
            // Idle terminal caret. It only blinks while the panel is open.
            Rectangle {
              implicitWidth: Style.space(7)
              implicitHeight: Style.font.heading
              color: root.accent
              opacity: root.caretOn ? 0.9 : 0.0
              Behavior on opacity { NumberAnimation { duration: 90 } }
            }
          }

          Item { Layout.fillWidth: true }

          // Tab 0 button: Watch & Pairing
          Rectangle {
            implicitWidth: Style.space(80)
            implicitHeight: Style.space(26)
            radius: root.radiusVal
            color: root.activeTab === 0 ? root.accent : root.cardBg
            border.color: root.cardBorder

            Text {
              anchors.centerIn: parent
              text: "PAIRING"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              color: root.activeTab === 0 ? Color.background : root.foreground
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = 0
            }
          }

          // Tab 1 button: LLMs & Slots
          Rectangle {
            implicitWidth: Style.space(90)
            implicitHeight: Style.space(26)
            radius: root.radiusVal
            color: root.activeTab === 1 ? root.accent : root.cardBg
            border.color: root.cardBorder

            Text {
              anchors.centerIn: parent
              text: "LLM SLOTS"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              color: root.activeTab === 1 ? Color.background : root.foreground
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = 1
            }
          }
        }

        // ======================== TAB 0: WATCH STATUS & PAIRING ========================
        ColumnLayout {
          visible: root.activeTab === 0
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(12)

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

              Text {
                text: "A watch wants to connect"
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                color: root.foreground
              }

              Text {
                text: root.pendingRequest ? root.pendingRequest.device : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: root.accent
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                ActionButton {
                  Layout.fillWidth: true
                  primary: true
                  label: "Approve"
                  onActivated: root.approveWatch()
                }
                ActionButton {
                  implicitWidth: Style.space(90)
                  label: "Deny"
                  onActivated: root.denyWatch()
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
                  border.color: root.watchOnline ? "#9ECE6A" : "#F59E0B"
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
                  Text {
                    text: root.watchStatus && root.watchStatus.device ? root.watchStatus.device : "Galaxy Watch"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    color: root.foreground
                  }
                  Rectangle {
                    implicitWidth: Style.space(62)
                    implicitHeight: Style.space(18)
                    radius: 4
                    color: root.watchOnline ? Qt.rgba(0.62, 0.81, 0.42, 0.2)
                                            : Qt.rgba(0.96, 0.62, 0.04, 0.2)
                    Text {
                      anchors.centerIn: parent
                      text: root.watchOnline ? "ONLINE" : (root.watchLinked ? "LINKED" : "WAITING")
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      color: root.watchOnline ? "#9ECE6A" : "#F59E0B"
                    }
                  }
                }

                Text {
                  text: root.watchOnline
                    ? "Battery: " + root.watchStatus.battery + "% \u2022 Synced " + root.lastSeenText()
                    : root.watchLinked
                      ? "Linked, but quiet. Last seen " + root.lastSeenText() + "."
                      : "Open Omarchy AI on your Galaxy Watch to connect"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
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

          // One-Time Pairing PIN Card
          Rectangle {
            Layout.fillWidth: true
            // Height follows the content so the card is a single row when
            // collapsed and as tall as it needs when open.
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

                  Text {
                    text: root.connectExpanded ? "\u25BE" : "\u25B8"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    color: root.muted
                  }
                  Text {
                    text: "[ CONNECT A WATCH ]"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                    color: root.muted
                  }
                  Item { Layout.fillWidth: true }
                  Text {
                    visible: !root.connectExpanded
                    text: "Show"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.accent
                  }
                }
              }

              // Everything below is setup, hidden unless asked for.
              ColumnLayout {
                id: connectBody
                Layout.fillWidth: true
                visible: root.connectExpanded
                spacing: Style.space(10)

              // Primary action. While this window is open the watch connects with
              // nothing typed on it at all.
              ActionButton {
                Layout.fillWidth: true
                primary: true
                active: !root.pairingOpen
                label: root.pairingOpen
                       ? "Ready \u2014 open the app on your watch (" + root.pairingSecondsLeft + "s)"
                       : "Add another watch"
                onActivated: root.addWatch()
              }

              Text {
                Layout.fillWidth: true
                visible: root.pairingOpen
                wrapMode: Text.WordWrap
                text: "Open Omarchy AI on your watch and tap Connect."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.accent
              }

              Text {
                text: "Or use a code:"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.muted
              }

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

                      Text {
                        anchors.centerIn: parent
                        text: modelData
                        font.family: root.fontFamily
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

                Text {
                  text: "Only needed if the button above isn't handy."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.muted
                }

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

                Text {
                  text: "How to connect:"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  color: root.foreground
                }
                Text {
                  text: "1. Turn on Wi-Fi on your watch, same network as this laptop."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.muted
                }
                Text {
                  text: "2. Open Omarchy AI on the watch and tap Connect."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.muted
                }
                Text {
                  text: "That's it. The first watch connects on its own."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.accent
                }
                Text {
                  text: "Adding another watch later? Click 'Add watch' first."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.muted
                }
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
                model: [
                  { "label": "⬆ TOP (12h)", "key": "top", "val": root.slotsData.top || "claude:session-5-hour", "color": "#D97757" },
                  { "label": "➡ RIGHT (3h)", "key": "right", "val": root.slotsData.right || "grok:weekly", "color": "#38BDF8" },
                  { "label": "⬇ BTM (6h)", "key": "bottom", "val": root.slotsData.bottom || "antigravity:thinking-models-quota", "color": "#A855F7" },
                  { "label": "⬅ LEFT (9h)", "key": "left", "val": root.slotsData.left || "global:today-tokens", "color": "#9ECE6A" }
                ]

                Rectangle {
                  id: slotTile
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  radius: 4
                  color: root.editingSlot === modelData.key
                         ? Qt.rgba(modelData.color.r || 0.5, 0.35, 0.25, 0.25)
                         : (slotArea.containsMouse ? root.cardHover : Qt.rgba(0, 0, 0, 0.2))
                  border.color: modelData.color
                  border.width: root.editingSlot === modelData.key ? 2 : 1

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(4)
                    spacing: 2

                    Text {
                      text: modelData.label
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      color: modelData.color
                    }
                    Text {
                      // Show the readable label when the model is known, rather
                      // than the tail of an identifier.
                      text: {
                        var m = root.slotModel(modelData.key)
                        return m ? (m.detailLabel || m.shortLabel || m.title)
                                 : (modelData.val.split(":")[1] || modelData.val)
                      }
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                      color: root.foreground
                    }
                    Text {
                      text: root.editingSlot === modelData.key ? "picking..." : "click to change"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      opacity: slotArea.containsMouse || root.editingSlot === modelData.key ? 0.9 : 0.0
                      color: root.muted
                      Behavior on opacity { NumberAnimation { duration: 150 } }
                    }
                  }

                  MouseArea {
                    id: slotArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.editingSlot =
                      (root.editingSlot === modelData.key) ? "" : modelData.key
                  }
                }
              }
            }
          }

          // While a gauge is being reassigned, the list below becomes the picker.
          Rectangle {
            visible: root.editingSlot !== ""
            Layout.fillWidth: true
            implicitHeight: pickCol.implicitHeight + Style.space(16)
            radius: root.radiusVal
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
            border.color: root.accent

            RowLayout {
              id: pickCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Text {
                  Layout.fillWidth: true
                  text: "Pick a limit for " + root.editingSlot.toUpperCase() + " - choose one below"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  color: root.foreground
                }
                // The watch pulls this on its next check-in rather than being
                // pushed to, so say so instead of letting it look broken.
                Text {
                  Layout.fillWidth: true
                  wrapMode: Text.WordWrap
                  text: "Saved here at once. Your watch picks it up on its next sync, usually a minute or two."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.muted
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

          Text {
            visible: root.editingSlot === ""
            Layout.fillWidth: true
            text: "Click a gauge to change what it tracks. The watch follows on its next sync."
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }

          Text {
            text: root.editingSlot !== ""
                  ? "[ CHOOSE A LIMIT " + root.modelsData.length + " ]"
                  : "[ DISCOVERED LIMITS " + root.modelsData.length + " ]"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            color: root.muted
          }

          // Scrollable list of all dynamic models on this laptop
          ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
              model: root.modelsData
              spacing: Style.space(6)

              delegate: Rectangle {
                id: providerRow
                width: ListView.view.width
                implicitHeight: Style.space(44)
                radius: 4

                // While a gauge is being reassigned every row becomes a choice,
                // and the one already assigned to that gauge is marked.
                readonly property bool picking: root.editingSlot !== ""
                readonly property bool isCurrent:
                  picking && root.slotsData[root.editingSlot] === modelData.id

                color: isCurrent ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                                 : (picking && rowArea.containsMouse ? root.cardHover : root.cardBg)
                border.color: isCurrent ? root.accent : root.cardBorder

                MouseArea {
                  id: rowArea
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: providerRow.picking
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setSlot(root.editingSlot, modelData.id)
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(10)

                  Rectangle {
                    width: 4
                    Layout.fillHeight: true
                    radius: 2
                    color: modelData.color || "#9ECE6A"
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                      spacing: Style.space(6)
                      Text {
                        text: modelData.providerName + ": " + modelData.title
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        color: root.foreground
                      }
                      Item { Layout.fillWidth: true }
                      Text {
                        text: modelData.valueFormatted ? modelData.valueFormatted : (modelData.percentInt + "%")
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        color: modelData.color || root.accent
                      }
                    }

                    // Progress bar. It animates to new values and glows once a
                    // quota is nearly gone, so a full one catches the eye instead
                    // of looking like every other row.
                    Rectangle {
                      id: track
                      Layout.fillWidth: true
                      height: Style.space(6)
                      radius: height / 2
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

                      readonly property real pct: Math.min(1.0, Math.max(0.0, modelData.percent || 0.0))
                      readonly property bool nearlyGone: pct >= 0.9

                      Rectangle {
                        id: fill
                        width: track.width * track.pct
                        height: parent.height
                        radius: height / 2
                        color: modelData.color || "#9ECE6A"

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

                      // A bright cap at the leading edge, like the round ends of
                      // the arcs on the watch face.
                      Rectangle {
                        visible: track.pct > 0.02 && track.pct < 0.995
                        width: track.height
                        height: track.height
                        radius: height / 2
                        x: Math.max(0, fill.width - width)
                        color: Qt.lighter(modelData.color || "#9ECE6A", 1.4)

                        Behavior on x {
                          NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
