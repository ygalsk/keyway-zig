import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

describe("body", () => {
  test("POST /test/echo echoes request body", async () => {
    const res = await fetch(`${base()}/test/echo`, {
      method: "POST",
      body: "payload",
    });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("payload");
  });

  test("GET /test/json returns JSON with message and worker_id", async () => {
    const res = await fetch(`${base()}/test/json`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.message).toBe("hello");
    expect(body.worker_id).toBeDefined();
  });
});
