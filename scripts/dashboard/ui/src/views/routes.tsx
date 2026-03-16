// Routes — route table with filtering, inline probe, visual emphasis

import { createSignal, createMemo, For, Show, onMount } from "solid-js";
import { api, fetchEffectiveConfig } from "../api";
import { state, type Route, type TrafficEntry } from "../state";
import { MethodBadge, StatusBadge } from "../components/badge";
import { SectionHeader } from "../components/section-header";
import { formatLatency, formatTime } from "./format";

function MiddlewarePipeline(props: { middleware: string[]; handler: string }) {
  const nodes = () => {
    const list: { name: string; type: string }[] = [];
    const mw = Array.isArray(props.middleware) ? props.middleware : [];
    for (const m of mw) list.push({ name: m, type: "middleware" });
    list.push({ name: props.handler, type: "handler" });
    return list;
  };

  return (
    <div class="flex items-center gap-1 overflow-x-auto py-2">
      <For each={nodes()}>
        {(node, i) => {
          const isHandler = node.type === "handler";
          const borderCls = isHandler ? "border-primary/50 bg-primary/5" : "border-base-content/20 bg-base-300/30";
          const labelCls = isHandler ? "text-primary" : "text-base-content/60";
          const typeCls = isHandler ? "text-primary/40" : "text-base-content/30";
          return (
            <>
              <Show when={i() > 0}>
                <span class="text-base-content/20 text-xs shrink-0">→</span>
              </Show>
              <div class={`border rounded px-2 py-1 shrink-0 ${borderCls}`}>
                <div class={`text-detail font-mono ${labelCls}`}>{node.name}</div>
                <div class={`text-micro ${typeCls}`}>{node.type}</div>
              </div>
            </>
          );
        }}
      </For>
    </div>
  );
}

interface ProbeResult {
  status: number;
  headers: [string, string][];
  timing_ms: number;
  body_preview: string;
  error?: string;
}

type SortKey = "pattern" | "hits" | "errors" | "latency";
type RouteType = "all" | "user" | "internal" | "script" | "hook";

function classifyRouteType(r: Route): RouteType {
  if (r.type === "hook") return "hook";
  if (r.pattern.startsWith("/__keyway")) return "internal";
  if (r.handler && r.handler !== "keyway.lua") return "script";
  return "user";
}

