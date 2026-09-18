import type { RgbEffect } from "../types";

// The armada-rgb effect list, in dropdown order. Kept here (pure, no React)
// so it can be unit-tested without a DOM. Matches the armada-rgb CLI
// contract (.claude/projects/rp6-rgb-cli-contract-2026-09-18.md).
//
// screen_sync (armada#27) IS offered: its capture path is now efficient
// (edge-only sampling on a slow, tunable cadence -- gamescope has no
// region/downscale capture, so those are the levers; see armada-rgb
// effects.rs). Because every effect armada-rgb supports appears here,
// `displayedEffect` never has to misrepresent a real saved effect as
// "Static" (the armada#27 dropdown-"Static" fix).
//
// Brightness-sync (armada#23) is NOT in this list -- it's the orthogonal
// toggle in RgbLighting, combinable with any of these.
export const EFFECT_OPTIONS: { data: RgbEffect; label: string }[] = [
  { data: "static", label: "Static" },
  { data: "breathing", label: "Breathing" },
  { data: "color_cycle", label: "Color Cycle" },
  { data: "rainbow", label: "Rainbow" },
  { data: "load", label: "CPU Load" },
  { data: "battery", label: "Battery" },
  { data: "screen_sync", label: "Screen Sync" },
];

// Effects that paint the configured base color (the rest derive their own
// hue -- screen_sync samples it from the screen, so it is NOT here and the
// color slider is disabled for it).
export const USES_BASE_COLOR: readonly RgbEffect[] = ["static", "breathing"];

// Effects whose motion the speed slider controls. State-driven effects set
// their own cadence, and the CLI contract says --speed is ignored by
// screen_sync, so it is NOT here.
export const USES_SPEED: readonly RgbEffect[] = ["breathing", "color_cycle", "rainbow"];

// Resolve the effect the Effect dropdown should DISPLAY for a persisted
// config value. Every effect armada-rgb actually supports is in
// EFFECT_OPTIONS, so a real saved effect (screen_sync included) is shown as
// itself; only a genuinely unknown/future value falls back to "static" so
// the control always has a valid selection. Pure display resolution -- it
// never rewrites config.effect or triggers a set_rgb() call by itself.
export function displayedEffect(raw: RgbEffect | undefined): RgbEffect {
  const effect: RgbEffect = raw ?? "static";
  return EFFECT_OPTIONS.some((option) => option.data === effect) ? effect : "static";
}
