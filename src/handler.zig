const std = @import("std");
const xev = @import("xev");
const log = @import("log.zig");
const LinearBuffer = @import("buffer.zig").LinearBuffer;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const Router = @import("router.zig").Router;
const LuaState = @import("lua_state.zig").LuaState;
const IoRequest = @import("io_request.zig").IoRequest;
const ring = @import("ring.zig");
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;
const TlsContext = tls_mod.TlsContext;
const Lua = @import("luajit").Lua;

// Buffer size constants
const READ_BUFFER_SIZE = 65536;
const WRITE_BUFFER_SIZE = 8192;
const CIPHERTEXT_BUFFER_SIZE = 8192;
const LARGE_RESPONSE_THRESHOLD = 1024 * 1024; // Free arena if response > 1MB
pub const MAX_ROUTE_PARAMS = 4; // Typical routes have 1-4 params
const MAX_QUERY_PARAMS = 4; // Typical query strings have 1-4 params

/// Lightweight param storage - replaces HashMap for route params
/// O(n) lookup but n ≤ 4, cache-friendly, zero allocations
pub const ParamArray = struct {
    items: [MAX_ROUTE_PARAMS]Param = undefined,
    len: usize = 0,

    const Param = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn put(self: *ParamArray, key: []const u8, value: []const u8) error{TooManyParams}!void {
        if (self.len >= MAX_ROUTE_PARAMS) return error.TooManyParams;
        self.items[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    pub fn get(self: *const ParamArray, key: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |param| {
            if (std.mem.eql(u8, param.key, key)) return param.value;
        }
        return null;
    }

    pub fn clear(self: *ParamArray) void {
        self.len = 0;
    }
};

/// Lightweight query param storage - same pattern as ParamArray
pub const QueryArray = struct {
    items: [MAX_QUERY_PARAMS]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn put(self: *QueryArray, key: []const u8, value: []const u8) error{TooManyParams}!void {
        if (self.len >= MAX_QUERY_PARAMS) return error.TooManyParams;
        self.items[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    pub fn get(self: *const QueryArray, key: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn clear(self: *QueryArray) void {
        self.len = 0;
    }
};

/// Parse a query string (everything after '?') into a QueryArray.
/// Splits on '&', then each pair on '='. Values are zero-copy slices.
fn parseQueryString(raw: []const u8, out: *QueryArray) void {
    var pairs = std.mem.splitScalar(u8, raw, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            out.put(pair[0..eq], pair[eq + 1 ..]) catch {
                std.log.warn("query string exceeds {d} params, truncating", .{MAX_QUERY_PARAMS});
                return;
            };
        } else {
            out.put(pair, "") catch {
                std.log.warn("query string exceeds {d} params, truncating", .{MAX_QUERY_PARAMS});
                return;
            };
        }
    }
}

/// Cosocket suspend state — bundled so one `= null` replaces seven resets.
/// Non-null means a handler is yielded waiting on outbound I/O.
pub const SuspendedState = struct {
    completion: xev.Completion,
    exchange: *HttpExchange,
    recv_buf: ?[]u8,
    coroutine_ref: i32,
    coroutine_thread: *anyopaque,
    outbound_fd: std.posix.socket_t,
    pending_op: IoRequest.Op,
    outbound_tls: ?*TlsConn = null, // temporary, during handshake only
};

/// Connection handler - manages HTTP request/response lifecycle
pub const Connection = struct {
    base_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    loop: *xev.Loop,
    socket: std.posix.socket_t,
    router: *Router,
    lua_state: *LuaState,

    // Completions (must have stable address!)
    read_completion: xev.Completion,
    write_completion: xev.Completion,

    // Buffers (allocated from base_allocator, persist across requests)
    read_buffer: LinearBuffer,
    write_buffer: []u8,
    write_pos: usize,

    // Inline param/query storage (reused across requests, zero allocations, cache-friendly)
    param_cache: ParamArray,
    query_cache: QueryArray,

    // Access log state
    request_start_ns: i128 = 0,
    request_method: []const u8 = "",
    request_path: []const u8 = "",
    request_raw_len: usize = 0, // total bytes consumed by current request (headers + body)

    // I/O ring: per-connection submission/completion buffers for batched I/O
    sq: ring.SubmissionRing = .{},
    cq: ring.CompletionRing = .{},
    pending_completions: u8 = 0,
    batch_completions: [ring.SubmissionRing.MAX_DEPTH]xev.Completion = undefined,
    batch_recv_bufs: [ring.SubmissionRing.MAX_DEPTH]?[]u8 = .{null} ** ring.SubmissionRing.MAX_DEPTH,
    batch_tls_conns: [ring.SubmissionRing.MAX_DEPTH]?*TlsConn = .{null} ** ring.SubmissionRing.MAX_DEPTH,

    // Cosocket: non-null when handler is suspended on outbound I/O
    suspended: ?SuspendedState = null,

    // TLS: non-null when connection is TLS-encrypted
    tls_conn: ?TlsConn = null,
    ciphertext_buffer: ?LinearBuffer = null, // recv target for TLS connections
    tls_handshake_complete: bool = false, // flag for sendTlsData → onTlsHandshakeWrite

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        socket: std.posix.socket_t,
        router: *Router,
        lua_state: *LuaState,
    ) !*Connection {
        const conn = try allocator.create(Connection);
        errdefer allocator.destroy(conn);

        // Allocate buffers from base allocator (persist across requests)
        const write_buf = try allocator.alloc(u8, WRITE_BUFFER_SIZE);
        errdefer allocator.free(write_buf);

        const read_buf = try LinearBuffer.init(allocator, READ_BUFFER_SIZE);
        errdefer allocator.free(read_buf.data);

        // Initialize arena for per-request allocations
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        // Assign everything at once
        conn.* = Connection{
            .base_allocator = allocator,
            .arena = arena,
            .loop = loop,
            .socket = socket,
            .router = router,
            .lua_state = lua_state,
            .read_completion = undefined,
            .write_completion = undefined,
            .read_buffer = read_buf,
            .write_buffer = write_buf,
            .write_pos = 0,
            .param_cache = ParamArray{},
            .query_cache = QueryArray{},
        };

        return conn;
    }

    /// Initialize TLS on this connection. Called from onAccept when TLS is configured.
    pub fn initTls(self: *Connection, tls_ctx: *TlsContext) !void {
        self.tls_conn = try TlsConn.init(self.base_allocator, tls_ctx.ctx, .server);
        self.ciphertext_buffer = try LinearBuffer.init(self.base_allocator, CIPHERTEXT_BUFFER_SIZE);
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        // Clean up suspended coroutine state if connection closes mid-I/O
        if (self.suspended) |s| {
            // Unref pinned coroutine to prevent Lua registry leak
            if (s.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
            }
            // Close leaked outbound fd
            if (s.outbound_fd != 0) std.posix.close(s.outbound_fd);
        }
        // Clean up TLS resources
        if (self.tls_conn) |*tc| tc.deinit(self.base_allocator);
        if (self.ciphertext_buffer) |*cb| cb.deinit();
        std.posix.close(self.socket);
        self.arena.deinit();
        // param_cache/query_cache are inline structs, no deinit needed
        self.base_allocator.free(self.write_buffer);
        self.base_allocator.free(self.read_buffer.data);
        allocator.destroy(self);
    }

    /// Start reading from connection
    pub fn startRead(self: *Connection) void {
        const buf = if (self.ciphertext_buffer) |*cb| blk: {
            if (cb.availableWrite() == 0) {
                self.send400BadRequest();
                return;
            }
            break :blk cb.writeSlice();
        } else blk: {
            if (self.read_buffer.availableWrite() == 0) {
                self.send400BadRequest();
                return;
            }
            break :blk self.read_buffer.writeSlice();
        };
        self.read_completion = .{
            .op = .{
                .recv = .{
                    .fd = self.socket,
                    .buffer = .{ .slice = buf },
                },
            },
            .userdata = self,
            .callback = onRead,
        };
        self.loop.add(&self.read_completion);
    }

    fn onRead(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));

        const bytes_read = result.recv catch |err| {
            if (err != error.EOF) {
                std.log.err("recv failed err={}", .{err});
            }
            self.close();
            return .disarm;
        };

        if (bytes_read == 0) {
            self.close();
            return .disarm;
        }

        // TLS path: decrypt ciphertext before processing
        if (self.tls_conn) |*tc| {
            var cb = &self.ciphertext_buffer.?;
            cb.commitWrite(bytes_read);
            tc.feedCiphertext(cb.readSlice());
            cb.reset(); // BIO owns the data now

            if (!tc.isEstablished()) {
                self.handleTlsHandshake(tc);
            } else {
                self.handleTlsDecrypt(tc);
            }
            return .disarm;
        }

        // Plaintext path
        self.read_buffer.commitWrite(bytes_read);

        self.sendResponse() catch |err| {
            std.log.err("response dispatch failed err={}", .{err});
            self.close();
            return .disarm;
        };

        return .disarm;
    }

    fn handleTlsHandshake(self: *Connection, tc: *TlsConn) void {
        const hs_result = tc.handshake();

        // Send any handshake data the TLS engine produced
        if (tc.needsWrite()) {
            self.sendTlsData(hs_result == .complete);
            return;
        }

        switch (hs_result) {
            .complete => self.startRead(), // handshake done, read first HTTP data
            .want_read => self.startRead(), // need more handshake data from client
            .failed => self.close(),
        }
    }

    fn handleTlsDecrypt(self: *Connection, tc: *TlsConn) void {
        const out = self.read_buffer.writeSlice();
        if (out.len == 0) {
            self.send400BadRequest();
            return;
        }
        switch (tc.decrypt(out)) {
            .data => |n| {
                self.read_buffer.commitWrite(n);
                self.sendResponse() catch |err| {
                    std.log.err("response dispatch failed err={}", .{err});
                    self.close();
                };
            },
            .want_read => self.startRead(),
            .err => self.close(),
        }
    }

    /// Send TLS handshake/ciphertext data over the wire.
    /// Drains all pending data from wbio into encrypt_buf and submits a send.
    fn sendTlsData(self: *Connection, handshake_complete: bool) void {
        const tc = &self.tls_conn.?;
        const total = tc.drainAll();
        if (total == 0) {
            if (handshake_complete) {
                self.startRead();
            } else {
                self.close();
            }
            return;
        }

        self.tls_handshake_complete = handshake_complete;

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

    fn onTlsHandshakeWrite(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));
        _ = result.send catch {
            self.close();
            return .disarm;
        };

        const handshake_complete = self.tls_handshake_complete;
        self.tls_handshake_complete = false;

        if (handshake_complete) {
            // Handshake finished, check if there's more data to send (e.g. TLS 1.2 multi-flight)
            const tc = &self.tls_conn.?;
            if (tc.needsWrite()) {
                self.sendTlsData(true);
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

    fn logAccess(self: *Connection, status: u16) void {
        const dur_us: i64 = @intCast(@divTrunc(std.time.nanoTimestamp() - self.request_start_ns, 1000));
        log.accessLog(self.request_method, self.request_path, status, dur_us);
    }

    fn sendResponse(self: *Connection) !void {
        self.request_start_ns = std.time.nanoTimestamp();

        // Parse HTTP request using picohttpparser
        const request_data = self.read_buffer.readSlice();
        const alloc = self.arena.allocator();

        var parser = http.Parser.init(alloc);
        const request = parser.parseRequest(request_data) catch |err| {
            if (err == error.Incomplete) {
                self.startRead();
                return;
            }
            std.log.err("http parse failed err={}", .{err});
            self.send400BadRequest();
            return;
        };
        // headers are arena-allocated, freed on arena reset in onWrite

        // Strip query string from path for routing, parse query params
        const query_pos = std.mem.indexOfScalar(u8, request.path, '?');
        const clean_path = if (query_pos) |qi| request.path[0..qi] else request.path;

        self.request_method = request.method;
        self.request_path = clean_path;
        self.request_raw_len = request.raw_len;

        self.query_cache.clear();
        if (query_pos) |qi| {
            parseQueryString(request.path[qi + 1 ..], &self.query_cache);
        }

        // Clear param cache and match route (using clean path without query string)
        self.param_cache.clear();
        const lua_ref = self.router.match(request.method, clean_path, &self.param_cache) catch {
            self.send400BadRequest();
            return;
        };

        if (lua_ref) |ref| {
            // Arena-allocate exchange (must persist across yields)
            const exchange_ptr = try alloc.create(HttpExchange);
            exchange_ptr.* = try HttpExchange.init(alloc, &request, &self.param_cache, &self.query_cache, clean_path);

            self.lua_state.current_connection = self;
            const handler_result = self.lua_state.callLuaHandler(ref, exchange_ptr) catch |err| {
                self.lua_state.current_connection = null;
                std.log.err("lua handler error path={s} method={s} err={}", .{ clean_path, request.method, err });
                self.logAccess(500);
                self.send500InternalError();
                return;
            };

            switch (handler_result) {
                .completed => {
                    self.lua_state.current_connection = null;
                    self.logAccess(exchange_ptr.status);
                    try self.writeResponse(exchange_ptr);
                },
                .yielded => {
                    // Handler wants outbound I/O — bundle coroutine state
                    self.suspended = .{
                        .completion = undefined,
                        .exchange = exchange_ptr,
                        .recv_buf = null,
                        .coroutine_ref = self.lua_state.coroutine_ref,
                        .coroutine_thread = @ptrCast(self.lua_state.coroutine_thread.?),
                        .outbound_fd = 0,
                        .pending_op = .none,
                    };
                    self.lua_state.coroutine_ref = 0;
                    self.lua_state.coroutine_thread = null;
                    self.dispatchIo();
                },
            }
        } else {
            // No route matched — 404
            self.logAccess(404);
            var resp = http.Response.init(alloc);
            resp.status = 404;
            const body404 = try alloc.alloc(u8, 9);
            @memcpy(body404, "Not Found");
            resp.body = body404;
            try self.writeResponseDirect(&resp);
        }
    }

    /// Serialize response from exchange and submit write
    fn writeResponse(self: *Connection, exchange_ptr: *HttpExchange) !void {
        var response = exchange_ptr.toResponse();
        defer response.deinit();
        try self.writeResponseDirect(&response);
    }

    /// Serialize a Response and submit the write completion
    fn writeResponseDirect(self: *Connection, response: *http.Response) !void {
        const alloc = self.arena.allocator();
        // Pre-size to avoid repeated ArrayList growth in arena (old buffers can't be freed)
        const estimated = response.body.len + 512;
        var response_buf = std.ArrayList(u8).initCapacity(alloc, estimated) catch unreachable;
        try response.serialize(response_buf.writer(alloc));

        // TLS: encrypt the HTTP response before sending
        if (self.tls_conn) |*tc| {
            const ciphertext = tlsEncryptAlloc(tc, response_buf.items, alloc) orelse {
                self.close();
                return;
            };

            self.write_completion = .{
                .op = .{
                    .send = .{
                        .fd = self.socket,
                        .buffer = .{ .slice = ciphertext },
                    },
                },
                .userdata = self,
                .callback = onWrite,
            };
            self.loop.add(&self.write_completion);
            return;
        }

        self.write_completion = .{
            .op = .{
                .send = .{
                    .fd = self.socket,
                    .buffer = .{ .slice = response_buf.items },
                },
            },
            .userdata = self,
            .callback = onWrite,
        };
        self.loop.add(&self.write_completion);
    }

    /// Read pending_io from LuaState, create socket / submit xev operation
    fn submitOutboundIO(self: *Connection) void {
        const s = &self.suspended.?;
        const pending = self.lua_state.pending_io;
        self.lua_state.pending_io = .{};

        switch (pending.op) {
            .connect, .pool_connect => {
                s.pending_op = pending.op;
                const sock = std.posix.socket(
                    std.posix.AF.INET,
                    std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
                    0,
                ) catch {
                    self.resumeWithError("socket creation failed");
                    return;
                };
                s.outbound_fd = sock;

                const host = pending.host orelse {
                    std.posix.close(sock);
                    s.outbound_fd = 0;
                    self.resumeWithError("connect: missing host");
                    return;
                };
                const addr = std.net.Address.parseIp4(host, pending.port) catch {
                    std.posix.close(sock);
                    s.outbound_fd = 0;
                    self.resumeWithError("connect: invalid address");
                    return;
                };

                s.completion = .{
                    .op = .{ .connect = .{ .socket = sock, .addr = addr } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&s.completion);
            },
            .udp_connect => {
                s.pending_op = .udp_connect;
                const sock = std.posix.socket(
                    std.posix.AF.INET,
                    std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
                    0,
                ) catch {
                    self.resumeWithError("udp_connect: socket creation failed");
                    return;
                };
                // Set receive timeout once on the socket
                if (pending.timeout_ms > 0) {
                    const tv = std.posix.timeval{
                        .sec = @intCast(pending.timeout_ms / 1000),
                        .usec = @intCast((pending.timeout_ms % 1000) * 1000),
                    };
                    _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
                }

                s.outbound_fd = sock;

                const host = pending.host orelse {
                    std.posix.close(sock);
                    s.outbound_fd = 0;
                    self.resumeWithError("udp_connect: missing host");
                    return;
                };
                const addr = std.net.Address.parseIp4(host, pending.port) catch {
                    std.posix.close(sock);
                    s.outbound_fd = 0;
                    self.resumeWithError("udp_connect: invalid address");
                    return;
                };

                s.completion = .{
                    .op = .{ .connect = .{ .socket = sock, .addr = addr } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&s.completion);
            },
            .send => {
                const raw_data = pending.send_data orelse {
                    self.resumeWithError("send: missing data");
                    return;
                };
                // Arena-dupe send_data before async submission — Lua string may be GC'd across yield
                const data = self.arena.allocator().dupe(u8, raw_data) catch {
                    self.resumeWithError("send: arena alloc failed");
                    return;
                };
                // TLS-aware send: encrypt if fd has TLS state
                if (self.lua_state.getTls(pending.fd)) |tls_conn| {
                    const ciphertext = tlsEncryptAlloc(tls_conn, data, self.arena.allocator()) orelse {
                        self.resumeWithError("send: tls encrypt failed");
                        return;
                    };
                    s.completion = .{
                        .op = .{ .send = .{ .fd = pending.fd, .buffer = .{ .slice = ciphertext } } },
                        .userdata = self,
                        .callback = onOutboundComplete,
                    };
                    self.loop.add(&s.completion);
                } else {
                    s.completion = .{
                        .op = .{ .send = .{ .fd = pending.fd, .buffer = .{ .slice = data } } },
                        .userdata = self,
                        .callback = onOutboundComplete,
                    };
                    self.loop.add(&s.completion);
                }
            },
            .recv => {
                // If fd has TLS state, check if BoringSSL already has buffered plaintext
                // from a previous feedCiphertext call. Without this check, the kernel recv
                // blocks because postgres has nothing more to send — the data is already
                // inside BoringSSL's internal buffers.
                if (self.lua_state.getTls(pending.fd)) |tls_conn| {
                    if (tls_conn.hasPending()) {
                        var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                        switch (tls_conn.decrypt(&plaintext_buf)) {
                            .data => |n| {
                                const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
                                thread.pushLString(plaintext_buf[0..n]);
                                self.dispatchResume(thread, 1, s.exchange);
                                return;
                            },
                            .want_read => {}, // Fall through to kernel recv
                            .err => {
                                self.resumeWithError("recv: tls decrypt failed");
                                return;
                            },
                        }
                    }
                }

                const buf = self.arena.allocator().alloc(u8, pending.max_len) catch {
                    self.resumeWithError("recv: alloc failed");
                    return;
                };
                s.recv_buf = buf;

                s.completion = .{
                    .op = .{ .recv = .{ .fd = pending.fd, .buffer = .{ .slice = buf } } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&s.completion);
            },
            .close => {
                // Clean up TLS state for this fd if present
                self.lua_state.removeTls(pending.fd);
                s.completion = .{
                    .op = .{ .close = .{ .fd = pending.fd } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&s.completion);
            },
            .tls_handshake => {
                s.pending_op = .tls_handshake;
                // Allocate TlsConn from base_allocator (outlives request)
                const tls_conn = self.base_allocator.create(TlsConn) catch {
                    self.resumeWithError("sslhandshake: alloc failed");
                    return;
                };
                tls_conn.* = TlsConn.init(self.base_allocator, self.lua_state.client_tls_ctx.ctx, .client) catch {
                    self.base_allocator.destroy(tls_conn);
                    self.resumeWithError("sslhandshake: tls init failed");
                    return;
                };

                // Set SNI if host provided
                if (pending.host) |host| {
                    const host_z = self.arena.allocator().dupeZ(u8, host) catch {
                        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                        self.resumeWithError("sslhandshake: alloc failed");
                        return;
                    };
                    tls_conn.setSni(host_z);
                }

                s.outbound_tls = tls_conn;

                // Kick off handshake — produces ClientHello in wbio
                _ = tls_conn.handshake();

                // Drain wbio and send ClientHello
                const total = tls_conn.drainAll();
                if (total == 0) {
                    tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                    s.outbound_tls = null;
                    self.resumeWithError("sslhandshake: no handshake data produced");
                    return;
                }

                s.completion = .{
                    .op = .{ .send = .{ .fd = pending.fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                    .userdata = self,
                    .callback = onTlsOutboundHandshakeSend,
                };
                s.outbound_fd = pending.fd;
                self.loop.add(&s.completion);
            },
            .none => {
                self.resumeWithError("no pending I/O operation");
            },
        }
    }

    /// xev callback for all outbound I/O completions
    fn onOutboundComplete(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));
        const s = &self.suspended.?;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        const exchange_ptr = s.exchange;

        // Determine what completed based on the op that was submitted
        const op = completion.op;
        var nresults: c_int = 1;

        if (op == .connect) {
            _ = result.connect catch {
                std.posix.close(s.outbound_fd);
                s.outbound_fd = 0;
                thread.pushNil();
                thread.pushString("connection refused");
                nresults = 2;
                s.pending_op = .none;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            if (s.pending_op == .pool_connect) {
                // pool_connect returns (fd, reuse_count=0)
                thread.pushInteger(@intCast(s.outbound_fd));
                thread.pushInteger(0);
                nresults = 2;
            } else {
                // connect and udp_connect both return fd only
                thread.pushInteger(@intCast(s.outbound_fd));
            }
            s.outbound_fd = 0; // ownership transferred to Lua; completeHandler must not close it
            s.pending_op = .none;
        } else if (op == .send) {
            const bytes_sent = result.send catch {
                thread.pushNil();
                thread.pushString("send failed");
                nresults = 2;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            thread.pushInteger(@intCast(bytes_sent));
        } else if (op == .recv) {
            const bytes_read = result.recv catch {
                thread.pushNil();
                thread.pushString("recv failed");
                nresults = 2;
                s.recv_buf = null;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            if (s.recv_buf) |buf| {
                // Check if this fd has TLS state — decrypt before pushing to Lua
                if (self.lua_state.getTls(completion.op.recv.fd)) |tls_conn| {
                    tls_conn.feedCiphertext(buf[0..bytes_read]);
                    var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                    switch (tls_conn.decrypt(&plaintext_buf)) {
                        .data => |n| {
                            thread.pushLString(plaintext_buf[0..n]);
                        },
                        .want_read => {
                            // Need more ciphertext — re-submit recv without resuming Lua
                            s.completion = .{
                                .op = .{ .recv = .{ .fd = completion.op.recv.fd, .buffer = .{ .slice = buf } } },
                                .userdata = self,
                                .callback = onOutboundComplete,
                            };
                            self.loop.add(&s.completion);
                            return .disarm;
                        },
                        .err => {
                            thread.pushNil();
                            thread.pushString("recv: tls decrypt failed");
                            nresults = 2;
                            s.recv_buf = null;
                            self.dispatchResume(thread, nresults, exchange_ptr);
                            return .disarm;
                        },
                    }
                } else {
                    thread.pushLString(buf[0..bytes_read]);
                }
            } else {
                thread.pushNil();
            }
            s.recv_buf = null;
        } else if (op == .close) {
            _ = result.close catch {
                thread.pushNil();
                thread.pushString("close failed");
                nresults = 2;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            s.outbound_fd = 0; // fd is now closed; prevent completeHandler double-close
            thread.pushInteger(1);
        } else {
            thread.pushNil();
            thread.pushString("unknown outbound op");
            nresults = 2;
        }

        self.dispatchResume(thread, nresults, exchange_ptr);
        return .disarm;
    }

    /// TLS outbound handshake: send completed → check if done or recv more
    fn onTlsOutboundHandshakeSend(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));
        const s = &self.suspended.?;
        const tls_conn = s.outbound_tls orelse {
            self.resumeWithError("sslhandshake: missing tls state");
            return .disarm;
        };

        _ = result.send catch {
            self.cleanupOutboundTls();
            self.resumeWithError("sslhandshake: send failed");
            return .disarm;
        };

        // If handshake already completed (we were just flushing final wbio), finish now
        if (tls_conn.isEstablished()) {
            self.finishOutboundHandshake(tls_conn);
            return .disarm;
        }

        // Need more data from server — recv
        self.submitTlsHandshakeRecv();
        return .disarm;
    }

    /// TLS outbound handshake: recv completed → feed to SSL, continue or complete
    fn onTlsOutboundHandshakeRecv(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));
        const s = &self.suspended.?;
        const tls_conn = s.outbound_tls orelse {
            self.resumeWithError("sslhandshake: missing tls state");
            return .disarm;
        };

        const bytes_read = result.recv catch {
            self.cleanupOutboundTls();
            self.resumeWithError("sslhandshake: recv failed");
            return .disarm;
        };

        if (bytes_read == 0) {
            self.cleanupOutboundTls();
            self.resumeWithError("sslhandshake: connection closed");
            return .disarm;
        }

        // Feed received ciphertext to TLS engine
        if (s.recv_buf) |buf| {
            tls_conn.feedCiphertext(buf[0..bytes_read]);
        }

        const hs_result = tls_conn.handshake();

        // Drain any outbound data the handshake produced (e.g. Finished)
        if (tls_conn.needsWrite()) {
            const total = tls_conn.drainAll();
            if (total > 0) {
                // Send it — onTlsOutboundHandshakeSend checks .established to know if done
                s.completion = .{
                    .op = .{ .send = .{ .fd = s.outbound_fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                    .userdata = self,
                    .callback = onTlsOutboundHandshakeSend,
                };
                self.loop.add(&s.completion);
                return .disarm;
            }
        }

        switch (hs_result) {
            .complete => self.finishOutboundHandshake(tls_conn),
            .want_read => self.submitTlsHandshakeRecv(),
            .failed => {
                self.cleanupOutboundTls();
                self.resumeWithError("sslhandshake: handshake failed");
            },
        }
        return .disarm;
    }

    /// Finish a successful outbound TLS handshake — store in tls_map, resume Lua
    fn finishOutboundHandshake(self: *Connection, tls_conn: *TlsConn) void {
        const s = &self.suspended.?;
        self.lua_state.registerTls(s.outbound_fd, tls_conn) catch {
            self.cleanupOutboundTls();
            self.resumeWithError("sslhandshake: map put failed");
            return;
        };
        s.outbound_tls = null;
        s.outbound_fd = 0;
        s.pending_op = .none;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        thread.pushInteger(1);
        self.dispatchResume(thread, 1, s.exchange);
    }

    /// Submit a recv for handshake data, reusing existing recv_buf or allocating one
    fn submitTlsHandshakeRecv(self: *Connection) void {
        const s = &self.suspended.?;
        const buf = s.recv_buf orelse blk: {
            const b = self.arena.allocator().alloc(u8, tls_mod.TLS_RECORD_MAX_SIZE) catch {
                self.cleanupOutboundTls();
                self.resumeWithError("sslhandshake: alloc failed");
                return;
            };
            s.recv_buf = b;
            break :blk b;
        };
        s.completion = .{
            .op = .{ .recv = .{ .fd = s.outbound_fd, .buffer = .{ .slice = buf } } },
            .userdata = self,
            .callback = onTlsOutboundHandshakeRecv,
        };
        self.loop.add(&s.completion);
    }

    /// Clean up outbound TLS state on handshake failure
    fn cleanupOutboundTls(self: *Connection) void {
        const s = &self.suspended.?;
        if (s.outbound_tls) |tls_conn| {
            tls_mod.freeTlsConn(self.base_allocator, tls_conn);
            s.outbound_tls = null;
        }
    }

    /// Resume coroutine and dispatch based on result
    fn dispatchResume(self: *Connection, thread: *Lua, nresults: c_int, exchange_ptr: *HttpExchange) void {
        self.lua_state.current_connection = self;
        const resume_result = self.lua_state.resumeHandler(@ptrCast(thread), nresults, exchange_ptr) catch {
            self.lua_state.current_connection = null;
            self.send500InternalError();
            return;
        };

        switch (resume_result) {
            .completed => {
                self.lua_state.current_connection = null;
                self.completeHandler();
            },
            .yielded => {
                self.dispatchIo();
            },
        }
    }

    /// Dispatch I/O after a Lua yield: ring path (SQ has entries) or old single-shot path.
    fn dispatchIo(self: *Connection) void {
        if (self.sq.len() > 0) {
            self.drainSubmissionRing();
        } else {
            self.submitOutboundIO();
        }
    }

    /// Drain the submission ring: process each IoEntry, submit async I/O to xev.
    /// Synchronous ops (pool_connect hit, setkeepalive) write CQE immediately.
    /// After all entries are drained, if pending_completions == 0 we resume immediately.
    fn drainSubmissionRing(self: *Connection) void {
        const s = &self.suspended.?;
        self.cq.reset();
        var io_index: u8 = 0;

        while (self.sq.pop()) |entry| {
            switch (entry.*) {
                .connect => |c| {
                    self.submitBatchConnect(c.host, c.port, io_index, .connect);
                    io_index += 1;
                },
                .pool_connect => |c| {
                    // Sync pool hit → write CQE immediately, no xev submission
                    if (self.lua_state.pool.get(c.pool_name)) |hit| {
                        // Restore TLS state from pool if present
                        if (hit.tls_conn) |tls_conn| {
                            self.lua_state.registerTls(hit.fd, tls_conn) catch {
                                tls_mod.freeTlsConn(self.lua_state.allocator, tls_conn);
                            };
                        }
                        self.cq.push(.{ .result = @intCast(hit.fd) });
                    } else {
                        self.submitBatchConnect(c.host, c.port, io_index, .pool_connect);
                    }
                    io_index += 1;
                },
                .send => |snd| {
                    // Arena-dupe send_data before async submission (Lua string lifetime safety)
                    const duped = self.arena.allocator().dupe(u8, snd.data) catch {
                        self.cq.push(.{ .result = -1, .err_msg = "send: arena alloc failed" });
                        io_index += 1;
                        continue;
                    };
                    // TLS-aware send
                    if (self.lua_state.getTls(snd.fd)) |tls_conn| {
                        const ciphertext = tlsEncryptAlloc(tls_conn, duped, self.arena.allocator()) orelse {
                            self.cq.push(.{ .result = -1, .err_msg = "send: tls encrypt failed" });
                            io_index += 1;
                            continue;
                        };
                        self.batch_completions[io_index] = .{
                            .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = ciphertext } } },
                            .userdata = self,
                            .callback = onBatchComplete,
                        };
                    } else {
                        self.batch_completions[io_index] = .{
                            .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = duped } } },
                            .userdata = self,
                            .callback = onBatchComplete,
                        };
                    }
                    self.pending_completions += 1;
                    self.loop.add(&self.batch_completions[io_index]);
                    io_index += 1;
                },
                .recv => |r| {
                    // Check for buffered TLS plaintext first
                    if (self.lua_state.getTls(r.fd)) |tls_conn| {
                        if (tls_conn.hasPending()) {
                            var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                            switch (tls_conn.decrypt(&plaintext_buf)) {
                                .data => |n| {
                                    const buf_copy = self.arena.allocator().dupe(u8, plaintext_buf[0..n]) catch {
                                        self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed" });
                                        io_index += 1;
                                        continue;
                                    };
                                    self.cq.push(.{ .result = @intCast(n), .buf = buf_copy });
                                    io_index += 1;
                                    continue;
                                },
                                .want_read => {}, // fall through to kernel recv
                                .err => {
                                    self.cq.push(.{ .result = -1, .err_msg = "recv: tls decrypt failed" });
                                    io_index += 1;
                                    continue;
                                },
                            }
                        }
                    }
                    const buf = self.arena.allocator().alloc(u8, r.max_len) catch {
                        self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed" });
                        io_index += 1;
                        continue;
                    };
                    self.batch_recv_bufs[io_index] = buf;
                    self.batch_completions[io_index] = .{
                        .op = .{ .recv = .{ .fd = r.fd, .buffer = .{ .slice = buf } } },
                        .userdata = self,
                        .callback = onBatchComplete,
                    };
                    self.pending_completions += 1;
                    self.loop.add(&self.batch_completions[io_index]);
                    io_index += 1;
                },
                .close => |c| {
                    self.lua_state.removeTls(c.fd);
                    self.batch_completions[io_index] = .{
                        .op = .{ .close = .{ .fd = c.fd } },
                        .userdata = self,
                        .callback = onBatchComplete,
                    };
                    self.pending_completions += 1;
                    self.loop.add(&self.batch_completions[io_index]);
                    io_index += 1;
                },
                .setkeepalive => |k| {
                    // Always synchronous — put fd into pool
                    const tls_ptr: ?*TlsConn = self.lua_state.detachTls(k.fd);
                    self.lua_state.pool.put(
                        k.pool_name,
                        k.fd,
                        @intCast(k.reuse_count),
                        @intCast(k.timeout_ms),
                        @intCast(k.pool_size),
                        tls_ptr,
                    ) catch {
                        self.cq.push(.{ .result = -1, .err_msg = "setkeepalive: pool put failed" });
                        io_index += 1;
                        continue;
                    };
                    self.cq.push(.{ .result = 1 });
                    io_index += 1;
                },
                .tls_handshake => |t| {
                    // TLS handshake is multi-step — submit as a sequence via the existing mechanism
                    // For now, allocate TlsConn and send ClientHello
                    const tls_conn = self.base_allocator.create(TlsConn) catch {
                        self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed" });
                        io_index += 1;
                        continue;
                    };
                    tls_conn.* = TlsConn.init(self.base_allocator, self.lua_state.client_tls_ctx.ctx, .client) catch {
                        self.base_allocator.destroy(tls_conn);
                        self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: tls init failed" });
                        io_index += 1;
                        continue;
                    };
                    if (t.sni_host) |host| {
                        const host_z = self.arena.allocator().dupeZ(u8, host) catch {
                            tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                            self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed" });
                            io_index += 1;
                            continue;
                        };
                        tls_conn.setSni(host_z);
                    }

                    _ = tls_conn.handshake();
                    const total = tls_conn.drainAll();
                    if (total == 0) {
                        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                        self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: no data produced" });
                        io_index += 1;
                        continue;
                    }

                    // Store tls_conn for the handshake continuation
                    self.batch_tls_conns[io_index] = tls_conn;
                    // For TLS handshake, fall back to single-shot mechanism via suspended state
                    // since handshake is multi-round-trip. We store in s.outbound_tls and delegate.
                    s.outbound_tls = tls_conn;
                    s.outbound_fd = t.fd;
                    s.pending_op = .tls_handshake;
                    self.batch_completions[io_index] = .{
                        .op = .{ .send = .{ .fd = t.fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                        .userdata = self,
                        .callback = onTlsOutboundHandshakeSend,
                    };
                    // TLS handshake hijacks the suspended state — can only have one per batch
                    self.pending_completions += 1;
                    self.loop.add(&self.batch_completions[io_index]);
                    io_index += 1;
                },
                .udp_connect => |u| {
                    self.submitBatchUdpConnect(u.host, u.port, u.timeout_ms, io_index);
                    io_index += 1;
                },
            }
        }
        self.sq.reset();

        if (self.pending_completions == 0) {
            // All ops were synchronous (pool hits, setkeepalive) — resume immediately
            const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
            thread.pushInteger(@intCast(self.cq.tail));
            self.dispatchResume(thread, 1, s.exchange);
        }
        // else: wait for onBatchComplete callbacks to decrement pending_completions
    }

    /// Helper: create TCP socket and submit connect for batched I/O
    fn submitBatchConnect(self: *Connection, host: []const u8, port: u16, io_index: u8, _: IoRequest.Op) void {
        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
        ) catch {
            self.cq.push(.{ .result = -1, .err_msg = "socket creation failed" });
            return;
        };

        const addr = std.net.Address.parseIp4(host, port) catch {
            std.posix.close(sock);
            self.cq.push(.{ .result = -1, .err_msg = "connect: invalid address" });
            return;
        };

        self.batch_completions[io_index] = .{
            .op = .{ .connect = .{ .socket = sock, .addr = addr } },
            .userdata = self,
            .callback = onBatchComplete,
        };
        self.pending_completions += 1;
        self.loop.add(&self.batch_completions[io_index]);
    }

    /// Helper: create UDP socket and submit connect for batched I/O
    fn submitBatchUdpConnect(self: *Connection, host: []const u8, port: u16, timeout_ms: u32, io_index: u8) void {
        const sock = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
            0,
        ) catch {
            self.cq.push(.{ .result = -1, .err_msg = "udp_connect: socket creation failed" });
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
            self.cq.push(.{ .result = -1, .err_msg = "udp_connect: invalid address" });
            return;
        };

        self.batch_completions[io_index] = .{
            .op = .{ .connect = .{ .socket = sock, .addr = addr } },
            .userdata = self,
            .callback = onBatchComplete,
        };
        self.pending_completions += 1;
        self.loop.add(&self.batch_completions[io_index]);
    }

    /// xev callback for batched I/O completions.
    /// Writes result into CQ at the correct index. When all completions arrive, resumes Lua once.
    fn onBatchComplete(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));

        // Determine which SQE index this completion corresponds to
        const base = @intFromPtr(&self.batch_completions[0]);
        const this = @intFromPtr(completion);
        const sqe_index: u8 = @intCast((this - base) / @sizeOf(xev.Completion));

        const op = completion.op;

        if (op == .connect) {
            _ = result.connect catch {
                // Close the socket on connect failure
                std.posix.close(completion.op.connect.socket);
                self.cq.push(.{ .result = -1, .err_msg = "connection refused" });
                self.batchCompletionCheck();
                return .disarm;
            };
            self.cq.push(.{ .result = @intCast(completion.op.connect.socket) });
        } else if (op == .send) {
            const bytes_sent = result.send catch {
                self.cq.push(.{ .result = -1, .err_msg = "send failed" });
                self.batchCompletionCheck();
                return .disarm;
            };
            self.cq.push(.{ .result = @intCast(bytes_sent) });
        } else if (op == .recv) {
            const bytes_read = result.recv catch {
                self.batch_recv_bufs[sqe_index] = null;
                self.cq.push(.{ .result = -1, .err_msg = "recv failed" });
                self.batchCompletionCheck();
                return .disarm;
            };
            if (self.batch_recv_bufs[sqe_index]) |buf| {
                // Check for TLS decryption
                if (self.lua_state.getTls(completion.op.recv.fd)) |tls_conn| {
                    tls_conn.feedCiphertext(buf[0..bytes_read]);
                    var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                    switch (tls_conn.decrypt(&plaintext_buf)) {
                        .data => |n| {
                            const duped = self.arena.allocator().dupe(u8, plaintext_buf[0..n]) catch {
                                self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed" });
                                self.batch_recv_bufs[sqe_index] = null;
                                self.batchCompletionCheck();
                                return .disarm;
                            };
                            self.cq.push(.{ .result = @intCast(n), .buf = duped });
                        },
                        .want_read => {
                            // Need more ciphertext — re-submit recv (stays in batch)
                            self.batch_completions[sqe_index] = .{
                                .op = .{ .recv = .{ .fd = completion.op.recv.fd, .buffer = .{ .slice = buf } } },
                                .userdata = self,
                                .callback = onBatchComplete,
                            };
                            self.loop.add(&self.batch_completions[sqe_index]);
                            return .disarm; // Don't decrement pending_completions
                        },
                        .err => {
                            self.cq.push(.{ .result = -1, .err_msg = "recv: tls decrypt failed" });
                        },
                    }
                } else {
                    self.cq.push(.{ .result = @intCast(bytes_read), .buf = buf[0..bytes_read] });
                }
            } else {
                self.cq.push(.{ .result = -1, .err_msg = "recv: no buffer" });
            }
            self.batch_recv_bufs[sqe_index] = null;
        } else if (op == .close) {
            _ = result.close catch {
                self.cq.push(.{ .result = -1, .err_msg = "close failed" });
                self.batchCompletionCheck();
                return .disarm;
            };
            self.cq.push(.{ .result = 1 });
        } else {
            self.cq.push(.{ .result = -1, .err_msg = "unknown op" });
        }

        self.batchCompletionCheck();
        return .disarm;
    }

    /// Check if all batch completions have arrived; if so, resume Lua with CQ count.
    fn batchCompletionCheck(self: *Connection) void {
        self.pending_completions -= 1;
        if (self.pending_completions == 0) {
            const s = &self.suspended.?;
            const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
            thread.pushInteger(@intCast(self.cq.tail));
            self.dispatchResume(thread, 1, s.exchange);
        }
    }

    /// Handler finished after one or more yield/resume cycles.
    /// Return coroutine to cache, serialize response, submit write.
    fn completeHandler(self: *Connection) void {
        const s = self.suspended orelse return;

        // Return coroutine thread to cache for reuse
        if (s.coroutine_ref != 0) {
            if (self.lua_state.cached_thread_ref == 0) {
                self.lua_state.cached_thread_ref = s.coroutine_ref;
                self.lua_state.cached_thread = @ptrCast(@alignCast(s.coroutine_thread));
            } else {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
            }
        }

        // Safety net: close leaked outbound fd
        if (s.outbound_fd != 0) std.posix.close(s.outbound_fd);

        const exchange_ptr = s.exchange;
        self.suspended = null;

        self.logAccess(exchange_ptr.status);
        self.writeResponse(exchange_ptr) catch {
            self.send500InternalError();
        };
    }

    /// Resume coroutine with nil, error_message for pre-submission failures
    fn resumeWithError(self: *Connection, msg: [:0]const u8) void {
        const s = &self.suspended.?;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        thread.pushNil();
        thread.pushString(msg);
        self.dispatchResume(thread, 2, s.exchange);
    }

    /// Encrypt plaintext via TLS and drain into an allocated buffer.
    /// Returns ciphertext slice, or null on encrypt/alloc failure.
    fn tlsEncryptAlloc(tc: *TlsConn, plaintext: []const u8, allocator: std.mem.Allocator) ?[]u8 {
        tc.encrypt(plaintext) catch return null;
        return tc.drainAllAlloc(allocator) catch null;
    }

    fn sendRawResponse(self: *Connection, text: []const u8) void {
        if (self.tls_conn) |*tc| {
            tc.encrypt(text) catch {
                self.close();
                return;
            };
            // Error responses are small, drainAll into encrypt_buf is fine
            const total = tc.drainAll();
            self.write_completion = .{
                .op = .{ .send = .{ .fd = self.socket, .buffer = .{ .slice = tc.encrypt_buf[0..total] } } },
                .userdata = self,
                .callback = onWrite,
            };
            self.loop.add(&self.write_completion);
            return;
        }
        @memcpy(self.write_buffer[0..text.len], text);
        self.write_pos = text.len;
        self.write_completion = .{
            .op = .{ .send = .{ .fd = self.socket, .buffer = .{ .slice = self.write_buffer[0..self.write_pos] } } },
            .userdata = self,
            .callback = onWrite,
        };
        self.loop.add(&self.write_completion);
    }

    fn send400BadRequest(self: *Connection) void {
        self.sendRawResponse("HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request");
    }

    fn send500InternalError(self: *Connection) void {
        self.sendRawResponse("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error");
    }

    fn onWrite(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));

        const bytes_written = result.send catch |err| {
            std.log.err("send failed err={}", .{err});
            self.close();
            return .disarm;
        };

        // Reset for next request (HTTP/1.1 keep-alive)
        self.suspended = null;
        self.sq.reset();
        self.cq.reset();
        self.pending_completions = 0;
        // Shrink arena if response was large to prevent unbounded growth
        // on keep-alive connections that occasionally serve large responses.
        if (bytes_written > LARGE_RESPONSE_THRESHOLD) {
            _ = self.arena.reset(.free_all);
        } else {
            _ = self.arena.reset(.retain_capacity);
        }

        // Consume exactly the bytes of the completed request (headers + body).
        // This preserves any pipelined data that arrived in the same recv.
        if (self.request_raw_len > 0) {
            self.read_buffer.consume(self.request_raw_len);
            self.request_raw_len = 0;
        } else {
            self.read_buffer.reset();
        }

        // Reset ciphertext buffer but NOT tls_conn — TLS session persists across keep-alive
        if (self.ciphertext_buffer) |*cb| cb.reset();

        // If there's leftover data in the buffer (HTTP pipelining), process it now
        if (self.read_buffer.availableRead() > 0) {
            self.sendResponse() catch |err| {
                std.log.err("pipelined response dispatch failed err={}", .{err});
                self.close();
                return .disarm;
            };
        } else {
            self.read_buffer.reset();
            self.startRead();
        }
        return .disarm;
    }

    fn close(self: *Connection) void {
        self.deinit(self.base_allocator);
    }
};
