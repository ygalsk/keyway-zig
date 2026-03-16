// Shared formatting utilities for dashboard views
// No JSX — stays as .ts

export function formatLatency(us: number): string {
  if (!us || us === 0) return "-";
  if (us < 1000) return us + "us";
  if (us < 1000000) return (us / 1000).toFixed(1) + "ms";
  return (us / 1000000).toFixed(2) + "s";
}

export function formatTime(ts: number, showMs = true): string {
  const d = new Date(ts);
  const base = d.toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" });
  return showMs ? base + "." + String(d.getMilliseconds()).padStart(3, "0") : base;
}
