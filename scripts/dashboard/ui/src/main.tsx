// Keyway Dashboard — entry point (Solid.js)

import { render } from "solid-js/web";
import { createSignal, lazy, Match, Switch } from "solid-js";
import { initState, state } from "./state";
import { connectSSE, connectWS, startMetricPolling } from "./api";
import { Layout, type RouteEntry } from "./components/layout";

// Views
import { Overview } from "./views/overview";
import { Traffic } from "./views/traffic";
import { Workers } from "./views/workers";
import { Routes } from "./views/routes";
import { Scripts } from "./views/scripts";
import { Hooks } from "./views/hooks";

const routes: RouteEntry[] = [
  // OBSERVE
  { group: "observe", path: "/", label: "Overview", icon: "◉" },
  { group: "observe", path: "/traffic", label: "Traffic", icon: "▤" },
  { group: "observe", path: "/workers", label: "Workers", icon: "▦" },
  // MANAGE
  { group: "manage", path: "/routes", label: "Routes", icon: "⇄" },
  { group: "manage", path: "/scripts", label: "Scripts", icon: "λ" },
  { group: "manage", path: "/hooks", label: "Hooks", icon: "↩" },
];

function App() {
  const s = state();
  const [currentPath, setCurrentPath] = createSignal(location.hash.slice(1) || "/");

  function navigate(path: string, ctx?: Record<string, unknown>) {
    if (ctx) s.setNavContextValues(ctx);
    location.hash = path;
    setCurrentPath(path);
  }

  function openConsole(cmd?: string) {
    if (cmd) s.setPendingConsoleCmd(cmd);
    s.setDrawerOpen(true);
  }

  // Listen for hash changes (back/forward)
  // Use onhashchange to avoid Solid's babel transform intercepting addEventListener
  window.onhashchange = () => {
    setCurrentPath(location.hash.slice(1) || "/");
  };

  return (
    <Layout routes={routes} currentPath={currentPath} onNavigate={navigate}>
      <Switch fallback={<Overview onNavigate={navigate} onOpenConsole={openConsole} />}>
        <Match when={currentPath() === "/"}><Overview onNavigate={navigate} onOpenConsole={openConsole} /></Match>
        <Match when={currentPath() === "/traffic"}><Traffic onNavigate={navigate} /></Match>
        <Match when={currentPath() === "/workers"}><Workers onNavigate={navigate} /></Match>
        <Match when={currentPath() === "/routes"}><Routes onNavigate={navigate} /></Match>
        <Match when={currentPath() === "/scripts"}><Scripts /></Match>
        <Match when={currentPath() === "/hooks"}><Hooks /></Match>
      </Switch>
    </Layout>
  );
}

// Boot
initState();
render(() => <App />, document.getElementById("app")!);
connectSSE();
connectWS();
startMetricPolling();
