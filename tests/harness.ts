import { resolve } from "path";

const PROJECT_ROOT = resolve(import.meta.dir, "..");
const BINARY = resolve(PROJECT_ROOT, "zig-out/bin/keyway");
const SCRIPT = resolve(PROJECT_ROOT, "tests/fixtures.lua");

/// Send a raw HTTP request over its own socket and return the full response
/// text (status line + headers, and body if it arrived before the deadline).
/// Bypasses fetch()'s connection pooling — needed when a test wants a
/// guaranteed-fresh connection (e.g. checking behavior after a response that
/// advertises `Connection: close`, see #180).
export async function rawResponse(port: number, request: string): Promise<string> {
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
  return resp;
}

/// Same as `rawResponse`, but returns just the status code.
export async function rawStatus(port: number, request: string): Promise<number> {
  const resp = await rawResponse(port, request);
  return Number(resp.split(" ")[1]);
}

/// Send a raw request on its own socket and observe whether the SERVER closes
/// the connection (FIN/EOF) after responding, as opposed to keeping it open
/// for keep-alive. Unlike `rawResponse` (which closes the socket itself on
/// seeing the header terminator), this waits for the response headers, then
/// watches a short quiet window for the socket's `close` callback to fire.
/// See #180 (error responses advertise `Connection: close` but must also
/// actually close the socket).
export async function rawResponseAndClose(
  port: number,
  request: string,
  waitMs = 500,
): Promise<{ response: string; serverClosed: boolean }> {
  let buf = "";
  const { promise: headersPromise, resolve: resolveHeaders } = Promise.withResolvers<void>();
  const { promise: closedPromise, resolve: resolveClosed } = Promise.withResolvers<void>();
  let headersSeen = false;
  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port,
    socket: {
      data(_s, data) {
        buf += data.toString();
        if (!headersSeen && buf.includes("\r\n\r\n")) {
          headersSeen = true;
          resolveHeaders();
        }
      },
      close() {
        resolveClosed();
      },
      error() {
        resolveClosed();
      },
    },
  });
  socket.write(request);
  socket.flush();
  await Promise.race([headersPromise, Bun.sleep(1500).then(() => {})]);
  const serverClosed = await Promise.race([
    closedPromise.then(() => true),
    Bun.sleep(waitMs).then(() => false),
  ]);
  socket.end();
  return { response: buf, serverClosed };
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
