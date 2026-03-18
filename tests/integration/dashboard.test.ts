import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

describe("dashboard", () => {
  test("GET /__keyway/dashboard returns HTML", async () => {
    const res = await fetch(`${base()}/__keyway/dashboard`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
  });
});
