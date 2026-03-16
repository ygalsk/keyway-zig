// Code editor component — monospace textarea with line numbers and tab support

export interface EditorOptions {
  value?: string;
  placeholder?: string;
  onChange?: (value: string) => void;
  readonly?: boolean;
}

export function createEditor(
  container: HTMLElement,
  opts: EditorOptions = {}
): { getValue: () => string; setValue: (v: string) => void } {
  container.innerHTML = "";
  container.className += " flex relative bg-base-100 border border-base-300 rounded";

  // Line numbers
  const gutter = document.createElement("div");
  gutter.className =
    "py-2 px-2 text-right text-base-content/20 select-none leading-[1.5] text-[11px] min-w-[3rem] border-r border-base-300 overflow-hidden";
  container.appendChild(gutter);

  // Textarea
  const textarea = document.createElement("textarea");
  textarea.className =
    "flex-1 bg-transparent text-base-content p-2 outline-none resize-none leading-[1.5] text-[11px] font-mono";
  textarea.spellcheck = false;
  textarea.value = opts.value || "";
  textarea.placeholder = opts.placeholder || "-- Lua script...";
  if (opts.readonly) textarea.readOnly = true;
  container.appendChild(textarea);

  function updateLineNumbers(): void {
    const lines = textarea.value.split("\n").length;
    gutter.innerHTML = Array.from({ length: lines }, (_, i) => i + 1).join(
      "<br>"
    );
  }

  textarea.addEventListener("input", () => {
    updateLineNumbers();
    opts.onChange?.(textarea.value);
  });

  textarea.addEventListener("scroll", () => {
    gutter.scrollTop = textarea.scrollTop;
  });

  // Tab support
  textarea.addEventListener("keydown", (e) => {
    if (e.key === "Tab") {
      e.preventDefault();
      const start = textarea.selectionStart;
      const end = textarea.selectionEnd;
      textarea.value =
        textarea.value.substring(0, start) +
        "  " +
        textarea.value.substring(end);
      textarea.selectionStart = textarea.selectionEnd = start + 2;
      opts.onChange?.(textarea.value);
      updateLineNumbers();
    }
  });

  updateLineNumbers();

  return {
    getValue: () => textarea.value,
    setValue: (v: string) => {
      textarea.value = v;
      updateLineNumbers();
    },
  };
}
