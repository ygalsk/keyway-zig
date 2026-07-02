// Static file serving — exercises the async pread+send path (issue #53).
//
// The dashboard route (dashboard/keyway.lua) serves dashboard/public at
// /__keyway/dashboard, so we read those assets back over HTTP and compare
// them byte-for-byte against disk. Files larger than STATIC_READ_SIZE (64 KB)
// span multiple async pread chunks — the case where a blocking/truncating
// read would corrupt the body.
//
// Also covers resolveStaticPath's traversal/symlink-escape 403 branches and
// the requested-vs-symlink-target content-type rule (issue #132), using two
// tiny checked-in symlink fixtures: dashboard/public/test-symlink-escape
// (points outside the mount root) and test-symlink-alias.css (points inside,
// at a .js file, to exercise the content-type rule).

import { describe, test, expect } from "bun:test";
import { resolve } from "path";

const base = () => globalThis.__KEYWAY_BASE;
const PUBLIC = resolve(import.meta.dir, "../../dashboard/public");

async function diskBytes(name: string): Promise<Uint8Array> {
  return new Uint8Array(await Bun.file(resolve(PUBLIC, name)).arrayBuffer());
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// fetch()/the WHATWG URL parser both collapse ".." (and its percent-encoded
// form) out of a path before the request is ever sent, so a well-behaved
// client can't reach resolveStaticPath's traversal checks through fetch().
// Open a raw socket and hand-write the request line to get the literal
// bytes onto the wire.
async function rawGetStatus(path: string): Promise<number> {
  const port = globalThis.__KEYWAY_PORT;
  let buf = "";
  const { promise, resolve } = Promise.withResolvers<string>();
  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port,
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
      error(_s, e) {
        resolve(buf || String(e));
      },
    },
  });
  socket.write(`GET ${path} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`);
  socket.flush();
  const resp = await promise;
  return Number(resp.split(" ")[1]);
}

describe("static file serving", () => {
  // Small file: served in a single pread chunk.
  test("serves a small file intact (single chunk)", async () => {
    const res = await fetch(`${base()}/__keyway/dashboard/index.html`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");

    const got = new Uint8Array(await res.arrayBuffer());
    const want = await diskBytes("index.html");
    expect(got.length).toBe(want.length);
    expect(bytesEqual(got, want)).toBe(true);
  });

  // Large file (~470 KB): spans ~8 async pread chunks. This is the regression
  // target for #53 — a blocking/truncating read would corrupt or short the body.
  test("serves a large file intact across multiple chunks", async () => {
    const res = await fetch(`${base()}/__keyway/dashboard/main.js`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/javascript");

    const got = new Uint8Array(await res.arrayBuffer());
    const want = await diskBytes("main.js");
    expect(got.length).toBe(want.length);
    expect(Number(res.headers.get("content-length"))).toBe(want.length);
    expect(bytesEqual(got, want)).toBe(true);
  });

  // Chunk-boundary case: ~90 KB file straddles the 64 KB chunk size.
  test("serves a file that straddles the chunk boundary", async () => {
    const res = await fetch(
      `${base()}/__keyway/dashboard/fonts/JetBrainsMono-Regular.woff2`,
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("font/woff2");

    const got = new Uint8Array(await res.arrayBuffer());
    const want = await diskBytes("fonts/JetBrainsMono-Regular.woff2");
    expect(got.length).toBe(want.length);
    expect(bytesEqual(got, want)).toBe(true);
  });

  // Missing file: 404, not a hang or 500.
  test("returns 404 for a missing file", async () => {
    const res = await fetch(`${base()}/__keyway/dashboard/does-not-exist.txt`);
    expect(res.status).toBe(404);
  });

  // ETag round-trip: a matching If-None-Match yields 304 with no body.
  test("returns 304 for a matching ETag", async () => {
    const first = await fetch(`${base()}/__keyway/dashboard/main.js`);
    expect(first.status).toBe(200);
    await first.arrayBuffer();
    const etag = first.headers.get("etag");
    expect(etag).toBeTruthy();

    const second = await fetch(`${base()}/__keyway/dashboard/main.js`, {
      headers: { "If-None-Match": etag! },
    });
    expect(second.status).toBe(304);
    expect((await second.text()).length).toBe(0);
  });

  // resolveStaticPath (src/http/static.zig) rejects a resolved path that
  // escapes route.root, returning 403 via error_response.sendErrorStatus
  // (the 403 arm was added in #161). fetch() collapses ".." client-side, so
  // this uses the raw-socket helper to get a literal ".." onto the wire.
  test("blocks a literal path traversal out of the mount root (403)", async () => {
    const status = await rawGetStatus("/__keyway/dashboard/../keyway.lua");
    expect(status).toBe(403);
  });

  // Percent-encoded dot segments are never decoded before static path
  // resolution, so "%2e%2e" is a literal (nonexistent) path segment rather
  // than "..": it 404s instead of hitting the traversal-block branch. Still
  // a real regression target — pins that the encoded form doesn't
  // accidentally succeed where the literal form is blocked.
  test("does not decode percent-encoded traversal segments", async () => {
    const status = await rawGetStatus("/__keyway/dashboard/%2e%2e/keyway.lua");
    expect(status).toBe(404);
  });

  // dashboard/public/test-symlink-escape -> ../../README.md, resolving
  // outside dashboard/public. No dot segments in the request path, so plain
  // fetch() is fine here (unlike the traversal cases above). Rejected with
  // 403 "symlink traversal blocked" (the 403 arm was added in #161).
  test("blocks a symlink that escapes the mount root (403)", async () => {
    const res = await fetch(`${base()}/__keyway/dashboard/test-symlink-escape`);
    expect(res.status).toBe(403);
  });

  // dashboard/public/test-symlink-alias.css -> main.js, both inside
  // dashboard/public — stays within root, so it serves 200. Content-type
  // must come from the requested extension (.css), not the symlink target's
  // (.js): behavior pinned in PR #126.
  test("derives content-type from the requested path, not the symlink target", async () => {
    const res = await fetch(`${base()}/__keyway/dashboard/test-symlink-alias.css`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/css; charset=utf-8");
  });
});
