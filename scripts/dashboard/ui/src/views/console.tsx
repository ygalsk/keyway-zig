// Console — REPL with command history, JSON highlighting, WS integration

import { createSignal, createEffect, For, Show, onMount, onCleanup } from "solid-js";
import { api, sendWS, fetchEffectiveConfig, fetchSelf, startStream } from "../api";
import { state, type TrafficEntry, classifyInvocation, INVOCATION_LABELS } from "../state";
import { CommandInput, type CommandInputHandle } from "../components/command-input";
import { SectionHeader } from "../components/section-header";
import { formatTime } from "./format";

interface LogEntry {
  type: "cmd" | "response" | "error";
  text: string;
  ts: number;
}

const COMMAND_GROUPS: { label: string; cmds: { name: string; desc: string }[] }[] = [
  { label: "inspect", cmds: [
    { name: "ping", desc: "Check WS connectivity" },
    { name: "info", desc: "Server status & workers" },
    { name: "routes", desc: "List registered routes" },
    { name: "workers", desc: "Worker thread details" },
    { name: "scripts", desc: "List Lua scripts" },
    { name: "config", desc: "Show effective config" },
    { name: "taxonomy", desc: "Request state breakdown" },
  ]},
  { label: "test", cmds: [
    { name: "probe <url>", desc: "HTTP test request" },
    { name: "dns <domain>", desc: "DNS resolution" },
    { name: "lua <code>", desc: "Execute Lua snippet" },
    { name: "self <path>", desc: "Self-request to server" },
    { name: "stream", desc: "Stream test chunks" },
  ]},
  { label: "control", cmds: [
    { name: "scripts:toggle <id>", desc: "Enable/disable script" },
    { name: "scripts:test <id>", desc: "Run script test" },
  ]},
];

function highlightJson(text: string): string {
  try {
    const obj = JSON.parse(text);
    const formatted = JSON.stringify(obj, null, 2);
    return formatted
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"([^"]+)"(?=\s*:)/g, '<span class="json-key">"$1"</span>')
      .replace(/:\s*"([^"]*)"/g, ': <span class="json-string">"$1"</span>')
      .replace(/:\s*(\d+\.?\d*)/g, ': <span class="json-number">$1</span>')
      .replace(/:\s*(true|false)/g, ': <span class="json-boolean">$1</span>')
      .replace(/:\s*(null)/g, ': <span class="json-null">$1</span>');
  } catch {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
}

function isJson(text: string): boolean {
  try { JSON.parse(text); return true; } catch { return false; }
}

