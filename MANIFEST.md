# MANIFEST.md — Keyway Architectural Contract

The authoritative design contract. Code conforms to these rules; deviations require explicit justification and approval.

## 1. Execution Model: Proactor

Lua **never** performs I/O, calls syscalls, or manages lifetimes. Lua describes intent by setting fields on `ctx` (the HttpExchange userdata); Zig reads that intent and submits all I/O via io_uring through libxev.

```
Lua: ctx.status = 200; ctx.body = "hello"   -- state assignment only
Zig: reads ctx → serializes response → submits async send via libxev
```

- All I/O is initiated by Zig, completed asynchronously by the kernel.
- libxev callbacks **dispatch** to the next stage; they hold no business logic.
- Lua coroutines yield on cosocket ops; Zig resumes them when I/O completes.

## 2. Per-Core Isolation

One worker thread per CPU core, pinned for cache locality. Each worker exclusively owns its `xev.Loop`, `LuaState`, `Router`, server socket (`SO_REUSEPORT`, kernel distributes), `SseRegistry`, `ConnectionPool`. `TlsContext` is shared read-only (immutable after init).

**No Lua state is shared. No cross-thread access. No mutexes on the hot path.** The only cross-worker mechanism is `SseBroadcastBus` (per-worker mutex-protected inboxes + `xev.Async` notifiers). eBPF can optionally pin a client to the same worker.

## 3. Request Lifecycle

```
Accept → Read → Parse → Route → Execute → Respond → Reuse
```

1. **Accept** — `Server.onAccept` makes a `Connection` with an arena allocator; TLS starts `conn_tls` handshake.
2. **Read** — libxev recv fills the `LinearBuffer`; TLS ciphertext is decrypted through `conn_tls`.
3. **Parse** — picohttpparser (C FFI) yields a zero-copy `Request` — method/path/headers/body are slices into the buffer, no allocations.
4. **Route** — `Router.match` does an O(path-length) trie lookup into inline `ParamArray`/`QueryArray` (zero heap).
5. **Execute** — `LuaState.callLuaHandler` runs a Lua coroutine with the `HttpExchange` userdata; cosocket calls yield → Zig does the I/O → Zig resumes.
6. **Respond** — `HttpExchange.toResponse` → `Response.serialize` → async send. Special paths: SSE (`conn_sse`), WebSocket (`conn_ws`), chunked (`conn_stream`). Static routes short-circuit before Lua (`static.zig`, ETag/Last-Modified).
7. **Reuse** — arena + buffer reset for keep-alive; if the response exceeded `LARGE_RESPONSE_THRESHOLD`, arena backing memory is freed to bound growth.

## 4. Memory Model

- **Zero-copy default** — request data stays in `LinearBuffer`; slices, never copies. Copying is a failure mode.
- **Arena-per-request** — every per-request allocation uses the `Connection`'s arena; reset after send.
- **Pointer-in-userdata** — Lua gets a userdata holding a pointer to the arena-allocated `HttpExchange`, so coroutines can't touch another request's state.
- **Inline params** — `ParamArray`/`QueryArray` are fixed-size inline arrays (caps in `config.zig`), no heap.
- **Connection pooling** — cosocket connections pooled per-worker by `host:port`, LIFO, lazy expiry.

## 5. Module Map

Source lives under `src/`, grouped by responsibility. Read the directory, not a per-file list (which rots):

| Dir | Owns |
|---|---|
| `core/` | Per-core lifecycle: `main`→`ThreadPool`→`worker` (CPU-pinned, owns loop+LuaState+Router+Server), `server` (accept, SO_REUSEPORT, BPF, TLS init), `handler` (`Connection`: socket lifecycle, read/write completions, arena, coroutine suspend/resume), `shutdown`, `reload`. |
| `http/` | HTTP path: `http` (Request/Response/parser bindings/serialize), `router` (zero-alloc trie), `route_loader`, `http_exchange` (the Lua-visible `ctx`), `params`, `static`, `error_response`. |
| `io/` | Outbound I/O + rings: `cosocket`(+`_ops`), `ring`/`ring_api` (IoEntry rings), `io_request`, `connection_pool`, `file_watcher`, `bpf_reuseport`. |
| `lua/` | LuaJIT: `lua_state` (state, handler dispatch, coroutine lifecycle), `lua_api` (ctx/headers/params metatables, cosocket registration), `json`. |
| `protocol/` | Upgraded protocols: `ws`/`conn_ws`, `sse`/`conn_sse` (SseRegistry + SseBroadcastBus), `conn_stream`. |
| `tls/` | `tls` (TlsContext/TlsConn/kTLS), `conn_tls` (inbound), `cosocket_tls` (outbound client). |
| `observability/` | `metrics` (per-worker atomics), `prom` (Prometheus export), `log`. |
| `util/` | `buffer` (LinearBuffer), `config` (tunable constants), `cli`, `helpers` (`castUserdata`), `clock`. |

## 6. The Lua Contract

Lua touches only `ctx` through metatables. **Read:** `ctx.method/.path/.body`, `ctx.params.id`, `ctx.headers["Key"]`, `ctx.query.name`. **Write:** `ctx.status`, `ctx.body`, `ctx.headers["Key"]`. No verbs (`send()`/`write()`) — state assignment only. Routes register via the declarative `keyway.routes` table; middleware chains at global and per-route levels.

Cosocket ops (`keyway.tcp_connect`, socket methods) are the one exception: function calls that **yield** the coroutine — but Lua still performs no I/O; it yields, Zig does the I/O and resumes with the result.

## 7. Design Rules (non-negotiable)

1. **Lua never does syscalls or manages lifetimes** — intent via state assignment; Zig owns all I/O and memory.
2. **Zero-copy is the default** — copying request data is a failure mode.
3. **libxev callbacks dispatch, not decide** — business logic lives in the handler or Lua.
4. **Each layer has one job** — modules don't compensate for other modules' failures.
5. **One core, one thread, one Lua state** — no hot-path sharing/locking; cross-worker only via `SseBroadcastBus`.
6. **Arena-per-request** — reset after response; no garbage accumulation.
7. **Inline over heap** — fixed-size arrays when bounds are known.
