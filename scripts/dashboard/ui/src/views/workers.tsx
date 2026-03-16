// Workers — worker grid + focused worker detail + aggregate metrics

import { createSignal, createMemo, For, Show, onMount } from "solid-js";
import { state, type TrafficEntry } from "../state";
import { sendWS } from "../api";
import { MethodBadge, StatusBadge } from "../components/badge";
import { SectionHeader } from "../components/section-header";
import { formatLatency, formatTime } from "./format";

interface WorkerStats {
  requests: number;
  errors: number;
  errorRate: number;
  avgLatency: number;
  minLatency: number;
  p50Latency: number;
  p95Latency: number;
  p99Latency: number;
  maxLatency: number;
  entries: TrafficEntry[];
}

function computeAllWorkerStats(traffic: TrafficEntry[]): Map<number, WorkerStats> {
  const buckets = new Map<number, { entries: TrafficEntry[]; errors: number; latencies: number[] }>();
  for (const e of traffic) {
    const w = Number(e.worker_id);
    let b = buckets.get(w);
    if (!b) { b = { entries: [], errors: 0, latencies: [] }; buckets.set(w, b); }
    b.entries.push(e);
    if (e.status >= 400) b.errors++;
    if (e.latency_us > 0) b.latencies.push(e.latency_us);
  }

  const result = new Map<number, WorkerStats>();
  for (const [w, b] of buckets) {
    b.latencies.sort((a, c) => a - c);
    const len = b.latencies.length;
    const reqs = b.entries.length;
    const p = (pct: number) => len ? b.latencies[Math.floor(len * pct)] || 0 : 0;
    result.set(w, {
      requests: reqs,
      errors: b.errors,
      errorRate: reqs > 0 ? (b.errors / reqs) * 100 : 0,
      avgLatency: len ? b.latencies.reduce((a, c) => a + c, 0) / len : 0,
      minLatency: len ? b.latencies[0] : 0,
      p50Latency: p(0.5),
      p95Latency: p(0.95),
      p99Latency: p(0.99),
      maxLatency: len ? b.latencies[len - 1] : 0,
      entries: b.entries,
    });
  }
  return result;
}

