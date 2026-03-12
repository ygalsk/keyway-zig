const std = @import("std");
const Lua = @import("luajit").Lua;
const LuaState = @import("lua_state.zig").LuaState;
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;

extern "c" fn lua_yield(L: *anyopaque, nresults: c_int) c_int;

/// Describes a single pending outbound I/O intent from Lua.
/// Written by C yield functions, read by Zig after lua_resume returns LUA_YIELD.
pub const IoRequest = struct {
    op: Op = .none,
    fd: std.posix.socket_t = 0,
    host: ?[]const u8 = null,
    port: u16 = 0,
    send_data: ?[]const u8 = null,
    max_len: usize = 0,

    pool_name: ?[]const u8 = null,
    timeout_ms: u32 = 0,

    pub const Op = enum { connect, send, recv, close, pool_connect, udp_connect, tls_handshake, none };
};

/// Helper: extract *LuaState from closure upvalue(1)
inline fn getState(lua: *Lua) *LuaState {
    const ptr = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse @panic("cosocket: expected LuaState upvalue");
    return @as(*LuaState, @ptrCast(@alignCast(ptr)));
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

    state.pending_io = .{
        .op = .connect,
        .host = std.mem.span(host_cstr),
        .port = @intCast(port_raw),
    };

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

    state.pending_io = .{
        .op = .send,
        .fd = @intCast(fd_raw),
        .send_data = data,
    };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_io_recv(fd, max_len) → yields, resumes with data or nil,err
pub fn keyway_io_recv(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);
    const max_len_raw = lua.toInteger(2);

    state.pending_io = .{
        .op = .recv,
        .fd = @intCast(fd_raw),
        .max_len = @intCast(max_len_raw),
    };

    return lua_yield(@ptrCast(lua), 0);
}

/// __keyway_io_close(fd) → yields, resumes with 1 or nil,err
pub fn keyway_io_close(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);

    state.pending_io = .{
        .op = .close,
        .fd = @intCast(fd_raw),
    };

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
    state.pending_io = .{
        .op = .pool_connect,
        .host = std.mem.span(host_cstr),
        .port = @intCast(port_raw),
        .pool_name = pool_name,
    };

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

/// __keyway_io_sslhandshake(fd, sni_host) → yields, resumes with 1 or nil,err
/// Initiates a TLS handshake on an existing connected socket.
/// sni_host is optional — used for SNI and hostname verification.
pub fn keyway_io_sslhandshake(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const fd_raw = lua.toInteger(1);
    const sni_host: ?[]const u8 = if (lua.isString(2))
        if (lua.toString(2)) |s| std.mem.span(s) else |_| null
    else
        null;

    state.pending_io = .{
        .op = .tls_handshake,
        .fd = @intCast(fd_raw),
        .host = sni_host,
    };

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

    state.pending_io = .{
        .op = .udp_connect,
        .host = std.mem.span(host_cstr),
        .port = @intCast(port_raw),
        .timeout_ms = @intCast(timeout_raw),
    };

    return lua_yield(@ptrCast(lua), 0);
}
