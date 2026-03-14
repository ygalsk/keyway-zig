//! Per-operation submit functions for outbound cosocket I/O.
//!
//! Single-shot path: submitOutboundIO reads pending_io from LuaState and
//! dispatches to the appropriate submit* function.
//!
//! Batch path: submitBatchConnect/submitBatchUdpConnect are called from
//! drainSubmissionRing in cosocket.zig for batched I/O.

const std = @import("std");
const xev = @import("xev");
const Lua = @import("luajit").Lua;

const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const SuspendedState = handler_mod.SuspendedState;

const ring = @import("ring.zig");
const IoEntry = ring.IoEntry;

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

pub fn submitConnect(self: *Connection, c: anytype, pending_op: IoEntry.Op) void {
    const s = &self.cs.suspended.?;
    s.pending_op = pending_op;
    const result = createTcpSocket(self, c.host, c.port, "connect: ") orelse return;
    s.outbound_fd = result.sock;
    s.completion = .{
        .op = .{ .connect = .{ .socket = result.sock, .addr = result.addr } },
        .userdata = self,
        .callback = cosocket.onOutboundComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

pub fn submitUdpConnect(self: *Connection, c: anytype) void {
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
    if (c.timeout_ms > 0) {
        const tv = std.posix.timeval{
            .sec = @intCast(c.timeout_ms / 1000),
            .usec = @intCast((c.timeout_ms % 1000) * 1000),
        };
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }
    s.outbound_fd = sock;
    const addr = std.net.Address.parseIp4(c.host, c.port) catch {
        std.posix.close(sock);
        s.outbound_fd = 0;
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

pub fn submitSend(self: *Connection, snd: anytype) void {
    const s = &self.cs.suspended.?;
    const data = self.arena.allocator().dupe(u8, snd.data) catch {
        cosocket.resumeWithError(self, .server_error, "send: arena alloc failed");
        return;
    };
    if (self.lua_state.getTls(snd.fd)) |tls_conn| {
        const ciphertext = cosocket.tlsEncryptAlloc(tls_conn, data, self.arena.allocator()) orelse {
            cosocket.resumeWithError(self, .upstream_error, "send: tls encrypt failed");
            return;
        };
        s.completion = .{
            .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = ciphertext } } },
            .userdata = self,
            .callback = cosocket.onOutboundComplete,
        };
    } else {
        s.completion = .{
            .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = data } } },
            .userdata = self,
            .callback = cosocket.onOutboundComplete,
        };
    }
    self.cs.pending_completions += 1;
    self.loop.add(&s.completion);
}

pub fn submitRecv(self: *Connection, r: anytype) void {
    const s = &self.cs.suspended.?;
    // Check if BoringSSL already has buffered plaintext before issuing kernel recv
    if (self.lua_state.getTls(r.fd)) |tls_conn| {
        if (tls_conn.hasPending()) {
            var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
            switch (tls_conn.decrypt(&plaintext_buf)) {
                .data => |n| {
                    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
                    thread.pushLString(plaintext_buf[0..n]);
                    cosocket.dispatchResume(self, thread, 1, s.exchange);
                    return;
                },
                .want_read => {},
                .zero_return => {
                    cosocket.resumeWithError(self, .upstream_error, "recv: tls connection closed");
                    return;
                },
                .err => |de| {
                    cosocket.resumeWithTlsError(self, "recv", de);
                    return;
                },
            }
        }
    }
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

pub fn submitClose(self: *Connection, c: anytype) void {
    const s = &self.cs.suspended.?;
    self.lua_state.removeTls(c.fd);
    s.completion = .{
        .op = .{ .close = .{ .fd = c.fd } },
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

    switch (pending) {
        .connect => |c| submitConnect(self, c, .connect),
        .pool_connect => |c| submitConnect(self, c, .pool_connect),
        .udp_connect => |c| submitUdpConnect(self, c),
        .send => |snd| submitSend(self, snd),
        .recv => |r| submitRecv(self, r),
        .close => |c| submitClose(self, c),
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
