const std = @import("std");
const xev = @import("xev");
const log = @import("log.zig");
const LinearBuffer = @import("buffer.zig").LinearBuffer;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const Router = @import("router.zig").Router;
const LuaState = @import("lua_state.zig").LuaState;
const io_request_mod = @import("io_request.zig");
const TlsMode = io_request_mod.TlsMode;
const ring = @import("ring.zig");
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;
const TlsContext = tls_mod.TlsContext;
const Lua = @import("luajit").Lua;
const ws = @import("ws.zig");
const lua_api = @import("lua_api.zig");
const SseRegistry = @import("sse.zig").SseRegistry;
const config = @import("config.zig");
const params = @import("params.zig");
const conn_tls = @import("conn_tls.zig");
pub const conn_sse = @import("conn_sse.zig");
pub const conn_ws = @import("conn_ws.zig");
pub const cosocket = @import("cosocket.zig");

// Re-exports for backward compatibility
pub const ParamArray = params.ParamArray;
pub const QueryArray = params.QueryArray;
pub const MAX_ROUTE_PARAMS = params.MAX_ROUTE_PARAMS;
const parseQueryString = params.parseQueryString;
pub const SuspendedState = cosocket.SuspendedState;

const READ_BUFFER_SIZE = config.READ_BUFFER_SIZE;
const WRITE_BUFFER_SIZE = config.WRITE_BUFFER_SIZE;
const CIPHERTEXT_BUFFER_SIZE = config.CIPHERTEXT_BUFFER_SIZE;
const LARGE_RESPONSE_THRESHOLD = config.LARGE_RESPONSE_THRESHOLD;

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

    // WebSocket: non-null when connection has been upgraded to WebSocket
    ws_state: ?conn_ws.WsState = null,

    // SSE: non-null when connection has been upgraded to SSE
    sse_state: ?conn_sse.SseState = null,
    sse_registry: ?*SseRegistry = null,
    sse_send_queue: std.ArrayListUnmanaged([]const u8) = .{},
    sse_drain_index: usize = 0,
    sse_writing: bool = false,
    sse_disconnect_completion: xev.Completion = undefined,

    // Close guard: prevents double-free when two async error paths race
    is_closing: bool = false,

    // TLS: non-null when connection is TLS-encrypted
    tls_conn: ?TlsConn = null,
    ciphertext_buffer: ?LinearBuffer = null, // recv target for TLS connections
    tls_handshake_complete: bool = false, // flag for sendTlsData -> onTlsHandshakeWrite

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        socket: std.posix.socket_t,
        router: *Router,
        lua_state: *LuaState,
        sse_registry: ?*SseRegistry,
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
            .sse_registry = sse_registry,
        };

        return conn;
    }

    /// Initialize TLS on this connection. Called from onAccept when TLS is configured.
    pub fn initTls(self: *Connection, tls_ctx: *TlsContext) !void {
        try conn_tls.initTls(self, tls_ctx);
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
        // Clean up WebSocket callback refs
        if (self.ws_state) |wss| {
            if (wss.on_message_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_message_ref);
            if (wss.on_close_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_close_ref);
        }
        // Clean up SSE state
        conn_sse.deinitSse(self);
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
                std.log.err("[fd={d}] recv failed err={}", .{ self.socket, err });
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
                conn_tls.handleTlsHandshake(self, tc);
            } else {
                conn_tls.handleTlsDecrypt(self, tc);
            }
            return .disarm;
        }

        // Plaintext path
        self.read_buffer.commitWrite(bytes_read);

        self.sendResponse() catch |err| {
            std.log.err("[fd={d}] response dispatch failed err={}", .{ self.socket, err });
            self.close();
            return .disarm;
        };

        return .disarm;
    }

    pub fn logAccess(self: *Connection, status: u16) void {
        const dur_us: i64 = @intCast(@divTrunc(std.time.nanoTimestamp() - self.request_start_ns, 1000));
        log.accessLog(self.request_method, self.request_path, status, dur_us);
    }

    pub fn sendResponse(self: *Connection) !void {
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
            std.log.err("[fd={d}] http parse failed err={}", .{ self.socket, err });
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
                std.log.err("[fd={d}] lua handler error {s} {s} err={}", .{ self.socket, request.method, clean_path, err });
                self.logAccess(500);
                self.send500InternalError();
                return;
            };

            switch (handler_result) {
                .completed => {
                    self.lua_state.current_connection = null;

                    // Check for WebSocket upgrade
                    if (exchange_ptr.upgrade_websocket) {
                        conn_ws.handleWsUpgrade(self, exchange_ptr, &request) catch {
                            self.logAccess(400);
                            self.send400BadRequest();
                            return;
                        };
                        return;
                    }

                    // Check for SSE upgrade
                    if (exchange_ptr.upgrade_sse) {
                        conn_sse.handleSseUpgrade(self, exchange_ptr);
                        return;
                    }

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
                    cosocket.dispatchIo(self);
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
    pub fn writeResponse(self: *Connection, exchange_ptr: *HttpExchange) !void {
        var response = exchange_ptr.toResponse();
        defer response.deinit();
        try self.writeResponseDirect(&response);
    }

    /// Serialize a Response and submit the write completion
    pub fn writeResponseDirect(self: *Connection, response: *http.Response) !void {
        const alloc = self.arena.allocator();
        // Pre-size to avoid repeated ArrayList growth in arena (old buffers can't be freed)
        const estimated = response.body.len + 512;
        var response_buf = try std.ArrayList(u8).initCapacity(alloc, estimated);
        try response.serialize(response_buf.writer(alloc));

        if (self.ws_state != null) {
            std.log.debug("ws: response buf len={d} content=[{s}]", .{ response_buf.items.len, response_buf.items });
        }

        if (!self.submitTlsAwareSend(response_buf.items, onWrite, false)) {
            self.close();
        }
    }

    /// TLS-aware send: encrypt if TLS, optionally arena-dupe for stack-local buffers.
    /// Returns false on allocation/encryption failure (caller decides error handling).
    pub fn submitTlsAwareSend(self: *Connection, data: []const u8, callback: *const fn (?*anyopaque, *xev.Loop, *xev.Completion, xev.Result) xev.CallbackAction, arena_dupe: bool) bool {
        const alloc = self.arena.allocator();
        if (self.tls_conn) |*tc| {
            const ciphertext = cosocket.tlsEncryptAlloc(tc, data, alloc) orelse return false;
            self.write_completion = .{
                .op = .{ .send = .{ .fd = self.socket, .buffer = .{ .slice = ciphertext } } },
                .userdata = self,
                .callback = callback,
            };
            self.loop.add(&self.write_completion);
            return true;
        }

        const send_data = if (arena_dupe) alloc.dupe(u8, data) catch return false else data;
        self.write_completion = .{
            .op = .{ .send = .{ .fd = self.socket, .buffer = .{ .slice = send_data } } },
            .userdata = self,
            .callback = callback,
        };
        self.loop.add(&self.write_completion);
        return true;
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

    pub fn send400BadRequest(self: *Connection) void {
        self.sendRawResponse("HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request");
    }

    pub fn send500InternalError(self: *Connection) void {
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
            std.log.err("[fd={d}] send failed err={}", .{ self.socket, err });
            self.close();
            return .disarm;
        };

        // WebSocket upgrade: after 101 is sent, switch to WS frame loop
        if (self.ws_state != null) {
            std.log.debug("ws: 101 sent ({d} bytes written), entering WS mode. raw_len={d} buf_avail_read={d} buf_avail_write={d}", .{
                bytes_written,
                self.request_raw_len,
                self.read_buffer.availableRead(),
                self.read_buffer.availableWrite(),
            });
            _ = self.arena.reset(.retain_capacity);
            // Consume the HTTP request bytes
            if (self.request_raw_len > 0) {
                self.read_buffer.consume(self.request_raw_len);
                self.request_raw_len = 0;
            } else {
                self.read_buffer.reset();
            }
            if (self.ciphertext_buffer) |*cb| cb.reset();
            std.log.debug("ws: starting WS read loop. buf_avail_read={d} buf_avail_write={d}", .{
                self.read_buffer.availableRead(),
                self.read_buffer.availableWrite(),
            });
            // If the client sent WS data in the same TCP segment as the HTTP
            // upgrade request, process it now instead of waiting for another recv.
            if (self.read_buffer.availableRead() > 0) {
                conn_ws.processWsFrames(self);
            } else {
                conn_ws.startWsRead(self);
            }
            return .disarm;
        }

        // SSE upgrade: after headers are sent, subscribe and start disconnect watch
        if (self.sse_state != null) {
            // SSE headers already sent — start watching for client disconnect
            conn_sse.startSseDisconnectWatch(self);
            return .disarm;
        }

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
                std.log.err("[fd={d}] pipelined response dispatch failed err={}", .{ self.socket, err });
                self.close();
                return .disarm;
            };
        } else {
            self.read_buffer.reset();
            self.startRead();
        }
        return .disarm;
    }

    pub fn close(self: *Connection) void {
        if (self.is_closing) return;
        self.is_closing = true;
        self.deinit(self.base_allocator);
    }
};
