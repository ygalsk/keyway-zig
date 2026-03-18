import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

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
});
