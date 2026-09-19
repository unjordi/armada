#!/usr/bin/env bash
# Exercises the RGB-suspend-charging hook (armada#26), DESIGN A (kernel LED
# trigger): on suspend, when the user opted in, it hands the stick LEDs to a
# kernel trigger ("<psy>-charging-orange-full-green") and keeps the HTR3212
# controllers powered through sleep (keep_alive=1) so the kernel repaints them
# amber/green when the charger-attach doorbell fires mid-sleep -- with no CPU,
# no userspace, no armada-rgb call. On resume it disarms the trigger, clears
# keep_alive, and nudges armada-rgb to repaint the user's own lighting. It is a
# no-op for a non-suspend sleep type or when the opt-in is off, and never
# fails/blocks suspend even if nodes are missing or armada-rgb errors.
#
# This is the DESIGN-A contract. There is deliberately NO `armada-rgb
# charge-indicator` CLI (that dead design-B path was removed): the suspend
# painting is owned by the kernel trigger, not a userspace command. And it does
# NOT gate on "already charging at suspend time" -- that was the bug that
# stopped it painting when you plug in while already asleep.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/system_files/usr/lib/systemd/system-sleep/56-armada-rgb-suspend-charging"
[[ -x "$HOOK" ]] || { echo "FAIL: hook not executable"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fail=0
TRIGGER="battery-charging-orange-full-green"

# ---- fake sysfs: 8 multicolor group LED nodes (2 HTR3212 controllers) -------
leds=()
for n in l1 l2 l3 l4 r1 r2 r3 r4; do
    d="$tmp/leds/rgb:$n"; mkdir -p "$d"; printf 'none\n' >"$d/trigger"; leds+=("$d")
done
LEDS_GLOB="$tmp/leds/rgb:l? $tmp/leds/rgb:r?"

# ---- fake keep_alive knobs, one per bound htr3212 controller ----------------
for addr in 3-0030 2-0030; do
    mkdir -p "$tmp/htr3212/$addr"; printf '0\n' >"$tmp/htr3212/$addr/keep_alive"
done
KA_GLOB="$tmp/htr3212/*/keep_alive"

# ---- opt-in config ----------------------------------------------------------
indicator_config="$tmp/indicator.conf"
set_indicator()   { printf 'enabled=%s\n' "$1" >"$indicator_config"; }
clear_indicator() { rm -f "$indicator_config"; }

# ---- fake armada-rgb tool (logs its argv) -----------------------------------
rgb_calls="$tmp/calls.log"; : >"$rgb_calls"
rgb_tool="$tmp/armada-rgb"
cat >"$rgb_tool" <<'EOF'
#!/bin/bash
echo "$@" >>"$RGB_CALLS"
EOF
chmod +x "$rgb_tool"

# ---- helpers ----------------------------------------------------------------
run_hook() { # $1=pre|post  $2=suspend|hibernate  [$3=rgb_tool override]
    env \
        ARMADA_SYSFS_ROOT="$tmp/unused" \
        ARMADA_RGB_TOOL="${3:-$rgb_tool}" \
        ARMADA_RGB_CHARGE_INDICATOR_CONFIG="$indicator_config" \
        ARMADA_RGB_INDICATOR_LEDS="$LEDS_GLOB" \
        ARMADA_RGB_KEEPALIVE="$KA_GLOB" \
        RGB_CALLS="$rgb_calls" \
        bash "$HOOK" "$1" "$2"
}
triggers()   { for d in "${leds[@]}"; do cat "$d/trigger"; done | sort -u | paste -sd, -; }
keepalives() { cat "$tmp"/htr3212/*/keep_alive | sort -u | paste -sd, -; }
reset_nodes() {
    for d in "${leds[@]}"; do printf 'none\n' >"$d/trigger"; done
    for f in "$tmp"/htr3212/*/keep_alive; do printf '0\n' >"$f"; done
    : >"$rgb_calls"
}
check() { # $1=msg $2=got $3=exp
    if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 — got [$2] exp [$3]"; fail=1; fi
}

# 1) opt-in ON -> pre suspend arms the kernel trigger + keep_alive on ALL nodes.
reset_nodes; set_indicator 1
run_hook pre suspend
check "pre+on: every LED handed to the kernel trigger" "$(triggers)" "$TRIGGER"
check "pre+on: every controller kept alive through sleep" "$(keepalives)" "1"
check "pre+on: no armada-rgb call (kernel owns the paint)"  "$(cat "$rgb_calls")" ""

# 2) DESIGN-A KEY: it does NOT gate on charging state -> arms on opt-in alone,
#    so it still paints when you plug in while ALREADY asleep. (The hook never
#    reads battery status; there is no discharging branch to test around.)
reset_nodes; set_indicator 1
run_hook pre suspend
check "pre+on arms regardless of charge state (plug-in-while-asleep case)" "$(triggers)" "$TRIGGER"

# 3) opt-in OFF -> pre suspend is a no-op (nothing armed).
reset_nodes; set_indicator 0
run_hook pre suspend
check "pre+off: nothing armed (trigger left alone)" "$(triggers)" "none"
check "pre+off: keep_alive left alone"              "$(keepalives)" "0"

# 4) opt-in config MISSING -> default OFF -> no-op.
reset_nodes; clear_indicator
run_hook pre suspend
check "pre+missing-config: default off, nothing armed" "$(triggers)" "none"
set_indicator 1

# 5) resume -> disarms UNCONDITIONALLY (trigger none + keep_alive 0) and repaints
#    via `armada-rgb apply`, regardless of the opt-in setting.
reset_nodes; for d in "${leds[@]}"; do printf '%s\n' "$TRIGGER" >"$d/trigger"; done
for f in "$tmp"/htr3212/*/keep_alive; do printf '1\n' >"$f"; done; : >"$rgb_calls"
run_hook post suspend
check "post: trigger disarmed on every LED"      "$(triggers)" "none"
check "post: keep_alive cleared on every ctrl"   "$(keepalives)" "0"
check "post: repaints user lighting via apply"   "$(cat "$rgb_calls")" "apply"

# 6) post is unconditional even with opt-in OFF (restore lighting either way).
reset_nodes; set_indicator 0
for d in "${leds[@]}"; do printf '%s\n' "$TRIGGER" >"$d/trigger"; done
run_hook post suspend
check "post+off: still disarmed unconditionally" "$(triggers)" "none"
check "post+off: still repaints via apply"       "$(cat "$rgb_calls")" "apply"
set_indicator 1

# 7) non-suspend sleep type (hibernate) is ignored entirely.
reset_nodes
run_hook pre hibernate
check "hibernate pre ignored (nothing armed)" "$(triggers)" "none"
run_hook post hibernate
check "hibernate post ignored (no apply)" "$(cat "$rgb_calls")" ""

# 8) armada-rgb tool missing on resume -> still disarms, exits 0, no crash.
reset_nodes; for d in "${leds[@]}"; do printf '%s\n' "$TRIGGER" >"$d/trigger"; done
if run_hook post suspend "$tmp/does-not-exist"; then echo "ok: missing tool -> exit 0"; else echo "FAIL: missing tool should not fail"; fail=1; fi
check "post+missing-tool: still disarmed" "$(triggers)" "none"

# 9) never blocks suspend: pre exits 0 even with no LED nodes at all.
reset_nodes
if env ARMADA_RGB_INDICATOR_LEDS="$tmp/nope/rgb:l?" ARMADA_RGB_KEEPALIVE="$tmp/nope/*/keep_alive" \
     ARMADA_RGB_CHARGE_INDICATOR_CONFIG="$indicator_config" ARMADA_RGB_TOOL="$rgb_tool" RGB_CALLS="$rgb_calls" \
     bash "$HOOK" pre suspend; then echo "ok: no nodes -> pre exit 0"; else echo "FAIL: missing nodes should not block suspend"; fail=1; fi

if (( fail )); then echo "rgb-suspend-charging hook: FAILURES"; exit 1; fi
echo "PASS: rgb-suspend-charging-hook-test (design A / kernel trigger)"
