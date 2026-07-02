import { describe, expect, test } from "bun:test";
import { rawStatus, withServer } from "../harness";

describe("worker resilience regressions", () => {
  // (#172)
  test("out-of-range Lua status does not kill the next request", async () => {
    await withServer(async ({ base }) => {
      const bad = await fetch(`${base}/test/status/70000`);
      expect(bad.status).toBe(500);

      const next = await fetch(`${base}/test/hello`);
      expect(next.status).toBe(200);
    });
  });

  // (#171)
  test("POST /test/echo body exceeding the read buffer returns 413, server keeps serving", async () => {
    await withServer(async ({ base, port }) => {
      const oversized = "x".repeat(100 * 1024);
      const status = await rawStatus(
        port,
        `POST /test/echo HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Length: ${oversized.length}\r\nConnection: close\r\n\r\n${oversized}`,
      );
      expect(status).toBe(413);

      // A fresh connection (not the one that got the 413) still routes fine.
      const next = await fetch(`${base}/test/hello`);
      expect(next.status).toBe(200);
    });
  });

  // (#171)
  test("POST /test/echo body within the read buffer echoes correctly", async () => {
    const body = "x".repeat(32 * 1024);
    await withServer(async ({ base }) => {
      const res = await fetch(`${base}/test/echo`, { method: "POST", body });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(body);
    });
  });
});
