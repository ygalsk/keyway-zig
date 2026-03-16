// Script Editor — Solid.js version

import { createSignal, createMemo, For, Show, onMount } from "solid-js";
import { state, type ScriptMeta, type TrafficEntry } from "../state";
import { api } from "../api";
import { Editor, type EditorHandle } from "../components/editor";
import { SectionHeader } from "../components/section-header";
import { MethodBadge, StatusBadge } from "../components/badge";
import { formatLatency, formatTime } from "./format";

const TEMPLATES: Record<string, { name: string; type: string; pattern: string; code: string }> = {
  rate_limiter: {
    name: "Rate Limiter", type: "middleware", pattern: "^/api/",
    code: `-- Rate limiter: 100 req/min per path
local counters = {}
local window = 60

return function(ctx, next)
  local key = ctx.path
  local now = os.time()
  local entry = counters[key]

  if not entry or (now - entry.ts) > window then
    counters[key] = { ts = now, count = 1 }
    next()
    return
  end

  entry.count = entry.count + 1
  if entry.count > 100 then
    ctx.status = 429
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"error":"rate limit exceeded"}'
    return
  end

  next()
end`,
  },
  cors: {
    name: "CORS Headers", type: "middleware", pattern: "^/api/",
    code: `-- CORS middleware
return function(ctx, next)
  ctx.headers["Access-Control-Allow-Origin"] = "*"
  ctx.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
  ctx.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"

  if ctx.method == "OPTIONS" then
    ctx.status = 204
    return
  end

  next()
end`,
  },
  auth_check: {
    name: "Auth Check", type: "middleware", pattern: "^/api/",
    code: `-- Bearer token auth check
local TOKEN = "changeme"

return function(ctx, next)
  local auth = nil
  for _, h in ipairs(ctx.request_headers) do
    if h[1]:lower() == "authorization" then
      auth = h[2]
      break
    end
  end

  if not auth or auth ~= "Bearer " .. TOKEN then
    ctx.status = 401
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"error":"unauthorized"}'
    return
  end

  next()
end`,
  },
  upstream_proxy: {
    name: "Upstream Proxy", type: "handler", pattern: "/api/proxy",
    code: `-- Proxy requests to upstream (socket, dns are sandbox globals)
return function(ctx)
  local ip = dns.resolve_host("httpbin.org")
  if not ip then
    ctx.status = 502
    ctx.body = '{"error":"dns failed"}'
    return
  end

  local tcp = socket.tcp()
  tcp:settimeout(5000)
  local ok = tcp:connect(ip, 80)
  if not ok then
    ctx.status = 502
    ctx.body = '{"error":"connect failed"}'
    return
  end

  tcp:send("GET /get HTTP/1.1\\r\\nHost: httpbin.org\\r\\nConnection: close\\r\\n\\r\\n")
  tcp:receive("*l") -- status
  while true do
    local line = tcp:receive("*l")
    if not line or line == "" then break end
  end
  local body = tcp:receive("*a") or ""
  tcp:close()

  ctx.status = 200
  ctx.headers["Content-Type"] = "application/json"
  ctx.body = body
end`,
  },
  canary_router: {
    name: "Canary Router", type: "middleware", pattern: "^/api/",
    code: `-- Canary: route 10% of traffic to canary upstream
return function(ctx, next)
  if math.random() < 0.10 then
    ctx.headers["X-Canary"] = "true"
  end
  next()
end`,
  },
  request_logger: {
    name: "Request Logger", type: "middleware", pattern: ".",
    code: `-- Log all requests with timing (response is a sandbox global)
return function(ctx, next)
  local t0 = response.now_us()
  next()
  local elapsed = math.floor(response.now_us() - t0)
  ctx.headers["X-Request-Time-Us"] = tostring(elapsed)
end`,
  },
};

