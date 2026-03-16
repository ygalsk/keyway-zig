// WebSocket Tester — multi-connection, message log

import { sendWS, connectWS } from "../api";
import { store } from "../state";

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function mountWsTester(container: HTMLElement): () => void {
  container.innerHTML = `
    <div class="flex flex-col h-full">
      <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
        <h2 class="text-sm font-semibold text-base-content/80">WebSocket</h2>
      </div>
      <div class="flex flex-1 overflow-hidden">
        <div class="flex-1 flex flex-col">
          <div id="ws-messages" class="flex-1 overflow-y-auto p-3 space-y-1"></div>
          <div class="flex gap-2 p-3 border-t border-base-300">
            <input id="ws-input" type="text" placeholder='{"cmd":"ping"}'
              class="input input-sm input-bordered bg-base-100 flex-1 text-[11px]" />
            <button id="ws-send" class="btn btn-sm btn-primary">Send</button>
          </div>
        </div>
        <div class="w-48 border-l border-base-300 p-3 space-y-3">
          <div class="text-[10px] text-base-content/40 font-medium">Quick Commands</div>
          <div class="space-y-1" id="ws-quick-cmds"></div>
          <div class="text-[9px] text-base-content/30 space-y-1 pt-2 border-t border-base-300/30">
            <div class="font-medium text-base-content/40">Advanced</div>
            <div>{"cmd":"trigger","id":"..."}</div>
            <div>{"cmd":"send_hook","id":"...","body":"..."}</div>
          </div>
        </div>
      </div>
    </div>
  `;

  const messagesEl = container.querySelector<HTMLElement>("#ws-messages")!;
  const input = container.querySelector<HTMLInputElement>("#ws-input")!;
  const sendBtn = container.querySelector<HTMLButtonElement>("#ws-send")!;
  const quickCmds = container.querySelector<HTMLElement>("#ws-quick-cmds")!;

  const commands = [
    { label: "Ping", cmd: { cmd: "ping" } },
    { label: "Info", cmd: { cmd: "info" } },
    { label: "Scripts", cmd: { cmd: "scripts" } },
    { label: "Hooks", cmd: { cmd: "hooks" } },
  ];

  for (const c of commands) {
    const btn = document.createElement("button");
    btn.className = "btn btn-xs btn-ghost w-full justify-start text-[10px] text-base-content/50";
    btn.textContent = c.label;
    btn.addEventListener("click", () => {
      sendWS(c.cmd);
      addMessage("out", JSON.stringify(c.cmd));
    });
    quickCmds.appendChild(btn);
  }

  function addMessage(dir: "in" | "out", data: string): void {
    const div = document.createElement("div");
    const prefix = dir === "out" ? "→" : "←";
    const color = dir === "out" ? "text-primary" : "text-info";
    let formatted = data;
    try {
      formatted = JSON.stringify(JSON.parse(data), null, 2);
    } catch { /* keep raw */ }
    div.className = `text-[10px] ${color}`;
    div.innerHTML = `<span class="text-base-content/20">${prefix}</span> <pre class="inline whitespace-pre-wrap">${esc(formatted)}</pre>`;
    messagesEl.appendChild(div);
    messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  function doSend(): void {
    const text = input.value.trim();
    if (!text) return;
    try {
      const data = JSON.parse(text);
      sendWS(data);
      addMessage("out", text);
    } catch {
      sendWS({ cmd: text });
      addMessage("out", JSON.stringify({ cmd: text }));
    }
    input.value = "";
  }

  sendBtn.addEventListener("click", doSend);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") doSend();
  });

  // Show incoming messages
  const unsub = store.on<object[]>("ws_messages", (msgs) => {
    if (!msgs || msgs.length === 0) return;
    const latest = msgs[msgs.length - 1];
    addMessage("in", JSON.stringify(latest));
  });

  // Ensure WS is connected
  connectWS();

  return () => unsub();
}