export function Routes(props: { onNavigate: (path: string, ctx?: Record<string, unknown>) => void }) {
  const s = state();
  const [routes, setRoutes] = createSignal<Route[]>([]);
  const [filter, setFilter] = createSignal("");
  const [methodFilter, setMethodFilter] = createSignal("");
  const [typeFilter, setTypeFilter] = createSignal<RouteType>("all");
  const [errorFilter, setErrorFilter] = createSignal(false);
  const [sortKey, setSortKey] = createSignal<SortKey>("pattern");
  const [expandedIdx, setExpandedIdx] = createSignal<number | null>(null);
  const [effectiveOpen, setEffectiveOpen] = createSignal(false);
  const [effectiveConfig, setEffectiveConfig] = createSignal<string | null>(null);
  const [probeResults, setProbeResults] = createSignal<Record<number, string>>({});

  const maxHits = createMemo(() => {
    let max = 0;
    for (const r of routes()) if (r.hits > max) max = r.hits;
    return max;
  });

  const filtered = createMemo(() => {
    let list = routes();
    const f = filter();
    if (f) list = list.filter(r => r.pattern.includes(f));
    const mf = methodFilter();
    if (mf) list = list.filter(r => r.method === mf);
    const tf = typeFilter();
    if (tf !== "all") list = list.filter(r => classifyRouteType(r) === tf);
    if (errorFilter()) list = list.filter(r => r.errors > 0);

    const sk = sortKey();
    if (sk === "hits") list = [...list].sort((a, b) => b.hits - a.hits);
    else if (sk === "errors") list = [...list].sort((a, b) => b.errors - a.errors);
    else if (sk === "latency") list = [...list].sort((a, b) => (b.avg_latency_us || 0) - (a.avg_latency_us || 0));
    else list = [...list].sort((a, b) => a.pattern.localeCompare(b.pattern));

    return list;
  });

  const hasActiveFilter = () => !!(filter() || methodFilter() || typeFilter() !== "all" || errorFilter());

  const allZero = createMemo(() => {
    const r = routes();
    return r.length > 0 && r.every(r => r.hits === 0);
  });

  async function loadRoutes() {
    try {
      const data = await api<{ routes: Route[] }>("/__keyway/api/routes");
      setRoutes(data.routes || []);
    } catch {
      // handle error
    }
  }

  onMount(() => {
    loadRoutes();
    const ctxFilter = s.consumeNavContext("filter_pattern") as string | undefined;
    if (ctxFilter) setFilter(ctxFilter);
  });

  async function doProbe(idx: number, url: string, _method: string) {
    if (!url.trim()) return;
    setProbeResults(prev => ({ ...prev, [idx]: "loading" }));
    try {
      const r = await api<ProbeResult>("/__keyway/api/probe", {
        method: "POST",
        body: JSON.stringify({ url }),
      });
      if (r.error) {
        setProbeResults(prev => ({ ...prev, [idx]: `error:${r.error}` }));
        return;
      }
      setProbeResults(prev => ({ ...prev, [idx]: JSON.stringify(r) }));
    } catch {
      setProbeResults(prev => ({ ...prev, [idx]: "error:Probe failed" }));
    }
  }

  async function toggleEffective() {
    if (effectiveOpen()) {
      setEffectiveOpen(false);
      setEffectiveConfig(null);
      return;
    }
    setEffectiveOpen(true);
    setEffectiveConfig("loading");
    try {
      const config = await fetchEffectiveConfig();
      setEffectiveConfig(JSON.stringify(config, null, 2));
    } catch {
      setEffectiveConfig("error");
    }
  }

  function clearFilters() {
    setFilter("");
    setMethodFilter("");
    setTypeFilter("all");
    setErrorFilter(false);
    setSortKey("pattern");
    setExpandedIdx(null);
  }

  const typeBadge = (r: Route) => {
    const t = classifyRouteType(r);
    if (t === "internal") return <span class="badge badge-xs badge-ghost text-tiny">internal</span>;
    if (t === "script") return <span class="badge badge-xs badge-success text-tiny">script</span>;
    if (t === "hook") return <span class="badge badge-xs badge-secondary text-tiny">hook</span>;
    return null;
  };

  return (
    <div class="flex flex-col h-full">
      <SectionHeader title="Routes">
        <button
          class={`btn btn-xs btn-outline btn-primary text-detail ${effectiveOpen() ? "btn-active" : ""}`}
          onClick={toggleEffective}
        >
          View Config
        </button>
        <button class="btn btn-xs btn-ghost text-base-content/50" onClick={() => { setExpandedIdx(null); loadRoutes(); }}>
          Refresh
        </button>
      </SectionHeader>

      {/* Filter bar */}
      <div class="px-4 py-2 flex items-center gap-2 flex-wrap border-b border-base-300/50 bg-base-200/30">
        <input
          type="text"
          placeholder="Filter pattern..."
          class="input input-xs input-bordered bg-base-100 w-40 text-body"
          value={filter()}
          onInput={(e) => { setFilter(e.currentTarget.value); setExpandedIdx(null); }}
        />
        <select
          class="select select-xs select-bordered bg-base-100 text-body"
          value={methodFilter()}
          onChange={(e) => setMethodFilter(e.currentTarget.value)}
        >
          <option value="">Method</option>
          <option>GET</option><option>POST</option><option>PUT</option><option>DELETE</option><option>MW</option>
        </select>
        <select
          class="select select-xs select-bordered bg-base-100 text-body"
          value={typeFilter()}
          onChange={(e) => setTypeFilter(e.currentTarget.value as RouteType)}
        >
          <option value="all">Type</option>
          <option value="user">User</option>
          <option value="internal">Internal</option>
          <option value="script">Script</option>
          <option value="hook">Hook</option>
        </select>
        <label class="flex items-center gap-1 text-detail text-base-content/50 cursor-pointer">
          <input
            type="checkbox"
            class="checkbox checkbox-xs checkbox-error"
            checked={errorFilter()}
            onChange={(e) => setErrorFilter(e.currentTarget.checked)}
          />
          Has errors
        </label>
        <select
          class="select select-xs select-bordered bg-base-100 text-body"
          value={sortKey()}
          onChange={(e) => setSortKey(e.currentTarget.value as SortKey)}
        >
          <option value="pattern">Sort: pattern</option>
          <option value="hits">Sort: hits</option>
          <option value="errors">Sort: errors</option>
          <option value="latency">Sort: latency</option>
        </select>
        <Show when={hasActiveFilter()}>
          <button class="btn btn-xs btn-ghost text-base-content/40" onClick={clearFilters}>Clear</button>
        </Show>
        <span class="ml-auto text-detail text-base-content/40">{filtered().length} / {routes().length}</span>
      </div>

      <Show when={allZero() && !hasActiveFilter()}>
        <div class="px-4 py-1 text-detail text-base-content/50 bg-base-200/30 border-b border-base-300/50">
          Click any route to see middleware pipeline or send a test request
        </div>
      </Show>

      <Show when={effectiveOpen()}>
        <div class="border-b border-base-300 p-3">
          <div class="flex items-center justify-between mb-2">
            <span class="text-detail text-base-content/50 font-medium">EFFECTIVE ROUTE TABLE</span>
            <button class="btn btn-xs btn-ghost text-base-content/40" onClick={() => { setEffectiveOpen(false); setEffectiveConfig(null); }}>Close</button>
          </div>
          <Show when={effectiveConfig() === "loading"}>
            <div class="text-detail text-base-content/50">Loading...</div>
          </Show>
          <Show when={effectiveConfig() === "error"}>
            <div class="text-detail text-error">Failed to load effective config</div>
          </Show>
          <Show when={effectiveConfig() && effectiveConfig() !== "loading" && effectiveConfig() !== "error"}>
            <pre class="bg-base-300 rounded p-2 text-detail text-base-content/70 overflow-auto max-h-64 font-mono">{effectiveConfig()}</pre>
          </Show>
        </div>
      </Show>

      <div class="flex-1 overflow-y-auto">
        <Show when={filtered().length > 0} fallback={<div class="p-4 text-base-content/30 text-center">No routes</div>}>
          <table class="table table-xs table-pin-rows w-full">
            <thead>
              <tr>
                <th class="bg-base-200 w-4" />
                <th class="bg-base-200 text-base-content/50 w-[70px]">Method</th>
                <th class="bg-base-200 text-base-content/50">Pattern</th>
                <th class="bg-base-200 text-base-content/50 w-[120px]">Handler</th>
                <th class="bg-base-200 text-base-content/50 w-[90px] text-right">Hits</th>
                <th class="bg-base-200 text-base-content/50 w-[80px] text-right">Errors</th>
                <th class="bg-base-200 text-base-content/50 w-[80px] text-right">Latency</th>
                <th class="bg-base-200 text-base-content/50 w-[80px] text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <For each={filtered()}>
                {(r, i) => {
                  const expanded = () => expandedIdx() === i();
                  const mwBadges = () => {
                    const mw = Array.isArray(r.middleware) ? r.middleware : [];
                    return mw.length > 0
                      ? mw.map(m => <span class="badge badge-xs badge-ghost text-tiny">{m}</span>)
                      : null;
                  };
                  const hitsPct = () => maxHits() > 0 ? (r.hits / maxHits()) * 100 : 0;

                  return (
                    <>
                      <tr
                        class={`cursor-pointer hover:bg-base-300/30 ${expanded() ? "bg-base-300/20" : ""}`}
                        onClick={() => setExpandedIdx(expanded() ? null : i())}
                      >
                        <td class="text-base-content/30 text-detail">{expanded() ? "▾" : "▸"}</td>
                        <td>
                          <MethodBadge method={r.method} />
                          {typeBadge(r)}
                        </td>
                        <td>
                          <span class="text-base-content/80">{r.pattern}</span>
                          <Show when={mwBadges()}><div class="mt-0.5">{mwBadges()}</div></Show>
                        </td>
                        <td
                          class="text-primary/70 cursor-pointer hover:text-primary"
                          onClick={(e) => { e.stopPropagation(); props.onNavigate("/scripts", { navigate_to_script_name: r.handler }); }}
                        >
                          {r.handler}
                        </td>
                        <td class="text-right">
                          <Show when={r.hits > 0} fallback={<span class="text-base-content/30">0</span>}>
                            <div class="flex items-center gap-1 justify-end">
                              <div class="w-12 bg-base-300 rounded-full h-1">
                                <div class="bg-primary/50 h-1 rounded-full" style={{ width: `${hitsPct()}%` }} />
                              </div>
                              <span class="text-base-content/80">{r.hits}</span>
                            </div>
                          </Show>
                        </td>
                        <td class="text-right">
                          <Show when={r.errors > 0} fallback={<span class="text-base-content/30">0</span>}>
                            <span
                              class="text-error bg-error/10 px-1.5 py-0.5 rounded cursor-pointer hover:underline font-semibold"
                              onClick={(e) => { e.stopPropagation(); props.onNavigate("/traffic", { path_pattern: r.pattern, status_family: "5xx" }); }}
                            >
                              {r.errors}
                            </span>
                          </Show>
                        </td>
                        <td class={`text-right ${!r.avg_latency_us ? "text-base-content/30" : "text-base-content/50"}`}>{formatLatency(r.avg_latency_us)}</td>
                        <td class="text-right">
                          <button
                            class="btn btn-xs btn-ghost text-primary"
                            onClick={(e) => { e.stopPropagation(); setExpandedIdx(expanded() ? null : i()); }}
                          >
                            Test
                          </button>
                        </td>
                      </tr>
                      <Show when={expanded()}>
                        <ProbePanel route={r} idx={i()} onProbe={doProbe} result={probeResults()[i()]} traffic={s.traffic()} />
                      </Show>
                    </>
                  );
                }}
              </For>
            </tbody>
          </table>
        </Show>
      </div>
    </div>
  );
}

