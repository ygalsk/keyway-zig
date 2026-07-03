import { describe, expect, test } from "bun:test";
import { rawResponse, rawStatus, withServer } from "../harness";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

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
    // (#224) Reads a pong frame (opcode 0xA) by payload.
    readPong: () => waitFor(() => readFrame(bytes, 0xa)),
    readClose: () => waitFor(() => (closed || readFrame(bytes, 0x8) !== null ? true : null)),
    // (#175) Parses the close frame's 2-byte big-endian status code instead
    // of just detecting that a close happened.
    readCloseCode: () => waitFor(() => readCloseCode(bytes)),
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
    len = Number(new DataView(Uint8Array.from(bytes.slice(2, 10)).buffer).getBigUint64(0));
    pos = 10;
  }
  if (bytes.length < pos + len) return null;
  if ((bytes[0] & 0x0f) !== opcode) return null;
  const payload = Uint8Array.from(bytes.slice(pos, pos + len));
  bytes.splice(0, pos + len);
  return decoder.decode(payload);
}

// (#175) Reads a close frame (opcode 0x8) and returns its status code, or 0
// if the close carried no payload. Returns null while more data is needed.
function readCloseCode(bytes: number[]): number | null {
  if (bytes.length < 2) return null;
  let len = bytes[1] & 0x7f;
  let pos = 2;
  if (len === 126) {
    if (bytes.length < 4) return null;
    len = (bytes[2] << 8) | bytes[3];
    pos = 4;
  } else if (len === 127) {
    if (bytes.length < 10) return null;
    len = Number(new DataView(Uint8Array.from(bytes.slice(2, 10)).buffer).getBigUint64(0));
    pos = 10;
  }
  if (bytes.length < pos + len) return null;
  if ((bytes[0] & 0x0f) !== 0x8) return null;
  const payload = bytes.slice(pos, pos + len);
  bytes.splice(0, pos + len);
  if (payload.length < 2) return 0;
  return (payload[0] << 8) | payload[1];
}

// (#175) General raw-frame builder taking an explicit byte payload (rather
// than a UTF-8 string) plus fin/mask/rsv knobs, needed to construct frames
// that are invalid by construction (unmasked, reserved bits, bad UTF-8).
function frameBytes(
  opcode: number,
  payload: Uint8Array,
  opts: { fin?: boolean; masked?: boolean; rsv?: number } = {},
): Uint8Array {
  const { fin = true, masked = true, rsv = 0 } = opts;
  const header = payload.length < 126 ? 2 : payload.length <= 65535 ? 4 : 10;
  const out = new Uint8Array(header + (masked ? 4 : 0) + payload.length);
  out[0] = (fin ? 0x80 : 0) | (rsv & 0x70) | opcode;
  const maskBit = masked ? 0x80 : 0;
  if (payload.length < 126) {
    out[1] = maskBit | payload.length;
  } else if (payload.length <= 65535) {
    out[1] = maskBit | 126;
    out[2] = payload.length >> 8;
    out[3] = payload.length & 0xff;
  } else {
    out[1] = maskBit | 127;
    new DataView(out.buffer).setBigUint64(2, BigInt(payload.length));
  }
  if (masked) {
    out.set([1, 2, 3, 4], header);
    for (let i = 0; i < payload.length; i++) out[header + 4 + i] = payload[i] ^ out[header + (i % 4)];
  } else {
    out.set(payload, header);
  }
  return out;
}

function clientFrame(opcode: number, data: string, fin = true): Uint8Array {
  return frameBytes(opcode, encoder.encode(data), { fin });
}

