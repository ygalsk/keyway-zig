import { resolve } from "path";

const PROJECT_ROOT = resolve(import.meta.dir, "..");
const BINARY = resolve(PROJECT_ROOT, "zig-out/bin/keyway");
const SCRIPT = resolve(PROJECT_ROOT, "tests/fixtures.lua");

/// Send a raw HTTP request over its own socket and return the response status
/// code. Bypasses fetch()'s connection pooling — needed when a test wants a
/// guaranteed-fresh connection (e.g. checking behavior after a response that
/// advertises `Connection: close`, see #180).
export async function rawStatus(port: number, request: string): Promise<number> {
  let buf = "";
  const { promise, resolve } = Promise.withResolvers<string>();
  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port,
    socket: {
      data(s, data) {
        buf += data.toString();
        if (buf.includes("\r\n\r\n")) {
          resolve(buf);
          s.end();
        }
      },
      close() {
        resolve(buf);
      },
      error(_socket, error) {
        resolve(buf || String(error));
      },
    },
  });
  socket.write(request);
  socket.flush();
  const resp = await Promise.race([promise, Bun.sleep(1500).then(() => "")]);
  socket.end();
  return Number(resp.split(" ")[1]);
}

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
