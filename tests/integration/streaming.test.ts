import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;
const port = () => globalThis.__KEYWAY_PORT;

/// Read a single-series Prometheus gauge value (worker_id="0", single-worker
/// test server) from /metrics.
async function readGauge(name: string): Promise<number> {
  const res = await fetch(`${base()}/metrics`);
  const text = await res.text();
  const match = text.match(new RegExp(`${name}\\{worker_id="0"\\} (\\d+)`));
  if (!match) throw new Error(`metric ${name} not found in /metrics output`);
  return Number(match[1]);
}

describe("streaming", () => {
  test("GET /test/stream returns chunked body with all chunks", async () => {
    const res = await fetch(`${base()}/test/stream`);
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("chunk1");
    expect(body).toContain("chunk2");
    expect(body).toContain("chunk3");
  });

  // (#173) Disconnecting mid-stream must not leak the stream coroutine: the
  // Lua registry ref (Connection.deinit) and the active-coroutine gauge
  // (dispatchCoroutine's start / the terminal transitions in conn_stream.zig)
  // must stay paired even when the connection never reaches sendTerminalChunk.
  test("stream requests disconnected mid-stream do not leak keyway_lua_coroutines_active", async () => {
    const baseline = await readGauge("keyway_lua_coroutines_active");

    const rounds = 10;
    for (let i = 0; i < rounds; i++) {
      const { promise, resolve } = Promise.withResolvers<void>();
      let acted = false;
      await Bun.connect({
        hostname: "127.0.0.1",
        port: port(),
        socket: {
          open(s) {
            s.write(
              `GET /test/stream HTTP/1.1\r\nHost: 127.0.0.1:${port()}\r\nConnection: keep-alive\r\n\r\n`,
            );
            s.flush();
          },
          data(s) {
            // First bytes back mean the coroutine has already yielded at
            // least once (mid-stream) — RST it now rather than let it
            // finish, so the server is forced through the abnormal-close path.
            if (!acted) {
              acted = true;
              s.terminate();
            }
          },
          close() {
            resolve();
          },
          error() {
            resolve();
          },
        },
      });
      await promise;
    }

    // Give the server a moment to observe the RSTs and clean up.
    let observed = baseline;
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      observed = await readGauge("keyway_lua_coroutines_active");
      if (observed === baseline) break;
      await Bun.sleep(100);
    }

    expect(observed).toBe(baseline);
  });
});
