import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.r-witz.nothing-ear"
  ipcTarget: "nothing-ear"
  manageIpc: false

  // The keyboard cursor walks groups of chips: j/k moves between groups, h/l
  // moves inside the current one. Battery is informational and never takes the
  // cursor.
  property int cursorGroup: 0
  property int cursorOption: 0
  property bool cursorActive: false
  property int phraseIndex: 0

  readonly property bool hideWhenDisconnected: setting("hideWhenDisconnected", true) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  // A bar icon follows `barForeground`, which tracks a transparent bar; panel
  // content follows `foreground`. They are not interchangeable.
  readonly property color barIconColor: ear.connected
    ? barForeground
    : Qt.darker(barForeground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string heroPhrase: activePhrases[phraseIndex % activePhrases.length]

  readonly property var activePhrases: [
    "Nothing but good vibes",
    "Tuning the silence",
    "Keeping the low end low",
    "Untangling the Bluetooth",
    "A little ear candy",
    "Rinsing the low end",
    "Putting the case to work",
    "Wireless, not magic"
  ]

  // Derived from the model, so the cycle order, the wire keys, and the labels
  // have exactly one home.
  readonly property var ancOptions: Model.ANC_VALUES.map(function (key) {
    return { key: key, label: Model.ANC_LABELS[key] }
  })

  readonly property var codecList: ear.codecOptions

  readonly property bool showNoise: ear.hasControls
  readonly property bool showCodec: ear.connected && ear.codecAvailable
  readonly property bool showLatency: ear.hasControls && ear.latencyAvailable

  readonly property var cursorGroups: {
    var groups = []
    if (showNoise) groups.push("anc")
    if (showCodec) groups.push("codec")
    if (showLatency) groups.push("latency")
    return groups
  }

  readonly property string cursorRow: {
    if (cursorGroups.length === 0) return ""
    var kind = cursorGroups[Math.min(cursorGroup, cursorGroups.length - 1)]
    var keys = groupKeys(kind)
    if (keys.length === 0) return ""
    return rowName(kind, keys[Math.min(cursorOption, keys.length - 1)])
  }

  function groupKeys(kind) {
    if (kind === "latency") return ["latency"]
    var source = kind === "anc" ? ancOptions : codecList
    var keys = []
    for (var i = 0; i < source.length; i++) keys.push(source[i].key)
    return keys
  }

  function rowName(kind, key) {
    return kind === "latency" ? "latency" : kind + ":" + key
  }

  function rowHasCursor(name) {
    return cursorActive && cursorRow === name
  }

  // Landing on the option that is already active makes j/k feel like walking
  // rows: the cursor arrives where the eye already is.
  function activeOptionIndex(kind) {
    var current = kind === "anc" ? ear.activeAncKey : ear.activeCodec
    var index = groupKeys(kind).indexOf(current)
    return index < 0 ? 0 : index
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (cursorGroups.length === 0) return
    if (dy !== 0) {
      cursorGroup = Math.max(0, Math.min(cursorGroups.length - 1, cursorGroup + dy))
      cursorOption = activeOptionIndex(cursorGroups[cursorGroup])
      return
    }
    if (dx !== 0) {
      var keys = groupKeys(cursorGroups[cursorGroup])
      cursorOption = Math.max(0, Math.min(keys.length - 1, cursorOption + dx))
    }
  }

  function focusRow(name) {
    for (var group = 0; group < cursorGroups.length; group++) {
      var keys = groupKeys(cursorGroups[group])
      for (var i = 0; i < keys.length; i++) {
        if (rowName(cursorGroups[group], keys[i]) !== name) continue
        cursorActive = true
        cursorGroup = group
        cursorOption = i
        return
      }
    }
  }

  function activate(name) {
    if (name.indexOf("anc:") === 0) ear.setAnc(name.substring(4))
    else if (name.indexOf("codec:") === 0) ear.setCodec(name.substring(6))
    else if (name === "latency") ear.setLatency(!ear.latencyEnabled)
  }

  function cycleAnc() {
    if (!ear.hasControls) return
    var index = Model.ANC_VALUES.indexOf(ear.activeAncKey)
    ear.setAnc(Model.ANC_VALUES[index < 0 ? 0 : (index + 1) % Model.ANC_VALUES.length])
  }

  function cycleCodec() {
    if (!showCodec || codecList.length === 0) return
    var index = groupKeys("codec").indexOf(ear.activeCodec)
    ear.setCodec(codecList[index < 0 ? 0 : (index + 1) % codecList.length].key)
  }

  // An error keeps the widget on the bar even with the earbuds away: hiding it
  // would leave a helper that cannot run with nowhere to say so.
  visible: !hideWhenDisconnected || ear.connected || ear.lastError !== ""
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorGroup = 0
    cursorOption = cursorGroups.length === 0 ? 0 : activeOptionIndex(cursorGroups[0])
    if (panelFlick) panelFlick.contentY = 0
    ear.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: ear
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { ear.refresh(); return "ok" }
    function noise(): string { root.cycleAnc(); return "ok" }
    function codec(): string { root.cycleCodec(); return "ok" }
    function status(): string {
      if (!ear.connected) return "disconnected"
      if (!ear.protocol) return "connected"
      return ear.activeAncKey === "" ? "unknown" : Model.ancLabel(ear.activeAncKey)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      NothingEarIcon {
        anchors.centerIn: parent
        iconSize: Style.space(12)
        color: root.barIconColor
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.cycleAnc()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.cursorRow)
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        var key = String(text).toLowerCase()
        if (key === "r") { ear.refresh(); return }
        if (key === "c") { root.cycleCodec(); return }
        if (!ear.hasControls) return
        if (key === "o") ear.setAnc("off")
        else if (key === "t") ear.setAnc("transparency")
        else if (key === "a") ear.setAnc("adaptive")
        else if (key === "m") ear.setAnc("mid")
        else if (key === "g") ear.setLatency(!ear.latencyEnabled)
        // Plain h / l walk the chips, so a level takes the shifted letter.
        else if (text === "H") ear.setAnc("high")
        else if (text === "L") ear.setAnc("low")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.spacing.xxxl

          PanelHero {
            id: hero
            width: parent.width
            title: ear.deviceName !== "" ? ear.deviceName : "Nothing Audio"
            meta: ear.connected
              ? (ear.protocol ? root.heroPhrase : "Bluetooth connected")
              : (ear.deviceKnown ? "Not connected" : "Find a paired Nothing device")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: ear.connected ? 1.0 : 0.5
            iconComponent: Component {
              NothingEarIcon {
                iconSize: Style.font.display
                color: ear.connected ? root.foreground : root.dim
              }
            }
          }

          Text {
            visible: ear.lastError !== ""
            width: parent.width
            text: ear.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: ear.hasBattery
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "BATTERY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              visible: ear.protocol
              width: parent.width
              spacing: Style.spacing.md
              // Headphones are one unit with one battery; earbuds report
              // left, right, and case. A case row stays whenever a case
              // reports, whichever form the device takes.
              BatteryRow { visible: ear.headsetBattery.available; width: parent.width; label: "Headset"; bud: ear.headsetBattery }
              BatteryRow { visible: !ear.headsetBattery.available; width: parent.width; label: "Left"; bud: ear.leftBud }
              BatteryRow { visible: !ear.headsetBattery.available; width: parent.width; label: "Right"; bud: ear.rightBud }
              BatteryRow { visible: !ear.headsetBattery.available || ear.caseBattery.available; width: parent.width; label: "Case"; bud: ear.caseBattery }
            }

            BatteryRow {
              visible: !ear.protocol && ear.aggregateBattery !== Model.LEVEL_UNKNOWN
              width: parent.width
              label: "Overall"
              bud: ({ level: ear.aggregateBattery, charging: false, available: true, stale: false })
            }
          }

          Column {
            visible: root.showNoise
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "NOISE CONTROL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: 3
              columnSpacing: Style.spacing.md
              rowSpacing: Style.spacing.md

              Repeater {
                model: root.ancOptions
                OptionChip {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: 1
                  label: modelData.label
                  name: "anc:" + modelData.key
                  selected: ear.activeAncKey === modelData.key
                }
              }
            }
          }

          Column {
            visible: root.showCodec
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              text: "AUDIO CODEC"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: Math.max(1, Math.min(4, root.codecList.length))
              columnSpacing: Style.spacing.md
              rowSpacing: Style.spacing.md

              Repeater {
                model: root.codecList
                OptionChip {
                  required property var modelData
                  Layout.fillWidth: true
                  Layout.preferredWidth: 1
                  label: modelData.label
                  name: "codec:" + modelData.key
                  selected: ear.activeCodec === modelData.key
                }
              }
            }
          }

          ToggleRow {
            visible: root.showLatency
            width: parent.width
            label: "Low latency"
            checked: ear.latencyEnabled
          }

          Text {
            visible: ear.connected && !ear.protocol
            width: parent.width
            text: ear.aggregateBattery !== Model.LEVEL_UNKNOWN
              ? "Bluetooth reports one overall percentage. Open the panel again when the Nothing control channel is available for battery details and noise controls."
              : "The device is connected, but its Nothing control channel did not answer."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: !ear.connected
            width: parent.width
            text: ear.deviceKnown
              ? "Connect your Nothing device to see battery and listening controls."
              : "Pair a Nothing device, then open this panel again."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  Timer {
    interval: 5000
    running: root.opened && ear.connected
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: hero
      property: "metaOpacity"
      to: 0.0
      duration: 180
      easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: hero
      property: "metaOpacity"
      to: 1.0
      duration: 260
      easing.type: Easing.InQuad
    }
  }

  component BatteryRow: Item {
    id: batteryRow
    property string label: ""
    property var bud: Model.defaultComponent()

    readonly property bool low: bud.level !== Model.LEVEL_UNKNOWN
      && bud.level <= 20 && !bud.charging
    implicitHeight: batteryLayout.implicitHeight

    RowLayout {
      id: batteryLayout
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.spacing.lg

      Text {
        text: batteryRow.label
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.preferredWidth: Style.space(50)
      }

      Rectangle {
        id: meterTrack
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        implicitHeight: Style.space(6)
        radius: height / 2
        color: Qt.darker(root.foreground, 3.2)

        Rectangle {
          id: meterFill
          width: meterTrack.width * Model.levelFraction(batteryRow.bud.level)
          height: parent.height
          radius: parent.radius
          color: batteryRow.low ? root.urgent : root.foreground
          // A reading the case left behind is dimmed instead of captioned.
          opacity: batteryRow.bud.stale ? 0.5 : 1.0
        }

        // Charging breathes over the fill rather than spelling itself out in a
        // caption, which is what used to keep the meter short.
        Rectangle {
          anchors.fill: meterFill
          radius: meterFill.radius
          color: meterTrack.color
          visible: batteryRow.bud.charging
          opacity: 0

          SequentialAnimation on opacity {
            running: batteryRow.bud.charging
            loops: Animation.Infinite
            NumberAnimation { from: 0.0; to: 0.55; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.55; to: 0.0; duration: 900; easing.type: Easing.InOutQuad }
          }
        }
      }

      Text {
        text: Model.levelText(batteryRow.bud.level)
        color: root.foreground
        opacity: batteryRow.bud.stale ? 0.5 : 1.0
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Style.space(38)
      }
    }
  }

  component LoadingRing: Item {
    id: ring
    property bool active: false
    property real size: Style.space(16)

    implicitWidth: size
    implicitHeight: size
    visible: active

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      border.width: Style.spacing.hairline
      border.color: root.foreground
      opacity: 0.28
    }

    Rectangle {
      width: ring.size * 0.3
      height: width
      radius: width / 2
      anchors.horizontalCenter: parent.horizontalCenter
      y: 0
      color: root.foreground
    }

    RotationAnimation on rotation {
      from: 0
      to: 360
      duration: 700
      loops: Animation.Infinite
      running: ring.active
    }
  }

  // One option of a group. The selected fill is the state, so a chip needs no
  // tick; while a change is in flight the label fades under the spinner rather
  // than the chip resizing and nudging its neighbours.
  component OptionChip: CursorSurface {
    id: chip
    property string label: ""
    property string name: ""
    property bool selected: false

    readonly property bool pending: ear.pendingRow === name

    hasCursor: root.rowHasCursor(name)
    current: selected
    bordered: true
    foreground: root.foreground
    implicitWidth: chipLabel.implicitWidth + Style.spacing.controlPaddingX * 2
    implicitHeight: chipLabel.implicitHeight + Style.spacing.controlPaddingY * 2
    Layout.minimumWidth: Style.space(60)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow(chip.name)
      onClicked: root.activate(chip.name)
    }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      width: Math.min(implicitWidth, chip.width - Style.spacing.controlPaddingX * 2)
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: chip.label
      color: root.foreground
      opacity: chip.pending ? 0.0 : (chip.selected ? 1.0 : 0.7)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    LoadingRing {
      anchors.centerIn: parent
      active: chip.pending
    }
  }

  component ToggleRow: CursorSurface {
    id: toggleRow
    property string label: ""
    property bool checked: false

    readonly property string name: "latency"

    hasCursor: root.rowHasCursor(name)
    foreground: root.foreground
    implicitHeight: switchSlot.implicitHeight + Style.spacing.lg

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.focusRow(toggleRow.name)
      onClicked: root.activate(toggleRow.name)
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.xl
      anchors.verticalCenter: parent.verticalCenter
      text: toggleRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Item {
      id: switchSlot
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.xl
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: Style.space(42)
      implicitHeight: Style.space(22)

      ToggleSwitch {
        anchors.centerIn: parent
        visible: ear.pendingRow !== toggleRow.name
        interactive: false
        checked: toggleRow.checked
        hasCursor: toggleRow.hasCursor
        foreground: root.foreground
      }

      LoadingRing {
        anchors.centerIn: parent
        active: ear.pendingRow === toggleRow.name
      }
    }
  }
}
