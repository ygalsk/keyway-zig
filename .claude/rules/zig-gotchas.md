---
paths:
  - "src/**/*.zig"
  - "build.zig"
  - "build.zig.zon"
---

# Zig Gotchas (keyway — LuaJIT via zig-luajit, libxev)

Read this before editing any `.zig` file. (Zig version + deps live in `build.zig.zon`; in-flight language migrations live in the issue tracker, not here.)

- **LuaJIT, not Lua 5.4.** Semantics are Lua 5.1 + a few 5.2 extensions. No 5.3/5.4 features: no `//` integer division, no `<close>` to-be-closed vars, no integer subtype. Bit ops come from the `bit` library.
- **Async-yield coroutine (WS/SSE/stream).** zig-luajit marks `resumeCoroutine`/`yieldCoroutine` private, so we call `c.lua_resume`/`c.lua_yield` from the typed `luajit_c` module (`@import("luajit_c")`, the `luajit-build` translate-C package, wired in `build.zig`), `@ptrCast`ing `*Lua`/thread values to `*c.lua_State` since they map 1:1. Still don't route resume/yield through the zig-luajit wrapper API. `luajit_c`'s `b.dependency` args must match zig-luajit's own internal `luajit_build` dependency (`link_as = .static`) exactly, or Zig instantiates the translate-C module twice and errors on the duplicate.
- **No `--gc-sections` — it breaks LuaJIT unwinding.** `build.zig` deliberately does NOT set `link_gc_sections`: `--gc-sections` strips the `.eh_frame` FDEs for keyway's own frames and the zig-luajit wrapper, so LuaJIT's external DWARF unwinder can't step through them and a C-raised `lua_error` (metamethods, etc.) `exit(1)`s the whole process (#186). It was originally added to work around GCC 15's `crt1.o` `.sframe`/`R_X86_64_PC64` relocations, but that no longer reproduces on current toolchains. If it ever returns, strip ONLY `.sframe`; never re-enable blanket gc-sections.
- **`rdynamic` on the exe** (`build.zig`) exports symbols so Lua `.so` modules (LuaRocks) resolve at runtime. Don't drop it.
- **OpenSSL is a system lib** — `linkSystemLibrary("ssl")` / `("crypto")` + `b.addTranslateC` on `src/tls/openssl.h` in `build.zig`, imported in `src/tls/tls.zig` as `@import("openssl")`.
- **`std.debug.assert` is stripped in release builds.** Never use it as a runtime guard for conditions that can actually occur (bad input, ring overflow, null state) — use real error returns.
- **Proactor rule (it bites here):** no blocking syscalls on the worker thread — no `std.net.tcpConnectToHost`, no blocking `read`/`pread`/`writeAll`. All I/O goes through libxev/io_uring. See MANIFEST.md.
