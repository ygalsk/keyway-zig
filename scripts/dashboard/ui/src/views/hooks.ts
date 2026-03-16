// Webhook Catcher — create endpoints, capture requests in real-time

import { api } from "../api";
import { store } from "../state";

interface Hook {
  id: string;
  created_at: string;
  request_count: number;
}

interface CapturedRequest {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: string;
  ts: string;
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function mountHooks(container: HTMLElement): () => void {
  container.innerHTML = `
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Webhooks</h2>
        <div class="flex-1"></div>
        <button id="hooks-create" class="btn btn-xs btn-primary">New Endpoint</button>
      </div>
      <div class="flex flex-1 overflow-hidden">
        <div id="hooks-list" class="w-56 border-r border-base-300 overflow-y-auto shrink-0"></div>
        <div id="hooks-detail" class="flex-1 overflow-y-auto p-4">
          <div class="flex items-center justify-center h-full text-base-content/20">Select or create an endpoint</div>
        </div>
      </div>
    </div>
  `;

  const listEl = container.querySelector<HTMLElement>("#hooks-list")!;
  const detailEl = container.querySelector<HTMLElement>("#hooks-detail")!;
  const createBtn = container.querySelector<HTMLButtonElement>("#hooks-create")!;
  let currentHook: string | null = null;
  let hookSSE: EventSource | null = null;

  async function loadHooks(): Promise<void> {
    try {
      const data = await api<{ hooks: Hook[] }>("/__keyway/api/hooks");
      renderList(data.hooks);
    } catch { /* ignore */ }
  }

  function renderList(hooks: Hook[]): void {
    listEl.innerHTML = "";
    if (hooks.length === 0) {
      listEl.innerHTML = `<div class="p-4 text-base-content/30 text-center">No endpoints</div>`;
      return;
    }
    for (const h of hooks) {
      const item = document.createElement("div");
      item.className = `px-3 py-2 cursor-pointer hover:bg-base-300 border-b border-base-300/50 ${
        currentHook === h.id ? "bg-base-300/50 border-l-2 border-l-primary" : ""
      }`;
      item.innerHTML = `
        <div class="font-medium text-base-content/80 text-[11px]">/h/${esc(h.id)}</div>
        <div class="text-[10px] text-base-content/30">${h.request_count} captured</div>
      `;
      item.addEventListener("click", () => selectHook(h.id));
      listEl.appendChild(item);
    }
  }

  async function selectHook(id: string): Promise<void> {
    currentHook = id;
    if (hookSSE) hookSSE.close();

    detailEl.innerHTML = `
      <div class="space-y-3">
        <div class="flex items-center gap-2">
          <code class="text-primary text-[11px]">${location.origin}/h/${esc(id)}</code>
          <button id="hook-copy" class="btn btn-xs btn-ghost">Copy</button>
          <div class="flex-1"></div>
          <button id="hook-delete" class="btn btn-xs btn-error btn-ghost">Delete</button>
        </div>
        <div class="text-[10px] text-base-content/40">
          curl -X POST ${location.origin}/h/${esc(id)} -d '{"test":true}'
        </div>
        <div class="divider my-1"></div>
        <div id="hook-requests" class="space-y-2"></div>
      </div>
    `;

    detailEl.querySelector("#hook-copy")!.addEventListener("click", () => {
      navigator.clipboard.writeText(`${location.origin}/h/${id}`);
    });

    detailEl.querySelector("#hook-delete")!.addEventListener("click", async () => {
      if (!confirm("Delete this endpoint?")) return;
      await api(`/__keyway/api/hooks/${id}`, { method: "DELETE" });
      currentHook = null;
      detailEl.innerHTML = `<div class="flex items-center justify-center h-full text-base-content/20">Select or create an endpoint</div>`;
      loadHooks();
    });

    // Load existing captures
    try {
      const data = await api<{ requests: CapturedRequest[] }>(`/__keyway/api/hooks/${id}`);
      renderCaptures(data.requests || []);
    } catch { /* ignore */ }

    // SSE for real-time captures
    hookSSE = new EventSource(`/__keyway/api/hooks/${id}/events`);
    hookSSE.addEventListener("capture", (e) => {
      try {
        const req = JSON.parse(e.data) as CapturedRequest;
        const reqEl = document.getElementById("hook-requests");
        if (reqEl) {
          const div = document.createElement("div");
          div.innerHTML = renderCapture(req);
          reqEl.insertBefore(div.firstElementChild!, reqEl.firstChild);
        }
      } catch { /* ignore */ }
    });

    loadHooks();
  }

  function renderCaptures(requests: CapturedRequest[]): void {
    const el = container.querySelector<HTMLElement>("#hook-requests");
    if (!el) return;
    el.innerHTML = requests.length
      ? requests.map(renderCapture).join("")
      : `<div class="text-base-content/20 text-center">No captures yet</div>`;
  }

  function renderCapture(r: CapturedRequest): string {
    return `
      <div class="bg-base-200 p-2 rounded space-y-1">
        <div class="flex items-center gap-2">
          <span class="method-${r.method} font-semibold text-[11px]">${r.method}</span>
          <span class="text-base-content/50 text-[10px]">${esc(r.path || "")}</span>
          <span class="ml-auto text-[10px] text-base-content/20">${r.ts || ""}</span>
        </div>
        ${r.body ? `<pre class="text-[10px] text-base-content/40 whitespace-pre-wrap max-h-20 overflow-auto">${esc(r.body)}</pre>` : ""}
      </div>
    `;
  }

  createBtn.addEventListener("click", async () => {
    const data = await api<{ hook: Hook }>("/__keyway/api/hooks", { method: "POST" });
    await loadHooks();
    selectHook(data.hook.id);
  });

  loadHooks().then(() => {
    const navId = store.get<string>("navigate_to_hook");
    if (navId) {
      store.set("navigate_to_hook", undefined);
      selectHook(navId);
    }
  });

  return () => {
    if (hookSSE) hookSSE.close();
  };
}
