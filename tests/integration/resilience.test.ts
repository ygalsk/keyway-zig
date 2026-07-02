import { describe, expect, test } from "bun:test";
import { resolve } from "path";

const PROJECT_ROOT = resolve(import.meta.dir, "../..");
const BINARY = resolve(PROJECT_ROOT, "zig-out/bin/keyway");
const SCRIPT = resolve(PROJECT_ROOT, "tests/fixtures.lua");
const base = () => globalThis.__KEYWAY_BASE;

async function withServer(fn: (base: string) => Promise<void>) {
  const port = 10000 + Math.floor(Math.random() * 50000);
  const proc = Bun.spawn(
    [BINARY, "--script", SCRIPT, "--workers", "1", "--port", String(port)],
    { cwd: PROJECT_ROOT, stdout: "ignore", stderr: "pipe" },
  );
  const stderr = new Response(proc.stderr).text();

  try {
    const url = `http://127.0.0.1:${port}`;
    for (let i = 0; i < 50; i++) {
      const res = await fetch(`${url}/health`).catch(() => null);
      if (res?.ok) return await fn(url);
      await Bun.sleep(100);
    }
    throw new Error(`isolated keyway did not start: ${await stderr}`);
  } finally {
    proc.kill("SIGKILL");
    await Promise.race([proc.exited.catch(() => {}), Bun.sleep(500)]);
  }
}

describe("worker resilience regressions", () => {
  // (#172)
  test.failing("out-of-range Lua status does not kill the next request", async () => {
    await withServer(async (url) => {
      await fetch(`${url}/test/status/70000`).catch(() => null);
      const next = await fetch(`${url}/test/hello`);
      expect(next.status).toBe(200);
    });
  });

  // (#171)
  test.failing("POST /test/echo accepts a 100KB body", async () => {
    const body = "x".repeat(100 * 1024);
    const res = await fetch(`${base()}/test/echo`, { method: "POST", body });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe(body);
  });
});