export function Scripts() {
  const s = state();
  const [scripts, setScripts] = createSignal<ScriptMeta[]>([]);
  const [currentScript, setCurrentScript] = createSignal<ScriptMeta | null>(null);
  const [feedback, setFeedback] = createSignal<{ msg: string; error: boolean } | null>(null);
  const [testResult, setTestResult] = createSignal<string | null>(null);
  let editorHandle: EditorHandle | null = null;
  let feedbackTimer: ReturnType<typeof setTimeout> | null = null;

  // Meta fields
  const [metaName, setMetaName] = createSignal("");
  const [metaType, setMetaType] = createSignal<"middleware" | "handler">("middleware");
  const [metaPattern, setMetaPattern] = createSignal("");
  const [metaPriority, setMetaPriority] = createSignal(0);

  async function loadScripts(): Promise<ScriptMeta[]> {
    try {
      const data = await api<{ scripts: ScriptMeta[] }>("/__keyway/api/scripts");
      setScripts(data.scripts);
      s.setScripts(data.scripts);
      return data.scripts;
    } catch {
      return [];
    }
  }

  function selectScript(sc: ScriptMeta) {
    setCurrentScript(sc);
    setMetaName(sc.name);
    setMetaType(sc.type);
    setMetaPattern(sc.pattern);
    setMetaPriority(sc.priority);
    setTestResult(null);
    editorHandle?.setValue(sc.code);
  }

  function showFeedback(msg: string, isError: boolean) {
    setFeedback({ msg, error: isError });
    if (feedbackTimer) clearTimeout(feedbackTimer);
    feedbackTimer = setTimeout(() => setFeedback(null), 3000);
  }

  async function onToggle(sc: ScriptMeta) {
    try {
      await api(`/__keyway/api/scripts/${sc.id}/toggle`, { method: "POST" });
    } catch { /* ignore */ }
    const loaded = await loadScripts();
    const updated = loaded.find(s => s.id === sc.id);
    if (updated && currentScript()?.id === sc.id) selectScript(updated);
  }

  async function onSave() {
    const cs = currentScript();
    if (!cs) return;
    try {
      await api(`/__keyway/api/scripts/${cs.id}`, {
        method: "PUT",
        body: JSON.stringify({
          name: metaName(),
          type: metaType(),
          pattern: metaPattern(),
          priority: metaPriority(),
          code: editorHandle?.getValue() || "",
        }),
      });
      showFeedback("Deployed", false);
      const loaded = await loadScripts();
      const updated = loaded.find(s => s.id === cs.id);
      if (updated) selectScript(updated);
    } catch (e) {
      showFeedback("Deploy failed: " + e, true);
    }
  }

  async function onToggleCurrent() {
    const cs = currentScript();
    if (!cs) return;
    try {
      await api(`/__keyway/api/scripts/${cs.id}/toggle`, { method: "POST" });
      const loaded = await loadScripts();
      const updated = loaded.find(s => s.id === cs.id);
      if (updated) {
        selectScript(updated);
        showFeedback(updated.enabled ? "Enabled" : "Disabled", false);
      }
    } catch (e) {
      showFeedback("Toggle failed: " + e, true);
    }
  }

  async function onTest() {
    const cs = currentScript();
    if (!cs) return;
    setTestResult("loading");
    try {
      const result = await api<Record<string, unknown>>(`/__keyway/api/scripts/${cs.id}/test`, {
        method: "POST",
        body: JSON.stringify({ method: "GET", path: cs.pattern, headers: {}, body: "" }),
      });
      setTestResult(JSON.stringify(result));
    } catch (e) {
      setTestResult(`error:${e}`);
    }
  }

  async function onDelete() {
    const cs = currentScript();
    if (!cs) return;
    if (!confirm(`Delete "${cs.name}"?`)) return;
    try {
      await api(`/__keyway/api/scripts/${cs.id}`, { method: "DELETE" });
      setCurrentScript(null);
      setTestResult(null);
      await loadScripts();
    } catch (e) {
      showFeedback("Delete failed: " + e, true);
    }
  }

  async function onNew() {
    const result = await api<{ script: ScriptMeta }>("/__keyway/api/scripts", {
      method: "POST",
      body: JSON.stringify({ name: "New Script", type: "middleware", pattern: ".", priority: 0, code: '-- New script\nreturn function(ctx, next)\n  next()\nend' }),
    });
    await loadScripts();
    selectScript(result.script);
  }

  async function onTemplate(key: string) {
    if (!key) return;
    const tmpl = TEMPLATES[key];
    const result = await api<{ script: ScriptMeta }>("/__keyway/api/scripts", {
      method: "POST",
      body: JSON.stringify({ name: tmpl.name, type: tmpl.type, pattern: tmpl.pattern, priority: 0, code: tmpl.code }),
    });
    await loadScripts();
    selectScript(result.script);
  }

  onMount(() => {
    loadScripts().then((loaded) => {
      const navName = s.consumeNavContext("navigate_to_script_name") as string | undefined;
      if (navName) {
        const target = loaded.find(s => s.name === navName);
        if (target) selectScript(target);
      }
    });
  });

  // Recent activity for current script — filter traffic by script name
  const recentActivity = createMemo(() => {
    const cs = currentScript();
    if (!cs) return [];
    return s.traffic()
      .filter(e => e.scripts?.some(sc => sc.id === cs.id || sc.name === cs.name))
      .slice(0, 20);
  });

  // Parse error line number from test result error string
  function parseErrorLine(error: string): number | null {
    const match = error.match(/:(\d+):/);
    return match ? parseInt(match[1], 10) : null;
  }

  return (
    <div class="flex flex-col h-full">
      <SectionHeader title="Scripts">
        <select
          class="select select-xs select-bordered bg-base-100 text-body"
          onChange={(e) => { onTemplate(e.currentTarget.value); e.currentTarget.value = ""; }}
        >
          <option value="">Template...</option>
          <For each={Object.entries(TEMPLATES)}>
            {([k, v]) => <option value={k}>{v.name}</option>}
          </For>
        </select>
        <button class="btn btn-xs btn-primary" onClick={onNew}>New</button>
      </SectionHeader>

      <div class="flex flex-1 overflow-hidden">
        {/* Script list */}
        <div class="w-64 border-r border-base-300 overflow-y-auto shrink-0">
          <Show when={scripts().length > 0} fallback={<div class="p-4 text-base-content/50 text-center">No scripts</div>}>
            <For each={scripts()}>
              {(sc) => (
                <div
                  class={`px-3 py-2 cursor-pointer hover:bg-base-300 border-b border-base-300/50 ${currentScript()?.id === sc.id ? "bg-base-300/50 border-l-2 border-l-primary" : ""}`}
                  onClick={() => selectScript(sc)}
                >
                  <div class="flex items-center gap-2">
                    <span class="font-medium text-base-content/80 flex-1 truncate">{sc.name}</span>
                    <input
                      type="checkbox"
                      class="toggle toggle-xs toggle-primary"
                      checked={sc.enabled}
                      onClick={(e) => { e.stopPropagation(); onToggle(sc); }}
                    />
                  </div>
                  <div class="text-detail text-base-content/50 mt-0.5 flex items-center gap-2">
                    <span class={`badge badge-xs ${sc.type === "handler" ? "badge-info" : "badge-ghost"}`}>{sc.type}</span>
                    <span class="truncate">{sc.pattern}</span>
                    <span class="ml-auto">{sc.metrics.calls}c</span>
                    <span class={sc.metrics.errors > 0 ? "text-error" : ""}>{sc.metrics.errors}e</span>
                    <span>{formatLatency(sc.metrics.avg_latency_us)}</span>
                  </div>
                </div>
              )}
            </For>
          </Show>
        </div>

        {/* Editor panel */}
        <div class="flex-1 flex flex-col overflow-hidden">
          <Show when={currentScript()} fallback={
            <div class="flex items-center justify-center h-full text-base-content/30">Select or create a script</div>
          }>
            {(cs) => (
              <>
                {/* Meta */}
                <div class="px-4 py-2 border-b border-base-300 bg-base-200/30">
                  <div class="flex items-center gap-3 flex-wrap">
                    <input class="input input-xs input-bordered bg-base-100 w-40 text-body" value={metaName()} onInput={(e) => setMetaName(e.currentTarget.value)} />
                    <select class="select select-xs select-bordered bg-base-100 text-body" value={metaType()} onChange={(e) => setMetaType(e.currentTarget.value as "middleware" | "handler")}>
                      <option value="middleware">Middleware</option>
                      <option value="handler">Handler</option>
                    </select>
                    <input class="input input-xs input-bordered bg-base-100 w-40 text-body" placeholder="Pattern/Path" value={metaPattern()} onInput={(e) => setMetaPattern(e.currentTarget.value)} />
                    <input class="input input-xs input-bordered bg-base-100 w-16 text-body" type="number" placeholder="Pri" value={metaPriority()} onInput={(e) => setMetaPriority(parseInt(e.currentTarget.value) || 0)} />
                    <div class="ml-auto flex items-center gap-2 text-detail text-base-content/50">
                      <span>{cs().metrics.calls} calls</span>
                      <span>{cs().metrics.errors} errors</span>
                    </div>
                  </div>
                </div>

                {/* Editor */}
                <div class="flex-1 overflow-hidden">
                  <Editor
                    value={cs().code}
                    ref={(h) => { editorHandle = h; }}
                    highlightLine={(() => {
                      const tr = testResult();
                      if (!tr || tr === "loading" || tr.startsWith("error:")) return undefined;
                      try {
                        const parsed = JSON.parse(tr);
                        if (parsed.error) return parseErrorLine(String(parsed.error)) ?? undefined;
                      } catch {}
                      return undefined;
                    })()}
                  />
                </div>

                {/* Test result */}
                <Show when={testResult()}>
                  {(tr) => {
                    if (tr() === "loading") return <div class="border-t border-base-300 bg-base-200/50 p-3 text-detail text-base-content/50">Testing...</div>;
                    if (tr().startsWith("error:")) return <div class="border-t border-base-300 bg-base-200/50 p-3 text-detail text-error">Test failed: {tr().slice(6)}</div>;
                    try {
                      const result = JSON.parse(tr()) as Record<string, unknown>;
                      const success = result.success as boolean;
                      const errorStr = result.error ? String(result.error) : null;
                      return (
                        <div class="border-t border-base-300 bg-base-200/50 p-3 max-h-48 overflow-y-auto text-detail space-y-1">
                          <div class="flex items-center gap-2">
                            <span class={`${success ? "text-success" : "text-error"} font-semibold`}>{success ? "PASS" : "FAIL"}</span>
                            {result.timing_us && <span class="text-base-content/40">{String(result.timing_us)}us</span>}
                          </div>
                          {errorStr && (
                            <pre class="text-error whitespace-pre-wrap bg-base-300 rounded p-2 font-mono overflow-auto max-h-32">{errorStr}</pre>
                          )}
                          {result.result && <pre class="text-base-content/80 whitespace-pre-wrap">{JSON.stringify(result.result, null, 2)}</pre>}
                        </div>
                      );
                    } catch { return null; }
                  }}
                </Show>

                {/* Recent Activity */}
                <Show when={recentActivity().length > 0}>
                  <div class="border-t border-base-300 bg-base-200/30 max-h-36 overflow-y-auto">
                    <div class="px-3 py-1 text-tiny text-base-content/40 font-medium sticky top-0 bg-base-200/30">RECENT ACTIVITY</div>
                    <For each={recentActivity()}>
                      {(e) => (
                        <div class="flex items-center gap-2 text-detail px-3 py-0.5 hover:bg-base-300/30">
                          <span class="text-base-content/50 w-[55px] shrink-0">{formatTime(e.ts)}</span>
                          <MethodBadge method={e.method} />
                          <span class="text-base-content/50 flex-1 truncate">{e.path}</span>
                          <StatusBadge status={e.status} />
                          <span class="text-base-content/50 w-[50px] text-right">{formatLatency(e.latency_us)}</span>
                          <Show when={e.error_message}>
                            <span class="text-error truncate max-w-[150px]" title={e.error_message}>!</span>
                          </Show>
                        </div>
                      )}
                    </For>
                  </div>
                </Show>

                {/* Actions */}
                <div class="flex items-center gap-2 px-4 py-2 border-t border-base-300 bg-base-200/30">
                  <button class="btn btn-xs btn-primary" onClick={onSave}>Deploy</button>
                  <button class={`btn btn-xs ${cs().enabled ? "btn-warning" : "btn-success"}`} onClick={onToggleCurrent}>
                    {cs().enabled ? "Disable" : "Enable"}
                  </button>
                  <button class="btn btn-xs btn-ghost" onClick={onTest}>Test</button>
                  <div class="flex-1" />
                  <button class="btn btn-xs btn-error btn-ghost" onClick={onDelete}>Delete</button>
                  <Show when={feedback()}>
                    {(fb) => <span class={`text-detail ml-2 ${fb().error ? "text-error" : "text-success"}`}>{fb().msg}</span>}
                  </Show>
                </div>
              </>
            )}
          </Show>
        </div>
      </div>
    </div>
  );
}
