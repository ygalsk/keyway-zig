# CLAUDE.md

## Build Commands

```bash
zig build          # Build the keyway binary
zig build run      # Build and run the server (listens on 0.0.0.0:8080)
zig build test     # Run all unit tests (tests are embedded in source files)
```

Requires Zig 0.15.0+. Dependencies (libxev, zig-luajit) are fetched via `build.zig.zon`.

## What Keyway Is

Keyway is a programmable HTTP engine where Zig owns the execution engine (memory, I/O, event loop) and Lua expresses routing policy through a declarative interface. Tech stack: Zig, LuaJIT, libxev (io_uring), picohttpparser, eBPF.

## Architecture

Read **MANIFEST.md** — it is the authoritative design contract. Key rules:

- **Proactor model**: Lua never performs I/O. Lua sets fields on `ctx`, Zig submits all I/O via io_uring/libxev.
- **Per-core isolation**: One worker thread per CPU core. Each owns its own xev loop, LuaJIT state, router, and server socket (`SO_REUSEPORT`). No sharing, no locking.
- **Lua contract**: Lua interacts only with `ctx` (HttpExchange userdata) through metatables. State assignment, not method calls. Routes registered via `keyway.routes`.
- **Zero-copy default**: Headers/path/body are slices into `LinearBuffer`. Copying is a failure mode.

### Cosocket Key Constraint

zig-luajit marks `resumeCoroutine`/`yieldCoroutine` as private. We declare `extern "c" fn lua_resume` and `@ptrCast` the `*Lua` to call it directly.

## Principles

- **Simplicity, not timidity**: Default to the simplest change — but when something architecturally incoherent is spotted (bad abstraction, misplaced responsibility, structural bug), **stop, note it, and surface it to the user**. Don't silently fix it or silently ignore it. The user decides whether to re-plan now or finish current work and address it later.
- **Root causes, not patches**: Find the real problem. No temporary fixes.
- **Verify before done**: Run `zig build test`, check compilation, demonstrate the fix.

## Testing Philosophy

**Integration-first, DDD/TDD red-green cycle.** Don't think in small unit tests. Think in integration tests that prove the architecture works end-to-end.

The **dashboard is the integration test client** — a real consumer of the Zig server that exercises the architecture (HTTP, WebSocket, SSE, cosocket, routing). Bugs found through the dashboard are categorized, isolated, and fixed against the real server.

### Bug Triage by Layer

Each layer (JS, Lua, Zig) is well-understood in isolation. JS and Lua have rich ecosystems, stdlib, and tooling — if something breaks at those layers using standard, well-known patterns, **the bug is below them**. Use this to triage:

1. **JS layer issue** → likely surfaces a Lua-layer limitation or mismatch
2. **Lua layer issue** → likely surfaces a Zig-layer implementation bug or missing capability
3. Each layer is encapsulated — if it's coherent on its own level, the flaw comes from the layer below

This layered debugging model is how we pinpoint Zig implementation issues efficiently. Problems at higher layers are symptoms; the Zig engine is where root causes live.

### Test Stack

- **Zig side**: `zig build test` for internal correctness (embedded tests in source files)
- **Integration side**: `bun test` against a running keyway server
  - Native `fetch`, `WebSocket`, `EventSource` — no mock libraries
  - `Bun.spawn()` manages server lifecycle (start in `beforeAll`, kill in `afterAll`)
  - `--preload` for global server setup across suites
  - `CLAUDECODE=1 bun test --bail --timeout 10000` for agentic workflows (failures only)
- **Later**: Playwright for browser-based dashboard UI testing
