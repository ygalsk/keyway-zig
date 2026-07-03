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

describe("sse", () => {
  test("GET /test/sse returns event stream, POST /test/broadcast delivers events", async () => {
    // Connect to SSE endpoint
    const controller = new AbortController();
    const res = await fetch(`${base()}/test/sse`, {
      signal: controller.signal,
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/event-stream");

    const reader = res.body!.getReader();
    const decoder = new TextDecoder();

    // Give the SSE subscription time to register
    await Bun.sleep(200);

    // Broadcast a message
    const broadcastRes = await fetch(`${base()}/test/broadcast`, {
      method: "POST",
      body: "test-payload",
    });
    expect(broadcastRes.status).toBe(200);

    // Read from the stream until we find our payload or timeout
    let collected = "";
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      const { value, done } = await Promise.race([
        reader.read(),
        Bun.sleep(500).then(() => ({ value: undefined, done: false })),
      ]);
      if (done) break;
      if (value) collected += decoder.decode(value, { stream: true });
      if (collected.includes("test-payload")) break;
    }

    controller.abort();
    reader.cancel().catch(() => {});

    expect(collected).toContain("test-payload");
  });

  // (#173) A subscriber that never drains its queue must be disconnected
  // once its backlog exceeds SSE_MAX_QUEUED_BYTES, not buffered forever.
  // close() decrements keyway_connections_active synchronously, so that
  // gauge returning to baseline is our signal the server dropped it.
  test("SSE slow consumer is disconnected rather than growing unbounded", async () => {
    const baseline = await readGauge("keyway_connections_active");

    const socket = await Bun.connect({
      hostname: "127.0.0.1",
      port: port(),
      socket: {
        open(s) {
          s.write(
            `GET /test/sse HTTP/1.1\r\nHost: 127.0.0.1:${port()}\r\nConnection: keep-alive\r\n\r\n`,
          );
          s.flush();
          // Never drain the response — simulate a stalled consumer so the
          // server's queued backlog for this connection can only grow.
          s.pause();
        },
        data() {},
        close() {},
        error() {},
      },
    });

    try {
      // Comfortably over SSE_MAX_QUEUED_BYTES (1 MB) and past typical kernel
      // receive-buffer defaults, so the paused socket forces real backpressure.
      const payload = "x".repeat(50_000);
      const maxBroadcasts = 200;
      let disconnected = false;
      for (let i = 0; i < maxBroadcasts && !disconnected; i++) {
        await fetch(`${base()}/test/broadcast`, { method: "POST", body: payload });
        if (i % 5 === 0) {
          disconnected = (await readGauge("keyway_connections_active")) === baseline;
        }
      }
      if (!disconnected) {
        disconnected = (await readGauge("keyway_connections_active")) === baseline;
      }

      expect(disconnected).toBe(true);
    } finally {
      socket.terminate();
    }
  }, 20000);

  // (#192) ctx.on_message/on_close ref the handler into the Lua registry
  // before the upgrade runs (lua_api.zig); the SSE reject path (missing
  // sse_room -> 400) never frees them unless conn_sse.handleSseUpgrade
  // unrefs on every return, mirroring the WS twin (#175). There's no
  // network-reachable signal for Lua registry size, so this can't assert
  // the leak is fixed directly — it only proves the reject path keeps
  // working (and doesn't wedge/crash) across many upgrade attempts that
  // each ref two callbacks. The fix itself is inspection-verified.
  test("repeated rejected SSE upgrades with on_message/on_close set stay healthy", async () => {
    for (let i = 0; i < 50; i++) {
      const res = await fetch(`${base()}/test/sse-no-room`);
      expect(res.status).toBe(400);
      await res.arrayBuffer();
    }

    // Server is still serving requests normally after the loop.
    const health = await fetch(`${base()}/test/hello`);
    expect(health.status).toBe(200);
  });
});
