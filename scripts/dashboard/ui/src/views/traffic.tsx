// Traffic view — live request stream with filtering

import { createSignal, createMemo, For, Show, onMount } from "solid-js";
import { state, type TrafficEntry, type TrafficFilters, type InvocationState, classifyInvocation, INVOCATION_LABELS, INVOCATION_COLORS } from "../state";
import { MethodBadge, StatusBadge } from "../components/badge";
import { formatLatency, formatTime } from "./format";

const METHODS = ["GET", "POST", "PUT", "PATCH", "DELETE"];
const STATUS_FAMILIES = ["2xx", "3xx", "4xx", "5xx"];
const STATES: InvocationState[] = ["success", "client_error", "client_disconnect", "script_error", "timeout", "resource_exceeded", "internal_error"];
const MAX_ROWS = 200;

function defaultFilters(): TrafficFilters {
  return { method: null, status_family: null, invocation_state: null, path_pattern: null, worker_id: null, paused: false };
}

function matchesFilter(entry: TrafficEntry, f: TrafficFilters): boolean {
  if (f.method && entry.method !== f.method) return false;
  if (f.status_family) {
    const fam = Math.floor(entry.status / 100) + "xx";
    if (fam !== f.status_family) return false;
  }
  if (f.invocation_state && classifyInvocation(entry) !== f.invocation_state) return false;
  if (f.path_pattern && !entry.path.includes(f.path_pattern)) return false;
  if (f.worker_id && entry.worker_id !== f.worker_id) return false;
  if (entry.path.startsWith("/__keyway/")) return false;
  return true;
}

function hasActiveFilter(f: TrafficFilters): boolean {
  return !!(f.method || f.status_family || f.invocation_state || f.path_pattern || f.worker_id);
}

function TrafficRow(props: { entry: TrafficEntry; idx: number; expanded: boolean; onToggle: () => void; onNavigate?: (path: string, ctx?: Record<string, unknown>) => void }) {
  const e = () => props.entry;
  const invState = () => classifyInvocation(e());
  const stateColor = () => INVOCATION_COLORS[invState()];

  return (
    <>
      <tr
        class="hover:bg-base-200 cursor-pointer border-b border-base-200/50 traffic-row row-enter"
        onClick={props.onToggle}
      >
        <td>
          <div class="flex items-center gap-1">
            <MethodBadge method={e().method} />
            <Show when={e().error_message}>
              <span class="inline-block w-1.5 h-1.5 rounded-full bg-error shrink-0" title={e().error_message} />
            </Show>
          </div>
        </td>
        <td class="truncate max-w-xs">{e().path}</td>
        <td class={`${stateColor()} text-detail max-sm:hidden`}>{INVOCATION_LABELS[invState()]}</td>
        <td class="text-right tabular-nums">{formatLatency(e().latency_us)}</td>
        <td class="text-right tabular-nums"><StatusBadge status={e().status} /></td>
        <td class="text-right text-base-content/50 max-md:hidden">{e().worker_id}</td>
        <td class="text-right text-base-content/40 text-detail max-md:hidden">{formatTime(e().ts)}</td>
      </tr>
      <Show when={props.expanded}>
        <tr>
          <td colspan="7" class="bg-base-200 p-3">
            <div class="grid grid-cols-2 gap-4 text-detail">
              <div>
                <div class="text-base-content/40 mb-1">Request Details</div>
                <div>
                  Path:{" "}
                  <span
                    class="text-primary cursor-pointer hover:underline"
                    onClick={(ev) => { ev.stopPropagation(); props.onNavigate?.("/routes", { filter_pattern: e().path }); }}
                  >
                    {e().path}
                  </span>
                </div>
                <div>Content-Type: <span class="text-base-content">{e().content_type}</span></div>
                <div>Headers: <span class="text-base-content">{e().header_count}</span></div>
                <Show when={e().scripts?.length}>
                  <div>Scripts:{" "}
                    <For each={e().scripts!}>
                      {(sc, i) => (
                        <>
                          <Show when={i() > 0}>, </Show>
                          <span
                            class="text-primary cursor-pointer hover:underline"
                            onClick={(ev) => { ev.stopPropagation(); props.onNavigate?.("/scripts", { navigate_to_script_name: sc.name }); }}
                          >
                            {sc.name}
                          </span>
                        </>
                      )}
                    </For>
                  </div>
                </Show>
                <Show when={e().hook_id}>
                  <div>Hook: <span class="text-secondary">{e().hook_id}</span></div>
                </Show>
              </div>
              <div>
                <div class="text-base-content/40 mb-1">Timing</div>
                <div>Latency: <span class="text-base-content">{formatLatency(e().latency_us)}</span></div>
                <div>Worker: <span class="text-base-content">{e().worker_id}</span></div>
                <Show when={e().error_message}>
                  <div class="mt-1">
                    <div class="text-error font-semibold">Error:</div>
                    <pre class="text-error whitespace-pre-wrap text-detail mt-0.5 bg-base-300 rounded p-1.5 max-h-32 overflow-auto">{e().error_message}</pre>
                  </div>
                </Show>
              </div>
            </div>
          </td>
        </tr>
      </Show>
    </>
  );
}

