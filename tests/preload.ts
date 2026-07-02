// preload.ts — Shared server lifecycle for bun integration tests
//
// Spawns a keyway server on a random port before all tests,
// kills it after all tests. Exposes globalThis.__KEYWAY_BASE
// and globalThis.__KEYWAY_PORT for test files to use.

import { afterAll, afterEach, beforeAll } from "bun:test";
import { resolve } from "path";

const PROJECT_ROOT = resolve(import.meta.dir, "..");
const BINARY = resolve(PROJECT_ROOT, "zig-out/bin/keyway");
const SCRIPT = resolve(PROJECT_ROOT, "tests/fixtures.lua");
const PORT = 10000 + Math.floor(Math.random() * 50000);

declare global {
  var __KEYWAY_BASE: string;
  var __KEYWAY_PORT: number;
}

let proc: ReturnType<typeof Bun.spawn> | null = null;
let stderr = "";
let stderrDone: Promise<void> | null = null;
let exitCode: number | null = null;
let stopping = false;

async function failIfExited(phase: string) {
  if (exitCode === null || stopping) return;

  await stderrDone;
  if (stderr) console.error(stderr);
  throw new Error(`Keyway server exited during ${phase} with code ${exitCode}`);
}

beforeAll(async () => {
  // Verify binary exists
  const file = Bun.file(BINARY);
  if (!(await file.exists())) {
    throw new Error(
      `Keyway binary not found at ${BINARY}. Run 'zig build' first.`
    );
  }

  proc = Bun.spawn(
    [BINARY, "--script", SCRIPT, "--workers", "1", "--port", String(PORT)],
    {
      cwd: PROJECT_ROOT,
      stdout: "ignore",
      stderr: "pipe",
    }
  );
  stderrDone = new Response(proc.stderr).text().then((text) => {
    stderr = text;
  });
  proc.exited.then((code) => {
    exitCode = code;
  });

  // Poll /health until the server is ready
  const base = `http://127.0.0.1:${PORT}`;
  for (let i = 0; i < 50; i++) {
    await failIfExited("startup");
    try {
      const res = await fetch(`${base}/health`);
      if (res.ok) break;
    } catch {
      // not ready yet
    }
    await Bun.sleep(100);
  }

  // Final check
  await failIfExited("startup");
  const res = await fetch(`${base}/health`).catch(() => null);
  if (!res?.ok) {
    stopping = true;
    proc.kill();
    await stderrDone;
    if (stderr) console.error(stderr);
    throw new Error(`Keyway server did not become ready on port ${PORT}`);
  }

  globalThis.__KEYWAY_BASE = base;
  globalThis.__KEYWAY_PORT = PORT;
});

afterEach(async () => {
  await failIfExited("test run");
});

afterAll(() => {
  if (proc) {
    stopping = true;
    proc.kill();
    proc = null;
  }
});
