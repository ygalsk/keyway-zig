// Metrics Dashboard — JSON polling, clickable cards with drill-down

import { api } from "../api";
import { store, type Metrics, type TrafficEntry, type ScriptMeta } from "../state";
import { methodBadge, statusBadge } from "../components/badge";
import { navigateWithContext } from "../router";

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function formatLatency(us: number): string {
  if (!us || us === 0) return "-";
  if (us < 1000) return us + "us";
  if (us < 1000000) return (us / 1000).toFixed(1) + "ms";
  return (us / 1000000).toFixed(2) + "s";
}

type DrillDown = "errors" | "requests" | "connections" | "scripts" | null;

export function mountMetrics(container: HTMLElement): () => void {
  container.innerHTML = `
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">Metrics</h2>
        <div class="flex-1"></div>
        <button id="metrics-refresh" class="btn btn-xs btn-ghost text-base-content/50">Refresh</button>
      </div>
      <div id="metrics-content" class="flex-1 overflow-y-auto p-4 space-y-4"></div>
    </div>
  `;

  const contentEl = container.querySelector<HTMLElement>("#metrics-content")!;
  const refreshBtn = container.querySelector<HTMLButtonElement>("#metrics-refresh")!;
  let timer: ReturnType<typeof setInterval>;
  let activeDrill: DrillDown = null;
  let lastMetrics: Metrics | null = null;

  async function refresh(): Promise<void> {
    try {
      const m = await api<Metrics>("/__keyway/api/metrics");
      lastMetrics = m;
      renderMetrics(m);
    } catch {
      contentEl.innerHTML = `<div class="text-error">Failed to load metrics</div>`;
    }
  }

  function renderMetrics(m: Metrics): void {
    const lat = m.latency || { min_us: 0, avg_us: 0, max_us: 0 };
    contentEl.innerHTML = `
      <div id="metric-cards" class="grid grid-cols-3 gap-3">
        ${metricCard("requests", "Requests", String(m.total_requests || 0), "text-base-content")}
        ${metricCard("connections", "Connections", String(m.active_connections || 0), "text-info")}
        ${metricCard("errors", "Errors", String(m.total_errors || 0), m.total_errors > 0 ? "text-error" : "text-base-content/50")}
        ${metricCard(null, "Status", m.status || "unknown", m.status === "ok" ? "text-success" : "text-error")}
        ${metricCard(null, "Workers", String(m.worker_count || 0), "text-primary")}
        ${metricCard(null, "Rejected", String(m.rejected_connections || 0), m.rejected_connections > 0 ? "text-warning" : "text-base-content/50")}
        ${metricCard("scripts", "Scripts", "-", "text-primary")}
      </div>
      <div id="drill-down"></div>
      <div class="divider my-2"></div>
      <div class="text-[10px] text-base-content/40 font-medium mb-2">Latency</div>
      <div class="grid grid-cols-3 gap-3">
        ${metricCard(null, "Min", formatLatency(lat.min_us), "text-success")}
        ${metricCard(null, "Avg", formatLatency(lat.avg_us), "text-warning")}
        ${metricCard(null, "Max", formatLatency(lat.max_us), "text-error")}
      </div>
      <div class="divider my-2"></div>
      <div id="metrics-counters"></div>
    `;

    // Attach click handlers to drillable cards
    contentEl.querySelectorAll<HTMLElement>("[data-drill]").forEach((el) => {
      el.addEventListener("click", () => {
        const drill = el.dataset.drill as DrillDown;
        activeDrill = activeDrill === drill ? null : drill;
        renderDrillDown();
      });
    });

    renderDrillDown();
    loadCounters();
  }

  function metricCard(drill: string | null, label: string, value: string, valueClass: string): string {
    const drillAttr = drill ? `data-drill="${drill}"` : "";
    const clickable = drill ? "cursor-pointer hover:bg-base-300 transition-colors" : "";
    const active = drill && activeDrill === drill ? "ring-1 ring-primary/50" : "";
    return `
      <div class="bg-base-200 rounded p-3 ${clickable} ${active}" ${drillAttr}>
        <div class="text-[10px] text-base-content/40">${esc(label)}</div>
        <div class="text-sm font-semibold ${valueClass} mt-0.5">${esc(value)}</div>
      </div>
    `;
  }

  function renderDrillDown(): void {
    const drillEl = contentEl.querySelector<HTMLElement>("#drill-down");
    if (!drillEl) return;

    if (!activeDrill) {
      drillEl.innerHTML = "";
      return;
    }

    const traffic = store.get<TrafficEntry[]>("traffic") || [];

    if (activeDrill === "errors") {
      const errors = traffic.filter((e) => e.status >= 400).slice(0, 20);
      drillEl.innerHTML = `
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Recent Errors (4xx/5xx)</div>
          ${errors.length === 0
            ? `<div class="text-[10px] text-base-content/30">No errors in traffic history</div>`
            : `<div class="space-y-0.5">${errors.map((e) => `
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <span class="w-[50px] shrink-0">${methodBadge(e.method)}</span>
                <span class="flex-1 text-base-content/60 truncate">${esc(e.path)}</span>
                <span>${statusBadge(e.status)}</span>
                <span class="text-base-content/40">${e.latency}</span>
              </div>
            `).join("")}</div>`
          }
        </div>
      `;
    } else if (activeDrill === "requests") {
      const total = traffic.length;
      const methods: Record<string, number> = {};
      for (const e of traffic) {
        methods[e.method] = (methods[e.method] || 0) + 1;
      }
      drillEl.innerHTML = `
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Request Breakdown (from traffic buffer)</div>
          <div class="space-y-0.5">
            <div class="flex items-center gap-2 text-[10px] py-0.5">
              <span class="text-base-content/40 w-20">Total</span>
              <span class="text-base-content/70">${total}</span>
            </div>
            ${Object.entries(methods).sort((a, b) => b[1] - a[1]).map(([m, c]) => `
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <span class="w-20">${methodBadge(m)}</span>
                <span class="text-base-content/70">${c}</span>
                <span class="text-base-content/30">(${total > 0 ? ((c / total) * 100).toFixed(0) : 0}%)</span>
              </div>
            `).join("")}
          </div>
        </div>
      `;
    } else if (activeDrill === "connections") {
      // Show worker distribution from traffic
      const workers: Record<string, number> = {};
      for (const e of traffic) {
        const w = e.worker_id || "-";
        workers[w] = (workers[w] || 0) + 1;
      }
      drillEl.innerHTML = `
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Worker Distribution (from traffic buffer)</div>
          ${Object.keys(workers).length === 0
            ? `<div class="text-[10px] text-base-content/30">No traffic data</div>`
            : `<div class="space-y-0.5">${Object.entries(workers).sort((a, b) => b[1] - a[1]).map(([w, c]) => `
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <span class="text-base-content/40 w-20">Worker ${esc(w)}</span>
                <span class="text-base-content/70">${c} reqs</span>
              </div>
            `).join("")}</div>`
          }
          ${lastMetrics ? `<div class="mt-2 pt-2 border-t border-base-300/30 text-[10px] text-base-content/40">Active connections: ${lastMetrics.active_connections}</div>` : ""}
        </div>
      `;
    } else if (activeDrill === "scripts") {
      drillEl.innerHTML = `
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Loading scripts...</div>
        </div>
      `;
      loadScriptsDrill(drillEl);
    }
  }

  async function loadScriptsDrill(drillEl: HTMLElement): Promise<void> {
    try {
      const data = await api<{ scripts: ScriptMeta[] }>("/__keyway/api/scripts");
      const scripts = data.scripts || [];
      const enabled = scripts.filter((s) => s.enabled);
      drillEl.innerHTML = `
        <div class="mt-3 bg-base-200 rounded p-3">
          <div class="text-[10px] text-base-content/40 font-medium mb-2">Scripts (${enabled.length} enabled / ${scripts.length} total)</div>
          ${scripts.length === 0
            ? `<div class="text-[10px] text-base-content/30">No scripts</div>`
            : `<div class="space-y-0.5">${scripts.map((s) => `
              <div class="flex items-center gap-2 text-[10px] py-0.5">
                <a class="flex-1 text-primary cursor-pointer hover:underline script-nav" data-script-id="${esc(s.id)}">${esc(s.name)}</a>
                <span class="badge badge-xs ${s.enabled ? "badge-success" : "badge-ghost"}">${s.enabled ? "on" : "off"}</span>
                <span class="text-base-content/50 w-16 text-right">${s.metrics.calls} calls</span>
                <span class="text-base-content/40 w-16 text-right">${s.metrics.errors} err</span>
                <span class="text-base-content/40 w-20 text-right">${formatLatency(s.metrics.avg_latency_us)}</span>
              </div>
            `).join("")}</div>`
          }
        </div>
      `;
      // Click delegation for script navigation
      drillEl.querySelectorAll<HTMLElement>(".script-nav").forEach((el) => {
        el.addEventListener("click", () => {
          navigateWithContext("/scripts", { navigate_to_script: el.dataset.scriptId });
        });
      });
    } catch {
      drillEl.innerHTML = `<div class="mt-3 text-error text-[10px]">Failed to load scripts</div>`;
    }
  }

  async function loadCounters(): Promise<void> {
    const countersEl = container.querySelector<HTMLElement>("#metrics-counters");
    if (!countersEl) return;
    try {
      const c = await api<Record<string, number>>("/__keyway/api/counters");
      countersEl.innerHTML = `
        <div class="text-[10px] text-base-content/40 font-medium mb-2">Worker Counters</div>
        <div class="grid grid-cols-3 gap-3">
          ${Object.entries(c).map(([k, v]) => metricCard(null, k.replace(/_/g, " "), String(v), "text-base-content/60")).join("")}
        </div>
      `;
    } catch { /* ignore */ }
  }

  refreshBtn.addEventListener("click", refresh);
  refresh();
  timer = setInterval(refresh, 5000);

  return () => clearInterval(timer);
}
