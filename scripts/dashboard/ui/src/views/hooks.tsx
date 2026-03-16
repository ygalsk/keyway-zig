// Hooks view — webhook endpoint management, metrics panel, capture inspection

import { createSignal, createMemo, For, Show, onMount, onCleanup } from "solid-js";
import { state, type Hook, type HookCapture } from "../state";
import { fetchHooks, createHook, deleteHook, fetchHookCaptures, updateHook } from "../api";
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
  const [configFeedback, setConfigFeedback] = createSignal<{ msg: string; error: boolean } | null>(null);
  let sseSource: EventSource | null = null;

  // Config form state
  const [cfgName, setCfgName] = createSignal("");
  const [cfgStatus, setCfgStatus] = createSignal(200);
  const [cfgBody, setCfgBody] = createSignal("");
  const [cfgCt, setCfgCt] = createSignal("application/json");

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

    const hook = hooks().find(h => h.id === id);
    const cfg = hook?.config || {};
    setCfgName(hook?.name || "");
    setCfgStatus(cfg.response_status || 200);
    setCfgBody(cfg.response_body || "");
    setCfgCt(cfg.response_content_type || "application/json");

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

  async function onSaveConfig() {
    const id = selectedHook();
    if (!id) return;
    try {
      await updateHook(id, {
        name: cfgName(),
        config: {
          response_status: cfgStatus(),
          response_body: cfgBody(),
          response_content_type: cfgCt(),
        },
      });
      setConfigFeedback({ msg: "Saved", error: false });
      await loadHooks();
    } catch {
      setConfigFeedback({ msg: "Save failed", error: true });
    }
    setTimeout(() => setConfigFeedback(null), 3000);
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
    // Captures per minute: count captures in the last 60s
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
              const statusBadge = () => {
                const st = h.config?.response_status || 200;
                const cls = st < 300 ? "badge-success" : st < 400 ? "badge-info" : st < 500 ? "badge-warning" : "badge-error";
                return <span class={`badge badge-xs ${cls}`}>{st}</span>;
              };
              return (
                <div
                  class={`p-2 rounded cursor-pointer text-xs border ${isSelected() ? "border-primary bg-base-200" : "border-base-300 hover:bg-base-200"}`}
                  onClick={() => selectHookById(h.id)}
                >
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-1.5">
                      <span class={`font-mono text-detail ${isSelected() ? "text-primary" : "text-base-content/70"}`}>
                        {h.name ? h.name : `/h/${h.id}`}
                      </span>
                      {statusBadge()}
                    </div>
                    <button
                      class="btn btn-xs btn-ghost text-error"
                      onClick={(e) => { e.stopPropagation(); onDeleteHook(h.id); }}
                    >
                      ×
                    </button>
                  </div>
                  <div class="text-tiny text-base-content/40 mt-0.5 flex items-center gap-2">
                    <span>{h.capture_count} captures</span>
                    <Show when={h.name}><span class="text-base-content/30">|</span><span class="truncate">/h/{h.id}</span></Show>
                  </div>
                </div>
              );
            }}
          </For>
        </div>
      </div>

      {/* Right: Config + Metrics + Captures */}
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

              {/* Config */}
              <div class="border border-base-300 rounded p-3 space-y-2">
                <div class="text-detail text-base-content/50 font-medium mb-1">Configuration</div>
                <div class="grid grid-cols-2 gap-2">
                  <div>
                    <label class="text-tiny text-base-content/40">Name</label>
                    <input class="input input-xs input-bordered w-full bg-base-100 text-body" value={cfgName()} onInput={(e) => setCfgName(e.currentTarget.value)} placeholder="Hook name" />
                  </div>
                  <div>
                    <label class="text-tiny text-base-content/40">Response Status</label>
                    <input class="input input-xs input-bordered w-full bg-base-100 text-body" type="number" value={cfgStatus()} onInput={(e) => setCfgStatus(parseInt(e.currentTarget.value) || 200)} />
                  </div>
                  <div class="col-span-2">
                    <label class="text-tiny text-base-content/40">Response Body</label>
                    <textarea class="textarea textarea-xs textarea-bordered w-full bg-base-100 text-body h-16" placeholder='{"ok":true}' value={cfgBody()} onInput={(e) => setCfgBody(e.currentTarget.value)} />
                  </div>
                  <div class="col-span-2">
                    <label class="text-tiny text-base-content/40">Content-Type</label>
                    <input class="input input-xs input-bordered w-full bg-base-100 text-body" value={cfgCt()} onInput={(e) => setCfgCt(e.currentTarget.value)} />
                  </div>
                </div>
                <div class="flex items-center gap-2 mt-2">
                  <button class="btn btn-xs btn-primary" onClick={onSaveConfig}>Save</button>
                  <Show when={configFeedback()}>
                    {(fb) => <span class={`text-detail ${fb().error ? "text-error" : "text-success"}`}>{fb().msg}</span>}
                  </Show>
                  <span class="ml-auto text-tiny text-base-content/30">→ {cfgStatus()} {cfgCt()}</span>
                </div>
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
