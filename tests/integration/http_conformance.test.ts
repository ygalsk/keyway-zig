// HTTP conformance regressions (#176): method-not-allowed semantics, HEAD on
// static files, conditional GET via If-Modified-Since, response header
// injection, and the static-mount sibling-prefix traversal boundary.
//
// Black-box only — these drive the running server over real HTTP/raw
// sockets and assert the RFC-correct outcome. No Zig symbols referenced.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "path";
import { rawStatus } from "../harness";

const base = () => globalThis.__KEYWAY_BASE;
const port = () => globalThis.__KEYWAY_PORT;
const PUBLIC = resolve(import.meta.dir, "../../dashboard/public");

describe("405 Method Not Allowed (#176)", () => {
  // /test/headers registers only GET (tests/fixtures.lua). Hitting it with an
  // unregistered method must be a 405 + Allow, not a bare 404 — the router
  // knows the path exists, it just doesn't have this method at that node.
  test("(#176) POST to a GET-only Lua route returns 405 with Allow: GET", async () => {
    const res = await fetch(`${base()}/test/headers`, { method: "POST" });
    expect(res.status).toBe(405);
    expect(res.headers.get("Allow")).toContain("GET");
  });
});

// fetch()/undici discard the body of a HEAD response regardless of what the
// server actually sent, so verifying "no body on the wire" needs the literal
// bytes from a raw socket. The response can arrive across multiple send()
// calls (e.g. static's headers-then-pread-loop), and not every response
// closes the connection afterward, so we can't rely on a socket close
// either. Instead debounce on a quiet period: resolve once no new bytes have
// arrived for a short window. Shared by (#176) static HEAD and (#202)
// HEAD-on-Lua-route/HEAD-on-canned-error.
async function rawHead(method: string, path: string): Promise<{ status: number; contentLength: number | null; bodyBytes: number }> {
  const request = `${method} ${path} HTTP/1.1\r\nHost: 127.0.0.1:${port()}\r\n\r\n`;
  const chunks: Buffer[] = [];
  const { promise, resolve: settle } = Promise.withResolvers<void>();
  let quietTimer: ReturnType<typeof setTimeout>;
  const armQuiet = () => {
    clearTimeout(quietTimer);
    quietTimer = setTimeout(settle, 250);
  };
  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port: port(),
    socket: {
      data(_s, data) {
        chunks.push(Buffer.from(data));
        armQuiet();
      },
      close() {
        clearTimeout(quietTimer);
        settle();
      },
      error() {
        clearTimeout(quietTimer);
        settle();
      },
    },
  });
  socket.write(request);
  socket.flush();
  armQuiet();
  await Promise.race([promise, Bun.sleep(3000).then(() => {})]);
  socket.end();

  const buf = Buffer.concat(chunks);
  const sep = buf.indexOf("\r\n\r\n");
  const headerText = (sep === -1 ? buf : buf.subarray(0, sep)).toString("latin1");
  const bodyBytes = sep === -1 ? 0 : buf.length - (sep + 4);
  const status = Number(headerText.split("\r\n")[0]?.split(" ")[1]);
  const clMatch = headerText.match(/content-length:\s*(\d+)/i);
  return { status, contentLength: clMatch ? Number(clMatch[1]) : null, bodyBytes };
}

describe("HEAD on static files (#176)", () => {
  test("(#176) HEAD on a static file returns Content-Length but no body", async () => {
    const want = await Bun.file(resolve(PUBLIC, "index.html")).arrayBuffer();
    const { status, contentLength, bodyBytes } = await rawHead("HEAD", "/__keyway/dashboard/index.html");
    expect(status).toBe(200);
    expect(contentLength).toBe(want.byteLength);
    expect(bodyBytes).toBe(0);
  });
});

