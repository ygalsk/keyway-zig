// Global error toast — auto-dismiss after 5s

import { For, onCleanup, createEffect } from "solid-js";
import { state } from "../state";

export function ToastBar() {
  const s = state();

  // Auto-dismiss after 5s
  createEffect(() => {
    const errs = s.errors();
    if (!errs.length) return;
    const timers = errs.map(e => {
      const age = Date.now() - e.ts;
      const remaining = Math.max(0, 5000 - age);
      return setTimeout(() => s.dismissError(e.ts), remaining);
    });
    onCleanup(() => timers.forEach(clearTimeout));
  });

  return (
    <For each={s.errors()}>
      {(err) => (
        <div class="bg-error/10 border-b border-error/30 text-error text-detail px-4 py-1.5 flex items-center gap-2">
          <span class="flex-1">{err.message}</span>
          <button
            class="btn btn-xs btn-ghost text-error"
            onClick={() => s.dismissError(err.ts)}
          >
            ×
          </button>
        </div>
      )}
    </For>
  );
}
