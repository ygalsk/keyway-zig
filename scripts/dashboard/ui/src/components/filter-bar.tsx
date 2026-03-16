// Shared filter bar component

import { For, type JSX } from "solid-js";

export interface FilterConfig {
  id: string;
  type: "select" | "text";
  placeholder: string;
  options?: { value: string; label: string }[];
  width?: string;
}

export function FilterBar(props: { filters: FilterConfig[]; children?: JSX.Element }) {
  return (
    <div class="flex items-center gap-2 flex-wrap">
      <For each={props.filters}>
        {(f) => {
          if (f.type === "select") {
            return (
              <select id={f.id} class="select select-xs select-bordered">
                <option value="">{f.placeholder}</option>
                <For each={f.options || []}>
                  {(o) => <option value={o.value}>{o.label}</option>}
                </For>
              </select>
            );
          }
          return (
            <input
              id={f.id}
              type="text"
              placeholder={f.placeholder}
              class={`input input-xs input-bordered ${f.width || "w-32"}`}
            />
          );
        }}
      </For>
      {props.children}
    </div>
  );
}
