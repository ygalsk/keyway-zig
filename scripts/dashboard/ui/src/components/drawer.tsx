// Console drawer — manages lazy mounting of console into the bottom drawer

import { createSignal, Show, onCleanup } from "solid-js";
import { state } from "../state";
import { ConsoleCore } from "../views/console";

export function Drawer(props: { ref?: (el: HTMLDivElement) => void }) {
  let drawerEl!: HTMLDivElement;
  const s = state();
  const [mounted, setMounted] = createSignal(false);

  // Mount console lazily on first open
  function ensureMounted() {
    if (!mounted()) setMounted(true);
  }

  // Expose the drawer element and mount trigger via state
  return (
    <div
      ref={(el) => { drawerEl = el; props.ref?.(el); }}
      id="console-drawer"
      role="complementary"
      class="border-t border-base-300 bg-base-200 overflow-hidden transition-[height] duration-300 ease-in-out"
      style={{ height: s.drawerOpen() ? (window.innerWidth < 640 ? "60vh" : "40vh") : "0px" }}
    >
      <Show when={mounted() || s.drawerOpen()}>
        {(() => { ensureMounted(); return <ConsoleCore />; })()}
      </Show>
    </div>
  );
}
