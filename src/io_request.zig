const std = @import("std");
const Lua = @import("luajit").Lua;
const LuaState = @import("lua_state.zig").LuaState;
const castUserdata = @import("helpers.zig").castUserdata;
const IoEntry = @import("ring.zig").IoEntry;
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;

extern "c" fn lua_yield(L: *anyopaque, nresults: c_int) c_int;

/// TLS context selector — which SSL_CTX to use for a handshake.
pub const TlsMode = enum { verify, insecure, custom };

/// Helper: extract a required string argument from the Lua stack, raising a Lua error on failure.
pub inline fn requireString(lua: *Lua, idx: i32, err_msg: [:0]const u8) []const u8 {
    return std.mem.span(lua.toString(idx) catch {
        lua.pushString(err_msg);
        lua.raiseError();
        unreachable;
    });
}

/// Parse TLS mode from a Lua argument: boolean (backward compat) or string ("verify","insecure","custom").
/// Returns .verify as the default.
pub fn parseTlsMode(lua: *Lua, arg_index: i32) TlsMode {
    if (lua.isString(arg_index)) {
        const mode_str = std.mem.span(lua.toString(arg_index) catch return TlsMode.verify);
        if (std.mem.eql(u8, mode_str, "custom")) return TlsMode.custom;
        if (std.mem.eql(u8, mode_str, "insecure")) return TlsMode.insecure;
        return TlsMode.verify;
    } else if (lua.isBoolean(arg_index) and lua.toBoolean(arg_index)) {
        return TlsMode.insecure;
    }
    return TlsMode.verify;
}

/// Parse a Lua stack into an IoEntry based on an op string.
/// `arg_offset` is the stack index of the first argument after the op string.
/// For direct io_request calls, this is 1. For ring_push where arg1=op, this is 2.
/// Uses `std.meta.stringToEnum` (comptime `@typeInfo` lookup) for O(1) dispatch
/// and exhaustive switch — adding a new Op variant is a compile error until handled here.
pub fn parseIoEntry(lua: *Lua, op: []const u8, arg_offset: i32) IoEntry {
    const tag = std.meta.stringToEnum(IoEntry.Op, op) orelse {
        lua.pushString("unknown io op");
        lua.raiseError();
        unreachable;
    };

    return switch (tag) {
        .connect => .{ .connect = .{
            .host = requireString(lua, arg_offset, "connect: host must be a string"),
            .port = @intCast(lua.toInteger(arg_offset + 1)),
        } },
        .pool_connect => .{ .pool_connect = .{
            .pool_name = requireString(lua, arg_offset, "pool_connect: pool_name must be a string"),
            .host = requireString(lua, arg_offset + 1, "pool_connect: host must be a string"),
            .port = @intCast(lua.toInteger(arg_offset + 2)),
        } },
        .udp_connect => .{ .udp_connect = .{
            .host = requireString(lua, arg_offset, "udp_connect: host must be a string"),
            .port = @intCast(lua.toInteger(arg_offset + 1)),
            .timeout_ms = @intCast(lua.toInteger(arg_offset + 2)),
        } },
        .send => .{ .send = .{
            .fd = @intCast(lua.toInteger(arg_offset)),
            .data = lua.toLString(arg_offset + 1) catch {
                lua.pushString("send: data must be a string");
                lua.raiseError();
                unreachable;
            },
        } },
        .recv => blk: {
            const max_len: usize = @intCast(lua.toInteger(arg_offset + 1));
            break :blk .{ .recv = .{
                .fd = @intCast(lua.toInteger(arg_offset)),
                .max_len = if (max_len == 0) 4096 else max_len,
            } };
        },
        .close => .{ .close = .{
            .fd = @intCast(lua.toInteger(arg_offset)),
        } },
        .setkeepalive => .{ .setkeepalive = .{
            .fd = @intCast(lua.toInteger(arg_offset)),
            .pool_name = requireString(lua, arg_offset + 1, "setkeepalive: pool_name must be a string"),
            .timeout_ms = @intCast(lua.toInteger(arg_offset + 2)),
            .pool_size = @intCast(lua.toInteger(arg_offset + 3)),
            .reuse_count = @intCast(lua.toInteger(arg_offset + 4)),
        } },
        .tls_handshake => .{ .tls_handshake = .{
            .fd = @intCast(lua.toInteger(arg_offset)),
            .sni_host = if (lua.isString(arg_offset + 1))
                if (lua.toString(arg_offset + 1)) |s| std.mem.span(s) else |_| null
            else
                null,
            .tls_mode = parseTlsMode(lua, arg_offset + 2),
        } },
        .none => {
            lua.pushString("unknown io op");
            lua.raiseError();
            unreachable;
        },
    };
}

/// Helper: extract *LuaState from closure upvalue(1)
inline fn getState(lua: *Lua) *LuaState {
    const ptr = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse {
        lua.pushString("cosocket: expected LuaState upvalue");
        lua.raiseError();
        unreachable;
    };
    return castUserdata(LuaState, @as(?*anyopaque, ptr));
}

