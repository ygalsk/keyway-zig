// Console command input with history and tab autocomplete

import { onMount } from "solid-js";

export interface CommandInputHandle {
  focus: () => void;
  setValue: (v: string) => void;
}

export function CommandInput(props: {
  onSubmit: (cmd: string) => void;
  commands?: string[];
  ref?: (handle: CommandInputHandle) => void;
}) {
  let input!: HTMLInputElement;
  const knownCommands = () => props.commands || [];

  let history: string[] = [];
  try { history = JSON.parse(localStorage.getItem("kw_console_history") || "[]"); } catch { /* private browsing */ }
  let histIdx = history.length;

  onMount(() => {
    props.ref?.({
      focus: () => input.focus(),
      setValue: (v: string) => { input.value = v; },
    });
  });

  function onKeydown(e: KeyboardEvent) {
    if (e.key === "Enter") {
      const cmd = input.value.trim();
      if (!cmd) return;
      history.push(cmd);
      if (history.length > 100) history.shift();
      try { localStorage.setItem("kw_console_history", JSON.stringify(history)); } catch { /* private browsing */ }
      histIdx = history.length;
      props.onSubmit(cmd);
      input.value = "";
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      if (histIdx > 0) { histIdx--; input.value = history[histIdx] || ""; }
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      if (histIdx < history.length - 1) { histIdx++; input.value = history[histIdx] || ""; }
      else { histIdx = history.length; input.value = ""; }
    } else if (e.key === "Tab") {
      e.preventDefault();
      const val = input.value;
      const match = knownCommands().find((c) => c.startsWith(val));
      if (match) input.value = match + " ";
    }
  }

  return (
    <div class="flex items-center gap-2 px-3 py-2 border-t border-base-300 bg-base-200">
      <span class="text-primary text-body">{">"}</span>
      <input
        ref={input}
        type="text"
        class="flex-1 bg-transparent text-base-content text-body outline-none"
        placeholder="Type a command..."
        onKeyDown={onKeydown}
      />
    </div>
  );
}
