#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -B - "$ROOT" <<'PYEOF'
import importlib.machinery
import importlib.util
from pathlib import Path
import sys

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "system_files/usr/lib/armada"))

control_path = root / "system_files/usr/libexec/armada/armada-control"
loader = importlib.machinery.SourceFileLoader("armada_control_service", str(control_path))
spec = importlib.util.spec_from_loader("armada_control_service", loader)
control = importlib.util.module_from_spec(spec)
loader.exec_module(control)

commands = []
supported = False


def check_output(command, **kwargs):
    commands.append(command)
    if command[-1] == "get":
        return '{"version":1,"enabled":false,"brightness":25,"color":"FFFFFF"}'
    return '{"version":1,"enabled":true,"brightness":40,"color":"A1B2C3"}'


def run(command, **kwargs):
    assert command == [control.RGB_TOOL, "supported"]
    return control.subprocess.CompletedProcess(command, 0 if supported else 1)


control.subprocess.check_output = check_output
control.subprocess.run = run
assert control.action_get_rgb({}) is None
assert commands == []

supported = True
state = control.action_get_rgb({})
assert state["color"] == "FFFFFF"
assert commands.pop() == [control.RGB_TOOL, "get"]

state = control.action_set_rgb({"enabled": True, "color": "a1b2c3", "brightness": 40})
assert state["color"] == "A1B2C3"
assert commands.pop() == [
    control.RGB_TOOL,
    "set",
    "--color",
    "a1b2c3",
    "--brightness",
    "40",
]

control.action_set_rgb({"enabled": False})
assert commands.pop() == [control.RGB_TOOL, "off"]

control.action_set_rgb(
    {
        "enabled": True,
        "color": "a1b2c3",
        "brightness": 40,
        "effect": "rainbow",
        "speed": 250,
    }
)
assert commands.pop() == [
    control.RGB_TOOL,
    "set",
    "--color",
    "a1b2c3",
    "--brightness",
    "40",
    "--effect",
    "rainbow",
    "--speed",
    "250",
]

for request in (
    {"enabled": True, "color": "12345", "brightness": 40},
    {"enabled": True, "color": "FFFFFF", "brightness": 101},
    {"enabled": True, "color": "FFFFFF", "brightness": 40, "effect": "sparkle"},
    {"enabled": True, "color": "FFFFFF", "brightness": 40, "speed": 0},
    {"enabled": True, "color": "FFFFFF", "brightness": 40, "speed": 1001},
):
    try:
        control.action_set_rgb(request)
    except ValueError:
        pass
    else:
        raise AssertionError("invalid RGB state was accepted")

sys.path.insert(0, str(root / "decky/armada-control/py_modules"))
from armada_control import rgb

rgb.call = lambda action, **payload: None
assert not rgb.rgb_supported()

calls = []
rgb.call = lambda action, **payload: calls.append((action, payload)) or {}
assert rgb.rgb_supported()
assert calls.pop() == ("get_rgb", {})
assert rgb.get_rgb() == {}
assert calls.pop() == ("get_rgb", {})
rgb.set_rgb(True, "112233", 50)
assert calls.pop() == (
    "set_rgb",
    {
        "enabled": True,
        "color": "112233",
        "brightness": 50,
        "effect": "static",
        "speed": 100,
    },
)
rgb.set_rgb(True, "112233", 50, "breathing", 200)
assert calls.pop() == (
    "set_rgb",
    {
        "enabled": True,
        "color": "112233",
        "brightness": 50,
        "effect": "breathing",
        "speed": 200,
    },
)

# armada#23/#27: matches the real armada-rgb CLI contract
# (.claude/projects/rp6-rgb-cli-contract-2026-09-18.md) -- backlight_sync
# and screen_sync are plain --effect values with no flags of their own.
assert {"backlight_sync", "screen_sync"} <= set(control.RGB_EFFECTS)
assert set(control.RGB_EFFECTS) == {
    "static", "breathing", "color_cycle", "rainbow", "load", "battery",
    "backlight_sync", "screen_sync",
}

for effect in ("backlight_sync", "screen_sync"):
    control.action_set_rgb(
        {"enabled": True, "color": "a1b2c3", "brightness": 40, "effect": effect}
    )
    assert commands.pop() == [
        control.RGB_TOOL,
        "set",
        "--color",
        "a1b2c3",
        "--brightness",
        "40",
        "--effect",
        effect,
    ]

