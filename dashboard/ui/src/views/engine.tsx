// Engine — runtime landing view: worker distribution, status taxonomy, route latency
// Sourced entirely from GET /metrics (Prometheus text), polled in main.tsx.

import { createMemo, For, Show } from "solid-js";
import { type MetricsSnapshot, classifyStatus, INVOCATION_LABELS, formatLatency } from "../main";

function chipClass(cls: string): string {
  if (cls === "success") return "text-success border-success/30";
  if (cls === "client_error" || cls === "timeout") return "text-warning border-warning/30";
  if (cls === "internal_error" || cls === "resource_exceeded") return "text-error border-error/30";
  return "text-base-content/50 border-base-300"; // client_disconnect
}

function StatCard(p: { label: string; value: string; class?: string }) {
  return (
    <div class={`flex-1 min-w-[100px] border border-base-300 rounded p-2 ${p.class || ""}`}>
      <div class="text-tiny text-base-content/40 uppercase tracking-wider">{p.label}</div>
      <div class="text-sm font-semibold mt-0.5">{p.value}</div>
    </div>
  );
}

export function EngineView(props: {
  metrics: () => MetricsSnapshot | null;
  prev: () => MetricsSnapshot | null;
  onNavigate: (path: string, ctx?: Record<string, unknown>) => void;
}) {
  const reqPerSec = createMemo(() => {
    const cur = props.metrics();
    const prev = props.prev();
    if (!cur || !prev || cur.ts === prev.ts) return null;
    const dt = (cur.ts - prev.ts) / 1000;
    return dt > 0 ? (cur.total - prev.total) / dt : null;
  });

  const errorRate = createMemo(() => {
    const m = props.metrics();
    if (!m || m.total === 0) return 0;
    let errors = 0;
    for (const [status, count] of m.byStatus) if (status >= 400) errors += count;
    return (errors / m.total) * 100;
  });

  const workers = createMemo(() => {
    const m = props.metrics();
    if (!m) return [];
    const max = Math.max(1, ...m.byWorker.values());
    return [...m.byWorker.entries()]
      .sort((a, b) => Number(a[0]) - Number(b[0]))
      .map(([id, count]) => ({ id, count, pct: (count / max) * 100 }));
  });

  const statusGroups = createMemo(() => {
    const m = props.metrics();
    if (!m) return [];
    const groups = new Map<string, number>();
    for (const [status, count] of m.byStatus) {
      const cls = classifyStatus(status);
      groups.set(cls, (groups.get(cls) || 0) + count);
    }
    return [...groups.entries()].map(([cls, count]) => ({ cls, count, label: INVOCATION_LABELS[cls] || cls }));
  });

  const routeRows = createMemo(() => {
    const m = props.metrics();
    if (!m) return [];
    const rows = [...m.byRoute.entries()].map(([route, s]) => {
      const lat = m.latencyByRoute.get(route);
      const avgUs = lat && lat.count > 0 ? (lat.sum / lat.count) * 1e6 : 0;
      return { route, hits: s.hits, errors: s.errors, avgUs };
    });
    rows.sort((a, b) => b.hits - a.hits);
    return rows;
  });

  return (
    <div class="flex flex-col h-full">
      <Show when={props.metrics()} fallback={
        <div class="flex flex-col gap-2 p-3">
          <div class="skeleton-pulse rounded h-14" />
          <div class="skeleton-pulse rounded h-20" />
          <div class="skeleton-pulse rounded h-40" />
        </div>
      }>
        {(m) => <>
          {/* Stat strip */}
          <div class="flex gap-2 p-3 flex-wrap border-b border-base-300/50">
            <StatCard label="Requests" value={String(m().total)} />
            <StatCard label="Req/s" value={reqPerSec() === null ? "-" : reqPerSec()!.toFixed(1)} />
            <StatCard label="Error rate" value={errorRate().toFixed(1) + "%"} />
            <StatCard label="Active conns" value={String(m().activeConnections)} />
            <StatCard label="Lua coroutines" value={String(m().activeCoroutines)} />
            <Show when={m().rejected > 0}>
              <StatCard label="Rejected conns" value={String(m().rejected)} class="text-error" />
            </Show>
          </div>

          {/* Workers — per-core SO_REUSEPORT distribution */}
          <div class="px-3 py-3 border-b border-base-300/50">
            <div class="text-detail text-base-content/40 font-semibold tracking-wider mb-1.5">WORKERS</div>
            <Show when={workers().length > 0} fallback={
              <div class="text-detail text-base-content/30 italic">No requests handled yet</div>
            }>
              <div class="flex flex-col gap-1">
                <For each={workers()}>
                  {(w) => (
                    <div class="flex items-center gap-2">
                      <span class="text-detail text-base-content/50 w-8 shrink-0">w{w.id}</span>
                      <div class="flex-1 h-3 bg-base-300/30 rounded overflow-hidden">
                        <div class="h-full bg-primary/40" style={{ width: `${w.pct}%` }} />
                      </div>
                      <span class="text-detail text-base-content/60 w-10 text-right shrink-0">{w.count}</span>
                    </div>
                  )}
                </For>
              </div>
            </Show>
          </div>

          {/* Status taxonomy */}
          <div class="px-3 py-3 border-b border-base-300/50 flex items-center gap-2 flex-wrap">
            <For each={statusGroups()}>
              {(g) => (
                <span class={`badge badge-xs border text-tiny py-2 ${chipClass(g.cls)}`}>{g.label}: {g.count}</span>
              )}
            </For>
          </div>

          {/* Zero traffic vs routes table */}
          <Show when={m().total === 0}>
            <div class="flex-1 flex items-center justify-center text-base-content/40 text-sm text-center px-4">
              No traffic yet &mdash; try <code class="mx-1 text-primary/70">curl localhost:8080/test/json</code> or use the console
            </div>
          </Show>
          <Show when={m().total > 0}>
            <div class="flex-1 overflow-y-auto px-3 py-3">
              <table class="table table-xs w-full">
                <thead>
                  <tr>
                    <th>Route</th><th>Hits</th><th>Errors</th><th>Avg latency</th>
                  </tr>
                </thead>
                <tbody>
                  <For each={routeRows()}>
                    {(r) => (
                      <tr
                        class={r.route ? "hover:bg-base-300/30 cursor-pointer" : ""}
                        onClick={() => { if (r.route) props.onNavigate("/routes", { filter_pattern: r.route }); }}
                      >
                        <td>{r.route || <span class="text-base-content/40 italic">(static / unmatched)</span>}</td>
                        <td>{r.hits}</td>
                        <td>{r.errors}</td>
                        <td>{formatLatency(r.avgUs)}</td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>
          </Show>
        </>}
      </Show>
    </div>
  );
}
