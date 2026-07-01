// Static file serving — exercises the async pread+send path (issue #53).
//
// The dashboard route (dashboard/keyway.lua) serves dashboard/public at
// /__keyway/dashboard, so we read those assets back over HTTP and compare
// them byte-for-byte against disk. Files larger than STATIC_READ_SIZE (64 KB)
// span multiple async pread chunks — the case where a blocking/truncating
// read would corrupt the body.

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
});
