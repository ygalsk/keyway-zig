const std = @import("std");
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/bio.h");
});

const ENCRYPT_BUF_SIZE = 20 * 1024; // 20KB for draining wbio ciphertext (handshake, small sends)
pub const TLS_RECORD_MAX_SIZE = 16384; // Max TLS record plaintext (RFC 8449)

/// Per-worker TLS context wrapping SSL_CTX.
/// One per worker thread — shares config across all connections on that worker.
pub const TlsContext = struct {
    ctx: *c.SSL_CTX,

    pub fn init(cert_path: [*:0]const u8, key_path: [*:0]const u8) !TlsContext {
        const method = c.TLS_server_method() orelse return error.TlsMethodFailed;
        const ctx = c.SSL_CTX_new(method) orelse return error.SslCtxNewFailed;
        errdefer c.SSL_CTX_free(ctx);

        // Minimum TLS 1.2
        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) {
            return error.SetMinProtoFailed;
        }

        // TLS 1.2 cipher suites
        if (c.SSL_CTX_set_cipher_list(
            ctx,
            "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:" ++
                "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:" ++
                "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305",
        ) != 1) {
            return error.SetCipherListFailed;
        }

        // TLS 1.3 cipher suites
        if (c.SSL_CTX_set_ciphersuites(
            ctx,
            "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
        ) != 1) {
            return error.SetCiphersuitesFailed;
        }

        // Load certificate
        if (c.SSL_CTX_use_certificate_chain_file(ctx, cert_path) != 1) {
            return error.LoadCertFailed;
        }

        // Load private key
        if (c.SSL_CTX_use_PrivateKey_file(ctx, key_path, c.SSL_FILETYPE_PEM) != 1) {
            return error.LoadKeyFailed;
        }

        // Verify key matches cert
        if (c.SSL_CTX_check_private_key(ctx) != 1) {
            return error.KeyCertMismatch;
        }

        return TlsContext{ .ctx = ctx };
    }

    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

