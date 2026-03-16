// Reactive state — Solid signals + stores

import { createSignal, createRoot } from "solid-js";
import { createStore, produce } from "solid-js/store";

// Connection status
export type ConnStatus = "connected" | "connecting" | "disconnected";

export interface TrafficEntry {
  method: string;
  path: string;
  status: number;
  latency: string;
  latency_us: number;
  worker_id: string;
  content_type: string;
  header_count: number;
  scripts?: { id: string; name: string }[];
  hook_id?: string;
  error_message?: string;
  ts: number;
}

export interface ScriptMeta {
  id: string;
  name: string;
  type: "middleware" | "handler";
  pattern: string;
  priority: number;
  enabled: boolean;
  code: string;
  metrics: { calls: number; errors: number; avg_latency_us: number };
  trigger_condition?: string;
  created_at: string;
  updated_at: string;
}

export interface Metrics {
  status: string;
  worker_count: number;
  total_requests: number;
  active_connections: number;
  total_errors: number;
  rejected_connections: number;
  latency: { min_us: number; avg_us: number; max_us: number };
}

export interface MetricSnapshot {
  ts: number;
  requests: number;
  errors: number;
  connections: number;
  avg_latency_us: number;
}

export interface Route {
  method: string;
  pattern: string;
  handler: string;
  middleware: string[];
  hits: number;
  errors: number;
  avg_latency_us: number;
  type?: string;
}

export interface WorkerInfo {
  id: number;
  requests: number;
  errors: number;
  active_connections: number;
  avg_latency_us: number;
  counters: Record<string, number>;
}

// Invocation taxonomy
export type InvocationState =
  | "success"
  | "client_error"
  | "client_disconnect"
  | "script_error"
  | "timeout"
  | "resource_exceeded"
  | "internal_error";

export function classifyInvocation(entry: TrafficEntry): InvocationState {
  if (entry.status >= 200 && entry.status < 400) return "success";
  if (entry.status === 499) return "client_disconnect";
  if (entry.status >= 400 && entry.status < 500) return "client_error";
  if (entry.status === 504) return "timeout";
  if (entry.status === 503) return "resource_exceeded";
  if (entry.status >= 500) return "internal_error";
  return "success";
}

export const INVOCATION_LABELS: Record<InvocationState, string> = {
  success: "Success",
  client_error: "Client Error",
  client_disconnect: "Client Disconnect",
  script_error: "Script Error",
  timeout: "Timeout",
  resource_exceeded: "Resource Exceeded",
  internal_error: "Internal Error",
};

export const INVOCATION_COLORS: Record<InvocationState, string> = {
  success: "text-success",
  client_error: "text-warning",
  client_disconnect: "text-base-content/40",
  script_error: "text-error",
  timeout: "text-warning",
  resource_exceeded: "text-secondary",
  internal_error: "text-error",
};

// Hooks
export interface Hook {
  id: string;
  endpoint: string;
  capture_count: number;
  created_at: string;
  name?: string;
  enabled?: boolean;
  config?: {
    response_status?: number;
    response_body?: string;
    response_content_type?: string;
  };
}

export interface HookCapture {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: string;
  ts: number;
}

// Active stats
export interface ActiveStat {
  key: string;
  value: number;
  delta: number;
  rate: number;
}

// Traffic filters
export interface TrafficFilters {
  method: string | null;
  status_family: string | null;
  invocation_state: InvocationState | null;
  path_pattern: string | null;
  worker_id: string | null;
  paused: boolean;
}

// ─── Global Signals ──────────────────────────────────────
// Created in a root so they live for the app lifetime.

const TRAFFIC_MAX = 500;
const METRIC_HISTORY_MAX = 60;

function createAppState() {
  const [sseStatus, setSseStatus] = createSignal<ConnStatus>("disconnected");
  const [wsStatus, setWsStatus] = createSignal<ConnStatus>("disconnected");
  const [metrics, setMetrics] = createSignal<Metrics | null>(null);
  const [traffic, setTraffic] = createSignal<TrafficEntry[]>([]);
  const [metricHistory, setMetricHistory] = createSignal<MetricSnapshot[]>([]);
  const [wsMessages, setWsMessages] = createSignal<Record<string, unknown>[]>([]);
  const [scripts, setScripts] = createSignal<ScriptMeta[]>([]);
  const [drawerOpen, setDrawerOpen] = createSignal(false);
  const [pendingConsoleCmd, setPendingConsoleCmd] = createSignal<string | null>(null);

  // Navigation context — ephemeral values consumed once
  const [navContext, setNavContext] = createSignal<Record<string, unknown>>({});

  function pushTraffic(entry: TrafficEntry) {
    setTraffic(prev => {
      const next = [entry, ...prev];
      if (next.length > TRAFFIC_MAX) next.length = TRAFFIC_MAX;
      return next;
    });
  }

  function pushMetricSnapshot(m: Metrics) {
    setMetricHistory(prev => {
      const entry: MetricSnapshot = {
        ts: Date.now(),
        requests: m.total_requests || 0,
        errors: m.total_errors || 0,
        connections: m.active_connections || 0,
        avg_latency_us: m.latency?.avg_us || 0,
      };
      const base = prev.length >= METRIC_HISTORY_MAX ? prev.slice(1) : prev;
      return [...base, entry];
    });
  }

  function pushWsMessage(msg: Record<string, unknown>) {
    setWsMessages(prev => {
      const base = prev.length >= 200 ? prev.slice(1) : prev;
      return [...base, { ...msg, _ts: Date.now() }];
    });
  }

  function consumeNavContext(key: string): unknown {
    const ctx = navContext();
    const val = ctx[key];
    if (val !== undefined) {
      setNavContext(prev => {
        const next = { ...prev };
        delete next[key];
        return next;
      });
    }
    return val;
  }

  function setNavContextValues(values: Record<string, unknown>) {
    setNavContext(prev => ({ ...prev, ...values }));
  }

  return {
    sseStatus, setSseStatus,
    wsStatus, setWsStatus,
    metrics, setMetrics,
    traffic, setTraffic,
    metricHistory, setMetricHistory,
    wsMessages, setWsMessages,
    scripts, setScripts,
    drawerOpen, setDrawerOpen,
    pendingConsoleCmd, setPendingConsoleCmd,
    navContext, setNavContext,
    pushTraffic,
    pushMetricSnapshot,
    pushWsMessage,
    consumeNavContext,
    setNavContextValues,
  };
}

// Singleton app state
let _state: ReturnType<typeof createAppState>;

export function initState() {
  _state = createRoot(() => createAppState());
}

export function state() {
  return _state;
}
