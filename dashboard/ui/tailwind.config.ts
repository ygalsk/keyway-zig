import type { Config } from "tailwindcss";

export default {
  content: ["./src/**/*.{ts,tsx}", "./index.html"],
  theme: {
    fontFamily: {
      mono: ['"JetBrains Mono"', "monospace"],
    },
    extend: {
      colors: {
        accent: {
          DEFAULT: "#73B44C",
          light: "#9CCC65",
          dim: "#4a7a2e",
        },
      },
      fontSize: {
        micro: ["8px", { lineHeight: "1.2" }],
        tiny: ["9px", { lineHeight: "1.2" }],
        detail: ["10px", { lineHeight: "1.3" }],
        body: ["11px", { lineHeight: "1.4" }],
      },
    },
  },
  plugins: [require("daisyui")],
  daisyui: {
    themes: [
      {
        keyway: {
          primary: "#73B44C",
          "primary-content": "#0a0f0a",
          secondary: "#5b9cf5",
          accent: "#c084fc",
          neutral: "#1a221a",
          "base-100": "#0a0f0a",
          "base-200": "#141a14",
          "base-300": "#1a221a",
          "base-content": "#c8ccc8",
          info: "#5b9cf5",
          success: "#73B44C",
          warning: "#eab308",
          error: "#ee5555",
        },
      },
    ],
    logs: false,
  },
} satisfies Config;
