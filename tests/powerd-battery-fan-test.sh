#!/usr/bin/env bash
# Covers the battery-temperature fan floor baked into armada-powerd: the
# [battery_fan] section in the factory power-profiles.conf is parsed, the floor
# is interpolated + quantized, gets a boost while charging, stays inert below the
# coolest knot / when disabled / when the sensor is unreadable, and fan_tick
# applies it ON TOP of the CPU/GPU curve (target = max(cpu_gpu, battery)).

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The floor must be applied on top of the CPU/GPU curve in the awake fan loop.
grep -Fq 'target = max(target, self.battery_target_pwm())' \
    "$ROOT/system_files/usr/libexec/armada/armada-powerd" || {
    printf 'FAIL: fan_tick no longer applies the battery floor on top of the CPU/GPU curve\n' >&2
    exit 1
}

# armada#29: the Reload D-Bus method (what Armada Control's battery-fan
# toggle triggers via action_write_config's "armada-power reload") must
# re-read [battery_fan], not just __init__ -- otherwise flipping the toggle
# in the UI silently does nothing until the daemon is restarted.
awk '/if method == "Reload":/,/if method == "Suspend":/' \
    "$ROOT/system_files/usr/libexec/armada/armada-powerd" \
    | grep -Fq 'self.load_battery_fan_config()' || {
    printf 'FAIL: Reload no longer re-reads [battery_fan] -- the UI toggle would need a daemon restart to take effect\n' >&2
    exit 1
}

# The factory config must ship the [battery_fan] section enabled.
grep -Fq '[battery_fan]' "$ROOT/system_files/usr/share/armada/power-profiles.conf" || {
    printf 'FAIL: factory power-profiles.conf lost the [battery_fan] section\n' >&2
    exit 1
}

python3 - "$ROOT" "$WORK" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import sys

ROOT, WORK = sys.argv[1], sys.argv[2]
LIB = os.path.join(ROOT, "system_files/usr/lib/armada")
LIBEXEC = os.path.join(ROOT, "system_files/usr/libexec/armada")
SHARE = os.path.join(ROOT, "system_files/usr/share/armada")
sys.path.insert(0, LIB)

failures = []


def check(name, condition):
    if not condition:
        failures.append(name)
        print(f"FAIL: {name}", file=sys.stderr)


def load_script(name):
    spec = importlib.util.spec_from_loader(
        name.replace("-", "_"),
        importlib.machinery.SourceFileLoader(
            name.replace("-", "_"), os.path.join(LIBEXEC, name)),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


powerd = load_script("armada-powerd")

temp_path = os.path.join(WORK, "batt-temp")
status_path = os.path.join(WORK, "batt-status")
etc_conf = os.path.join(WORK, "etc-power.conf")

powerd.FACTORY_CONFIG_FILE = powerd.Path(os.path.join(SHARE, "power-profiles.conf"))
powerd.CONFIG_FILE = powerd.Path(os.path.join(WORK, "no-such-etc.conf"))
powerd.BATTERY_TEMP_PATH = powerd.Path(temp_path)
powerd.BATTERY_STATUS_PATH = powerd.Path(status_path)


def make_power():
    p = powerd.ArmadaPower.__new__(powerd.ArmadaPower)
    # quantize_pwm() only needs these three keys.
    p.fan_config = {"min_pwm": 51, "max_pwm": 255, "pwm_quantum": 8}
    return p


def set_battery(temp_c=None, status="Discharging"):
    if temp_c is None:
        with open(temp_path, "w") as f:
            f.write("unknown")
    else:
        with open(temp_path, "w") as f:
            f.write(str(int(temp_c * 10)))  # deci-Celsius
    with open(status_path, "w") as f:
        f.write(status)


# --- factory [battery_fan] parses ------------------------------------------
power = make_power()
power.load_battery_fan_config()
check("factory battery_fan enabled", power.battery_enabled is True)
check("factory charging boost loaded", power.battery_charging_boost == 36)
check("factory curve has 7 knots", len(power.battery_curve) == 7)
check("curve sorted ascending by temp",
      power.battery_curve == sorted(power.battery_curve))

# --- floor is inert below the coolest knot (35 C -> 0) ----------------------
set_battery(30, "Discharging")
check("cool battery -> no floor (discharging)", power.battery_target_pwm() == 0)
set_battery(30, "Charging")
check("cool battery -> no floor even charging", power.battery_target_pwm() == 0)
set_battery(35, "Charging")
check("35 C knot is 0 -> no floor", power.battery_target_pwm() == 0)

# --- warm battery: interpolated + quantized, discharging vs charging --------
set_battery(40, "Discharging")
check("40 C discharging floor = 144", power.battery_target_pwm() == 144)
set_battery(40, "Charging")
check("40 C charging floor = 176 (144 + boost, quantized)",
      power.battery_target_pwm() == 176)
set_battery(50, "Charging")
check("hot battery clamps to max 255", power.battery_target_pwm() == 255)
set_battery(50, "Discharging")
check("hot battery clamps to max 255 discharging", power.battery_target_pwm() == 255)

# --- unreadable sensor -> inert (never blindly spin) ------------------------
set_battery(None, "Charging")
check("unreadable battery temp -> 0", power.battery_target_pwm() == 0)

# --- disabled via /etc override -> inert (stock behaviour) ------------------
with open(etc_conf, "w") as f:
    f.write("[battery_fan]\nenabled=0\n")
powerd.CONFIG_FILE = powerd.Path(etc_conf)
power2 = make_power()
power2.load_battery_fan_config()
check("enabled=0 override disables floor", power2.battery_enabled is False)
set_battery(45, "Charging")
check("disabled floor returns 0 while warm+charging",
      power2.battery_target_pwm() == 0)
powerd.CONFIG_FILE = powerd.Path(os.path.join(WORK, "no-such-etc.conf"))

# --- missing section entirely -> inert -------------------------------------
powerd.FACTORY_CONFIG_FILE = powerd.Path(os.path.join(WORK, "bare.conf"))
with open(os.path.join(WORK, "bare.conf"), "w") as f:
    f.write("[general]\ndefault_profile=balanced\n")
power3 = make_power()
power3.load_battery_fan_config()
check("no [battery_fan] section -> inert", power3.battery_enabled is False)
set_battery(45, "Charging")
check("missing section returns 0", power3.battery_target_pwm() == 0)

if failures:
    print(f"\n{len(failures)} battery-fan check(s) failed", file=sys.stderr)
    sys.exit(1)
print("powerd battery-fan: all checks passed")
PYEOF

echo "PASS: powerd-battery-fan-test"
