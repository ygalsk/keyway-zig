const Lua = @import("luajit").Lua;
const LuaState = @import("lua_state.zig").LuaState;
const castUserdata = @import("helpers.zig").castUserdata;
const io_request = @import("io_request.zig");
const ErrorCategory = @import("error_response.zig").ErrorCategory;

extern "c" fn lua_yield(L: *anyopaque, nresults: c_int) c_int;

/// Helper: extract *LuaState from closure upvalue(1)
inline fn getState(lua: *Lua) *LuaState {
    const ptr = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse {
        lua.pushString("ring_api: expected LuaState upvalue");
        lua.raiseError();
        unreachable;
    };
    return castUserdata(LuaState, @as(?*anyopaque, ptr));
}

/// __keyway_ring_push(op_str, ...) — Push one IoEntry onto the SQ. Never yields.
///
/// Lua signatures by op:
///   __keyway_ring_push("connect", host, port)
///   __keyway_ring_push("pool_connect", pool_name, host, port)
///   __keyway_ring_push("udp_connect", host, port, timeout_ms)
///   __keyway_ring_push("send", fd, data)
///   __keyway_ring_push("recv", fd, max_len)
///   __keyway_ring_push("close", fd)
///   __keyway_ring_push("setkeepalive", fd, pool_name, timeout_ms, pool_size, reuse_count)
///   __keyway_ring_push("tls_handshake", fd, sni_host_or_nil, tls_mode)
pub fn keyway_ring_push(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const op = io_request.requireString(lua, 1, "ring_push: op must be a string");

    // arg_offset=2 because arg 1 is the op string
    const entry = io_request.parseIoEntry(lua, op, 2);

    state.pushSqEntry(entry) catch |err| switch (err) {
        error.NoActiveRequest => {
            lua.pushString("ring_push: no active request");
            lua.raiseError();
            return 0;
        },
        error.RingFull => {
            lua.pushString("ring_push: ring full (max 16 ops per batch, call ring_submit between batches)");
            lua.raiseError();
            return 0;
        },
    };

    return 0;
}

/// __keyway_ring_submit() — Yield once. Zig drains entire SQ, resumes when all completions arrive.
/// Returns number of CQEs on resume.
/// If SQ is empty, returns 0 without yielding.
pub fn keyway_ring_submit(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);
    const sq_len = state.sqLen() orelse {
        lua.pushString("ring_submit: no active request");
        lua.raiseError();
        return 0;
    };

    if (sq_len == 0) {
        lua.pushInteger(0);
        return 1; // no yield needed
    }

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_ring_result(index) — Read one CQE by index (0-based). Synchronous.
/// Returns: result, buf_or_nil, err_or_nil
pub fn keyway_ring_result(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);
    const index: u8 = @intCast(lua.toInteger(1));

    const cqe = state.getCqEntry(index) orelse {
        lua.pushNil();
        lua.pushNil();
        lua.pushString("ring_result: index out of range");
        return 3;
    };
    lua.pushInteger(@intCast(cqe.result));
    if (cqe.buf) |b| lua.pushLString(b) else lua.pushNil();
    if (cqe.err_msg) |e| {
        // Construct structured error table {category=..., message=...}
        // matching single-shot path error format for consistency
        lua.createTable(0, 2);
        if (cqe.err_category) |cat| {
            lua.pushString(@tagName(cat));
        } else {
            lua.pushString("server_error");
        }
        lua.setField(-2, "category");
        lua.pushString(e);
        lua.setField(-2, "message");
    } else lua.pushNil();
    return 3;
}
