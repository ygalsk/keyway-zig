# Keyway

A programmable HTTP engine — Zig execution engine, Lua routing policy. Part of the [keystone-gateway.dev](https://keystone-gateway.dev) ecosystem.

## What is Keyway?

Keyway is a programmable HTTP engine where Zig owns the execution engine and Lua expresses routing policy. The philosophy is **"dumb gateway, smart tenants"** — Zig owns memory, I/O, and the event loop; Lua declares intent through a simple, organic interface.

**Tech stack:** Zig, LuaJIT, libxev, picohttpparser, io_uring, eBPF

## Example

```lua
local response = require("keyway.response")

keyway.routes = {
    middleware = {
        function(ctx, next)
            request_count = request_count + 1
            next()
        end,
    },

    ["/ping"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.body = "pong"
        end,
    },

    ["/users/{id}"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, {
                id = ctx.params.id,
                status = "active",
            })
        end,
    },

    ["/events"] = {
        GET = function(ctx)
            ctx.upgrade = "sse"
            ctx.sse_room = "updates"
        end,
    },

    ["/ws"] = {
        GET = function(ctx)
            ctx.upgrade = "websocket"
            ctx.on_message = function(ws)
                ws:send(ws.message)
            end
            ctx.on_close = function() end
        end,
    },

    ["/stream"] = {
        GET = function(ctx)
            ctx.upgrade = "stream"
            ctx.status = 200
            ctx.body = "chunk 1\n"
            coroutine.yield()
            ctx.body = "chunk 2\n"
        end,
    },
}
```

No `send()`, no `write()`, no lifecycle calls — only state assignment. Zig commits all I/O via io_uring.

## Features

- **Per-core isolation** — one worker thread, one Lua state, one event loop per CPU core. No locks.
- **WebSocket** — upgrade via `ctx.upgrade = "websocket"`, frame encoding/decoding handled by Zig.
- **SSE** — upgrade via `ctx.upgrade = "sse"`, cross-worker broadcast via `SseBroadcastBus`.
- **Chunked streaming** — `ctx.upgrade = "stream"` with `coroutine.yield()` to flush chunks.
- **TLS** — OpenSSL userspace handshake + kTLS kernel offload for the data path. kTLS is **required** (Linux ≥ 4.13 with the `tls` module): there is no userspace data path, so keyway refuses to start TLS when the module is absent rather than dropping every request.
- **Radix router** — O(path-length) trie with `{param}` support, zero allocations per match.
- **Middleware** — global and per-route chains with short-circuit support.
- **Zero-copy parsing** — picohttpparser produces slices into the read buffer. No copies.
- **Hot reload** — `--watch` monitors `.lua` files and reloads without dropping connections.
- **Static file serving** — Zig-native with ETag/Last-Modified caching, short-circuits before Lua.
- **Built-in dashboard** — Solid.js control plane at `/__keyway/dashboard`.
- **Prometheus metrics** — `/metrics` endpoint with request latency, connection gauges, Lua execution histograms.
- **eBPF** — optional `SO_REUSEPORT` connection affinity via classic BPF.

## Project Structure

```
src/
├── main.zig
├── core/           # server, worker, handler, shutdown, reload
├── http/           # HTTP types, exchange, router, params, static
├── protocol/       # WebSocket, SSE, chunked streaming
├── tls/            # TLS primitives, inbound handshake, kTLS offload
├── io/             # async-yield entry points (WS/SSE), file watcher, BPF
├── lua/            # LuaJIT state management, Lua API bindings
├── observability/  # logging, metrics, Prometheus
└── util/           # buffer, helpers, config, CLI
dashboard/          # Solid.js admin dashboard + keyway.lua entry script
lua/                # embedded Lua stdlib modules (keyway.response)
tests/              # Integration tests (Bun)
```

## Build

```bash
zig build          # Build the keyway binary
zig build run      # Build and run the server
zig build test     # Run all unit tests
```

See `build.zig.zon` for the required Zig version (source of truth). Dependencies (libxev, zig-luajit) are fetched automatically via `build.zig.zon`.

## Configuration

All flags have environment variable equivalents. CLI args take precedence over env vars.

| Flag | Env | Default | Description |
|---|---|---|---|
| `--host <addr>` | `KEYWAY_HOST` | `0.0.0.0` | Bind address |
| `--port <port>` | `KEYWAY_PORT` | `8080` | Listen port |
| `--workers <n>` | `KEYWAY_WORKERS` | `0` (auto) | Worker threads (0 = CPU count) |
| `--script <path>` | `KEYWAY_SCRIPT` | `keyway.lua` | Lua entry script |
| `--tls-cert <path>` | `KEYWAY_TLS_CERT` | — | TLS certificate file |
| `--tls-key <path>` | `KEYWAY_TLS_KEY` | — | TLS private key file |
| `--log-level <lvl>` | `KEYWAY_LOG_LEVEL` | `info` | `err`, `warn`, `info`, `debug` |
| `--log-format <fmt>` | `KEYWAY_LOG_FORMAT` | `logfmt` | `logfmt`, `json` |
| `--enable-bpf` | `KEYWAY_ENABLE_BPF` | off | Enable eBPF connection affinity |
| `--watch` | `KEYWAY_WATCH` | off | Hot-reload on `.lua` file changes |

## Dashboard

Keyway ships a built-in Solid.js dashboard at `/__keyway/dashboard`. It provides:

- Real-time event stream via SSE
- Route and middleware inspection
- Lua file editor (read/write/delete)

Access is restricted to localhost (`127.0.0.1` / `::1`). Manual reload: `POST /__keyway/reload`.

## Lua API

### ctx fields

**Read:** `ctx.method`, `ctx.path`, `ctx.body`, `ctx.params.id`, `ctx.query.name`, `ctx.headers["Key"]`, `ctx.request_headers`, `ctx.remote_addr`

**Write:** `ctx.status`, `ctx.body`, `ctx.headers["Key"]`, `ctx.upgrade`, `ctx.sse_room`, `ctx.on_message`, `ctx.on_close`

### Protocol upgrades

| Protocol | Directive | Notes |
|---|---|---|
| WebSocket | `ctx.upgrade = "websocket"` | Set `ctx.on_message` and `ctx.on_close` |
| SSE | `ctx.upgrade = "sse"` | Set `ctx.sse_room` for room-based broadcast |
| Streaming | `ctx.upgrade = "stream"` | `coroutine.yield()` flushes each chunk |

### Stdlib modules

| Module | Purpose |
|---|---|
| `keyway.response` | `json_response`, `get_header`, `broadcast_event`, `now_us` |

## Observability

Keyway exposes Prometheus metrics at `/metrics` (text exposition format).

**HTTP**
- `keyway_http_requests_total` — counter by worker, method, status, route
- `keyway_http_request_duration_seconds` — latency histogram by worker, route
- `keyway_http_request_body_bytes` — request body size histogram
- `keyway_http_response_body_bytes` — response body size histogram

**Connections**
- `keyway_connections_accepted_total` — per-worker counter
- `keyway_connections_active` — per-worker gauge
- `keyway_connections_rejected_total` — per-worker counter

**Lua runtime**
- `keyway_lua_coroutines_active` — per-worker gauge
- `keyway_lua_script_duration_seconds` — execution time histogram by worker, route

## Testing

```bash
# Zig unit tests (embedded in source files)
zig build test

# Integration tests (requires bun, starts server automatically)
cd tests && bun run test

# CI / agent mode — bail on first failure
cd tests && bun run test:ci
```

Integration tests use native `fetch`, `WebSocket`, and `EventSource` against a real server instance. Test suites cover routing, headers, body handling, streaming, WebSocket, SSE, and the dashboard API.

## Architecture

See [MANIFEST.md](MANIFEST.md) for the full architecture contract.

## References

- [keystone-gateway.dev](https://keystone-gateway.dev)
- [libxev](https://github.com/mitchellh/libxev)
- [zig-luajit](https://github.com/sackosoft/zig-luajit)
- [picohttpparser](https://github.com/h2o/picohttpparser)
