import { useEffect, useState } from "react";
import { getActivePowerProfile } from "../backend";

const POLL_INTERVAL_MS = 3000;

// armada#24: polls the LIVE active power profile so the Power tab stays
// correct if it's changed from elsewhere (Steam's native "Rendimiento"
// panel) while this tab is open -- the same failure mode that made Armada
// Control and "Rendimiento" look like two disagreeing systems in the
// 2026-09-18 QA.
export function useActivePowerProfile(initial: string = ""): string {
  const [active, setActive] = useState(initial);
  useEffect(() => {
    let cancelled = false;
    const poll = async () => {
      try {
        const next = await getActivePowerProfile();
        if (!cancelled) setActive(next);
      } catch {
        // Transient read failure -- skip this tick rather than surfacing an error.
      }
    };
    // Skip the immediate fetch when the caller already seeded a fresh value
    // (Power.tsx passes config.activePowerProfile); callers with no initial
    // (the title-bar badge) fetch right away instead of waiting a full tick.
    if (!initial) poll();
    const timer = window.setInterval(poll, POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);
  return active;
}