function ProbePanel(props: { route: Route; idx: number; onProbe: (idx: number, url: string, method: string) => void; result?: string; traffic: TrafficEntry[] }) {
  const defaultUrl = () => `${location.origin}${props.route.pattern.replace(/\{[^}]+\}/g, "test")}`;
  let urlInput!: HTMLInputElement;

  // Use the route's own method for probing — no separate dropdown
  const probeMethod = () => props.route.method === "MW" ? "GET" : props.route.method;

  const resultDisplay = createMemo(() => {
    const r = props.result;
    if (!r) return null;
    if (r === "loading") return { type: "loading" as const };
    if (r.startsWith("error:")) return { type: "error" as const, msg: r.slice(6) };
    try {
      return { type: "data" as const, data: JSON.parse(r) as ProbeResult };
    } catch {
      return null;
    }
  });

  // Recent errors for this route
  const recentErrors = createMemo(() => {
    const pattern = props.route.pattern;
    return props.traffic
      .filter(e => e.status >= 400 && e.path.includes(pattern.replace(/\{[^}]+\}/g, "")))
      .slice(0, 10);
  });

  return (
    <tr>
      <td colspan="8" class="bg-base-200/50 p-3">
        <div class="space-y-3">
          <div>
            <div class="text-tiny text-base-content/40 font-medium mb-1">MIDDLEWARE PIPELINE</div>
            <MiddlewarePipeline middleware={Array.isArray(props.route.middleware) ? props.route.middleware : []} handler={props.route.handler} />
          </div>
          <div class="border-t border-base-300/50 pt-2">
            <div class="text-tiny text-base-content/40 font-medium mb-1">PROBE ({probeMethod()})</div>
            <div class="flex gap-2">
              <input ref={urlInput} type="text" class="input input-xs input-bordered bg-base-100 flex-1 text-body" value={defaultUrl()} />
              <button class="btn btn-xs btn-primary" onClick={() => props.onProbe(props.idx, urlInput.value, probeMethod())}>Send</button>
            </div>
            <div class="text-detail mt-1">
              <Show when={resultDisplay()?.type === "loading"}>
                <span class="text-base-content/50">Probing...</span>
              </Show>
              <Show when={resultDisplay()?.type === "error"}>
                <span class="text-error">{(resultDisplay() as { type: "error"; msg: string }).msg}</span>
              </Show>
              <Show when={resultDisplay()?.type === "data"}>
                {(_) => {
                  const d = () => (resultDisplay() as { type: "data"; data: ProbeResult }).data;
                  const statusCls = () => d().status < 300 ? "text-success" : d().status < 400 ? "text-info" : d().status < 500 ? "text-warning" : "text-error";
                  return (
                    <>
                      <div class="flex items-center gap-3 mb-1">
                        <span class={`${statusCls()} font-bold`}>{d().status}</span>
                        <span class="text-base-content/50">{d().timing_ms}ms</span>
                      </div>
                      <Show when={d().headers.length > 0}>
                        <div class="space-y-0.5 mb-1">
                          <For each={d().headers.slice(0, 8)}>
                            {([n, v]) => <div><span class="text-base-content/50">{n}:</span> <span class="text-base-content/80">{v}</span></div>}
                          </For>
                        </div>
                      </Show>
                      <Show when={d().body_preview}>
                        <pre class="bg-base-100 p-1.5 rounded text-base-content/50 max-h-24 overflow-auto whitespace-pre-wrap">{d().body_preview}</pre>
                      </Show>
                    </>
                  );
                }}
              </Show>
            </div>
          </div>

          {/* Recent Errors for this route */}
          <Show when={recentErrors().length > 0}>
            <div class="border-t border-base-300/50 pt-2">
              <div class="text-tiny text-base-content/40 font-medium mb-1">RECENT ERRORS</div>
              <For each={recentErrors()}>
                {(e) => (
                  <div class="flex items-center gap-2 text-detail py-0.5">
                    <span class="text-base-content/50 w-[55px] shrink-0">{formatTime(e.ts)}</span>
                    <MethodBadge method={e.method} />
                    <span class="text-base-content/50 flex-1 truncate">{e.path}</span>
                    <StatusBadge status={e.status} />
                    <span class="text-base-content/50 w-[50px] text-right">{formatLatency(e.latency_us)}</span>
                    <Show when={e.error_message}>
                      <span class="text-error truncate max-w-[200px]" title={e.error_message}>{e.error_message}</span>
                    </Show>
                  </div>
                )}
              </For>
            </div>
          </Show>
        </div>
      </td>
    </tr>
  );
}
