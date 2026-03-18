import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

describe("headers", () => {
  test("GET /test/headers returns X-Echo-UA and X-Worker", async () => {
    const res = await fetch(`${base()}/test/headers`);
    expect(res.status).toBe(200);
    expect(res.headers.get("X-Echo-UA")).toBeTruthy();
    expect(res.headers.get("X-Worker")).toBeTruthy();
  });

  test("GET /test/mw returns middleware headers", async () => {
    const res = await fetch(`${base()}/test/mw`);
    expect(res.status).toBe(200);
    expect(res.headers.get("X-MW-Before")).toBeTruthy();
  });
});
