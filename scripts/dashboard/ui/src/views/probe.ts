// HTTP Probe — request any URL, inspect response

import { api } from "../api";

interface ProbeResult {
  status: number;
  headers: [string, string][];
  timing_ms: number;
  body_preview: string;
  error?: string;
}

const SECURITY_HEADERS = new Set([
  "strict-transport-security", "content-security-policy", "x-content-type-options",
  "x-frame-options", "x-xss-protection", "referrer-policy", "permissions-policy",
]);
const CACHE_HEADERS = new Set([
  "cache-control", "etag", "last-modified", "expires", "age", "vary",
]);

function classifyHeader(name: string): string {
  const lower = name.toLowerCase();
  if (SECURITY_HEADERS.has(lower)) return "text-success";
  if (CACHE_HEADERS.has(lower)) return "text-info";
  return "text-base-content/50";
}

function statusColor(s: number): string {
  if (s >= 200 && s < 300) return "status-2xx";
  if (s >= 300 && s < 400) return "status-3xx";
  if (s >= 400 && s < 500) return "status-4xx";
  if (s >= 500) return "status-5xx";
  return "";
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function mountProbe(container: HTMLElement): () => void {
  container.innerHTML = `
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">HTTP Probe</h2>
      </div>
      <div class="p-4 space-y-4 overflow-y-auto flex-1">
        <div class="flex gap-2">
          <input id="probe-url" type="text" placeholder="https://example.com"
            class="input input-sm input-bordered bg-base-100 flex-1 text-[11px]" />
          <button id="probe-send" class="btn btn-sm btn-primary">Probe</button>
        </div>
        <div id="probe-result"></div>
        <div id="probe-history" class="space-y-2"></div>
      </div>
    </div>
  `;

  const urlInput = container.querySelector<HTMLInputElement>("#probe-url")!;
  const sendBtn = container.querySelector<HTMLButtonElement>("#probe-send")!;
  const resultEl = container.querySelector<HTMLElement>("#probe-result")!;
  const historyEl = container.querySelector<HTMLElement>("#probe-history")!;

  const history: { url: string; status: number; timing_ms: number }[] = [];

  async function doProbe(): Promise<void> {
    const url = urlInput.value.trim();
    if (!url) return;

    sendBtn.disabled = true;
    sendBtn.textContent = "...";
    resultEl.innerHTML = `<div class="text-base-content/30">Probing...</div>`;

    try {
      const r = await api<ProbeResult>("/__keyway/api/probe", {
        method: "POST",
        body: JSON.stringify({ url }),
      });

      if (r.error) {
        resultEl.innerHTML = `<div class="text-error">${esc(r.error)}</div>`;
        return;
      }

      history.unshift({ url, status: r.status, timing_ms: r.timing_ms });
      if (history.length > 10) history.pop();
      renderHistory();

      const headerRows = r.headers
        .map(([n, v]) => `<tr><td class="${classifyHeader(n)} whitespace-nowrap pr-3">${esc(n)}</td><td class="text-base-content/70 break-all">${esc(v)}</td></tr>`)
        .join("");

      resultEl.innerHTML = `
        <div class="space-y-3">
          <div class="flex items-center gap-3">
            <span class="${statusColor(r.status)} text-lg font-bold">${r.status}</span>
            <span class="text-base-content/40">${r.timing_ms}ms</span>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-xs"><tbody>${headerRows}</tbody></table>
          </div>
          ${r.body_preview ? `<div class="bg-base-200 p-2 rounded text-[10px] text-base-content/60 max-h-40 overflow-auto whitespace-pre-wrap">${esc(r.body_preview)}</div>` : ""}
        </div>
      `;
    } catch (e) {
      resultEl.innerHTML = `<div class="text-error">Probe failed: ${e}</div>`;
    } finally {
      sendBtn.disabled = false;
      sendBtn.textContent = "Probe";
    }
  }

  function renderHistory(): void {
    historyEl.innerHTML = history.length
      ? `<div class="text-[10px] text-base-content/30 mb-1">History</div>` +
        history
          .map(
            (h) =>
              `<div class="flex items-center gap-2 text-[10px] text-base-content/40 cursor-pointer hover:text-base-content/60" data-url="${esc(h.url)}">
                <span class="${statusColor(h.status)}">${h.status}</span>
                <span class="truncate flex-1">${esc(h.url)}</span>
                <span>${h.timing_ms}ms</span>
              </div>`
          )
          .join("")
      : "";

    historyEl.querySelectorAll("[data-url]").forEach((el) => {
      el.addEventListener("click", () => {
        urlInput.value = (el as HTMLElement).dataset.url || "";
      });
    });
  }

  sendBtn.addEventListener("click", doProbe);
  urlInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") doProbe();
  });

  return () => {};
}
