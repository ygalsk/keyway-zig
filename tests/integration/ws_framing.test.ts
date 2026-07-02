import { describe, expect, test } from "bun:test";
import { resolve } from "path";

const PROJECT_ROOT = resolve(import.meta.dir, "../..");
const BINARY = resolve(PROJECT_ROOT, "zig-out/bin/keyway");
const SCRIPT = resolve(PROJECT_ROOT, "tests/fixtures.lua");
const encoder = new TextEncoder();
const decoder = new TextDecoder();

async function withServer(fn: (port: number) => Promise<void>) {
  const port = 10000 + Math.floor(Math.random() * 50000);
  const proc = Bun.spawn(
    [BINARY, "--script", SCRIPT, "--workers", "1", "--port", String(port)],
    { cwd: PROJECT_ROOT, stdout: "ignore", stderr: "pipe" },
  );
  const stderr = new Response(proc.stderr).text();

  try {
    const base = `http://127.0.0.1:${port}`;
    for (let i = 0; i < 50; i++) {
      const res = await fetch(`${base}/health`).catch(() => null);
      if (res?.ok) return await fn(port);
      await Bun.sleep(100);
    }
    throw new Error(`isolated keyway did not start: ${await stderr}`);
  } finally {
    proc.kill("SIGKILL");
    await Promise.race([proc.exited.catch(() => {}), Bun.sleep(500)]);
  }
}

async function openRawWs(port: number) {
  let bytes: number[] = [];
  let closed = false;
  let err: Error | null = null;
  let wake: (() => void) | null = null;
  const notify = () => {
    wake?.();
    wake = null;
  };

  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port,
    socket: {
      data(_socket, data) {
        bytes.push(...data);
        notify();
      },
      close() {
        closed = true;
        notify();
      },
      error(_socket, error) {
        err = error;
        notify();
      },
    },
  });

  async function waitFor<T>(read: () => T | null, timeout = 1500): Promise<T> {
    const deadline = Date.now() + timeout;
    while (true) {
      const value = read();
      if (value !== null) return value;
      if (err) throw err;
      const left = deadline - Date.now();
      if (left <= 0) throw new Error("timed out waiting for raw websocket data");
      const { promise, resolve } = Promise.withResolvers<void>();
      wake = resolve;
      await Promise.race([promise, Bun.sleep(left)]);
    }
  }

  socket.write(
    `GET /test/ws HTTP/1.1\r\n` +
      `Host: 127.0.0.1:${port}\r\n` +
      `Upgrade: websocket\r\n` +
      `Connection: Upgrade\r\n` +
      `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n` +
      `Sec-WebSocket-Version: 13\r\n\r\n`,
  );
  socket.flush();

  const headers = await waitFor(() => {
    const text = String.fromCharCode(...bytes);
    const end = text.indexOf("\r\n\r\n");
    if (end === -1) return null;
    const head = text.slice(0, end + 4);
    bytes = bytes.slice(end + 4);
    return head;
  });
  expect(headers.startsWith("HTTP/1.1 101")).toBe(true);

  return {
    socket,
    readText: () => waitFor(() => readFrame(bytes, 0x1)),
    readClose: () => waitFor(() => (closed || readFrame(bytes, 0x8) !== null ? true : null)),
  };
}

function readFrame(bytes: number[], opcode: number): string | null {
  if (bytes.length < 2) return null;
  let len = bytes[1] & 0x7f;
  let pos = 2;
  if (len === 126) {
    if (bytes.length < 4) return null;
    len = (bytes[2] << 8) | bytes[3];
    pos = 4;
  } else if (len === 127) {
    if (bytes.length < 10) return null;
    len = Number((BigInt(bytes[2]) << 56n) | (BigInt(bytes[3]) << 48n) | (BigInt(bytes[4]) << 40n) | (BigInt(bytes[5]) << 32n) | (BigInt(bytes[6]) << 24n) | (BigInt(bytes[7]) << 16n) | (BigInt(bytes[8]) << 8n) | BigInt(bytes[9]));
    pos = 10;
  }
  if (bytes.length < pos + len) return null;
  if ((bytes[0] & 0x0f) !== opcode) return null;
  const payload = Uint8Array.from(bytes.slice(pos, pos + len));
  bytes.splice(0, pos + len);
  return decoder.decode(payload);
}

function clientFrame(opcode: number, data: string, fin = true): Uint8Array {
  const payload = encoder.encode(data);
  const header = payload.length < 126 ? 2 : payload.length <= 65535 ? 4 : 10;
  const out = new Uint8Array(header + 4 + payload.length);
  out[0] = (fin ? 0x80 : 0) | opcode;
  if (payload.length < 126) {
    out[1] = 0x80 | payload.length;
  } else if (payload.length <= 65535) {
    out[1] = 0x80 | 126;
    out[2] = payload.length >> 8;
    out[3] = payload.length & 0xff;
  } else {
    out[1] = 0x80 | 127;
    new DataView(out.buffer).setBigUint64(2, BigInt(payload.length));
  }
  out.set([1, 2, 3, 4], header);
  for (let i = 0; i < payload.length; i++) out[header + 4 + i] = payload[i] ^ out[header + (i % 4)];
  return out;
}

describe("websocket adversarial framing", () => {
  // (#165)
  test.failing("echoes a frame whose header and payload arrive in separate writes", async () => {
    await withServer(async (port) => {
      const ws = await openRawWs(port);
      const frame = clientFrame(0x1, "x".repeat(4096));
      const payloadOffset = frame.length - 4096;
      ws.socket.write(frame.slice(0, payloadOffset));
      ws.socket.flush();
      await Bun.sleep(10);
      ws.socket.write(frame.slice(payloadOffset));
      ws.socket.flush();
      expect(await ws.readText()).toBe("x".repeat(4096));
      ws.socket.end();
    });
  });

  // (#166)
  test.failing("rejects a 127-length frame declaring more than 1MB", async () => {
    await withServer(async (port) => {
      const ws = await openRawWs(port);
      const frame = new Uint8Array(14);
      frame[0] = 0x81;
      frame[1] = 0xff;
      new DataView(frame.buffer).setBigUint64(2, 1_048_577n);
      frame.set([1, 2, 3, 4], 10);
      ws.socket.write(frame);
      ws.socket.flush();
      expect(await ws.readClose()).toBe(true);
      ws.socket.end();
    });
  });

  // (#167)
  test.failing("echoes a text message sent as three continuation frames", async () => {
    await withServer(async (port) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x1, "he", false));
      ws.socket.write(clientFrame(0x0, "llo", false));
      ws.socket.write(clientFrame(0x0, " ws", true));
      ws.socket.flush();
      expect(await ws.readText()).toBe("hello ws");
      ws.socket.end();
    });
  });
});