/// Per-worker client TLS context for outbound connections.
/// One per worker — no cert/key, just system CA store for verification.
pub const ClientTlsContext = struct {
    ctx: *c.SSL_CTX,

    pub fn init() !ClientTlsContext {
        const method = c.TLS_client_method() orelse return error.TlsMethodFailed;
        const ctx = c.SSL_CTX_new(method) orelse return error.SslCtxNewFailed;
        errdefer c.SSL_CTX_free(ctx);

        // Minimum TLS 1.2
        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) {
            return error.SetMinProtoFailed;
        }

        // Load system CA store
        if (c.SSL_CTX_load_verify_locations(ctx, "/etc/pki/tls/certs/ca-bundle.crt", "/etc/pki/tls/certs") != 1) {
            if (c.SSL_CTX_load_verify_locations(ctx, "/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/certs") != 1) {
                _ = c.SSL_CTX_set_default_verify_paths(ctx);
            }
        }

        // Enable server certificate verification
        c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);

        return ClientTlsContext{ .ctx = ctx };
    }

    pub fn deinit(self: *ClientTlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

/// Unified per-connection TLS state (server or client mode).
/// Decouples TLS record processing from async I/O — handler feeds/drains ciphertext,
/// TLS engine reads/writes plaintext.
pub const TlsConn = struct {
    ssl: *c.SSL,
    // rbio/wbio ownership is transferred to SSL via SSL_set_bio.
    // SSL_free frees both — never call BIO_free on these.
    rbio: *c.BIO,
    wbio: *c.BIO,
    state: State,
    encrypt_buf: []u8,
    mode: Mode,

    pub const Mode = enum { server, client };
    const State = enum { handshaking, established };

    pub const HandshakeResult = enum { complete, want_read, failed };
    pub const DecryptResult = union(enum) { data: usize, want_read, err };

    pub fn init(allocator: std.mem.Allocator, ssl_ctx: *c.SSL_CTX, mode: Mode) !TlsConn {
        const ssl = c.SSL_new(ssl_ctx) orelse return error.SslNewFailed;
        errdefer c.SSL_free(ssl);

        const rbio = c.BIO_new(c.BIO_s_mem()) orelse return error.BioNewFailed;
        // Note: if wbio alloc fails, rbio is NOT yet owned by SSL, so we must free it
        const wbio = c.BIO_new(c.BIO_s_mem()) orelse {
            _ = c.BIO_free(rbio);
            return error.BioNewFailed;
        };

        // Transfers ownership of both BIOs to SSL — SSL_free will free them
        c.SSL_set_bio(ssl, rbio, wbio);

        switch (mode) {
            .server => c.SSL_set_accept_state(ssl),
            .client => {
                c.SSL_set_connect_state(ssl);
                // Disable renegotiation for safety (SSL_OP_NO_RENEGOTIATION = 1 << 30)
                _ = c.SSL_set_options(ssl, @as(c_ulong, 1) << 30);
            },
        }

        const buf = try allocator.alloc(u8, ENCRYPT_BUF_SIZE);

        return TlsConn{
            .ssl = ssl,
            .rbio = rbio,
            .wbio = wbio,
            .state = .handshaking,
            .encrypt_buf = buf,
            .mode = mode,
        };
    }

    pub fn deinit(self: *TlsConn, allocator: std.mem.Allocator) void {
        allocator.free(self.encrypt_buf);
        c.SSL_free(self.ssl); // frees both BIOs
    }

    /// Set SNI hostname for the TLS handshake. Must be called before handshake().
    pub fn setSni(self: *TlsConn, hostname: [:0]const u8) void {
        // SSL_set_tlsext_host_name is a macro — use the underlying ctrl call
        _ = c.SSL_ctrl(self.ssl, c.SSL_CTRL_SET_TLSEXT_HOSTNAME, c.TLSEXT_NAMETYPE_host_name, @ptrCast(@constCast(hostname.ptr)));
        // Enable hostname verification
        _ = c.SSL_set1_host(self.ssl, hostname);
    }

    /// Feed received ciphertext into the TLS engine (BIO_write to rbio).
    pub fn feedCiphertext(self: *TlsConn, data: []const u8) void {
        _ = c.BIO_write(self.rbio, data.ptr, @intCast(data.len));
    }

    /// Drain pending ciphertext from the TLS engine (BIO_read from wbio).
    /// Returns number of bytes written to buf, or 0 if nothing pending.
    pub fn drainCiphertext(self: *TlsConn, buf: []u8) usize {
        const pending = c.BIO_ctrl_pending(self.wbio);
        if (pending == 0) return 0;
        const to_read: c_int = @intCast(@min(pending, buf.len));
        const n = c.BIO_read(self.wbio, buf.ptr, to_read);
        if (n <= 0) return 0;
        return @intCast(n);
    }

    /// Drain all pending ciphertext into encrypt_buf. Returns total bytes drained.
    /// Suitable for handshake data and small sends where encrypt_buf is sufficient.
    pub fn drainAll(self: *TlsConn) usize {
        var total: usize = 0;
        while (self.needsWrite()) {
            const n = self.drainCiphertext(self.encrypt_buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    /// Drain all pending ciphertext into a dynamically-allocated buffer.
    /// Use for response data that may exceed encrypt_buf capacity.
    pub fn drainAllAlloc(self: *TlsConn, allocator: std.mem.Allocator) ![]u8 {
        const pending = c.BIO_ctrl_pending(self.wbio);
        if (pending == 0) return &.{};
        const buf = try allocator.alloc(u8, pending);
        var total: usize = 0;
        while (self.needsWrite()) {
            const n = self.drainCiphertext(buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }

    /// Drive the TLS handshake state machine.
    pub fn handshake(self: *TlsConn) HandshakeResult {
        const ret = c.SSL_do_handshake(self.ssl);
        if (ret == 1) {
            self.state = .established;
            return .complete;
        }
        const err = c.SSL_get_error(self.ssl, ret);
        if (err == c.SSL_ERROR_WANT_READ or err == c.SSL_ERROR_WANT_WRITE) {
            return .want_read;
        }
        // Log errors in client mode for debugging outbound connections
        if (self.mode == .client) {
            const verify_result = c.SSL_get_verify_result(self.ssl);
            if (verify_result != 0) {
                std.log.err("outbound tls: certificate verify failed code={d}", .{verify_result});
            }
            var errbuf: [256]u8 = undefined;
            while (true) {
                const e = c.ERR_get_error();
                if (e == 0) break;
                c.ERR_error_string_n(e, &errbuf, errbuf.len);
                std.log.err("outbound tls: {s}", .{std.mem.sliceTo(&errbuf, 0)});
            }
        }
        return .failed;
    }

    /// Check if SSL has data available without a kernel read.
    /// Returns true if either:
    /// - SSL has already-decrypted plaintext buffered (SSL_pending)
    /// - The read BIO has unprocessed ciphertext from a previous feedCiphertext
    pub fn hasPending(self: *TlsConn) bool {
        return c.SSL_pending(self.ssl) > 0 or c.BIO_ctrl_pending(self.rbio) > 0;
    }

    /// Decrypt application data from the TLS engine.
    /// Caller must have fed ciphertext via feedCiphertext() first.
    pub fn decrypt(self: *TlsConn, out: []u8) DecryptResult {
        const ret = c.SSL_read(self.ssl, out.ptr, @intCast(out.len));
        if (ret > 0) return .{ .data = @intCast(ret) };
        const err = c.SSL_get_error(self.ssl, ret);
        if (err == c.SSL_ERROR_WANT_READ) return .want_read;
        return .err;
    }

    /// Encrypt plaintext for sending. After this call, drainCiphertext()/drainAll()/drainAllAlloc()
    /// to get the ciphertext that needs to be sent over the wire.
    pub fn encrypt(self: *TlsConn, plaintext: []const u8) !void {
        var written: usize = 0;
        while (written < plaintext.len) {
            const chunk: c_int = @intCast(@min(plaintext.len - written, TLS_RECORD_MAX_SIZE));
            const ret = c.SSL_write(self.ssl, plaintext[written..].ptr, chunk);
            if (ret <= 0) return error.SslWriteFailed;
            written += @intCast(ret);
        }
    }

    pub fn isEstablished(self: *TlsConn) bool {
        return self.state == .established;
    }

    pub fn needsWrite(self: *TlsConn) bool {
        return c.BIO_ctrl_pending(self.wbio) > 0;
    }
};

/// Free a heap-allocated TlsConn (deinit + destroy). Used by connection pool, handler cleanup, etc.
pub fn freeTlsConn(allocator: std.mem.Allocator, tc: *TlsConn) void {
    tc.deinit(allocator);
    allocator.destroy(tc);
}
