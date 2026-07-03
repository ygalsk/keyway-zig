import { describe, expect, test } from "bun:test";
import { rawResponseAndClose, rawStatus, withServer } from "../harness";

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

  // (#223)
  test("Content-Length that overflows bytes_consumed + cl returns 413, server keeps serving", async () => {
    await withServer(async ({ base, port }) => {
      const status = await rawStatus(
        port,
        `POST /test/echo HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Length: 18446744073709551600\r\nConnection: close\r\n\r\n`,
      );
      expect(status).toBe(413);

      // A fresh connection (not the one that got the 413) still routes fine —
      // proves the process didn't die. Unchecked, this Content-Length
      // overflows the framing arithmetic and panics the whole worker,
      // taking every SO_REUSEPORT sibling down with it.
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

  // (#226) A pathologically nested JSON body (well within the 64KB read
  // buffer, so it actually reaches json.decode) must not hang or crash the
  // worker — it should fail cleanly, and the worker must keep serving.
  test("POST body with pathologically nested JSON does not crash the worker", async () => {
    const depth = 30000;
    const body = "[".repeat(depth) + "]".repeat(depth);
    await withServer(async ({ base }) => {
      const res = await fetch(`${base}/test/json-decode`, { method: "POST", body });
      expect(res.status).toBeGreaterThanOrEqual(400);
      expect(res.status).toBeLessThan(600);

      const next = await fetch(`${base}/test/hello`);
      expect(next.status).toBe(200);
    });
  });
});

describe("connection close after error responses (#180)", () => {
  // Every error response is served with `Connection: close`, but the server
  // must actually close the socket after writing it — otherwise the header
  // is a protocol lie and the connection gets recycled for keep-alive.
  // Duplicate Content-Length is a known-good 400 trigger (see
  // smuggling.test.ts, #169) that doesn't depend on any not-yet-shipped
  // behavior (#203 is not done yet).
  test("a malformed request (400) closes the socket after the response", async () => {
    await withServer(async ({ port }) => {
      const request =
        `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port}\r\n` +
        `Content-Length: 4\r\n` +
        `Content-Length: 5\r\n\r\n` +
        `hello`;
      const { response, serverClosed } = await rawResponseAndClose(port, request);
      expect(response.split(" ")[1]).toBe("400");
      expect(serverClosed).toBe(true);
    });
  });

  // Mid-stream framing desync: an oversized body (413) leaves the client's
  // in-flight bytes unread. If the server recycled the socket for keep-alive
  // (the pre-#180 bug), those leftover body bytes plus the pipelined second
  // request would get parsed as a new request on the same connection. The
  // server closing the socket after the 413 is what prevents that: the
  // pipelined GET must never be served.
  test("mid-stream desync: an oversized-body 413 closes before a pipelined request can be served", async () => {
    await withServer(async ({ port }) => {
      const oversized = "x".repeat(100 * 1024); // exceeds the 64KB read buffer
      const pipelined =
        `POST /test/echo HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Length: ${oversized.length}\r\n\r\n${oversized}` +
        `GET /test/hello HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`;
      const { response, serverClosed } = await rawResponseAndClose(port, pipelined);
      expect(response.split(" ")[1]).toBe("413");
      expect(response).not.toContain("200 OK");
      expect(serverClosed).toBe(true);
    });
  });
});

describe("connection close semantics (#204)", () => {
  // RFC 9112 §9.6: HTTP/1.0 defaults to close unless the client explicitly
  // asked to keep-alive.
  test("HTTP/1.0 with no Connection header closes (implicit close)", async () => {
    await withServer(async ({ port }) => {
      const { response, serverClosed } = await rawResponseAndClose(
        port,
        `GET /health HTTP/1.0\r\n\r\n`,
      );
      expect(response.split(" ")[1]).toBe("200");
      expect(serverClosed).toBe(true);
    });
  });

  // RFC 9112 §9.6: a client's `Connection: close` request header must be
  // honored on ANY version, including success responses.
  test("HTTP/1.1 with Connection: close closes after the response", async () => {
    await withServer(async ({ port }) => {
      const { response, serverClosed } = await rawResponseAndClose(
        port,
        `GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`,
      );
      expect(response.split(" ")[1]).toBe("200");
      expect(serverClosed).toBe(true);
    });
  });

  // Guard against over-closing: HTTP/1.0 with an explicit keep-alive request
  // must NOT be closed by the server.
  test("HTTP/1.0 with Connection: keep-alive stays open", async () => {
    await withServer(async ({ port }) => {
      const { response, serverClosed } = await rawResponseAndClose(
        port,
        `GET /health HTTP/1.0\r\nConnection: keep-alive\r\n\r\n`,
      );
      expect(response.split(" ")[1]).toBe("200");
      expect(serverClosed).toBe(false);
    });
  });

  // Control: HTTP/1.1 default (no Connection header) keeps the connection open.
  test("HTTP/1.1 with no Connection header stays open (default keep-alive)", async () => {
    await withServer(async ({ port }) => {
      const { response, serverClosed } = await rawResponseAndClose(
        port,
        `GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`,
      );
      expect(response.split(" ")[1]).toBe("200");
      expect(serverClosed).toBe(false);
    });
  });
});
