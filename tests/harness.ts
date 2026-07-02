import { resolve } from "path";

const PROJECT_ROOT = resolve(import.meta.dir, "..");
const BINARY = resolve(PROJECT_ROOT, "zig-out/bin/keyway");
const SCRIPT = resolve(PROJECT_ROOT, "tests/fixtures.lua");

export async function withServer(fn: (server: { base: string; port: number }) => Promise<void>) {
  const port = 10000 + Math.floor(Math.random() * 50000);
  const proc = Bun.spawn(
    [BINARY, "--script", SCRIPT, "--workers", "1", "--port", String(port)],
    { cwd: PROJECT_ROOT, stdout: "ignore", stderr: "pipe" },
  );
  const stderr = new Response(proc.stderr).text();

  try {
    const base = `http://127.0.0.1:${port}`;
    for (let i = 0; i < 50; i++) {
      const res = await fetch(`${base}/health`).catch(() => null);
      if (res?.ok) return await fn({ base, port });
      await Bun.sleep(100);
    }
    throw new Error(`isolated keyway did not start: ${await stderr}`);
  } finally {
    proc.kill("SIGKILL");
    await Promise.race([proc.exited.catch(() => {}), Bun.sleep(500)]);
  }
}
