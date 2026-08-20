import QtQuick
import Quickshell.Io
import Quickshell.Bluetooth
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool connected: false
  property bool protocol: false
  property bool deviceKnown: false
  property string deviceName: ""
  property string deviceAddress: ""
  property var leftBud: Model.defaultComponent()
  property var rightBud: Model.defaultComponent()
  property var caseBattery: Model.defaultComponent()
  property var headsetBattery: Model.defaultComponent()
  property int aggregateBattery: Model.LEVEL_UNKNOWN
  property bool noiseAvailable: false
  property string noiseMode: "unknown"
  property int ancLevel: Model.LEVEL_UNKNOWN
  property bool latencyAvailable: false
  property bool latencyEnabled: false
  property bool codecAvailable: false
  property string activeCodec: "unknown"
  property var codecOptions: []
  property int deviceCodecCode: Model.LEVEL_UNKNOWN
  property string deviceCodecMode: "Unknown"
  property string lastError: ""
  property var pendingAction: null

  // A control change that arrived while a status read held the earbuds' single
  // control channel. It runs the moment the read finishes.
  property var queuedAction: null

  // The control channel is not always ready the instant BlueZ reports the
  // connection. One delayed retry covers that without bringing back a polling
  // timer: it is armed by a connection and spent on the first attempt.
  property bool retryArmed: true

  // How long a spinner stays on screen once a change is confirmed, and how long
  // one may spin before the service gives up waiting for the earbuds.
  readonly property int minimumVisibleMs: 600
  readonly property int pendingTimeoutMs: 4000
  readonly property int retryDelayMs: 1500

  // Resolved from this file's own location so the plugin keeps working under any
  // directory name: a fork, a rename, or a checkout somewhere else.
  readonly property string defaultHelperPath:
    Qt.resolvedUrl("nothing-earctl.py").toString().replace(/^file:\/\//, "")
  readonly property string helperPath: String(setting("helperPath", defaultHelperPath) || defaultHelperPath)
  readonly property string configuredAddress: String(setting("deviceAddress", "") || "")
  readonly property var bluezDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var bluezTarget: findBluezTarget()
  readonly property bool bluezConnected: !!(bluezTarget && bluezTarget.connected)
  readonly property real bluezBattery: bluezTarget && bluezTarget.batteryAvailable
    ? bluezTarget.battery : -1
  // A control change is in flight or waiting its turn. A status read does not
  // block one, it only delays it, so reading is deliberately not part of this.
  readonly property bool applying: actionProcess.running || queuedAction !== null
  readonly property bool hasBattery: leftBud.available || rightBud.available
    || caseBattery.available || headsetBattery.available
    || aggregateBattery !== Model.LEVEL_UNKNOWN
  readonly property bool hasControls: connected && protocol
  readonly property string activeAncKey: Model.currentAncKey(noiseMode, ancLevel)
  // The row whose spinner is showing, "" when nothing is in flight.
  readonly property string pendingRow: !pendingAction
    ? ""
    : (pendingAction.kind === "latency" ? "latency" : pendingAction.kind + ":" + pendingAction.value)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function findBluezTarget() {
    var devices = bluezDevices || []
    var wanted = configuredAddress.toLowerCase()
    if (wanted !== "") {
      for (var i = 0; i < devices.length; i++) {
        if (String(devices[i].address || "").toLowerCase() === wanted) return devices[i]
      }
    }

    var knownAddress = deviceAddress.toLowerCase()
    if (knownAddress !== "") {
      for (var j = 0; j < devices.length; j++) {
        if (String(devices[j].address || "").toLowerCase() === knownAddress) return devices[j]
      }
    }

    for (var k = 0; k < devices.length; k++) {
      var name = String(devices[k].deviceName || devices[k].name || "").toLowerCase()
      if (name.indexOf("nothing") >= 0 || name.indexOf("ear") >= 0 || name.indexOf("cmf") >= 0)
        return devices[k]
    }
    return null
  }

  function commandFor(args) {
    // System Python: a version manager's python3 (mise, pyenv, uv) may be
    // built without Bluetooth socket support.
    var command = ["/usr/bin/python3", helperPath]
    if (configuredAddress !== "") command.push("--device", configuredAddress)
    for (var i = 0; i < args.length; i++) command.push(args[i])
    return command
  }

  // The helper owns the control channel for the length of one call, so only one
  // call runs at a time. A read asked for during an action is simply dropped:
  // the action's own settle refresh already covers it.
  function refresh() {
    if (statusProcess.running || actionProcess.running) return
    statusProcess.command = commandFor(["status"])
    statusProcess.running = true
  }

  function assign(target, values) {
    for (var key in values) target[key] = values[key]
  }

  // One control change at a time, tracked so the row that started it can show a
  // spinner until the earbuds confirm the new value. `next` is written to the
  // service immediately so the panel reacts on the click, `previous` restores
  // it if the device refuses.
  function beginPending(kind, value, next, previous) {
    pendingAction = {
      kind: kind,
      value: value,
      next: next,
      previous: previous,
      startedAt: Date.now(),
      confirmed: false
    }
    assign(root, next)
    pendingTimer.restart()
  }

  function clearPending() {
    pendingTimer.stop()
    pendingMinimumTimer.stop()
    pendingAction = null
  }

  function pendingSatisfied(status) {
    if (pendingAction.kind === "anc")
      return Model.currentAncKey(status.noiseMode, status.ancLevel) === pendingAction.value
    if (pendingAction.kind === "latency") return status.latencyEnabled === pendingAction.value
    return status.activeCodec === pendingAction.value
  }

  function overlayPending(status) {
    var pending = pendingAction
    if (!pending) return

    if (!pendingSatisfied(status)) {
      // The earbuds have not caught up yet: keep the requested value, and the
      // spinner with it, on screen.
      pending.confirmed = false
      assign(status, pending.next)
      return
    }

    // Confirmed. A spinner that flashes for a few milliseconds reads as a
    // glitch, so hold it until it has been visible for minimumVisibleMs.
    var age = Date.now() - pending.startedAt
    if (age >= minimumVisibleMs) {
      clearPending()
      return
    }
    pending.confirmed = true
    pendingMinimumTimer.interval = minimumVisibleMs - age
    pendingMinimumTimer.restart()
  }

  function revertPending() {
    if (!pendingAction) return
    assign(root, pendingAction.previous)
    clearPending()
  }

  function applyStatus(raw) {
    var status = Model.parseStatus(raw)
    if (!status.ok) {
      lastError = status.lastError
      return
    }

    overlayPending(status)

    // Bluetooth and PipeWire answer whether or not the earbuds' own control
    // channel does.
    connected = status.connected
    deviceKnown = status.deviceAddress !== ""
    deviceName = status.deviceName
    deviceAddress = status.deviceAddress
    aggregateBattery = status.aggregate
    codecAvailable = status.codecAvailable
    activeCodec = status.activeCodec
    codecOptions = status.codecOptions

    if (!status.connected) {
      forgetDevice()
      lastError = Model.errorText(status.lastError)
      return
    }

    // A refresh that lands right after a control change often finds the RFCOMM
    // channel still busy and reports "connected, no protocol" for one round.
    // Keeping the last reading costs nothing and spares the panel a full
    // collapse and rebuild, which moves every row under the pointer, for a
    // second at a time. Reporting it is left to the case where there is no
    // reading to keep, so a round that corrects itself does not push the panel
    // down with an error row either.
    if (!status.protocol) {
      if (!protocol) lastError = Model.errorText(status.lastError)
      if (retryArmed) {
        retryArmed = false
        retryTimer.restart()
      }
      return
    }

    retryArmed = false
    lastError = Model.errorText(status.lastError)
    protocol = true
    leftBud = status.left
    rightBud = status.right
    caseBattery = status.caseBattery
    headsetBattery = status.headset
    noiseAvailable = status.noiseAvailable
    noiseMode = status.noiseMode
    ancLevel = status.ancLevel
    latencyAvailable = status.latencyAvailable
    latencyEnabled = status.latencyEnabled
    deviceCodecCode = status.deviceCodecCode
    deviceCodecMode = status.deviceCodecMode
  }

  // The earbuds are gone: everything the control channel fed is now unknown,
  // and a change still waiting its turn has nothing left to change.
  function forgetDevice() {
    protocol = false
    leftBud = Model.defaultComponent()
    rightBud = Model.defaultComponent()
    caseBattery = Model.defaultComponent()
    headsetBattery = Model.defaultComponent()
    noiseAvailable = false
    noiseMode = "unknown"
    ancLevel = Model.LEVEL_UNKNOWN
    latencyAvailable = false
    latencyEnabled = false
    queuedAction = null
    clearPending()
  }

  // A helper that cannot run says nothing about the earbuds, so the reading on
  // screen stands and only the error is new.
  function failedStatus(message) {
    lastError = Model.errorText(message || "Could not query the Nothing device")
  }

  // A status read holds the control channel for well under a second, but that is
  // long enough to swallow the first click after the panel opens. Queue the
  // change instead of dropping it: the panel has already shown the new value.
  function runAction(args) {
    if (statusProcess.running) {
      queuedAction = args
      return
    }
    actionProcess.command = commandFor(args)
    actionProcess.running = true
  }

  function setAnc(mode) {
    if (!hasControls || applying) return
    var level = Model.ANC_WIRE_LEVELS[mode] === undefined ? ancLevel : Model.ANC_WIRE_LEVELS[mode]
    beginPending("anc", mode,
      { noiseMode: (mode === "off" || mode === "transparency") ? mode : "anc", ancLevel: level },
      { noiseMode: noiseMode, ancLevel: ancLevel })
    runAction(["set-anc", mode])
  }

  function setLatency(enabled) {
    if (!hasControls || !latencyAvailable || applying) return
    beginPending("latency", enabled,
      { latencyEnabled: enabled },
      { latencyEnabled: latencyEnabled })
    runAction(["set-latency", enabled ? "on" : "off"])
  }

  function setCodec(key) {
    if (!connected || !codecAvailable || applying) return
    beginPending("codec", key,
      { activeCodec: key },
      { activeCodec: activeCodec })
    runAction(["set-codec", key])
  }

  Component.onCompleted: refresh()

  onBluezConnectedChanged: {
    if (root.bluezConnected) root.retryArmed = true
    if (root.bluezConnected !== root.connected) root.refresh()
  }

  onBluezBatteryChanged: if (root.bluezConnected) root.refresh()
  onBluezTargetChanged: if (root.bluezConnected) root.refresh()

  Timer {
    id: settleTimer
    interval: 250
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: retryTimer
    interval: root.retryDelayMs
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(statusStdout.text || "")
      var stderr = String(statusStderr.text || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.failedStatus(stderr || stdout)
      if (root.queuedAction !== null) {
        var next = root.queuedAction
        root.queuedAction = null
        root.runAction(next)
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || "")
      var stderr = String(actionStderr.text || "")
      if (exitCode === 0) {
        root.lastError = ""
      } else {
        root.revertPending()
        root.lastError = Model.errorText(stderr || stdout || "The device rejected the change")
      }
      settleTimer.restart()
    }
  }

  Timer {
    id: pendingTimer
    interval: root.pendingTimeoutMs
    repeat: false
    onTriggered: {
      root.pendingAction = null
      root.refresh()
    }
  }

  Timer {
    id: pendingMinimumTimer
    interval: root.minimumVisibleMs
    repeat: false
    onTriggered: {
      if (root.pendingAction && root.pendingAction.confirmed) root.clearPending()
    }
  }
}
