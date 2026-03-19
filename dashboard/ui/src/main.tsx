// Keyway Dashboard — app shell
// PaaS scripting engine experience: Scripts, Routes, Console

import { render } from "solid-js/web";
import { createSignal, createEffect, onCleanup, For, Show, Switch, Match } from "solid-js";

// ─── Types ──────────────────────────────────────────

export type ConnStatus = "connected" | "connecting" | "disconnected";

export interface TrafficEntry {
  method: string; path: string; status: number; latency: string; latency_us: number;
  worker_id: string; content_type: string; header_count: number;
  scripts?: { id: string; name: string }[]; error_message?: string; ts: number;
}

export interface ScriptMeta {
  id: string; name: string; type: "middleware" | "handler"; pattern: string;
  priority: number; enabled: boolean; code: string; middleware?: string[];
  created_at: string; updated_at: string;
}

export interface Route {
  method: string; pattern: string; handler: string; middleware: string[]; type?: string;
}

export interface MiddlewareInfo {
  name: string; source: string; line: number;
}

// ─── Utilities ──────────────────────────────────────────

export function classifyInvocation(e: TrafficEntry): string {
  if (e.status >= 200 && e.status < 400) return "success";
  if (e.status === 499) return "client_disconnect";
  if (e.status >= 400 && e.status < 500) return "client_error";
  if (e.status === 504) return "timeout";
  if (e.status === 503) return "resource_exceeded";
  if (e.status >= 500) return "internal_error";
  return "success";
}

export const INVOCATION_LABELS: Record<string, string> = {
  success: "Success", client_error: "Client Error", client_disconnect: "Client Disconnect",
  script_error: "Script Error", timeout: "Timeout", resource_exceeded: "Resource Exceeded",
  internal_error: "Internal Error",
};

