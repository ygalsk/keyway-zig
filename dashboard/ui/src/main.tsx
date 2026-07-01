// Keyway Dashboard — app shell
// PaaS scripting engine experience: Engine, Routes, Files, Console

import { render } from "solid-js/web";
import { createSignal, createEffect, onCleanup, For, Show, Switch, Match } from "solid-js";

// ─── Types ──────────────────────────────────────────

export type ConnStatus = "connected" | "connecting" | "disconnected";

export interface Route {
  method: string; pattern: string; handler: string; middleware: string[]; type?: string;
}

// ─── Utilities ──────────────────────────────────────────

export function classifyStatus(status: number): string {
  if (status >= 200 && status < 400) return "success";
  if (status === 499) return "client_disconnect";
  if (status >= 400 && status < 500) return "client_error";
  if (status === 504) return "timeout";
  if (status === 503) return "resource_exceeded";
  if (status >= 500) return "internal_error";
  return "success";
}

export const INVOCATION_LABELS: Record<string, string> = {
  success: "Success", client_error: "Client Error", client_disconnect: "Client Disconnect",
  timeout: "Timeout", resource_exceeded: "Resource Exceeded", internal_error: "Internal Error",
};

export function formatLatency(us: number): string {
  if (!us || us === 0) return "-";
  if (us < 1000) return Math.round(us) + "us";
  if (us < 1000000) return (us / 1000).toFixed(1) + "ms";
  return (us / 1000000).toFixed(2) + "s";
}

export function formatTime(ts: number, showMs = true): string {
  const d = new Date(ts);
  const base = d.toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" });
  return showMs ? base + "." + String(d.getMilliseconds()).padStart(3, "0") : base;
}

export function getHashParams(): URLSearchParams {
  const raw = location.hash.slice(1) || "/";
  const q = raw.indexOf("?");
  return q === -1 ? new URLSearchParams() : new URLSearchParams(raw.slice(q + 1));
}

function parseHash(hash: string): string {
  const raw = hash.slice(1) || "/";
  const q = raw.indexOf("?");
  return q === -1 ? raw : raw.slice(0, q);
}

// ─── API ────────────────────────────────────────────────

const FETCH_TIMEOUT = 10_000;
let _pushError: (msg: string) => void = (m) => console.warn("[keyway]", m);

