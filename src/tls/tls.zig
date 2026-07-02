const std = @import("std");
const log = @import("../observability/log.zig");
const config = @import("../util/config.zig");
const helpers = @import("../util/helpers.zig");
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
    const n = secret_hex.len / 2; // ignore a trailing odd hex digit, as before
    if (n == 0 or n > 48) return;
    _ = std.fmt.hexToBytes(out[0..n], secret_hex[0 .. n * 2]) catch return;
    len.* = @intCast(n);
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

/// Per-connection TLS state (server mode only).
/// After handshake, setupKtls() transfers keys to the kernel and this struct is freed.
pub const TlsConn = struct {
    ssl: *c.SSL,
    // rbio/wbio ownership is transferred to SSL via SSL_set_bio.
    // SSL_free frees both — never call BIO_free on these.
    rbio: *c.BIO,
    wbio: *c.BIO,
    state: State,
    encrypt_buf: []u8,
    ktls_secrets: KtlsSecrets = .{},

    const State = enum { handshaking, established };

    pub const HandshakeResult = enum { complete, want_read, failed };

    pub fn init(allocator: std.mem.Allocator, ssl_ctx: *c.SSL_CTX) !TlsConn {
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
        c.SSL_set_accept_state(ssl);

        const buf = try allocator.alloc(u8, ENCRYPT_BUF_SIZE);

        return TlsConn{
            .ssl = ssl,
            .rbio = rbio,
            .wbio = wbio,
            .state = .handshaking,
            .encrypt_buf = buf,
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
        return .failed;
    }

    pub fn needsWrite(self: *TlsConn) bool {
        return c.BIO_ctrl_pending(self.wbio) > 0;
    }

    // ========================================================================
    // kTLS setup — transfer keys to kernel after handshake
    // ========================================================================

    /// After handshake completes, extract negotiated keys and configure kTLS.
    /// On success, the kernel handles all encrypt/decrypt — TlsConn can be freed.
    /// On failure, returns error (caller should keep TlsConn for userspace TLS).
    pub fn setupKtls(self: *TlsConn, fd: std.posix.socket_t) !void {
        const ssl_version = c.SSL_version(self.ssl);

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
        //     TLS 1.3: set_num_tickets(0) prevents post-handshake sends → 0.
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
            const e = helpers.syscallErrno(rc);
            if (e == .NOENT) {
                log.warn().string("msg", "ktls tls kernel module not loaded (ENOENT from TCP_ULP) — run 'modprobe tls'").log();
            } else {
                log.err().string("msg", "ktls TCP_ULP setsockopt failed").int("errno", @intFromEnum(e)).stringSafe("errname", @tagName(e)).int("fd", fd).log();
            }
            return error.KtlsSetupFailed;
        }

        // Set TX and RX crypto info. Each cipher has its own tls12_crypto_info_*
        // struct; the generic installer derives the key/salt/iv layout from the
        // struct's own field sizes, so the three arms differ only by type + id.
        switch (params.kind) {
            .aes_gcm_128 => try installKtlsCipher(
                c.tls12_crypto_info_aes_gcm_128,
                c.TLS_CIPHER_AES_GCM_128,
                fd,
                tls_version,
                &tx_key,
                &tx_iv,
                tx_rec_seq,
                &rx_key,
                &rx_iv,
                rx_rec_seq,
            ),
            .aes_gcm_256 => try installKtlsCipher(
                c.tls12_crypto_info_aes_gcm_256,
                c.TLS_CIPHER_AES_GCM_256,
                fd,
                tls_version,
                &tx_key,
                &tx_iv,
                tx_rec_seq,
                &rx_key,
                &rx_iv,
                rx_rec_seq,
            ),
            .chacha20_poly1305 => try installKtlsCipher(
                c.tls12_crypto_info_chacha20_poly1305,
                c.TLS_CIPHER_CHACHA20_POLY1305,
                fd,
                tls_version,
                &tx_key,
                &tx_iv,
                tx_rec_seq,
                &rx_key,
                &rx_iv,
                rx_rec_seq,
            ),
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

    /// Build the TX/RX `tls12_crypto_info_*` structs for one cipher and install
    /// them on the socket. `Info` selects the cipher struct; the key/salt/iv
    /// split is read from that struct's own field sizes — AES-GCM has a 4-byte
    /// salt + 8-byte explicit IV, ChaCha20 has no salt + a 12-byte IV.
    fn installKtlsCipher(
        comptime Info: type,
        comptime cipher_type: u16,
        fd: std.posix.socket_t,
        tls_version: u16,
        tx_key: []const u8,
        tx_iv: []const u8,
        tx_rec_seq: [8]u8,
        rx_key: []const u8,
        rx_iv: []const u8,
        rx_rec_seq: [8]u8,
    ) !void {
        var tx_info: Info = .{
            .info = .{ .version = tls_version, .cipher_type = cipher_type },
            .iv = undefined,
            .key = undefined,
            .salt = undefined,
            .rec_seq = tx_rec_seq,
        };
        fillKtlsKeys(&tx_info, tx_key, tx_iv);

        var rx_info = tx_info;
        rx_info.rec_seq = rx_rec_seq;
        fillKtlsKeys(&rx_info, rx_key, rx_iv);

        try setsockoptTls(fd, c.TLS_TX, std.mem.asBytes(&tx_info));
        try setsockoptTls(fd, c.TLS_RX, std.mem.asBytes(&rx_info));
    }

    /// Copy the derived key + nonce into a crypto_info struct. Sizes come from
    /// the struct's array fields: salt takes the fixed IV prefix, `iv` the rest.
    fn fillKtlsKeys(info: anytype, key: []const u8, iv: []const u8) void {
        const salt_len = info.salt.len; // comptime: 4 for AES-GCM, 0 for ChaCha20
        @memcpy(&info.key, key[0..info.key.len]);
        @memcpy(&info.salt, iv[0..salt_len]);
        @memcpy(&info.iv, iv[salt_len..][0..info.iv.len]);
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
            const e = helpers.syscallErrno(rc);
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

        // TX = sending direction: server sends with server_secret
        const tx_secret = self.ktls_secrets.server_secret[0..self.ktls_secrets.secret_len];
        const rx_secret = self.ktls_secrets.client_secret[0..self.ktls_secrets.secret_len];

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

        // Server: TX uses server_write_*, RX uses client_write_*
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

        // Scrub
        @memset(&master_secret, 0);
        @memset(&key_block, 0);
    }
};

// ============================================================================
// Tests
// ============================================================================

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

test "parseKeylogSecret rejects invalid hex characters" {
    const client_random_hex = "a" ** 64;
    const secret_hex = "zz" ++ "00" ** 31; // invalid first byte, 64 hex chars total
    const rest = client_random_hex ++ " " ++ secret_hex;

    var out: [48]u8 = .{0} ** 48;
    var len: u8 = 0;
    parseKeylogSecret(rest, &out, &len);
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
