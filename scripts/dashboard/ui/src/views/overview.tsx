// Overview — RED metrics from Prometheus, operation counters, quick actions

import { createSignal, createMemo, For, Show, onMount } from "solid-js";
import { state, classifyInvocation, INVOCATION_LABELS, INVOCATION_COLORS, type InvocationState } from "../state";
import { Sparkline } from "../components/sparkline";
import { SectionHeader } from "../components/section-header";
import { Card } from "../components/card";
import { colors } from "../theme";
import { formatLatency, formatTime } from "./format";
import { fetchCounters } from "../api";
import { rate, rateHistory, gauge, gaugeHistory, histogramQuantile, scrapeCount } from "../prom";

// ─── Collapsible section with localStorage persistence ──

function CollapsibleSection(props: { id: string; title: string; children: any }) {
  const storageKey = () => `kw-collapse-${props.id}`;
  const [open, setOpen] = createSignal(localStorage.getItem(storageKey()) !== "closed");

  function toggle() {
    const next = !open();
    setOpen(next);
    localStorage.setItem(storageKey(), next ? "open" : "closed");
  }

  return (
    <div>
      <button
        class="flex items-center gap-1.5 text-detail text-base-content/50 font-medium mb-2 cursor-pointer hover:text-base-content/70 transition-colors"
        onClick={toggle}
      >
        <span class="text-base-content/35">{open() ? "▾" : "▸"}</span>
        {props.title}
      </button>
      <Show when={open()}>
        {props.children}
      </Show>
    </div>
  );
}

