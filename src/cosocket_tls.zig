//! Outbound TLS handshake state machine for cosocket connections.
//!
//! Manages the multi-step TLS handshake over xev async I/O:
//!   send ClientHello -> recv ServerHello -> ... -> established
//!
//! Each step is an xev callback that feeds ciphertext to BoringSSL,
//! drains outbound data, and re-submits until handshake completes.

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
const ErrorCategory = error_response.ErrorCategory;

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

    // Timeout: clean up TLS handshake state without resuming coroutine.
    // Decrement pending_completions (incremented by submitTlsHandshake in cosocket_ops).
    if (self.timed_out) {
        self.pending_completions -= 1;
        cleanup(self);
        if (self.suspended) |*s| {
            if (s.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
                s.coroutine_ref = 0;
            }
            self.suspended = null;
        }
        self.maybeFinishClose();
        return .disarm;
    }

    const s = &self.suspended.?;
    const tls_conn = s.outbound_tls orelse {
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: missing tls state");
        return .disarm;
    };

    _ = result.send catch {
        cleanup(self);
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: send failed");
        return .disarm;
    };

    if (tls_conn.isEstablished()) {
        finish(self, tls_conn);
        return .disarm;
    }

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

    // Timeout: clean up TLS handshake state without resuming coroutine.
    if (self.timed_out) {
        self.pending_completions -= 1;
        cleanup(self);
        if (self.suspended) |*s| {
            if (s.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
                s.coroutine_ref = 0;
            }
            self.suspended = null;
        }
        self.maybeFinishClose();
        return .disarm;
    }

    const s = &self.suspended.?;
    const tls_conn = s.outbound_tls orelse {
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: missing tls state");
        return .disarm;
    };

    const bytes_read = result.recv catch {
        cleanup(self);
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: recv failed");
        return .disarm;
    };

    if (bytes_read == 0) {
        cleanup(self);
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: connection closed");
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
        .failed => {
            cleanup(self);
            cosocket.resumeWithError(self, .upstream_error, "sslhandshake: handshake failed");
        },
    }
    return .disarm;
}

/// Handshake complete: register TLS conn, resume coroutine with success.
fn finish(self: *Connection, tls_conn: *TlsConn) void {
    const s = &self.suspended.?;
    self.lua_state.registerTls(s.outbound_fd, tls_conn) catch {
        cleanup(self);
        cosocket.resumeWithError(self, .upstream_error, "sslhandshake: map put failed");
        return;
    };
    s.outbound_tls = null;
    s.outbound_fd = 0;
    s.pending_op = .none;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushInteger(1);
    cosocket.dispatchResume(self, thread, 1, s.exchange);
}

/// Submit a recv for the next handshake message from the server.
fn submitRecv(self: *Connection) void {
    const s = &self.suspended.?;
    const buf = s.recv_buf orelse blk: {
        const b = self.arena.allocator().alloc(u8, tls_mod.TLS_RECORD_MAX_SIZE) catch {
            cleanup(self);
            cosocket.resumeWithError(self, .upstream_error, "sslhandshake: alloc failed");
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

/// Clean up TLS resources on handshake failure.
pub fn cleanup(self: *Connection) void {
    const s = &self.suspended.?;
    if (s.outbound_tls) |tls_conn| {
        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
        s.outbound_tls = null;
    }
}
