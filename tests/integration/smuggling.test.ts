import { describe, expect, test } from "bun:test";
import { rawStatus } from "../harness";

const port = () => globalThis.__KEYWAY_PORT;

describe("request smuggling regressions", () => {
  // (#169)
  test("rejects requests with both Content-Length and Transfer-Encoding", async () => {
    const status = await rawStatus(
      port(),
      `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Content-Length: 4\r\n` +
        `Transfer-Encoding: chunked\r\n` +
        `Connection: close\r\n\r\n` +
        `4\r\nping\r\n0\r\n\r\n`,
    );
    expect(status).toBe(400);
  });

  // (#169)
  test("rejects duplicate Content-Length headers", async () => {
    const status = await rawStatus(
      port(),
      `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Content-Length: 4\r\n` +
        `Content-Length: 5\r\n` +
        `Connection: close\r\n\r\n` +
        `hello`,
    );
    expect(status).toBe(400);
  });

  // (#169)
  test("rejects malformed Content-Length", async () => {
    const status = await rawStatus(
      port(),
      `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Content-Length: abc\r\n` +
        `Connection: close\r\n\r\n` +
        `hello`,
    );
    expect(status).toBe(400);
  });

  // (#169)
  test("rejects signed Content-Length", async () => {
    const status = await rawStatus(
      port(),
      `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Content-Length: +4\r\n` +
        `Connection: close\r\n\r\n` +
        `ping`,
    );
    expect(status).toBe(400);
  });

  // (#245) RFC 9112 §5.2. picohttpparser accepts obs-fold and reports the
  // folded line as a header with a NULL name: a null deref in safe builds,
  // and in ReleaseFast a bare `: value` line forwarded to the upstream.
  for (const [label, ws] of [
    ["SP", "  "],
    ["HTAB", "\t"],
  ] as const) {
    test(`rejects obs-fold continuation line (${label})`, async () => {
      const status = await rawStatus(
        port(),
        `POST /test/echo HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${port()}\r\n` +
          `X-Y: 1\r\n${ws}2\r\n` +
          `Content-Length: 0\r\n` +
          `Connection: close\r\n\r\n`,
      );
      expect(status).toBe(400);
    });
  }

  // (#245) These two were reported alongside obs-fold as hangs; they were
  // always correct — the obs-fold crash was killing the run around them.
  test("rejects whitespace before the header colon", async () => {
    const status = await rawStatus(
      port(),
      `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Foo : bar\r\n` +
        `Content-Length: 0\r\n` +
        `Connection: close\r\n\r\n`,
    );
    expect(status).toBe(400);
  });

  test("rejects Transfer-Encoding with a non-chunked final coding", async () => {
    const status = await rawStatus(
      port(),
      `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Transfer-Encoding: chunked, identity\r\n` +
        `Connection: close\r\n\r\n` +
        `0\r\n\r\n`,
    );
    expect(status).toBe(400);
  });
});