export function Overview(props: { onNavigate: (path: string, ctx?: Record<string, unknown>) => void; onOpenConsole?: (cmd?: string) => void }) {
  const s = state();
  const [counters, setCounters] = createSignal<Record<string, Record<string, number>> | null>(null);

  onMount(async () => {
    try {
      const data = await fetchCounters();
      setCounters(data);
    } catch { /* ignore */ }
  });

  // Prometheus-derived metrics (reactive via traffic signal as proxy for re-render)
  const _ = () => s.traffic().length; // touch to re-render on SSE events

  const rps = createMemo(() => {
    _();
    return Math.round(rate("keyway_http_requests_total"));
  });

  const errorRate = createMemo(() => {
    _();
    const totalRate = rate("keyway_http_requests_total");
    if (totalRate === 0) return 0;
    const errRate = rate("keyway_http_requests_total", (labels) => {
      const s = String(labels.status || "");
      return s.startsWith("5");
    });
    return (errRate / totalRate) * 100;
  });

  const p50 = createMemo(() => { _(); return histogramQuantile(0.50, "keyway_http_request_duration_seconds"); });
  const p95 = createMemo(() => { _(); return histogramQuantile(0.95, "keyway_http_request_duration_seconds"); });
  const p99 = createMemo(() => { _(); return histogramQuantile(0.99, "keyway_http_request_duration_seconds"); });

  const activeConns = createMemo(() => { _(); return gauge("keyway_connections_active"); });

  const rpsSparkline = createMemo(() => { _(); return rateHistory("keyway_http_requests_total"); });
  const connSparkline = createMemo(() => { _(); return gaugeHistory("keyway_connections_active"); });

  const errCls = createMemo(() => {
    const ep = errorRate();
    if (ep > 5) return "text-error";
    if (ep >= 1) return "text-warning";
    if (ep === 0) return "text-success/70";
    return "text-base-content/50";
  });

  // Latency in seconds → microseconds for formatLatency
  const latencyUs = (seconds: number) => Math.round(seconds * 1_000_000);

  // Traffic-based request outcomes (still from SSE buffer)
  const trafficAnalysis = createMemo(() => {
    const traffic = s.traffic();
    const taxonomy: Record<InvocationState, number> = {
      success: 0, client_error: 0, client_disconnect: 0, script_error: 0,
      timeout: 0, resource_exceeded: 0, internal_error: 0,
    };
    for (const e of traffic) {
      if (e.path.startsWith("/__keyway/") || e.path === "/health") continue;
      taxonomy[classifyInvocation(e)]++;
    }
    return taxonomy;
  });

  const taxonomyEntries = createMemo(() => {
    const taxonomy = trafficAnalysis();
    const total = Object.values(taxonomy).reduce((a, b) => a + b, 0);
    if (total === 0) return [];
    return (Object.entries(taxonomy) as [InvocationState, number][])
      .filter(([, c]) => c > 0)
      .sort((a, b) => b[1] - a[1])
      .map(([st, count]) => ({ state: st, count, pct: ((count / total) * 100).toFixed(0), total }));
  });

  const hasScrapes = createMemo(() => { _(); return scrapeCount() >= 2; });

  return (
    <div>
      <SectionHeader title="Overview" />
      <div class="p-4 h-full overflow-y-auto space-y-4">
        {/* RED Health Cards */}
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <Card>
            <div class="text-detail text-base-content/50">Requests/sec</div>
            <div class="text-lg font-semibold text-base-content mt-0.5">{rps()}</div>
            <div class="mt-1" aria-label="Requests per second sparkline">
              <Sparkline data={rpsSparkline()} color={colors.accent} />
            </div>
          </Card>
          <Card>
            <div class="text-detail text-base-content/50">Error rate</div>
            <div class={`text-lg font-semibold mt-0.5 ${errCls()}`}>{errorRate().toFixed(1)}%</div>
          </Card>
          <Card>
            <div class="text-detail text-base-content/50">Latency (p95)</div>
            <div class="text-lg font-semibold text-warning mt-0.5">{formatLatency(latencyUs(p95()))}</div>
          </Card>
          <Card>
            <div class="text-detail text-base-content/50">Active Connections</div>
            <div class="text-lg font-semibold text-info mt-0.5">{activeConns()}</div>
            <div class="mt-1" aria-label="Connections sparkline">
              <Sparkline data={connSparkline()} color={colors.blue} />
            </div>
          </Card>
        </div>

        {/* Temporal context */}
        <Show when={s.dataStartTime()}>
          {(startTime) => (
            <div class="text-tiny text-base-content/35 px-1">
              Since {formatTime(startTime())} · {s.traffic().length} requests in buffer
            </div>
          )}
        </Show>

        {/* Middle row: Latency Percentiles + Request Outcomes */}
        <div class="grid grid-cols-1 lg:grid-cols-5 gap-3">
          <div class="lg:col-span-3">
            <Card>
              <CollapsibleSection id="percentiles" title="Latency Percentiles">
                <Show when={hasScrapes()} fallback={<div class="text-detail text-base-content/45">Waiting for scrapes...</div>}>
                  <div class="grid grid-cols-3 gap-1 text-center text-detail">
                    <div>
                      <div class="text-base-content/50">p50</div>
                      <div class="text-base-content/80 font-semibold">{formatLatency(latencyUs(p50()))}</div>
                    </div>
                    <div>
                      <div class="text-base-content/50">p95</div>
                      <div class="text-warning font-semibold">{formatLatency(latencyUs(p95()))}</div>
                    </div>
                    <div>
                      <div class="text-base-content/50">p99</div>
                      <div class="text-error font-semibold">{formatLatency(latencyUs(p99()))}</div>
                    </div>
                  </div>
                </Show>
              </CollapsibleSection>
            </Card>
          </div>

          <div class="lg:col-span-2">
            <Card>
              <div class="text-detail text-base-content/50 font-medium mb-2">Request Outcomes</div>
              <div class="space-y-1">
                <Show when={taxonomyEntries().length > 0} fallback={<div class="text-detail text-base-content/45">No traffic yet</div>}>
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
            </Card>
          </div>
        </div>

        {/* Quick Actions */}
        <Card>
          <div class="text-detail text-base-content/50 font-medium mb-2">Quick Actions</div>
          <div class="flex flex-wrap gap-2">
            <For each={[
              { cmd: "probe", label: "Probe", desc: "HTTP test request" },
              { cmd: "dns", label: "DNS", desc: "DNS resolution" },
              { cmd: "scripts", label: "Scripts", desc: "List Lua scripts" },
              { cmd: "config", label: "Config", desc: "Effective config" },
            ]}>
              {(action) => (
                <button
                  class="btn btn-xs btn-outline btn-primary"
                  title={action.desc}
                  onClick={() => props.onOpenConsole?.(action.cmd)}
                >
                  {action.label}
                </button>
              )}
            </For>
          </div>
          <div class="text-tiny text-base-content/45 mt-1">Opens console with command pre-filled</div>
        </Card>

        {/* Counters */}
        <Show when={counters()}>
          {(c) => (
            <Card>
              <CollapsibleSection id="counters" title="Operation Counters">
                <div class="space-y-2">
                  <For each={Object.entries(c())}>
                    {([worker, ops]) => (
                      <div>
                        <div class="text-detail text-base-content/50 mb-1">Worker {worker}</div>
                        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-1">
                          <For each={Object.entries(ops)}>
                            {([key, val]) => (
                              <div class="text-detail flex justify-between gap-2">
                                <span class="text-base-content/50 truncate">{key.replace(/_/g, " ")}</span>
                                <span class="text-base-content/80 font-mono">{val}</span>
                              </div>
                            )}
                          </For>
                        </div>
                      </div>
                    )}
                  </For>
                </div>
              </CollapsibleSection>
            </Card>
          )}
        </Show>
      </div>
    </div>
  );
}
