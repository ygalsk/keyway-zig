// Layout shell — sidebar + content + console drawer

import { createSignal, createEffect, onCleanup, For, Show, type JSX } from "solid-js";
import { state, type ConnStatus } from "../state";
import { Drawer } from "./drawer";

const isMac = typeof navigator !== "undefined" && /Mac/.test(navigator.userAgent);
const shortcutLabel = isMac ? "Cmd+K" : "Ctrl+K";

export interface RouteEntry {
  path: string;
  label: string;
  icon: string;
  group: string;
}

function StatusDot(props: { status: ConnStatus }) {
  const color = () =>
    props.status === "connected"
      ? "bg-success"
      : props.status === "connecting"
        ? "bg-warning status-connecting"
        : "bg-error";
  return (
    <span
      class={`inline-block w-2 h-2 rounded-full ${color()}`}
      aria-label={`Connection ${props.status}`}
    />
  );
}

export function Layout(props: {
  routes: RouteEntry[];
  currentPath: () => string;
  onNavigate: (path: string) => void;
  children: JSX.Element;
}) {
  const s = state();
  const [sidebarOpen, setSidebarOpen] = createSignal(false);
  const [shortcutsOpen, setShortcutsOpen] = createSignal(false);

  // Group routes
  const routesByGroup = () => {
    const groups = new Map<string, RouteEntry[]>();
    for (const r of props.routes) {
      let list = groups.get(r.group);
      if (!list) { list = []; groups.set(r.group, list); }
      list.push(r);
    }
    return groups;
  };

  function toggleDrawer() {
    s.setDrawerOpen(!s.drawerOpen());
  }

  function onKeydown(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key === "k") {
      e.preventDefault();
      toggleDrawer();
    }
    if (e.key === "?" && !e.metaKey && !e.ctrlKey && !(e.target as HTMLElement).matches("input,textarea,select")) {
      e.preventDefault();
      setShortcutsOpen(!shortcutsOpen());
    }
  }

  // Bind via property to avoid Solid's babel transform intercepting addEventListener
  const doc = document;
  doc.addEventListener("keydown", onKeydown);
  onCleanup(() => doc.removeEventListener("keydown", onKeydown));

  const bothDown = () => s.sseStatus() === "disconnected" && s.wsStatus() === "disconnected";

  return (
    <div class="flex h-screen bg-base-100 text-base-content text-xs">
      {/* Mobile hamburger */}
      <button
        class="fixed top-2 left-2 z-50 btn btn-xs btn-ghost sm:hidden"
        aria-label="Toggle navigation"
        onClick={() => setSidebarOpen(!sidebarOpen())}
      >
        ☰
      </button>

      {/* Mobile overlay */}
      <Show when={sidebarOpen()}>
        <div
          class="fixed inset-0 bg-black/50 z-30 sm:hidden"
          onClick={() => setSidebarOpen(false)}
        />
      </Show>

      {/* Sidebar */}
      <aside
        role="navigation"
        aria-label="Main navigation"
        class={`w-48 bg-base-200 border-r border-base-300 flex flex-col shrink-0 max-md:w-12 max-sm:fixed max-sm:inset-y-0 max-sm:left-0 max-sm:z-40 max-sm:w-48 max-sm:transition-transform max-sm:duration-300 ${
          sidebarOpen() ? "max-sm:translate-x-0" : "max-sm:-translate-x-full"
        }`}
        id="sidebar"
      >
        {/* Logo */}
        <div class="px-4 py-3 border-b border-base-300 max-md:px-2 max-md:text-center">
          <span class="text-primary font-bold text-sm tracking-wide max-md:text-detail">KEYWAY</span>
        </div>

        {/* Nav */}
        <nav class="flex-1 py-1 overflow-y-auto">
          <For each={[...routesByGroup().entries()]}>
            {([group, groupRoutes]) => (
              <>
                <div class="px-4 pt-3 pb-1 text-tiny font-semibold tracking-widest text-base-content/30 uppercase max-md:hidden">
                  {group}
                </div>
                <For each={groupRoutes}>
                  {(route) => {
                    const isActive = () => props.currentPath() === route.path;
                    return (
                      <a
                        data-nav={route.path}
                        role="link"
                        tabindex="0"
                        class={`flex items-center gap-2 px-4 py-1.5 text-xs cursor-pointer hover:bg-base-300 text-base-content/80 hover:text-base-content transition-colors max-md:justify-center max-md:px-0 max-md:py-2 ${
                          isActive() ? "active text-primary bg-base-300 border-l-2 border-l-primary" : ""
                        }`}
                        onClick={() => { props.onNavigate(route.path); setSidebarOpen(false); }}
                        onKeyDown={(e) => { if (e.key === "Enter") props.onNavigate(route.path); }}
                      >
                        <span class="opacity-40 max-md:opacity-100 max-md:text-sm" title={route.label}>
                          {route.icon}
                        </span>
                        <span class="max-md:hidden">{route.label}</span>
                      </a>
                    );
                  }}
                </For>
              </>
            )}
          </For>
        </nav>

        {/* Console trigger */}
        <div
          class="px-4 py-2 border-t border-base-300 cursor-pointer hover:bg-primary/10 text-base-content/60 hover:text-primary transition-colors text-xs flex items-center gap-2 max-md:justify-center max-md:px-0"
          onClick={toggleDrawer}
        >
          <span class="text-primary/70">{">_"}</span>
          <span class="max-md:hidden flex items-center gap-1">
            Console
            <kbd class="kbd kbd-xs text-tiny ml-auto">{shortcutLabel}</kbd>
          </span>
        </div>

        {/* Connection status */}
        <div
          id="conn-status"
          role="status"
          aria-live="polite"
          class="px-4 py-2 border-t border-base-300 text-detail text-base-content/50 space-y-1 max-md:px-1 max-md:text-center"
        >
          <div class="flex items-center gap-1.5 max-md:justify-center">
            <StatusDot status={s.sseStatus()} />
            <span class="max-md:hidden">SSE {s.sseStatus()}</span>
          </div>
          <div class="flex items-center gap-1.5 max-md:justify-center">
            <StatusDot status={s.wsStatus()} />
            <span class="max-md:hidden">WS {s.wsStatus()}</span>
          </div>
        </div>
      </aside>

      {/* Main area */}
      <div role="main" class="flex-1 flex flex-col overflow-hidden max-sm:ml-0">
        {/* Degradation banner */}
        <Show when={bothDown()}>
          <div class="bg-warning/10 border-b border-warning/30 text-warning text-detail px-4 py-1.5 text-center">
            Live stream disconnected. Reconnecting...
          </div>
        </Show>

        {/* Content */}
        <div id="main-content" tabindex="-1" class="flex-1 overflow-auto">
          {props.children}
        </div>

        {/* Console drawer */}
        <Drawer />
      </div>

      {/* Shortcuts overlay */}
      <Show when={shortcutsOpen()}>
        <div
          id="kw-shortcuts"
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
          onClick={(e) => { if (e.target === e.currentTarget) setShortcutsOpen(false); }}
        >
          <div class="bg-base-200 border border-base-300 rounded-lg p-6 max-w-sm w-full mx-4 shadow-xl">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-sm font-semibold text-base-content">Keyboard Shortcuts</h3>
              <button class="btn btn-xs btn-ghost" onClick={() => setShortcutsOpen(false)}>×</button>
            </div>
            <div class="space-y-2 text-detail">
              <div class="flex justify-between">
                <span class="text-base-content/60">Toggle Console</span>
                <kbd class="kbd kbd-xs">{shortcutLabel}</kbd>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Show Shortcuts</span>
                <kbd class="kbd kbd-xs">?</kbd>
              </div>
            </div>
          </div>
        </div>
      </Show>
    </div>
  );
}
