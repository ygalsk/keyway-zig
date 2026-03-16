// Keyway Dashboard — entry point

import { registerRoute, initRouter } from "./router";
import { connectSSE, connectWS } from "./api";
import { createLayout } from "./components/layout";

// Views
import { mountTraffic } from "./views/traffic";
import { mountScripts } from "./views/scripts";
import { mountProbe } from "./views/probe";
import { mountHooks } from "./views/hooks";
import { mountWsTester } from "./views/ws-tester";
import { mountMetrics } from "./views/metrics";

// Register routes
registerRoute("/traffic", "Traffic", "◉", mountTraffic);
registerRoute("/scripts", "Scripts", "λ", mountScripts);
registerRoute("/probe", "Probe", "⇄", mountProbe);
registerRoute("/hooks", "Hooks", "⇥", mountHooks);
registerRoute("/ws", "WebSocket", "⇌", mountWsTester);
registerRoute("/metrics", "Metrics", "▦", mountMetrics);

// Boot
const { content, cleanup } = createLayout();
initRouter(content);
connectSSE();
connectWS();
