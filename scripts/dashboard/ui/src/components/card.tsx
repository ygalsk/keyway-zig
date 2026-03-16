// Shared card component

import type { JSX } from "solid-js";

interface CardProps {
  children: JSX.Element;
  border?: boolean;
  borderColor?: string;
  padding?: "compact" | "normal";
  interactive?: boolean;
}

export function Card(props: CardProps) {
  const pad = () => props.padding === "compact" ? "p-2" : "p-3";
  const border = () => props.border ? `border-l-2 ${props.borderColor || "border-base-300"}` : "";
  const hover = () => props.interactive ? "cursor-pointer hover:bg-base-300/50 transition-colors" : "";
  return (
    <div class={`bg-base-200 rounded ${pad()} ${border()} ${hover()}`}>
      {props.children}
    </div>
  );
}
