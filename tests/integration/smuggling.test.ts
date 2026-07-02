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
});
