//! Outbound TLS handshake state machine for cosocket connections.
//!
//! Manages the multi-step TLS handshake over xev async I/O:
//!   send ClientHello -> recv ServerHello -> ... -> established
//!
//! Each step is an xev callback that feeds ciphertext to OpenSSL,
//! drains outbound data, and re-submits until handshake completes.
//! After handshake, kTLS is set up and TlsConn is freed.

const std = @import("std");
const xev = @import("xev");
const Lua = @import("luajit").Lua;

const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;

const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;

const cosocket = @import("cosocket.zig");
const castUserdata = @import("helpers.zig").castUserdata;

const error_response = @import("error_response.zig");

/// xev callback: handshake send completed. Check if handshake is done,
/// submit recv for server response, or finish.
pub fn onSendComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const self = castUserdata(Connection, userdata);

    if (self.timed_out) return handleTimeoutCleanup(self);

    const s = &self.cs.suspended.?;
    const tls_conn = s.outbound_tls orelse {
        self.cs.pending_completions -= 1;
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: missing tls state");
        return .disarm;
    };

    _ = result.send catch {
        failHandshake(self, "sslhandshake: send failed");
        return .disarm;
    };

    if (tls_conn.isEstablished()) {
        finish(self, tls_conn);
        return .disarm;
    }

    // Handshake continues — re-submit recv using the same completion slot
    // (no pending_completions change, we're reusing the existing slot)
    submitRecv(self);
    return .disarm;
}

/// xev callback: handshake recv completed. Feed ciphertext to TLS engine,
/// continue handshake, submit next send or finish.
pub fn onRecvComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const self = castUserdata(Connection, userdata);

    if (self.timed_out) return handleTimeoutCleanup(self);

    const s = &self.cs.suspended.?;
    const tls_conn = s.outbound_tls orelse {
        self.cs.pending_completions -= 1;
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: missing tls state");
        return .disarm;
    };

    const bytes_read = result.recv catch {
        failHandshake(self, "sslhandshake: recv failed");
        return .disarm;
    };

    if (bytes_read == 0) {
        failHandshake(self, "sslhandshake: connection closed");
        return .disarm;
    }

    if (s.recv_buf) |buf| {
        tls_conn.feedCiphertext(buf[0..bytes_read]);
    }

    const hs_result = tls_conn.handshake();

    if (tls_conn.needsWrite()) {
        const total = tls_conn.drainAll();
        if (total > 0) {
            s.completion = .{
                .op = .{ .send = .{ .fd = s.outbound_fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                .userdata = self,
                .callback = onSendComplete,
            };
            self.loop.add(&s.completion);
            return .disarm;
        }
    }

    switch (hs_result) {
        .complete => finish(self, tls_conn),
        .want_read => submitRecv(self),
        .failed => failHandshake(self, "sslhandshake: handshake failed"),
    }
    return .disarm;
}

/// Handshake complete: set up kTLS, free TlsConn, resume coroutine with success.
fn finish(self: *Connection, tls_conn: *TlsConn) void {
    const s = &self.cs.suspended.?;

    // Enable kTLS — kernel handles encrypt/decrypt from here
    tls_conn.setupKtls(s.outbound_fd) catch {
        failHandshake(self, "sslhandshake: ktls setup failed");
        return;
    };

    // Free TlsConn — no longer needed after kTLS
    tls_mod.freeTlsConn(self.base_allocator, tls_conn);
    s.outbound_tls = null;
    s.outbound_fd = -1;
    s.pending_op = .none;
    self.cs.pending_completions -= 1;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushInteger(1);
    cosocket.dispatchResume(self, thread, 1, s.exchange);
}

/// Submit a recv for the next handshake message from the server.
fn submitRecv(self: *Connection) void {
    const s = &self.cs.suspended.?;
    const buf = s.recv_buf orelse blk: {
        const b = self.arena.allocator().alloc(u8, tls_mod.TLS_RECORD_MAX_SIZE) catch {
            failHandshake(self, "sslhandshake: alloc failed");
            return;
        };
        s.recv_buf = b;
        break :blk b;
    };
    s.completion = .{
        .op = .{ .recv = .{ .fd = s.outbound_fd, .buffer = .{ .slice = buf } } },
        .userdata = self,
        .callback = onRecvComplete,
    };
    self.loop.add(&s.completion);
}

/// Timeout cleanup: release TLS state and coroutine ref without resuming.
fn handleTimeoutCleanup(self: *Connection) xev.CallbackAction {
    self.cs.pending_completions -= 1;
    cleanup(self);
    if (self.cs.suspended) |*s| {
        if (s.coroutine_ref != 0) {
            self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
            s.coroutine_ref = 0;
        }
        self.cs.suspended = null;
    }
    self.maybeFinishClose();
    return .disarm;
}

/// Clean up TLS resources and resume coroutine with error.
fn failHandshake(self: *Connection, msg: [:0]const u8) void {
    cleanup(self);
    self.cs.pending_completions -= 1;
    cosocket.resumeWithError(self, .upstream_error, msg);
}

/// Clean up TLS resources on handshake failure.
pub fn cleanup(self: *Connection) void {
    const s = &self.cs.suspended.?;
    if (s.outbound_tls) |tls_conn| {
        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
        s.outbound_tls = null;
    }
}