export function ConsoleCore() {
  const s = state();
  const [entries, setEntries] = createSignal<LogEntry[]>([]);
  const [showHelp, setShowHelp] = createSignal(true);
  let logEl!: HTMLDivElement;
  let cmdHandle: CommandInputHandle | null = null;
  let activeStreamCancel: (() => void) | null = null;

  function addEntry(entry: LogEntry) {
    setEntries(prev => {
      const next = [...prev, entry];
      if (next.length > 500) next.shift();
      return next;
    });
    requestAnimationFrame(() => { logEl.scrollTop = logEl.scrollHeight; });
  }

  function reply(text: string) { addEntry({ type: "response", text, ts: Date.now() }); }
  function err(text: string) { addEntry({ type: "error", text, ts: Date.now() }); }

  async function apiCmd(path: string, opts: RequestInit = {}) {
    try {
      const r = await api<Record<string, unknown>>(path, opts);
      reply(JSON.stringify(r));
    } catch (e) {
      err(String(e));
    }
  }

  function requireArg(arg: string, usage: string): boolean {
    if (!arg) { err(`Usage: ${usage}`); return false; }
    return true;
  }

  // WS response handler — track last processed index to avoid dropping messages
  let lastProcessedIndex = 0;
  createEffect(() => {
    const msgs = s.wsMessages();
    if (!msgs.length) { lastProcessedIndex = 0; return; }
    // Process all messages from lastProcessedIndex forward
    const startIdx = Math.max(lastProcessedIndex, 0);
    for (let i = startIdx; i < msgs.length; i++) {
      const msg = msgs[i];
      if (msg.cmd || msg.error || msg.routes || msg.scripts || msg.result) {
        addEntry({ type: "response", text: JSON.stringify(msg), ts: Date.now() });
      }
    }
    lastProcessedIndex = msgs.length;
  });

  type CmdHandler = (arg: string) => void | Promise<void>;
  const commands: Record<string, CmdHandler> = {
    help:             ()    => setShowHelp(true),
    ping:             ()    => sendWS({ cmd: "ping" }),
    info:             ()    => sendWS({ cmd: "info" }),
    scripts:          ()    => sendWS({ cmd: "scripts" }),
    hooks:            ()    => sendWS({ cmd: "hooks" }),
    routes:           ()    => sendWS({ cmd: "routes" }),
    workers:          ()    => sendWS({ cmd: "info" }),
    connections:      ()    => sendWS({ cmd: "info" }),
    tail:             ()    => reply("Subscribed to traffic stream. New requests will appear here."),
    lua:              (arg) => { if (requireArg(arg, "lua <code>")) sendWS({ cmd: "lua", code: arg }); },
    "scripts:toggle": (arg) => { if (requireArg(arg, "scripts:toggle <id>")) apiCmd(`/__keyway/api/scripts/${arg}/toggle`, { method: "POST" }); },
    "scripts:test":   (arg) => { if (requireArg(arg, "scripts:test <id>")) apiCmd(`/__keyway/api/scripts/${arg}/test`, { method: "POST", body: JSON.stringify({ method: "GET", path: "/test", headers: {}, body: "" }) }); },
    probe:            (arg) => { if (requireArg(arg, "probe <url>")) apiCmd("/__keyway/api/probe", { method: "POST", body: JSON.stringify({ url: arg }) }); },
    dns:              (arg) => { if (requireArg(arg, "dns <domain>")) apiCmd("/__keyway/api/dns", { method: "POST", body: JSON.stringify({ domain: arg }) }); },
    self:             async (arg) => {
      const path = arg || "/";
      reply(`Self-request: ${path}`);
      try {
        const r = await fetchSelf(path);
        reply(JSON.stringify(r));
      } catch (e) {
        err(String(e));
      }
    },
    stream:           () => {
      if (activeStreamCancel) {
        activeStreamCancel();
        activeStreamCancel = null;
        reply("Stream cancelled.");
        return;
      }
      reply("Streaming...");
      activeStreamCancel = startStream(
        (chunk) => addEntry({ type: "response", text: chunk, ts: Date.now() }),
        () => { activeStreamCancel = null; reply("Stream ended."); },
      );
    },
    config:           async () => {
      try { const config = await fetchEffectiveConfig(); reply(JSON.stringify(config)); }
      catch (e) { err(String(e)); }
    },
    taxonomy:         () => {
      const traffic = s.traffic();
      const counts: Record<string, number> = {};
      for (const e of traffic) {
        if (e.path.startsWith("/__keyway/")) continue;
        const st = classifyInvocation(e);
        counts[INVOCATION_LABELS[st]] = (counts[INVOCATION_LABELS[st]] || 0) + 1;
      }
      const total = Object.values(counts).reduce((a, b) => a + b, 0);
      if (total === 0) { reply("No traffic data yet"); return; }
      const lines = Object.entries(counts)
        .sort((a, b) => b[1] - a[1])
        .map(([label, count]) => `${label}: ${count} (${((count / total) * 100).toFixed(1)}%)`)
        .join("\n");
      reply(`Invocation States (${total} requests):\n${lines}`);
    },
  };

  async function handleCommand(raw: string) {
    setShowHelp(false);
    addEntry({ type: "cmd", text: raw, ts: Date.now() });

    const parts = raw.trim().split(/\s+/);
    const cmd = parts[0].toLowerCase();
    const arg = parts.slice(1).join(" ");

    const handler = commands[cmd];
    if (handler) {
      await handler(arg);
    } else if (raw.trimStart().startsWith("{")) {
      try { sendWS(JSON.parse(raw)); } catch { err("Invalid JSON: " + raw); }
    } else {
      err(`Unknown command: "${cmd}". Type help for available commands.`);
    }
  }

  function fillInput(cmd: string) {
    cmdHandle?.setValue(cmd);
    cmdHandle?.focus();
  }

  // Pick up pending command from state (e.g. Quick Actions in Overview)
  createEffect(() => {
    const pending = s.pendingConsoleCmd();
    if (pending) {
      s.setPendingConsoleCmd(null);
      cmdHandle?.setValue(pending.includes(" ") ? pending : pending + " ");
      cmdHandle?.focus();
    }
  });

  onMount(() => { setTimeout(() => cmdHandle?.focus(), 100); });
  onCleanup(() => { if (activeStreamCancel) activeStreamCancel(); });

  return (
    <div class="flex flex-col h-full">
      <div ref={logEl} class="flex-1 overflow-y-auto p-3 space-y-1">
        {/* Help grid */}
        <Show when={showHelp()}>
          <div class="px-3 py-2 space-y-2">
            <For each={COMMAND_GROUPS}>
              {(group) => (
                <div class="flex items-center gap-1.5 text-detail">
                  <span class="text-base-content/50 w-14 shrink-0">{group.label}:</span>
                  <For each={group.cmds}>
                    {(cmd) => (
                      <span
                        class="badge badge-xs bg-base-300 text-base-content/50 cursor-pointer hover:bg-primary/20 hover:text-primary transition-colors"
                        title={cmd.desc}
                        onClick={() => {
                          const base = cmd.name.split(" ")[0];
                          fillInput(cmd.name.includes("<") ? base + " " : base);
                        }}
                      >
                        {cmd.name}
                      </span>
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
              <div class="text-detail flex gap-2">
                <span class="text-base-content/45 shrink-0">{ts}</span>
                {entry.type === "cmd" ? (
                  <span class="text-primary">{">"} {entry.text}</span>
                ) : entry.type === "error" ? (
                  <span class="text-error">{entry.text}</span>
                ) : isJson(entry.text) ? (
                  <pre class="text-base-content/80 whitespace-pre-wrap" innerHTML={highlightJson(entry.text)} />
                ) : (
                  <pre class="text-base-content/80 whitespace-pre-wrap">{entry.text}</pre>
                )}
              </div>
            );
          }}
        </For>
      </div>
      <CommandInput
        onSubmit={handleCommand}
        commands={Object.keys(commands)}
        ref={(h) => { cmdHandle = h; }}
      />
    </div>
  );
}

// Full-page console mount
export function Console() {
  return (
    <div class="h-full flex flex-col">
      <SectionHeader title="Console" />
      <div class="flex-1 overflow-hidden">
        <ConsoleCore />
      </div>
    </div>
  );
}
