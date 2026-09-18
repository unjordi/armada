#!/usr/bin/env bash
# Exercises the RGB-suspend-charging gate (armada#26): on suspend it paints
# the "charging" pattern only while plugged in and only when armada-rgb is
# present/supported, is a no-op on battery or for a non-suspend sleep type,
# and never fails/blocks even if the armada-rgb call itself errors.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/system_files/usr/lib/systemd/system-sleep/56-armada-rgb-suspend-charging"
[[ -x "$HOOK" ]] || { echo "FAIL: hook not executable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

sysfs="$tmp/sys"
mkdir -p "$sysfs/class/power_supply/battery"
set_status() { printf '%s\n' "$1" >"$sysfs/class/power_supply/battery/status"; }

rgb_tool="$tmp/armada-rgb"
rgb_calls="$tmp/calls.log"
rgb_supported_rc="$tmp/supported-rc"
rgb_set_rc="$tmp/set-rc"
: >"$rgb_calls"
echo 0 >"$rgb_supported_rc"
echo 0 >"$rgb_set_rc"

cat >"$rgb_tool" <<'EOF'
#!/bin/bash
echo "$@" >>"$RGB_CALLS"
if [[ "${1:-}" == supported ]]; then
    exit "$(cat "$RGB_SUPPORTED_RC")"
fi
exit "$(cat "$RGB_SET_RC")"
EOF
chmod +x "$rgb_tool"

run_hook() {
    env \
        "ARMADA_SYSFS_ROOT=$sysfs" \
        "ARMADA_RGB_TOOL=$rgb_tool" \
        "RGB_CALLS=$rgb_calls" \
        "RGB_SUPPORTED_RC=$rgb_supported_rc" \
        "RGB_SET_RC=$rgb_set_rc" \
        bash "$HOOK" "$@"
}

fail=0
check() { if [[ "$2" != "$3" ]]; then echo "FAIL: $1 (want '$3' got '$2')"; fail=1; else echo "ok: $1"; fi; }

# 1) charging + supported -> pre suspend paints the battery effect
set_status Charging
run_hook pre suspend
check "charging pre -> painted battery effect" "$(cat "$rgb_calls")" \
"supported
set --effect battery --color 00FF00 --brightness 40"

# 2) on battery -> no set call (still probes supported first)
: >"$rgb_calls"
set_status Discharging
run_hook pre suspend
check "discharging pre -> supported probed, no paint" "$(cat "$rgb_calls")" "supported"

# 3) resume -> probes supported (cheap, gates the whole hook) but paints
#    nothing (hands lighting back to armada-rgb's own state)
: >"$rgb_calls"
set_status Charging
run_hook post suspend
check "post -> supported probed, no paint" "$(cat "$rgb_calls")" "supported"

# 4) non-suspend sleep type ignored (hibernate)
: >"$rgb_calls"
run_hook pre hibernate
check "hibernate ignored" "$(cat "$rgb_calls")" ""

# 5) armada-rgb not supported (crash-looping daemon, old RPM pin) -> no-op,
#    exit 0 regardless (never blocks suspend on an RGB failure)
: >"$rgb_calls"
echo 1 >"$rgb_supported_rc"
set_status Charging
run_hook pre suspend && echo "ok: unsupported -> exit 0" || { echo "FAIL: unsupported should not fail"; fail=1; }
check "unsupported -> no paint attempt" "$(cat "$rgb_calls")" "supported"
echo 0 >"$rgb_supported_rc"

# 6) armada-rgb tool missing entirely -> no-op, no crash
: >"$rgb_calls"
run_hook_missing_tool() {
    env \
        "ARMADA_SYSFS_ROOT=$sysfs" \
        "ARMADA_RGB_TOOL=$tmp/does-not-exist" \
        bash "$HOOK" "$@"
}
run_hook_missing_tool pre suspend && echo "ok: missing tool -> exit 0" || { echo "FAIL: missing tool should not fail"; fail=1; }

# 7) armada-rgb set fails (e.g. version-skew crash) -> hook still exits 0
: >"$rgb_calls"
echo 2 >"$rgb_set_rc"
set_status Charging
run_hook pre suspend && echo "ok: failed set -> exit 0 (never blocks suspend)" || { echo "FAIL: a failed paint should not block suspend"; fail=1; }

if (( fail )); then echo "rgb-suspend-charging hook: FAILURES"; exit 1; fi
echo "PASS: rgb-suspend-charging-hook-test"
