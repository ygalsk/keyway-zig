// GET /__keyway/api/log — the engine log ring (#230). Surfaces Lua
// tracebacks and other warn/error engine events for the dashboard console,
// served directly from Zig (no Lua round-trip), same class of endpoint as
// /health and /metrics.

import { describe, test, expect } from "bun:test";

const base = () => globalThis.__KEYWAY_BASE;
const port = () => globalThis.__KEYWAY_PORT;

interface LogEntry {
  seq: number;
  ts: number;
  level: string;
  worker: number;
  msg: string;
}
interface LogResponse {
  entries: LogEntry[];
  latest: number;
}

async function getLog(since?: number): Promise<LogResponse> {
  const url = since === undefined ? `${base()}/__keyway/api/log` : `${base()}/__keyway/api/log?since=${since}`;
  const res = await fetch(url);
  return (await res.json()) as LogResponse;
}

// /test/ws-error's on_message handler indexes a nil value. WS message
// dispatch (conn_ws.zig -> LuaState.dispatchCoroutine) is NOT wrapped by the
// dashboard's global middleware pcall (see fixtures.lua comment), so this is
// the one fixture that actually exercises the coroutine-error traceback
// path in src/lua/lua_state.zig — the ring's highest-value payload.
//
// Deliberately triggered only once across this whole file: LuaState caches
// and reuses one coroutine thread per worker across dispatches, and it's
// only known to be safely reusable after a *yielded* or *completed*
// dispatch — a second on_message error against the same cached thread hits
// a separate, pre-existing bug ("cannot resume non-suspended coroutine")
// that's out of scope for #230.
function triggerWsError(): Promise<void> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port()}/test/ws-error`);
    const timeout = setTimeout(() => {
      ws.close();
      reject(new Error("ws-error trigger timed out"));
    }, 5000);
    ws.onopen = () => ws.send("boom");
    ws.onerror = () => {
      // A socket-level error/reset is fine here — the server-side handler
      // error is what we're after, not a clean client round-trip.
    };
    // The handler doesn't reply (it errors before ever calling ws:send), so
    // there's nothing to await but time for the server to log it.
    setTimeout(() => {
      clearTimeout(timeout);
      ws.close();
      resolve();
    }, 300);
  });
}

describe("log ring", () => {
  test("GET /__keyway/api/log returns the {entries, latest} shape", async () => {
    const res = await fetch(`${base()}/__keyway/api/log`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    const body = (await res.json()) as LogResponse;
    expect(Array.isArray(body.entries)).toBe(true);
    expect(typeof body.latest).toBe("number");
  });

  test("since cursor advances, surfaces a Lua traceback, and is empty once caught up", async () => {
    const first = await getLog();
    const cursor = first.latest;

    await triggerWsError();

    const second = await getLog(cursor);
    expect(second.latest).toBeGreaterThan(cursor);
    for (const e of second.entries) {
      expect(e.seq).toBeGreaterThan(cursor);
    }

    const tracebackEntry = second.entries.find(
      (e) => e.level === "err" && e.msg.includes("traceback"),
    );
    expect(tracebackEntry).toBeDefined();
    // The actual Lua error text from indexing `this_is_nil` in the fixture
    // (LuaJIT phrasing: "attempt to index local 'this_is_nil' (a nil value)").
    expect(tracebackEntry!.msg).toMatch(/attempt to index .*\(a nil value\)/);

    // Caught up: re-querying with the new latest returns no entries, but
    // still reports latest so the client can hold its cursor.
    const caughtUp = await getLog(second.latest);
    expect(caughtUp.entries.length).toBe(0);
    expect(caughtUp.latest).toBe(second.latest);
  });
});
