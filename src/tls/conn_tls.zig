const std = @import("std");
const xev = @import("xev");
const log = @import("../observability/log.zig");
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;
const TlsContext = tls_mod.TlsContext;
const LinearBuffer = @import("../util/buffer.zig").LinearBuffer;
const handler = @import("../core/handler.zig");
const Connection = handler.Connection;
const castUserdata = @import("../util/helpers.zig").castUserdata;
const config = @import("../util/config.zig");
const CIPHERTEXT_BUFFER_SIZE = config.CIPHERTEXT_BUFFER_SIZE;

/// Initialize TLS on this connection. Called from onAccept when TLS is configured.
pub fn initTls(self: *Connection, tls_ctx: *TlsContext) !void {
    self.tls_state.tls_conn = try TlsConn.init(self.base_allocator, tls_ctx.ctx);
    self.tls_state.tls_conn.?.fixupExData();
    self.tls_state.ciphertext_buffer = try LinearBuffer.init(self.base_allocator, CIPHERTEXT_BUFFER_SIZE);
}

/// Drive the inbound TLS handshake state machine after feeding ciphertext.
pub fn handleTlsHandshake(self: *Connection, tc: *TlsConn) void {
    const hs_result = tc.handshake();

    // Send any handshake data the TLS engine produced
    if (tc.needsWrite()) {
        sendTlsData(self, hs_result == .complete);
        return;
    }

    switch (hs_result) {
        .complete => completeHandshake(self),
        .want_read => self.startRead(), // need more handshake data from client
        .failed => self.close(),
    }
}

/// Handshake done: set up kTLS, free TLS state, start plaintext reads.
fn completeHandshake(self: *Connection) void {
    const tc = &self.tls_state.tls_conn.?;
    tc.setupKtls(self.socket) catch |err| {
        // No userspace data-path fallback (#168): a fully-handshaked connection
        // we can't offload to kTLS must be closed. Log loudly — the common cause
        // (module absent) is refused at startup, so reaching here means an
        // unsupported cipher/version on a host that otherwise has kTLS.
        log.err().string("msg", "kTLS setup failed after handshake, closing connection").err(err).int("fd", self.socket).log();
        self.close();
        return;
    };
    // Free TLS state — kernel handles crypto now. Mark kTLS active so the
    // plaintext-socket recv path can recognize a control-record teardown
    // (close_notify → EIO → error.Unexpected) as a normal TLS close (#198).
    self.tls_state.ktls_active = true;
    tc.deinit(self.base_allocator);
    self.tls_state.tls_conn = null;
    if (self.tls_state.ciphertext_buffer) |*cb| {
        cb.deinit();
        self.tls_state.ciphertext_buffer = null;
    }
    self.startRead();
}

/// Send TLS handshake/ciphertext data over the wire.
/// Drains all pending data from wbio into encrypt_buf and submits a send.
fn sendTlsData(self: *Connection, handshake_complete: bool) void {
    const tc = &self.tls_state.tls_conn.?;
    const total = tc.drainAll();
    if (total == 0) {
        if (handshake_complete) {
            completeHandshake(self);
        } else {
            self.close();
        }
        return;
    }

    self.tls_state.tls_handshake_complete = handshake_complete;

    self.write_completion = .{
        .op = .{
            .send = .{
                .fd = self.socket,
                .buffer = .{ .slice = tc.encrypt_buf[0..total] },
            },
        },
        .userdata = self,
        .callback = onTlsHandshakeWrite,
    };
    self.pending_io_ops += 1;
    self.loop.add(&self.write_completion);
}

/// xev callback for inbound TLS handshake write completion.
pub fn onTlsHandshakeWrite(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;

    const handshake_complete = self.tls_state.tls_handshake_complete;
    self.tls_state.tls_handshake_complete = false;

    if (handshake_complete) {
        // Handshake finished, check if there's more data to send (e.g. TLS 1.2 multi-flight)
        const tc = &self.tls_state.tls_conn.?;
        if (tc.needsWrite()) {
            sendTlsData(self, true);
            return .disarm;
        }
        completeHandshake(self);
    } else {
        // Need more handshake data from client
        self.startRead();
    }
    return .disarm;
}

// Tests for conn_tls require a live TlsContext (OpenSSL) and a
// Connection with xev.Loop, so unit tests are not feasible here. TLS
// handshake is covered by integration tests against the running server.
