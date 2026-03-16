// Layout shell — sidebar + topbar + content area

import { store, type ConnStatus } from "../state";
import { getRoutes, navigate } from "../router";

function statusDot(status: ConnStatus): string {
  const color =
    status === "connected"
      ? "bg-success"
      : status === "connecting"
        ? "bg-warning"
        : "bg-error";
  return `<span class="inline-block w-2 h-2 rounded-full ${color}"></span>`;
}

export function createLayout(): { content: HTMLElement; cleanup: () => void } {
  const app = document.getElementById("app")!;
  app.innerHTML = "";

  // Sidebar
  const sidebar = document.createElement("aside");
  sidebar.className =
    "w-48 bg-base-200 border-r border-base-300 flex flex-col shrink-0";

  // Logo
  const logo = document.createElement("div");
  logo.className = "px-4 py-3 border-b border-base-300";
  logo.innerHTML = `<span class="text-primary font-bold text-sm tracking-wide">KEYWAY</span>`;
  sidebar.appendChild(logo);

  // Nav
  const nav = document.createElement("nav");
  nav.className = "flex-1 py-2";
  for (const route of getRoutes()) {
    const a = document.createElement("a");
    a.dataset.nav = route.path;
    a.className =
      "flex items-center gap-2 px-4 py-1.5 text-xs cursor-pointer hover:bg-base-300 text-base-content/70 hover:text-base-content transition-colors [&.active]:text-primary [&.active]:bg-base-300/50";
    a.innerHTML = `<span class="opacity-60">${route.icon}</span> ${route.label}`;
    a.addEventListener("click", () => navigate(route.path));
    nav.appendChild(a);
  }
  sidebar.appendChild(nav);

  // Connection status
  const connStatus = document.createElement("div");
  connStatus.id = "conn-status";
  connStatus.className =
    "px-4 py-2 border-t border-base-300 text-[10px] text-base-content/50 space-y-1";
  sidebar.appendChild(connStatus);

  function updateConnStatus(): void {
    const sseStatus = store.get<ConnStatus>("sse_status") || "disconnected";
    const wsStatus = store.get<ConnStatus>("ws_status") || "disconnected";
    connStatus.innerHTML = `
      <div class="flex items-center gap-1.5">${statusDot(sseStatus)} SSE ${sseStatus}</div>
      <div class="flex items-center gap-1.5">${statusDot(wsStatus)} WS ${wsStatus}</div>
    `;
  }

  const unsub1 = store.on("sse_status", updateConnStatus);
  const unsub2 = store.on("ws_status", updateConnStatus);
  updateConnStatus();

  // Content area
  const main = document.createElement("main");
  main.className = "flex-1 overflow-auto";

  const content = document.createElement("div");
  content.className = "h-full";
  main.appendChild(content);

  // Assemble
  app.className = "flex h-screen bg-base-100 text-base-content text-xs";
  app.appendChild(sidebar);
  app.appendChild(main);

  return {
    content,
    cleanup: () => {
      unsub1();
      unsub2();
    },
  };
}
