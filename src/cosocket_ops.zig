//! Per-operation submit functions for outbound cosocket I/O.
//!
//! Single-shot path: submitOutboundIO reads pending_io from LuaState and
//! dispatches to the appropriate submit* function.
//!
//! Batch path: submitBatchConnect/submitBatchUdpConnect are called from
//! drainSubmissionRing in cosocket.zig for batched I/O.
//!
//! After kTLS: send/recv are plaintext — the kernel handles crypto transparently.

const std = @import("std");
const xev = @import("xev");
const Lua = @import("luajit").Lua;

const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const SuspendedState = handler_mod.SuspendedState;

const ring = @import("ring.zig");
const IoEntry = ring.IoEntry;
const prom = @import("prom.zig");

const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;

const io_request_mod = @import("io_request.zig");
const TlsMode = io_request_mod.TlsMode;

const LuaState = @import("lua_state.zig").LuaState;
const castUserdata = @import("helpers.zig").castUserdata;

const cosocket = @import("cosocket.zig");
const cosocket_tls = @import("cosocket_tls.zig");

const error_response = @import("error_response.zig");
const ErrorCategory = error_response.ErrorCategory;

// ============================================================================
// Shared error infrastructure
// ============================================================================

/// Result of an interpret function: how many Lua values were pushed, and
/// whether the operation completed (false = re-submitted, e.g. TLS want_read).
pub const InterpretResult = struct {
    nresults: c_int,
    done: bool = true,
};

/// Push nil, {category=..., message=...} error table to the Lua thread stack.
/// All cosocket errors flow through this function so Lua always sees structured tables.
pub fn pushErrorTable(thread: *Lua, category: ErrorCategory, msg: [:0]const u8) void {
    thread.pushNil();
    thread.createTable(0, 2);
    thread.pushString(@tagName(category));
    thread.setField(-2, "category");
    thread.pushString(msg);
    thread.setField(-2, "message");
}

// ============================================================================
// Shared TLS helpers
// ============================================================================

/// Encrypt data for outbound send if TLS is active, then arena-dupe.
/// Returns the send-ready data (encrypted or plain, arena-duped), or null on failure.
pub fn encryptForSend(alloc: std.mem.Allocator, tls_conn: ?*TlsConn, data: []const u8) ?[]const u8 {
    if (tls_conn) |tc| {
        const ct = tc.sslWrite(data) orelse return null;
        return alloc.dupe(u8, ct) catch null;
    }
    return alloc.dupe(u8, data) catch null;
}

// ============================================================================
// Interpret functions — shared by onOutboundComplete (single-shot path)
// ============================================================================

/// Interpret a connect/pool_connect/udp_connect completion.
/// On failure: closes socket, pushes error table. On success: pushes fd (and reuse_count for pool_connect).
pub fn interpretConnect(thread: *Lua, s: *SuspendedState, result: xev.Result) InterpretResult {
    _ = result.connect catch {
        std.posix.close(s.outbound_fd);
        s.outbound_fd = -1;
        s.pending_op = .none;
        pushErrorTable(thread, .upstream_error, "connection refused");
        return .{ .nresults = 2 };
    };
    if (s.pending_op == .pool_connect) {
        thread.pushInteger(@intCast(s.outbound_fd));
        thread.pushInteger(0);
        s.outbound_fd = -1;
        s.pending_op = .none;
        return .{ .nresults = 2 };
    }
    thread.pushInteger(@intCast(s.outbound_fd));
    s.outbound_fd = -1;
    s.pending_op = .none;
    return .{ .nresults = 1 };
}

/// Interpret a send completion.
/// On failure: pushes error table. On success: pushes bytes_sent.
pub fn interpretSend(thread: *Lua, result: xev.Result) InterpretResult {
    const bytes_sent = result.send catch {
        pushErrorTable(thread, .upstream_error, "send failed");
        return .{ .nresults = 2 };
    };
    thread.pushInteger(@intCast(bytes_sent));
    return .{ .nresults = 1 };
}

/// Interpret a recv completion.
/// After kTLS, recv data is already plaintext. With userspace TLS, decrypt here.
pub fn interpretRecv(
    thread: *Lua,
    s: *SuspendedState,
    result: xev.Result,
) InterpretResult {
    const bytes_read = result.recv catch {
        s.recv_buf = null;
        pushErrorTable(thread, .upstream_error, "recv failed");
        return .{ .nresults = 2 };
    };
    if (s.recv_buf) |buf| {
        // Userspace TLS: decrypt ciphertext received from the wire
        if (s.outbound_tls) |tls_conn| {
            const plaintext = tls_conn.sslRead(buf[0..bytes_read], buf) orelse {
                s.recv_buf = null;
                pushErrorTable(thread, .upstream_error, "recv: TLS decrypt failed");
                return .{ .nresults = 2 };
            };
            thread.pushLString(plaintext);
        } else {
            thread.pushLString(buf[0..bytes_read]);
        }
    } else {
        thread.pushNil();
    }
    s.recv_buf = null;
    return .{ .nresults = 1 };
}

