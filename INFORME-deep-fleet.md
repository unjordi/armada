# Deep suspend as a two-gate FLEET feature

**Branch:** `feat/deep-sleep-fleet-gate` · **Base:** `origin/develop` @ `74a9e0d70e6bb42c890f86d4ff0fa617d1de48fc`
(`suspend-dispatch: drop the dead "mem" suspend-mode branch (#3)`).

## Goal
Deep suspend must activate only when **BOTH** compuertas pass:
1. **Kernel gate** — the running kernel advertises `deep` in `/sys/power/mem_sleep`.
2. **Fleet-validation gate** — the *model* is validated for deep.

Expressed with Armada's **existing per-`.conf` idiom** (no new central manifest), with the mode
logic **unified into one source of truth** and the UI showing deep **greyed** (not hidden) when the
model is not validated.

## How "validated" is declared (native, per-`.conf`)
A device `.conf` clears its model for deep in its own idiom:
- **Default path (native):** set `ARMADA_SUSPEND_MODE=deep` → deep is the default *and* implies
  validation. The **RP6** already does this (`retroid-pocket-6.conf:10`), so it needed no new flag.
- **Explicit flag (minimal addition):** `ARMADA_SUSPEND_DEEP_VALIDATED=1` marks a model cleared for
  deep **without** making it the default (deep stays user-selectable/greyed-off). Introduced in the
  `.conf` shell-var idiom; fleet floor `ARMADA_SUSPEND_DEEP_VALIDATED=0` in `defaults.conf`.
- **Migration pre-seed:** every other device `.conf` (20 files) got a commented line
  `# ARMADA_SUSPEND_MODE=deep  # uncomment once deep-charge is validated on this model`.

## Net change (file:line)

### Gate + validation signal — `system_files/usr/libexec/armada/device-env`
- `:53-56` resolve `deep_validated` from the `.conf` (`ARMADA_SUSPEND_DEEP_VALIDATED`, and
  `profile_suspend_mode==deep` ⇒ validated).
- `:83-85` **fleet gate (2nd compuerta):** `if mode==deep && !validated → mode=$profile_suspend_mode`.
  Runs before the existing kernel gate (`:87-93`), so an unvalidated model that asked for deep (only a
  user `sleep.conf` can, no unvalidated profile does) falls back to s2idle, then to fake if s2idle
  isn't advertised. Reuses `profile_suspend_mode` as the fallback exactly as the task asked.
- `:139` + `:147` export `ARMADA_SUSPEND_DEEP_VALIDATED` so UI/backend read one resolved signal.

### Confs
- `defaults.conf` — fleet floor `ARMADA_SUSPEND_DEEP_VALIDATED=0` + doc comment.
- `retroid-pocket-6.conf` — comment noting deep-default ⇒ validated (no flag needed).
- 20 other device `.conf` — commented pre-seed line for progressive migration.

### Unification (ONE source of truth) — `system_files/usr/libexec/armada/armada-control`
- `:391 sleep_modes()` — **authoritative** menu: `[{data,label,disabled}]`. Kernel-unadvertised
  modes are omitted; `deep` is always offered on a deep-capable kernel but `disabled=True` until the
  model is validated (reads `ARMADA_SUSPEND_DEEP_VALIDATED` from `device_env()`). Owns the labels.
- `:420 enabled_sleep_modes()` — derived set (non-disabled) for enforcement, so display and
  enforcement can't drift. Replaces the old `available_sleep_modes()`.
- `:434 action_get_sleep_modes` + registered in `ACTIONS` (`:787`) — the menu the plugin consumes.
- `:443 action_set_sleep_mode` — **defense in depth:** rejects any value not in
  `enabled_sleep_modes()` (same source the menu is built from), so deep-not-validated is refused even
  if the UI showed it.
- **Decky `py_modules/armada_control/system.py:163 sleep_modes()`** — now calls
  `get_sleep_modes` on the backend instead of re-reading `mem_sleep`; removed the duplicated
  `SLEEP_MODE_LABELS`/`MEM_SLEEP_PATH`. Safe fallback = `fake` only if the backend is unreachable.
  (This kills the triplication: device-env resolves validation → armada-control owns the menu →
  Decky + TS consume it.)

### UI greyed (present but not selectable)
- `src/types.ts:132` — `DropdownChoice` extended with optional `disabled?: boolean`.
- `src/components/widgets.tsx:23-35` — `SelectEdit` decorates disabled options with a `(unavailable)`
  cue and **guards `onChange`** so a disabled option is a no-op. This works regardless of whether the
  Steam `Dropdown` honours per-option disabled (it also passes the flag through), which is the clean
  fallback the task allowed ("labeled + non-selectable"). Deep therefore renders greyed + inert on an
  unvalidated model, distinct from a kernel-absent mode which is not in the list at all.

## Tests (extended, run GREEN)
- `tests/device-env-suspend-test.sh` — **9/9 pass**. Added #7 (unvalidated model ignores a `sleep.conf`
  deep override → s2idle), #8 (unvalidated + only-deep kernel → degrades to fake), #9 (unknown device
  ignores deep override). Existing RP6 deep + override cases still pass.
- `tests/armada-control-settings-test.sh` — **passes**. Rewrote the sleep section to assert: validated
  model → deep enabled + accepted; **plugin menu == backend menu** (single source of truth);
  unvalidated model → deep greyed (`disabled:true`) + `set_sleep_mode` rejects it; kernel gate omits
  unadvertised modes; `sleep.conf` overrides for s2idle/fake still respected. Retargeted the two
  AYN-Odin-2 deep-override assertions to the new intent and the device-quirks reapply test to the RP6.
- **Decky frontend:** `npx tsc --noEmit` exit 0; `npm run build` (rollup, same as image build) OK;
  `npm test` **26/26 pass**.
- Pre-existing/unrelated failures (verified failing on pristine `origin/develop` too, environmental):
  `perf-settings-test.sh`, `run-bottom-test.sh` (absent scx schedulers), `controller-profile-test.sh`
  (`ARMADA_PROFILE_NAMES`). Not touched by this change.

## Pending
None. (Follow-up outside this task's scope: validating additional models is now a one-line `.conf`
edit — uncomment the pre-seeded `ARMADA_SUSPEND_MODE=deep`, or set `ARMADA_SUSPEND_DEEP_VALIDATED=1`.)
