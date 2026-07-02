import { describe, test, expect } from "bun:test";

const port = () => globalThis.__KEYWAY_PORT;
const enc = new TextEncoder();
const dec = new TextDecoder();

function append(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

function headerEnd(buf: Uint8Array): number {
  for (let i = 3; i < buf.length; i++) {
    if (buf[i - 3] === 13 && buf[i - 2] === 10 && buf[i - 1] === 13 && buf[i] === 10) {
      return i + 1;
    }
  }
  return -1;
}

function maskedFrame(opcode: number, text: string, fin = true): Uint8Array {
  const payload = enc.encode(text);
  if (payload.length > 0xffff) throw new Error("test frame too large");

  const extended = payload.length >= 126;
  const frame = new Uint8Array(2 + (extended ? 2 : 0) + 4 + payload.length);
  let pos = 0;
  frame[pos++] = (fin ? 0x80 : 0) | opcode;
  if (extended) {
    frame[pos++] = 0x80 | 126;
    frame[pos++] = payload.length >> 8;
    frame[pos++] = payload.length & 0xff;
  } else {
    frame[pos++] = 0x80 | payload.length;
  }

  const mask = new Uint8Array([0x12, 0x34, 0x56, 0x78]);
  frame.set(mask, pos);
  pos += 4;
  for (let i = 0; i < payload.length; i++) frame[pos + i] = payload[i] ^ mask[i % 4];
  return frame;
}

function readServerTextFrame(buf: Uint8Array): { text: string; rest: Uint8Array } | null {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  let len = buf[1] & 0x7f;
  let pos = 2;

  if (len === 126) {
    if (buf.length < 4) return null;
    len = (buf[2] << 8) | buf[3];
    pos = 4;
  } else if (len === 127) {
    throw new Error("unexpected 64-bit server frame");
  }

  if (buf.length < pos + len) return null;
  if (opcode === 0x8) throw new Error("server closed websocket");
  return { text: dec.decode(buf.slice(pos, pos + len)), rest: buf.slice(pos + len) };
}

async function rawWsEcho(sendFrames: (socket: any) => void | Promise<void>): Promise<string> {
  const done = Promise.withResolvers<string>();
  let socket: any = null;
  let settled = false;
  let upgraded = false;
  let buf = new Uint8Array();

  const timeout = setTimeout(() => settle(() => done.reject(new Error("raw WebSocket echo timed out"))), 5000);
  const settle = (finish: () => void) => {
    if (settled) return;
    settled = true;
    clearTimeout(timeout);
    socket?.end();
    finish();
  };

  socket = await Bun.connect({
    hostname: "127.0.0.1",
    port: port(),
    socket: {
      data(s, data) {
        buf = append(buf, new Uint8Array(data));
        if (!upgraded) {
          const end = headerEnd(buf);
          if (end === -1) return;
          const head = dec.decode(buf.slice(0, end));
          if (!head.startsWith("HTTP/1.1 101")) {
            settle(() => done.reject(new Error(`WebSocket upgrade failed: ${head.split("\r\n")[0]}`)));
            return;
          }
          upgraded = true;
          buf = buf.slice(end);
          Promise.resolve(sendFrames(s)).catch((e) => settle(() => done.reject(e)));
        }

        try {
          const frame = readServerTextFrame(buf);
          if (frame) settle(() => done.resolve(frame.text));
        } catch (e) {
          settle(() => done.reject(e));
        }
      },
      close() {
        if (!settled) settle(() => done.reject(new Error("raw WebSocket closed before echo")));
      },
      error(_s, e) {
        settle(() => done.reject(e));
      },
    },
  });

  socket.write(
    `GET /test/ws HTTP/1.1\r\nHost: 127.0.0.1:${port()}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`,
  );
  socket.flush();
  return done.promise;
}

describe("websocket", () => {
  test("WS /test/ws echoes messages", async () => {
    const received = await new Promise<string>((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port()}/test/ws`);
      const timeout = setTimeout(() => {
        ws.close();
        reject(new Error("WebSocket echo timed out"));
      }, 5000);

      ws.onopen = () => ws.send("hello ws");
      ws.onmessage = (e) => {
        clearTimeout(timeout);
        ws.close();
        resolve(String(e.data));
      };
      ws.onerror = (e) => {
        clearTimeout(timeout);
        reject(new Error(`WebSocket error: ${e}`));
      };
    });

    expect(received).toBe("hello ws");
  });

  test("echoes a frame split across TCP writes", async () => {
    const payload = "x".repeat(4096);
    const received = await rawWsEcho(async (socket) => {
      const frame = maskedFrame(0x1, payload);
      socket.write(frame.slice(0, 2048));
      socket.flush();
      await Bun.sleep(20);
      socket.write(frame.slice(2048));
      socket.flush();
    });

    expect(received).toBe(payload);
  });

  test("echoes fragmented messages intact", async () => {
    const received = await rawWsEcho(async (socket) => {
      socket.write(maskedFrame(0x1, "frag", false));
      socket.flush();
      await Bun.sleep(1);
      socket.write(maskedFrame(0x0, "ment", false));
      socket.flush();
      await Bun.sleep(1);
      socket.write(maskedFrame(0x0, "ed", true));
      socket.flush();
    });

    expect(received).toBe("fragmented");
  });
});
