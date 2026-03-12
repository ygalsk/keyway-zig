const std = @import("std");
const Lua = @import("luajit").Lua;
const LuaState = @import("lua_state.zig").LuaState;
const ring = @import("ring.zig");
const IoEntry = ring.IoEntry;

extern "c" fn lua_yield(L: *anyopaque, nresults: c_int) c_int;

/// Helper: extract *LuaState from closure upvalue(1)
inline fn getState(lua: *Lua) *LuaState {
    const ptr = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse @panic("ring_api: expected LuaState upvalue");
    return @as(*LuaState, @ptrCast(@alignCast(ptr)));
}

/// Helper: get the Connection's SubmissionRing from the current_connection pointer.
/// Returns null if no connection is active.
inline fn getSQ(state: *LuaState) ?*ring.SubmissionRing {
    const conn_ptr = state.current_connection orelse return null;
    // current_connection is *Connection stored as *anyopaque
    // We need to access the sq field. Since Connection is defined in handler.zig,
    // we use @fieldParentPtr or direct offset. But since we store *anyopaque,
    // we cast to the Connection type.
    const Connection = @import("handler.zig").Connection;
    const conn: *Connection = @ptrCast(@alignCast(conn_ptr));
    return &conn.sq;
}

/// Helper: extract a required string argument from the Lua stack, raising a Lua error on failure.
inline fn requireString(lua: *Lua, idx: i32, err_msg: [:0]const u8) []const u8 {
    return std.mem.span(lua.toString(idx) catch {
        lua.pushString(err_msg);
        lua.raiseError();
        unreachable;
    });
}

/// Helper: get the Connection's CompletionRing.
inline fn getCQ(state: *LuaState) ?*ring.CompletionRing {
    const conn_ptr = state.current_connection orelse return null;
    const Connection = @import("handler.zig").Connection;
    const conn: *Connection = @ptrCast(@alignCast(conn_ptr));
    return &conn.cq;
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
///   __keyway_ring_push("tls_handshake", fd, sni_host_or_nil)
pub fn keyway_ring_push(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);
    const sq = getSQ(state) orelse {
        lua.pushString("ring_push: no active request");
        lua.raiseError();
        return 0;
    };

    const op = requireString(lua, 1, "ring_push: op must be a string");

    const entry: IoEntry = if (std.mem.eql(u8, op, "connect")) blk: {
        const host = requireString(lua, 2, "ring_push connect: host must be a string");
        const port: u16 = @intCast(lua.toInteger(3));
        break :blk .{ .connect = .{ .host = host, .port = port } };
    } else if (std.mem.eql(u8, op, "pool_connect")) blk: {
        const pool_name = requireString(lua, 2, "ring_push pool_connect: pool_name must be a string");
        const host = requireString(lua, 3, "ring_push pool_connect: host must be a string");
        const port: u16 = @intCast(lua.toInteger(4));
        break :blk .{ .pool_connect = .{ .host = host, .port = port, .pool_name = pool_name } };
    } else if (std.mem.eql(u8, op, "udp_connect")) blk: {
        const host = requireString(lua, 2, "ring_push udp_connect: host must be a string");
        const port: u16 = @intCast(lua.toInteger(3));
        const timeout_ms: u32 = @intCast(lua.toInteger(4));
        break :blk .{ .udp_connect = .{ .host = host, .port = port, .timeout_ms = timeout_ms } };
    } else if (std.mem.eql(u8, op, "send")) blk: {
        const fd: std.posix.socket_t = @intCast(lua.toInteger(2));
        const data = lua.toLString(3) catch {
            lua.pushString("ring_push send: data must be a string");
            lua.raiseError();
            unreachable;
        };
        break :blk .{ .send = .{ .fd = fd, .data = data } };
    } else if (std.mem.eql(u8, op, "recv")) blk: {
        const fd: std.posix.socket_t = @intCast(lua.toInteger(2));
        const max_len: usize = @intCast(lua.toInteger(3));
        break :blk .{ .recv = .{ .fd = fd, .max_len = if (max_len == 0) 4096 else max_len } };
    } else if (std.mem.eql(u8, op, "close")) blk: {
        const fd: std.posix.socket_t = @intCast(lua.toInteger(2));
        break :blk .{ .close = .{ .fd = fd } };
    } else if (std.mem.eql(u8, op, "setkeepalive")) blk: {
        const fd: std.posix.socket_t = @intCast(lua.toInteger(2));
        const pool_name = requireString(lua, 3, "ring_push setkeepalive: pool_name must be a string");
        const timeout_ms: u32 = @intCast(lua.toInteger(4));
        const pool_size: u32 = @intCast(lua.toInteger(5));
        const reuse_count: u32 = @intCast(lua.toInteger(6));
        break :blk .{ .setkeepalive = .{ .fd = fd, .pool_name = pool_name, .timeout_ms = timeout_ms, .pool_size = pool_size, .reuse_count = reuse_count } };
    } else if (std.mem.eql(u8, op, "tls_handshake")) blk: {
        const fd: std.posix.socket_t = @intCast(lua.toInteger(2));
        const sni_host: ?[]const u8 = if (lua.isString(3))
            if (lua.toString(3)) |s| std.mem.span(s) else |_| null
        else
            null;
        break :blk .{ .tls_handshake = .{ .fd = fd, .sni_host = sni_host } };
    } else {
        lua.pushString("ring_push: unknown op");
        lua.raiseError();
        unreachable;
    };

    sq.push(entry) catch {
        lua.pushString("ring_push: ring full");
        lua.raiseError();
        return 0;
    };

    return 0;
}

/// __keyway_ring_submit() — Yield once. Zig drains entire SQ, resumes when all completions arrive.
/// Returns number of CQEs on resume.
/// If SQ is empty, returns 0 without yielding.
pub fn keyway_ring_submit(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);
    const sq = getSQ(state) orelse {
        lua.pushString("ring_submit: no active request");
        lua.raiseError();
        return 0;
    };

    if (sq.len() == 0) {
        lua.pushInteger(0);
        return 1; // no yield needed
    }

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_ring_result(index) — Read one CQE by index (0-based). Synchronous.
/// Returns: result, buf_or_nil, err_or_nil
pub fn keyway_ring_result(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);
    const cq = getCQ(state) orelse {
        lua.pushString("ring_result: no active request");
        lua.raiseError();
        return 0;
    };

    const index: u8 = @intCast(lua.toInteger(1));
    if (index >= cq.tail) {
        lua.pushNil();
        lua.pushNil();
        lua.pushString("ring_result: index out of range");
        return 3;
    }

    const cqe = cq.get(index);
    lua.pushInteger(@intCast(cqe.result));
    if (cqe.buf) |b| lua.pushLString(b) else lua.pushNil();
    if (cqe.err_msg) |e| lua.pushString(e) else lua.pushNil();
    return 3;
}
