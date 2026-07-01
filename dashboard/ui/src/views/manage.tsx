// Manage — RoutesView (path-segment tree), FilesView (file browser + editor)

import { createSignal, createMemo, For, Show, onMount, onCleanup } from "solid-js";
import {
  type TrafficEntry, type Route, type MiddlewareInfo,
  api, getHashParams,
} from "../main";
import { EditorView, basicSetup } from "codemirror";
import { EditorState } from "@codemirror/state";
import { StreamLanguage } from "@codemirror/language";
import { lua } from "@codemirror/legacy-modes/mode/lua";

// ─── CodeMirror dark theme ──────────────────────────────

const cmTheme = EditorView.theme({
  "&": { backgroundColor: "var(--kw-bg)", color: "var(--kw-text)", fontSize: "12px", height: "100%" },
  ".cm-content": { fontFamily: '"JetBrains Mono", monospace', caretColor: "var(--kw-accent)" },
  ".cm-gutters": { backgroundColor: "var(--kw-surface)", color: "rgba(200,204,200,0.3)", borderRight: "1px solid var(--kw-border)" },
  ".cm-activeLineGutter": { backgroundColor: "var(--kw-surface)" },
  ".cm-activeLine": { backgroundColor: "rgba(115,180,76,0.05)" },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": { backgroundColor: "rgba(115,180,76,0.15) !important" },
  ".cm-cursor": { borderLeftColor: "var(--kw-accent)" },
  ".cm-matchingBracket": { backgroundColor: "rgba(115,180,76,0.2)", outline: "none" },
}, { dark: true });

// ─── Route Tree Types ───────────────────────────────────

interface TreeNode {
  segment: string;
  fullPath: string;
  routes: Route[];
  children: TreeNode[];
}

function buildTree(routes: Route[]): TreeNode[] {
  const root: TreeNode = { segment: "", fullPath: "", routes: [], children: [] };

  for (const r of routes) {
    const segments = r.pattern.split("/").filter(Boolean);
    let node = root;
    let path = "";
    for (const seg of segments) {
      path += "/" + seg;
      let child = node.children.find(c => c.segment === seg);
      if (!child) {
        child = { segment: seg, fullPath: path, routes: [], children: [] };
        node.children.push(child);
      }
      node = child;
    }
    node.routes.push(r);
  }

  // Sort children alphabetically
  function sortTree(node: TreeNode) {
    node.children.sort((a, b) => a.segment.localeCompare(b.segment));
    for (const c of node.children) sortTree(c);
  }
  sortTree(root);

  return root.children;
}

function countRoutes(node: TreeNode): number {
  let count = node.routes.length;
  for (const c of node.children) count += countRoutes(c);
  return count;
}

function renderPattern(pattern: string): any[] {
  return pattern.split(/(\{[^}]+\})/).map(part =>
    part.startsWith("{") ? <span class="text-accent/80">{part}</span> : part
  );
}

const onKeyActivate = (fn: () => void) => (e: KeyboardEvent) => {
  if (e.key === "Enter" || e.key === " ") { e.preventDefault(); fn(); }
};

// ─── Traffic stats helpers ───────────────────────────────

interface RouteStats {
  hits: number;
  errors: number;
  lastHit: number | null;
}

function buildRouteStats(traffic: TrafficEntry[]): Map<string, RouteStats> {
  const stats = new Map<string, RouteStats>();
  for (const t of traffic) {
    if (t.path.startsWith("/__keyway/")) continue;
    const key = `${t.method} ${t.path}`;
    let s = stats.get(key);
    if (!s) { s = { hits: 0, errors: 0, lastHit: null }; stats.set(key, s); }
    s.hits++;
    if (t.status >= 400) s.errors++;
    if (s.lastHit === null || t.ts > s.lastHit) s.lastHit = t.ts;
  }
  return stats;
}

function matchRouteToStats(route: Route, stats: Map<string, RouteStats>): RouteStats {
  // Exact match first, then aggregate by pattern matching
  const agg: RouteStats = { hits: 0, errors: 0, lastHit: null };
  const patternRegex = routePatternToRegex(route.pattern);
  for (const [key, s] of stats) {
    const [method, ...pathParts] = key.split(" ");
    const path = pathParts.join(" ");
    if (route.method !== "*" && method !== route.method) continue;
    if (patternRegex.test(path)) {
      agg.hits += s.hits;
      agg.errors += s.errors;
      if (s.lastHit !== null && (agg.lastHit === null || s.lastHit > agg.lastHit)) agg.lastHit = s.lastHit;
    }
  }
  return agg;
}

const _regexCache = new Map<string, RegExp>();
function routePatternToRegex(pattern: string): RegExp {
  let cached = _regexCache.get(pattern);
  if (cached) return cached;
  const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, (m) => {
    if (m === "{" || m === "}") return m;
    return "\\" + m;
  });
  const withParams = escaped.replace(/\{[^}]+\}/g, "[^/]+");
  cached = new RegExp("^" + withParams + "$");
  _regexCache.set(pattern, cached);
  return cached;
}

function relativeTime(ts: number): string {
  const diff = Math.floor((Date.now() - ts) / 1000);
  if (diff < 2) return "just now";
  if (diff < 60) return diff + "s ago";
  if (diff < 3600) return Math.floor(diff / 60) + "m ago";
  return Math.floor(diff / 3600) + "h ago";
}

function statusDotClass(stats: RouteStats): string {
  if (stats.hits === 0) return "bg-base-content/20";
  if (stats.errors === 0) return "bg-success";
  const errorRate = stats.errors / stats.hits;
  if (errorRate < 0.1) return "bg-success";
  if (errorRate < 0.5) return "bg-warning";
  return "bg-error";
}

