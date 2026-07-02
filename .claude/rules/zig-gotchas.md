---
paths:
  - "src/**/*.zig"
  - "build.zig"
  - "build.zig.zon"
---

# Zig Gotchas (keyway — LuaJIT via zig-luajit, libxev)

Read this before editing any `.zig` file. (Zig version + deps live in `build.zig.zon`; in-flight language migrations live in the issue tracker, not here.)

- **LuaJIT, not Lua 5.4.** Semantics are Lua 5.1 + a few 5.2 extensions. No 5.3/5.4 features: no `//` integer division, no `<close>` to-be-closed vars, no integer subtype. Bit ops come from the `bit` library.
- **Async-yield coroutine hack (WS/SSE/stream) — keep it.** zig-luajit marks `resumeCoroutine`/`yieldCoroutine` private. We declare `extern "c" fn lua_yield` and export `lua_resume` (both in `src/lua/lua_state.zig`), calling them via `@ptrCast(lua)` because `*Lua` maps 1:1 to `lua_State*`. Don't route this through the wrapper API.
- **GCC 15 linker workaround — don't remove.** `link_gc_sections = true` in `build.zig`: GCC 15's `crt1.o` has `.sframe` sections with `R_X86_64_PC64` relocations that Zig's bundled lld can't handle; `--gc-sections` discards the unreferenced ones.
- **`rdynamic` on the exe** (`build.zig`) exports symbols so Lua `.so` modules (LuaRocks) resolve at runtime. Don't drop it.
- **OpenSSL is a system lib** — `linkSystemLibrary("ssl")` / `("crypto")` + inline `@cImport` in `src/tls/tls.zig`.
- **`std.debug.assert` is stripped in release builds.** Never use it as a runtime guard for conditions that can actually occur (bad input, ring overflow, null state) — use real error returns.
- **Proactor rule (it bites here):** no blocking syscalls on the worker thread — no `std.net.tcpConnectToHost`, no blocking `read`/`pread`/`writeAll`. All I/O goes through libxev/io_uring. See MANIFEST.md.
