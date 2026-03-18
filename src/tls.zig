const std = @import("std");
const log = @import("log.zig");
const config = @import("config.zig");
const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/hmac.h");
    @cInclude("openssl/evp.h");
    @cInclude("linux/tls.h");
    @cInclude("netinet/tcp.h");
});

const ENCRYPT_BUF_SIZE = config.TLS_ENCRYPT_BUF_SIZE;
pub const TLS_RECORD_MAX_SIZE = config.TLS_RECORD_MAX_SIZE;

// kTLS setsockopt constants
const SOL_TLS: i32 = 282;

// SSL_OP_NO_TICKET = SSL_OP_BIT(14) — Zig's C translator can't evaluate the macro.
const SSL_OP_NO_TICKET: c_ulong = 1 << 14;

/// Decode errno from a raw Linux syscall return value.
/// Raw syscalls return -errno as usize on failure. std.posix.errno() doesn't
/// reliably decode all values (e.g. small negative values can slip through),
/// so we decode manually: negate the signed value to get the errno integer.
fn syscallErrno(rc: usize) std.posix.E {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed > -4096) {
        return @enumFromInt(@as(u16, @intCast(-signed)));
    }
    return .SUCCESS;
}

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

        // Disable session tickets for kTLS compatibility.
        // TLS 1.3 NewSessionTicket records are sent post-handshake under
        // server_traffic_secret_0, incrementing the TX sequence counter.
        // kTLS is set up with rec_seq=0, so any tickets sent by OpenSSL
        // before the kernel takes over cause a sequence mismatch → bad MAC.
        // This is the same approach nginx uses for kTLS.
        _ = c.SSL_CTX_set_num_tickets(ctx, 0);

        // Enable keylog callback for kTLS key extraction
        c.SSL_CTX_set_keylog_callback(ctx, keylogCallback);

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
            // Insecure mode: skip certificate verification (man-in-the-middle risk)
            log.warn().string("msg", "TLS certificate verification disabled (SSL_VERIFY_NONE)").log();
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

        // Disable TLS 1.2 session tickets — outbound connections are short-lived
        // and don't benefit from session resumption. For TLS 1.3, this option has
        // no effect (ticket emission is server-controlled); TLS 1.3 outbound
        // connections use full userspace TLS instead of kTLS to handle
        // post-handshake NewSessionTicket records gracefully.
        _ = c.SSL_CTX_set_options(ctx, SSL_OP_NO_TICKET);

        // Enable keylog callback for kTLS key extraction
        c.SSL_CTX_set_keylog_callback(ctx, keylogCallback);

        return ClientTlsContext{ .ctx = ctx };
    }

    pub fn deinit(self: *ClientTlsContext) void {
        c.SSL_CTX_free(self.ctx);
    }
};

// ============================================================================
// kTLS key extraction — keylog callback + secret storage
// ============================================================================

/// TLS 1.3 traffic secrets captured during handshake via keylog callback.
pub const KtlsSecrets = struct {
    client_secret: [48]u8 = .{0} ** 48,
    server_secret: [48]u8 = .{0} ** 48,
    secret_len: u8 = 0, // 0 = not captured, 32 = SHA-256, 48 = SHA-384
};

/// SSL_CTX keylog callback — captures TLS 1.3 traffic secrets into per-TlsConn storage.
/// For TLS 1.2, keys are extracted directly from the SSL session after handshake.
fn keylogCallback(ssl: ?*const c.SSL, line: [*c]const u8) callconv(.c) void {
    if (ssl == null or line == null) return;
    const ptr = c.SSL_get_ex_data(@constCast(ssl), 0) orelse return;
    const self: *TlsConn = @ptrCast(@alignCast(ptr));
    const line_str = std.mem.span(line);

    if (std.mem.startsWith(u8, line_str, "CLIENT_TRAFFIC_SECRET_0 ")) {
        parseKeylogSecret(line_str["CLIENT_TRAFFIC_SECRET_0 ".len..], &self.ktls_secrets.client_secret, &self.ktls_secrets.secret_len);
    } else if (std.mem.startsWith(u8, line_str, "SERVER_TRAFFIC_SECRET_0 ")) {
        parseKeylogSecret(line_str["SERVER_TRAFFIC_SECRET_0 ".len..], &self.ktls_secrets.server_secret, &self.ktls_secrets.secret_len);
    }
}