/// Interpret a close completion.
/// On failure: pushes error table. On success: pushes 1.
/// Frees userspace TLS state if present.
pub fn interpretClose(conn: *Connection, thread: *Lua, s: *SuspendedState, result: xev.Result) InterpretResult {
    _ = result.close catch {
        pushErrorTable(thread, .upstream_error, "close failed");
        return .{ .nresults = 2 };
    };
    s.outbound_fd = -1;
    s.cleanupTls(conn.base_allocator);
    thread.pushInteger(1);
    return .{ .nresults = 1 };
}

// -- Single-shot submit functions --

fn createTcpSocket(self: *Connection, host: []const u8, port: u16, comptime err_prefix: [:0]const u8) ?struct { sock: std.posix.socket_t, addr: std.net.Address } {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        cosocket.resumeWithError(self, .upstream_error, err_prefix ++ "socket creation failed");
        return null;
    };
    const addr = std.net.Address.parseIp4(host, port) catch {
        std.posix.close(sock);
        cosocket.resumeWithError(self, .upstream_error, err_prefix ++ "invalid address");
        return null;
    };
    return .{ .sock = sock, .addr = addr };
}

pub fn submitConnect(self: *Connection, conn: anytype, pending_op: IoEntry.Op) void {
    const s = &self.cs.suspended.?;
    s.pending_op = pending_op;
    const result = createTcpSocket(self, conn.host, conn.port, "connect: ") orelse return;
    s.outbound_fd = result.sock;
    s.completion = .{
        .op = .{ .connect = .{ .socket = result.sock, .addr = result.addr } },
        .userdata = self,
        .callback = cosocket.onOutboundComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

pub fn submitUdpConnect(self: *Connection, conn: anytype) void {
    const s = &self.cs.suspended.?;
    s.pending_op = .udp_connect;
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        cosocket.resumeWithError(self, .upstream_error, "udp_connect: socket creation failed");
        return;
    };
    if (conn.timeout_ms > 0) {
        const tv = std.posix.timeval{
            .sec = @intCast(conn.timeout_ms / 1000),
            .usec = @intCast((conn.timeout_ms % 1000) * 1000),
        };
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }
    s.outbound_fd = sock;
    const addr = std.net.Address.parseIp4(conn.host, conn.port) catch {
        std.posix.close(sock);
        s.outbound_fd = -1;
        cosocket.resumeWithError(self, .upstream_error, "udp_connect: invalid address");
        return;
    };
    s.completion = .{
        .op = .{ .connect = .{ .socket = sock, .addr = addr } },
        .userdata = self,
        .callback = cosocket.onOutboundComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

/// Submit plaintext send — kernel encrypts if kTLS is active.
pub fn submitSend(self: *Connection, snd: anytype) void {
    const s = &self.cs.suspended.?;
    const send_data = encryptForSend(self.arena.allocator(), s.outbound_tls, snd.data) orelse {
        cosocket.resumeWithError(self, .upstream_error, "send: encrypt/alloc failed");
        return;
    };
    s.completion = .{
        .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = send_data } } },
        .userdata = self,
        .callback = cosocket.onOutboundComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

/// Submit plaintext recv — kernel decrypts if kTLS is active.
pub fn submitRecv(self: *Connection, r: anytype) void {
    const s = &self.cs.suspended.?;
    const buf = self.arena.allocator().alloc(u8, r.max_len) catch {
        cosocket.resumeWithError(self, .server_error, "recv: alloc failed");
        return;
    };
    s.recv_buf = buf;
    s.completion = .{
        .op = .{ .recv = .{ .fd = r.fd, .buffer = .{ .slice = buf } } },
        .userdata = self,
        .callback = cosocket.onOutboundComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

pub fn submitClose(self: *Connection, cl: anytype) void {
    const s = &self.cs.suspended.?;
    s.completion = .{
        .op = .{ .close = .{ .fd = cl.fd } },
        .userdata = self,
        .callback = cosocket.onOutboundComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

pub fn submitTlsHandshake(self: *Connection, th: anytype) void {
    const s = &self.cs.suspended.?;
    s.pending_op = .tls_handshake;
    const tls_conn = self.base_allocator.create(TlsConn) catch {
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: alloc failed");
        return;
    };
    tls_conn.* = TlsConn.init(self.base_allocator, selectClientTlsCtx(self.lua_state, th.tls_mode), .client) catch {
        self.base_allocator.destroy(tls_conn);
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: tls init failed");
        return;
    };
    tls_conn.fixupExData();
    if (th.sni_host) |host| {
        const host_z = self.arena.allocator().dupeZ(u8, host) catch {
            tls_mod.freeTlsConn(self.base_allocator, tls_conn);
            cosocket.resumeWithError(self, .upstream_error, "sslhandshake: alloc failed");
            return;
        };
        tls_conn.setSni(host_z);
    }
    s.outbound_tls = tls_conn;
    _ = tls_conn.handshake();
    const total = tls_conn.drainAll();
    if (total == 0) {
        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
        s.outbound_tls = null;
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: no handshake data produced");
        return;
    }
    s.completion = .{
        .op = .{ .send = .{ .fd = th.fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
        .userdata = self,
        .callback = cosocket_tls.onSendComplete,
    };
    s.outbound_fd = th.fd;
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

/// Read pending_io from LuaState, dispatch to per-op handler
pub fn submitOutboundIO(self: *Connection) void {
    const pending = self.lua_state.pending_io orelse {
        cosocket.resumeWithError(self, .server_error, "no pending I/O operation");
        return;
    };
    self.lua_state.pending_io = null;
    prom.ringSubmissions(1);

    switch (pending) {
        .connect => |conn| submitConnect(self, conn, .connect),
        .pool_connect => |conn| submitConnect(self, conn, .pool_connect),
        .udp_connect => |conn| submitUdpConnect(self, conn),
        .send => |snd| submitSend(self, snd),
        .recv => |r| submitRecv(self, r),
        .close => |cl| submitClose(self, cl),
        .tls_handshake => |th| submitTlsHandshake(self, th),
        .setkeepalive => cosocket.resumeWithError(self, .server_error, "setkeepalive: not valid as pending I/O"),
        .none => cosocket.resumeWithError(self, .server_error, "no pending I/O operation"),
    }
}

// -- Batch submit helpers (called from drainSubmissionRing in cosocket.zig) --

/// Select the SSL_CTX for outbound cosocket TLS based on the requested mode.
pub fn selectClientTlsCtx(lua_state: *LuaState, mode: TlsMode) @TypeOf(lua_state.tls_manager.client_tls_ctx.ctx) {
    return switch (mode) {
        .verify => lua_state.tls_manager.client_tls_ctx.ctx,
        .insecure => lua_state.tls_manager.insecure_tls_ctx.ctx,
        .custom => if (lua_state.tls_manager.custom_tls_ctx) |ctx| ctx.ctx else lua_state.tls_manager.insecure_tls_ctx.ctx,
    };
}

/// Helper: create TCP socket and submit connect for batched I/O
pub fn submitBatchConnect(self: *Connection, host: []const u8, port: u16, io_index: u8, _: IoEntry.Op) void {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        self.cs.cq.push(.{ .result = -1, .err_msg = "socket creation failed", .err_category = .upstream_error });
        return;
    };

    const addr = std.net.Address.parseIp4(host, port) catch {
        std.posix.close(sock);
        self.cs.cq.push(.{ .result = -1, .err_msg = "connect: invalid address", .err_category = .upstream_error });
        return;
    };

    self.cs.batch_completions[io_index] = .{
        .op = .{ .connect = .{ .socket = sock, .addr = addr } },
        .userdata = self,
        .callback = cosocket.onBatchComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&self.cs.batch_completions[io_index]);
}

/// Helper: create UDP socket and submit connect for batched I/O
pub fn submitBatchUdpConnect(self: *Connection, host: []const u8, port: u16, timeout_ms: u32, io_index: u8) void {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        self.cs.cq.push(.{ .result = -1, .err_msg = "udp_connect: socket creation failed", .err_category = .upstream_error });
        return;
    };

    if (timeout_ms > 0) {
        const tv = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    const addr = std.net.Address.parseIp4(host, port) catch {
        std.posix.close(sock);
        self.cs.cq.push(.{ .result = -1, .err_msg = "udp_connect: invalid address", .err_category = .upstream_error });
        return;
    };

    self.cs.batch_completions[io_index] = .{
        .op = .{ .connect = .{ .socket = sock, .addr = addr } },
        .userdata = self,
        .callback = cosocket.onBatchComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&self.cs.batch_completions[io_index]);
}

// ============================================================================
// Tests
// ============================================================================

test "InterpretResult defaults done to true" {
    const ir = InterpretResult{ .nresults = 1 };
    try std.testing.expect(ir.done);
}

test "InterpretResult can be set to not done" {
    const ir = InterpretResult{ .nresults = 0, .done = false };
    try std.testing.expect(!ir.done);
}
