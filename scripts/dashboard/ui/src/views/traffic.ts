// Live Traffic Stream — real-time request log via SSE with click-to-expand

import { store, type TrafficEntry } from "../state";
import { methodBadge, statusBadge } from "../components/badge";
import { navigateWithContext } from "../router";

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function formatTime(ts: number): string {
  const d = new Date(ts);
  return d.toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" })
    + "." + String(d.getMilliseconds()).padStart(3, "0");
}

const MAX_ROWS = 500;

export function mountTraffic(container: HTMLElement): () => void {
  container.innerHTML = `
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Traffic</h2>
        <div class="flex-1"></div>
        <input id="traffic-filter" type="text" placeholder="Filter path..."
          class="input input-xs input-bordered bg-base-100 w-48 text-[11px]" />
        <button id="traffic-pause" class="btn btn-xs btn-ghost text-base-content/50">Pause</button>
        <button id="traffic-clear" class="btn btn-xs btn-ghost text-base-content/50">Clear</button>
      </div>
      <div id="traffic-list" class="flex-1 overflow-y-auto"></div>
    </div>
  `;

  const listEl = container.querySelector<HTMLElement>("#traffic-list")!;
  const filterInput = container.querySelector<HTMLInputElement>("#traffic-filter")!;
  const pauseBtn = container.querySelector<HTMLButtonElement>("#traffic-pause")!;
  const clearBtn = container.querySelector<HTMLButtonElement>("#traffic-clear")!;

  let paused = false;
  let filter = "";
  let expandedIdx: number | null = null;

  function statusColor(s: number): string {
    if (s >= 500) return "text-error";
    if (s >= 400) return "text-warning";
    if (s >= 300) return "text-info";
    if (s >= 200) return "text-success";
    return "text-base-content/50";
  }

  function renderRow(entry: TrafficEntry, idx: number): string {
    const expanded = expandedIdx === idx;
    const scriptCount = entry.scripts?.length || 0;
    const badges = [
      scriptCount > 0 ? `<span class="badge badge-xs badge-primary/30 text-[9px]">${scriptCount} script${scriptCount > 1 ? "s" : ""}</span>` : "",
      entry.hook_id ? `<span class="badge badge-xs badge-info/30 text-[9px] hook-badge" data-hook="${esc(entry.hook_id)}">hook</span>` : "",
    ].filter(Boolean).join("");
    return `
      <div class="traffic-row border-b border-base-300/30 cursor-pointer hover:bg-base-300/30 ${expanded ? "bg-base-300/20" : ""}" data-idx="${idx}">
        <div class="flex items-center gap-2 px-4 py-1.5 text-[11px]">
          <span class="w-[60px] shrink-0">${methodBadge(entry.method)}</span>
          <span class="flex-1 text-base-content/80 truncate">${esc(entry.path)}</span>
          ${badges ? `<span class="flex gap-1 shrink-0">${badges}</span>` : ""}
          <span class="w-[50px] shrink-0 text-right">${statusBadge(entry.status)}</span>
          <span class="w-[70px] shrink-0 text-right text-base-content/50">${entry.latency}</span>
          <span class="w-[40px] shrink-0 text-right text-base-content/30">${entry.worker_id}</span>
        </div>
        ${expanded ? renderDetail(entry) : ""}
      </div>
    `;
  }

  function renderDetail(entry: TrafficEntry): string {
    const scriptsHtml = entry.scripts && entry.scripts.length > 0
      ? `<div><span class="text-base-content/40">Scripts</span> <span class="ml-2">${
          entry.scripts.map((s) => `<a class="text-primary cursor-pointer hover:underline script-link" data-script-id="${esc(s.id)}">${esc(s.name)}</a>`).join(", ")
        }</span></div>`
      : "";
    const hookHtml = entry.hook_id
      ? `<div><span class="text-base-content/40">Hook</span> <a class="text-info cursor-pointer hover:underline ml-2 hook-link" data-hook-id="${esc(entry.hook_id)}">/h/${esc(entry.hook_id)}</a></div>`
      : "";
    return `
      <div class="px-4 py-2 bg-base-200/50 border-t border-base-300/30 text-[10px] space-y-1">
        <div class="grid grid-cols-2 gap-x-6 gap-y-1">
          <div><span class="text-base-content/40">Timestamp</span> <span class="text-base-content/70 ml-2">${formatTime(entry.ts)}</span></div>
          <div><span class="text-base-content/40">Worker</span> <span class="text-base-content/70 ml-2">${entry.worker_id}</span></div>
          <div><span class="text-base-content/40">Path</span> <span class="text-base-content/70 ml-2">${esc(entry.path)}</span></div>
          <div><span class="text-base-content/40">Status</span> <span class="${statusColor(entry.status)} ml-2">${entry.status}</span></div>
          <div><span class="text-base-content/40">Latency</span> <span class="text-base-content/70 ml-2">${entry.latency}${entry.latency_us ? ` (${entry.latency_us}us)` : ""}</span></div>
          <div><span class="text-base-content/40">Content-Type</span> <span class="text-base-content/70 ml-2">${esc(entry.content_type || "-")}</span></div>
          <div><span class="text-base-content/40">Method</span> <span class="text-base-content/70 ml-2">${entry.method}</span></div>
          <div><span class="text-base-content/40">Req Headers</span> <span class="text-base-content/70 ml-2">${entry.header_count || "-"}</span></div>
          ${scriptsHtml}
          ${hookHtml}
        </div>
      </div>
    `;
  }

  function renderAll(entries: TrafficEntry[]): void {
    listEl.innerHTML = entries.slice(0, MAX_ROWS).map((e, i) => renderRow(e, i)).join("");
  }

  function getFiltered(): TrafficEntry[] {
    const all = store.get<TrafficEntry[]>("traffic") || [];
    return filter ? all.filter((e) => e.path.includes(filter)) : all;
  }

  // Click delegation for row expand/collapse + cross-refs
  listEl.addEventListener("click", (e) => {
    const target = e.target as HTMLElement;

    // Script cross-ref link
    const scriptLink = target.closest<HTMLElement>(".script-link");
    if (scriptLink) {
      e.stopPropagation();
      navigateWithContext("/scripts", { navigate_to_script: scriptLink.dataset.scriptId });
      return;
    }

    // Hook cross-ref link
    const hookLink = target.closest<HTMLElement>(".hook-link");
    if (hookLink) {
      e.stopPropagation();
      navigateWithContext("/hooks", { navigate_to_hook: hookLink.dataset.hookId });
      return;
    }

    // Hook badge in row
    const hookBadge = target.closest<HTMLElement>(".hook-badge");
    if (hookBadge) {
      e.stopPropagation();
      navigateWithContext("/hooks", { navigate_to_hook: hookBadge.dataset.hook });
      return;
    }

    const row = target.closest<HTMLElement>(".traffic-row");
    if (!row) return;
    const idx = parseInt(row.dataset.idx || "");
    if (isNaN(idx)) return;
    expandedIdx = expandedIdx === idx ? null : idx;
    renderAll(getFiltered());
  });

  // Apply navigation context
  const navFilter = store.get<string>("navigate_to_traffic_filter");
  if (navFilter) {
    filter = navFilter;
    filterInput.value = navFilter;
    store.set("navigate_to_traffic_filter", undefined);
  }

  // Initial render
  renderAll(getFiltered());

  const unsub = store.on<TrafficEntry[]>("traffic", () => {
    if (paused) return;
    expandedIdx = null;
    renderAll(getFiltered());
  });

  filterInput.addEventListener("input", () => {
    filter = filterInput.value;
    expandedIdx = null;
    renderAll(getFiltered());
  });

  pauseBtn.addEventListener("click", () => {
    paused = !paused;
    pauseBtn.textContent = paused ? "Resume" : "Pause";
    pauseBtn.classList.toggle("text-warning", paused);
    if (!paused) {
      expandedIdx = null;
      renderAll(getFiltered());
    }
  });

  clearBtn.addEventListener("click", () => {
    store.set<TrafficEntry[]>("traffic", []);
    expandedIdx = null;
    listEl.innerHTML = "";
  });

  return () => unsub();
}