describe("HEAD support everywhere else (#202)", () => {
  // #176 fixed HEAD for static files only; Lua routes and canned/built-in
  // responses still 405'd or leaked a body. RFC 9110 §9.1 requires HEAD
  // wherever GET is supported, and §9.3.2/§8.6 says a HEAD response carries
  // the Content-Length GET would have produced but no body.

  test("(#202) HEAD on a GET-only Lua route returns 200 with GET's Content-Length and no body", async () => {
    const want = await fetch(`${base()}/test/hello`).then((r) => r.arrayBuffer());
    const { status, contentLength, bodyBytes } = await rawHead("HEAD", "/test/hello");
    expect(status).toBe(200);
    expect(contentLength).toBe(want.byteLength);
    expect(bodyBytes).toBe(0);
  });

  test("(#202) HEAD on a canned error (404) returns zero body bytes", async () => {
    const { status, bodyBytes } = await rawHead("HEAD", "/test/does-not-exist-202");
    expect(status).toBe(404);
    expect(bodyBytes).toBe(0);
  });

  // A compliant client that sent HEAD does not expect a body and stops
  // reading after the header block. If the server actually put body bytes
  // on the wire, those bytes sit unread until the client's *next* response
  // read (for a subsequent request on the same keep-alive connection),
  // corrupting that parse. /health is a success response, so it stays
  // keep-alive (#180 only closes after errors) — this reproduces the
  // desync directly: read only through HEAD's header block (mimicking a
  // compliant client), fire the next request immediately, then verify
  // everything that follows on the wire is GET's response and nothing else.
  test("(#202) HEAD /health then GET /health on one socket: HEAD leaves no stray body bytes", async () => {
    let wire = Buffer.alloc(0);
    let headerEnd = -1;
    let sentSecond = false;
    const { promise: donePromise, resolve: settleDone } = Promise.withResolvers<void>();
    let quietTimer: ReturnType<typeof setTimeout>;
    const armQuiet = () => {
      clearTimeout(quietTimer);
      quietTimer = setTimeout(settleDone, 250);
    };
    const socket = await Bun.connect({
      hostname: "127.0.0.1",
      port: port(),
      socket: {
        data(s, data) {
          wire = Buffer.concat([wire, Buffer.from(data)]);
          if (!sentSecond) {
            const sep = wire.indexOf("\r\n\r\n");
            if (sep !== -1) {
              headerEnd = sep + 4;
              sentSecond = true;
              s.write(`GET /health HTTP/1.1\r\nHost: 127.0.0.1:${port()}\r\n\r\n`);
              s.flush();
            }
          }
          armQuiet();
        },
        close() {
          clearTimeout(quietTimer);
          settleDone();
        },
        error() {
          clearTimeout(quietTimer);
          settleDone();
        },
      },
    });
    socket.write(`HEAD /health HTTP/1.1\r\nHost: 127.0.0.1:${port()}\r\n\r\n`);
    socket.flush();
    armQuiet();
    await Promise.race([donePromise, Bun.sleep(3000).then(() => {})]);
    socket.end();

    expect(headerEnd).toBeGreaterThan(-1);
    const rest = wire.subarray(headerEnd).toString("latin1");
    // The bytes right after HEAD's header block must be GET's response —
    // nothing else. A stray leading body byte from HEAD fails this first.
    expect(rest.startsWith("HTTP/1.1 200")).toBe(true);
    const sep2 = rest.indexOf("\r\n\r\n");
    expect(sep2).toBeGreaterThan(-1);
    const clMatch = rest.slice(0, sep2).match(/content-length:\s*(\d+)/i);
    expect(clMatch).toBeTruthy();
    const contentLength = Number(clMatch![1]);
    const body = rest.slice(sep2 + 4);
    expect(body.length).toBe(contentLength);
    expect(JSON.parse(body)).toEqual({ status: "ok" });
  });
});

describe("If-Modified-Since (#176)", () => {
  test("(#176) If-Modified-Since with the file's own Last-Modified returns 304", async () => {
    const first = await fetch(`${base()}/__keyway/dashboard/index.html`);
    expect(first.status).toBe(200);
    await first.arrayBuffer();
    const lastModified = first.headers.get("last-modified");
    expect(lastModified).toBeTruthy();

    const second = await fetch(`${base()}/__keyway/dashboard/index.html`, {
      headers: { "If-Modified-Since": lastModified! },
    });
    expect(second.status).toBe(304);
    expect((await second.text()).length).toBe(0);
  });

  // Control: a date safely before the file's mtime must NOT short-circuit to
  // 304 — this already passes today (If-Modified-Since is simply ignored),
  // and must keep passing once the header is honored.
  test("(#176) If-Modified-Since with a date before the file's mtime returns 200 (control)", async () => {
    const res = await fetch(`${base()}/__keyway/dashboard/index.html`, {
      headers: { "If-Modified-Since": "Thu, 01 Jan 1970 00:00:00 GMT" },
    });
    expect(res.status).toBe(200);
  });
});

