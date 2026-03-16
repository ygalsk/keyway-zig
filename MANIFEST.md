# MANIFEST.md — Keyway Architectural Contract

This document is the authoritative design contract for Keyway, a programmable HTTP engine. All code must conform to these rules. Deviations require explicit justification and approval.

## 1. Execution Model: Proactor

Lua **never** performs I/O. Lua **never** calls syscalls. Lua **never** manages lifetimes.

Lua describes intent by setting fields on `ctx` (the HttpExchange userdata). Zig reads that intent and submits all I/O via io_uring through libxev. This separation is the foundational rule of the system.

```
Lua: ctx.status = 200; ctx.body = "hello"   -- state assignment only
Zig: reads ctx fields → serializes response → submits async send via libxev
```

The proactor model means:
- All I/O is initiated by Zig, completed asynchronously by the kernel
- libxev callbacks dispatch to the next stage; they do not contain business logic
- Lua coroutines yield on cosocket operations; Zig resumes them when I/O completes

## 2. Per-Core Isolation

Each CPU core runs exactly one worker thread. Each worker owns:

| Resource | Type | Sharing |
|---|---|---|
| Event loop | `xev.Loop` | None |
| Lua state | `LuaState` | None |
| Router | `Router` | None (loaded independently) |
| Server socket | TCP listener | `SO_REUSEPORT` (kernel distributes) |
| SSE registry | `SseRegistry` | None (cross-worker via `SseBroadcastBus`) |
| Connection pool | `ConnectionPool` | None |
| TLS context | `TlsContext` | Shared read-only (immutable after init) |

**No Lua state is shared. No cross-thread access. No mutexes on the hot path.**

Workers are pinned to CPU cores for cache locality. eBPF can optionally provide connection affinity so the same client always hits the same worker.

The only cross-worker mechanism is `SseBroadcastBus`, which uses per-worker mutex-protected inboxes and `xev.Async` notifiers to wake target event loops.

## 3. Request Lifecycle

```
Accept → Read → Parse → Route → Execute → Respond → Reuse
```

1. **Accept** — `Server.onAccept` creates a `Connection` with an arena allocator. If TLS is configured, `conn_tls.initTls` starts the handshake state machine.

2. **Read** — libxev async recv fills the `LinearBuffer`. Callback: `Connection.onRead`. For TLS connections, ciphertext is fed through `conn_tls` which decrypts into the plaintext buffer.

3. **Parse** — `http.Parser` (picohttpparser via C FFI) produces a zero-copy `Request`. All header names, values, path, and method are slices into the `LinearBuffer`. No allocations.

4. **Route** — `Router.match` performs O(path-length) trie lookup, populating a `ParamArray` (inline array, max 4 params, zero heap allocation). Query string is parsed into `QueryArray` via `parseQueryString`.

5. **Execute** — `LuaState.callLuaHandler` creates a Lua coroutine (`lua_newthread` + `lua_resume`), passes `HttpExchange` userdata. The handler reads request data and sets response fields on `ctx`. If the handler calls cosocket APIs, the coroutine yields and Zig submits the I/O; on completion, Zig resumes the coroutine.

6. **Respond** — `HttpExchange.toResponse` builds the `Response`, `Response.serialize` writes headers + body into the send buffer, libxev async send transmits it. Special paths: SSE upgrade (`conn_sse`), WebSocket upgrade (`conn_ws`), chunked streaming (`conn_stream`). Static file routes (`static.zig`) short-circuit before Lua dispatch — served entirely in Zig with ETag/Last-Modified caching.

7. **Reuse** — Arena reset + buffer reset for HTTP/1.1 keep-alive. The `Connection` is ready for the next request on the same socket.

## 4. Memory Model

### Zero-Copy Default

Request data lives in `LinearBuffer`. Headers, path, method, and body are slices into this buffer — never copied. Copying data is a failure mode that must be justified.

### Arena Per-Request

Each `Connection` owns an arena allocator. All per-request allocations (HttpExchange userdata, formatted strings, response bodies) use this arena. After the response is sent, the arena is reset. If the response exceeded `LARGE_RESPONSE_THRESHOLD`, the arena backing memory is freed entirely to prevent unbounded growth on keep-alive connections.

### Pointer-in-Userdata

`HttpExchange` is a Zig struct allocated in the arena. Lua receives a userdata containing a pointer to this struct. This avoids the singleton-sharing problem: each request has its own userdata, and coroutines cannot accidentally access another request's state.

### Inline Parameter Storage

`ParamArray` (route params) and `QueryArray` (query params) are fixed-size inline arrays on the `Connection` struct. No heap allocation for parameter storage. Maximum counts are configured in `config.zig`.

### Connection Pooling

Cosocket connections are pooled per-worker in `ConnectionPool`, keyed by destination (host:port), using LIFO ordering with lazy expiry. Pooled connections avoid repeated TCP handshakes and TLS negotiations.

## 5. Module Architecture

