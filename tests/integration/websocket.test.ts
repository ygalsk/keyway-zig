import { describe, test, expect } from "bun:test";

const port = () => globalThis.__KEYWAY_PORT;

describe("websocket", () => {
  test("WS /test/ws echoes messages", async () => {
    const received = await new Promise<string>((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port()}/test/ws`);
      const timeout = setTimeout(() => {
        ws.close();
        reject(new Error("WebSocket echo timed out"));
      }, 5000);

      ws.onopen = () => ws.send("hello ws");
      ws.onmessage = (e) => {
        clearTimeout(timeout);
        ws.close();
        resolve(String(e.data));
      };
      ws.onerror = (e) => {
        clearTimeout(timeout);
        reject(new Error(`WebSocket error: ${e}`));
      };
    });

    expect(received).toBe("hello ws");
  });
});
