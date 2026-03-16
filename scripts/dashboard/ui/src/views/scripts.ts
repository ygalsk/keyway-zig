// Script Editor — centerpiece view

import { store, type ScriptMeta } from "../state";
import { api } from "../api";
import { createEditor } from "../components/editor";

const TEMPLATES: Record<string, { name: string; type: string; pattern: string; code: string }> = {
  rate_limiter: {
    name: "Rate Limiter",
    type: "middleware",
    pattern: "^/api/",
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
    name: "CORS Headers",
    type: "middleware",
    pattern: "^/api/",
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
    name: "Auth Check",
    type: "middleware",
    pattern: "^/api/",
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
    name: "Upstream Proxy",
    type: "handler",
    pattern: "/api/proxy",
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
    name: "Canary Router",
    type: "middleware",
    pattern: "^/api/",
    code: `-- Canary: route 10% of traffic to canary upstream
return function(ctx, next)
  if math.random() < 0.10 then
    ctx.headers["X-Canary"] = "true"
    -- Route to canary upstream here
    -- e.g., modify ctx or use cosocket to proxy
  end
  next()
end`,
  },
  request_logger: {
    name: "Request Logger",
    type: "middleware",
    pattern: ".",
    code: `-- Log all requests with timing (response is a sandbox global)
return function(ctx, next)
  local t0 = response.now_us()
  next()
  local elapsed = math.floor(response.now_us() - t0)
  -- Log is available via SSE traffic stream
  ctx.headers["X-Request-Time-Us"] = tostring(elapsed)
end`,
  },
};

let currentScript: ScriptMeta | null = null;
let editorRef: { getValue: () => string; setValue: (v: string) => void } | null = null;

async function loadScripts(): Promise<ScriptMeta[]> {
  try {
    const data = await api<{ scripts: ScriptMeta[] }>("/__keyway/api/scripts");
    store.set("scripts", data.scripts);
    return data.scripts;
  } catch {
    return [];
  }
}

