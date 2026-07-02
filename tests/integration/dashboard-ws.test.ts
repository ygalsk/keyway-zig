// /__keyway/ws command round-trips — the dashboard's console/live-reload UI
// drives this socket. Only commands that actually exist in ws_commands
// (dashboard/keyway.lua) are covered: ping and lua.

import { describe, test, expect } from "bun:test";

const port = () => globalThis.__KEYWAY_PORT;

function sendAndReceive(payload: object): Promise<any> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port()}/__keyway/ws`);
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error("dashboard ws command timed out"));
    }, 5000);

    ws.onopen = () => ws.send(JSON.stringify(payload));
    ws.onmessage = (e) => {
      clearTimeout(timeout);
      ws.close();
      resolve(JSON.parse(String(e.data)));
    };
    ws.onerror = (e) => {
      clearTimeout(timeout);
      reject(new Error(`WebSocket error: ${e}`));
    };
  });
}

describe("dashboard ws commands", () => {
  test("cmd:ping replies with pong + worker_id", async () => {
    const msg = await sendAndReceive({ cmd: "ping" });
    expect(msg.cmd).toBe("pong");
    expect(typeof msg.worker_id).toBe("number");
  });

  test("cmd:lua evaluates code and returns the result", async () => {
    const msg = await sendAndReceive({ cmd: "lua", code: "1+1" });
    expect(msg.cmd).toBe("lua");
    expect(msg.result).toBe("2");
  });

  test("cmd:lua surfaces a compile error instead of hanging", async () => {
    const msg = await sendAndReceive({ cmd: "lua", code: "this is not lua(" });
    expect(msg.cmd).toBe("lua");
    expect(typeof msg.error).toBe("string");
  });

  test("unknown command returns an error, not a hang", async () => {
    const msg = await sendAndReceive({ cmd: "does-not-exist" });
    expect(typeof msg.error).toBe("string");
  });
});
