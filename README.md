# Key-way (Zig)

A reimagining of Keystone Gateway in Zig, leveraging libxev's event loop and LuaJIT for high-performance, protocol-agnostic gateway.

## Philosophy

**"Dumb gateway, smart tenants"** - Zero opinions about business logic, all primitives.

- **Deep modules** - Simple interfaces hiding complex implementations
- **Information hiding** - Users never see implementation details
- **Pull complexity down** - Zig handles hard stuff, Lua stays simple
- **General-purpose** - Primitives only, no opinions

## Architecture

- **Worker threads** (configurable, default 1)
- **One Lua state per thread** (long-lived, no state pool)
- **Lua coroutines for async** (one coroutine per request)
- **Yield/resume bridge** between Lua and libxev

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

## Status

🚧 **Work in Progress** - Phase 1: Foundation

See `/home/dkremer/.claude/plans/vast-yawning-church.md` for the full implementation plan.

## References

- Original Go implementation: `/home/dkremer/Documents/keystone-gateway/`
- libxev: https://github.com/mitchellh/libxev
- zig-luajit: https://github.com/sackosoft/zig-luajit
- picohttpparser: https://github.com/h2o/picohttpparser
