import { describe, expect, test } from "bun:test";
import { withServer } from "../harness";

describe("worker resilience regressions", () => {
  // (#172)
  test.failing("out-of-range Lua status does not kill the next request", async () => {
    await withServer(async ({ base }) => {
      await fetch(`${base}/test/status/70000`).catch(() => null);
      const next = await fetch(`${base}/test/hello`);
      expect(next.status).toBe(200);
    });
  });

  // (#171)
  test.failing("POST /test/echo accepts a 100KB body", async () => {
    const body = "x".repeat(100 * 1024);
    await withServer(async ({ base }) => {
      const res = await fetch(`${base}/test/echo`, { method: "POST", body });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(body);
    });
  });
});