// ─── Filter highlighting ─────────────────────────────────

function highlightMatch(text: string, query: string): any {
  if (!query) return text;
  const lower = text.toLowerCase();
  const qLower = query.toLowerCase();
  const idx = lower.indexOf(qLower);
  if (idx === -1) return text;
  return <>
    {text.slice(0, idx)}
    <mark class="bg-primary/20 text-primary rounded px-0.5">{text.slice(idx, idx + query.length)}</mark>
    {text.slice(idx + query.length)}
  </>;
}

function renderPatternHighlighted(pattern: string, query: string): any[] {
  if (!query) return renderPattern(pattern);
  // Split into segments, highlight within each
  return pattern.split(/(\{[^}]+\})/).map(part =>
    part.startsWith("{")
      ? <span class="text-accent/80">{highlightMatch(part, query)}</span>
      : highlightMatch(part, query)
  );
}

// ─── RoutesView ─────────────────────────────────────────

interface GlobalMW { name: string; index: number; }

export function RoutesView(props: {
  traffic: () => TrafficEntry[];
  onNavigate: (path: string, ctx?: Record<string, unknown>) => void;
}) {
  const [routes, setRoutes] = createSignal<Route[] | null>(null);
  const [globalMw, setGlobalMw] = createSignal<GlobalMW[]>([]);
  const [availableMw, setAvailableMw] = createSignal<string[]>([]);
  const [error, setError] = createSignal<string | null>(null);
  const [filter, setFilter] = createSignal("");
  const [loading, setLoading] = createSignal(false);
  const [collapsed, setCollapsed] = createSignal<Set<string>>(new Set());
  const [mwPanelOpen, setMwPanelOpen] = createSignal(true);
  const [expandedRoutes, setExpandedRoutes] = createSignal<Set<string>>(new Set());
  const [pendingMw, setPendingMw] = createSignal<Map<string, string[]>>(new Map());
  const [saving, setSaving] = createSignal<string | null>(null);
  const [mwFeedback, setMwFeedback] = createSignal<{ key: string; msg: string; err: boolean } | null>(null);

  // Tick every 10s to refresh relative timestamps
  const [tick, setTick] = createSignal(0);
  const tickTimer = setInterval(() => setTick(t => t + 1), 10_000);
  onCleanup(() => clearInterval(tickTimer));

  const trafficStats = createMemo(() => buildRouteStats(props.traffic()));

  const filtered = createMemo(() => {
    let list = routes() || [];
    const f = filter();
    if (f) list = list.filter(r => r.pattern.toLowerCase().includes(f.toLowerCase()));
    return list;
  });

  const tree = createMemo(() => buildTree(filtered()));

  function toggleRouteExpand(key: string) {
    setExpandedRoutes(prev => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key); else next.add(key);
      return next;
    });
  }

  async function loadRoutes() {
    setError(null);
    setLoading(true);
    try {
      const d = await api<{ routes: Route[]; global_middleware: GlobalMW[]; available_middleware: string[] }>("/__keyway/api/routes");
      setRoutes(d.routes || []);
      setGlobalMw(d.global_middleware || []);
      setAvailableMw(d.available_middleware || []);
      setPendingMw(new Map());
    }
    catch (e) { setError((e as Error).message); }
    finally { setLoading(false); }
  }

  function getPendingOrCurrent(routeKey: string, currentMw: string[]): string[] {
    const pending = pendingMw().get(routeKey);
    return pending ?? currentMw;
  }

  function setPendingForRoute(routeKey: string, mw: string[]) {
    setPendingMw(prev => {
      const next = new Map(prev);
      next.set(routeKey, mw);
      return next;
    });
  }

  function cancelPending(routeKey: string) {
    setPendingMw(prev => {
      const next = new Map(prev);
      next.delete(routeKey);
      return next;
    });
  }

  function flashMw(key: string, msg: string, err: boolean) {
    setMwFeedback({ key, msg, err });
    setTimeout(() => setMwFeedback(null), 2500);
  }

  async function saveMw(pattern: string, routeKey: string, mwList: string[]) {
    setSaving(routeKey);
    try {
      const encodedPattern = encodeURIComponent(pattern.slice(1)); // strip leading /
      await api(`/__keyway/api/routes/${encodedPattern}/middleware`, {
        method: "PUT",
        body: JSON.stringify({ middleware: mwList }),
      });
      cancelPending(routeKey);
      flashMw(routeKey, "Saved", false);
      // Reload routes to reflect changes
      await loadRoutes();
    } catch (e) {
      flashMw(routeKey, (e as Error).message, true);
    } finally {
      setSaving(null);
    }
  }

  async function saveGlobalMw(mwList: string[]) {
    setSaving("__global");
    try {
      await api("/__keyway/api/middleware/global", {
        method: "PUT",
        body: JSON.stringify({ middleware: mwList }),
      });
      cancelPending("__global");
      flashMw("__global", "Saved", false);
      await loadRoutes();
    } catch (e) {
      flashMw("__global", (e as Error).message, true);
    } finally {
      setSaving(null);
    }
  }

  function toggleCollapse(path: string) {
    setCollapsed(prev => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path); else next.add(path);
      return next;
    });
  }

  onMount(async () => {
    await loadRoutes();
    const p = getHashParams();
    const ctxFilter = p.get("filter_pattern");
    if (ctxFilter) setFilter(ctxFilter);
  });

  // ─── Interactive Middleware Panel ──────────────────
  function MiddlewarePanel(mwProps: {
    items: string[];
    available: string[];
    onChange: (items: string[]) => void;
    label: string;
  }) {
    let dragIdx: number | null = null;
    let dropIdx: number | null = null;
    const [dragOver, setDragOver] = createSignal<number | null>(null);
    const [showAdd, setShowAdd] = createSignal(false);

    const unassigned = createMemo(() =>
      mwProps.available.filter(name => !mwProps.items.includes(name))
    );

    function onDragStart(e: DragEvent, idx: number) {
      dragIdx = idx;
      e.dataTransfer!.effectAllowed = "move";
      e.dataTransfer!.setData("text/plain", String(idx));
    }

    function onDragOverItem(e: DragEvent, idx: number) {
      e.preventDefault();
      e.dataTransfer!.dropEffect = "move";
      setDragOver(idx);
    }

    function onDrop(e: DragEvent, idx: number) {
      e.preventDefault();
      dropIdx = idx;
      setDragOver(null);
      if (dragIdx !== null && dropIdx !== null && dragIdx !== dropIdx) {
        const next = [...mwProps.items];
        const [moved] = next.splice(dragIdx, 1);
        next.splice(dropIdx, 0, moved);
        mwProps.onChange(next);
      }
      dragIdx = null;
      dropIdx = null;
    }

    function onDragEnd() { setDragOver(null); dragIdx = null; }

    function remove(idx: number) {
      const next = [...mwProps.items];
      next.splice(idx, 1);
      mwProps.onChange(next);
    }

    function addMw(name: string) {
      mwProps.onChange([...mwProps.items, name]);
      setShowAdd(false);
    }

    return (
      <div class="flex flex-col gap-1">
        <span class="text-detail text-base-content/40 font-semibold mb-0.5">{mwProps.label}</span>
        <For each={mwProps.items}>
          {(name, i) => (
            <div
              class={`flex items-center gap-2 group/mw ${dragOver() === i() ? "mw-drop-target" : ""}`}
              draggable={true}
              onDragStart={(e) => onDragStart(e, i())}
              onDragOver={(e) => onDragOverItem(e, i())}
              onDrop={(e) => onDrop(e, i())}
              onDragEnd={onDragEnd}
            >
              <span class="text-base-content/30 text-detail w-5 text-right shrink-0">{i() + 1}.</span>
              <span class="mw-drag-handle text-base-content/20 cursor-grab group-hover/mw:text-base-content/50" title="Drag to reorder">{"\u2807"}</span>
              <span class="badge badge-xs badge-primary text-tiny">{name}</span>
              <button
                class="text-base-content/20 hover:text-error text-detail bg-transparent border-none p-0 cursor-pointer opacity-0 group-hover/mw:opacity-100 transition-opacity"
                onClick={(e) => { e.stopPropagation(); remove(i()); }}
                title={`Remove ${name}`}
              >&#215;</button>
            </div>
          )}
        </For>
        <Show when={mwProps.items.length === 0}>
          <span class="text-detail text-base-content/20 italic">No middleware assigned</span>
        </Show>
        <div class="flex items-center gap-1 mt-1">
          <Show when={!showAdd()} fallback={
            <div class="flex items-center gap-1 flex-wrap">
              <For each={unassigned()}>
                {(name) => (
                  <button
                    class="badge badge-xs badge-ghost text-tiny cursor-pointer hover:bg-primary/20 hover:text-primary transition-colors"
                    onClick={(e) => { e.stopPropagation(); addMw(name); }}
                  >+ {name}</button>
                )}
              </For>
              <button
                class="text-base-content/30 text-detail cursor-pointer hover:text-base-content bg-transparent border-none p-0"
                onClick={(e) => { e.stopPropagation(); setShowAdd(false); }}
              >Cancel</button>
            </div>
          }>
            <Show when={unassigned().length > 0}>
              <button
                class="btn btn-xs btn-ghost text-primary/50"
                onClick={(e) => { e.stopPropagation(); setShowAdd(true); }}
              >+ Add middleware</button>
            </Show>
          </Show>
        </div>
      </div>
    );
  }

  function TreeRow(treeProps: {
    node: TreeNode; depth: number;
    onNavigate: (path: string, ctx?: Record<string, unknown>) => void;
    stats: Map<string, RouteStats>;
    filterQuery: string;
    globalMw: GlobalMW[];
  }) {
    const indent = () => treeProps.depth * 20;
    const hasChildren = () => treeProps.node.children.length > 0;
    const isCollapsed = () => collapsed().has(treeProps.node.fullPath);
    const guides = () => Array.from({ length: treeProps.depth }, (_, i) => i);

    return <>
      {/* Branch header */}
      <Show when={hasChildren()}>
        <tr
          class="group cursor-pointer hover:bg-base-300/20"
          tabindex="0"
          role="button"
          onClick={() => toggleCollapse(treeProps.node.fullPath)}
          onKeyDown={onKeyActivate(() => toggleCollapse(treeProps.node.fullPath))}
        >
          <td class="relative py-1.5" colspan="2">
            {guides().map(i => (
              <span class="tree-guide" style={{ left: `${i * 20 + 16}px` }} />
            ))}
            <div class="flex items-center gap-1.5" style={{ "padding-left": `${indent() + 8}px` }}>
              <span class="text-base-content/60 text-xs w-4 text-center shrink-0" aria-label={isCollapsed() ? "Expand section" : "Collapse section"}>{isCollapsed() ? "\u25B8" : "\u25BE"}</span>
              <span class="text-base-content/70 font-semibold text-xs">{highlightMatch("/" + treeProps.node.segment, treeProps.filterQuery)}</span>
              <span class="text-base-content/50 text-xs ml-0.5">({countRoutes(treeProps.node)})</span>
            </div>
          </td>
        </tr>
      </Show>

      <Show when={!isCollapsed()}>
        {/* Route rows */}
        <For each={treeProps.node.routes}>
          {(r) => {
            const stats = matchRouteToStats(r, treeProps.stats);
            const routeMw = () => Array.isArray(r.middleware) ? r.middleware : [];
            const hasRouteMw = () => routeMw().length > 0;
            const routeKey = () => `${r.method} ${r.pattern}`;
            const isExpanded = () => expandedRoutes().has(routeKey());
            return (<>
              <tr class="hover:bg-base-300/30 group">
                <td class="relative py-1.5">
                  {guides().map(i => (
                    <span class="tree-guide" style={{ left: `${i * 20 + 16}px` }} />
                  ))}
                  <div style={{ "padding-left": `${indent() + (hasChildren() ? 28 : 8)}px` }}>
                    <div class="flex items-center gap-2">
                      <span class={`method-${r.method} font-semibold min-w-[52px] w-fit text-center shrink-0`}>{r.method}</span>
                      <span class="text-base-content/80">{renderPatternHighlighted(r.pattern, treeProps.filterQuery)}</span>
                      {/* Inline traffic indicators */}
                      <Show when={stats.hits > 0}>
                        <span class="flex items-center gap-1.5 ml-auto mr-2 shrink-0 max-sm:hidden">
                          <span class={`inline-block w-1.5 h-1.5 rounded-full ${statusDotClass(stats)}`} title={`${stats.errors} errors / ${stats.hits} total`} aria-label={`${stats.hits} requests, ${stats.errors} errors`} />
                          <span class="text-base-content/40 text-detail">{stats.hits}</span>
                          <Show when={stats.lastHit}>
                            <span class="text-base-content/30 text-detail">{(tick(), relativeTime(stats.lastHit!))}</span>
                          </Show>
                        </span>
                      </Show>
                    </div>
                    {/* Mobile: show handler + middleware below pattern */}
                    <div class="sm:hidden mt-0.5">
                      <button
                        class="text-primary/70 text-detail cursor-pointer hover:text-primary hover:underline bg-transparent border-none p-0 font-inherit focus-visible:ring-1 focus-visible:ring-primary rounded"
                        onClick={(e) => { e.stopPropagation(); treeProps.onNavigate("/files", { navigate_to_script_name: r.handler }); }}
                      >{r.handler}</button>
                      <Show when={hasRouteMw()}>
                        <div class="flex items-center gap-1.5 mt-1 flex-wrap">
                          <For each={routeMw()}>{(m, i) => (
                            <button
                              class="badge badge-xs badge-primary text-tiny cursor-pointer hover:bg-primary/20 hover:text-primary transition-colors focus-visible:ring-1 focus-visible:ring-primary"
                              onClick={(e) => { e.stopPropagation(); treeProps.onNavigate("/files", { navigate_to_script_name: r.handler }); }}
                              title={`Route middleware #${i() + 1} — click to edit source`}
                            >{m}</button>
                          )}</For>
                          <button
                            class="text-base-content/30 text-detail cursor-pointer hover:text-primary bg-transparent border-none p-0 font-inherit"
                            onClick={(e) => { e.stopPropagation(); toggleRouteExpand(routeKey()); }}
                            title="Show full middleware chain"
                            aria-label="Show middleware chain"
                          >{isExpanded() ? "\u25BE" : "\u25B8"}</button>
                        </div>
                      </Show>
                    </div>
                  </div>
                </td>
                <td class="max-sm:hidden py-1.5">
                  <div class="flex items-center gap-2 flex-wrap">
                    <button
                      class="text-primary/70 cursor-pointer hover:text-primary hover:underline bg-transparent border-none p-0 font-inherit focus-visible:ring-1 focus-visible:ring-primary rounded"
                      onClick={(e) => { e.stopPropagation(); treeProps.onNavigate("/files", { navigate_to_script_name: r.handler }); }}
                    >{r.handler}</button>
                    <Show when={hasRouteMw()}>
                      <For each={routeMw()}>{(m, i) => (
                        <button
                          class="badge badge-xs badge-primary text-tiny cursor-pointer hover:bg-primary/20 hover:text-primary transition-colors focus-visible:ring-1 focus-visible:ring-primary"
                          onClick={(e) => { e.stopPropagation(); treeProps.onNavigate("/files", { navigate_to_script_name: r.handler }); }}
                          title={`Route middleware #${i() + 1} — click to edit source`}
                        >{m}</button>
                      )}</For>
                      <button
                        class="text-base-content/30 text-detail cursor-pointer hover:text-primary bg-transparent border-none p-0 font-inherit"
                        onClick={(e) => { e.stopPropagation(); toggleRouteExpand(routeKey()); }}
                        title="Show full middleware chain"
                        aria-label="Show middleware chain"
                      >{isExpanded() ? "\u25BE" : "\u25B8"}</button>
                    </Show>
                  </div>
                </td>
              </tr>
              {/* Expanded: interactive middleware panel */}
              <Show when={isExpanded()}>
                <tr class="bg-base-200/40">
                  <td colspan="2" class="py-2">
                    <div style={{ "padding-left": `${indent() + (hasChildren() ? 44 : 24)}px` }} class="flex flex-col gap-3">
                      {/* Global middleware (read-only context) */}
                      <Show when={treeProps.globalMw.length > 0}>
                        <div class="flex flex-col gap-1">
                          <span class="text-detail text-base-content/40 font-semibold mb-0.5">Global middleware</span>
                          <For each={treeProps.globalMw}>
                            {(g, i) => (
                              <div class="flex items-center gap-2">
                                <span class="text-base-content/30 text-detail w-5 text-right shrink-0">{i() + 1}.</span>
                                <span class="badge badge-xs badge-ghost text-tiny">{g.name}</span>
                                <span class="text-base-content/20 text-detail">(global)</span>
                              </div>
                            )}
                          </For>
                        </div>
                      </Show>
                      {/* Route middleware (interactive) */}
                      {(() => {
                        const currentItems = getPendingOrCurrent(routeKey(), routeMw());
                        const hasPending = pendingMw().has(routeKey());
                        return <>
                          <MiddlewarePanel
                            items={currentItems}
                            available={availableMw()}
                            onChange={(items) => setPendingForRoute(routeKey(), items)}
                            label="Route middleware"
                          />
                          <Show when={hasPending}>
                            <div class="flex items-center gap-2 mt-1">
                              <button
                                class={`btn btn-xs btn-primary ${saving() === routeKey() ? "loading loading-spinner loading-xs" : ""}`}
                                disabled={saving() === routeKey()}
                                onClick={(e) => { e.stopPropagation(); saveMw(r.pattern, routeKey(), currentItems); }}
                              >Save</button>
                              <button
                                class="btn btn-xs btn-ghost"
                                onClick={(e) => { e.stopPropagation(); cancelPending(routeKey()); }}
                              >Cancel</button>
                              <Show when={mwFeedback()?.key === routeKey()}>
                                <span class={`text-detail feedback-flash ${mwFeedback()!.err ? "text-error" : "text-success"}`}>{mwFeedback()!.msg}</span>
                              </Show>
                            </div>
                          </Show>
                          <Show when={!hasPending && mwFeedback()?.key === routeKey()}>
                            <span class={`text-detail feedback-flash ${mwFeedback()!.err ? "text-error" : "text-success"}`}>{mwFeedback()!.msg}</span>
                          </Show>
                        </>;
                      })()}
                      <button
                        class="btn btn-xs btn-ghost text-primary/60 w-fit"
                        onClick={(e) => { e.stopPropagation(); treeProps.onNavigate("/files", { navigate_to_script_name: r.handler }); }}
                      >Edit in source</button>
                    </div>
                  </td>
                </tr>
              </Show>
            </>);
          }}
        </For>

        {/* Leaf branch with no routes */}
        <Show when={treeProps.node.routes.length === 0 && !hasChildren()}>
          <tr class="bg-base-200/30">
            <td class="relative py-1.5" colspan="2">
              {guides().map(i => (
                <span class="tree-guide" style={{ left: `${i * 20 + 16}px` }} />
              ))}
              <div style={{ "padding-left": `${indent() + 8}px` }}>
                <span class="text-base-content/50 text-detail font-medium">/{treeProps.node.segment}</span>
              </div>
            </td>
          </tr>
        </Show>

        {/* Recurse children */}
        <For each={treeProps.node.children}>
          {(child) => <TreeRow node={child} depth={treeProps.depth + 1} onNavigate={treeProps.onNavigate} stats={treeProps.stats} filterQuery={treeProps.filterQuery} globalMw={treeProps.globalMw} />}
        </For>
      </Show>
    </>;
  }

  return (
    <div class="flex flex-col h-full">
      <div class="px-4 py-2 border-b border-base-300/50 bg-base-200/30 flex items-center gap-2 flex-wrap">
        <input
          class="input input-xs input-bordered w-48 max-sm:w-32"
          placeholder="Filter routes..."
          aria-label="Filter routes by pattern"
          value={filter()}
          onInput={e => setFilter(e.currentTarget.value)}
        />
        <Show when={filter()}>
          <button class="btn btn-xs btn-ghost text-base-content/50" onClick={() => setFilter("")} aria-label="Clear filter">Clear</button>
        </Show>
        <span class="ml-auto text-detail text-base-content/60">{filtered().length} routes</span>
        <button
          class={`btn btn-xs btn-ghost text-base-content/60 ${loading() ? "loading loading-spinner loading-xs" : ""}`}
          onClick={loadRoutes} disabled={loading()}
          title="Refresh routes"
          aria-label="Refresh routes"
        >{loading() ? "" : "\u21BB"}</button>
      </div>

      <div class="flex-1 overflow-y-auto">
        <Show when={routes() === null && !error()}>
          <div class="flex flex-col gap-2 p-3">
            <div class="skeleton-pulse rounded h-4" style="width:40%" />
            <div class="skeleton-pulse rounded h-4" style="width:70%" />
            <div class="skeleton-pulse rounded h-4" style="width:55%" />
            <div class="skeleton-pulse rounded h-4" style="width:65%" />
          </div>
        </Show>
        <Show when={error()}>{(e) => <div class="p-4 text-error text-center">{e()}<button class="btn btn-xs btn-ghost text-error ml-2" onClick={loadRoutes}>Retry</button></div>}</Show>
        <Show when={routes() !== null && !error()}>
          {/* Global middleware panel */}
          <Show when={globalMw().length > 0}>
            <div class="border-b border-base-300/50">
              <div
                class="px-4 py-2 flex items-center gap-2 cursor-pointer hover:bg-base-300/20"
                onClick={() => setMwPanelOpen(!mwPanelOpen())}
              >
                <span class="text-base-content/60 text-xs">{mwPanelOpen() ? "\u25BE" : "\u25B8"}</span>
                <span class="text-detail text-base-content/50 font-semibold tracking-wider">GLOBAL MIDDLEWARE</span>
                <span class="text-base-content/30 text-detail">({globalMw().length})</span>
              </div>
              <Show when={mwPanelOpen()}>
                <div class="px-4 pb-3">
                  {(() => {
                    const currentGlobal = getPendingOrCurrent("__global", globalMw().map(g => g.name));
                    const hasPending = pendingMw().has("__global");
                    return <>
                      <MiddlewarePanel
                        items={currentGlobal}
                        available={availableMw()}
                        onChange={(items) => setPendingForRoute("__global", items)}
                        label="Execution order"
                      />
                      <Show when={hasPending}>
                        <div class="flex items-center gap-2 mt-2">
                          <button
                            class={`btn btn-xs btn-primary ${saving() === "__global" ? "loading loading-spinner loading-xs" : ""}`}
                            disabled={saving() === "__global"}
                            onClick={() => saveGlobalMw(currentGlobal)}
                          >Save</button>
                          <button
                            class="btn btn-xs btn-ghost"
                            onClick={() => cancelPending("__global")}
                          >Cancel</button>
                          <Show when={mwFeedback()?.key === "__global"}>
                            <span class={`text-detail feedback-flash ${mwFeedback()!.err ? "text-error" : "text-success"}`}>{mwFeedback()!.msg}</span>
                          </Show>
                        </div>
                      </Show>
                      <Show when={!hasPending && mwFeedback()?.key === "__global"}>
                        <span class={`text-detail feedback-flash ${mwFeedback()!.err ? "text-error" : "text-success"}`}>{mwFeedback()!.msg}</span>
                      </Show>
                      <button
                        class="btn btn-xs btn-ghost text-primary/50 mt-1"
                        onClick={() => props.onNavigate("/files", { navigate_to_script_name: "keyway.lua" })}
                        title="Edit global middleware in source"
                      >Edit in keyway.lua</button>
                    </>;
                  })()}
                </div>
              </Show>
            </div>
          </Show>

          <Show when={filtered().length > 0} fallback={
            <div class="flex flex-col items-center justify-center py-12 space-y-3">
              <Show when={filter()} fallback={<>
                <span class="text-2xl text-primary/20 font-mono">/path</span>
                <h3 class="text-sm font-semibold text-base-content">No routes yet</h3>
                <p class="text-detail text-base-content/50 text-center max-w-xs">Routes appear here when you add URL patterns to your Lua scripts.</p>
                <button class="btn btn-sm btn-ghost border border-base-300 text-base-content/60" onClick={() => props.onNavigate("/files")}>Go to Files</button>
              </>}>
                <span class="text-2xl text-base-content/20 font-mono">/...</span>
                <span class="text-sm text-base-content/50">No routes match "<span class="text-primary/70">{filter()}</span>"</span>
                <button class="btn btn-xs btn-ghost text-base-content/40" onClick={() => setFilter("")}>Clear filter</button>
              </Show>
            </div>
          }>
            <table class="table table-xs w-full">
              <tbody>
                <For each={tree()}>
                  {(node) => <TreeRow node={node} depth={0} onNavigate={props.onNavigate} stats={trafficStats()} filterQuery={filter()} globalMw={globalMw()} />}
                </For>
              </tbody>
            </table>
          </Show>
        </Show>
      </div>
    </div>
  );
}

