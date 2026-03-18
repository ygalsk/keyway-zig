// Console — REPL with command history, JSON highlighting, onboarding UX

import { createSignal, createEffect, For, Show, onMount, onCleanup } from "solid-js";
import {
  type TrafficEntry, type ScriptMeta, api, sendWS, fetchEffectiveConfig, startStream,
  classifyInvocation, INVOCATION_LABELS, formatTime,
} from "../main";

interface LogEntry { type: "cmd" | "response" | "error"; text: string; ts: number; }

function timeGreeting(): string {
  const h = new Date().getHours();
  if (h < 6) return "Burning the midnight oil?";
  if (h < 12) return "Good morning";
  if (h < 17) return "Good afternoon";
  if (h < 21) return "Good evening";
  return "Late night hacking?";
}

const COMMANDS: { label: string; cmds: { name: string; desc: string }[] }[] = [
  { label: "inspect", cmds: [
    { name: "ping", desc: "Check server connection" },
    { name: "routes", desc: "List routes" }, { name: "scripts", desc: "List scripts" },
    { name: "config", desc: "Show running config" }, { name: "taxonomy", desc: "Traffic by status category" },
  ]},
  { label: "test", cmds: [
    { name: "probe <url>", desc: "Fetch a URL and show response" }, { name: "dns <domain>", desc: "DNS lookup" },
    { name: "lua <code>", desc: "Run Lua on the server" }, { name: "stream", desc: "Test SSE streaming" },
  ]},
  { label: "control", cmds: [
    { name: "scripts:toggle <id>", desc: "Enable or disable a script" }, { name: "scripts:test <id>", desc: "Run a script's test handler" },
  ]},
];

