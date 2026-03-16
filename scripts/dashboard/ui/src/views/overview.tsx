// Overview — RED metrics, active stats panel, status distribution

import { createMemo, createEffect, For, Show } from "solid-js";
import { state, type TrafficEntry, type Metrics, type MetricSnapshot, type ActiveStat, classifyInvocation, INVOCATION_LABELS, INVOCATION_COLORS, type InvocationState } from "../state";
import { Sparkline } from "../components/sparkline";
import { SectionHeader } from "../components/section-header";
import { colors } from "../theme";
import { formatLatency } from "./format";

function computeActiveStats(history: MetricSnapshot[]): ActiveStat[] {
  if (history.length < 2) return [];
  const latest = history[history.length - 1];
  const prev = history[history.length - 2];
  const dt = (latest.ts - prev.ts) / 1000;
  if (dt <= 0) return [];

  const stats: ActiveStat[] = [];
  const pairs: [string, number, number][] = [
    ["total_requests", latest.requests, prev.requests],
    ["total_errors", latest.errors, prev.errors],
    ["active_connections", latest.connections, prev.connections],
    ["avg_latency_us", latest.avg_latency_us, prev.avg_latency_us],
  ];

  for (const [key, curr, old] of pairs) {
    const delta = curr - old;
    const rate = Math.abs(delta) / dt;
    stats.push({ key, value: curr, delta, rate });
  }
  stats.sort((a, b) => b.rate - a.rate);
  return stats;
}

function arrowColor(key: string, delta: number): string {
  if (delta === 0) return "text-base-content/20";
  if (key.includes("error")) return delta > 0 ? "text-error" : "text-success";
  if (key.includes("latency")) return delta > 0 ? "text-warning" : "text-success";
  if (key.includes("connections")) return delta > 0 ? "text-info" : "text-base-content/40";
  return delta > 0 ? "text-success" : "text-base-content/40";
}

function formatStatValue(key: string, value: number): string {
  if (key.includes("latency")) return formatLatency(value);
  if (value >= 1000000) return (value / 1000000).toFixed(1) + "M";
  if (value >= 1000) return (value / 1000).toFixed(1) + "k";
  return String(Math.round(value));
}

