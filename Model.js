// Parsing and formatting stay outside QML so the data contract is easy to test.

var LEVEL_UNKNOWN = -1
var ANC_OFF = "off"
var ANC_TRANSPARENCY = "transparency"
var ANC_MODE = "anc"

// Cycle order matches the panel: quietest level first.
var ANC_VALUES = ["off", "transparency", "adaptive", "low", "mid", "high"]
var ANC_LABELS = {
  off: "Off",
  transparency: "Transparency",
  adaptive: "Adaptive",
  high: "High",
  mid: "Medium",
  low: "Low"
}
var ANC_WIRE_LEVELS = { adaptive: 4, high: 1, mid: 2, low: 3 }

var SUPPORTED_SCHEMA = 1

function defaultComponent() {
  return {
    level: LEVEL_UNKNOWN,
    charging: false,
    available: false,
    stale: false
  }
}

function defaultStatus() {
  return {
    ok: false,
    connected: false,
    protocol: false,
    deviceName: "",
    deviceAddress: "",
    left: defaultComponent(),
    right: defaultComponent(),
    caseBattery: defaultComponent(),
    // One battery for the whole device (Nothing Headphone (1)); left, right
    // and case stay unavailable when it is set.
    headset: defaultComponent(),
    aggregate: LEVEL_UNKNOWN,
    noiseAvailable: false,
    noiseMode: "unknown",
    ancLevel: LEVEL_UNKNOWN,
    latencyAvailable: false,
    latencyEnabled: false,
    codecAvailable: false,
    activeCodec: "unknown",
    codecOptions: [],
    deviceCodecCode: LEVEL_UNKNOWN,
    deviceCodecMode: "Unknown",
    lastError: "",
    schemaTooNew: false
  }
}

function integer(value, fallback) {
  var n = parseInt(value, 10)
  return isFinite(n) ? n : fallback
}

function component(raw) {
  var value = defaultComponent()
  if (!raw || typeof raw !== "object") return value
  var level = integer(raw.level, LEVEL_UNKNOWN)
  if (raw.available !== true || level < 0 || level > 100) return value
  value.level = level
  value.charging = raw.charging === true
  value.available = true
  value.stale = raw.stale === true
  return value
}

function parseStatus(raw) {
  var status = defaultStatus()
  var text = String(raw || "").trim()
  if (text === "") {
    status.lastError = "The Nothing Audio helper returned no status"
    return status
  }

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    status.lastError = "Could not read the Nothing Audio status"
    return status
  }
  if (!parsed || typeof parsed !== "object") {
    status.lastError = "The Nothing Audio helper returned an invalid status"
    return status
  }

  var version = integer(parsed.schema_version, 0)
  if (version > SUPPORTED_SCHEMA) {
    status.schemaTooNew = true
    status.lastError = "Nothing Audio status schema " + version + " is newer than this plugin"
    return status
  }

  status.ok = true
  status.connected = parsed.connected === true
  status.protocol = parsed.protocol === true
  var device = parsed.device && typeof parsed.device === "object" ? parsed.device : ({})
  status.deviceName = String(device.name || "")
  status.deviceAddress = String(device.address || "")

  var battery = parsed.battery && typeof parsed.battery === "object" ? parsed.battery : ({})
  status.left = component(battery.left)
  status.right = component(battery.right)
  status.caseBattery = component(battery.case)
  status.headset = component(battery.headset)
  status.aggregate = integer(battery.aggregate, LEVEL_UNKNOWN)

  var noise = parsed.noise && typeof parsed.noise === "object" ? parsed.noise : ({})
  status.noiseAvailable = noise.available === true
  status.noiseMode = String(noise.mode || "unknown")
  status.ancLevel = integer(noise.level, LEVEL_UNKNOWN)

  var latency = parsed.latency && typeof parsed.latency === "object" ? parsed.latency : ({})
  status.latencyAvailable = latency.available === true
  status.latencyEnabled = latency.enabled === true

  var codec = parsed.codec && typeof parsed.codec === "object" ? parsed.codec : ({})
  status.codecAvailable = codec.available === true
  status.activeCodec = String(codec.active || "unknown")
  status.codecOptions = Array.isArray(codec.options) ? codec.options : []
  status.deviceCodecCode = integer(codec.device_code, LEVEL_UNKNOWN)
  status.deviceCodecMode = String(codec.device_mode || "Unknown")

  status.lastError = String(parsed.error || "")
  return status
}

function levelText(level) {
  return level === LEVEL_UNKNOWN ? "--" : String(level) + "%"
}

function levelFraction(level) {
  if (level === LEVEL_UNKNOWN) return 0
  return Math.max(0, Math.min(100, level)) / 100
}

function ancLabel(value) {
  return ANC_LABELS[value] || "Unknown"
}

function currentAncKey(noiseMode, ancLevel) {
  if (noiseMode === ANC_OFF) return ANC_OFF
  if (noiseMode === ANC_TRANSPARENCY) return ANC_TRANSPARENCY
  for (var key in ANC_WIRE_LEVELS) {
    if (ANC_WIRE_LEVELS[key] === ancLevel) return key
  }
  return ""
}

function errorText(value) {
  var text = String(value || "").replace(/\s+/g, " ").trim()
  return text.length > 180 ? text.substring(0, 177) + "…" : text
}

if (typeof module !== "undefined") {
  module.exports = {
    LEVEL_UNKNOWN: LEVEL_UNKNOWN,
    ANC_VALUES: ANC_VALUES,
    ANC_LABELS: ANC_LABELS,
    ANC_WIRE_LEVELS: ANC_WIRE_LEVELS,
    defaultComponent: defaultComponent,
    defaultStatus: defaultStatus,
    parseStatus: parseStatus,
    levelText: levelText,
    levelFraction: levelFraction,
    ancLabel: ancLabel,
    currentAncKey: currentAncKey,
    errorText: errorText
  }
}
