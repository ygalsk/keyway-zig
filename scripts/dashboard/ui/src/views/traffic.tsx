// Traffic view — live request stream with filtering

import { createSignal, createMemo, For, Show, onMount } from "solid-js";
import { state, type TrafficEntry, type TrafficFilters, type InvocationState, classifyInvocation, INVOCATION_LABELS, INVOCATION_COLORS } from "../state";
import { MethodBadge, StatusBadge } from "../components/badge";
import { FilterBar, type FilterConfig } from "../components/filter-bar";
import { formatLatency, formatTime } from "./format";
import { getHashParams } from "../router";

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
            <span class="text-base-content/35 text-detail">{props.expanded ? "▾" : "▸"}</span>
            <MethodBadge method={e().method} />
            <Show when={e().error_message}>
              <span class="inline-block w-1.5 h-1.5 rounded-full bg-error shrink-0" title={e().error_message} />
            </Show>
          </div>
        </td>
        <td class="truncate max-w-xs max-sm:max-w-[120px]">{e().path}</td>
        <td class={`${stateColor()} text-detail`}>{INVOCATION_LABELS[invState()]}</td>
        <td class="text-right tabular-nums max-sm:hidden">{formatLatency(e().latency_us)}</td>
        <td class="text-right tabular-nums"><StatusBadge status={e().status} /></td>
        <td class="text-right text-base-content/50 max-md:hidden">{e().worker_id}</td>
        <td class="text-right text-base-content/50 text-detail max-md:hidden">{formatTime(e().ts)}</td>
      </tr>
      <Show when={props.expanded}>
        <tr>
          <td colspan="7" class="bg-base-200 p-3">
            <div class="grid grid-cols-2 gap-4 text-detail">
              <div>
                <div class="text-base-content/50 mb-1">Request Details</div>
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
                <div class="text-base-content/50 mb-1">Timing</div>
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
  const [pausedSnapshot, setPausedSnapshot] = createSignal<TrafficEntry[]>([]);

  // Read filters from URL query params
  onMount(() => {
    const params = getHashParams();
    const f = defaultFilters();
    const st = params.get("traffic_filter_state");
    if (st) f.invocation_state = st as InvocationState;
    const wk = params.get("worker_id");
    if (wk) f.worker_id = wk;
    const sf = params.get("status_family");
    if (sf) f.status_family = sf;
    const pp = params.get("path_pattern");
    if (pp) f.path_pattern = pp;
    if (st || wk || sf || pp) setFilters(f);
  });

  const traffic = () => filters().paused ? pausedSnapshot() : s.traffic();
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
    const wasPaused = filters().paused;
    if (!wasPaused) {
      setPausedSnapshot(s.traffic());
    }
    setFilters(f => ({ ...f, paused: !f.paused }));
  }

  const filterConfigs = (): FilterConfig[] => [
    {
      id: "method", type: "select", placeholder: "Method",
      options: METHODS.map(m => ({ value: m, label: m })),
      value: filters().method || "",
      onChange: (v) => setFilters(f => ({ ...f, method: v || null })),
    },
    {
      id: "status", type: "select", placeholder: "Status",
      options: STATUS_FAMILIES.map(s => ({ value: s, label: s })),
      value: filters().status_family || "",
      onChange: (v) => setFilters(f => ({ ...f, status_family: v || null })),
    },
    {
      id: "state", type: "select", placeholder: "State",
      options: STATES.map(s => ({ value: s, label: INVOCATION_LABELS[s] })),
      value: filters().invocation_state || "",
      onChange: (v) => setFilters(f => ({ ...f, invocation_state: (v as InvocationState) || null })),
    },
    {
      id: "path", type: "text", placeholder: "path filter", width: "w-32",
      value: filters().path_pattern || "",
      onChange: (v) => setFilters(f => ({ ...f, path_pattern: v || null })),
    },
    {
      id: "worker", type: "text", placeholder: "worker", width: "w-16",
      value: filters().worker_id || "",
      onChange: (v) => setFilters(f => ({ ...f, worker_id: v || null })),
    },
  ];

  return (
    <div class="p-4 h-full flex flex-col gap-3">
      <div class="flex items-center gap-2 flex-wrap">
        <h2 class="text-sm font-semibold text-base-content mr-2">Traffic</h2>
        <FilterBar filters={filterConfigs()}>
          <Show when={hasActiveFilter(filters())}>
            <button class="btn btn-xs btn-ghost text-base-content/50" onClick={clearFilters}>Clear</button>
          </Show>
          <button
            class={`btn btn-xs btn-outline ${filters().paused ? "btn-active" : ""}`}
            onClick={togglePause}
          >
            {filters().paused ? "Resume" : "Pause"}
          </button>
          <span class="ml-auto text-detail text-base-content/50">{filteredCount()} / {totalCount()}</span>
        </FilterBar>
      </div>
      <div class="flex-1 overflow-auto" tabindex="0" role="grid" aria-label="Traffic entries">
        <table class="table table-xs table-pin-rows w-full">
          <thead>
            <tr class="text-base-content/50">
              <th class="w-20">Method</th>
              <th>Path</th>
              <th class="w-32">State</th>
              <th class="w-20 text-right max-sm:hidden">Latency</th>
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