export function Overview(props: { onNavigate: (path: string, ctx?: Record<string, unknown>) => void; onOpenConsole?: (cmd?: string) => void }) {
  const s = state();

  const history = () => s.metricHistory();
  const m = () => s.metrics();

  const rps = createMemo(() => {
    const h = history();
    if (h.length < 2) return 0;
    const last = h[h.length - 1];
    const prev = h[h.length - 2];
    const dt = (last.ts - prev.ts) / 1000;
    return dt > 0 ? Math.max(0, Math.round((last.requests - prev.requests) / dt)) : 0;
  });

  const errorPct = createMemo(() => {
    const met = m();
    if (!met || met.total_requests === 0) return 0;
    return (met.total_errors / met.total_requests) * 100;
  });

  const rpsData = createMemo(() => {
    const h = history();
    if (h.length < 2) return [];
    const data: number[] = [];
    for (let i = 1; i < h.length; i++) {
      const dt = (h[i].ts - h[i - 1].ts) / 1000;
      data.push(dt > 0 ? (h[i].requests - h[i - 1].requests) / dt : 0);
    }
    return data;
  });

  const activeStats = createMemo(() => computeActiveStats(history()));

  // Single-pass traffic analysis
  const trafficAnalysis = createMemo(() => {
    const traffic = s.traffic();
    const taxonomy: Record<InvocationState, number> = {
      success: 0, client_error: 0, client_disconnect: 0, script_error: 0,
      timeout: 0, resource_exceeded: 0, internal_error: 0,
    };
    const workerCounts: Record<number, number> = {};
    const latencies: number[] = [];

    for (const e of traffic) {
      if (e.path.startsWith("/__keyway/") || e.path === "/health") continue;
      taxonomy[classifyInvocation(e)]++;
      const w = Number(e.worker_id);
      workerCounts[w] = (workerCounts[w] || 0) + 1;
      if (e.latency_us > 0) latencies.push(e.latency_us);
    }
    latencies.sort((a, b) => a - b);
    return { taxonomy, workerCounts, latencies };
  });

  const taxonomyEntries = createMemo(() => {
    const { taxonomy } = trafficAnalysis();
    const total = Object.values(taxonomy).reduce((a, b) => a + b, 0);
    if (total === 0) return [];
    return (Object.entries(taxonomy) as [InvocationState, number][])
      .filter(([, c]) => c > 0)
      .sort((a, b) => b[1] - a[1])
      .map(([st, count]) => ({ state: st, count, pct: ((count / total) * 100).toFixed(0), total }));
  });

  const workerCount = () => m()?.worker_count || 1;
  const totalWorkerTraffic = createMemo(() => {
    const wc = trafficAnalysis().workerCounts;
    return Object.values(wc).reduce((a, b) => a + b, 0) || 1;
  });

  const percentiles = createMemo(() => {
    const lat = trafficAnalysis().latencies;
    if (!lat.length) return null;
    const p = (pct: number) => lat[Math.floor(lat.length * pct)] || 0;
    return [
      { label: "min", value: lat[0], cls: "text-base-content/80" },
      { label: "p50", value: p(0.5), cls: "text-base-content/80" },
      { label: "p95", value: p(0.95), cls: "text-warning" },
      { label: "p99", value: p(0.99), cls: "text-error" },
      { label: "max", value: lat[lat.length - 1], cls: "text-error" },
    ];
  });

  const errCls = createMemo(() => {
    const ep = errorPct();
    if (ep > 5) return "text-error";
    if (ep >= 1) return "text-warning";
    if (ep === 0) return "text-success/70";
    return "text-base-content/50";
  });

  return (
    <div>
      <SectionHeader title="Overview" />
      <div class="p-4 h-full overflow-y-auto space-y-4">
        {/* RED Health Cards */}
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50">Requests/sec</div>
            <div class="text-lg font-semibold text-base-content mt-0.5">{rps()}</div>
            <div class="mt-1" aria-label="Requests per second sparkline">
              <Sparkline data={rpsData()} color={colors.accent} />
            </div>
          </div>
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50">Error rate</div>
            <div class={`text-lg font-semibold mt-0.5 ${errCls()}`}>{errorPct().toFixed(1)}%</div>
            <div class="mt-1" aria-label="Error rate sparkline">
              <Sparkline data={history().map(h => h.errors)} color={colors.red} />
            </div>
          </div>
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50">P50 Latency</div>
            <div class="text-lg font-semibold text-warning mt-0.5">{formatLatency(m()?.latency?.avg_us || 0)}</div>
            <div class="mt-1" aria-label="Latency sparkline">
              <Sparkline data={history().map(h => h.avg_latency_us)} color={colors.yellow} />
            </div>
          </div>
          <div class="bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50">Active Connections</div>
            <div class="text-lg font-semibold text-info mt-0.5">{m()?.active_connections || 0}</div>
            <div class="mt-1" aria-label="Connections sparkline">
              <Sparkline data={history().map(h => h.connections)} color={colors.blue} />
            </div>
          </div>
        </div>

        {/* Middle row: Trending Metrics + Request Outcomes */}
        <div class="grid grid-cols-1 lg:grid-cols-5 gap-3">
          <div class="lg:col-span-3 bg-base-200 rounded p-3">
            <div class="flex items-center gap-2 mb-2">
              <div class="text-detail text-base-content/50 font-medium">Trending Metrics</div>
              <div class="text-tiny text-base-content/30">sorted by change rate</div>
            </div>
            <div class="space-y-1">
              <Show when={activeStats().length > 0} fallback={<div class="text-detail text-base-content/30">Waiting for data...</div>}>
                <For each={activeStats()}>
                  {(stat) => {
                    const arrow = () => stat.delta > 0 ? "↑" : stat.delta < 0 ? "↓" : "–";
                    const barWidth = () => activeStats()[0].rate > 0 ? Math.max(4, (stat.rate / activeStats()[0].rate) * 100) : 0;
                    return (
                      <div class="flex items-center gap-2 text-detail">
                        <span class="w-28 text-base-content/50 truncate">{stat.key.replace(/_/g, " ")}</span>
                        <span class="w-16 text-right font-mono text-base-content/80">{formatStatValue(stat.key, stat.value)}</span>
                        <span class={`${arrowColor(stat.key, stat.delta)} w-4 text-center`}>{arrow()}</span>
                        <div class="flex-1 bg-base-300 rounded-full h-1">
                          <div
                            class="bg-primary/60 h-1 rounded-full transition-all"
                            style={{ width: `${barWidth()}%` }}
                            role="progressbar"
                            aria-valuenow={Math.round(barWidth())}
                            aria-valuemin="0"
                            aria-valuemax="100"
                          />
                        </div>
                        <span class="w-12 text-right text-base-content/30 font-mono">{stat.rate.toFixed(1)}/s</span>
                      </div>
                    );
                  }}
                </For>
              </Show>
            </div>
          </div>

          <div class="lg:col-span-2 bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50 font-medium mb-2">Request Outcomes</div>
            <div class="space-y-1">
              <Show when={taxonomyEntries().length > 0} fallback={<div class="text-detail text-base-content/30">No traffic yet</div>}>
                <For each={taxonomyEntries()}>
                  {(entry) => (
                    <div
                      class={`flex items-center gap-2 text-detail cursor-pointer hover:bg-base-300/50 rounded px-1 -mx-1 ${entry.state === "internal_error" && entry.count > 0 ? "flash-error" : ""}`}
                      onClick={() => props.onNavigate("/traffic", { traffic_filter_state: entry.state })}
                    >
                      <span class={`${INVOCATION_COLORS[entry.state]} w-24 truncate`}>{INVOCATION_LABELS[entry.state]}</span>
                      <div class="flex-1 bg-base-300 rounded-full h-1.5">
                        <div class={`bg-current ${INVOCATION_COLORS[entry.state]} h-1.5 rounded-full`} style={{ width: `${entry.pct}%` }} />
                      </div>
                      <span class="text-base-content/50 w-14 text-right">{entry.count} ({entry.pct}%)</span>
                    </div>
                  )}
                </For>
              </Show>
            </div>
          </div>
        </div>

        {/* Bottom row: Worker Load Balance + Latency Percentiles */}
        <div class="grid grid-cols-1 lg:grid-cols-5 gap-3">
          <div class="lg:col-span-3 bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50 font-medium mb-2">Worker Distribution</div>
            <div class="space-y-1">
              <For each={Array.from({ length: workerCount() }, (_, i) => i)}>
                {(i) => {
                  const count = () => trafficAnalysis().workerCounts[i] || 0;
                  const pct = () => ((count() / totalWorkerTraffic()) * 100).toFixed(0);
                  return (
                    <div
                      class="flex items-center gap-2 text-detail cursor-pointer hover:bg-base-300/50 rounded px-1 -mx-1"
                      onClick={() => props.onNavigate("/workers", { focus_worker: i })}
                    >
                      <span class="text-base-content/50 w-8">W{i}</span>
                      <div class="flex-1 bg-base-300 rounded-full h-1.5">
                        <div class="bg-primary/60 h-1.5 rounded-full" style={{ width: `${pct()}%` }} />
                      </div>
                      <span class="text-base-content/50 w-14 text-right">{count()} ({pct()}%)</span>
                    </div>
                  );
                }}
              </For>
            </div>
          </div>

          <div class="lg:col-span-2 bg-base-200 rounded p-3">
            <div class="text-detail text-base-content/50 font-medium mb-2">Latency Percentiles</div>
            <Show when={percentiles()} fallback={<div class="text-detail text-base-content/30">No latency data</div>}>
              {(p) => (
                <>
                  <div class="grid grid-cols-5 gap-1 text-center text-detail">
                    <For each={p()}>
                      {(v) => (
                        <div>
                          <div class="text-base-content/40">{v.label}</div>
                          <div class={`${v.cls} font-semibold`}>{formatLatency(v.value)}</div>
                        </div>
                      )}
                    </For>
                  </div>
                  <div class="text-tiny text-base-content/20 text-right mt-1">{trafficAnalysis().latencies.length} samples</div>
                </>
              )}
            </Show>
          </div>
        </div>
        {/* Quick Actions */}
        <div class="bg-base-200 rounded p-3">
          <div class="text-detail text-base-content/50 font-medium mb-2">Quick Actions</div>
          <div class="flex flex-wrap gap-2">
            {[
              { cmd: "probe", label: "Probe", desc: "HTTP test request" },
              { cmd: "dns", label: "DNS", desc: "DNS resolution" },
              { cmd: "scripts", label: "Scripts", desc: "List Lua scripts" },
              { cmd: "config", label: "Config", desc: "Effective config" },
            ].map(action => (
              <button
                class="btn btn-xs btn-outline btn-primary"
                title={action.desc}
                onClick={() => props.onOpenConsole?.(action.cmd)}
              >
                {action.label}
              </button>
            ))}
          </div>
          <div class="text-tiny text-base-content/30 mt-1">Opens console with command pre-filled</div>
        </div>
      </div>
    </div>
  );
}
