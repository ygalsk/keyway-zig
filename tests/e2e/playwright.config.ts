import { defineConfig } from "@playwright/test";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = 19876;
const PROJECT_ROOT = resolve(__dirname, "../..");

export default defineConfig({
  testDir: ".",
  timeout: 30000,
  retries: 0,
  workers: 1,
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    headless: true,
  },
  projects: [
    {
      name: "chromium",
      use: { browserName: "chromium" },
    },
  ],
  webServer: {
    command: `./zig-out/bin/keyway --script scripts/dashboard/keyway.lua --workers 1 --port ${PORT}`,
    cwd: PROJECT_ROOT,
    port: PORT,
    reuseExistingServer: !process.env.CI,
    timeout: 10000,
  },
});
