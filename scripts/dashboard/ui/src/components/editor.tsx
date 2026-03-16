// Code editor component — monospace textarea with line numbers, tab support, and Lua syntax highlighting

import { createSignal, createEffect, onMount, onCleanup, Show } from "solid-js";

export interface EditorHandle {
  getValue: () => string;
  setValue: (v: string) => void;
}

// Lua syntax highlighting — lightweight overlay approach
const LUA_KEYWORDS = new Set([
  "local", "function", "if", "then", "else", "elseif", "end", "for", "while",
  "do", "return", "not", "and", "or", "in", "repeat", "until", "nil", "true", "false",
]);

function highlightLua(code: string, errorLine?: number): string {
  const lines = code.split("\n");
  const result: string[] = [];

  for (let lineIdx = 0; lineIdx < lines.length; lineIdx++) {
    const line = lines[lineIdx];
    const isErrorLine = errorLine !== undefined && lineIdx + 1 === errorLine;
    let highlighted = "";
    let i = 0;

    while (i < line.length) {
      // Comments
      if (line[i] === "-" && line[i + 1] === "-") {
        highlighted += `<span class="hl-comment">${escapeHtml(line.slice(i))}</span>`;
        i = line.length;
        continue;
      }

      // Strings (double-quoted)
      if (line[i] === '"') {
        let end = i + 1;
        while (end < line.length && line[end] !== '"') {
          if (line[end] === "\\") end++;
          end++;
        }
        end = Math.min(end + 1, line.length);
        highlighted += `<span class="hl-string">${escapeHtml(line.slice(i, end))}</span>`;
        i = end;
        continue;
      }

      // Strings (single-quoted)
      if (line[i] === "'") {
        let end = i + 1;
        while (end < line.length && line[end] !== "'") {
          if (line[end] === "\\") end++;
          end++;
        }
        end = Math.min(end + 1, line.length);
        highlighted += `<span class="hl-string">${escapeHtml(line.slice(i, end))}</span>`;
        i = end;
        continue;
      }

      // Keywords and identifiers
      if (/[a-zA-Z_]/.test(line[i])) {
        let end = i;
        while (end < line.length && /[a-zA-Z0-9_]/.test(line[end])) end++;
        const word = line.slice(i, end);
        if (LUA_KEYWORDS.has(word)) {
          highlighted += `<span class="hl-keyword">${escapeHtml(word)}</span>`;
        } else {
          highlighted += escapeHtml(word);
        }
        i = end;
        continue;
      }

      // Numbers
      if (/[0-9]/.test(line[i])) {
        let end = i;
        while (end < line.length && /[0-9.xXa-fA-F]/.test(line[end])) end++;
        highlighted += `<span class="hl-number">${escapeHtml(line.slice(i, end))}</span>`;
        i = end;
        continue;
      }

      highlighted += escapeHtml(line[i]);
      i++;
    }

    if (isErrorLine) {
      result.push(`<span class="hl-error-line">${highlighted}</span>`);
    } else {
      result.push(highlighted);
    }
  }

  return result.join("\n");
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function Editor(props: {
  value?: string;
  placeholder?: string;
  onChange?: (value: string) => void;
  readonly?: boolean;
  ref?: (handle: EditorHandle) => void;
  highlightLine?: number;
}) {
  let textarea!: HTMLTextAreaElement;
  let gutter!: HTMLDivElement;
  let overlay!: HTMLDivElement;
  const [lineNums, setLineNums] = createSignal("1");
  const [highlighted, setHighlighted] = createSignal("");

  function updateLineNumbers() {
    const lines = textarea.value.split("\n").length;
    setLineNums(Array.from({ length: lines }, (_, i) => i + 1).join("\n"));
  }

  function updateHighlight() {
    setHighlighted(highlightLua(textarea.value, props.highlightLine));
  }

  onMount(() => {
    textarea.value = props.value || "";
    updateLineNumbers();
    updateHighlight();
    props.ref?.({
      getValue: () => textarea.value,
      setValue: (v: string) => { textarea.value = v; updateLineNumbers(); updateHighlight(); },
    });
  });

  // Update highlight when highlightLine changes
  createEffect(() => {
    const _ = props.highlightLine;
    updateHighlight();
  });

  function onInput() {
    updateLineNumbers();
    updateHighlight();
    props.onChange?.(textarea.value);
  }

  function onScroll() {
    gutter.scrollTop = textarea.scrollTop;
    overlay.scrollTop = textarea.scrollTop;
    overlay.scrollLeft = textarea.scrollLeft;
  }

  function onKeydown(e: KeyboardEvent) {
    if (e.key === "Tab") {
      e.preventDefault();
      const start = textarea.selectionStart;
      const end = textarea.selectionEnd;
      textarea.value = textarea.value.substring(0, start) + "  " + textarea.value.substring(end);
      textarea.selectionStart = textarea.selectionEnd = start + 2;
      props.onChange?.(textarea.value);
      updateLineNumbers();
      updateHighlight();
    }
  }

  return (
    <div class="flex relative bg-base-100 border border-base-300 rounded h-full">
      <div
        ref={gutter}
        class="py-2 px-2 text-right text-base-content/20 select-none leading-[1.5] text-body min-w-[3rem] border-r border-base-300 overflow-hidden whitespace-pre"
      >
        {lineNums()}
      </div>
      <div class="flex-1 relative overflow-hidden">
        {/* Syntax highlight overlay */}
        <div
          ref={overlay}
          class="absolute inset-0 p-2 leading-[1.5] text-body font-mono whitespace-pre overflow-hidden pointer-events-none hl-overlay"
          innerHTML={highlighted()}
        />
        {/* Actual textarea */}
        <textarea
          ref={textarea}
          class="absolute inset-0 w-full h-full bg-transparent text-transparent caret-base-content p-2 outline-none resize-none leading-[1.5] text-body font-mono"
          spellcheck={false}
          placeholder={props.placeholder || "-- Lua script..."}
          readOnly={props.readonly}
          onInput={onInput}
          onScroll={onScroll}
          onKeyDown={onKeydown}
        />
      </div>
    </div>
  );
}
