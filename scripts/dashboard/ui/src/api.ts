// API client — fetch, SSE, WebSocket wrappers

import { state, type ConnStatus, type TrafficEntry, type Metrics } from "./state";

const BASE = "";
const FETCH_TIMEOUT = 10_000;

// ─── Fetch ──────────────────────────────────────────────

export async function api<T>(
  path: string,
  opts: RequestInit = {}
): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT);
  try {
    const res = await fetch(`${BASE}${path}`, {
      headers: { "Content-Type": "application/json", ...opts.headers as Record<string, string> },
      signal: controller.signal,
      ...opts,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${res.statusText}`);
    const text = await res.text();
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new Error(`Invalid JSON from ${path}: ${text.slice(0, 200)}`);
    }
  } finally {
    clearTimeout(timer);
  }
}

async function apiWithRetry<T>(path: string, opts: RequestInit = {}, retries = 3): Promise<T> {
  for (let i = 0; i < retries; i++) {
    try {
      return await api<T>(path, opts);
    } catch (err) {
      if (i === retries - 1) throw err;
      await new Promise(r => setTimeout(r, 1000 * (i + 1)));
    }
  }
  throw new Error("unreachable");
}

// ─── Debounce utility ───────────────────────────────────

export function debounce<T extends (...args: unknown[]) => void>(fn: T, ms: number): T {
  let timer: ReturnType<typeof setTimeout>;
  return ((...args: unknown[]) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  }) as T;
}

// ─── Metric Polling ─────────────────────────────────────

let metricTimer: ReturnType<typeof setInterval> | null = null;

export function startMetricPolling(): void {
  if (metricTimer) return;
  const s = state();
  async function poll() {
    try {
      const m = await apiWithRetry<Metrics>("/__keyway/api/metrics");
      s.setMetrics(m);
      s.pushMetricSnapshot(m);
    } catch { /* ignore after retries exhausted */ }
  }
  poll();
  metricTimer = setInterval(poll, 5000);
}

export function stopMetricPolling(): void {
  if (metricTimer) {
    clearInterval(metricTimer);
    metricTimer = null;
  }
}

// ─── SSE ────────────────────────────────────────────────

let sse: EventSource | null = null;
let sseRetryTimer: ReturnType<typeof setTimeout> | null = null;

export function connectSSE(): void {
  if (sse) return;
  const s = state();
  s.setSseStatus("connecting");

  sse = new EventSource("/__keyway/events");

  sse.onopen = () => {
    s.setSseStatus("connected");
  };

  sse.addEventListener("message", (e) => {
    try {
      const data = JSON.parse(e.data);
      if (data.method && data.path && data.status !== undefined) {
        const entry: TrafficEntry = {
          method: data.method,
          path: data.path,
          status: data.status,
          latency: data.latency || "",
          latency_us: data.latency_us || 0,
          worker_id: data.worker_id || "",
          content_type: data.content_type || "",
          header_count: data.header_count || 0,
          scripts: data.scripts || undefined,
          hook_id: data.hook_id || undefined,
          error_message: data.error_message || undefined,
          ts: Date.now(),
        };
        s.pushTraffic(entry);
      }
    } catch (err) { console.warn("[keyway] SSE parse error:", err); }
  });

  sse.onerror = () => {
    s.setSseStatus("disconnected");
    sse?.close();
    sse = null;
    sseRetryTimer = setTimeout(connectSSE, 3000);
  };
}

export function disconnectSSE(): void {
  if (sseRetryTimer) clearTimeout(sseRetryTimer);
  sse?.close();
  sse = null;
  state().setSseStatus("disconnected");
}

// ─── WebSocket ──────────────────────────────────────────

let ws: WebSocket | null = null;
let wsRetryTimer: ReturnType<typeof setTimeout> | null = null;

export function connectWS(): void {
  if (ws) return;
  const s = state();
  s.setWsStatus("connecting");

  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/__keyway/ws`);

  ws.onopen = () => {
    s.setWsStatus("connected");
  };

  ws.onmessage = (e) => {
    try {
      const data = JSON.parse(e.data);
      s.pushWsMessage(data);
    } catch (err) { console.warn("[keyway] WS parse error:", err); }
  };

  ws.onclose = () => {
    s.setWsStatus("disconnected");
    ws = null;
    wsRetryTimer = setTimeout(connectWS, 3000);
  };

  ws.onerror = () => {
    ws?.close();
  };
}

export function disconnectWS(): void {
  if (wsRetryTimer) clearTimeout(wsRetryTimer);
  ws?.close();
  ws = null;
  state().setWsStatus("disconnected");
}

export function sendWS(data: object): void {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(data));
  }
}

// ─── Hooks API ──────────────────────────────────────────

export async function fetchHooks(): Promise<{ hooks: { id: string; endpoint: string; capture_count: number; created_at: string }[] }> {
  return api("/__keyway/api/hooks");
}

export async function createHook(): Promise<{ id: string; endpoint: string }> {
  return api("/__keyway/api/hooks", { method: "POST" });
}

export async function deleteHook(id: string): Promise<void> {
  await api(`/__keyway/api/hooks/${id}`, { method: "DELETE" });
}

export async function fetchHookCaptures(id: string): Promise<{ hook: object; requests: object[] }> {
  return api(`/__keyway/api/hooks/${id}`);
}

export async function updateHook(id: string, fields: Record<string, unknown>): Promise<void> {
  await api(`/__keyway/api/hooks/${id}`, { method: "PUT", body: JSON.stringify(fields) });
}

// ─── Effective Config ───────────────────────────────────

export async function fetchEffectiveConfig(): Promise<object> {
  return api("/__keyway/api/config/effective");
}
