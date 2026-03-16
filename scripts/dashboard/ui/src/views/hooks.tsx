// Hooks view — webhook endpoint management, capture inspection

import { createSignal, createMemo, For, Show, onMount, onCleanup } from "solid-js";
import { state, type Hook, type HookCapture } from "../state";
import { fetchHooks, createHook, deleteHook, fetchHookCaptures } from "../api";
import { MethodBadge } from "../components/badge";
import { formatTime } from "./format";

function relativeTime(ts: number): string {
  const delta = Math.floor((Date.now() - ts) / 1000);
  if (delta < 5) return "just now";
  if (delta < 60) return `${delta}s ago`;
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  return `${Math.floor(delta / 3600)}h ago`;
}

export function Hooks() {
  const [hooks, setHooks] = createSignal<Hook[]>([]);
  const [selectedHook, setSelectedHook] = createSignal<string | null>(null);
  const [captures, setCaptures] = createSignal<HookCapture[]>([]);
  let sseSource: EventSource | null = null;

  async function loadHooks() {
    try {
      const data = await fetchHooks();
      setHooks((data.hooks || []) as Hook[]);
    } catch { /* ignore */ }
  }

  async function onCreateHook() {
    await createHook();
    await loadHooks();
  }

  async function onDeleteHook(id: string) {
    await deleteHook(id);
    if (selectedHook() === id) {
      setSelectedHook(null);
      setCaptures([]);
    }
    await loadHooks();
  }

  async function selectHookById(id: string) {
    setSelectedHook(id);

    // Load existing captures
    try {
      const data = await fetchHookCaptures(id);
      setCaptures((data.requests || []) as HookCapture[]);
    } catch { /* ignore */ }

    // Connect SSE for live updates
    if (sseSource) sseSource.close();
    sseSource = new EventSource(`/__keyway/api/hooks/${id}/events`);
    sseSource.addEventListener("message", (e) => {
      try {
        const cap = JSON.parse(e.data) as HookCapture;
        setCaptures(prev => [{ ...cap, ts: Date.now() }, ...prev].slice(0, 100));
      } catch { /* ignore */ }
    });
  }

  async function onCopyEndpoint() {
    const id = selectedHook();
    if (!id) return;
    try {
      await navigator.clipboard.writeText(`${location.origin}/h/${id}`);
    } catch { /* clipboard API not available */ }
  }

  // Metrics computed from captures
  const captureMetrics = createMemo(() => {
    const caps = captures();
    const total = caps.length;
    const methodCounts: Record<string, number> = {};
    let lastTs = 0;
    for (const c of caps) {
      methodCounts[c.method] = (methodCounts[c.method] || 0) + 1;
      if (c.ts && c.ts > lastTs) lastTs = c.ts;
    }
    const now = Date.now();
    const recentCount = caps.filter(c => c.ts && (now - c.ts) < 60000).length;
    return {
      total,
      rate: recentCount,
      lastTs,
      methods: Object.entries(methodCounts).sort((a, b) => b[1] - a[1]),
    };
  });

  onMount(() => { loadHooks(); });
  onCleanup(() => { if (sseSource) sseSource.close(); });

  return (
    <div class="p-4 h-full flex gap-3">
      {/* Left: Hook list */}
      <div class="w-64 shrink-0 flex flex-col gap-2">
        <div class="flex items-center justify-between">
          <h2 class="text-sm font-semibold text-base-content">Hooks</h2>
          <button class="btn btn-xs btn-primary" onClick={onCreateHook}>+ New</button>
        </div>
        <div class="flex-1 overflow-auto space-y-1">
          <For each={hooks()}>
            {(h) => {
              const isSelected = () => h.id === selectedHook();
              return (
                <div
                  class={`p-2 rounded cursor-pointer text-xs border ${isSelected() ? "border-primary bg-base-200" : "border-base-300 hover:bg-base-200"}`}
                  onClick={() => selectHookById(h.id)}
                >
                  <div class="flex items-center justify-between">
                    <span class={`font-mono text-detail ${isSelected() ? "text-primary" : "text-base-content/70"}`}>
                      /h/{h.id}
                    </span>
                    <button
                      class="btn btn-xs btn-ghost text-error"
                      onClick={(e) => { e.stopPropagation(); onDeleteHook(h.id); }}
                    >
                      ×
                    </button>
                  </div>
                  <div class="text-tiny text-base-content/40 mt-0.5">
                    {h.capture_count} captures
                  </div>
                </div>
              );
            }}
          </For>
        </div>
      </div>

      {/* Right: Metrics + Captures */}
      <div class="flex-1 flex flex-col gap-2 min-w-0">
        <Show when={selectedHook()}>
          {(hookId) => (
            <>
              {/* Header */}
              <div class="flex items-center gap-2 text-detail text-base-content/40">
                <span>Endpoint:</span>
                <code class="text-primary select-all">{`${location.origin}/h/${hookId()}`}</code>
                <button class="btn btn-xs btn-ghost text-base-content/40" title="Copy endpoint URL" onClick={onCopyEndpoint}>⎘</button>
                <span class="ml-auto">Live</span>
              </div>

              {/* Metrics panel */}
              <div class="border border-base-300 rounded p-3">
                <div class="text-detail text-base-content/50 font-medium mb-2">Metrics</div>
                <div class="grid grid-cols-3 gap-3 text-center text-detail">
                  <div>
                    <div class="text-base-content/40">Total captures</div>
                    <div class="text-base-content/80 font-semibold text-sm">{captureMetrics().total}</div>
                  </div>
                  <div>
                    <div class="text-base-content/40">Rate (last 60s)</div>
                    <div class="text-base-content/80 font-semibold text-sm">{captureMetrics().rate}/min</div>
                  </div>
                  <div>
                    <div class="text-base-content/40">Last capture</div>
                    <div class="text-base-content/80 font-semibold text-sm">
                      {captureMetrics().lastTs ? relativeTime(captureMetrics().lastTs) : "never"}
                    </div>
                  </div>
                </div>
                <Show when={captureMetrics().methods.length > 0}>
                  <div class="mt-2 space-y-0.5">
                    <For each={captureMetrics().methods}>
                      {([method, count]) => {
                        const pct = () => captureMetrics().total > 0 ? ((count / captureMetrics().total) * 100).toFixed(0) : "0";
                        return (
                          <div class="flex items-center gap-2 text-detail">
                            <MethodBadge method={method} />
                            <div class="flex-1 bg-base-300 rounded-full h-1.5">
                              <div class="bg-primary/50 h-1.5 rounded-full" style={{ width: `${pct()}%` }} />
                            </div>
                            <span class="text-base-content/50 w-14 text-right">{count} ({pct()}%)</span>
                          </div>
                        );
                      }}
                    </For>
                  </div>
                </Show>
              </div>

              {/* Captures */}
              <div class="flex-1 overflow-auto">
                <Show when={captures().length > 0} fallback={
                  <div class="text-center text-base-content/30 text-xs py-8">No captures yet. Send a request to the endpoint.</div>
                }>
                  <For each={captures()}>
                    {(c) => (
                      <div class="border border-base-300 rounded p-2 mb-2 text-detail">
                        <div class="flex items-center gap-2 mb-1">
                          <MethodBadge method={c.method} />
                          <span class="text-base-content/70 truncate">{c.path}</span>
                          <span class="ml-auto text-base-content/30">{c.ts ? formatTime(c.ts) : ""}</span>
                        </div>
                        <Show when={c.headers}>
                          <div class="text-base-content/40 mb-1">
                            <For each={Object.entries(c.headers)}>
                              {([k, v]) => <div>{k}: {v}</div>}
                            </For>
                          </div>
                        </Show>
                        <Show when={c.body}>
                          <pre class="bg-base-300 rounded p-1 mt-1 text-base-content/70 overflow-x-auto">{c.body}</pre>
                        </Show>
                      </div>
                    )}
                  </For>
                </Show>
              </div>
            </>
          )}
        </Show>
      </div>
    </div>
  );
}
