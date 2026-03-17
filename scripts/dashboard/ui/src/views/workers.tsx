// Workers — aggregate Prometheus stats + worker list

import { createMemo, For, Show, onMount } from "solid-js";
import { state } from "../state";
import { sendWS } from "../api";
import { SectionHeader } from "../components/section-header";
import { formatLatency } from "./format";
import { rate, gauge, histogramQuantile, scrapeCount } from "../prom";

export function Workers(props: { onNavigate?: (path: string, ctx?: Record<string, unknown>) => void }) {
  const s = state();

  onMount(() => {
    sendWS({ cmd: "info" });
  });

  // Touch traffic signal to trigger re-renders when SSE ticks
  const _ = () => s.traffic().length;

  const hasScrapes = createMemo(() => { _(); return scrapeCount() >= 2; });

  const totalRps = createMemo(() => { _(); return Math.round(rate("keyway_http_requests_total")); });
  const activeConns = createMemo(() => { _(); return gauge("keyway_connections_active"); });
  const activeCoroutines = createMemo(() => { _(); return gauge("keyway_lua_coroutines_active"); });
  const ringSubRate = createMemo(() => { _(); return Math.round(rate("keyway_ring_submissions_total")); });
  const ringCompRate = createMemo(() => { _(); return Math.round(rate("keyway_ring_completions_total")); });

  const p50 = createMemo(() => { _(); return histogramQuantile(0.50, "keyway_http_request_duration_seconds"); });
  const p95 = createMemo(() => { _(); return histogramQuantile(0.95, "keyway_http_request_duration_seconds"); });
  const p99 = createMemo(() => { _(); return histogramQuantile(0.99, "keyway_http_request_duration_seconds"); });

  const latencyUs = (seconds: number) => Math.round(seconds * 1_000_000);

  // Derive worker count from traffic entries
  const workerIds = createMemo(() => {
    const ids = new Set<string>();
    for (const e of s.traffic()) {
      if (e.worker_id && e.worker_id !== "-") ids.add(e.worker_id);
    }
    return Array.from(ids).sort((a, b) => Number(a) - Number(b));
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
        {/* Aggregate stats from Prometheus */}
        <div class="bg-base-200 rounded p-3 space-y-3">
          <div class="text-detail text-base-content/50 font-medium">Aggregate (Prometheus)</div>
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

        {/* Worker list */}
        <div class="bg-base-200 rounded p-3">
          <div class="text-detail text-base-content/50 font-medium mb-2">Workers (from traffic)</div>
          <Show when={workerIds().length > 0} fallback={<div class="text-detail text-base-content/45">No traffic yet — worker IDs appear when requests arrive</div>}>
            <div class="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
              <For each={workerIds()}>
                {(wid) => {
                  const count = createMemo(() => s.traffic().filter(e => e.worker_id === wid).length);
                  return (
                    <div class="bg-base-300/30 rounded p-3 border-l-2 border-base-content/20">
                      <div class="text-sm font-semibold text-base-content/80 mb-1">Worker {wid}</div>
                      <div class="text-detail text-base-content/50">{count()} requests in buffer</div>
                    </div>
                  );
                }}
              </For>
            </div>
          </Show>
          <div class="text-tiny text-base-content/35 mt-2">Per-worker Prometheus metrics require worker labels in prom.zig</div>
        </div>
      </div>
    </div>
  );
}
