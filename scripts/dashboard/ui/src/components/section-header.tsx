// Shared section header bar

import type { JSX } from "solid-js";

export function SectionHeader(props: { title: string; children?: JSX.Element }) {
  return (
    <div class="flex items-center gap-3 px-4 py-2 border-b border-base-300 bg-base-200/50">
      <h2 class="text-sm font-semibold text-base-content/80">{props.title}</h2>
      <div class="flex-1" />
      {props.children}
    </div>
  );
}
