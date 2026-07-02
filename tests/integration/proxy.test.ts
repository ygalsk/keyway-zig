// Reverse proxy — exercises the async connect/send/recv path (issue #29).
//
// The integration fixtures (tests/fixtures.lua) register three proxy routes:
//   /__keyway/test-proxy       -> 127.0.0.1:38291 (the upstream spawned below)
//   /__keyway/test-proxy-dead  -> 127.0.0.1:1     (closed port -> 502)
//   /__keyway/test-proxy-hung  -> 127.0.0.1:38292 (accepts, never responds -> 504)
// strip_prefix=true, so /__keyway/test-proxy/small forwards as /small upstream.
//
// We spin up a tiny Bun upstream here so the proxy has something real to talk
// to. The large-response case is the regression target: the upstream reply
// spans many async recv chunks, where a blocking/truncating relay would
// corrupt or short the body.

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import type { Server, TCPSocketListener } from "bun";

const base = () => globalThis.__KEYWAY_BASE;
const port = () => globalThis.__KEYWAY_PORT;
const UPSTREAM_PORT = 38291;
const HUNG_UPSTREAM_PORT = 38292;
const LARGE_SIZE = 500_000; // ~32 chunks at a 16 KB recv buffer
const LARGE_BODY = "x".repeat(LARGE_SIZE);

let upstream: Server | null = null;
let hungUpstream: TCPSocketListener | null = null;

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
        case "/dump":
          // Reflect what the upstream actually received (#170): body plus
          // presence/value of the framing headers, so the test can assert
          // the proxy regenerated Content-Length instead of forwarding a
          // stale Transfer-Encoding alongside an already-de-chunked body.
          return Response.json({
            body: await req.text(),
            contentLength: req.headers.get("content-length"),
            transferEncoding: req.headers.get("transfer-encoding"),
          });
        default:
          return new Response("not found", { status: 404 });
      }
    },
  });

  // Raw TCP listener (not Bun.serve, which always answers): accepts the
  // connection and the request bytes, then never writes a response and
  // never closes — the shape of a hung/non-compliant upstream (#72).
  hungUpstream = Bun.listen({
    hostname: "127.0.0.1",
    port: HUNG_UPSTREAM_PORT,
    socket: {
      data() {},
      open() {},
      close() {},
      drain() {},
      error() {},
    },
  });
});

afterAll(() => {
  upstream?.stop(true);
  upstream = null;
  hungUpstream?.stop(true);
  hungUpstream = null;
});

// Raw-socket helper (mirrors smuggling.test.ts's rawStatus): fetch() can't
// hand-roll chunked request framing, and we need that to reach the proxy
// with a real Transfer-Encoding: chunked request. Resolves as soon as the
// full response (headers + Content-Length body bytes) has arrived — keyway
// keeps the client connection alive (only the upstream leg forces
// Connection: close), so waiting on socket close would just burn the
// fallback timeout on every run.
async function rawRequest(request: string): Promise<string> {
  let buf = "";
  const { promise, resolve } = Promise.withResolvers<string>();
  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port: port(),
    socket: {
      data(s, data) {
        buf += data.toString();
        const headerEnd = buf.indexOf("\r\n\r\n");
        if (headerEnd === -1) return;
        const match = buf.slice(0, headerEnd).match(/content-length:\s*(\d+)/i);
        const bodyLen = match ? Number(match[1]) : 0;
        if (buf.length >= headerEnd + 4 + bodyLen) {
          resolve(buf);
          s.end();
        }
      },
      close() {
        resolve(buf);
      },
      error(_socket, error) {
        resolve(buf || String(error));
      },
    },
  });
  socket.write(request);
  socket.flush();
  const resp = await Promise.race([promise, Bun.sleep(2000).then(() => buf)]);
  socket.end();
  return resp;
}

describe("reverse proxy", () => {
  // (#170) Regression: the parser decodes a chunked request body before
  // proxy.zig ever sees it, but buildUpstreamRequest used to forward the
  // client's original Transfer-Encoding: chunked header unchanged and append
  // the already-decoded body — the upstream then saw a framing header that
  // didn't match the bytes on the wire. It must regenerate Content-Length
  // and never forward Transfer-Encoding/Content-Length from the client.
  test("de-chunks a chunked request body and forwards Content-Length, not Transfer-Encoding", async () => {
    const raw = await rawRequest(
      `POST /__keyway/test-proxy/dump HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Transfer-Encoding: chunked\r\n` +
        `Connection: close\r\n\r\n` +
        `5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n`,
    );
    const bodyStart = raw.indexOf("\r\n\r\n") + 4;
    const parsed = JSON.parse(raw.slice(bodyStart));
    expect(parsed.body).toBe("hello world");
    expect(parsed.contentLength).toBe("11");
    expect(parsed.transferEncoding).toBeNull();
  });

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

  // Regression target for #73: the proxy used to hardcode status 200 in its
  // access log / metrics regardless of what the upstream actually returned.
  test("relays and logs the real upstream status (500)", async () => {
    const res = await fetch(`${base()}/__keyway/test-proxy/status500`);
    expect(res.status).toBe(500);
    expect(await res.text()).toBe("upstream error");

    const metrics = await (await fetch(`${base()}/metrics`)).text();
    expect(metrics).toMatch(/keyway_http_requests_total\{[^}]*status="500"[^}]*\}/);
  });
});

describe("reverse proxy upstream deadline (#72)", () => {
  // Runs against the real PROXY_UPSTREAM_TIMEOUT_MS (config.zig, 30s) — no
  // test-only config surface for a shorter deadline (keyway.proxy routes
  // don't take a timeout option, and adding one just for this test would be
  // new production API surface for a value that's otherwise a fixed
  // constant). The per-test timeout override below is local to this test and
  // doesn't touch the suite's shared 10s default (see tests/preload.ts).
  test(
    "hung upstream (accepts, never responds) gets 504 after the deadline; server stays healthy after",
    async () => {
      const start = Date.now();
      const res = await fetch(`${base()}/__keyway/test-proxy-hung/whatever`);
      const elapsed = Date.now() - start;
      expect(res.status).toBe(504);
      // Sanity check this actually rode out the real deadline rather than
      // failing fast on some other path (e.g. connect refused -> 502).
      expect(elapsed).toBeGreaterThan(25_000);

      // The connection must be usable afterward — not left half-torn-down —
      // and the worker must still be accepting/serving other requests.
      const health = await fetch(`${base()}/health`);
      expect(health.status).toBe(200);
    },
    35_000,
  );
});
