# Keyway

A Zig-powered, Lua-controlled HTTP engine. Part of the [keystone-gateway.dev](https://keystone-gateway.dev) ecosystem.

## What is Keyway?

Keyway is a high-performance HTTP server where Zig handles the execution engine and Lua expresses routing policy. The philosophy is **"dumb gateway, smart tenants"** -- Zig owns memory, I/O, and the event loop; Lua declares intent through a simple, organic interface.

**Tech stack:** Zig, LuaJIT, libxev, picohttpparser, io_uring, eBPF

## Example

```lua
keyway.add_route("GET", "/ping", function(ctx)
    ctx.status = 200
    ctx.body = "pong"
end)

keyway.add_route("GET", "/users/{id}", function(ctx)
    local user_id = ctx.params.id
    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"id": ' .. user_id .. ', "status": "active"}'
end)
```

## Build

```bash
zig build
```

## Run

```bash
zig build run
```

## Test

```bash
zig build test
```

## Architecture

See [MANIFEST.md](MANIFEST.md) for the full architecture manifesto.

## References

- [keystone-gateway.dev](https://keystone-gateway.dev)
- [libxev](https://github.com/mitchellh/libxev)
- [zig-luajit](https://github.com/sackosoft/zig-luajit)
- [picohttpparser](https://github.com/h2o/picohttpparser)