describe("websocket adversarial framing", () => {
  // (#165)
  test("echoes a frame whose header and payload arrive in separate writes", async () => {
    await withServer(async ({ port }) => {
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
  test("rejects a 127-length frame declaring more than 1MB", async () => {
    await withServer(async ({ port }) => {
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

  // (#228) A legal single (unfragmented) frame whose declared length is under
  // the 1MB message limit but over the 64KB read buffer used to be
  // unassemblable: parseFrame kept returning `.incomplete` until the buffer
  // filled, then armWsRecv gave up with a bare `close()` (client sees 1006).
  // It must instead get a clean 1009, same as the existing >1MB case above.
  test("closes with 1009 on a legal single frame too large for the read buffer", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x2, "x".repeat(100_000))); // binary, ~100KB
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1009);
      ws.socket.end();
    });
  });

  // (#228) The largest single-frame payload guaranteed to fit the read
  // buffer: 65536 (READ_BUFFER_SIZE) - 10 (max frame header) - 4 (mask key).
  test("echoes a single frame at the read-buffer capacity and keeps the worker alive", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      const payload = "x".repeat(65522);
      ws.socket.write(clientFrame(0x1, payload));
      ws.socket.flush();
      expect(await ws.readText()).toBe(payload);
      ws.socket.end();
      expect(await rawStatus(port, `GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`)).toBe(200);
    });
  });

  // (#167)
  test("echoes a text message sent as three continuation frames", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x1, "he", false));
      ws.socket.write(clientFrame(0x0, "llo", false));
      ws.socket.write(clientFrame(0x0, " ws", true));
      ws.socket.flush();
      expect(await ws.readText()).toBe("hello ws");
      ws.socket.end();
    });
  });

  // (#175) RFC 6455 §5.1: a server MUST close on an unmasked client frame.
  test("closes with 1002 on an unmasked client frame", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(frameBytes(0x1, encoder.encode("hi"), { masked: false }));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1002);
      ws.socket.end();
    });
  });

  // (#175) RFC 6455 §5.2: RSV1-3 are reserved; we negotiate no extensions.
  test("closes with 1002 when a client frame sets a reserved bit", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(frameBytes(0x1, encoder.encode("hi"), { rsv: 0x40 }));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1002);
      ws.socket.end();
    });
  });

  // (#175) RFC 6455 §8.1: a text frame's payload must be valid UTF-8.
  test("closes with 1007 on a text frame with invalid UTF-8", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(frameBytes(0x1, new Uint8Array([0xff, 0xfe, 0xfd])));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1007);
      ws.socket.end();
    });
  });

  // (#175) UTF-8 validity is checked on the reassembled message, since a
  // multi-byte codepoint can legitimately split across fragment boundaries —
  // this fragmentation makes the reassembled result invalid regardless.
  test("closes with 1007 on a fragmented message with invalid reassembled UTF-8", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(frameBytes(0x1, new Uint8Array([0x68, 0x65]), { fin: false })); // "he"
      ws.socket.write(frameBytes(0x0, new Uint8Array([0xff]), { fin: true })); // invalid byte
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1007);
      ws.socket.end();
    });
  });

  // (#175) RFC 6455 §5.5: control frames MUST NOT be fragmented.
  test("closes with 1002 on a fragmented control frame", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x9, "hi", false)); // ping, FIN=0
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1002);
      ws.socket.end();
    });
  });

  // (#175) RFC 6455 §5.5: control-frame payloads MUST be 125 bytes or fewer.
  test("closes with 1002 on an oversized ping payload", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x9, "x".repeat(126)));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1002);
      ws.socket.end();
    });
  });

  // (#175) RFC 6455 §7.4.1: a close code, if present, must be 2 bytes.
  test("closes with 1002 on a close frame with a 1-byte payload", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x8, "A"));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1002);
      ws.socket.end();
    });
  });

  // (#175) RFC 6455 §7.4.1: 1005 is reserved and MUST NOT appear on the wire.
  test("closes with 1002 on a reserved close code", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      const payload = new Uint8Array(2);
      new DataView(payload.buffer).setUint16(0, 1005);
      ws.socket.write(frameBytes(0x8, payload));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1002);
      ws.socket.end();
    });
  });

  // (#175) Autobahn 7.5.1: the close reason (bytes after the 2-byte code)
  // must be valid UTF-8.
  test("closes with 1007 on a close frame with a non-UTF8 reason", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      const payload = new Uint8Array([0x03, 0xe8, 0xff, 0xfe]); // code 1000 + invalid UTF-8 reason
      ws.socket.write(frameBytes(0x8, payload));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1007);
      ws.socket.end();
    });
  });
});

