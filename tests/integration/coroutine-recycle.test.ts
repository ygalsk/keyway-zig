// (#242) A single Lua error in a coroutine-dispatched handler must not wedge
// the worker: the dead coroutine has to be discarded and later dispatch must
// get a fresh one. Before the fix, the next dispatch resumed the dead thread
// ("cannot resume non-suspended coroutine") and every request 500'd forever.
//
// Each test is self-contained: trigger the error, then prove the same worker
// (--workers 1 in preload.ts) still serves a normal coroutine dispatch.

import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;
const port = () => globalThis.__KEYWAY_PORT;

/// Open a WS to `path`, send one text frame to trigger on_message, then close.
/// The close handshake is sent on the same connection AFTER the text frame, so
/// by the time the server answers the close, on_message has been dispatched —
/// no sleep needed. If `expectReply` is set, wait for that reply first.
function triggerWsError(path: string, expectReply?: string): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port()}${path}`);
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error(`WS error trigger on ${path} timed out`));
    }, 5000);

    let gotReply = expectReply === undefined;
    ws.onopen = () => {
      ws.send("trigger");
      if (expectReply === undefined) ws.close();
    };
    ws.onmessage = (e) => {
      if (expectReply !== undefined && String(e.data) === expectReply) {
        gotReply = true;
        ws.close();
      }
    };
    ws.onclose = () => {
      clearTimeout(timeout);
      if (gotReply) resolve();
      else reject(new Error(`WS closed before expected reply "${expectReply}"`));
    };
    ws.onerror = () => {
      // onclose fires afterwards and settles the promise
    };
  });
}

async function expectWorkerAlive() {
  const res = await fetch(`${base()}/test/json`);
  expect(res.status).toBe(200);
  const body = (await res.json()) as { message: string };
  expect(body.message).toBe("hello");
}

describe("coroutine recycle after handler error (#242)", () => {
  test("worker survives an erroring WS on_message", async () => {
    await expectWorkerAlive(); // sanity: healthy before

    await triggerWsError("/test/coro-error");

    // Before the fix: 500 "cannot resume non-suspended coroutine"
    await expectWorkerAlive();
  });

  test("worker survives a WS handler that yields then errors on resume", async () => {
    await triggerWsError("/test/coro-error-after-send", "before-error");

    // Before the fix: completeHandler cached the dead thread -> 500
    await expectWorkerAlive();
  });
});
