// API client — fetch, SSE, WebSocket wrappers

import { store, type ConnStatus, type TrafficEntry } from "./state";

const BASE = "";

// ─── Fetch ──────────────────────────────────────────────

export async function api<T>(
  path: string,
  opts: RequestInit = {}
): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json", ...opts.headers as Record<string, string> },
    ...opts,
  });
  return res.json() as Promise<T>;
}

// ─── SSE ────────────────────────────────────────────────

let sse: EventSource | null = null;
let sseRetryTimer: ReturnType<typeof setTimeout> | null = null;

export function connectSSE(): void {
  if (sse) return;
  store.set<ConnStatus>("sse_status", "connecting");

  sse = new EventSource("/__keyway/events");

  sse.onopen = () => {
    store.set<ConnStatus>("sse_status", "connected");
  };

  // JSON data events (traffic + generic)
  sse.addEventListener("message", (e) => {
    try {
      const data = JSON.parse(e.data);
      // Traffic entry: has method + path + status fields
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
          ts: Date.now(),
        };
        store.update<TrafficEntry[]>("traffic", (prev) => {
          const list = prev || [];
          const next = [entry, ...list];
          return next.length > 500 ? next.slice(0, 500) : next;
        });
      } else {
        store.set("sse_event", data);
      }
    } catch { /* ignore non-JSON */ }
  });

  sse.onerror = () => {
    store.set<ConnStatus>("sse_status", "disconnected");
    sse?.close();
    sse = null;
    sseRetryTimer = setTimeout(connectSSE, 3000);
  };
}

export function disconnectSSE(): void {
  if (sseRetryTimer) clearTimeout(sseRetryTimer);
  sse?.close();
  sse = null;
  store.set<ConnStatus>("sse_status", "disconnected");
}

// ─── WebSocket ──────────────────────────────────────────

let ws: WebSocket | null = null;
let wsRetryTimer: ReturnType<typeof setTimeout> | null = null;

export function connectWS(): void {
  if (ws) return;
  store.set<ConnStatus>("ws_status", "connecting");

  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/__keyway/ws`);

  ws.onopen = () => {
    store.set<ConnStatus>("ws_status", "connected");
  };

  ws.onmessage = (e) => {
    try {
      const data = JSON.parse(e.data);
      store.update<object[]>("ws_messages", (prev) => {
        const list = prev || [];
        const next = [...list, { ...data, _ts: Date.now() }];
        return next.length > 200 ? next.slice(-200) : next;
      });
    } catch { /* ignore */ }
  };

  ws.onclose = () => {
    store.set<ConnStatus>("ws_status", "disconnected");
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
  store.set<ConnStatus>("ws_status", "disconnected");
}

export function sendWS(data: object): void {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(data));
  }
}
