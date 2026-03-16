// Minimal reactive store — pub/sub over typed keys

type Listener<T> = (value: T) => void;

class Store {
  private data: Map<string, unknown> = new Map();
  private listeners: Map<string, Set<Listener<unknown>>> = new Map();

  get<T>(key: string): T | undefined {
    return this.data.get(key) as T | undefined;
  }

  set<T>(key: string, value: T): void {
    this.data.set(key, value);
    const subs = this.listeners.get(key);
    if (subs) subs.forEach((fn) => fn(value));
  }

  update<T>(key: string, fn: (prev: T | undefined) => T): void {
    this.set(key, fn(this.get<T>(key)));
  }

  on<T>(key: string, fn: Listener<T>): () => void {
    let subs = this.listeners.get(key);
    if (!subs) {
      subs = new Set();
      this.listeners.set(key, subs);
    }
    subs.add(fn as Listener<unknown>);
    return () => subs!.delete(fn as Listener<unknown>);
  }
}

export const store = new Store();

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