| Module | Role |
|---|---|
| `main.zig` | Entry point, creates `ThreadPool` |
| `worker.zig` | Per-core thread with CPU pinning, owns xev.Loop + LuaState + Router + Server |
| `server.zig` | TCP listener, accept loop, SO_REUSEPORT, BPF attachment, TLS context init |
| `handler.zig` | `Connection` struct — socket lifecycle, read/write completions, arena, buffers, `SuspendedState` for coroutine yield/resume |
| `lua_state.zig` | LuaJIT state management, handler dispatch, coroutine lifecycle |
| `lua_api.zig` | Lua metatables for `ctx` (HttpExchange), headers proxy, params table, cosocket API registration |
| `route_loader.zig` | Route table processing from Lua `keyway.routes` declarations |
| `http_exchange.zig` | `HttpExchange` — the single Lua-visible object binding request/response |
| `http.zig` | HTTP types (`Request`, `Response`, `Header`), picohttpparser C bindings, response serialization |
| `router.zig` | Segment-level trie router with `{param}` support, zero-alloc matching |
| `params.zig` | `ParamArray`, `QueryArray`, `parseQueryString` — inline parameter storage |
| `buffer.zig` | `LinearBuffer` for single-request I/O |
| `config.zig` | Centralized tunable constants (buffer sizes, limits, capacities) |
| `ring.zig` | `IoEntry` tagged union, `SubmissionRing`, `CompletionRing` for batched cosocket I/O |
| `ring_api.zig` | Lua C API for ring push/submit/result |
| `cosocket.zig` | Outbound I/O engine: submission ring drain, batch ops, coroutine resume |
| `io_request.zig` | `IoRequest` — typed outbound I/O descriptor passed from Lua cosocket API to Zig |
| `connection_pool.zig` | Per-worker cosocket connection pool, keyed by destination, LIFO, lazy expiry |
| `tls.zig` | `TlsConn`, `TlsContext`, `ClientTlsContext`, `TlsManager` — TLS primitives |
| `conn_tls.zig` | Inbound TLS handshake/decrypt state machine for accepted connections |
| `conn_ws.zig` | WebSocket upgrade, frame encoding/decoding, send/recv |
| `ws.zig` | WebSocket frame parsing (low-level) |
| `conn_sse.zig` | SSE upgrade, per-connection send, disconnect watch |
| `sse.zig` | `SseRegistry` (per-worker room→subscribers), `SseBroadcastBus` (cross-worker pub/sub) |
| `conn_stream.zig` | Chunked transfer encoding streaming — yield-to-flush abstraction |
| `static.zig` | Static file serving — pread+send with ETag/Last-Modified caching |
| `shutdown.zig` | Graceful shutdown coordination (running → draining → force_shutdown) |
| `cli.zig` | CLI argument parsing with environment variable fallback |
| `error_response.zig` | Unified error response model — ErrorCategory → status/body/log-level |
| `cosocket_tls.zig` | Outbound cosocket TLS handshake state machine (client-side) |
| `cosocket_ops.zig` | Interpret functions for cosocket completion results |
| `helpers.zig` | Shared utility: `castUserdata` for xev callback pointer casts |
| `metrics.zig` | Per-worker atomic metrics for health monitoring |
| `bpf_reuseport.zig` | Classic BPF program generation for SO_REUSEPORT worker affinity |
| `log.zig` | Custom log formatting |

## 6. The Lua Contract

Lua interacts only with `ctx` (HttpExchange userdata) through metatables:

**Read:** `ctx.method`, `ctx.path`, `ctx.body`, `ctx.params.id`, `ctx.headers["Key"]`, `ctx.query.name`

**Write:** `ctx.status = 200`, `ctx.body = "..."`, `ctx.headers["Key"] = "value"`

No verbs (`send()`, `write()`). Only state assignment. Routes are registered via the declarative `keyway.routes` table. Middleware chains are supported at global and per-route levels.

Cosocket operations (`keyway.tcp_connect`, socket methods) are the exception: they are function calls that yield the Lua coroutine. But even here, Lua does not perform the I/O — it yields, Zig performs the I/O, and Zig resumes Lua with the result.

## 7. Design Rules

These rules are non-negotiable:

1. **Lua never performs syscalls or manages lifetimes.** Lua expresses intent through state assignment. Zig owns all I/O and memory.

2. **Zero-copy is the default.** Copying data is a failure mode. Request headers, path, and body are slices into the read buffer.

3. **libxev callbacks dispatch, not decide.** Callbacks transition to the next state. Business logic lives in the handler or Lua.

4. **Each layer has one job.** Modules do not compensate for failures in other modules. The router routes. The parser parses. The handler manages connection state.

5. **One core, one thread, one Lua state.** No sharing, no locking on the hot path. Cross-worker communication uses explicit message passing (SseBroadcastBus).

6. **Arena-per-request.** All per-request allocations use the connection's arena. Reset after response. No garbage accumulation.

7. **Inline over heap.** Fixed-size arrays (ParamArray, IoEntry rings) are preferred over heap-allocated dynamic containers when bounds are known.
