// Console — REPL with command history, JSON highlighting, onboarding UX

import { createSignal, createEffect, For, Show, onMount, onCleanup } from "solid-js";
import {
  type MetricsSnapshot, api, sendWS, startStream,
  classifyStatus, INVOCATION_LABELS, formatTime, METRICS_POLL_MS,
} from "../main";

interface EngineLogEntry { seq: number; ts: number; level: string; worker: number; msg: string; }
interface EngineLogResponse { entries: EngineLogEntry[]; latest: number; }

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
    { name: "config", desc: "Show running config" }, { name: "taxonomy", desc: "Traffic by status category" },
  ]},
  { label: "test", cmds: [
    { name: "lua <code>", desc: "Run Lua on the server" }, { name: "stream", desc: "Test SSE streaming" },
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

export function ConsoleCore(props: {
  metrics: () => MetricsSnapshot | null;
  wsMessages: () => Record<string, unknown>[];
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

  // WS response handler
  let lastIdx = 0;
  createEffect(() => {
    const msgs = props.wsMessages();
    if (!msgs.length) { lastIdx = 0; return; }
    for (let i = Math.max(lastIdx, 0); i < msgs.length; i++) {
      const msg = msgs[i];
      if (msg.cmd || msg.error || msg.result) {
        addEntry({ type: "response", text: JSON.stringify(msg), ts: Date.now() });
      }
    }
    lastIdx = msgs.length;
  });

  // Live engine log — polls GET /__keyway/api/log with a `since` cursor at
  // the same cadence as the metrics poll, surfacing Lua tracebacks and other
  // warn/error engine events without leaving the dashboard (#230). Raw
  // fetch (not the `api()` helper): a transient poll failure shouldn't pop
  // an error toast, same reasoning as the metrics poll in main.tsx.
  let logCursor = 0;
  async function pollEngineLog() {
    try {
      const res = await fetch(`/__keyway/api/log?since=${logCursor}`);
      if (!res.ok) return;
      const data = await res.json() as EngineLogResponse;
      for (const e of data.entries) {
        addEntry({
          type: e.level === "err" ? "error" : "response",
          text: `[w${e.worker}] ${e.level.toUpperCase()}: ${e.msg.replace(/\\n/g, "\n")}`,
          ts: e.ts,
        });
      }
      logCursor = data.latest;
    } catch { /* dashboard connectivity is already signaled elsewhere */ }
  }
  onMount(() => {
    pollEngineLog();
    const logTimer = setInterval(pollEngineLog, METRICS_POLL_MS);
    onCleanup(() => clearInterval(logTimer));
  });

  type CmdFn = (arg: string) => void | Promise<void>;
  const handlers: Record<string, CmdFn> = {
    help:             () => setShowHelp(true),
    ping:             () => sendWS({ cmd: "ping" }),
    lua:              (a) => { if (a) sendWS({ cmd: "lua", code: a }); else err("Usage: lua <code>  —  e.g. lua print('hello')"); },
    stream:           () => {
      if (activeStreamCancel) { activeStreamCancel(); activeStreamCancel = null; reply("Stream cancelled."); return; }
      reply("Streaming...");
      activeStreamCancel = startStream(
        (chunk) => addEntry({ type: "response", text: chunk, ts: Date.now() }),
        () => { activeStreamCancel = null; reply("Stream ended."); },
      );
    },
    config:           async () => {
      try { reply(JSON.stringify(await api<object>("/__keyway/api/config/effective"))); } catch (e) { err(String(e)); }
    },
    taxonomy:         () => {
      const m = props.metrics();
      if (!m || m.total === 0) { reply("No traffic yet — send some requests and check back"); return; }
      const counts: Record<string, number> = {};
      for (const [status, n] of m.byStatus) {
        const label = INVOCATION_LABELS[classifyStatus(status)] || "unknown";
        counts[label] = (counts[label] || 0) + n;
      }
      reply(`Traffic breakdown (${m.total} requests, since server start):\n` +
        Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([l, c]) => `${l}: ${c} (${((c / m.total) * 100).toFixed(1)}%)`).join("\n"));
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

  return (
    <div class="flex flex-col h-full">
      <div ref={logEl} class="flex-1 overflow-y-auto p-3 space-y-1">
        {/* Onboarding empty state */}
        <Show when={!hasEntries() && !showHelp()}>
          <div class="px-3 py-4 space-y-3">
            <div class="text-base-content/60 text-sm font-medium">{timeGreeting()} — ready when you are</div>
            <div class="space-y-1.5 text-detail">
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
            const ts = formatTime(entry.ts);
            return (
              <div class="text-detail flex gap-2 console-entry">
                <span class="text-base-content/60 shrink-0">{ts}</span>
                {entry.type === "cmd" ? (
                  <span class="text-primary">{">"} {entry.text}</span>
                ) : entry.type === "error" ? (
                  <pre class="text-error whitespace-pre-wrap m-0 font-inherit">{entry.text}</pre>
                ) : (
                  <JsonHighlight text={entry.text} />
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
