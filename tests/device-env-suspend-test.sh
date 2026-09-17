#!/usr/bin/env bash
# Asserts the INTENT of the RP6 deep-suspend default, not just that device-env
# runs. device-env resolves ARMADA_SUSPEND_MODE from defaults.conf, the matched
# device profile, /sys/power/mem_sleep and /etc/armada/sleep.conf, in that order.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ENV="$ROOT/system_files/usr/libexec/armada/device-env"
DEVICE_DIR="$ROOT/system_files/usr/lib/armada/devices"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
pass=0

# resolve_mode <model> <mem_sleep_contents> <sleep_conf_contents|"">
# Prints the resolved ARMADA_SUSPEND_MODE. Empty sleep-conf arg => no sleep.conf.
resolve_mode() {
    local model=$1 mem_contents=$2 sleep_contents=${3-}
    local mem sconf
    mem="$WORK/mem_sleep"
    printf '%s\n' "$mem_contents" >"$mem"
    if [[ -n "$sleep_contents" ]]; then
        sconf="$WORK/sleep.conf"
        printf '%s\n' "$sleep_contents" >"$sconf"
    else
        sconf="$WORK/nonexistent-sleep.conf"
        rm -f "$sconf"
    fi
    local out
    out=$(ARMADA_DEVICE_DIR="$DEVICE_DIR" ARMADA_MODEL="$model" \
        ARMADA_MEM_SLEEP_PATH="$mem" ARMADA_SLEEP_CONFIG="$sconf" \
        bash "$DEVICE_ENV")
    eval "$out"
    printf '%s' "${ARMADA_SUSPEND_MODE:-}"
}

check() {
    local desc=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        pass=$((pass + 1))
        printf 'ok   - %s (got %q)\n' "$desc" "$got"
    else
        fail=$((fail + 1))
        printf 'FAIL - %s: got %q, want %q\n' "$desc" "$got" "$want"
    fi
}

# 1. The RP6 profile defaults to deep with no user override, when the kernel
#    advertises deep. This is the whole point of the branch.
check "RP6 defaults to deep" \
    "$(resolve_mode 'Retroid Pocket 6' 's2idle [deep]')" deep

# 2. An explicit, supported user override in sleep.conf wins over the profile.
check "RP6 sleep.conf=s2idle overrides the deep default" \
    "$(resolve_mode 'Retroid Pocket 6' 's2idle [deep]' 'suspend_mode=s2idle')" s2idle

# 3. fake is always accepted (it is not a kernel mem_sleep mode).
check "RP6 sleep.conf=fake is honored" \
    "$(resolve_mode 'Retroid Pocket 6' 's2idle [deep]' 'suspend_mode=fake')" fake

# 4. A user override the running kernel does NOT advertise falls back to the
#    device profile default (deep on the RP6) instead of being applied blindly.
check "RP6 unsupported sleep.conf override falls back to the profile default" \
    "$(resolve_mode 'Retroid Pocket 6' '[deep]' 'suspend_mode=s2idle')" deep

# 5. deep is RP6-scoped: every other/unknown device keeps the s2idle default
#    from defaults.conf, so the branch does not change the rest of the fleet.
check "unknown device keeps the s2idle fleet default" \
    "$(resolve_mode 'No Such Handheld' 's2idle [deep]')" s2idle

# 6. deep survives on the RP6 even when it is the *selected* kernel mode already
#    (s2idle absent), i.e. the profile default is not clobbered to fake.
check "RP6 stays on deep when only deep is advertised" \
    "$(resolve_mode 'Retroid Pocket 6' '[deep]')" deep

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