// ─── FilesView ──────────────────────────────────────────

interface FileEntry { path: string; name: string; enabled: boolean; }

export function FilesView(props: {
  onNavigate: (path: string, ctx?: Record<string, unknown>) => void;
}) {
  const [files, setFiles] = createSignal<FileEntry[]>([]);
  const [loadError, setLoadError] = createSignal<string | null>(null);
  const [currentFile, setCurrentFile] = createSignal<string | null>(null);
  const [editorContent, setEditorContent] = createSignal("");
  const [dirty, setDirty] = createSignal(false);
  const [feedback, setFeedback] = createSignal<{ msg: string; err: boolean } | null>(null);
  const [reloading, setReloading] = createSignal(false);
  const [newFileName, setNewFileName] = createSignal("");
  const [showNewFile, setShowNewFile] = createSignal(false);
  const [confirmingDelete, setConfirmingDelete] = createSignal(false);
  const [draggingOver, setDraggingOver] = createSignal(false);
  let editorRef!: HTMLDivElement;
  let editorView: EditorView | null = null;
  let feedbackTimer: ReturnType<typeof setTimeout> | null = null;
  let dragCounter = 0;

  function createEditor(code: string) {
    if (editorView) editorView.destroy();
    editorView = new EditorView({
      state: EditorState.create({
        doc: code,
        extensions: [
          basicSetup,
          StreamLanguage.define(lua),
          cmTheme,
          EditorView.lineWrapping,
          EditorView.updateListener.of((update) => {
            if (update.docChanged) setDirty(true);
          }),
        ],
      }),
      parent: editorRef,
    });
  }

  function getEditorCode(): string {
    return editorView?.state.doc.toString() || "";
  }

  function flash(msg: string, isErr: boolean) {
    setFeedback({ msg, err: isErr });
    if (feedbackTimer) clearTimeout(feedbackTimer);
    feedbackTimer = setTimeout(() => setFeedback(null), 3000);
  }

  async function loadFiles() {
    setLoadError(null);
    try {
      const d = await api<{ files: FileEntry[] }>("/__keyway/api/files");
      setFiles(d.files || []);
    } catch (e) { setLoadError((e as Error).message); }
  }

  async function selectFile(path: string) {
    try {
      const d = await api<{ content: string }>(`/__keyway/api/files/${encodeURIComponent(path)}`);
      setCurrentFile(path);
      setEditorContent(d.content);
      setDirty(false);
      setConfirmingDelete(false);
      if (editorRef) createEditor(d.content);
    } catch (e) { flash("Failed to load: " + (e as Error).message, true); }
  }

  async function onSave() {
    const path = currentFile();
    if (!path) return;
    try {
      await api(`/__keyway/api/files/${encodeURIComponent(path)}`, {
        method: "PUT",
        body: JSON.stringify({ content: getEditorCode() }),
      });
      setDirty(false);
      flash("Saved", false);
    } catch (e) { flash("Save failed: " + (e as Error).message, true); }
  }

  async function onReload() {
    setReloading(true);
    try {
      await api("/__keyway/reload", { method: "POST" });
      flash("Reload triggered", false);
    } catch (e) { flash("Reload failed: " + (e as Error).message, true); }
    finally { setReloading(false); }
  }

  async function onDelete() {
    const path = currentFile();
    if (!path) return;
    setConfirmingDelete(false);
    try {
      await api(`/__keyway/api/files/${encodeURIComponent(path)}`, { method: "DELETE" });
      setCurrentFile(null);
      if (editorView) { editorView.destroy(); editorView = null; }
      await loadFiles();
      flash("Deleted", false);
    } catch (e) { flash("Delete failed: " + (e as Error).message, true); }
  }

  async function onNewFile() {
    const name = newFileName().trim();
    if (!name) return;
    const path = name.endsWith(".lua") ? name : name + ".lua";
    try {
      await api(`/__keyway/api/files/${encodeURIComponent(path)}`, {
        method: "PUT",
        body: JSON.stringify({ content: "-- " + path + "\n" }),
      });
      setShowNewFile(false);
      setNewFileName("");
      await loadFiles();
      await selectFile(path);
    } catch (e) { flash("Create failed: " + (e as Error).message, true); }
  }

  async function onToggle(path: string, e: Event) {
    e.stopPropagation();
    try {
      const d = await api<{ path: string }>(`/__keyway/api/files/${encodeURIComponent(path)}/toggle`, { method: "POST" });
      await loadFiles();
      if (currentFile() === path) setCurrentFile(d.path);
      flash(path.endsWith(".disabled") ? "Enabled" : "Disabled", false);
    } catch (err) { flash("Toggle failed: " + (err as Error).message, true); }
  }

  function onDragEnter(e: DragEvent) {
    e.preventDefault();
    dragCounter++;
    if (e.dataTransfer?.types.includes("Files")) setDraggingOver(true);
  }

  function onDragLeave(e: DragEvent) {
    e.preventDefault();
    dragCounter--;
    if (dragCounter <= 0) { dragCounter = 0; setDraggingOver(false); }
  }

  function onDragOverHandler(e: DragEvent) { e.preventDefault(); }

  async function onDrop(e: DragEvent) {
    e.preventDefault();
    dragCounter = 0;
    setDraggingOver(false);
    const dt = e.dataTransfer;
    if (!dt?.files.length) return;
    for (const file of Array.from(dt.files)) {
      if (!file.name.endsWith(".lua")) continue;
      const content = await file.text();
      try {
        await api(`/__keyway/api/files/${encodeURIComponent(file.name)}`, {
          method: "PUT",
          body: JSON.stringify({ content }),
        });
        await loadFiles();
        await selectFile(file.name);
        flash(`Uploaded ${file.name}`, false);
      } catch (err) { flash("Upload failed: " + (err as Error).message, true); }
    }
  }

  // Group files by directory
  const fileTree = createMemo(() => {
    const dirs = new Map<string, FileEntry[]>();
    for (const f of files()) {
      const parts = f.path.split("/");
      const dir = parts.length > 1 ? parts.slice(0, -1).join("/") : ".";
      if (!dirs.has(dir)) dirs.set(dir, []);
      dirs.get(dir)!.push(f);
    }
    // Sort dirs alphabetically, files within each dir alphabetically
    const sorted = [...dirs.entries()].sort(([a], [b]) => a.localeCompare(b));
    for (const [, list] of sorted) list.sort((a, b) => a.name.localeCompare(b.name));
    return sorted;
  });

  onMount(() => { loadFiles(); });
  onCleanup(() => { if (editorView) editorView.destroy(); });

  return (
    <div class="flex flex-col h-full">
      <div class="flex flex-1 overflow-hidden max-sm:flex-col">
        {/* File tree — hidden on mobile when editing */}
        <div class={`w-64 border-r border-base-300 overflow-y-auto shrink-0 max-sm:w-full max-sm:border-r-0 max-sm:border-b ${currentFile() ? "max-sm:hidden" : ""}`}>
          <div class="px-3 py-2 border-b border-base-300/50 flex items-center gap-2">
            <button class="btn btn-xs btn-primary flex-1" onClick={() => setShowNewFile(true)}>+ New File</button>
            <button
              class={`btn btn-xs btn-ghost border border-base-300 ${reloading() ? "loading loading-spinner loading-xs" : ""}`}
              onClick={onReload}
              disabled={reloading()}
              title="Hot-reload all workers"
            >{reloading() ? "" : "\u21BB Reload"}</button>
          </div>
          <Show when={showNewFile()}>
            <div class="px-3 py-2 border-b border-base-300/50 bg-base-200/50 flex items-center gap-1">
              <input
                class="input input-xs input-bordered flex-1"
                placeholder="path/file.lua"
                value={newFileName()}
                onInput={e => setNewFileName(e.currentTarget.value)}
                onKeyDown={e => { if (e.key === "Enter") onNewFile(); if (e.key === "Escape") setShowNewFile(false); }}
                autofocus
              />
              <button class="btn btn-xs btn-primary" onClick={onNewFile}>Create</button>
              <button class="btn btn-xs btn-ghost" onClick={() => setShowNewFile(false)}>&#215;</button>
            </div>
          </Show>
          <Show when={loadError()}>{(e) => <div class="p-4 text-error text-center">{e()}</div>}</Show>
          <Show when={files().length === 0 && !loadError()}>
            <div class="p-4 text-detail text-base-content/30 text-center">No .lua files found</div>
          </Show>
          <For each={fileTree()}>
            {([dir, dirFiles]) => (
              <>
                <div class="px-3 pt-3 pb-1">
                  <span class="text-detail text-base-content/40 font-semibold tracking-wider">{dir === "." ? "ROOT" : dir.toUpperCase()}</span>
                </div>
                <For each={dirFiles}>
                  {(f) => (
                    <div
                      class={`px-3 py-1.5 cursor-pointer hover:bg-base-300 border-b border-base-300/50 ${currentFile() === f.path ? "bg-base-300/50 border-l-2 border-l-primary" : ""} ${!f.enabled ? "opacity-50" : ""}`}
                      tabindex="0"
                      role="button"
                      onClick={() => selectFile(f.path)}
                      onKeyDown={onKeyActivate(() => selectFile(f.path))}
                    >
                      <div class="flex items-center gap-2">
                        <span class="text-primary/40 text-detail shrink-0">.lua</span>
                        <span class="font-medium text-base-content/80 truncate">{f.name}</span>
                        <input
                          type="checkbox"
                          class="toggle toggle-xs toggle-primary ml-auto shrink-0"
                          checked={f.enabled}
                          onClick={(e) => onToggle(f.path, e)}
                          title={f.enabled ? "Disable file" : "Enable file"}
                        />
                      </div>
                      <Show when={f.path !== f.name}>
                        <div class="text-detail text-base-content/40 truncate">{f.path}</div>
                      </Show>
                    </div>
                  )}
                </For>
              </>
            )}
          </For>
        </div>

        {/* Editor panel */}
        <div
          class={`flex-1 flex flex-col overflow-hidden ${draggingOver() ? "ring-2 ring-primary ring-dashed" : ""}`}
          onDragEnter={onDragEnter}
          onDragOver={onDragOverHandler}
          onDragLeave={onDragLeave}
          onDrop={onDrop}
        >
          <Show when={currentFile()} fallback={
            <div class="flex flex-col items-center justify-center h-full text-base-content/50 max-sm:py-12 space-y-3">
              <span class="text-2xl opacity-20 font-mono">.lua</span>
              <span class="text-sm">{draggingOver() ? "Drop .lua files to upload" : "Select a file to edit"}</span>
              <span class="text-detail text-base-content/30">{draggingOver() ? "" : "Drag & drop .lua files here, or"}</span>
              <Show when={!draggingOver()}>
                <button class="btn btn-xs btn-primary mt-2" onClick={() => setShowNewFile(true)}>+ New File</button>
              </Show>
            </div>
          }>
            {(path) => <>
              {/* Mobile: back button */}
              <div class="sm:hidden px-4 py-1.5 border-b border-base-300 bg-base-200/30">
                <button class="btn btn-xs btn-ghost" onClick={() => setCurrentFile(null)}>{"\u2190"} Back</button>
              </div>
              {/* File path header */}
              <div class="px-4 py-2 border-b border-base-300 bg-base-200/30 flex items-center gap-3">
                <span class="font-mono text-base-content/70 text-sm">{path()}</span>
                <Show when={dirty()}>
                  <span class="badge badge-xs badge-warning">unsaved</span>
                </Show>
              </div>
              {/* CodeMirror editor */}
              <div ref={editorRef} class="flex-1 overflow-auto border-b border-base-300" />
              {/* Actions */}
              <div class="flex items-center gap-2 px-4 py-2 border-t border-base-300 bg-base-200/30 flex-wrap">
                <button class="btn btn-xs btn-primary" onClick={onSave} disabled={!dirty()}>Save</button>
                <button
                  class={`btn btn-xs btn-ghost border border-base-300 ${reloading() ? "loading loading-spinner loading-xs" : ""}`}
                  onClick={async () => { if (dirty()) await onSave(); await onReload(); }}
                  disabled={reloading()}
                >Save & Reload</button>
                <div class="flex-1" />
                <Show when={confirmingDelete()} fallback={
                  <button class="btn btn-xs btn-error btn-ghost" onClick={() => setConfirmingDelete(true)}>Delete</button>
                }>
                  <span class="text-detail text-base-content/70">Delete "{path()}"?</span>
                  <button class="btn btn-xs btn-error" onClick={onDelete}>Yes</button>
                  <button class="btn btn-xs btn-ghost" onClick={() => setConfirmingDelete(false)}>Cancel</button>
                </Show>
                <Show when={feedback()}>{(fb) => <span class={`text-detail ml-2 feedback-flash ${fb().err ? "text-error" : "text-success"}`}>{fb().msg}</span>}</Show>
              </div>
            </>}
          </Show>
        </div>
      </div>
    </div>
  );
}