/// __keyway_io_connect(host, port) → yields, resumes with fd or nil,err
pub fn keyway_io_connect(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const host_cstr = lua.toString(1) catch {
        lua.pushString("connect: host must be a string");
        lua.raiseError();
        return 0;
    };
    const port_raw = lua.toInteger(2);

    state.pending_io = .{ .connect = .{
        .host = std.mem.span(host_cstr),
        .port = @intCast(port_raw),
    } };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_io_send(fd, data) → yields, resumes with bytes_sent or nil,err
pub fn keyway_io_send(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);
    // Use toLString to preserve embedded null bytes (PostgreSQL wire protocol is binary)
    const data = lua.toLString(2) catch {
        lua.pushString("send: data must be a string");
        lua.raiseError();
        return 0;
    };

    state.pending_io = .{ .send = .{
        .fd = @intCast(fd_raw),
        .data = data,
    } };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_io_recv(fd, max_len) → yields, resumes with data or nil,err
pub fn keyway_io_recv(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);
    const max_len_raw = lua.toInteger(2);

    state.pending_io = .{ .recv = .{
        .fd = @intCast(fd_raw),
        .max_len = @intCast(max_len_raw),
    } };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_io_close(fd) → yields, resumes with 1 or nil,err
pub fn keyway_io_close(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);

    state.pending_io = .{ .close = .{
        .fd = @intCast(fd_raw),
    } };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_pool_connect(pool_name, host, port) → sync on pool hit, yields on miss
/// Pool hit: pushes (fd, reuse_count), returns 2 (no yield)
/// Pool miss: writes pending_io with .pool_connect, yields
pub fn keyway_pool_connect(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const pool_name_cstr = lua.toString(1) catch {
        lua.pushString("pool_connect: pool_name must be a string");
        lua.raiseError();
        return 0;
    };
    const host_cstr = lua.toString(2) catch {
        lua.pushString("pool_connect: host must be a string");
        lua.raiseError();
        return 0;
    };
    const port_raw = lua.toInteger(3);

    const pool_name = std.mem.span(pool_name_cstr);

    // Try pool first (synchronous path)
    if (state.pool.get(pool_name)) |entry| {
        // Restore TLS state from pool if present
        if (entry.tls_conn) |tls_conn| {
            state.registerTls(entry.fd, tls_conn) catch {
                // TLS map insert failed — free TLS state, still return the fd
                tls_mod.freeTlsConn(state.allocator, tls_conn);
            };
        }
        lua.pushInteger(@intCast(entry.fd));
        lua.pushInteger(@intCast(entry.reuse_count + 1));
        return 2; // No yield — return fd and reuse_count directly
    }

    // Pool miss — async connect via io_uring
    state.pending_io = .{ .pool_connect = .{
        .host = std.mem.span(host_cstr),
        .port = @intCast(port_raw),
        .pool_name = pool_name,
    } };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_pool_setkeepalive(fd, pool_name, timeout_ms, pool_size, reuse_count) → always sync
/// Returns 1 on success, pushes (nil, err) on failure
pub fn keyway_pool_setkeepalive(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);
    const pool_name_cstr = lua.toString(2) catch {
        lua.pushNil();
        lua.pushString("setkeepalive: pool_name must be a string");
        return 2;
    };
    const timeout_raw = lua.toInteger(3);
    const size_raw = lua.toInteger(4);
    const reuse_raw = lua.toInteger(5);

    const fd: std.posix.socket_t = @intCast(fd_raw);

    // Transfer TLS state from tls_map to pool if present
    const tls_ptr: ?*TlsConn = state.detachTls(fd);

    state.pool.put(
        std.mem.span(pool_name_cstr),
        fd,
        @intCast(reuse_raw),
        @intCast(timeout_raw),
        @intCast(size_raw),
        tls_ptr,
    ) catch {
        lua.pushNil();
        lua.pushString("setkeepalive: pool put failed");
        return 2;
    };

    lua.pushInteger(1);
    return 1;
}

/// __keyway_io_sslhandshake(fd, sni_host, no_verify_or_mode) → yields, resumes with 1 or nil,err
/// Initiates a TLS handshake on an existing connected socket.
/// sni_host is optional — used for SNI and hostname verification.
/// no_verify_or_mode: boolean (true=insecure) or string ("verify","insecure","custom")
pub fn keyway_io_sslhandshake(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);
    const sni_host: ?[]const u8 = if (lua.isString(2))
        if (lua.toString(2)) |s| std.mem.span(s) else |_| null
    else
        null;

    // Parse TLS mode from arg 3: boolean (backward compat) or string
    const tls_mode = parseTlsMode(lua, 3);

    state.pending_io = .{ .tls_handshake = .{
        .fd = @intCast(fd_raw),
        .sni_host = sni_host,
        .tls_mode = tls_mode,
    } };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_ws_send(data) → yields, resumes after WS frame is sent
pub fn keyway_ws_send(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    // arg 1 = self (WsContext userdata, from ws:send() colon syntax), arg 2 = data string
    const data = lua.toLString(2) catch {
        lua.pushString("ws_send: data must be a string");
        lua.raiseError();
        return 0;
    };

    // Use send with fd=0 as ws_send signal (conn_ws checks for this)
    state.pending_io = .{ .send = .{
        .fd = 0,
        .data = data,
    } };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_io_udp_connect(host, port, timeout_ms) → yields, resumes with fd or nil,err
/// Creates a SOCK_DGRAM socket and connects it to the given address.
/// After this, __keyway_io_send and __keyway_io_recv work normally.
/// timeout_ms is stored in SuspendedState and applied to subsequent recv operations.
pub fn keyway_io_udp_connect(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const host_cstr = lua.toString(1) catch {
        lua.pushString("udp_connect: host must be a string");
        lua.raiseError();
        return 0;
    };
    const port_raw = lua.toInteger(2);
    const timeout_raw = lua.toInteger(3);

    state.pending_io = .{ .udp_connect = .{
        .host = std.mem.span(host_cstr),
        .port = @intCast(port_raw),
        .timeout_ms = @intCast(timeout_raw),
    } };

    return lua_yield(@ptrCast(lua), 0);
}
