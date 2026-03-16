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

Keyway is a programmable HTTP engine where Zig owns the execution engine (memory, I/O, event loop) and Lua expresses routing policy through a declarative interface. Tech stack: Zig, LuaJIT, libxev (io_uring), picohttpparser, eBPF.

The architecture is defined in MANIFEST.md — it is a non-negotiable design contract that all code must follow.

## Architecture

### Execution Model: Proactor

Lua **never** performs I/O. Lua describes intent (setting fields on `ctx`), Zig submits all I/O via io_uring through libxev. This is the foundational rule.

### Per-Core Isolation

Each CPU core runs one worker thread with its own:
- libxev event loop (`Loop`)
- LuaJIT state (`LuaState`)
- Trie router (`Router`)
- Server socket (via `SO_REUSEPORT`)

No Lua state is shared. No cross-thread access. Workers are pinned to CPU cores for cache locality. eBPF provides optional connection affinity so the same client always hits the same worker.

### Request Lifecycle

1. **Accept** — `Server.onAccept` creates a `Connection` with arena allocator
2. **Read** — libxev async recv into `LinearBuffer`, callback `Connection.onRead`
3. **Parse** — `http.Parser` (picohttpparser FFI) produces zero-copy `Request` slices into the LinearBuffer
4. **Route** — `Router.match` does O(path-length) lookup, populates `ParamArray` (inline, zero-alloc)
5. **Execute** — `LuaState.callLuaHandler` creates a Lua coroutine (`lua_newthread` + `lua_resume`), passes `HttpExchange` userdata to handler
6. **Respond** — `HttpExchange.toResponse` → `Response.serialize` → libxev async send
7. **Reuse** — Arena reset + buffer reset for HTTP/1.1 keep-alive on same connection

### Key Module Roles

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
| `bpf_reuseport.zig` | Classic BPF program generation for SO_REUSEPORT worker affinity (disabled by default) |
| `log.zig` | Custom log formatting |

### The Lua Contract

Lua interacts only with `ctx` (HttpExchange userdata) through metatables:
- **Read**: `ctx.method`, `ctx.path`, `ctx.body`, `ctx.params.id`, `ctx.headers["Key"]`
- **Write**: `ctx.status = 200`, `ctx.body = "..."`, `ctx.headers["Key"] = "value"`

No verbs (`send()`, `write()`). Only state assignment. Routes are registered via the declarative `keyway.routes` table. Middleware chains are supported at global and per-route levels.

### Memory Model

- Request data lives in `LinearBuffer` — headers/path/body are slices, never copied
- Per-request allocations use `Connection.arena` (reset after each response)
- `HttpExchange` userdata is created per-request (pointer-in-userdata pattern), `HeadersProxy` and params table are fresh per access
- `ParamArray` is inline on Connection (max 4 params, zero heap allocation)
- `rdynamic = true` in build.zig exports symbols for LuaRocks C module loading

### Lua Handler Scripts

The entry point is `keyway.lua` (configurable via `--script`), loaded by each worker independently. The file configures LuaJIT optimizations and registers routes. Core stdlib modules (`keyway.socket`, `keyway.ring`, `keyway.dns`, `keyway.form`, `keyway.response`, `keyway.crypto`, `keyway.http`, `keyway.db_socket`) are embedded in the binary via `@embedFile` and registered as `package.preload` entries — always available without disk I/O.

## Design Rules (from MANIFEST.md)

- Lua never performs syscalls or manages lifetimes
- Lua expresses intent through state assignment, not method calls
- Zero-copy is the default; copying is a failure mode
- libxev callbacks do not contain logic — they dispatch
- Each layer has one job and does not compensate for another
- One core, one thread, one Lua state — no sharing, no locking

## Cosocket Implementation Status

**Complete:** Full coroutine + cosocket infrastructure. Handler dispatch uses `lua_newthread` + `lua_resume`. Per-request userdata (pointer-in-userdata pattern) eliminates singleton sharing. `SuspendedState` struct in `handler.zig` bundles all yield state. Cosocket API (`keyway.tcp_connect`, `keyway.socket` Lua module) supports yield/resume on I/O with connection pooling.

**Key constraint:** zig-luajit marks `resumeCoroutine`/`yieldCoroutine` as private. We declare `extern "c" fn lua_resume` and `@ptrCast` the `*Lua` to call it directly.

## Workflow Orchestration

### 1. Plan Mode Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately — don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy
- Use subagents to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents when direct grep/read would take 3+ rounds
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review `tasks/lessons.md` at session start if it exists

### 4. Verification Before Done
- Never mark a task complete without proving it works — run `zig build test`, check compilation, demonstrate the fix
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes — don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests — then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items. For single-file fixes, skip the file and just do it.
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.

## Design Context

### Users
Backend and infrastructure engineers building routing/gateway systems. They open the dashboard to observe live traffic, debug request flows, and verify that Keyway's primitives (cosocket, DNS, streaming, WebSocket) work correctly. They're used to dense data tools and want full visibility without hand-holding.

### Brand Personality
**Precise, Fast, Minimal.** Keyway is an engineering tool that earns trust through transparency and speed, not decoration. Every pixel serves a purpose.

### Aesthetic Direction
- **Visual tone**: Dense data dashboard in the style of Grafana/Datadog — dark theme, functional color coding, maximum information density without clutter
- **Theme**: Dark mode only. Deep green-tinted blacks (`#0a0f0a` bg, `#141a14` surface) with kiwi green (`#73B44C`) as the singular accent
- **Typography**: JetBrains Mono exclusively — monospace reinforces the systems-engineering identity
- **Anti-references**: No generic SaaS aesthetic (rounded cards, pastel gradients, corporate feel). No cluttered IDE look (overwhelming panels, tiny unreadable text). No gratuitous animations or glassmorphism

### Color System
| Token | Value | Usage |
|---|---|---|
| `--accent` | `#73B44C` | Primary brand, success states, interactive highlights |
| `--accent-light` | `#9CCC65` | Hover states, emphasis |
| `--accent-dim` | `#4a7a2e` | Muted accent, borders on active elements |
| `--blue` | `#5b9cf5` | POST method, redirects, fetch/send indicators |
| `--yellow` | `#eab308` | PUT/PATCH, client errors (4xx) |
| `--red` | `#e55` | DELETE, server errors (5xx), disconnected states |
| `--purple` | `#c084fc` | WebSocket, streaming, broadcast events |

### Design Principles
1. **Data density over whitespace** — Show more information per pixel. Developers scan, they don't browse. Tight spacing, compact rows, no decorative padding.
2. **Color is functional, not decorative** — Every color communicates state: method type, status code, worker affinity, connection health. Never use color for pure aesthetics.
3. **No glow on non-clickable elements** — Hover effects only on interactive elements (buttons, clickable rows). Static content stays static.
4. **No horizontal scroll** — Layout must fit the viewport. Fixed sidebar, flexible main content. Constrain content rather than overflow.
5. **Confidence through visibility** — The dashboard should make the developer feel they can see everything happening in the system. Nothing hidden, nothing ambiguous.
6. **Authoring is lightweight** — Script editing, deploy, and toggle workflows should feel fast and low-friction. No modal wizards or multi-step forms. Inline editing, immediate feedback, keyboard-driven where possible.

### Frontend Stack
- **Bun + vanilla TypeScript** — No framework (React/Vue/etc). Vanilla DOM manipulation.
- **Tailwind CSS + daisyUI** — Use daisyUI defaults for component styling. Only override the color theme to match Keyway's palette. Don't fight default spacing/sizing.
- **JetBrains Mono everywhere** — Override daisyUI's font stack globally. All text is monospace.
