// Routes — route table with filtering, inline probe, visual emphasis

import { createSignal, createMemo, For, Show, onMount } from "solid-js";
import { api, fetchEffectiveConfig } from "../api";
import { state, type Route, type TrafficEntry } from "../state";
import { MethodBadge, StatusBadge } from "../components/badge";
import { SectionHeader } from "../components/section-header";
import { Card } from "../components/card";
import { FilterBar, type FilterConfig } from "../components/filter-bar";
import { LoadingState, ErrorState } from "../components/feedback";
import { formatLatency, formatTime } from "./format";
import { getHashParams } from "../router";

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
          const typeCls = isHandler ? "text-primary/40" : "text-base-content/35";
          return (
            <>
              <Show when={i() > 0}>
                <span class="text-base-content/35 text-xs shrink-0">→</span>
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

type RouteType = "all" | "user" | "internal" | "script" | "hook";

function classifyRouteType(r: Route): RouteType {
  if (r.type === "hook") return "hook";
  if (r.pattern.startsWith("/__keyway")) return "internal";
  if (r.handler && r.handler !== "keyway.lua") return "script";
  return "user";
}

export function Routes(props: { onNavigate: (path: string, ctx?: Record<string, unknown>) => void }) {
  const s = state();
  const [routes, setRoutes] = createSignal<Route[] | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [filter, setFilter] = createSignal("");
  const [methodFilter, setMethodFilter] = createSignal("");
  const [typeFilter, setTypeFilter] = createSignal<RouteType>("all");
  const [expandedIdx, setExpandedIdx] = createSignal<number | null>(null);
  const [effectiveOpen, setEffectiveOpen] = createSignal(false);
  const [effectiveConfig, setEffectiveConfig] = createSignal<string | null>(null);
  const [probeResults, setProbeResults] = createSignal<Record<number, string>>({});

  const filtered = createMemo(() => {
    let list = routes() || [];
    const f = filter();
    if (f) list = list.filter(r => r.pattern.includes(f));
    const mf = methodFilter();
    if (mf) list = list.filter(r => r.method === mf);
    const tf = typeFilter();
    if (tf !== "all") list = list.filter(r => classifyRouteType(r) === tf);

    list = [...list].sort((a, b) => a.pattern.localeCompare(b.pattern));
    return list;
  });

  const hasActiveFilter = () => !!(filter() || methodFilter() || typeFilter() !== "all");

  async function loadRoutes() {
    setError(null);
    try {
      const data = await api<{ routes: Route[] }>("/__keyway/api/routes");
      setRoutes(data.routes || []);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  onMount(() => {
    loadRoutes();
    const params = getHashParams();
    const ctxFilter = params.get("filter_pattern");
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
    setExpandedIdx(null);
  }

  const typeBadge = (r: Route) => {
    const t = classifyRouteType(r);
    if (t === "internal") return <span class="badge badge-xs badge-ghost text-tiny">internal</span>;
    if (t === "script") return <span class="badge badge-xs badge-success text-tiny">script</span>;
    if (t === "hook") return <span class="badge badge-xs badge-secondary text-tiny">hook</span>;
    return null;
  };

  const filterConfigs = (): FilterConfig[] => [
    {
      id: "pattern", type: "text", placeholder: "Filter pattern...", width: "w-40",
      value: filter(),
      onChange: (v) => { setFilter(v); setExpandedIdx(null); },
    },
    {
      id: "method", type: "select", placeholder: "Method",
      options: [
        { value: "GET", label: "GET" }, { value: "POST", label: "POST" },
        { value: "PUT", label: "PUT" }, { value: "DELETE", label: "DELETE" },
        { value: "MW", label: "MW" },
      ],
      value: methodFilter(),
      onChange: (v) => setMethodFilter(v),
    },
    {
      id: "type", type: "select", placeholder: "Type",
      options: [
        { value: "all", label: "All" }, { value: "user", label: "User" },
        { value: "internal", label: "Internal" }, { value: "script", label: "Script" },
        { value: "hook", label: "Hook" },
      ],
      value: typeFilter(),
      onChange: (v) => setTypeFilter(v as RouteType),
    },
  ];

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
      <div class="px-4 py-2 border-b border-base-300/50 bg-base-200/30">
        <FilterBar filters={filterConfigs()}>
          <Show when={hasActiveFilter()}>
            <button class="btn btn-xs btn-ghost text-base-content/50" onClick={clearFilters}>Clear</button>
          </Show>
          <span class="ml-auto text-detail text-base-content/50">{filtered().length} / {(routes() || []).length}</span>
        </FilterBar>
      </div>

      <Show when={effectiveOpen()}>
        <div class="border-b border-base-300 p-3">
          <Card>
            <div class="flex items-center justify-between mb-2">
              <span class="text-detail text-base-content/50 font-medium">EFFECTIVE ROUTE TABLE</span>
              <button class="btn btn-xs btn-ghost text-base-content/50" onClick={() => { setEffectiveOpen(false); setEffectiveConfig(null); }}>Close</button>
            </div>
            <Show when={effectiveConfig() === "loading"}>
              <LoadingState rows={4} />
            </Show>
            <Show when={effectiveConfig() === "error"}>
              <div class="text-detail text-error">Failed to load effective config</div>
            </Show>
            <Show when={effectiveConfig() && effectiveConfig() !== "loading" && effectiveConfig() !== "error"}>
              <pre class="bg-base-300 rounded p-2 text-detail text-base-content/70 overflow-auto max-h-64 font-mono">{effectiveConfig()}</pre>
            </Show>
          </Card>
        </div>
      </Show>

      <div class="flex-1 overflow-y-auto">
        {/* Loading state */}
        <Show when={routes() === null && !error()}>
          <LoadingState rows={6} />
        </Show>

        {/* Error state */}
        <Show when={error()}>
          {(errMsg) => <ErrorState message={errMsg()} onRetry={loadRoutes} />}
        </Show>

        {/* Data */}
        <Show when={routes() !== null && !error()}>
          <Show when={filtered().length > 0} fallback={<div class="p-4 text-base-content/45 text-center">No routes</div>}>
            <table class="table table-xs table-pin-rows w-full">
              <thead>
                <tr>
                  <th class="bg-base-200 w-4" />
                  <th class="bg-base-200 text-base-content/50 w-[70px]">Method</th>
                  <th class="bg-base-200 text-base-content/50">Pattern</th>
                  <th class="bg-base-200 text-base-content/50 w-[120px]">Handler</th>
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

                    return (
                      <>
                        <tr
                          class={`cursor-pointer hover:bg-base-300/30 ${expanded() ? "bg-base-300/20" : ""}`}
                          onClick={() => setExpandedIdx(expanded() ? null : i())}
                        >
                          <td class="text-base-content/35 text-detail">{expanded() ? "▾" : "▸"}</td>
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
        </Show>
      </div>
    </div>
  );
}

function ProbePanel(props: { route: Route; idx: number; onProbe: (idx: number, url: string, method: string) => void; result?: string; traffic: TrafficEntry[] }) {
  const defaultUrl = () => `${location.origin}${props.route.pattern.replace(/\{[^}]+\}/g, "test")}`;
  let urlInput!: HTMLInputElement;

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

  const recentErrors = createMemo(() => {
    const pattern = props.route.pattern;
    return props.traffic
      .filter(e => e.status >= 400 && e.path.includes(pattern.replace(/\{[^}]+\}/g, "")))
      .slice(0, 10);
  });

  return (
    <tr>
      <td colspan="5" class="bg-base-200/50 p-3">
        <div class="space-y-3">
          <Card>
            <div class="text-tiny text-base-content/50 font-medium mb-1">MIDDLEWARE PIPELINE</div>
            <MiddlewarePipeline middleware={Array.isArray(props.route.middleware) ? props.route.middleware : []} handler={props.route.handler} />
          </Card>
          <Card>
            <div class="text-tiny text-base-content/50 font-medium mb-1">PROBE ({probeMethod()})</div>
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
          </Card>

          {/* Recent Errors for this route */}
          <Show when={recentErrors().length > 0}>
            <Card>
              <div class="text-tiny text-base-content/50 font-medium mb-1">RECENT ERRORS</div>
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
            </Card>
          </Show>
        </div>
      </td>
    </tr>
  );
}
