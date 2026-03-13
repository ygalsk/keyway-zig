const std = @import("std");
const config = @import("config.zig");
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/bio.h");
});

const ENCRYPT_BUF_SIZE = config.TLS_ENCRYPT_BUF_SIZE;
pub const TLS_RECORD_MAX_SIZE = config.TLS_RECORD_MAX_SIZE;

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

/// Options for creating a client TLS context.
pub const ClientTlsOpts = struct {
    verify: bool = true,
    ca_path: ?[*:0]const u8 = null, // custom CA cert (e.g., Astra SCB ca.crt)
    cert_path: ?[*:0]const u8 = null, // client certificate for mTLS
    key_path: ?[*:0]const u8 = null, // client private key for mTLS
};

/// Per-worker client TLS context for outbound connections.
/// One per worker — system CA store for verification, or SSL_VERIFY_NONE for insecure mode.
/// Supports mTLS via optional client certificate + key.
pub const ClientTlsContext = struct {
    ctx: *c.SSL_CTX,

    pub fn init(opts: ClientTlsOpts) !ClientTlsContext {
        const method = c.TLS_client_method() orelse return error.TlsMethodFailed;
        const ctx = c.SSL_CTX_new(method) orelse return error.SslCtxNewFailed;
        errdefer c.SSL_CTX_free(ctx);

        // Minimum TLS 1.2
        if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) {
            return error.SetMinProtoFailed;
        }

        if (opts.ca_path) |ca| {
            // Custom CA (e.g., Astra Secure Connect Bundle)
            if (c.SSL_CTX_load_verify_locations(ctx, ca, null) != 1) {
                return error.LoadCaFailed;
            }
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
        } else if (opts.verify) {
            // Load system CA store
            if (c.SSL_CTX_load_verify_locations(ctx, "/etc/pki/tls/certs/ca-bundle.crt", "/etc/pki/tls/certs") != 1) {
                if (c.SSL_CTX_load_verify_locations(ctx, "/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/certs") != 1) {
                    _ = c.SSL_CTX_set_default_verify_paths(ctx);
                }
            }
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);
        } else {
            c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_NONE, null);
        }

        // Client certificate for mTLS
        if (opts.cert_path) |cert| {
            if (c.SSL_CTX_use_certificate_chain_file(ctx, cert) != 1) {
                return error.LoadClientCertFailed;
            }
        }
        if (opts.key_path) |key| {
            if (c.SSL_CTX_use_PrivateKey_file(ctx, key, c.SSL_FILETYPE_PEM) != 1) {
                return error.LoadClientKeyFailed;
            }
        }
        // Verify key matches cert if both provided
        if (opts.cert_path != null and opts.key_path != null) {
            if (c.SSL_CTX_check_private_key(ctx) != 1) {
                return error.KeyCertMismatch;
            }
        }

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
    pub const DecryptError = struct {
        ssl_error: c_int,
        msg: [256]u8 = undefined,
        msg_len: usize = 0,
    };
    pub const DecryptResult = union(enum) { data: usize, want_read, zero_return, err: DecryptError };

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
        const ssl_err = c.SSL_get_error(self.ssl, ret);
        if (ssl_err == c.SSL_ERROR_WANT_READ) return .want_read;
        if (ssl_err == c.SSL_ERROR_ZERO_RETURN) {
            std.log.info("tls decrypt: clean shutdown (SSL_ERROR_ZERO_RETURN)", .{});
            return .zero_return;
        }

        // Build error details for caller
        var de = DecryptError{ .ssl_error = ssl_err };

        // Log and capture the ERR queue
        var errbuf: [256]u8 = undefined;
        while (true) {
            const e = c.ERR_get_error();
            if (e == 0) break;
            c.ERR_error_string_n(e, &errbuf, errbuf.len);
            const msg = std.mem.sliceTo(&errbuf, 0);
            std.log.err("tls decrypt: SSL_ERROR={d} {s}", .{ ssl_err, msg });
            // Capture first error message for the caller
            if (de.msg_len == 0) {
                @memcpy(de.msg[0..msg.len], msg);
                de.msg_len = msg.len;
            }
        }
        if (de.msg_len == 0) {
            std.log.err("tls decrypt: SSL_ERROR={d} (no ERR queue details)", .{ssl_err});
        }

        return .{ .err = de };
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