// Safe JSON tokenizer — returns JSX elements instead of HTML strings
function tokenizeJson(json: string): (string | Element)[] {
  const result: any[] = [];
  const regex = /("(?:[^"\\]|\\.)*")\s*(:)|("(?:[^"\\]|\\.)*")|\b(true|false)\b|\b(null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g;
  let last = 0;
  let m;
  while ((m = regex.exec(json)) !== null) {
    if (m.index > last) result.push(json.slice(last, m.index));
    if (m[1] !== undefined) {
      result.push(<span class="json-key">{m[1]}</span>);
      result.push(":");
    } else if (m[3] !== undefined) {
      result.push(<span class="json-string">{m[3]}</span>);
    } else if (m[4] !== undefined) {
      result.push(<span class="json-boolean">{m[4]}</span>);
    } else if (m[5] !== undefined) {
      result.push(<span class="json-null">{m[5]}</span>);
    } else if (m[6] !== undefined) {
      result.push(<span class="json-number">{m[6]}</span>);
    }
    last = regex.lastIndex;
  }
  if (last < json.length) result.push(json.slice(last));
  return result;
}

function JsonHighlight(props: { text: string }) {
  const tokens = () => {
    try {
      const obj = JSON.parse(props.text);
      const formatted = JSON.stringify(obj, null, 2);
      return tokenizeJson(formatted);
    } catch {
      return null;
    }
  };

  return (
    <Show when={tokens()} fallback={<pre class="text-base-content/80 whitespace-pre-wrap">{props.text}</pre>}>
      {(t) => <pre class="text-base-content/80 whitespace-pre-wrap">{t()}</pre>}
    </Show>
  );
}

function isJson(text: string): boolean { try { JSON.parse(text); return true; } catch { return false; } }

export function ConsoleCore(props: {
  traffic: () => TrafficEntry[];
  scripts: () => ScriptMeta[];
  wsMessages: () => Record<string, unknown>[];
  pendingCmd: () => string | null;
  setPendingCmd: (v: string | null) => void;
}) {
  const [entries, setEntries] = createSignal<LogEntry[]>([]);
  const [showHelp, setShowHelp] = createSignal(false);
  let logEl!: HTMLDivElement;
  let input!: HTMLInputElement;
  let activeStreamCancel: (() => void) | null = null;

  // Command history
  let history: string[] = [];
  try { history = JSON.parse(localStorage.getItem("kw_console_history") || "[]"); } catch {}
  let histIdx = history.length;

  const cmdNames = ["help", ...COMMANDS.flatMap(g => g.cmds.map(c => c.name.split(" ")[0]))];

  function addEntry(entry: LogEntry) {
    setEntries(prev => { const n = [...prev, entry]; if (n.length > 500) n.shift(); return n; });
    requestAnimationFrame(() => { logEl.scrollTop = logEl.scrollHeight; });
  }
  function reply(text: string) { addEntry({ type: "response", text, ts: Date.now() }); }
  function err(text: string) { addEntry({ type: "error", text, ts: Date.now() }); }

  async function apiCmd(path: string, opts: RequestInit = {}) {
    try { reply(JSON.stringify(await api<Record<string, unknown>>(path, opts))); }
    catch (e) { err(String(e)); }
  }

  // WS response handler
  let lastIdx = 0;
  createEffect(() => {
    const msgs = props.wsMessages();
    if (!msgs.length) { lastIdx = 0; return; }
    for (let i = Math.max(lastIdx, 0); i < msgs.length; i++) {
      const msg = msgs[i];
      if (msg.cmd || msg.error || msg.routes || msg.scripts || msg.result) {
        addEntry({ type: "response", text: JSON.stringify(msg), ts: Date.now() });
      }
    }
    lastIdx = msgs.length;
  });

  type CmdFn = (arg: string) => void | Promise<void>;
  const handlers: Record<string, CmdFn> = {
    help:             () => setShowHelp(true),
    ping:             () => sendWS({ cmd: "ping" }),
    scripts:          () => sendWS({ cmd: "scripts" }),
    routes:           () => sendWS({ cmd: "routes" }),
    lua:              (a) => { if (a) sendWS({ cmd: "lua", code: a }); else err("Usage: lua <code>  —  e.g. lua print('hello')"); },
    "scripts:toggle": (a) => { if (a) apiCmd(`/__keyway/api/scripts/${a}/toggle`, { method: "POST" }); else err("Usage: scripts:toggle <id>"); },
    "scripts:test":   (a) => { if (a) apiCmd(`/__keyway/api/scripts/${a}/test`, { method: "POST", body: JSON.stringify({ method: "GET", path: "/test", headers: {}, body: "" }) }); else err("Usage: scripts:test <id>"); },
    probe:            (a) => { if (a) apiCmd("/__keyway/api/probe", { method: "POST", body: JSON.stringify({ url: a }) }); else err("Usage: probe <url>"); },
    dns:              (a) => { if (a) apiCmd("/__keyway/api/dns", { method: "POST", body: JSON.stringify({ domain: a }) }); else err("Usage: dns <domain>"); },
    stream:           () => {
      if (activeStreamCancel) { activeStreamCancel(); activeStreamCancel = null; reply("Stream cancelled."); return; }
      reply("Streaming...");
      activeStreamCancel = startStream(
        (chunk) => addEntry({ type: "response", text: chunk, ts: Date.now() }),
        () => { activeStreamCancel = null; reply("Stream ended."); },
      );
    },
    config:           async () => {
      try { reply(JSON.stringify(await fetchEffectiveConfig())); } catch (e) { err(String(e)); }
    },
    taxonomy:         () => {
      const counts: Record<string, number> = {};
      for (const e of props.traffic()) {
        if (e.path.startsWith("/__keyway/")) continue;
        const label = INVOCATION_LABELS[classifyInvocation(e)] || "unknown";
        counts[label] = (counts[label] || 0) + 1;
      }
      const total = Object.values(counts).reduce((a, b) => a + b, 0);
      if (!total) { reply("No traffic yet — send some requests and check back"); return; }
      reply(`Traffic breakdown (${total} requests):\n` +
        Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([l, c]) => `${l}: ${c} (${((c / total) * 100).toFixed(1)}%)`).join("\n"));
    },
  };

  async function handleCommand(raw: string) {
    setShowHelp(false);
    addEntry({ type: "cmd", text: raw, ts: Date.now() });
    const parts = raw.trim().split(/\s+/);
    const cmd = parts[0].toLowerCase();
    const arg = parts.slice(1).join(" ");
    const h = handlers[cmd];
    if (h) { await h(arg); }
    else if (raw.trimStart().startsWith("{")) { try { sendWS(JSON.parse(raw)); } catch { err("Invalid JSON: " + raw); } }
    else { err(`"${cmd}" isn't a command I know — try help to see what's available`); }
  }

  // Pending command from other views
  createEffect(() => {
    const pending = props.pendingCmd();
    if (pending) {
      props.setPendingCmd(null);
      input.value = pending.includes(" ") ? pending : pending + " ";
      input.focus();
    }
  });

  function onInputKeydown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      const cmd = input.value.trim(); if (!cmd) return;
      history.push(cmd);
      if (history.length > 100) history.shift();
      try { localStorage.setItem("kw_console_history", JSON.stringify(history)); } catch {}
      histIdx = history.length;
      handleCommand(cmd);
      input.value = "";
    } else if (e.key === "ArrowUp") {
      e.preventDefault(); if (histIdx > 0) { histIdx--; input.value = history[histIdx] || ""; }
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      if (histIdx < history.length - 1) { histIdx++; input.value = history[histIdx] || ""; }
      else { histIdx = history.length; input.value = ""; }
    } else if (e.key === "Tab") {
      e.preventDefault();
      const match = cmdNames.find(c => c.startsWith(input.value));
      if (match) input.value = match + " ";
    }
  }

  onMount(() => setTimeout(() => input?.focus(), 100));
  onCleanup(() => { if (activeStreamCancel) activeStreamCancel(); });

  const hasEntries = () => entries().length > 0;
  const scriptCount = () => props.scripts().length;

  return (
    <div class="flex flex-col h-full">
      <div ref={logEl} class="flex-1 overflow-y-auto p-3 space-y-1">
        {/* Onboarding empty state */}
        <Show when={!hasEntries() && !showHelp()}>
          <div class="px-3 py-4 space-y-3">
            <div class="text-base-content/60 text-sm font-medium">{timeGreeting()} — ready when you are</div>
            <div class="space-y-1.5 text-detail">
              <Show when={scriptCount() > 0}>
                <div class="flex items-center gap-2 text-base-content/60">
                  <span class="text-primary/60">{">"}</span>
                  <span>You have <span class="text-primary font-semibold">{scriptCount()}</span> scripts — try</span>
                  <button
                    class="text-primary cursor-pointer hover:underline bg-transparent border-none p-0 font-inherit text-inherit focus-visible:ring-1 focus-visible:ring-primary rounded"
                    onClick={() => { input.value = "scripts"; input.focus(); }}
                  >scripts</button>
                </div>
              </Show>
              <div class="flex items-center gap-2 text-base-content/60">
                <span class="text-primary/60">{">"}</span>
                <span>Run Lua on the server:</span>
                <button
                  class="text-primary cursor-pointer hover:underline font-mono bg-transparent border-none p-0 font-inherit focus-visible:ring-1 focus-visible:ring-primary rounded"
                  onClick={() => { input.value = "lua print('hello')"; input.focus(); }}
                >lua print('hello')</button>
              </div>
              <div class="flex items-center gap-2 text-base-content/60">
                <span class="text-primary/60">{">"}</span>
                <span>Probe an endpoint:</span>
                <button
                  class="text-primary cursor-pointer hover:underline font-mono bg-transparent border-none p-0 font-inherit focus-visible:ring-1 focus-visible:ring-primary rounded"
                  onClick={() => { input.value = "probe http://localhost:8080/test/json"; input.focus(); }}
                >probe http://localhost:8080/test/json</button>
              </div>
              <div class="flex items-center gap-2 text-base-content/60">
                <span class="text-primary/60">{">"}</span>
                <span>Type</span>
                <button
                  class="text-primary cursor-pointer hover:underline bg-transparent border-none p-0 font-inherit focus-visible:ring-1 focus-visible:ring-primary rounded"
                  onClick={() => setShowHelp(true)}
                >help</button>
                <span>for all commands</span>
              </div>
            </div>
          </div>
        </Show>

        {/* Help panel */}
        <Show when={showHelp()}>
          <div class="px-3 py-2 space-y-3">
            <div class="flex items-center justify-between">
              <span class="text-base-content/60 text-sm font-medium">Commands</span>
              <button class="btn btn-xs btn-ghost text-base-content/60" aria-label="Close help" onClick={() => setShowHelp(false)}>&#215;</button>
            </div>
            <For each={COMMANDS}>
              {(group) => (
                <div class="space-y-1">
                  <div class="text-tiny font-semibold tracking-widest text-base-content/60 uppercase">{group.label}</div>
                  <For each={group.cmds}>
                    {(cmd) => (
                      <button
                        class="flex items-center gap-3 text-detail py-0.5 hover:bg-base-300/30 rounded px-1 -mx-1 cursor-pointer w-full text-left bg-transparent border-none font-inherit focus-visible:ring-1 focus-visible:ring-primary"
                        onClick={() => { const base = cmd.name.split(" ")[0]; input.value = cmd.name.includes("<") ? base + " " : base; input.focus(); setShowHelp(false); }}
                      >
                        <span class="text-primary font-mono w-32 shrink-0">{cmd.name}</span>
                        <span class="text-base-content/60">{cmd.desc}</span>
                      </button>
                    )}
                  </For>
                </div>
              )}
            </For>
          </div>
        </Show>

        {/* Log entries */}
        <For each={entries()}>
          {(entry) => {
            const ts = formatTime(entry.ts, false);
            return (
              <div class="text-detail flex gap-2 console-entry">
                <span class="text-base-content/60 shrink-0">{ts}</span>
                {entry.type === "cmd" ? (
                  <span class="text-primary">{">"} {entry.text}</span>
                ) : entry.type === "error" ? (
                  <span class="text-error">{entry.text}</span>
                ) : isJson(entry.text) ? (
                  <JsonHighlight text={entry.text} />
                ) : (
                  <pre class="text-base-content/80 whitespace-pre-wrap">{entry.text}</pre>
                )}
              </div>
            );
          }}
        </For>
      </div>
      <div class="flex items-center gap-2 px-3 py-2 border-t border-base-300 bg-base-200">
        <span class="text-primary text-body">{">"}</span>
        <input
          ref={input}
          type="text"
          class="flex-1 bg-transparent text-base-content text-body outline-none focus-visible:ring-1 focus-visible:ring-primary/50"
          placeholder="Type a command..."
          aria-label="Console command input"
          onKeyDown={onInputKeydown}
        />
        <button
          class="btn btn-xs btn-ghost text-base-content/60"
          title="Help"
          onClick={() => setShowHelp(!showHelp())}
        >?</button>
      </div>
    </div>
  );
}