export function formatLatency(us: number): string {
  if (!us || us === 0) return "-";
  if (us < 1000) return us + "us";
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

// ─── Views ──────────────────────────────────────────────

import { RoutesView, FilesView } from "./views/manage";
import { ConsoleCore } from "./views/console";

// ─── App ────────────────────────────────────────────────

const TRAFFIC_MAX = 500;
const WS_MESSAGE_MAX = 200;
const ERROR_MAX = 10;
const MAC = typeof navigator !== "undefined" && /Mac/.test(navigator.userAgent);
const CONSOLE_MIN_H = 120;
const CONSOLE_MAX_VH = 70;
const CONSOLE_DEFAULT_H = 300;
const CONSOLE_STORAGE_KEY = "kw_console_height";

const NAV = [
  { path: "/files",  label: "Files" },
  { path: "/routes", label: "Routes" },
];

function getClientY(e: MouseEvent | TouchEvent): number {
  return "touches" in e ? e.touches[0].clientY : e.clientY;
}

interface ToastError { message: string; ts: number; }

function App() {
  // ── State ──
  const [sseStatus, setSseStatus] = createSignal<ConnStatus>("disconnected");
  const [wsStatus, setWsStatus] = createSignal<ConnStatus>("disconnected");
  const [traffic, setTraffic] = createSignal<TrafficEntry[]>([]);
  const [wsMessages, setWsMessages] = createSignal<Record<string, unknown>[]>([]);
  const [scripts] = createSignal<ScriptMeta[]>([]);
  const [drawerOpen, setDrawerOpen] = createSignal(false);
  const [pendingCmd, setPendingCmd] = createSignal<string | null>(null);
  const [dataStartTime, setDataStartTime] = createSignal<number | null>(null);
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

  function pushTraffic(entry: TrafficEntry) {
    if (dataStartTime() === null) setDataStartTime(Date.now());
    setTraffic(prev => { const n = [entry, ...prev]; if (n.length > TRAFFIC_MAX) n.length = TRAFFIC_MAX; return n; });
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

  // ── SSE ──
  let sse: EventSource | null = null;
  let sseRetry: ReturnType<typeof setTimeout> | null = null;
  function connectSSE() {
    if (sse) return;
    setSseStatus("connecting");
    sse = new EventSource("/__keyway/events");
    sse.onopen = () => setSseStatus("connected");
    sse.addEventListener("message", (e) => {
      try {
        const d = JSON.parse(e.data);
        if (d.method && d.path && d.status !== undefined) {
          pushTraffic({
            method: d.method, path: d.path, status: d.status, latency: d.latency || "",
            latency_us: d.latency_us || 0, worker_id: d.worker_id || "", content_type: d.content_type || "",
            header_count: d.header_count || 0, scripts: d.scripts,
            error_message: d.error_message, ts: Date.now(),
          });
        }
      } catch {}
    });
    sse.onerror = () => {
      setSseStatus("disconnected"); sse?.close(); sse = null;
      sseRetry = setTimeout(connectSSE, 3000);
    };
  }

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

  connectSSE();
  connectWS();

  // ── Keyboard shortcuts ──
  function onKeydown(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "k") { e.preventDefault(); setDrawerOpen(!drawerOpen()); }
  }
  document.addEventListener("keydown", onKeydown);
  onCleanup(() => document.removeEventListener("keydown", onKeydown));
  onCleanup(() => {
    if (_wsRetryTimer) clearTimeout(_wsRetryTimer);
    if (sseRetry) clearTimeout(sseRetry);
    if (sse) { sse.close(); sse = null; }
    if (_ws) { _ws.close(); _ws = null; }
  });

  // ── Toast auto-dismiss ──
  createEffect(() => {
    const errs = errors();
    if (!errs.length) return;
    const timers = errs.map(e => setTimeout(() => dismissError(e.ts), Math.max(0, 5000 - (Date.now() - e.ts))));
    onCleanup(() => timers.forEach(clearTimeout));
  });

  const bothDown = () => sseStatus() === "disconnected" && wsStatus() === "disconnected";

  const connStatus = (): ConnStatus => {
    const sse = sseStatus();
    const ws = wsStatus();
    if (sse === "connected" || ws === "connected") return "connected";
    if (sse === "connecting" || ws === "connecting") return "connecting";
    return "disconnected";
  };

  const [wasConnected, setWasConnected] = createSignal(false);
  createEffect(() => {
    if (connStatus() === "connected" && !wasConnected()) setWasConnected(true);
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
              const active = () => currentPath() === route.path || (currentPath() === "/" && route.path === "/files");
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
        <span class={`inline-block w-2 h-2 rounded-full mr-3 ${statusDot(connStatus())} ${connStatus() === "connected" ? "status-live" : ""}`}
              title={`Event stream: ${sseStatus()} | WebSocket: ${wsStatus()}`} />
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
                <div class="text-primary/20 text-2xl mb-2">{"{..}"}</div>
                <div class="text-sm font-semibold text-base-content mb-1">Files</div>
                <div class="text-detail text-base-content/50">Lua scripts, handlers & middleware</div>
              </div>
              <div class="flex-1 border border-base-300 rounded-lg p-4 text-center">
                <div class="text-primary/20 text-2xl mb-2">/api</div>
                <div class="text-sm font-semibold text-base-content mb-1">Routes</div>
                <div class="text-detail text-base-content/50">Auto-created from scripts</div>
              </div>
              <div class="flex-1 border border-base-300 rounded-lg p-4 text-center">
                <div class="text-primary/20 text-2xl mb-2">{">_"}</div>
                <div class="text-sm font-semibold text-base-content mb-1">Console</div>
                <div class="text-detail text-base-content/50">Live REPL &mdash; {MAC ? "Cmd" : "Ctrl"}+K</div>
              </div>
            </div>

            <div class="flex items-center gap-3">
              <button class="btn btn-sm btn-primary flex-1" onClick={() => { dismissWelcome(); navigate("/files"); }}>Browse files</button>
              <button class="btn btn-sm btn-ghost border border-base-300 flex-1" onClick={() => { dismissWelcome(); setDrawerOpen(true); }}>Open console</button>
              <button class="btn btn-sm btn-ghost text-base-content/40" onClick={dismissWelcome}>Skip</button>
            </div>
          </div>
        </div>
      </Show>

      <Show when={bothDown()}>
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
        <Switch fallback={<FilesView onNavigate={navigate} />}>
          <Match when={currentPath() === "/files"}><FilesView onNavigate={navigate} /></Match>
          <Match when={currentPath() === "/routes"}><RoutesView traffic={traffic} onNavigate={navigate} /></Match>
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
              traffic={traffic}
              scripts={scripts}
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
