const std = @import("std");
const xev = @import("xev");
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;
const TlsContext = tls_mod.TlsContext;
const LinearBuffer = @import("buffer.zig").LinearBuffer;
const handler = @import("handler.zig");
const Connection = handler.Connection;
const castUserdata = @import("helpers.zig").castUserdata;
const config = @import("config.zig");
const error_response = @import("error_response.zig");

const CIPHERTEXT_BUFFER_SIZE = config.CIPHERTEXT_BUFFER_SIZE;

/// Initialize TLS on this connection. Called from onAccept when TLS is configured.
pub fn initTls(self: *Connection, tls_ctx: *TlsContext) !void {
    self.tls_state.tls_conn = try TlsConn.init(self.base_allocator, tls_ctx.ctx, .server);
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
        .complete => self.startRead(), // handshake done, read first HTTP data
        .want_read => self.startRead(), // need more handshake data from client
        .failed => self.close(),
    }
}

/// Decrypt application data from the TLS engine after handshake is established.
pub fn handleTlsDecrypt(self: *Connection, tc: *TlsConn) void {
    const out = self.read_buffer.writeSlice();
    if (out.len == 0) {
        self.send400BadRequest();
        return;
    }
    switch (tc.decrypt(out)) {
        .data => |n| {
            self.read_buffer.commitWrite(n);
            // Streaming body size enforcement for TLS connections
            if (self.state == .reading) {
                self.http_state.body_bytes_received += n;
                if (self.http_state.body_bytes_received > config.MAX_BODY_SIZE) {
                    error_response.sendErrorStatus(self, 413, "streaming body exceeds size limit");
                    return;
                }
            }
            self.sendResponse() catch |err| {
                std.log.err("[fd={d}] response dispatch failed err={}", .{ self.socket, err });
                self.close();
            };
        },
        .want_read => self.startRead(),
        .zero_return, .err => self.close(),
    }
}

/// Send TLS handshake/ciphertext data over the wire.
/// Drains all pending data from wbio into encrypt_buf and submits a send.
fn sendTlsData(self: *Connection, handshake_complete: bool) void {
    const tc = &self.tls_state.tls_conn.?;
    const total = tc.drainAll();
    if (total == 0) {
        if (handshake_complete) {
            self.startRead();
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
    _ = result.send catch {
        self.close();
        return .disarm;
    };

    const handshake_complete = self.tls_state.tls_handshake_complete;
    self.tls_state.tls_handshake_complete = false;

    if (handshake_complete) {
        // Handshake finished, check if there's more data to send (e.g. TLS 1.2 multi-flight)
        const tc = &self.tls_state.tls_conn.?;
        if (tc.needsWrite()) {
            sendTlsData(self, true);
            return .disarm;
        }
        // Ready for first HTTP request
        self.startRead();
    } else {
        // Need more handshake data from client
        self.startRead();
    }
    return .disarm;
}

// Tests for conn_tls require a live TlsContext (OpenSSL/BoringSSL) and a
// Connection with xev.Loop, so unit tests are not feasible here. TLS
// handshake and decrypt are covered by integration tests against the running
// server.
