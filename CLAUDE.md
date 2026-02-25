# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build          # Build the keyway binary
zig build run      # Build and run the server (listens on 0.0.0.0:8080)
zig build test     # Run all unit tests (tests are embedded in source files)
```

Requires Zig 0.15.0+. Dependencies (libxev, zig-luajit) are fetched automatically via build.zig.zon.

## What Keyway Is

Keyway is a high-performance HTTP server where Zig owns the execution engine (memory, I/O, event loop) and Lua expresses routing policy through a declarative interface. Tech stack: Zig, LuaJIT, libxev (io_uring), picohttpparser, eBPF.

The architecture is defined in MANIFEST.md — it is a non-negotiable design contract that all code must follow.

## Architecture

### Execution Model: Proactor

Lua **never** performs I/O. Lua describes intent (setting fields on `ctx`), Zig submits all I/O via io_uring through libxev. This is the foundational rule.

### Per-Core Isolation

Each CPU core runs one worker thread with its own:
- libxev event loop (`Loop`)
- LuaJIT state (`LuaState`)
- Radix router (`RadixRouter`)
- Server socket (via `SO_REUSEPORT`)

No Lua state is shared. No cross-thread access. Workers are pinned to CPU cores for cache locality. eBPF provides optional connection affinity so the same client always hits the same worker.

### Request Lifecycle

1. **Accept** — `Server.onAccept` creates a `Connection` with arena allocator
2. **Read** — libxev async recv into `RingBuffer`, callback `Connection.onRead`
3. **Parse** — `http.Parser` (picohttpparser FFI) produces zero-copy `Request` slices into the RingBuffer
4. **Route** — `RadixRouter.match` does O(path-length) lookup, populates `ParamArray` (inline, zero-alloc)
5. **Execute** — `LuaState.callLuaHandler` creates a Lua coroutine (`lua_newthread` + `lua_resume`), passes `HttpExchange` userdata to handler
6. **Respond** — `HttpExchange.toResponse` → `Response.serialize` → libxev async send
7. **Reuse** — Arena reset + buffer reset for HTTP/1.1 keep-alive on same connection

### Key Module Roles

| Module | Role |
|---|---|
| `main.zig` | Entry point, creates `ThreadPool` |
| `worker.zig` | Per-core thread with pinning, owns Loop + LuaState + Router + Server |
| `server.zig` | TCP listener, accept loop, SO_REUSEPORT, BPF attachment |
| `handler.zig` | `Connection` struct — owns socket lifecycle, read/write completions, arena, buffers |
| `lua_state.zig` | LuaJIT state management, handler dispatch, reusable userdata caching |
| `lua_api.zig` | Lua metatables for `ctx` (HttpExchange), headers proxy, params table, `keyway.add_route` |
| `http_exchange.zig` | `HttpExchange` — the single Lua-visible object binding request/response |
| `http.zig` | HTTP types (`Request`, `Response`, `Header`), picohttpparser C bindings, response serialization |
| `radix_router.zig` | Radix tree router with `{param}` support, zero-alloc matching |
| `buffer.zig` | `RingBuffer` for streaming I/O |
| `loop.zig` | Thin wrapper over `xev.Loop` |
| `bpf_reuseport.zig` | Classic BPF program generation for SO_REUSEPORT worker affinity |

### The Lua Contract

Lua interacts only with `ctx` (HttpExchange userdata) through metatables:
- **Read**: `ctx.method`, `ctx.path`, `ctx.body`, `ctx.params.id`, `ctx.headers["Key"]`
- **Write**: `ctx.status = 200`, `ctx.body = "..."`, `ctx.headers["Key"] = "value"`

No verbs (`send()`, `write()`). Only state assignment. Routes are registered via `keyway.add_route(method, pattern, handler_fn)`.

### Memory Model

- Request data lives in `RingBuffer` — headers/path/body are slices, never copied
- Per-request allocations use `Connection.arena` (reset after each response)
- `HttpExchange` userdata and `HeadersProxy` are cached in LuaState (reused across requests)
- `ParamArray` is inline on Connection (max 4 params, zero heap allocation)
- `rdynamic = true` in build.zig exports symbols for LuaRocks C module loading

### Lua Handler Scripts

Handlers live in `scripts/handlers.lua`, loaded by each worker independently. The file configures LuaJIT optimizations and registers routes.

## Design Rules (from MANIFEST.md)

- Lua never performs syscalls or manages lifetimes
- Lua expresses intent through state assignment, not method calls
- Zero-copy is the default; copying is a failure mode
- libxev callbacks do not contain logic — they dispatch
- Each layer has one job and does not compensate for another
- One core, one thread, one Lua state — no sharing, no locking

## Cosocket Implementation Status

**Phase 1 (complete):** Coroutine infrastructure. Handler dispatch uses `lua_newthread` + `lua_resume` instead of `callProtected`. Non-yielding handlers work identically. `ConnectionState` enum added to `handler.zig` for future suspend/resume. See `COSOCKET_FINDINGS.md` for technical notes.

**Phase 2 (next):** Cosocket API — `keyway.tcp_connect`, yield/resume on I/O, `ConnectionState.suspended`.

**Key constraint:** zig-luajit marks `resumeCoroutine`/`yieldCoroutine` as private. We declare `extern "c" fn lua_resume` and `@ptrCast` the `*Lua` to call it directly.
