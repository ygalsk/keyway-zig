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
    // (#243) Binary echo must come back as opcode 0x2 with the bytes intact,
    // so this returns the raw payload rather than a UTF-8 decode.
    readBinary: () => waitFor(() => readFrameBytes(bytes, 0x2)),
    // (#224) Reads a pong frame (opcode 0xA) by payload.
    readPong: () => waitFor(() => readFrame(bytes, 0xa)),
    readClose: () => waitFor(() => (closed || readFrame(bytes, 0x8) !== null ? true : null)),
    // (#175) Parses the close frame's 2-byte big-endian status code instead
    // of just detecting that a close happened.
    readCloseCode: () => waitFor(() => readCloseCode(bytes)),
  };
}

function readFrameBytes(bytes: number[], opcode: number): Uint8Array | null {
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
  return payload;
}

function readFrame(bytes: number[], opcode: number): string | null {
  const payload = readFrameBytes(bytes, opcode);
  return payload === null ? null : decoder.decode(payload);
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


describe("websocket large messages", () => {
  // (#244) A message's acceptability must not depend on how the sender chose
  // to chop it. Before this, 100 KB in one frame was 1009 while the identical
  // 100 KB in two 50 KB fragments echoed fine.
  test("echoes the same 100 KB message whether sent as one frame or two", async () => {
    await withServer(async ({ port }) => {
      const payload = "x".repeat(100_000);

      const one = await openRawWs(port);
      one.socket.write(clientFrame(0x1, payload));
      one.socket.flush();
      expect(await one.readText()).toBe(payload);
      one.socket.end();

      const two = await openRawWs(port);
      two.socket.write(clientFrame(0x1, payload.slice(0, 50_000), false));
      two.socket.write(frameBytes(0x0, encoder.encode(payload.slice(50_000))));
      two.socket.flush();
      expect(await two.readText()).toBe(payload);
      two.socket.end();
    });
  });

  // (#244) Autobahn 1.1.6/1.1.7 — 65535 bytes is just over the old
  // MAX_SINGLE_FRAME_PAYLOAD of 65522, which is why those cases failed.
  test("echoes a single frame of exactly 1 MiB", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      const payload = "z".repeat(1_048_576);
      ws.socket.write(clientFrame(0x2, payload));
      ws.socket.flush();
      expect((await ws.readBinary()).length).toBe(1_048_576);
      ws.socket.end();
    });
  });

  // (#244) Autobahn 1.1.8 — the same large frame dribbled in across many
  // recvs. This is the case that needs the resumable payload drain, including
  // carrying the mask offset across chunk boundaries that aren't multiples of 4.
  test("echoes a large frame arriving in many small TCP chunks", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      const payload = "q".repeat(200_000);
      const frame = clientFrame(0x1, payload);
      // 4093 is coprime with 4, so chunk boundaries land on every mask phase.
      for (let i = 0; i < frame.length; i += 4093) {
        ws.socket.write(frame.slice(i, i + 4093));
        ws.socket.flush();
      }
      expect(await ws.readText()).toBe(payload);
      ws.socket.end();
    });
  });

  // (#244) Large and small frames mix freely within one message, in either
  // order — the drain path and the buffered path both feed fragment_buf, so
  // both orderings have to reassemble identically.
  test("reassembles a message mixing a large fragment with a small one", async () => {
    await withServer(async ({ port }) => {
      const big = "b".repeat(120_000);
      const small = "s".repeat(10);

      const largeFirst = await openRawWs(port);
      largeFirst.socket.write(clientFrame(0x1, big, false));
      largeFirst.socket.write(frameBytes(0x0, encoder.encode(small)));
      largeFirst.socket.flush();
      expect(await largeFirst.readText()).toBe(big + small);
      largeFirst.socket.end();

      const smallFirst = await openRawWs(port);
      smallFirst.socket.write(clientFrame(0x1, small, false));
      smallFirst.socket.write(frameBytes(0x0, encoder.encode(big)));
      smallFirst.socket.flush();
      expect(await smallFirst.readText()).toBe(small + big);
      smallFirst.socket.end();
    });
  });

  // (#244) The message ceiling still applies when the total is only reached
  // by accumulating across frames, not by any single frame's length.
  test("closes 1009 when large fragments together exceed the message limit", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      const chunk = "c".repeat(600_000);
      ws.socket.write(clientFrame(0x1, chunk, false));
      ws.socket.write(frameBytes(0x0, encoder.encode(chunk)));
      ws.socket.flush();
      expect(await ws.readCloseCode()).toBe(1009);
      ws.socket.end();
    });
  });

  // (#244) A control frame must still be handled promptly while a large data
  // frame is mid-drain (RFC 6455 §5.5 — control frames may be interleaved).
  test("keeps the connection healthy across a large frame followed by a ping", async () => {
    await withServer(async ({ port }) => {
      const ws = await openRawWs(port);
      const payload = "w".repeat(150_000);
      ws.socket.write(clientFrame(0x1, payload));
      ws.socket.flush();
      expect(await ws.readText()).toBe(payload);
      ws.socket.write(frameBytes(0x9, encoder.encode("hb")));
      ws.socket.flush();
      expect(await ws.readPong()).toBe("hb");
      ws.socket.end();
    });
  });
});

describe("websocket adversarial framing", () => {
  // (#165)
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
      expect(await ws.readCloseCode()).toBe(1009);
      ws.socket.end();
    });
  });

  // (#228) The largest single-frame payload that fits the read buffer in one
  // recv: 65536 (READ_BUFFER_SIZE) - 10 (max frame header) - 4 (mask key).
  // Still the zero-copy fast path after #244 — it must not regress.
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