function renderScriptList(
  listEl: HTMLElement,
  scripts: ScriptMeta[],
  onSelect: (s: ScriptMeta) => void
): void {
  listEl.innerHTML = "";
  if (scripts.length === 0) {
    listEl.innerHTML = `<div class="p-4 text-base-content/30 text-center">No scripts</div>`;
    return;
  }
  for (const s of scripts) {
    const item = document.createElement("div");
    item.className = `px-3 py-2 cursor-pointer hover:bg-base-300 border-b border-base-300/50 ${
      currentScript?.id === s.id ? "bg-base-300/50 border-l-2 border-l-primary" : ""
    }`;
    item.innerHTML = `
      <div class="flex items-center gap-2">
        <span class="font-medium text-base-content/80">${esc(s.name)}</span>
        <span class="ml-auto badge badge-xs ${s.enabled ? "badge-success" : "badge-ghost"}">${s.enabled ? "on" : "off"}</span>
      </div>
      <div class="text-[10px] text-base-content/30 mt-0.5">
        ${s.type} · ${esc(s.pattern)} · ${s.metrics.calls} calls
      </div>
    `;
    item.addEventListener("click", () => onSelect(s));
    listEl.appendChild(item);
  }
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function mountScripts(container: HTMLElement): () => void {
  container.innerHTML = `
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Scripts</h2>
        <div class="flex-1"></div>
        <select id="script-template" class="select select-xs select-bordered bg-base-100 text-[11px]">
          <option value="">Template...</option>
          ${Object.entries(TEMPLATES)
            .map(([k, v]) => `<option value="${k}">${v.name}</option>`)
            .join("")}
        </select>
        <button id="script-new" class="btn btn-xs btn-primary">New</button>
      </div>
      <div class="flex flex-1 overflow-hidden">
        <div id="script-list" class="w-56 border-r border-base-300 overflow-y-auto shrink-0"></div>
        <div class="flex-1 flex flex-col overflow-hidden">
          <div id="script-meta" class="px-4 py-2 border-b border-base-300 bg-base-200/30"></div>
          <div id="script-editor" class="flex-1 overflow-hidden"></div>
          <div id="script-actions" class="flex items-center gap-2 px-4 py-2 border-t border-base-300 bg-base-200/30"></div>
        </div>
      </div>
    </div>
  `;

  const listEl = container.querySelector<HTMLElement>("#script-list")!;
  const metaEl = container.querySelector<HTMLElement>("#script-meta")!;
  const editorEl = container.querySelector<HTMLElement>("#script-editor")!;
  const actionsEl = container.querySelector<HTMLElement>("#script-actions")!;
  const newBtn = container.querySelector<HTMLButtonElement>("#script-new")!;
  const templateSelect = container.querySelector<HTMLSelectElement>("#script-template")!;

  function selectScript(s: ScriptMeta): void {
    currentScript = s;
    renderMeta(s);
    renderEditor(s);
    renderActions(s);
    loadScripts().then((scripts) => renderScriptList(listEl, scripts, selectScript));
  }

  function renderMeta(s: ScriptMeta): void {
    metaEl.innerHTML = `
      <div class="flex items-center gap-3 flex-wrap">
        <input id="meta-name" class="input input-xs input-bordered bg-base-100 w-40 text-[11px]" value="${esc(s.name)}" />
        <select id="meta-type" class="select select-xs select-bordered bg-base-100 text-[11px]">
          <option value="middleware" ${s.type === "middleware" ? "selected" : ""}>Middleware</option>
          <option value="handler" ${s.type === "handler" ? "selected" : ""}>Handler</option>
        </select>
        <input id="meta-pattern" class="input input-xs input-bordered bg-base-100 w-40 text-[11px]" placeholder="Pattern/Path" value="${esc(s.pattern)}" />
        <input id="meta-priority" class="input input-xs input-bordered bg-base-100 w-16 text-[11px]" type="number" placeholder="Pri" value="${s.priority}" />
        <div class="ml-auto flex items-center gap-2 text-[10px] text-base-content/40">
          <span>${s.metrics.calls} calls</span>
          <span>${s.metrics.errors} errors</span>
        </div>
      </div>
    `;
  }

  function renderEditor(s: ScriptMeta): void {
    editorEl.innerHTML = "";
    editorRef = createEditor(editorEl, { value: s.code });
  }

  function renderActions(s: ScriptMeta): void {
    actionsEl.innerHTML = `
      <button id="action-save" class="btn btn-xs btn-primary">Deploy</button>
      <button id="action-toggle" class="btn btn-xs ${s.enabled ? "btn-warning" : "btn-success"}">${s.enabled ? "Disable" : "Enable"}</button>
      <button id="action-test" class="btn btn-xs btn-ghost">Test</button>
      <div class="flex-1"></div>
      <button id="action-delete" class="btn btn-xs btn-error btn-ghost">Delete</button>
    `;

    actionsEl.querySelector("#action-save")!.addEventListener("click", async () => {
      if (!currentScript) return;
      const name = (metaEl.querySelector<HTMLInputElement>("#meta-name")!).value;
      const type = (metaEl.querySelector<HTMLSelectElement>("#meta-type")!).value;
      const pattern = (metaEl.querySelector<HTMLInputElement>("#meta-pattern")!).value;
      const priority = parseInt((metaEl.querySelector<HTMLInputElement>("#meta-priority")!).value) || 0;
      const code = editorRef?.getValue() || "";

      await api(`/__keyway/api/scripts/${currentScript.id}`, {
        method: "PUT",
        body: JSON.stringify({ name, type, pattern, priority, code }),
      });
      const scripts = await loadScripts();
      const updated = scripts.find((s) => s.id === currentScript!.id);
      if (updated) selectScript(updated);
    });

    actionsEl.querySelector("#action-toggle")!.addEventListener("click", async () => {
      if (!currentScript) return;
      await api(`/__keyway/api/scripts/${currentScript.id}/toggle`, { method: "POST" });
      const scripts = await loadScripts();
      const updated = scripts.find((s) => s.id === currentScript!.id);
      if (updated) selectScript(updated);
    });

    actionsEl.querySelector("#action-test")!.addEventListener("click", async () => {
      if (!currentScript) return;
      const result = await api<{ output: string }>(`/__keyway/api/scripts/${currentScript.id}/test`, {
        method: "POST",
        body: JSON.stringify({ method: "GET", path: currentScript.pattern, headers: {}, body: "" }),
      });
      alert(JSON.stringify(result, null, 2));
    });

    actionsEl.querySelector("#action-delete")!.addEventListener("click", async () => {
      if (!currentScript) return;
      if (!confirm(`Delete "${currentScript.name}"?`)) return;
      await api(`/__keyway/api/scripts/${currentScript.id}`, { method: "DELETE" });
      currentScript = null;
      editorEl.innerHTML = `<div class="flex items-center justify-center h-full text-base-content/20">Select or create a script</div>`;
      metaEl.innerHTML = "";
      actionsEl.innerHTML = "";
      const scripts = await loadScripts();
      renderScriptList(listEl, scripts, selectScript);
    });
  }

  newBtn.addEventListener("click", async () => {
    const result = await api<{ script: ScriptMeta }>("/__keyway/api/scripts", {
      method: "POST",
      body: JSON.stringify({
        name: "New Script",
        type: "middleware",
        pattern: ".",
        priority: 0,
        code: '-- New script\nreturn function(ctx, next)\n  next()\nend',
      }),
    });
    const scripts = await loadScripts();
    selectScript(result.script);
  });

  templateSelect.addEventListener("change", async () => {
    const key = templateSelect.value;
    if (!key) return;
    const tmpl = TEMPLATES[key];
    const result = await api<{ script: ScriptMeta }>("/__keyway/api/scripts", {
      method: "POST",
      body: JSON.stringify({
        name: tmpl.name,
        type: tmpl.type,
        pattern: tmpl.pattern,
        priority: 0,
        code: tmpl.code,
      }),
    });
    templateSelect.value = "";
    const scripts = await loadScripts();
    selectScript(result.script);
  });

  // Initial load — check for navigation context
  editorEl.innerHTML = `<div class="flex items-center justify-center h-full text-base-content/20">Select or create a script</div>`;
  loadScripts().then((scripts) => {
    renderScriptList(listEl, scripts, selectScript);
    const navId = store.get<string>("navigate_to_script");
    if (navId) {
      store.set("navigate_to_script", undefined);
      const target = scripts.find((s) => s.id === navId);
      if (target) selectScript(target);
    }
  });

  return () => {
    currentScript = null;
    editorRef = null;
  };
}