// (#224) Two control frames arriving in a single TCP segment used to be
// processed synchronously in one pass of the frame loop while the first
// frame's pong send was still in flight, clobbering the shared
// write_completion (double io_uring add on a live Completion) — a
// whole-worker corruption from unauthenticated input. Each write() below is
// unflushed until the final flush() so both frames land in the same recv().
describe("websocket queued control frames in one segment (#224)", () => {
  test("answers back-to-back pings with two pongs and keeps the worker alive", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x9, "a"));
      ws.socket.write(clientFrame(0x9, "b"));
      ws.socket.flush();
      expect(await ws.readPong()).toBe("a");
      expect(await ws.readPong()).toBe("b");
      ws.socket.end();
      // The worker must have survived the double send unscathed.
      expect(await rawStatus(port, `GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`)).toBe(200);
    });
  });

  test("answers a queued [ping][close] with a pong then a clean close, and keeps the worker alive", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      ws.socket.write(clientFrame(0x9, "a"));
      ws.socket.write(clientFrame(0x8, ""));
      ws.socket.flush();
      expect(await ws.readPong()).toBe("a");
      expect(await ws.readCloseCode()).toBe(1000);
      ws.socket.end();
      expect(await rawStatus(port, `GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`)).toBe(200);
    });
  });

  // A single [ping][ping] pair doesn't always corrupt anything an observer
  // can see — the kernel often already captured each pong's buffer when its
  // send was submitted. But processWsFrames's stray re-arm of the recv
  // completion each round leaves a dangling operation targeting the same
  // (stale) buffer offset as the next round's real recv, and repeating the
  // pair reliably wins that race within a handful of rounds: a later round's
  // ping payload lands in the wrong recv's buffer and comes back echoed
  // under the wrong round number below. Left running long enough, the
  // dangling completions also accumulate forever (never cleaned up until
  // close) and overflow pending_io_ops (a u8 counter), panicking — and on
  // this single-worker build, killing — the whole process ("panic: integer
  // overflow" at handler.zig's submitSend, reached from sendWsFrame <-
  // processWsFrames's `.ping` arm). 150 rounds is overkill for the fast
  // corruption but cheap insurance against the slower overflow too.
  test("many back-to-back ping pairs on one connection don't wedge or crash the worker", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      for (let round = 0; round < 150; round++) {
        ws.socket.write(clientFrame(0x9, `${round}`));
        ws.socket.write(clientFrame(0x9, `${round}`));
        ws.socket.flush();
        expect(await ws.readPong()).toBe(`${round}`);
        expect(await ws.readPong()).toBe(`${round}`);
      }
      ws.socket.end();
      expect(await rawStatus(port, `GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`)).toBe(200);
    });
  });
});

describe("websocket handshake validation (#175)", () => {
  test("responds 426 with Sec-WebSocket-Version when the version is missing", async () => {
    await withServer(async ({ port }) => {
      const resp = await rawResponse(
        port,
        `GET /test/ws HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${port}\r\n` +
          `Upgrade: websocket\r\n` +
          `Connection: Upgrade\r\n` +
          `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`,
      );
      expect(resp.startsWith("HTTP/1.1 426")).toBe(true);
      expect(resp.toLowerCase()).toContain("sec-websocket-version: 13");
    });
  });

  test("responds 426 on an unsupported Sec-WebSocket-Version", async () => {
    await withServer(async ({ port }) => {
      const status = await rawStatus(
        port,
        `GET /test/ws HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${port}\r\n` +
          `Upgrade: websocket\r\n` +
          `Connection: Upgrade\r\n` +
          `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n` +
          `Sec-WebSocket-Version: 8\r\n\r\n`,
      );
      expect(status).toBe(426);
    });
  });

  // The router only registers GET for /test/ws (tests/fixtures.lua), so a
  // POST hits the router's 405 Method Not Allowed path (#176) before
  // conn_ws.handleWsUpgrade's own method check ever runs — this still
  // proves a non-GET request is never upgraded.
  test("does not upgrade a non-GET request", async () => {
    await withServer(async ({ port }) => {
      const status = await rawStatus(
        port,
        `POST /test/ws HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${port}\r\n` +
          `Upgrade: websocket\r\n` +
          `Connection: Upgrade\r\n` +
          `Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n` +
          `Sec-WebSocket-Version: 13\r\n\r\n`,
      );
      expect(status).toBe(405);
    });
  });
});

// (#225) A WebSocket connection captures its route pattern once at handshake
// and never refreshes it (only method/path are updated per message). A
// hot-reload frees and rebuilds the whole route trie, so a message on a live
// WS connection after a reload used to read the freed pattern string. Cycles
// reload+message repeatedly to widen the race and confirms the connection
// keeps echoing correctly and the worker stays alive throughout.
describe("websocket survives hot-reload of its own route (#225)", () => {
  test("echoes correctly and stays healthy across repeated reloads", async () => {
    await withServer(async ({ base, port }) => {
      const ws = await openRawWs(port);
      for (let round = 0; round < 20; round++) {
        const res = await fetch(`${base}/__keyway/reload`, { method: "POST" });
        expect(res.ok).toBe(true);
        // Give the worker's event loop a turn to process the reload signal
        // and free the old trie before the next WS message lands.
        await Bun.sleep(20);
        ws.socket.write(clientFrame(0x1, `round-${round}`));
        ws.socket.flush();
        expect(await ws.readText()).toBe(`round-${round}`);
      }
      ws.socket.end();
      expect(await rawStatus(port, `GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`)).toBe(200);
    });
  });
});
