import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

describe("streaming", () => {
  test("GET /test/stream returns chunked body with all chunks", async () => {
    const res = await fetch(`${base()}/test/stream`);
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("chunk1");
    expect(body).toContain("chunk2");
    expect(body).toContain("chunk3");
  });
});
