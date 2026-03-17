// Workers — per-worker Prometheus metrics with cards, comparison, anomaly detection

import { createMemo, For, Show, onMount } from "solid-js";
import { state } from "../state";
import { sendWS } from "../api";
import { SectionHeader } from "../components/section-header";
import { formatLatency } from "./format";
import { rate, gauge, histogramQuantile, scrapeCount, uniqueLabels, rateHistory } from "../prom";

function HealthBadge(props: { errorRate: number }) {
  const cls = () => {
    if (props.errorRate > 0.05) return "badge-error";
    if (props.errorRate > 0.01) return "badge-warning";
    return "badge-success";
  };
  const label = () => {
    if (props.errorRate > 0.05) return "unhealthy";
    if (props.errorRate > 0.01) return "degraded";
    return "healthy";
  };
  return <span class={`badge badge-xs ${cls()}`}>{label()}</span>;
}

function Sparkline(props: { data: number[]; color?: string; height?: number }) {
  const h = () => props.height ?? 24;
  const w = 80;
  const path = createMemo(() => {
    const d = props.data;
    if (d.length < 2) return "";
    const max = Math.max(...d, 1);
    const points = d.map((v, i) => {
      const x = (i / (d.length - 1)) * w;
      const y = h() - (v / max) * h();
      return `${x},${y}`;
    });
    return `M${points.join("L")}`;
  });

  return (
    <svg width={w} height={h()} class="inline-block align-middle">
      <path d={path()} fill="none" stroke={props.color ?? "currentColor"} stroke-width="1.5" />
    </svg>
  );
}

