import { describe, expect, test } from "bun:test";

const port = () => globalThis.__KEYWAY_PORT;

async function rawStatus(request: string): Promise<number> {
  let buf = "";
  const { promise, resolve } = Promise.withResolvers<string>();
  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port: port(),
    socket: {
      data(s, data) {
        buf += data.toString();
        if (buf.includes("\r\n\r\n")) {
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
  const resp = await Promise.race([
    promise,
    Bun.sleep(1500).then(() => ""),
  ]);
  socket.end();
  return Number(resp.split(" ")[1]);
}

describe("request smuggling regressions", () => {
  // (#169)
  test.failing("rejects requests with both Content-Length and Transfer-Encoding", async () => {
    const status = await rawStatus(
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
  test.failing("rejects duplicate Content-Length headers", async () => {
    const status = await rawStatus(
      `POST /test/echo HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Content-Length: 4\r\n` +
        `Content-Length: 5\r\n` +
        `Connection: close\r\n\r\n` +
        `hello`,
    );
    expect(status).toBe(400);
  });
});
