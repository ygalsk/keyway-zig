// Sparkline — tiny inline canvas polyline

import { onMount, onCleanup, createEffect } from "solid-js";
import { colors } from "../theme";

interface SparklineProps {
  data: number[];
  width?: number;
  height?: number;
  color?: string;
}

export function Sparkline(props: SparklineProps) {
  let canvas!: HTMLCanvasElement;
  let rangeLabel!: HTMLSpanElement;
  const w = () => props.width || 100;
  const h = () => props.height || 20;
  const color = () => props.color || colors.accent;

  function formatVal(v: number): string {
    if (v >= 1000000) return (v / 1000000).toFixed(1) + "M";
    if (v >= 1000) return (v / 1000).toFixed(1) + "k";
    return v < 10 ? v.toFixed(1) : String(Math.round(v));
  }

  createEffect(() => {
    const data = props.data;
    const ctx = canvas.getContext("2d")!;
    const cw = w();
    const ch = h();
    const c = color();

    ctx.clearRect(0, 0, cw, ch);
    if (data.length < 2) { rangeLabel.textContent = ""; return; }

    const max = Math.max(...data, 1);
    const min = Math.min(...data, 0);
    const range = max - min || 1;
    const step = cw / (data.length - 1);

    ctx.beginPath();
    ctx.strokeStyle = c;
    ctx.lineWidth = 1.5;
    ctx.lineJoin = "round";

    for (let i = 0; i < data.length; i++) {
      const x = i * step;
      const y = ch - ((data[i] - min) / range) * (ch - 2) - 1;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();

    ctx.lineTo((data.length - 1) * step, ch);
    ctx.lineTo(0, ch);
    ctx.closePath();
    ctx.fillStyle = c + "15";
    ctx.fill();

    rangeLabel.textContent = formatVal(min) + "-" + formatVal(max);
  });

  return (
    <div class="sparkline-enter" style={{ position: "relative", width: w() + "px", height: h() + "px" }}>
      <canvas ref={canvas} width={w()} height={h()} style="display:block" />
      <span
        ref={rangeLabel}
        style="position:absolute;bottom:0;right:0;font-size:8px;line-height:1;color:rgba(255,255,255,0.3);pointer-events:none;"
      />
    </div>
  );
}