# armada#26: a dedicated CLI command, not a UI-facing action -- only the
# suspend hook (rgb-suspend-charging-hook-test.sh) calls it, this UI never
# exposes a "charge indicator" button (per the contract).
assert "charge_indicator" not in control.ACTIONS
assert "set_charge_indicator" not in control.ACTIONS

# run_rgb error handling: a Python exception must never reach the UI as
# opaque text (2026-09-18 QA: armada-rgb.service crash-looping surfaced as
# a bare "Python Exception" toast). Every failure mode gets a clean,
# actionable RuntimeError message instead.


def missing_tool(command, **kwargs):
    raise FileNotFoundError(command[0])


control.subprocess.check_output = missing_tool
try:
    control.action_set_rgb({"enabled": True, "color": "a1b2c3", "brightness": 40})
except RuntimeError as exc:
    assert "not installed" in str(exc)
else:
    raise AssertionError("missing armada-rgb binary was not reported")


def timed_out(command, **kwargs):
    raise control.subprocess.TimeoutExpired(command, 5)


control.subprocess.check_output = timed_out
try:
    control.action_set_rgb({"enabled": True, "color": "a1b2c3", "brightness": 40})
except RuntimeError as exc:
    assert "timed out" in str(exc)
else:
    raise AssertionError("armada-rgb timeout was not reported")


def rejected(command, **kwargs):
    raise control.subprocess.CalledProcessError(
        2, command, stderr="error: unrecognized subcommand 'run'\n"
    )


control.subprocess.check_output = rejected
try:
    control.action_set_rgb({"enabled": True, "color": "a1b2c3", "brightness": 40})
except RuntimeError as exc:
    assert "unrecognized subcommand" in str(exc)
else:
    raise AssertionError("armada-rgb rejection was not reported")


def bad_json(command, **kwargs):
    return "not json"


control.subprocess.check_output = bad_json
try:
    control.action_set_rgb({"enabled": True, "color": "a1b2c3", "brightness": 40})
except RuntimeError as exc:
    assert "unexpected response" in str(exc)
else:
    raise AssertionError("malformed armada-rgb output was not reported")

control.subprocess.check_output = check_output

# armada#24: switching the LIVE power profile via armada-power, independent
# of [general] default_profile.
power_commands = []


def power_run(command, **kwargs):
    power_commands.append(command)


control.run = power_run
assert control.action_set_power_profile({"profile": "performance"}) == {
    "profile": "performance"
}
assert power_commands.pop() == [control.ARMADA_POWER_TOOL, "profile", "performance"]

try:
    control.action_set_power_profile({"profile": "turbo"})
except ValueError:
    pass
else:
    raise AssertionError("invalid power profile was accepted")


def power_missing(command, **kwargs):
    raise FileNotFoundError(command[0])


control.run = power_missing
try:
    control.action_set_power_profile({"profile": "eco"})
except RuntimeError as exc:
    assert "not installed" in str(exc)
else:
    raise AssertionError("missing armada-power binary was not reported")

assert "set_power_profile" in control.ACTIONS

# privileged.py: a socket-level failure (armada-control.service itself down)
# must not leak a raw errno/OSError string to the UI either.
sys.path.insert(0, str(root / "decky/armada-control/py_modules"))
import importlib

privileged = importlib.import_module("armada_control.privileged")


class FakeSocket:
    def __init__(self, *a, **k):
        pass

    def __enter__(self):
        raise FileNotFoundError("no such socket")

    def __exit__(self, *a):
        return False


privileged.socket.socket = FakeSocket
try:
    privileged.call("get_rgb")
except RuntimeError as exc:
    assert "Couldn't reach" in str(exc)
else:
    raise AssertionError("missing armada-control socket was not reported")
PYEOF

! rg -q 'ARMADA_RGB_' "$ROOT/system_files/usr/lib/armada/devices"
! rg -q 'ARMADA_RGB_' "$ROOT/system_files/usr/libexec/armada/device-env"
SERVICE="$ROOT/system_files/usr/lib/systemd/system/armada-rgb.service"
! grep -Fq 'ConditionPathExists=/etc/armada/rgb.json' "$SERVICE"
grep -Fq 'ExecStart=/usr/bin/armada-rgb run' "$SERVICE"
grep -Fq 'ExecCondition=/usr/bin/armada-rgb supported' "$SERVICE"
grep -Fq 'systemctl enable armada-rgb.service' "$ROOT/build_files/40-vendor-system-files.sh"

printf 'Armada Control RGB tests passed\n'