describe("response header CRLF injection (#176)", () => {
  // /test/header-injection (tests/fixtures.lua) sets a response header value
  // containing a literal CRLF + a fake header line. From the wire's
  // perspective "X-Bad: a\r\nX-Injected: evil\r\n" is indistinguishable from
  // two genuine header lines, so a plain fetch() is enough to observe the
  // split — no raw socket needed, since we're not fighting fetch's
  // request-side header validation here, only reading whatever the server
  // actually sent back.
  test("(#176) a CRLF-containing header value cannot smuggle a second response header", async () => {
    const res = await fetch(`${base()}/test/header-injection`);
    expect(res.status).toBe(200);
    expect(res.headers.get("X-Injected")).toBeNull();
  });
});

describe("static sibling-prefix traversal boundary (#176)", () => {
  // resolveStaticPath (src/http/static.zig) checks
  // std.mem.startsWith(resolved, root_resolved) with no trailing separator,
  // so a sibling directory whose name has the mount root as a *string*
  // prefix ("public-secret" vs "public") satisfies the check even though it
  // resolves outside the mount. Fixture created/removed around the test so
  // no stray directory is left in the repo.
  const SIBLING_DIR = resolve(PUBLIC, "../public-secret");
  const SIBLING_FILE = resolve(SIBLING_DIR, "secret.txt");

  beforeAll(async () => {
    await mkdir(SIBLING_DIR, { recursive: true });
    await writeFile(SIBLING_FILE, "top secret\n");
  });

  afterAll(async () => {
    await rm(SIBLING_DIR, { recursive: true, force: true });
  });

  // fetch()/the WHATWG URL parser collapse ".." before the request is sent
  // (see static.test.ts), so this needs a raw socket to get the literal
  // dot-segment onto the wire.
  test("(#176) a sibling dir sharing the mount root's name prefix is blocked (403)", async () => {
    const status = await rawStatus(
      port(),
      `GET /__keyway/dashboard/../public-secret/secret.txt HTTP/1.1\r\n` +
        `Host: 127.0.0.1:${port()}\r\n` +
        `Connection: close\r\n\r\n`,
    );
    expect(status).toBe(403);
  });
});

describe("Host header enforcement (#203)", () => {
  // RFC 9112 §3.2: a server MUST respond 400 to any HTTP/1.1 request that
  // does not have exactly one Host header. HTTP/1.0 has no such requirement.
  test("(#203) HTTP/1.1 request with no Host header is rejected with 400", async () => {
    const status = await rawStatus(
      port(),
      `GET /health HTTP/1.1\r\nConnection: close\r\n\r\n`,
    );
    expect(status).toBe(400);
  });

  test("(#203) HTTP/1.1 request with two differing Host headers is rejected with 400", async () => {
    const status = await rawStatus(
      port(),
      `GET /health HTTP/1.1\r\nHost: a.example\r\nHost: b.example\r\nConnection: close\r\n\r\n`,
    );
    expect(status).toBe(400);
  });

  // Control: HTTP/1.0 has no Host requirement — a Host-less 1.0 request must
  // still be served, not rejected.
  test("(#203) HTTP/1.0 request with no Host header is still served (control)", async () => {
    const status = await rawStatus(
      port(),
      `GET /health HTTP/1.0\r\nConnection: close\r\n\r\n`,
    );
    expect(status).toBe(200);
  });

  // Control: a well-formed HTTP/1.1 request with exactly one Host is
  // unaffected by the new check.
  test("(#203) HTTP/1.1 request with exactly one Host header is served (control)", async () => {
    const status = await rawStatus(
      port(),
      `GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`,
    );
    expect(status).toBe(200);
  });
});