/// Parse "<client_random_hex> <secret_hex>" and store the secret bytes.
fn parseKeylogSecret(rest: []const u8, out: *[48]u8, len: *u8) void {
    // client_random is 32 bytes = 64 hex chars, then a space, then the secret
    if (rest.len < 65) return;
    const secret_hex = rest[65..];
    const n = secret_hex.len / 2;
    if (n == 0 or n > 48) return;
    for (0..n) |i| {
        out[i] = (hexVal(secret_hex[i * 2]) orelse return) << 4 | (hexVal(secret_hex[i * 2 + 1]) orelse return);
    }
    len.* = @intCast(n);
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

// ============================================================================
// kTLS cipher parameters
// ============================================================================

const CipherKind = enum { aes_gcm_128, aes_gcm_256, chacha20_poly1305 };

const CipherParams = struct {
    kind: CipherKind,
    key_size: u8,
    iv_size: u8, // full nonce length (12 for all supported ciphers)
    salt_size: u8, // 4 for AES-GCM, 0 for ChaCha20
    evp_md: *const c.EVP_MD,
};

/// Map SSL cipher suite ID to kTLS cipher parameters.
fn getCipherParams(cipher_id: u32) ?CipherParams {
    const sha256 = c.EVP_sha256() orelse return null;
    const sha384 = c.EVP_sha384() orelse return null;
    return switch (cipher_id & 0xFFFF) {
        // TLS 1.3
        0x1301 => .{ .kind = .aes_gcm_128, .key_size = 16, .iv_size = 12, .salt_size = 4, .evp_md = sha256 },
        0x1302 => .{ .kind = .aes_gcm_256, .key_size = 32, .iv_size = 12, .salt_size = 4, .evp_md = sha384 },
        0x1303 => .{ .kind = .chacha20_poly1305, .key_size = 32, .iv_size = 12, .salt_size = 0, .evp_md = sha256 },
        // TLS 1.2 ECDHE-RSA / ECDHE-ECDSA AES-128-GCM
        0xC02F, 0xC02B => .{ .kind = .aes_gcm_128, .key_size = 16, .iv_size = 12, .salt_size = 4, .evp_md = sha256 },
        // TLS 1.2 ECDHE-RSA / ECDHE-ECDSA AES-256-GCM
        0xC030, 0xC02C => .{ .kind = .aes_gcm_256, .key_size = 32, .iv_size = 12, .salt_size = 4, .evp_md = sha384 },
        // TLS 1.2 ECDHE-RSA / ECDHE-ECDSA ChaCha20-Poly1305
        0xCCA8, 0xCCA9 => .{ .kind = .chacha20_poly1305, .key_size = 32, .iv_size = 12, .salt_size = 0, .evp_md = sha256 },
        else => null,
    };
}

// ============================================================================
// HKDF / PRF key derivation
// ============================================================================

/// HKDF-Expand-Label for TLS 1.3 (RFC 8446 §7.1).
/// Derives key or IV from a traffic secret.
fn hkdfExpandLabel(
    evp_md: *const c.EVP_MD,
    secret: []const u8,
    comptime label: []const u8,
    out: []u8,
) !void {
    const full_label = "tls13 " ++ label;
    // HkdfLabel: length(2) + label_len(1) + label + context_len(1)
    const info_len = 2 + 1 + full_label.len + 1;
    var info: [info_len]u8 = undefined;
    info[0] = @intCast((out.len >> 8) & 0xFF);
    info[1] = @intCast(out.len & 0xFF);
    info[2] = @intCast(full_label.len);
    @memcpy(info[3 .. 3 + full_label.len], full_label);
    info[3 + full_label.len] = 0; // empty context

    // HKDF-Expand with N=1 (out.len <= hash_len): T(1) = HMAC(secret, info || 0x01)
    var hmac_in: [info_len + 1]u8 = undefined;
    @memcpy(hmac_in[0..info_len], &info);
    hmac_in[info_len] = 0x01;

    var hmac_out: [48]u8 = undefined; // max SHA-384
    var hmac_len: c_uint = 0;
    const result = c.HMAC(
        evp_md,
        secret.ptr,
        @intCast(secret.len),
        &hmac_in,
        hmac_in.len,
        &hmac_out,
        &hmac_len,
    );
    if (result == null) return error.HkdfFailed;
    if (hmac_len < out.len) return error.HkdfFailed;
    @memcpy(out, hmac_out[0..out.len]);
}

/// TLS 1.2 PRF (RFC 5246 §5) — P_SHA256 based key expansion.
/// Derives key_block from master secret + server_random + client_random.
fn tls12Prf(
    evp_md: *const c.EVP_MD,
    secret: []const u8,
    label: []const u8,
    seed: []const u8,
    out: []u8,
) !void {
    // A(0) = label + seed
    // A(i) = HMAC(secret, A(i-1))
    // P_hash = HMAC(secret, A(1) + label + seed) || HMAC(secret, A(2) + label + seed) || ...
    const hash_len: usize = @intCast(c.EVP_MD_size(evp_md));
    var a_buf: [48]u8 = undefined; // A(i), max SHA-384

    // Compute A(1) = HMAC(secret, label + seed)
    {
        const ctx = c.HMAC_CTX_new() orelse return error.PrfFailed;
        defer c.HMAC_CTX_free(ctx);
        if (c.HMAC_Init_ex(ctx, secret.ptr, @intCast(secret.len), evp_md, null) != 1) return error.PrfFailed;
        if (c.HMAC_Update(ctx, label.ptr, label.len) != 1) return error.PrfFailed;
        if (c.HMAC_Update(ctx, seed.ptr, seed.len) != 1) return error.PrfFailed;
        var a_len: c_uint = 0;
        if (c.HMAC_Final(ctx, &a_buf, &a_len) != 1) return error.PrfFailed;
    }

    var written: usize = 0;
    while (written < out.len) {
        // P_hash block = HMAC(secret, A(i) + label + seed)
        var p_buf: [48]u8 = undefined;
        {
            const ctx = c.HMAC_CTX_new() orelse return error.PrfFailed;
            defer c.HMAC_CTX_free(ctx);
            if (c.HMAC_Init_ex(ctx, secret.ptr, @intCast(secret.len), evp_md, null) != 1) return error.PrfFailed;
            if (c.HMAC_Update(ctx, &a_buf, hash_len) != 1) return error.PrfFailed;
            if (c.HMAC_Update(ctx, label.ptr, label.len) != 1) return error.PrfFailed;
            if (c.HMAC_Update(ctx, seed.ptr, seed.len) != 1) return error.PrfFailed;
            var p_len: c_uint = 0;
            if (c.HMAC_Final(ctx, &p_buf, &p_len) != 1) return error.PrfFailed;
        }

        const chunk = @min(hash_len, out.len - written);
        @memcpy(out[written .. written + chunk], p_buf[0..chunk]);
        written += chunk;

        if (written >= out.len) break;

        // A(i+1) = HMAC(secret, A(i))
        var new_a: [48]u8 = undefined;
        var new_a_len: c_uint = 0;
        const r = c.HMAC(evp_md, secret.ptr, @intCast(secret.len), &a_buf, hash_len, &new_a, &new_a_len);
        if (r == null) return error.PrfFailed;
        a_buf = new_a;
    }
}

// ============================================================================
// TlsConn — per-connection TLS state (handshake only after kTLS setup)
// ============================================================================

/// Unified per-connection TLS state (server or client mode).
/// After handshake, setupKtls() transfers keys to the kernel and this struct is freed.
pub const TlsConn = struct {
    ssl: *c.SSL,
    // rbio/wbio ownership is transferred to SSL via SSL_set_bio.
    // SSL_free frees both — never call BIO_free on these.
    rbio: *c.BIO,
    wbio: *c.BIO,
    state: State,
    encrypt_buf: []u8,
    mode: Mode,
    ktls_secrets: KtlsSecrets = .{},

    pub const Mode = enum { server, client };
    const State = enum { handshaking, established };

    pub const HandshakeResult = enum { complete, want_read, failed };

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

    /// Re-register self-pointer in SSL ex_data after the TlsConn has been
    /// moved (e.g. copied to a heap-allocated *TlsConn via allocator.create).
    /// Must be called whenever the address of TlsConn changes.
    pub fn fixupExData(self: *TlsConn) void {
        _ = c.SSL_set_ex_data(self.ssl, 0, self);
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
    /// Used for handshake data where encrypt_buf is sufficient.
    pub fn drainAll(self: *TlsConn) usize {
        var total: usize = 0;
        while (self.needsWrite()) {
            const n = self.drainCiphertext(self.encrypt_buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
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
                log.err().string("msg", "outbound tls certificate verify failed").int("code", verify_result).log();
            }
            var errbuf: [256]u8 = undefined;
            while (true) {
                const e = c.ERR_get_error();
                if (e == 0) break;
                c.ERR_error_string_n(e, &errbuf, errbuf.len);
                log.err().string("msg", "outbound tls error").string("detail", std.mem.sliceTo(&errbuf, 0)).log();
            }
        }
        return .failed;
    }

    pub fn isEstablished(self: *TlsConn) bool {
        return self.state == .established;
    }

    pub fn needsWrite(self: *TlsConn) bool {
        return c.BIO_ctrl_pending(self.wbio) > 0;
    }

    // ========================================================================
    // Userspace encrypt/decrypt — fallback when kTLS is unavailable
    // ========================================================================

    /// Encrypt plaintext via SSL_write and return the ciphertext slice
    /// (points into encrypt_buf). Returns null on SSL error.
    pub fn sslWrite(self: *TlsConn, plaintext: []const u8) ?[]const u8 {
        const ret = c.SSL_write(self.ssl, plaintext.ptr, @intCast(plaintext.len));
        if (ret <= 0) return null;
        const total = self.drainAll();
        if (total == 0) return null;
        return self.encrypt_buf[0..total];
    }

    /// Decrypt ciphertext: feed it into the read BIO, then SSL_read plaintext
    /// into the provided buffer. Returns the plaintext slice, or null on error.
    pub fn sslRead(self: *TlsConn, ciphertext: []const u8, out: []u8) ?[]const u8 {
        self.feedCiphertext(ciphertext);
        const ret = c.SSL_read(self.ssl, out.ptr, @intCast(out.len));
        if (ret <= 0) return null;
        return out[0..@intCast(ret)];
    }

    // ========================================================================
    // kTLS setup — transfer keys to kernel after handshake
    // ========================================================================

    /// After handshake completes, extract negotiated keys and configure kTLS.
    /// On success, the kernel handles all encrypt/decrypt — TlsConn can be freed.
    /// On failure, returns error (caller should keep TlsConn for userspace TLS).
    pub fn setupKtls(self: *TlsConn, fd: std.posix.socket_t) !void {
        const ssl_version = c.SSL_version(self.ssl);

        // TLS 1.3 client: skip kTLS entirely. Remote servers send NewSessionTicket
        // post-handshake records that kTLS RX can't deliver via plain recv() — the
        // kernel returns EIO for non-application-data records. SSL_OP_NO_TICKET only
        // affects TLS 1.2; for 1.3, ticket emission is server-controlled. Draining
        // via SSL_read before kTLS setup is racy (tickets may arrive later).
        // Full userspace TLS handles post-handshake messages transparently.
        if (ssl_version == c.TLS1_3_VERSION and self.mode == .client) {
            return error.KtlsUnsupportedVersion;
        }

        const cipher = c.SSL_get_current_cipher(self.ssl) orelse return error.KtlsNoCipher;
        const cipher_id = c.SSL_CIPHER_get_id(cipher);
        const params = getCipherParams(cipher_id) orelse {
            log.warn().string("msg", "ktls unsupported cipher").fmt("cipher", "0x{x}", .{cipher_id & 0xFFFF}).log();
            return error.KtlsUnsupportedCipher;
        };

        // Derive TX and RX keys
        var tx_key: [32]u8 = .{0} ** 32;
        var tx_iv: [12]u8 = .{0} ** 12;
        var rx_key: [32]u8 = .{0} ** 32;
        var rx_iv: [12]u8 = .{0} ** 12;

        if (ssl_version == c.TLS1_3_VERSION) {
            try self.deriveTls13Keys(params, &tx_key, &tx_iv, &rx_key, &rx_iv);
        } else if (ssl_version == c.TLS1_2_VERSION) {
            try self.deriveTls12Keys(params, &tx_key, &tx_iv, &rx_key, &rx_iv);
        } else {
            return error.KtlsUnsupportedVersion;
        }

        const tls_version: u16 = @intCast(ssl_version);

        // Record sequence numbers for kTLS.
        // TX: always 0 — we haven't sent any application records yet.
        // RX: TLS 1.2 Finished was at seq=0 under application keys → start at 1.
        //     TLS 1.3 server: set_num_tickets(0) prevents post-handshake sends → 0.
        //     TLS 1.3 client: excluded above (full userspace TLS).
        var tx_rec_seq = [_]u8{0} ** 8;
        var rx_rec_seq = [_]u8{0} ** 8;
        if (ssl_version == c.TLS1_2_VERSION) {
            tx_rec_seq[7] = 1;
            rx_rec_seq[7] = 1;
        }

        // Enable TLS ULP on the socket.
        // Use raw syscall because std.posix.setsockopt doesn't handle ENOENT
        // (returned when the tls kernel module isn't loaded), causing a noisy
        // unexpectedErrno stack dump even though we handle the error.
        // Check rc != 0 explicitly — errno() only detects negative values in
        // (-4096, 0), so a positive non-zero rc would slip through as SUCCESS.
        const ulp = [4]u8{ 't', 'l', 's', 0 };
        const rc = std.os.linux.setsockopt(fd, std.posix.IPPROTO.TCP, c.TCP_ULP, &ulp, ulp.len);
        if (rc != 0) {
            const e = syscallErrno(rc);
            if (e == .NOENT) {
                log.warn().string("msg", "ktls tls kernel module not loaded (ENOENT from TCP_ULP) — run 'modprobe tls'").log();
            } else {
                log.err().string("msg", "ktls TCP_ULP setsockopt failed").int("errno", @intFromEnum(e)).stringSafe("errname", @tagName(e)).int("fd", fd).log();
            }
            return error.KtlsSetupFailed;
        }

        // Set TX and RX crypto info
        switch (params.kind) {
            .aes_gcm_128 => {
                var tx_info = c.tls12_crypto_info_aes_gcm_128{
                    .info = .{ .version = tls_version, .cipher_type = c.TLS_CIPHER_AES_GCM_128 },
                    .iv = .{0} ** 8,
                    .key = undefined,
                    .salt = undefined,
                    .rec_seq = tx_rec_seq,
                };
                @memcpy(&tx_info.key, tx_key[0..16]);
                @memcpy(&tx_info.salt, tx_iv[0..4]);
                @memcpy(&tx_info.iv, tx_iv[4..12]);

                var rx_info = tx_info;
                rx_info.rec_seq = rx_rec_seq;
                @memcpy(&rx_info.key, rx_key[0..16]);
                @memcpy(&rx_info.salt, rx_iv[0..4]);
                @memcpy(&rx_info.iv, rx_iv[4..12]);

                try setsockoptTls(fd, c.TLS_TX, std.mem.asBytes(&tx_info));
                try setsockoptTls(fd, c.TLS_RX, std.mem.asBytes(&rx_info));
            },
            .aes_gcm_256 => {
                var tx_info = c.tls12_crypto_info_aes_gcm_256{
                    .info = .{ .version = tls_version, .cipher_type = c.TLS_CIPHER_AES_GCM_256 },
                    .iv = .{0} ** 8,
                    .key = undefined,
                    .salt = undefined,
                    .rec_seq = tx_rec_seq,
                };
                @memcpy(&tx_info.key, tx_key[0..32]);
                @memcpy(&tx_info.salt, tx_iv[0..4]);
                @memcpy(&tx_info.iv, tx_iv[4..12]);

                var rx_info = tx_info;
                rx_info.rec_seq = rx_rec_seq;
                @memcpy(&rx_info.key, rx_key[0..32]);
                @memcpy(&rx_info.salt, rx_iv[0..4]);
                @memcpy(&rx_info.iv, rx_iv[4..12]);

                try setsockoptTls(fd, c.TLS_TX, std.mem.asBytes(&tx_info));
                try setsockoptTls(fd, c.TLS_RX, std.mem.asBytes(&rx_info));
            },
            .chacha20_poly1305 => {
                var tx_info = c.tls12_crypto_info_chacha20_poly1305{
                    .info = .{ .version = tls_version, .cipher_type = c.TLS_CIPHER_CHACHA20_POLY1305 },
                    .iv = undefined,
                    .key = undefined,
                    .salt = .{},
                    .rec_seq = tx_rec_seq,
                };
                @memcpy(&tx_info.key, tx_key[0..32]);
                @memcpy(&tx_info.iv, tx_iv[0..12]);

                var rx_info = tx_info;
                rx_info.rec_seq = rx_rec_seq;
                @memcpy(&rx_info.key, rx_key[0..32]);
                @memcpy(&rx_info.iv, rx_iv[0..12]);

                try setsockoptTls(fd, c.TLS_TX, std.mem.asBytes(&tx_info));
                try setsockoptTls(fd, c.TLS_RX, std.mem.asBytes(&rx_info));
            },
        }

        // Scrub keys from memory
        @memset(&tx_key, 0);
        @memset(&tx_iv, 0);
        @memset(&rx_key, 0);
        @memset(&rx_iv, 0);
        @memset(&self.ktls_secrets.client_secret, 0);
        @memset(&self.ktls_secrets.server_secret, 0);

        log.info().string("msg", "ktls enabled").int("fd", fd).fmt("cipher", "0x{x}", .{cipher_id & 0xFFFF}).fmt("version", "0x{x}", .{tls_version}).log();
    }

    fn setsockoptTls(fd: std.posix.socket_t, direction: u32, info_bytes: []const u8) !void {
        // Use raw syscall with explicit rc != 0 check, matching the TCP_ULP path.
        // std.posix.setsockopt uses errno() which misses positive non-zero rc values.
        const rc = std.os.linux.setsockopt(
            fd,
            SOL_TLS,
            direction,
            @ptrCast(info_bytes.ptr),
            @intCast(info_bytes.len),
        );
        if (rc != 0) {
            const e = syscallErrno(rc);
            log.err().string("msg", "ktls setsockopt SOL_TLS failed").int("dir", direction).int("errno", @intFromEnum(e)).stringSafe("errname", @tagName(e)).int("fd", fd).log();
            return error.KtlsSetupFailed;
        }
    }

    /// Derive TLS 1.3 record keys from traffic secrets captured by keylog callback.
    fn deriveTls13Keys(
        self: *TlsConn,
        params: CipherParams,
        tx_key: *[32]u8,
        tx_iv: *[12]u8,
        rx_key: *[32]u8,
        rx_iv: *[12]u8,
    ) !void {
        if (self.ktls_secrets.secret_len == 0) return error.KtlsNoSecrets;

        // TX = sending direction: server sends with server_secret, client with client_secret
        const tx_secret = if (self.mode == .server)
            self.ktls_secrets.server_secret[0..self.ktls_secrets.secret_len]
        else
            self.ktls_secrets.client_secret[0..self.ktls_secrets.secret_len];

        const rx_secret = if (self.mode == .server)
            self.ktls_secrets.client_secret[0..self.ktls_secrets.secret_len]
        else
            self.ktls_secrets.server_secret[0..self.ktls_secrets.secret_len];

        try hkdfExpandLabel(params.evp_md, tx_secret, "key", tx_key[0..params.key_size]);
        try hkdfExpandLabel(params.evp_md, tx_secret, "iv", tx_iv);
        try hkdfExpandLabel(params.evp_md, rx_secret, "key", rx_key[0..params.key_size]);
        try hkdfExpandLabel(params.evp_md, rx_secret, "iv", rx_iv);
    }

    /// Derive TLS 1.2 record keys from master secret + randoms via PRF.
    fn deriveTls12Keys(
        self: *TlsConn,
        params: CipherParams,
        tx_key: *[32]u8,
        tx_iv: *[12]u8,
        rx_key: *[32]u8,
        rx_iv: *[12]u8,
    ) !void {
        const session = c.SSL_get_session(self.ssl) orelse return error.KtlsNoSession;

        // Extract master secret
        var master_secret: [48]u8 = undefined;
        const ms_len = c.SSL_SESSION_get_master_key(session, &master_secret, 48);
        if (ms_len == 0) return error.KtlsNoMasterKey;

        // Extract client and server randoms
        var client_random: [32]u8 = undefined;
        var server_random: [32]u8 = undefined;
        _ = c.SSL_get_client_random(self.ssl, &client_random, 32);
        _ = c.SSL_get_server_random(self.ssl, &server_random, 32);

        // PRF seed = server_random + client_random (for key expansion)
        var seed: [64]u8 = undefined;
        @memcpy(seed[0..32], &server_random);
        @memcpy(seed[32..64], &client_random);

        // key_block = PRF(master_secret, "key expansion", seed)
        // Layout: client_write_key | server_write_key | client_write_iv | server_write_iv
        const fixed_iv_len: usize = params.salt_size; // 4 for AES-GCM, 0 for ChaCha20
        const iv_len: usize = if (params.salt_size == 0) 12 else params.salt_size; // ChaCha20 gets full 12-byte IV
        const key_block_len = @as(usize, params.key_size) * 2 + iv_len * 2;
        var key_block: [128]u8 = undefined; // max needed
        try tls12Prf(params.evp_md, master_secret[0..ms_len], "key expansion", &seed, key_block[0..key_block_len]);

        // Parse key block
        var off: usize = 0;
        const client_key = key_block[off .. off + params.key_size];
        off += params.key_size;
        const server_key = key_block[off .. off + params.key_size];
        off += params.key_size;
        const client_iv_block = key_block[off .. off + iv_len];
        off += iv_len;
        const server_iv_block = key_block[off .. off + iv_len];

        // Assign TX/RX based on mode
        if (self.mode == .server) {
            @memcpy(tx_key[0..params.key_size], server_key);
            @memcpy(rx_key[0..params.key_size], client_key);
            if (fixed_iv_len > 0) {
                // AES-GCM: salt = fixed_iv (4 bytes), iv = zeros (kernel manages explicit nonce)
                @memcpy(tx_iv[0..fixed_iv_len], server_iv_block[0..fixed_iv_len]);
                @memcpy(rx_iv[0..fixed_iv_len], client_iv_block[0..fixed_iv_len]);
            } else {
                // ChaCha20: full 12-byte IV
                @memcpy(tx_iv, server_iv_block[0..12]);
                @memcpy(rx_iv, client_iv_block[0..12]);
            }
        } else {
            @memcpy(tx_key[0..params.key_size], client_key);
            @memcpy(rx_key[0..params.key_size], server_key);
            if (fixed_iv_len > 0) {
                @memcpy(tx_iv[0..fixed_iv_len], client_iv_block[0..fixed_iv_len]);
                @memcpy(rx_iv[0..fixed_iv_len], server_iv_block[0..fixed_iv_len]);
            } else {
                @memcpy(tx_iv, client_iv_block[0..12]);
                @memcpy(rx_iv, server_iv_block[0..12]);
            }
        }

        // Scrub
        @memset(&master_secret, 0);
        @memset(&key_block, 0);
    }
};

/// Free a heap-allocated TlsConn (deinit + destroy). Used by handler cleanup, etc.
pub fn freeTlsConn(allocator: std.mem.Allocator, tc: *TlsConn) void {
    tc.deinit(allocator);
    allocator.destroy(tc);
}

/// Per-worker TLS manager — owns the client TLS contexts for outbound handshakes.
/// After kTLS setup, TlsConn is freed — no fd-to-TlsConn mapping needed.
pub const TlsManager = struct {
    allocator: std.mem.Allocator,
    client_tls_ctx: ClientTlsContext,
    insecure_tls_ctx: ClientTlsContext,
    custom_tls_ctx: ?ClientTlsContext,

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
                log.err().string("msg", "custom TLS context init failed (CASS_TLS_*)").err(err).log();
                break :blk null;
            };
            log.info().string("msg", "custom mTLS context loaded from CASS_TLS_CA/CERT/KEY").log();
            break :blk ctx;
        };

        return TlsManager{
            .allocator = allocator,
            .client_tls_ctx = client_tls_ctx,
            .insecure_tls_ctx = insecure_tls_ctx,
            .custom_tls_ctx = custom_tls_ctx,
        };
    }

    pub fn deinit(self: *TlsManager) void {
        self.client_tls_ctx.deinit();
        self.insecure_tls_ctx.deinit();
        if (self.custom_tls_ctx) |*ctx| ctx.deinit();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "hexVal decodes hex characters" {
    try std.testing.expectEqual(@as(?u8, 0), hexVal('0'));
    try std.testing.expectEqual(@as(?u8, 9), hexVal('9'));
    try std.testing.expectEqual(@as(?u8, 10), hexVal('a'));
    try std.testing.expectEqual(@as(?u8, 15), hexVal('f'));
    try std.testing.expectEqual(@as(?u8, 10), hexVal('A'));
    try std.testing.expectEqual(@as(?u8, 15), hexVal('F'));
    try std.testing.expectEqual(@as(?u8, null), hexVal('g'));
    try std.testing.expectEqual(@as(?u8, null), hexVal(' '));
}

test "parseKeylogSecret parses valid TLS 1.3 keylog line" {
    // 64 hex chars (client_random) + space + 64 hex chars (32-byte secret)
    const client_random_hex = "a" ** 64;
    const secret_hex = "0102030405060708091011121314151617181920212223242526272829303132";
    const rest = client_random_hex ++ " " ++ secret_hex;

    var out: [48]u8 = .{0} ** 48;
    var len: u8 = 0;
    parseKeylogSecret(rest, &out, &len);

    try std.testing.expectEqual(@as(u8, 32), len);
    try std.testing.expectEqual(@as(u8, 0x01), out[0]);
    try std.testing.expectEqual(@as(u8, 0x02), out[1]);
}

test "parseKeylogSecret rejects short input" {
    var out: [48]u8 = .{0} ** 48;
    var len: u8 = 0;
    parseKeylogSecret("tooshort", &out, &len);
    try std.testing.expectEqual(@as(u8, 0), len);
}

test "getCipherParams returns params for known ciphers" {
    // TLS 1.3 AES-128-GCM
    const p1 = getCipherParams(0x1301);
    try std.testing.expect(p1 != null);
    try std.testing.expectEqual(CipherKind.aes_gcm_128, p1.?.kind);
    try std.testing.expectEqual(@as(u8, 16), p1.?.key_size);

    // TLS 1.3 AES-256-GCM
    const p2 = getCipherParams(0x1302);
    try std.testing.expect(p2 != null);
    try std.testing.expectEqual(CipherKind.aes_gcm_256, p2.?.kind);
    try std.testing.expectEqual(@as(u8, 32), p2.?.key_size);

    // TLS 1.3 ChaCha20
    const p3 = getCipherParams(0x1303);
    try std.testing.expect(p3 != null);
    try std.testing.expectEqual(CipherKind.chacha20_poly1305, p3.?.kind);
    try std.testing.expectEqual(@as(u8, 0), p3.?.salt_size);

    // TLS 1.2 ECDHE-RSA-AES128-GCM
    const p4 = getCipherParams(0xC02F);
    try std.testing.expect(p4 != null);
    try std.testing.expectEqual(CipherKind.aes_gcm_128, p4.?.kind);

    // Unknown cipher
    try std.testing.expect(getCipherParams(0xFFFF) == null);
}
