import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

describe("health", () => {
  test("GET /health returns 200 with status ok", async () => {
    const res = await fetch(`${base()}/health`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
  });

  test("GET /nonexistent returns 404", async () => {
    const res = await fetch(`${base()}/nonexistent`);
    expect(res.status).toBe(404);
  });
});
