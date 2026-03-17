// Reactive state — Solid signals + stores

import { createSignal, createRoot } from "solid-js";

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
  created_at: string;
  updated_at: string;
}

export interface Route {
  method: string;
  pattern: string;
  handler: string;
  middleware: string[];
  type?: string;
}

export interface WorkerInfo {
  id: number;
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
  client_disconnect: "text-base-content/50",
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
}

export interface HookCapture {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: string;
  ts: number;
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

// Toast errors
export interface ToastError {
  message: string;
  ts: number;
}

// ─── Global Signals ──────────────────────────────────────
// Created in a root so they live for the app lifetime.

const TRAFFIC_MAX = 500;

function createAppState() {
  const [sseStatus, setSseStatus] = createSignal<ConnStatus>("disconnected");
  const [wsStatus, setWsStatus] = createSignal<ConnStatus>("disconnected");
  const [traffic, setTraffic] = createSignal<TrafficEntry[]>([]);
  const [wsMessages, setWsMessages] = createSignal<Record<string, unknown>[]>([]);
  const [scripts, setScripts] = createSignal<ScriptMeta[]>([]);
  const [drawerOpen, setDrawerOpen] = createSignal(false);
  const [pendingConsoleCmd, setPendingConsoleCmd] = createSignal<string | null>(null);
  const [dataStartTime, setDataStartTime] = createSignal<number | null>(null);
  const [errors, setErrors] = createSignal<ToastError[]>([]);

  function pushTraffic(entry: TrafficEntry) {
    // Track when first data arrives
    if (dataStartTime() === null) setDataStartTime(Date.now());
    setTraffic(prev => {
      const next = [entry, ...prev];
      if (next.length > TRAFFIC_MAX) next.length = TRAFFIC_MAX;
      return next;
    });
  }

  function pushWsMessage(msg: Record<string, unknown>) {
    setWsMessages(prev => {
      const base = prev.length >= 200 ? prev.slice(1) : prev;
      return [...base, { ...msg, _ts: Date.now() }];
    });
  }

  function pushError(message: string) {
    setErrors(prev => [...prev.slice(-9), { message, ts: Date.now() }]);
  }

  function dismissError(ts: number) {
    setErrors(prev => prev.filter(e => e.ts !== ts));
  }

  return {
    sseStatus, setSseStatus,
    wsStatus, setWsStatus,
    traffic, setTraffic,
    wsMessages, setWsMessages,
    scripts, setScripts,
    drawerOpen, setDrawerOpen,
    pendingConsoleCmd, setPendingConsoleCmd,
    dataStartTime, setDataStartTime,
    errors, setErrors,
    pushTraffic,
    pushWsMessage,
    pushError,
    dismissError,
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
