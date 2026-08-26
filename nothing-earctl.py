#!/usr/bin/python3
"""Small, dependency-free RFCOMM client for Nothing Ear and Headphone devices.

The Nothing X protocol is a binary protocol on RFCOMM channel 15.  This helper
is intentionally short-lived: the Omarchy widget starts it only when it needs
a snapshot or a control change, so it does not keep the earbuds' control
channel busy while the bar is idle.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import struct
import subprocess
import time
from pathlib import Path
from typing import Iterable

SOF = 0x55
CTRL_WITH_CRC = 0x0160
RFCOMM_CHANNEL = 15

CMD_DEVICE_INFO = 0x06
CMD_BATTERY = 0x07
CMD_ANC_GET = 0x1E
CMD_ANC_SET = 0x0F
CMD_LATENCY_GET = 0x41
CMD_LATENCY_SET = 0x40
CMD_CODEC_GET = 0x29

DIR_GET = 0xC0
DIR_SET = 0xF0
DIR_RESPONSE = 0x40
DIR_ACK = 0x70

ANC_WIRE = {
    "high": 1,
    "mid": 2,
    "low": 3,
    "adaptive": 4,
    "off": 5,
    "transparency": 7,
}

CODEC_LABELS = {
    "sbc": "SBC",
    "sbc_xq": "SBC-XQ",
    "aac": "AAC",
    "ldac": "LDAC",
    "lhdc": "LHDC",
    "aptx": "aptX",
    "aptx_hd": "aptX HD",
    "aptx_ll": "aptX Low Latency",
}

DEVICE_CODEC_LABELS = {
    0: "Standard",
    1: "LHDC",
    2: "LDAC",
    3: "Alternative hi-res",
}

# How long a case reading stays usable after the case stops reporting. Long
# enough to still mean something once the case is shut, short enough that the
# panel never presents yesterday's charge as today's.
CASE_CACHE_MAX_AGE = 6 * 3600

ADDRESS_RE = re.compile(r"^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$")


def crc16(data: bytes) -> int:
    """CRC-16/MODBUS as used by the Nothing X RFCOMM protocol."""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def packet(command: int, direction: int, payload: bytes = b"", operation: int = 1) -> bytes:
    wire_command = (command & 0xFF) | ((direction & 0xFF) << 8)
    header = struct.pack(
        "<BHHH", SOF, CTRL_WITH_CRC, wire_command, len(payload)
    ) + bytes([operation & 0xFF])
    body = header + payload
    return body + struct.pack("<H", crc16(body))


def bluetoothctl(*args: str) -> str:
    try:
        result = subprocess.run(
            ["bluetoothctl", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout


def paired_devices() -> list[dict[str, str]]:
    devices: list[dict[str, str]] = []
    for line in bluetoothctl("devices").splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[0] == "Device" and ADDRESS_RE.match(parts[1]):
            devices.append({"address": parts[1], "name": parts[2].strip()})
    return devices


def is_connected(address: str) -> bool:
    return re.search(r"^\s*Connected:\s*yes\s*$", bluetoothctl("info", address), re.M) is not None


def looks_like_nothing(name: str) -> bool:
    value = name.lower()
    return "nothing" in value or "ear" in value or "cmf" in value


def choose_device(requested: str = "") -> dict[str, str] | None:
    devices = paired_devices()
    if requested:
        requested_lower = requested.lower()
        for device in devices:
            if device["address"].lower() == requested_lower or device["name"].lower() == requested_lower:
                return device
        # A configured address is still useful if bluetoothctl has temporarily
        # omitted it from `devices`.
        if ADDRESS_RE.match(requested):
            return {"address": requested.upper(), "name": "Nothing device"}
        return None

    connected = [d for d in devices if looks_like_nothing(d["name"]) and is_connected(d["address"])]
    if connected:
        return connected[0]
    known = [d for d in devices if looks_like_nothing(d["name"])]
    return known[0] if known else None


class Frame:
    __slots__ = ("command", "direction", "payload")

    def __init__(self, command: int, direction: int, payload: bytes):
        self.command = command
        self.direction = direction
        self.payload = payload


class FrameParser:
    def __init__(self) -> None:
        self.buffer = bytearray()

    def feed(self, data: bytes) -> None:
        self.buffer.extend(data)

    def frames(self) -> Iterable[Frame]:
        while True:
            # Discard noise before a frame start.
            try:
                start = self.buffer.index(SOF)
            except ValueError:
                self.buffer.clear()
                return
            if start:
                del self.buffer[:start]
            if len(self.buffer) < 8:
                return

            # 0x55, ctrl (2), command (2), payload length (2), operation id.
            _, ctrl, command, length = struct.unpack_from("<BHHH", self.buffer)
            crc_size = 2 if ctrl & 0x20 else 0
            total = 8 + length + crc_size
            if len(self.buffer) < total:
                return

            raw = bytes(self.buffer[:total])
            del self.buffer[:total]
            payload = raw[8 : 8 + length]
            # Responses encode the direction in the high byte; the low command
            # byte is shared by GET, SET, response and unsolicited events.
            yield Frame(command & 0xFF, (command >> 8) & 0xFF, payload)


def recv_until(sock: socket.socket, parser: FrameParser, command: int, timeout: float = 1.6) -> bytes | None:
    deadline = time.monotonic() + timeout
    wanted = command & 0xFF
    while time.monotonic() < deadline:
        for frame in parser.frames():
            if frame.command == wanted and frame.direction in (DIR_RESPONSE, DIR_ACK):
                return frame.payload
        remaining = max(0.05, deadline - time.monotonic())
        sock.settimeout(min(0.25, remaining))
        try:
            data = sock.recv(512)
        except socket.timeout:
            continue
        except OSError:
            return None
        if not data:
            return None
        parser.feed(data)
    return None


def request(sock: socket.socket, parser: FrameParser, command: int, direction: int = DIR_GET, payload: bytes = b"", operation: int = 1) -> bytes | None:
    try:
        sock.sendall(packet(command, direction, payload, operation))
    except OSError:
        return None
    return recv_until(sock, parser, command)


def open_control(address: str) -> socket.socket:
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
    sock.settimeout(2.0)
    try:
        sock.connect((address, RFCOMM_CHANNEL))
    except Exception:
        sock.close()
        raise
    return sock


def unknown_component() -> dict[str, object]:
    return {"level": -1, "charging": False, "available": False}


def parse_components(payload: bytes) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    if not payload:
        return result
    # The first byte is the number of (component, value) pairs. Some firmware
    # returns a malformed count, so bounded parsing is deliberately defensive.
    count = payload[0]
    for index in range(count):
        offset = 1 + index * 2
        if offset + 1 >= len(payload):
            break
        component = payload[offset]
        raw = payload[offset + 1]
        level = raw & 0x7F
        if level > 100:
            continue
        entry = {
            "level": level,
            "charging": bool(raw & 0x80),
            "available": True,
        }
        if component == 2:
            result["left"] = entry
        elif component == 3:
            result["right"] = entry
        elif component == 4:
            result["case"] = entry
        elif component == 6:
            # One battery for the whole device: Nothing Headphone (1).
            result["headset"] = entry
    return result


def parse_anc(payload: bytes) -> dict[str, object]:
    state: dict[str, object] = {"available": False, "mode": "unknown", "level": -1}
    for offset in range(0, len(payload) - 2, 3):
        kind, value = payload[offset], payload[offset + 1]
        if kind == 1:
            state["available"] = True
            state["mode"] = "transparency" if value == 7 else "off" if value in (0, 5) else "anc"
        elif kind == 2:
            state["level"] = value if 1 <= value <= 4 else -1
    return state


def parse_latency(payload: bytes) -> dict[str, object]:
    return {"available": bool(payload), "enabled": bool(payload and payload[0] == 1)}


def pactl(*args: str) -> str:
    """Run pactl quietly; a machine without Pulse/PipeWire simply has no codecs."""
    try:
        result = subprocess.run(
            ["pactl", *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=4,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout if result.returncode == 0 else ""


def codec_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def host_codec_profiles(address: str) -> list[dict[str, str]]:
    """Return only A2DP sink codecs actually advertised by this laptop."""
    card = "bluez_card." + address.replace(":", "_")
    text = pactl("list", "cards")
    if not text:
        return []

    blocks = re.split(r"(?=^Card #)", text, flags=re.MULTILINE)
    block = next((item for item in blocks if re.search(r"^\s*Name:\s*" + re.escape(card) + r"\s*$", item, re.MULTILINE)), "")
    if not block:
        return []

    found: list[dict[str, str]] = []
    in_profiles = False
    for line in block.splitlines():
        if line.strip() == "Profiles:":
            in_profiles = True
            continue
        if in_profiles and line.strip().startswith("Active Profile:"):
            break
        if not in_profiles or "a2dp-sink" not in line:
            continue
        profile_match = re.match(r"\s*([^:]+):", line)
        codec_match = re.search(r"codec\s+([^()\s]+)", line, re.IGNORECASE)
        if not profile_match or not codec_match:
            continue
        profile = profile_match.group(1).strip()
        key = codec_key(codec_match.group(1))
        if not key or any(option["key"] == key for option in found):
            continue
        found.append({
            "key": key,
            "label": CODEC_LABELS.get(key, codec_match.group(1).upper()),
            "profile": profile,
        })
    return found


def active_host_codec(address: str) -> str:
    text = pactl("list", "sinks")
    if not text:
        return "unknown"
    blocks = re.split(r"(?=^Sink #)", text, flags=re.MULTILINE)
    for block in blocks:
        if address not in block:
            continue
        match = re.search(r"api\.bluez5\.codec\s*=\s*[\"]([^\"]+)[\"]", block)
        if match:
            return codec_key(match.group(1))
    return "unknown"


def unknown_codec_state() -> dict[str, object]:
    return {
        "available": False,
        "active": "unknown",
        "options": [],
        "device_code": -1,
        "device_mode": "Unknown",
    }


def host_codec_state(address: str, device_code: int | None = None) -> dict[str, object]:
    options = host_codec_profiles(address)
    return {
        "available": bool(options),
        "active": active_host_codec(address),
        "options": options,
        "device_code": device_code if device_code is not None else -1,
        "device_mode": DEVICE_CODEC_LABELS.get(device_code, "Unknown") if device_code is not None else "Unknown",
    }


def set_host_codec(address: str, key: str) -> tuple[bool, str]:
    options = host_codec_profiles(address)
    selected = next((option for option in options if option["key"] == key), None)
    if selected is None:
        available = ", ".join(option["label"] for option in options) or "none"
        return False, f"{key} is not available for this laptop (available: {available})"
    card = "bluez_card." + address.replace(":", "_")
    try:
        result = subprocess.run(
            ["pactl", "set-card-profile", card, selected["profile"]],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=6,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"Could not select {selected['label']}: {exc}"
    if result.returncode != 0:
        return False, result.stderr.strip() or f"Could not select {selected['label']}"
    # PipeWire may need a moment to recreate the Bluetooth sink. The setting
    # command itself is successful once pactl accepts the profile.
    time.sleep(0.25)
    return True, "ok"


def state_dir() -> Path:
    # An empty XDG_STATE_HOME must fall back too, or the cache lands in whatever
    # directory the shell happens to be running from.
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "nothing-ear"


def cache_case(case: dict[str, object], address: str) -> None:
    directory = state_dir()
    try:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "case.json").write_text(
            json.dumps({"address": address, "case": case, "saved": int(time.time())}) + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass


def cached_case(address: str) -> dict[str, object] | None:
    try:
        data = json.loads((state_dir() / "case.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    if str(data.get("address", "")).lower() != address.lower():
        return None
    saved = data.get("saved")
    if not isinstance(saved, int) or time.time() - saved > CASE_CACHE_MAX_AGE:
        return None
    case = data.get("case")
    if not isinstance(case, dict) or not isinstance(case.get("level"), int):
        return None
    # The reading is a memory, not a live value. The panel dims it, and a charge
    # that ended some time ago must not keep a charging animation running.
    return {**case, "charging": False, "stale": True}


def aggregate_battery(address: str) -> int:
    output = bluetoothctl("info", address)
    match = re.search(r"Battery Percentage:\s*0x[0-9a-f]+\s*\((\d+)\)", output, re.I)
    return int(match.group(1)) if match else -1


def read_case(battery: dict[str, object], address: str) -> None:
    """Cache a live case reading, or fall back to the last one it left behind."""
    case = battery.get("case")
    if isinstance(case, dict) and case.get("available"):
        cache_case(case, address)
        return
    remembered = cached_case(address)
    if remembered:
        battery["case"] = remembered


def snapshot(device: dict[str, str] | None) -> dict[str, object]:
    """Everything the panel needs, as one JSON-ready dict.

    Absent, disconnected, and silent earbuds are all ordinary states rather than
    errors: `connected` and `protocol` say which one it is, and `error` carries
    only the things that genuinely went wrong.
    """
    address = device["address"] if device else ""
    name = (device.get("name") if device else "") or ("Nothing device" if address else "")
    battery: dict[str, object] = {
        "left": unknown_component(),
        "right": unknown_component(),
        "case": unknown_component(),
        "headset": unknown_component(),
        "aggregate": aggregate_battery(address) if address else -1,
    }
    noise: dict[str, object] = {"available": False, "mode": "unknown", "level": -1}
    latency: dict[str, object] = {"available": False, "enabled": False}
    codec = unknown_codec_state()
    connected = bool(address) and is_connected(address)
    protocol = False
    errors: list[str] = []

    if address:
        device_codec: int | None = None
        sock: socket.socket | None = None
        if connected:
            try:
                sock = open_control(address)
            except OSError as exc:
                errors.append(f"Could not open Nothing control channel: {exc.strerror or exc}")

        if sock is not None:
            parser = FrameParser()
            try:
                # The device expects a harmless device-info GET first. Besides
                # being a useful channel probe, this is the activation step used
                # by Nothing X; later queries may be silently ignored on a fresh
                # RFCOMM session otherwise.
                request(sock, parser, CMD_DEVICE_INFO)

                battery_payload = request(sock, parser, CMD_BATTERY)
                if battery_payload is None:
                    errors.append("Battery query timed out")
                else:
                    protocol = True
                    battery.update(parse_components(battery_payload))

                anc_payload = request(sock, parser, CMD_ANC_GET)
                if anc_payload is None:
                    errors.append("Noise-control query timed out")
                else:
                    noise = parse_anc(anc_payload)

                latency_payload = request(sock, parser, CMD_LATENCY_GET)
                if latency_payload is not None:
                    latency = parse_latency(latency_payload)

                codec_payload = request(sock, parser, CMD_CODEC_GET)
                if codec_payload:
                    device_codec = codec_payload[0]
            finally:
                try:
                    sock.close()
                except OSError:
                    pass
            read_case(battery, address)

        codec = host_codec_state(address, device_codec)

    return {
        "schema_version": 1,
        "connected": connected,
        "device": {"address": address, "name": name},
        "battery": battery,
        "noise": noise,
        "latency": latency,
        "codec": codec,
        "protocol": protocol,
        "error": "; ".join(errors),
        "timestamp": int(time.time()),
    }


def control(device: dict[str, str], action: str, value: str) -> tuple[bool, str]:
    address = device["address"]
    if not is_connected(address):
        return False, "The device is not connected"
    if action == "codec":
        # Codec selection is a host-side PipeWire operation. It is deliberately
        # separate from the vendor codec flag: the host is the authority on
        # which codecs this particular laptop can actually negotiate.
        return set_host_codec(address, value)

    # Build the frame before touching the radio, so a bad request never costs an
    # RFCOMM session. argparse has already restricted both action and value.
    if action == "anc":
        command, payload = CMD_ANC_SET, bytes([1, ANC_WIRE[value], 0])
    else:
        command, payload = CMD_LATENCY_SET, bytes([1 if value == "on" else 2])

    try:
        sock = open_control(address)
    except OSError as exc:
        return False, f"Could not open Nothing control channel: {exc.strerror or exc}"
    try:
        if request(sock, FrameParser(), command, DIR_SET, payload) is None:
            return False, "The device did not acknowledge the change"
        # BlueZ can keep the RFCOMM channel marked busy for a short moment
        # after the final ACK. Let the controller finish before closing the
        # short-lived session; this also makes rapid bar clicks reliable.
        time.sleep(0.35)
        return True, "ok"
    finally:
        try:
            sock.close()
        except OSError:
            pass


def emit(data: object) -> None:
    print(json.dumps(data, separators=(",", ":"), sort_keys=True), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Read and control Nothing earbuds and headphones over Bluetooth")
    parser.add_argument("--device", default="", help="Bluetooth address or name")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    anc = sub.add_parser("set-anc")
    anc.add_argument("mode", choices=sorted(ANC_WIRE))
    latency = sub.add_parser("set-latency")
    latency.add_argument("state", choices=["on", "off"])
    codec = sub.add_parser("set-codec")
    codec.add_argument("codec", help="one of the codecs advertised by PipeWire")
    args = parser.parse_args()

    device = choose_device(args.device)
    if args.command == "status":
        emit(snapshot(device))
        return 0

    if not device:
        emit({"ok": False, "error": "No paired Nothing device found"})
        return 1

    if args.command == "set-anc":
        action, value = "anc", args.mode
    elif args.command == "set-latency":
        action, value = "latency", args.state
    else:
        action, value = "codec", args.codec
    ok, message = control(device, action, value)
    emit({"ok": ok, "error": "" if ok else message})
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
