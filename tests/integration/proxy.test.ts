// Reverse proxy — exercises the async connect/send/recv path (issue #29).
//
// The dashboard config (dashboard/keyway.lua) registers two proxy routes:
//   /__keyway/test-proxy       -> 127.0.0.1:38291 (the upstream spawned below)
//   /__keyway/test-proxy-dead  -> 127.0.0.1:1     (closed port -> 502)
// strip_prefix=true, so /__keyway/test-proxy/small forwards as /small upstream.
//
// We spin up a tiny Bun upstream here so the proxy has something real to talk
// to. The large-response case is the regression target: the upstream reply
// spans many async recv chunks, where a blocking/truncating relay would
// corrupt or short the body.

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import type { Server } from "bun";

const base = () => globalThis.__KEYWAY_BASE;
const UPSTREAM_PORT = 38291;
const LARGE_SIZE = 500_000; // ~32 chunks at a 16 KB recv buffer
const LARGE_BODY = "x".repeat(LARGE_SIZE);

let upstream: Server | null = null;

beforeAll(() => {
  upstream = Bun.serve({
    port: UPSTREAM_PORT,
    async fetch(req) {
      const url = new URL(req.url);
      switch (url.pathname) {
        case "/small":
          return new Response("hello from upstream", {
            headers: { "X-Upstream": "yes" },
          });
        case "/large":
          return new Response(LARGE_BODY);
        case "/echo":
          return new Response(await req.text());
        case "/header":
          // Reflect a forwarded request header back in the body.
          return new Response(req.headers.get("X-Client-Header") ?? "(none)");
        case "/status500":
          return new Response("upstream error", { status: 500 });
        default:
          return new Response("not found", { status: 404 });
      }
    },
  });
});

afterAll(() => {
  upstream?.stop(true);
  upstream = null;
});

describe("reverse proxy", () => {
  test("forwards a small GET and relays the upstream body + headers", async () => {
    const res = await fetch(`${base()}/__keyway/test-proxy/small`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("hello from upstream");
    expect(res.headers.get("x-upstream")).toBe("yes");
  });

  // Regression target for #29: response spans many async recv chunks.
  test("relays a large upstream response intact across many chunks", async () => {
    const res = await fetch(`${base()}/__keyway/test-proxy/large`);
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body.length).toBe(LARGE_SIZE);
    expect(body).toBe(LARGE_BODY);
  });

  test("forwards the request body to the upstream (POST)", async () => {
    const payload = "the quick brown fox".repeat(1000);
    const res = await fetch(`${base()}/__keyway/test-proxy/echo`, {
      method: "POST",
      body: payload,
    });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe(payload);
  });

  test("forwards request headers to the upstream", async () => {
    const res = await fetch(`${base()}/__keyway/test-proxy/header`, {
      headers: { "X-Client-Header": "keyway-rocks" },
    });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("keyway-rocks");
  });

  test("returns 502 when the upstream connection is refused", async () => {
    const res = await fetch(`${base()}/__keyway/test-proxy-dead/whatever`);
    expect(res.status).toBe(502);
  });
});
