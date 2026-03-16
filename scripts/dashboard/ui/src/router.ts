// Hash-based SPA router

import { store } from "./state";

export type ViewMount = (container: HTMLElement) => (() => void) | void;

interface Route {
  path: string;
  label: string;
  icon: string;
  mount: ViewMount;
}

const routes: Route[] = [];
let currentCleanup: (() => void) | void;
let container: HTMLElement | null = null;

export function registerRoute(
  path: string,
  label: string,
  icon: string,
  mount: ViewMount
): void {
  routes.push({ path, label, icon, mount });
}

export function getRoutes(): readonly Route[] {
  return routes;
}

export function navigate(path: string): void {
  location.hash = path;
}

export function navigateWithContext(path: string, ctx: Record<string, unknown>): void {
  for (const [k, v] of Object.entries(ctx)) store.set(k, v);
  navigate(path);
}

export function initRouter(el: HTMLElement): void {
  container = el;

  window.addEventListener("hashchange", () => render());
  render();
}

function render(): void {
  if (!container) return;

  const hash = location.hash.slice(1) || routes[0]?.path || "/traffic";
  const route = routes.find((r) => r.path === hash) || routes[0];

  if (!route) return;

  // Cleanup previous view
  if (currentCleanup) currentCleanup();
  container.innerHTML = "";

  // Mount new view
  currentCleanup = route.mount(container);

  // Update active nav
  document.querySelectorAll("[data-nav]").forEach((el) => {
    const navEl = el as HTMLElement;
    if (navEl.dataset.nav === route.path) {
      navEl.classList.add("active");
    } else {
      navEl.classList.remove("active");
    }
  });
}
