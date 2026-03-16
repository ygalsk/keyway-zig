// Shared feedback states: empty, loading, error

import { For } from "solid-js";

export function EmptyState(props: { message: string; hint?: string }) {
  return (
    <div class="flex flex-col items-center justify-center py-8 text-center">
      <div class="text-detail text-base-content/30">{props.message}</div>
      {props.hint && <div class="text-tiny text-base-content/20 mt-1">{props.hint}</div>}
    </div>
  );
}

export function LoadingState(props: { rows?: number }) {
  const rows = () => props.rows ?? 3;
  return (
    <div class="space-y-2 p-3">
      <For each={Array.from({ length: rows() }, (_, i) => i)}>
        {(i) => <div class="skeleton-pulse rounded h-4" style={{ width: `${80 - i * 15}%` }} />}
      </For>
    </div>
  );
}

export function ErrorState(props: { message: string; onRetry?: () => void }) {
  return (
    <div class="flex flex-col items-center justify-center py-8 text-center">
      <div class="text-detail text-error">{props.message}</div>
      {props.onRetry && (
        <button class="btn btn-xs btn-ghost text-error mt-2" onClick={props.onRetry}>
          Retry
        </button>
      )}
    </div>
  );
}
