# Keyway

A programmable HTTP engine — Zig execution engine, Lua routing policy. Part of the [keystone-gateway.dev](https://keystone-gateway.dev) ecosystem.

## What is Keyway?

Keyway is a programmable HTTP engine where Zig owns the execution engine and Lua expresses routing policy. The philosophy is **"dumb gateway, smart tenants"** — Zig owns memory, I/O, and the event loop; Lua declares intent through a simple, organic interface.

**Tech stack:** Zig, LuaJIT, libxev, picohttpparser, io_uring, eBPF

## Example

```lua
keyway.routes = {
    -- Middleware runs on every request
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
            local user_id = ctx.params.id
            ctx.status = 200
            ctx.headers["Content-Type"] = "application/json"
            ctx.body = '{"id": ' .. user_id .. ', "status": "active"}'
        end,
    },
}
```

No `send()`, no `write()`, no lifecycle calls — only state assignment. Zig commits all I/O via io_uring.

## Features

- **Per-core isolation**: one worker thread, one Lua state, one event loop per CPU core — no locks
- **Cosockets**: non-blocking outbound TCP (e.g. Redis, PostgreSQL) via coroutine yield/resume with connection pooling
- **Middleware**: global and per-route middleware chains with short-circuit support
- **Zero-copy parsing**: picohttpparser FFI produces slices into the read buffer
- **Radix router**: O(path-length) route matching with `{param}` support, zero allocations

## Build

```bash
zig build          # Build the keyway binary
zig build run      # Build and run the server (listens on 0.0.0.0:8080)
zig build test     # Run all unit tests
```

Requires Zig 0.15.0+. Dependencies (libxev, zig-luajit) are fetched automatically via `build.zig.zon`.

## Architecture

See [MANIFEST.md](MANIFEST.md) for the full architecture manifesto.

## References

- [keystone-gateway.dev](https://keystone-gateway.dev)
- [libxev](https://github.com/mitchellh/libxev)
- [zig-luajit](https://github.com/sackosoft/zig-luajit)
- [picohttpparser](https://github.com/h2o/picohttpparser)