export function Traffic(props: { onNavigate?: (path: string, ctx?: Record<string, unknown>) => void }) {
  const s = state();
  const [filters, setFilters] = createSignal<TrafficFilters>(defaultFilters());
  const [expanded, setExpanded] = createSignal<number | null>(null);

  // Check for navigation context
  onMount(() => {
    const ctxState = s.consumeNavContext("traffic_filter_state") as string | undefined;
    if (ctxState) setFilters(f => ({ ...f, invocation_state: ctxState as InvocationState }));
    const ctxWorker = s.consumeNavContext("worker_id") as string | undefined;
    if (ctxWorker) setFilters(f => ({ ...f, worker_id: ctxWorker }));
    const ctxStatusFam = s.consumeNavContext("status_family") as string | undefined;
    if (ctxStatusFam) setFilters(f => ({ ...f, status_family: ctxStatusFam }));
    const ctxPath = s.consumeNavContext("path_pattern") as string | undefined;
    if (ctxPath) setFilters(f => ({ ...f, path_pattern: ctxPath }));
  });

  const traffic = () => filters().paused ? s.traffic() : s.traffic();
  const filtered = createMemo(() => {
    const f = filters();
    return traffic().filter(e => matchesFilter(e, f)).slice(0, MAX_ROWS);
  });

  const totalCount = () => s.traffic().length;
  const filteredCount = () => {
    const f = filters();
    return s.traffic().filter(e => matchesFilter(e, f)).length;
  };

  function clearFilters() {
    setFilters(defaultFilters());
  }

  function togglePause() {
    setFilters(f => ({ ...f, paused: !f.paused }));
  }

  return (
    <div class="p-4 h-full flex flex-col gap-3">
      <div class="flex items-center gap-2 flex-wrap">
        <h2 class="text-sm font-semibold text-base-content mr-2">Traffic</h2>
        <select
          class="select select-xs select-bordered"
          value={filters().method || ""}
          onChange={(e) => setFilters(f => ({ ...f, method: e.currentTarget.value || null }))}
        >
          <option value="">Method</option>
          <For each={METHODS}>{(m) => <option>{m}</option>}</For>
        </select>
        <select
          class="select select-xs select-bordered"
          value={filters().status_family || ""}
          onChange={(e) => setFilters(f => ({ ...f, status_family: e.currentTarget.value || null }))}
        >
          <option value="">Status</option>
          <For each={STATUS_FAMILIES}>{(s) => <option>{s}</option>}</For>
        </select>
        <select
          class="select select-xs select-bordered"
          value={filters().invocation_state || ""}
          onChange={(e) => setFilters(f => ({ ...f, invocation_state: (e.currentTarget.value as InvocationState) || null }))}
        >
          <option value="">State</option>
          <For each={STATES}>{(s) => <option value={s}>{INVOCATION_LABELS[s]}</option>}</For>
        </select>
        <input
          type="text"
          placeholder="path filter"
          class="input input-xs input-bordered w-32"
          value={filters().path_pattern || ""}
          onInput={(e) => setFilters(f => ({ ...f, path_pattern: e.currentTarget.value || null }))}
        />
        <input
          type="text"
          placeholder="worker"
          class="input input-xs input-bordered w-16"
          value={filters().worker_id || ""}
          onInput={(e) => setFilters(f => ({ ...f, worker_id: e.currentTarget.value || null }))}
        />
        <Show when={hasActiveFilter(filters())}>
          <button class="btn btn-xs btn-ghost text-base-content/40" onClick={clearFilters}>Clear</button>
        </Show>
        <button
          class={`btn btn-xs btn-outline ${filters().paused ? "btn-active" : ""}`}
          onClick={togglePause}
        >
          {filters().paused ? "Resume" : "Pause"}
        </button>
        <span class="ml-auto text-detail text-base-content/40">{filteredCount()} / {totalCount()}</span>
      </div>
      <div class="flex-1 overflow-auto" tabindex="0" role="grid" aria-label="Traffic entries">
        <table class="table table-xs table-pin-rows w-full">
          <thead>
            <tr class="text-base-content/40">
              <th class="w-16">Method</th>
              <th>Path</th>
              <th class="w-32 max-sm:hidden">State</th>
              <th class="w-20 text-right">Latency</th>
              <th class="w-16 text-right">Status</th>
              <th class="w-16 text-right max-md:hidden">Worker</th>
              <th class="w-20 text-right max-md:hidden">Time</th>
            </tr>
          </thead>
          <tbody>
            <For each={filtered()}>
              {(entry, i) => (
                <TrafficRow
                  entry={entry}
                  idx={i()}
                  expanded={expanded() === i()}
                  onToggle={() => setExpanded(prev => prev === i() ? null : i())}
                  onNavigate={props.onNavigate}
                />
              )}
            </For>
          </tbody>
        </table>
      </div>
    </div>
  );
}
