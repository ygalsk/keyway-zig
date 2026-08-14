// (#248) A stalled stderr consumer must not freeze the data plane.
//
// logz writes synchronously to fd 2 from the calling thread, holding a
// process-global mutex across the write (logfmt.zig:453, Pool is a singleton).
// So when whatever reads keyway's stderr stops reading, the pipe fills, the
// first worker blocks in write(2) *while holding the lock*, and every other
// worker freezes on its next log call. Measured with --workers 4: stall at
// request 639, then 0/12 fresh connections served, recovering 1.4ms after the
// pipe was drained.
//
// A log line is an observation about a request, not part of it, so the engine
// must drop lines rather than make the data plane wait on whoever reads them.
//
// Why a FIFO and not `stderr: "pipe"`: Bun drains child pipes internally even
// if the test never touches proc.stderr, so a "pipe" here can never fill and
// the test would be permanently green. Handing Bun.spawn a raw fd it did not
// create leaves the buffer entirely under this test's control. (That internal
// draining is also the mechanism behind #246 — spawnSync blocked the event
// loop and *stopped* it, which is why the pipe filled there.)

import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { closeSync, constants, mkdtempSync, openSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "path";

const PROJECT_ROOT = resolve(import.meta.dir, "../..");
const BINARY = resolve(PROJECT_ROOT, "zig-out/bin/keyway");
const SCRIPT = resolve(PROJECT_ROOT, "tests/fixtures.lua");

// A FIFO holds 64 KiB and one access-log line is ~100 B, so the buffer fills
// around request 640. 1500 is comfortably past it.
const REQUESTS = 1500;

let cleanup: (() => void) | null = null;
afterEach(() => {
  cleanup?.();
  cleanup = null;
});

describe("log backpressure (#248)", () => {
  test("keeps serving when nothing drains stderr", async () => {
    const dir = mkdtempSync(join(tmpdir(), "keyway-248-"));
    const fifo = join(dir, "stderr");
    execFileSync("mkfifo", [fifo]);

    // Read end opened non-blocking so it does not wait for a writer, then
    // deliberately never read — this is the stalled log consumer. Opening the
    // write end only succeeds because a reader already exists.
    const rfd = openSync(fifo, constants.O_RDONLY | constants.O_NONBLOCK);
    const wfd = openSync(fifo, constants.O_WRONLY);

    const port = 10000 + Math.floor(Math.random() * 50000);
    const proc = Bun.spawn(
      [BINARY, "--script", SCRIPT, "--workers", "1", "--port", String(port)],
      { cwd: PROJECT_ROOT, stdout: "ignore", stderr: wfd },
    );
    cleanup = () => {
      proc.kill("SIGKILL");
      for (const fd of [rfd, wfd]) {
        try {
          closeSync(fd);
        } catch {}
      }
      rmSync(dir, { recursive: true, force: true });
    };

    const base = `http://127.0.0.1:${port}`;
    let up = false;
    for (let i = 0; i < 50; i++) {
      if ((await fetch(`${base}/health`).catch(() => null))?.ok) {
        up = true;
        break;
      }
      await Bun.sleep(100);
    }
    expect(up).toBe(true);

    let served = 0;
    try {
      for (let i = 0; i < REQUESTS; i++) {
        const res = await fetch(`${base}/test/json`, {
          signal: AbortSignal.timeout(2000),
        });
        if (res.status !== 200) throw new Error(`status ${res.status}`);
        await res.text();
        served++;
      }
    } catch (e) {
      throw new Error(
        `stalled after ${served}/${REQUESTS} requests with stderr undrained: ${e}`,
      );
    }
    expect(served).toBe(REQUESTS);
  }, 60000);
});
