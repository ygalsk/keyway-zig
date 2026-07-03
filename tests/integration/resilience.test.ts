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

  // (#171)
  test("POST /test/echo body within the read buffer echoes correctly", async () => {
    const body = "x".repeat(32 * 1024);
    await withServer(async ({ base }) => {
      const res = await fetch(`${base}/test/echo`, { method: "POST", body });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(body);
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