export function Workers(props: { onNavigate?: (path: string, ctx?: Record<string, unknown>) => void }) {
  const s = state();

  onMount(() => {
    sendWS({ cmd: "info" });
  });

  // Touch traffic signal to trigger re-renders when SSE ticks
  const _ = () => s.traffic().length;

  const hasScrapes = createMemo(() => { _(); return scrapeCount() >= 2; });

  // Derive worker list from Prometheus labels
  const workerIds = createMemo(() => {
    _();
    return uniqueLabels("keyway_connections_active", "worker_id");
  });

  // Aggregate stats
  const totalRps = createMemo(() => { _(); return Math.round(rate("keyway_http_requests_total")); });
  const activeConns = createMemo(() => { _(); return gauge("keyway_connections_active"); });
  const activeCoroutines = createMemo(() => { _(); return gauge("keyway_lua_coroutines_active"); });
  const ringSubRate = createMemo(() => { _(); return Math.round(rate("keyway_ring_submissions_total")); });
  const ringCompRate = createMemo(() => { _(); return Math.round(rate("keyway_ring_completions_total")); });

  const p50 = createMemo(() => { _(); return histogramQuantile(0.50, "keyway_http_request_duration_seconds"); });
  const p95 = createMemo(() => { _(); return histogramQuantile(0.95, "keyway_http_request_duration_seconds"); });
  const p99 = createMemo(() => { _(); return histogramQuantile(0.99, "keyway_http_request_duration_seconds"); });

  const latencyUs = (seconds: number) => Math.round(seconds * 1_000_000);

  // Per-worker metric accessors
  function workerSelector(wid: string) {
    return (l: Record<string, string>) => l.worker_id === wid;
  }

  function workerRps(wid: string) {
    return Math.round(rate("keyway_http_requests_total", workerSelector(wid)));
  }

  function workerConns(wid: string) {
    return gauge("keyway_connections_active", { worker_id: wid });
  }

  function workerCoroutines(wid: string) {
    return gauge("keyway_lua_coroutines_active", { worker_id: wid });
  }

  function workerErrorRate(wid: string) {
    const total = rate("keyway_http_requests_total", workerSelector(wid));
    const errors = rate("keyway_http_requests_total", (l) => l.worker_id === wid && Number(l.status) >= 400);
    return total > 0 ? errors / total : 0;
  }

  function workerRpsHistory(wid: string) {
    return rateHistory("keyway_http_requests_total", workerSelector(wid));
  }

  // Anomaly detection: flag workers with error rate > 2x average
  const avgErrorRate = createMemo(() => {
    _();
    const ids = workerIds();
    if (ids.length === 0) return 0;
    let sum = 0;
    for (const wid of ids) sum += workerErrorRate(wid);
    return sum / ids.length;
  });

  function isAnomaly(wid: string) {
    const avg = avgErrorRate();
    if (avg <= 0) return false;
    return workerErrorRate(wid) > avg * 2;
  }

  function refresh() {
    sendWS({ cmd: "info" });
  }

  return (
    <div class="flex flex-col h-full">
      <SectionHeader title="Workers">
        <button class="btn btn-xs btn-ghost text-base-content/50" onClick={refresh}>Refresh</button>
      </SectionHeader>
      <div class="flex-1 overflow-y-auto p-4 space-y-4">
        {/* Aggregate stats from Prometheus */}
        <div class="bg-base-200 rounded p-3 space-y-3">
          <div class="text-detail text-base-content/50 font-medium">Aggregate</div>
          <Show when={hasScrapes()} fallback={<div class="text-detail text-base-content/45">Waiting for scrapes...</div>}>
            <div class="grid grid-cols-3 gap-3 text-center text-detail">
              <div><div class="text-base-content/50">Requests/sec</div><div class="text-base-content/80 font-semibold text-sm">{totalRps()}</div></div>
              <div><div class="text-base-content/50">Active Connections</div><div class="text-info font-semibold text-sm">{activeConns()}</div></div>
              <div><div class="text-base-content/50">Lua Coroutines</div><div class="text-base-content/80 font-semibold text-sm">{activeCoroutines()}</div></div>
            </div>
            <div class="grid grid-cols-3 gap-1 text-detail text-center">
              <div><div class="text-base-content/50">p50</div><div class="text-base-content/80 font-semibold">{formatLatency(latencyUs(p50()))}</div></div>
              <div><div class="text-base-content/50">p95</div><div class="text-warning font-semibold">{formatLatency(latencyUs(p95()))}</div></div>
              <div><div class="text-base-content/50">p99</div><div class="text-error font-semibold">{formatLatency(latencyUs(p99()))}</div></div>
            </div>
            <div class="grid grid-cols-2 gap-3 text-center text-detail">
              <div><div class="text-base-content/50">Ring Submissions/sec</div><div class="text-base-content/80 font-semibold text-sm">{ringSubRate()}</div></div>
              <div><div class="text-base-content/50">Ring Completions/sec</div><div class="text-base-content/80 font-semibold text-sm">{ringCompRate()}</div></div>
            </div>
          </Show>
        </div>

        {/* Per-worker cards */}
        <Show when={hasScrapes() && workerIds().length > 0}>
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50 font-medium mb-2">Per-Worker</div>
            <div class="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
              <For each={workerIds()}>
                {(wid) => {
                  const rps = createMemo(() => { _(); return workerRps(wid); });
                  const conns = createMemo(() => { _(); return workerConns(wid); });
                  const coros = createMemo(() => { _(); return workerCoroutines(wid); });
                  const errRate = createMemo(() => { _(); return workerErrorRate(wid); });
                  const anomaly = createMemo(() => { _(); return isAnomaly(wid); });
                  const history = createMemo(() => { _(); return workerRpsHistory(wid); });

                  return (
                    <div class={`bg-base-300/30 rounded p-3 border-l-2 ${anomaly() ? "border-error" : "border-base-content/20"}`}>
                      <div class="flex items-center gap-2 mb-2">
                        <span class="text-sm font-semibold text-base-content/80">Worker {wid}</span>
                        <HealthBadge errorRate={errRate()} />
                        <Show when={anomaly()}>
                          <span class="badge badge-xs badge-error badge-outline">anomaly</span>
                        </Show>
                      </div>
                      <div class="grid grid-cols-2 gap-1 text-detail">
                        <div><span class="text-base-content/50">RPS</span> <span class="text-base-content/80 font-semibold">{rps()}</span></div>
                        <div><span class="text-base-content/50">Conns</span> <span class="text-info font-semibold">{conns()}</span></div>
                        <div><span class="text-base-content/50">Coros</span> <span class="text-base-content/80 font-semibold">{coros()}</span></div>
                        <div><span class="text-base-content/50">Err%</span> <span class={`font-semibold ${errRate() > 0.05 ? "text-error" : errRate() > 0.01 ? "text-warning" : "text-success"}`}>{(errRate() * 100).toFixed(1)}%</span></div>
                      </div>
                      <Show when={history().length > 1}>
                        <div class="mt-1">
                          <Sparkline data={history()} color="var(--color-primary)" />
                        </div>
                      </Show>
                    </div>
                  );
                }}
              </For>
            </div>
          </div>
        </Show>

        {/* Worker comparison table */}
        <Show when={hasScrapes() && workerIds().length > 1}>
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50 font-medium mb-2">Worker Comparison</div>
            <div class="overflow-x-auto">
              <table class="table table-xs w-full">
                <thead>
                  <tr>
                    <th class="text-base-content/50">Worker</th>
                    <th class="text-base-content/50 text-right">RPS</th>
                    <th class="text-base-content/50 text-right">Connections</th>
                    <th class="text-base-content/50 text-right">Coroutines</th>
                    <th class="text-base-content/50 text-right">Error Rate</th>
                    <th class="text-base-content/50 text-center">Health</th>
                  </tr>
                </thead>
                <tbody>
                  <For each={workerIds()}>
                    {(wid) => {
                      const rps = createMemo(() => { _(); return workerRps(wid); });
                      const conns = createMemo(() => { _(); return workerConns(wid); });
                      const coros = createMemo(() => { _(); return workerCoroutines(wid); });
                      const errRate = createMemo(() => { _(); return workerErrorRate(wid); });

                      return (
                        <tr>
                          <td class="font-semibold text-base-content/80">{wid}</td>
                          <td class="text-right text-base-content/80">{rps()}</td>
                          <td class="text-right text-info">{conns()}</td>
                          <td class="text-right text-base-content/80">{coros()}</td>
                          <td class={`text-right font-semibold ${errRate() > 0.05 ? "text-error" : errRate() > 0.01 ? "text-warning" : "text-success"}`}>{(errRate() * 100).toFixed(1)}%</td>
                          <td class="text-center"><HealthBadge errorRate={errRate()} /></td>
                        </tr>
                      );
                    }}
                  </For>
                </tbody>
              </table>
            </div>
          </div>
        </Show>

        {/* Empty state */}
        <Show when={hasScrapes() && workerIds().length === 0}>
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/45 text-center">No worker metrics yet — send requests to see per-worker data</div>
          </div>
        </Show>
      </div>
    </div>
  );
}