export async function api<T>(path: string, opts: RequestInit = {}): Promise<T> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT);
  try {
    const res = await fetch(path, {
      headers: { "Content-Type": "application/json", ...opts.headers as Record<string, string> },
      signal: ctrl.signal, ...opts,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${res.statusText}`);
    const text = await res.text();
    try { return JSON.parse(text) as T; }
    catch { throw new Error(`Invalid JSON from ${path}: ${text.slice(0, 200)}`); }
  } catch (err) {
    _pushError(`API ${path}: ${(err as Error).message}`);
    throw err;
  } finally { clearTimeout(t); }
}

export async function fetchEffectiveConfig() { return api<object>("/__keyway/api/config/effective"); }
export function startStream(onChunk: (s: string) => void, onDone: () => void): () => void {
  const ctrl = new AbortController();
  fetch("/__keyway/api/stream", { signal: ctrl.signal })
    .then(async res => {
      const r = res.body?.getReader();
      if (!r) { onDone(); return; }
      const dec = new TextDecoder();
      while (true) { const { done, value } = await r.read(); if (done) break; onChunk(dec.decode(value, { stream: true })); }
      onDone();
    }).catch(() => onDone());
  return () => ctrl.abort();
}

let _ws: WebSocket | null = null;
let _wsRetryTimer: ReturnType<typeof setTimeout> | null = null;

export function sendWS(data: object): void {
  if (_ws?.readyState === WebSocket.OPEN) _ws.send(JSON.stringify(data));
}

// ─── Metrics ────────────────────────────────────────────
// Polls GET /metrics (Prometheus text format) and reduces it into a snapshot
// the views can read without re-parsing.

export interface MetricsSnapshot {
  ts: number; total: number;
  byWorker: Map<string, number>;
  byStatus: Map<number, number>;
  byRoute: Map<string, { hits: number; errors: number }>;
  byMethodRoute: Map<string, { hits: number; errors: number }>;
  latencyByRoute: Map<string, { sum: number; count: number }>;
  activeConnections: number; activeCoroutines: number; rejected: number;
}

function parseMetrics(text: string): MetricsSnapshot {
  const snap: MetricsSnapshot = {
    ts: Date.now(), total: 0,
    byWorker: new Map(), byStatus: new Map(), byRoute: new Map(),
    byMethodRoute: new Map(), latencyByRoute: new Map(),
    activeConnections: 0, activeCoroutines: 0, rejected: 0,
  };
  for (const line of text.split("\n")) {
    if (!line || line[0] === "#") continue;
    const brace = line.indexOf("{");
    const lastSpace = line.lastIndexOf(" ");
    const name = line.slice(0, brace === -1 ? lastSpace : brace);
    const value = Number(line.slice(lastSpace + 1));
    if (Number.isNaN(value)) continue;
    const labels: Record<string, string> = {};
    if (brace !== -1) {
      // route patterns like "/test/status/{code}" embed a closing brace in the
      // label value itself, so the label block's terminator must be found by
      // scanning backward from the value separator, not forward from the start.
      const closeBrace = line.lastIndexOf("}", lastSpace);
      const re = /(\w+)="([^"]*)"/g;
      let m;
      while ((m = re.exec(line.slice(brace, closeBrace)))) labels[m[1]] = m[2];
    }
    if (name === "keyway_http_requests_total") {
      snap.total += value;
      const status = Number(labels.status);
      const worker = labels.worker_id || "";
      const route = labels.route || "";
      const err = status >= 400;
      snap.byStatus.set(status, (snap.byStatus.get(status) || 0) + value);
      snap.byWorker.set(worker, (snap.byWorker.get(worker) || 0) + value);
      const r = snap.byRoute.get(route) || { hits: 0, errors: 0 };
      r.hits += value; if (err) r.errors += value;
      snap.byRoute.set(route, r);
      const key = `${labels.method} ${route}`;
      const mr = snap.byMethodRoute.get(key) || { hits: 0, errors: 0 };
      mr.hits += value; if (err) mr.errors += value;
      snap.byMethodRoute.set(key, mr);
    } else if (name === "keyway_http_request_duration_seconds_sum") {
      const l = snap.latencyByRoute.get(labels.route || "") || { sum: 0, count: 0 };
      l.sum += value;
      snap.latencyByRoute.set(labels.route || "", l);
    } else if (name === "keyway_http_request_duration_seconds_count") {
      const l = snap.latencyByRoute.get(labels.route || "") || { sum: 0, count: 0 };
      l.count += value;
      snap.latencyByRoute.set(labels.route || "", l);
    } else if (name === "keyway_connections_active") {
      snap.activeConnections += value;
    } else if (name === "keyway_lua_coroutines_active") {
      snap.activeCoroutines += value;
    } else if (name === "keyway_connections_rejected_total") {
      snap.rejected += value;
    }
  }
  return snap;
}

// ─── Views ──────────────────────────────────────────────

import { EngineView } from "./views/engine";
import { RoutesView, FilesView } from "./views/manage";
import { ConsoleCore } from "./views/console";

// ─── App ────────────────────────────────────────────────

const WS_MESSAGE_MAX = 200;
const ERROR_MAX = 10;
const METRICS_POLL_MS = 2000;
const MAC = typeof navigator !== "undefined" && /Mac/.test(navigator.userAgent);
const CONSOLE_MIN_H = 120;
const CONSOLE_MAX_VH = 70;
const CONSOLE_DEFAULT_H = 300;
const CONSOLE_STORAGE_KEY = "kw_console_height";

const NAV = [
  { path: "/engine", label: "Engine" },
  { path: "/routes", label: "Routes" },
  { path: "/files",  label: "Files" },
];

function getClientY(e: MouseEvent | TouchEvent): number {
  return "touches" in e ? e.touches[0].clientY : e.clientY;
}

interface ToastError { message: string; ts: number; }

function App() {
  // ── State ──
  const [wsStatus, setWsStatus] = createSignal<ConnStatus>("disconnected");
  const [wsMessages, setWsMessages] = createSignal<Record<string, unknown>[]>([]);
  const [metrics, setMetrics] = createSignal<MetricsSnapshot | null>(null);
  const [prevMetrics, setPrevMetrics] = createSignal<MetricsSnapshot | null>(null);
  const [drawerOpen, setDrawerOpen] = createSignal(false);
  const [pendingCmd, setPendingCmd] = createSignal<string | null>(null);
  const [errors, setErrors] = createSignal<ToastError[]>([]);
  const [currentPath, setCurrentPath] = createSignal(parseHash(location.hash));
  const [consoleMounted, setConsoleMounted] = createSignal(false);
  const [showWelcome, setShowWelcome] = createSignal(!localStorage.getItem("kw_onboarded"));
  let viewRef!: HTMLDivElement;

  // ── Resizable console ──
  const savedH = parseInt(localStorage.getItem(CONSOLE_STORAGE_KEY) || "", 10);
  const [consoleHeight, setConsoleHeight] = createSignal(savedH > 0 ? savedH : CONSOLE_DEFAULT_H);
  let dragging = false;
  let dragStartY = 0;
  let dragStartH = 0;

  function onDragStart(e: MouseEvent | TouchEvent) {
    e.preventDefault();
    dragging = true;
    dragStartY = getClientY(e);
    dragStartH = consoleHeight();
    document.addEventListener("mousemove", onDragMove);
    document.addEventListener("mouseup", onDragEnd);
    document.addEventListener("touchmove", onDragMove, { passive: false });
    document.addEventListener("touchend", onDragEnd);
  }

  function onDragMove(e: MouseEvent | TouchEvent) {
    if (!dragging) return;
    if ("touches" in e) e.preventDefault();
    const clientY = getClientY(e);
    const maxH = window.innerHeight * (CONSOLE_MAX_VH / 100);
    const delta = dragStartY - clientY;
    const newH = Math.min(maxH, Math.max(CONSOLE_MIN_H, dragStartH + delta));
    setConsoleHeight(newH);
  }

  function onDragEnd() {
    dragging = false;
    document.removeEventListener("mousemove", onDragMove);
    document.removeEventListener("mouseup", onDragEnd);
    document.removeEventListener("touchmove", onDragMove);
    document.removeEventListener("touchend", onDragEnd);
    localStorage.setItem(CONSOLE_STORAGE_KEY, String(consoleHeight()));
  }

  function pushWsMessage(msg: Record<string, unknown>) {
    setWsMessages(prev => [...(prev.length >= WS_MESSAGE_MAX ? prev.slice(1) : prev), { ...msg, _ts: Date.now() }]);
  }
  function pushError(message: string) { setErrors(prev => [...prev.slice(-(ERROR_MAX - 1)), { message, ts: Date.now() }]); }
  function dismissError(ts: number) { setErrors(prev => prev.filter(e => e.ts !== ts)); }
  _pushError = pushError;

  // ── Navigation ──
  function navigate(path: string, ctx?: Record<string, unknown>) {
    let hash = path;
    if (ctx) {
      const p = new URLSearchParams();
      for (const [k, v] of Object.entries(ctx)) if (v != null) p.set(k, String(v));
      const qs = p.toString();
      if (qs) hash = `${path}?${qs}`;
    }
    location.hash = hash;
    setCurrentPath(path);
  }
  function dismissWelcome() { localStorage.setItem("kw_onboarded", "1"); setShowWelcome(false); }

  window.onhashchange = () => setCurrentPath(parseHash(location.hash));

  // Mark console as mounted once drawer opens
  createEffect(() => { if (drawerOpen() && !consoleMounted()) setConsoleMounted(true); });

  // Restart view-enter animation on navigation
  createEffect(() => {
    currentPath(); // track
    if (viewRef) {
      viewRef.classList.remove("view-enter");
      void viewRef.offsetWidth; // force reflow
      viewRef.classList.add("view-enter");
    }
  });

  // ── Metrics polling ──
  async function pollMetrics() {
    try {
      const res = await fetch("/metrics");
      if (!res.ok) return;
      const text = await res.text();
      setPrevMetrics(metrics());
      setMetrics(parseMetrics(text));
    } catch { /* server-down is already signaled by the WS dot */ }
  }
  pollMetrics();
  const metricsTimer = setInterval(pollMetrics, METRICS_POLL_MS);
  onCleanup(() => clearInterval(metricsTimer));

  // ── WebSocket ──
  function connectWS() {
    if (_ws) return;
    setWsStatus("connecting");
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    _ws = new WebSocket(`${proto}//${location.host}/__keyway/ws`);
    _ws.onopen = () => setWsStatus("connected");
    _ws.onmessage = (e) => { try { pushWsMessage(JSON.parse(e.data)); } catch {} };
    _ws.onclose = () => { setWsStatus("disconnected"); _ws = null; _wsRetryTimer = setTimeout(connectWS, 3000); };
    _ws.onerror = () => _ws?.close();
  }

  connectWS();

  // ── Keyboard shortcuts ──
  function onKeydown(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "k") { e.preventDefault(); setDrawerOpen(!drawerOpen()); }
  }
  document.addEventListener("keydown", onKeydown);
  onCleanup(() => document.removeEventListener("keydown", onKeydown));
  onCleanup(() => {
    if (_wsRetryTimer) clearTimeout(_wsRetryTimer);
    if (_ws) { _ws.close(); _ws = null; }
  });

  // ── Toast auto-dismiss ──
  createEffect(() => {
    const errs = errors();
    if (!errs.length) return;
    const timers = errs.map(e => setTimeout(() => dismissError(e.ts), Math.max(0, 5000 - (Date.now() - e.ts))));
    onCleanup(() => timers.forEach(clearTimeout));
  });

  const serverDown = () => wsStatus() === "disconnected";

  const [wasConnected, setWasConnected] = createSignal(false);
  createEffect(() => {
    if (wsStatus() === "connected" && !wasConnected()) setWasConnected(true);
  });

  function statusDot(status: ConnStatus) {
    const base = status === "connected" ? "bg-success" : status === "connecting" ? "bg-warning status-connecting" : "bg-error";
    return status === "connected" && wasConnected() ? base + " status-connected-enter" : base;
  }

  return (
    <div class="flex flex-col h-screen bg-base-100 text-base-content text-xs">
      {/* Top bar */}
      <header class="flex items-center h-11 px-3 border-b border-base-300 bg-base-200 shrink-0">
        <span class="text-primary font-bold text-sm tracking-widest mr-5">KEYWAY</span>
        <nav class="flex items-center gap-0.5 h-full">
          <For each={NAV}>
            {(route) => {
              const active = () => currentPath() === route.path || (currentPath() === "/" && route.path === "/engine");
              return (
                <a
                  href={`#${route.path}`}
                  class={`px-3 h-full flex items-center text-sm no-underline transition-colors ${
                    active()
                      ? "tab-active font-semibold"
                      : "text-base-content/50 hover:text-base-content"
                  }`}
                  onClick={(e) => { e.preventDefault(); navigate(route.path); }}
                >{route.label}</a>
              );
            }}
          </For>
        </nav>
        <div class="flex-1" />
        <span class={`inline-block w-2 h-2 rounded-full mr-3 ${statusDot(wsStatus())} ${wsStatus() === "connected" ? "status-live" : ""}`}
              title={`WebSocket: ${wsStatus()}`} />
        <button
          class="console-btn px-2 py-1 text-body rounded text-base-content/50 hover:text-primary hover:bg-primary/10 bg-transparent border-none font-inherit cursor-pointer font-semibold"
          onClick={() => setDrawerOpen(!drawerOpen())}
          title={`Console (${MAC ? "Cmd" : "Ctrl"}+K)`}
        >{">_"}</button>
      </header>

      {/* Welcome overlay — first visit only */}
      <Show when={showWelcome()}>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 welcome-backdrop" onClick={(e) => { if (e.target === e.currentTarget) dismissWelcome(); }}>
          <div class="welcome-enter bg-base-200 border border-base-300 rounded-lg p-8 max-w-lg w-full mx-4 shadow-xl">
            <h1 class="text-primary font-bold text-lg tracking-widest text-center mb-2">K E Y W A Y</h1>
            <p class="text-base-content/60 text-sm text-center mb-6">Write Lua scripts, route HTTP traffic, inspect everything live.</p>

            <div class="flex gap-3 mb-6 max-sm:flex-col">
              <div class="flex-1 border border-base-300 rounded-lg p-4 text-center">
                <div class="text-primary/20 text-2xl mb-2">{"▁▄█"}</div>
                <div class="text-sm font-semibold text-base-content mb-1">Engine</div>
                <div class="text-detail text-base-content/50">Live engine state &mdash; workers, traffic, latency</div>
              </div>
              <div class="flex-1 border border-base-300 rounded-lg p-4 text-center">
                <div class="text-primary/20 text-2xl mb-2">{"{..}"}</div>
                <div class="text-sm font-semibold text-base-content mb-1">Files</div>
                <div class="text-detail text-base-content/50">Lua scripts, handlers & middleware</div>
              </div>
              <div class="flex-1 border border-base-300 rounded-lg p-4 text-center">
                <div class="text-primary/20 text-2xl mb-2">{">_"}</div>
                <div class="text-sm font-semibold text-base-content mb-1">Console</div>
                <div class="text-detail text-base-content/50">Live REPL &mdash; {MAC ? "Cmd" : "Ctrl"}+K</div>
              </div>
            </div>

            <div class="flex items-center gap-3">
              <button class="btn btn-sm btn-primary flex-1" onClick={() => { dismissWelcome(); navigate("/engine"); }}>View engine</button>
              <button class="btn btn-sm btn-ghost border border-base-300 flex-1" onClick={() => { dismissWelcome(); setDrawerOpen(true); }}>Open console</button>
              <button class="btn btn-sm btn-ghost text-base-content/40" onClick={dismissWelcome}>Skip</button>
            </div>
          </div>
        </div>
      </Show>

      <Show when={serverDown()}>
        <div class="bg-warning/10 border-b border-warning/30 text-warning text-detail px-4 py-1.5 text-center toast-enter">
          Lost the server — hanging tight, reconnecting...
        </div>
      </Show>
      <For each={errors()}>
        {(err) => (
          <div class="bg-error/10 border-b border-error/30 text-error text-detail px-4 py-1.5 flex items-center gap-2 toast-enter">
            <span class="flex-1">{err.message}</span>
            <button class="btn btn-xs btn-ghost text-error" aria-label="Dismiss error" onClick={() => dismissError(err.ts)}>&#215;</button>
          </div>
        )}
      </For>

      <div ref={viewRef} class="flex-1 overflow-auto view-enter">
        <Switch fallback={<EngineView metrics={metrics} prev={prevMetrics} onNavigate={navigate} />}>
          <Match when={currentPath() === "/engine"}><EngineView metrics={metrics} prev={prevMetrics} onNavigate={navigate} /></Match>
          <Match when={currentPath() === "/routes"}><RoutesView metrics={metrics} onNavigate={navigate} /></Match>
          <Match when={currentPath() === "/files"}><FilesView onNavigate={navigate} /></Match>
        </Switch>
      </div>

      {/* Console drawer — resizable */}
      <Show when={drawerOpen()}>
        <div
          class="h-1 cursor-row-resize bg-base-300 drag-handle shrink-0 touch-none"
          onMouseDown={onDragStart}
          onTouchStart={onDragStart}
        />
        <div
          class="border-t border-base-300 bg-base-200 overflow-hidden shrink-0"
          style={{ height: `${consoleHeight()}px` }}
        >
          <Show when={consoleMounted() || drawerOpen()}>
            <ConsoleCore
              metrics={metrics}
              wsMessages={wsMessages}
              pendingCmd={pendingCmd}
              setPendingCmd={setPendingCmd}
            />
          </Show>
        </div>
      </Show>
    </div>
  );
}

render(() => <App />, document.getElementById("app")!);
