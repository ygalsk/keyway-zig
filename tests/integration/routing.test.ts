import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;

describe("routing", () => {
  test("GET /test/hello returns 200 with hello world", async () => {
    const res = await fetch(`${base()}/test/hello`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("hello world");
  });

  test("GET /test/users/42 returns JSON with id", async () => {
    const res = await fetch(`${base()}/test/users/42`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.id).toBe("42");
  });

  test("GET /test/search?q=foo returns JSON with query param", async () => {
    const res = await fetch(`${base()}/test/search?q=foo`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.q).toBe("foo");
  });

  test("GET /test/status/201 returns 201", async () => {
    const res = await fetch(`${base()}/test/status/201`);
    expect(res.status).toBe(201);
  });

  test("GET /test/status/404 returns 404", async () => {
    const res = await fetch(`${base()}/test/status/404`);
    expect(res.status).toBe(404);
  });
});
