# Keyway

A programmable HTTP engine: **Zig owns the execution engine** (memory, io_uring via libxev, LuaJIT); **Lua expresses routing/policy** as declarative state on `ctx` — it never performs I/O. Stack: Zig, LuaJIT, libxev, picohttpparser, eBPF.

**What it's for:** a programmable reverse proxy / API gateway (peers: OpenResty, Kong, Envoy) — Lua expresses routing, auth, rate-limiting, transforms, and TLS as *policy*, not app logic. Craft-first, aspiring open-source; the dashboard is the end-to-end test client, not the product. Fuller rationale: README / MANIFEST.md.

## Build & test

```bash
zig build                     # build the keyway binary
zig build run                 # run the server (0.0.0.0:8080)
zig build test                # unit tests (embedded in source files)
cd tests && bun run test:ci   # bun integration suite (needs a running server)
```

Zig version and deps: see `build.zig.zon` — the source of truth, so this file can't go stale on a bump.

## The contracts — read these

- **MANIFEST.md** — *architecture* contract: proactor model, per-core isolation, zero-copy, request lifecycle, the Lua contract, module map. Authoritative: code conforms or the deviation is justified.
- **.claude/rules/zig-gotchas.md** — read before editing any `.zig`.

## Working conventions

Work is tracked as **GitHub Issues** (the backlog, hand-driven via `gh`). Branch `kw/<issue#>-<slug>`; PR body contains `Closes #<issue#>`. **No AI/Claude attribution in commits or PRs.**

## Non-negotiables

- **Proactor:** Lua never does I/O or syscalls — it sets fields on `ctx`; Zig submits all I/O via libxev/io_uring.
- **Per-core isolation:** one thread / one xev loop / one LuaState / one Router per core, `SO_REUSEPORT`. No sharing, no hot-path locks.
- **Zero-copy default:** headers/path/body are slices into the read buffer. Copying is a failure mode.
- **Surgical & minimal:** touch only what the task needs; simplest change that works; no speculative abstractions. Spot something incoherent? File an issue — don't fix it inline.
- **Verify before done:** `zig build test` + the bun integration suite must pass.

## Testing & tone

- **Integration-first.** The dashboard is the integration test client. Triage by layer: if JS/Lua breaks using standard patterns, the real bug is usually in the layer below — the Zig engine is where root causes live.
- **Skeptical mentor.** Default stance is challenge, not agreement: decompose from first principles (what *genus*? essential vs. accidental?), research current (2025–2026) practice, critique the tradeoffs — *then* recommend. If an idea is genuinely good, say why. Terse, direct — a senior engineer who's seen too many rewrites.