export function Workers(props: { onNavigate?: (path: string, ctx?: Record<string, unknown>) => void }) {
  const s = state();
  const [focusedWorker, setFocusedWorker] = createSignal<number | null>(null);

  onMount(() => {
    const ctx = s.consumeNavContext("focus_worker") as number | undefined;
    if (ctx !== undefined && ctx !== null) setFocusedWorker(ctx);
    sendWS({ cmd: "info" });
  });

  const allStats = createMemo(() => computeAllWorkerStats(s.traffic()));
  const workerCount = () => s.metrics()?.worker_count || 1;

  // Compute averages across workers for anomaly detection
  const avgErrorRate = createMemo(() => {
    const stats = allStats();
    if (stats.size === 0) return 0;
    let total = 0;
    for (const [, ws] of stats) total += ws.errorRate;
    return total / stats.size;
  });
  const avgP95 = createMemo(() => {
    const stats = allStats();
    if (stats.size === 0) return 0;
    let total = 0;
    for (const [, ws] of stats) total += ws.p95Latency;
    return total / stats.size;
  });

  // Aggregate metrics
  const aggregate = createMemo(() => {
    const m = s.metrics();
    const stats = allStats();
    let totalReqs = 0, totalErrs = 0;
    const allLatencies: number[] = [];
    for (const [, ws] of stats) {
      totalReqs += ws.requests;
      totalErrs += ws.errors;
      for (const e of ws.entries) {
        if (e.latency_us > 0) allLatencies.push(e.latency_us);
      }
    }
    allLatencies.sort((a, b) => a - b);
    const len = allLatencies.length;
    const p = (pct: number) => len ? allLatencies[Math.floor(len * pct)] || 0 : 0;
    return {
      totalRequests: m?.total_requests || totalReqs,
      activeConnections: m?.active_connections || 0,
      totalErrors: m?.total_errors || totalErrs,
      min: len ? allLatencies[0] : 0,
      p50: p(0.5),
      p95: p(0.95),
      p99: p(0.99),
      max: len ? allLatencies[len - 1] : 0,
      samples: len,
    };
  });

  function refresh() {
    sendWS({ cmd: "info" });
  }

  return (
    <div class="flex flex-col h-full">
      <SectionHeader title="Workers">
        <button class="btn btn-xs btn-ghost text-base-content/50" onClick={refresh}>Refresh</button>
      </SectionHeader>
      <div class="flex-1 overflow-y-auto p-4 space-y-4">
        {/* Worker grid */}
        <div class="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
          <For each={Array.from({ length: workerCount() }, (_, i) => i)}>
            {(i) => {
              const stats = () => allStats().get(i) || { requests: 0, errors: 0, errorRate: 0, avgLatency: 0, minLatency: 0, p50Latency: 0, p95Latency: 0, p99Latency: 0, maxLatency: 0, entries: [] };
              const isFocused = () => focusedWorker() === i;

              // Anomaly: error rate or p95 is >2x the average
              const isAnomaly = () => {
                const st = stats();
                if (st.requests === 0) return false;
                const errAnomaly = avgErrorRate() > 0 && st.errorRate > avgErrorRate() * 2;
                const latAnomaly = avgP95() > 0 && st.p95Latency > avgP95() * 2;
                return errAnomaly || latAnomaly;
              };

              const healthLabel = () => {
                const st = stats();
                if (st.requests === 0) return "idle";
                if (st.errorRate > 5) return "degraded";
                return "healthy";
              };
              const healthBadge = () => {
                const h = healthLabel();
                if (h === "idle") return "badge-ghost text-base-content/50";
                if (h === "degraded") return "badge-warning";
                return "badge-success";
              };
              const borderColor = () => {
                if (isFocused()) return "border-primary ring-1 ring-primary";
                if (isAnomaly()) return "border-warning";
                const h = healthLabel();
                if (h === "idle") return "border-base-300";
                if (h === "degraded") return "border-warning";
                return "border-success";
              };

              return (
                <div
                  class={`bg-base-200 rounded p-3 border-l-2 ${borderColor()} cursor-pointer hover:bg-base-300/50 transition-colors`}
                  onClick={() => setFocusedWorker(focusedWorker() === i ? null : i)}
                >
                  <div class="flex items-center gap-2 mb-2">
                    <span class="text-sm font-semibold text-base-content/80">Worker {i}</span>
                    <Show when={isAnomaly()}>
                      <span class="text-warning text-xs" title="Anomaly: significantly above average">▲</span>
                    </Show>
                    <span class={`ml-auto badge badge-xs ${healthBadge()}`}>{healthLabel()}</span>
                  </div>
                  <div class="space-y-0.5 text-detail">
                    <div class="flex justify-between"><span class="text-base-content/50">Requests</span><span class="text-base-content/80">{stats().requests}</span></div>
                    <div class="flex justify-between">
                      <span class="text-base-content/50">Error rate</span>
                      <span class={stats().errorRate > 0 ? "text-error" : "text-base-content/30"}>{stats().errorRate.toFixed(1)}%</span>
                    </div>
                    <div class="flex justify-between"><span class="text-base-content/50">Avg latency</span><span class="text-base-content/80">{formatLatency(stats().avgLatency)}</span></div>
                  </div>
                </div>
              );
            }}
          </For>
        </div>

        {/* Focused worker detail */}
        <Show when={focusedWorker() !== null}>
          {(_) => {
            const wid = () => focusedWorker()!;
            const ws = () => allStats().get(wid()) || { requests: 0, errors: 0, errorRate: 0, avgLatency: 0, minLatency: 0, p50Latency: 0, p95Latency: 0, p99Latency: 0, maxLatency: 0, entries: [] };
            const methods = createMemo(() => {
              const m: Record<string, number> = {};
              ws().entries.forEach(e => { m[e.method] = (m[e.method] || 0) + 1; });
              return Object.entries(m).sort((a, b) => b[1] - a[1]);
            });
            const statuses = createMemo(() => {
              const st: Record<string, number> = {};
              ws().entries.forEach(e => {
                const bucket = e.status < 200 ? "1xx" : e.status < 300 ? "2xx" : e.status < 400 ? "3xx" : e.status < 500 ? "4xx" : "5xx";
                st[bucket] = (st[bucket] || 0) + 1;
              });
              return Object.entries(st);
            });
            const statusCls: Record<string, string> = { "2xx": "text-success", "3xx": "text-info", "4xx": "text-warning", "5xx": "text-error" };

            // Health explanation
            const healthExplanation = () => {
              const st = ws();
              const parts: string[] = [];
              if (st.errorRate > 5) parts.push(`${st.errorRate.toFixed(1)}% error rate`);
              if (avgP95() > 0 && st.p95Latency > avgP95() * 2) parts.push(`p95 ${formatLatency(st.p95Latency)} exceeds avg ${formatLatency(avgP95())}`);
              if (parts.length === 0) {
                if (st.requests === 0) return "idle — no traffic";
                return "healthy";
              }
              return "degraded: " + parts.join(", ");
            };

            // Recent errors — status >= 400 for this worker
            const recentErrors = createMemo(() =>
              ws().entries.filter(e => e.status >= 400).slice(0, 20)
            );

            return (
              <div class="bg-base-200 rounded p-3 border-l-2 border-primary space-y-3">
                <div class="flex items-center justify-between">
                  <span class="text-sm font-semibold text-primary">Worker {wid()} Detail</span>
                  <button class="btn btn-xs btn-ghost text-base-content/40" onClick={() => setFocusedWorker(null)}>Close</button>
                </div>

                <div class="text-detail text-base-content/50">{healthExplanation()}</div>

                {/* Latency percentiles */}
                <div class="grid grid-cols-5 gap-1 text-detail text-center">
                  <div><div class="text-base-content/40">min</div><div class="text-base-content/80 font-semibold">{formatLatency(ws().minLatency)}</div></div>
                  <div><div class="text-base-content/40">p50</div><div class="text-base-content/80 font-semibold">{formatLatency(ws().p50Latency)}</div></div>
                  <div><div class="text-base-content/40">p95</div><div class="text-warning font-semibold">{formatLatency(ws().p95Latency)}</div></div>
                  <div><div class="text-base-content/40">p99</div><div class="text-error font-semibold">{formatLatency(ws().p99Latency)}</div></div>
                  <div><div class="text-base-content/40">max</div><div class="text-error font-semibold">{formatLatency(ws().maxLatency)}</div></div>
                </div>

                <div class="grid grid-cols-3 gap-2 text-detail text-center">
                  <div><div class="text-base-content/50">requests</div><div class="text-base-content/80 font-semibold">{ws().requests}</div></div>
                  <div><div class="text-base-content/50">error rate</div><div class={`${ws().errorRate > 0 ? "text-error" : "text-base-content/30"} font-semibold`}>{ws().errorRate.toFixed(1)}%</div></div>
                  <div><div class="text-base-content/50">avg latency</div><div class="text-base-content/80 font-semibold">{formatLatency(ws().avgLatency)}</div></div>
                </div>

                <div class="flex gap-2 text-detail">
                  <Show when={statuses().length > 0} fallback={<span class="text-base-content/30">No traffic</span>}>
                    <For each={statuses()}>
                      {([bucket, count], i) => (
                        <>
                          <Show when={i() > 0}><span class="text-base-content/20">|</span></Show>
                          <span class={statusCls[bucket] || "text-base-content/50"}>{bucket}: {count}</span>
                        </>
                      )}
                    </For>
                  </Show>
                </div>

                <Show when={methods().length > 0}>
                  <div class="space-y-0.5">
                    <For each={methods()}>
                      {([method, count]) => {
                        const pct = () => ws().requests > 0 ? ((count / ws().requests) * 100).toFixed(0) : "0";
                        return (
                          <div class="flex items-center gap-2 text-detail">
                            <MethodBadge method={method} />
                            <div class="flex-1 bg-base-300 rounded-full h-1.5">
                              <div class="bg-primary/50 h-1.5 rounded-full" style={{ width: `${pct()}%` }} />
                            </div>
                            <span class="text-base-content/50 w-12 text-right">{count} ({pct()}%)</span>
                          </div>
                        );
                      }}
                    </For>
                  </div>
                </Show>

                {/* Recent Errors */}
                <Show when={recentErrors().length > 0}>
                  <div>
                    <div class="text-detail text-base-content/50 mb-1">Recent Errors</div>
                    <For each={recentErrors()}>
                      {(e) => (
                        <div
                          class="py-1 border-b border-base-300/30 cursor-pointer hover:bg-base-300/30"
                          onClick={() => props.onNavigate?.("/traffic", { worker_id: String(wid()), status_family: e.status >= 500 ? "5xx" : "4xx" })}
                        >
                          <div class="flex items-center gap-2 text-detail">
                            <span class="text-base-content/50 w-[55px] shrink-0">{formatTime(e.ts)}</span>
                            <MethodBadge method={e.method} />
                            <span class="text-base-content/50 flex-1 truncate">{e.path}</span>
                            <StatusBadge status={e.status} />
                            <span class="text-base-content/50 w-[50px] text-right">{formatLatency(e.latency_us)}</span>
                          </div>
                          <Show when={e.error_message}>
                            <div class="text-error text-detail ml-[55px] mt-0.5 truncate" title={e.error_message}>→ {e.error_message}</div>
                          </Show>
                        </div>
                      )}
                    </For>
                  </div>
                </Show>
              </div>
            );
          }}
        </Show>

        {/* Aggregate metrics */}
        <div class="bg-base-200 rounded p-3 space-y-3">
          <div class="text-detail text-base-content/50 font-medium">Aggregate</div>
          <div class="grid grid-cols-3 gap-3 text-center text-detail">
            <div><div class="text-base-content/40">Total Requests</div><div class="text-base-content/80 font-semibold text-sm">{aggregate().totalRequests.toLocaleString()}</div></div>
            <div><div class="text-base-content/40">Active Connections</div><div class="text-info font-semibold text-sm">{aggregate().activeConnections}</div></div>
            <div><div class="text-base-content/40">Total Errors</div><div class={`font-semibold text-sm ${aggregate().totalErrors > 0 ? "text-error" : "text-base-content/30"}`}>{aggregate().totalErrors}</div></div>
          </div>
          <Show when={aggregate().samples > 0}>
            <div class="grid grid-cols-5 gap-1 text-detail text-center">
              <div><div class="text-base-content/40">min</div><div class="text-base-content/80 font-semibold">{formatLatency(aggregate().min)}</div></div>
              <div><div class="text-base-content/40">p50</div><div class="text-base-content/80 font-semibold">{formatLatency(aggregate().p50)}</div></div>
              <div><div class="text-base-content/40">p95</div><div class="text-warning font-semibold">{formatLatency(aggregate().p95)}</div></div>
              <div><div class="text-base-content/40">p99</div><div class="text-error font-semibold">{formatLatency(aggregate().p99)}</div></div>
              <div><div class="text-base-content/40">max</div><div class="text-error font-semibold">{formatLatency(aggregate().max)}</div></div>
            </div>
            <div class="text-tiny text-base-content/20 text-right">{aggregate().samples} samples</div>
          </Show>
        </div>

        {/* Worker comparison table */}
        <Show when={allStats().size > 1}>
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50 font-medium mb-2">Worker Comparison</div>
            <table class="table table-xs w-full">
              <thead>
                <tr class="text-base-content/40">
                  <th>Worker</th>
                  <th class="text-right">Requests</th>
                  <th class="text-right">Error %</th>
                  <th class="text-right">Avg</th>
                  <th class="text-right">p95</th>
                </tr>
              </thead>
              <tbody>
                <For each={Array.from({ length: workerCount() }, (_, i) => i)}>
                  {(i) => {
                    const st = () => allStats().get(i) || { requests: 0, errors: 0, errorRate: 0, avgLatency: 0, minLatency: 0, p50Latency: 0, p95Latency: 0, p99Latency: 0, maxLatency: 0, entries: [] };
                    return (
                      <tr
                        class={`cursor-pointer hover:bg-base-300/30 ${focusedWorker() === i ? "bg-base-300/20" : ""}`}
                        onClick={() => setFocusedWorker(focusedWorker() === i ? null : i)}
                      >
                        <td class="text-base-content/70">W{i}</td>
                        <td class="text-right text-base-content/80">{st().requests}</td>
                        <td class={`text-right ${st().errorRate > 0 ? "text-error" : "text-base-content/30"}`}>{st().errorRate.toFixed(1)}%</td>
                        <td class="text-right text-base-content/50">{formatLatency(st().avgLatency)}</td>
                        <td class="text-right text-warning">{formatLatency(st().p95Latency)}</td>
                      </tr>
                    );
                  }}
                </For>
              </tbody>
            </table>
          </div>
        </Show>
      </div>
    </div>
  );
}
