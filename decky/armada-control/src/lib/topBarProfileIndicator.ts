// NOT WIRED IN. Skeleton for the FULLER version of armada#25: an icon next
// to the battery/clock in the SYSTEM top bar (gamepadui), visible without
// opening Armada Control's own panel -- ActiveProfileBadge.tsx only covers
// the safe, officially-typed half (Decky's `titleView`, shown inside our own
// panel).
//
// This half needs patching Steam's own gamepadui React tree. @decky/ui does
// export the tools other Decky plugins use for exactly this
// (findModuleChild, afterPatch, findModuleExport -- confirmed present in
// @decky/ui 4.11.6's dist/webpack.d.ts and dist/utils/patcher.d.ts as of
// 2026-09-18), so the MECHANISM is real and sanctioned. What's missing is
// the actual target: which webpack module/component renders the row of
// icons next to the clock in the CURRENT armada-os gamepadui build. That is
// not discoverable by reading source in this repo -- gamepadui is Valve's
// bundle, not ours -- and this session had no live device/browser devtools
// connection to inspect it.
//
// TO FINISH THIS (needs a live RP6 or a Steam Deck on the target build):
//   1. Put the device in game mode, connect Chrome DevTools to the gamepadui
//      CEF instance (SteamOS/ArmadaOS expose a remote-debugging port for
//      this; several Decky plugin READMEs document the exact steps, e.g.
//      PowerTools / decky-cssloader's dev docs).
//   2. In the console, use `findModuleChild` from the page's own webpack
//      runtime to locate the component that renders the top-bar icon row
//      (search by a stable string it renders, e.g. the battery percentage
//      format, NOT by a minified export name -- those aren't stable across
//      steamui builds).
//   3. Replace TOP_BAR_MODULE_FILTER below with that real filter, verify the
//      afterPatch call renders in the right slot without shifting existing
//      icons, and QA across a couple of steamui updates before trusting it
//      long-term (this pattern is known to break on major Steam updates --
//      that's an accepted, not a novel, risk in the Decky ecosystem).
//
// Until then, this file intentionally does nothing when imported -- it is
// NOT imported from index.tsx. Wire `installTopBarProfileIndicator()` in
// from index.tsx's definePlugin() (call on mount, keep the returned
// Patch.unpatch for onDismount) once step 2 above has a real filter.

import { afterPatch, findModuleChild } from "@decky/ui";

// PLACEHOLDER -- must never match anything real until replaced, so an
// accidental import can't silently patch the wrong module.
const TOP_BAR_MODULE_FILTER = (_module: unknown) => false;

export function installTopBarProfileIndicator(): (() => void) | null {
  const target = findModuleChild(TOP_BAR_MODULE_FILTER);
  if (!target) return null;
  // Example shape once a real target is found (component name/prop is a
  // guess for illustration, NOT verified):
  //   const patch = afterPatch(target.prototype, "render", (_args, ret) => {
  //     ret.props.children.push(<ActiveProfileBadge />);
  //     return ret;
  //   });
  //   return patch.unpatch;
  void afterPatch;
  return null;
}