/// Per-worker TLS manager — owns the client TLS contexts and fd-to-TlsConn mapping.
/// Extracted from LuaState to give TLS state a single, focused owner.
pub const TlsManager = struct {
    allocator: std.mem.Allocator,
    client_tls_ctx: ClientTlsContext,
    insecure_tls_ctx: ClientTlsContext,
    custom_tls_ctx: ?ClientTlsContext,
    tls_map: std.AutoHashMapUnmanaged(std.posix.socket_t, *TlsConn),

    pub fn init(allocator: std.mem.Allocator) !TlsManager {
        const client_tls_ctx = ClientTlsContext.init(.{ .verify = true }) catch return error.TlsInitFailed;
        const insecure_tls_ctx = ClientTlsContext.init(.{ .verify = false }) catch return error.TlsInitFailed;

        // Custom mTLS context from env vars (e.g., Astra Secure Connect Bundle)
        const custom_tls_ctx: ?ClientTlsContext = blk: {
            const ca = std.posix.getenv("CASS_TLS_CA") orelse break :blk null;
            const cert = std.posix.getenv("CASS_TLS_CERT") orelse break :blk null;
            const key = std.posix.getenv("CASS_TLS_KEY") orelse break :blk null;
            const ctx = ClientTlsContext.init(.{
                .verify = true,
                .ca_path = @ptrCast(ca.ptr),
                .cert_path = @ptrCast(cert.ptr),
                .key_path = @ptrCast(key.ptr),
            }) catch |err| {
                std.log.err("custom TLS context init failed (CASS_TLS_*): {}", .{err});
                break :blk null;
            };
            std.log.info("custom mTLS context loaded from CASS_TLS_CA/CERT/KEY", .{});
            break :blk ctx;
        };

        return TlsManager{
            .allocator = allocator,
            .client_tls_ctx = client_tls_ctx,
            .insecure_tls_ctx = insecure_tls_ctx,
            .custom_tls_ctx = custom_tls_ctx,
            .tls_map = .{},
        };
    }

    /// Ownership transfers to TlsManager.
    pub fn registerTls(self: *TlsManager, fd: std.posix.socket_t, tls_conn: *TlsConn) !void {
        try self.tls_map.put(self.allocator, fd, tls_conn);
    }

    /// Borrow — returns null for plain TCP.
    pub fn getTls(self: *TlsManager, fd: std.posix.socket_t) ?*TlsConn {
        return self.tls_map.get(fd);
    }

    /// Ownership transfers to caller. Used for pool transfer or manual cleanup.
    pub fn detachTls(self: *TlsManager, fd: std.posix.socket_t) ?*TlsConn {
        return if (self.tls_map.fetchRemove(fd)) |kv| kv.value else null;
    }

    /// Remove and free. Used on close paths.
    pub fn removeTls(self: *TlsManager, fd: std.posix.socket_t) void {
        if (self.tls_map.fetchRemove(fd)) |kv| {
            freeTlsConn(self.allocator, kv.value);
        }
    }

    pub fn deinit(self: *TlsManager) void {
        var tls_it = self.tls_map.iterator();
        while (tls_it.next()) |entry| {
            freeTlsConn(self.allocator, entry.value_ptr.*);
        }
        self.tls_map.deinit(self.allocator);
        self.client_tls_ctx.deinit();
        self.insecure_tls_ctx.deinit();
        if (self.custom_tls_ctx) |*ctx| ctx.deinit();
    }
};
