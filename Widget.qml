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
  readonly property string fontFamily: bar ? bar.fontFamily : "JetBrainsMono Nerd Font"
  readonly property int radiusVal: Style.cornerRadius > 0 ? Math.min(6, Style.cornerRadius) : 6

  property string serverPin: "----"
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

  Process {
    id: statusProcess
    command: ["python3", root.serverScriptPath, "--status"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var res = JSON.parse(value)
          if (res.pin) root.serverPin = res.pin
          if (res.watchStatus) root.watchStatus = res.watchStatus
          if (res.models) root.modelsData = res.models
          if (res.providers) root.providersData = res.providers
          if (res.slots) root.slotsData = res.slots
        } catch (e) {
          // ignore parsing error
        }
      }
    }
  }

  Process {
    id: regenProcess
    command: ["python3", root.serverScriptPath, "--new-pin"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var trimmed = value.trim()
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

      // Watch icon with dynamic connection dot
      Item {
        implicitWidth: Style.space(18)
        implicitHeight: Style.space(18)

        Text {
          anchors.centerIn: parent
          text: "󰟟" // Material Nerd Font Watch
          font.family: root.fontFamily
          font.pixelSize: Style.fontSize(14)
          color: root.watchStatus && root.watchStatus.connected ? "#9ECE6A" : root.muted
        }

        // Connection status indicator dot
        Rectangle {
          width: Style.space(6)
          height: Style.space(6)
          radius: width / 2
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          color: root.watchStatus && root.watchStatus.connected ? "#9ECE6A" : "#F59E0B"
        }
      }

      // Short status label in dock
      Text {
        font.family: root.fontFamily
        font.pixelSize: Style.fontSize(12)
        font.bold: true
        color: root.foreground
        text: {
          if (root.watchStatus && root.watchStatus.connected) {
            return "⌚ " + (root.watchStatus.battery ? root.watchStatus.battery + "%" : "OK")
          }
          return "AI Watch"
        }
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

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(12)

        // Header with Title and Tabs
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            text: "⌚ Omarchy AI Watch"
            font.family: root.fontFamily
            font.pixelSize: Style.fontSize(15)
            font.bold: true
            color: root.foreground
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
              text: "Pairing"
              font.family: root.fontFamily
              font.pixelSize: Style.fontSize(11)
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
              text: "LLM Slots"
              font.family: root.fontFamily
              font.pixelSize: Style.fontSize(11)
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

          // Watch Connection Status Card
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: Style.space(80)
            radius: root.radiusVal
            color: root.cardBg
            border.color: root.cardBorder

            RowLayout {
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(14)

              Text {
                text: "󰟟"
                font.family: root.fontFamily
                font.pixelSize: Style.fontSize(32)
                color: root.watchStatus && root.watchStatus.connected ? "#9ECE6A" : "#F59E0B"
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(4)

                RowLayout {
                  spacing: Style.space(8)
                  Text {
                    text: root.watchStatus && root.watchStatus.device ? root.watchStatus.device : "Galaxy Watch"
                    font.family: root.fontFamily
                    font.pixelSize: Style.fontSize(13)
                    font.bold: true
                    color: root.foreground
                  }
                  Rectangle {
                    implicitWidth: Style.space(56)
                    implicitHeight: Style.space(18)
                    radius: 4
                    color: root.watchStatus && root.watchStatus.connected ? Qt.rgba(0.62, 0.81, 0.42, 0.2) : Qt.rgba(0.96, 0.62, 0.04, 0.2)
                    Text {
                      anchors.centerIn: parent
                      text: root.watchStatus && root.watchStatus.connected ? "ONLINE" : "WAITING"
                      font.family: root.fontFamily
                      font.pixelSize: Style.fontSize(9)
                      font.bold: true
                      color: root.watchStatus && root.watchStatus.connected ? "#9ECE6A" : "#F59E0B"
                    }
                  }
                }

                Text {
                  text: root.watchStatus && root.watchStatus.connected
                    ? "Battery: " + root.watchStatus.battery + "% • Synced: just now"
                    : "Open Omarchy AI on your Galaxy Watch to connect"
                  font.family: root.fontFamily
                  font.pixelSize: Style.fontSize(11)
                  color: root.muted
                }
              }
            }
          }

          // One-Time Pairing PIN Card
          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: root.radiusVal
            color: root.cardBg
            border.color: root.cardBorder

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(16)
              spacing: Style.space(10)

              Text {
                text: "ONE-TIME PAIRING PIN"
                font.family: root.fontFamily
                font.pixelSize: Style.fontSize(11)
                font.bold: true
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
                    model: root.serverPin ? root.serverPin.split("") : ["1", "2", "3", "4"]
                    Rectangle {
                      implicitWidth: Style.space(40)
                      implicitHeight: Style.space(48)
                      radius: 6
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

                      Text {
                        anchors.centerIn: parent
                        text: modelData
                        font.family: root.fontFamily
                        font.pixelSize: Style.fontSize(24)
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
                  text: "mDNS: _omarchy-ai._tcp • Port: 8765"
                  font.family: root.fontFamily
                  font.pixelSize: Style.fontSize(10)
                  color: root.muted
                }

                Item { Layout.fillWidth: true }

                Button {
                  text: "New PIN"
                  onClicked: root.regeneratePin()
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
                  font.pixelSize: Style.fontSize(11)
                  font.bold: true
                  color: root.foreground
                }
                Text {
                  text: "1. Watch & laptop must be on the same Wi-Fi."
                  font.family: root.fontFamily
                  font.pixelSize: Style.fontSize(10)
                  color: root.muted
                }
                Text {
                  text: "2. Open Omarchy AI app on Galaxy Watch."
                  font.family: root.fontFamily
                  font.pixelSize: Style.fontSize(10)
                  color: root.muted
                }
                Text {
                  text: "3. Tap 'Discover Laptop' and enter the 4-digit PIN above."
                  font.family: root.fontFamily
                  font.pixelSize: Style.fontSize(10)
                  color: root.muted
                }
              }
            }
          }
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
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  radius: 4
                  color: Qt.rgba(0, 0, 0, 0.2)
                  border.color: modelData.color

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(4)
                    spacing: 2

                    Text {
                      text: modelData.label
                      font.family: root.fontFamily
                      font.pixelSize: Style.fontSize(9)
                      font.bold: true
                      color: modelData.color
                    }
                    Text {
                      text: modelData.val.split(":")[1] || modelData.val
                      font.family: root.fontFamily
                      font.pixelSize: Style.fontSize(10)
                      elide: Text.ElideRight
                      Layout.fillWidth: true
                      color: root.foreground
                    }
                  }
                }
              }
            }
          }

          Text {
            text: "DISCOVERED AI PROVIDERS & LIMITS (" + root.modelsData.length + ")"
            font.family: root.fontFamily
            font.pixelSize: Style.fontSize(11)
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
                width: ListView.view.width
                implicitHeight: Style.space(44)
                radius: 4
                color: root.cardBg
                border.color: root.cardBorder

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
                        font.pixelSize: Style.fontSize(11)
                        font.bold: true
                        color: root.foreground
                      }
                      Item { Layout.fillWidth: true }
                      Text {
                        text: modelData.valueFormatted ? modelData.valueFormatted : (modelData.percentInt + "%")
                        font.family: root.fontFamily
                        font.pixelSize: Style.fontSize(11)
                        font.bold: true
                        color: modelData.color || root.accent
                      }
                    }

                    // Progress bar
                    Rectangle {
                      Layout.fillWidth: true
                      height: Style.space(4)
                      radius: 2
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)

                      Rectangle {
                        width: parent.width * Math.min(1.0, Math.max(0.0, modelData.percent || 0.0))
                        height: parent.height
                        radius: 2
                        color: modelData.color || "#9ECE6A"
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
