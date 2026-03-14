//! Connection lifecycle and proactor boundary.
//!
//! Each Connection owns a socket, read/write buffers, an arena allocator,
//! and per-request state (params, query, I/O rings). The proactor contract:
//! Lua sets state on HttpExchange, Zig submits all I/O via libxev.
//!
//! Lifecycle: accept → startRead → onRead → sendResponse → onWrite → (keep-alive or close)
//! Protocol upgrades (WS, SSE) and cosocket yields branch from sendResponse.

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
const castUserdata = @import("helpers.zig").castUserdata;
const conn_sse = @import("conn_sse.zig");
const conn_ws = @import("conn_ws.zig");
const cosocket = @import("cosocket.zig");
const error_response = @import("error_response.zig");

const ParamArray = params.ParamArray;
const QueryArray = params.QueryArray;
const parseQueryString = params.parseQueryString;
const SuspendedState = cosocket.SuspendedState;

const READ_BUFFER_SIZE = config.READ_BUFFER_SIZE;
const CIPHERTEXT_BUFFER_SIZE = config.CIPHERTEXT_BUFFER_SIZE;
const LARGE_RESPONSE_THRESHOLD = config.LARGE_RESPONSE_THRESHOLD;

/// Connection handler - manages HTTP request/response lifecycle
pub const Connection = struct {
    pub const State = enum { reading, processing, writing, websocket, sse, closing };

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

    // Connection state machine
    state: State = .reading,

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

        const self = castUserdata(Connection, userdata);

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

    fn parseHttpRequest(self: *Connection) ?http.Request {
        const request_data = self.read_buffer.readSlice();
        var parser = http.Parser.init(self.arena.allocator());
        return parser.parseRequest(request_data) catch |err| {
            if (err == error.Incomplete) {
                self.startRead();
            } else {
                error_response.sendError(self, .client_error, "http parse failed");
            }
            return null;
        };
    }

    fn dispatchToHandler(self: *Connection, ref: i32, exchange: *HttpExchange, request: *const http.Request, clean_path: []const u8) !void {
        self.lua_state.current_connection = self;
        const handler_result = self.lua_state.callLuaHandler(ref, exchange) catch |err| {
            self.lua_state.current_connection = null;
            // Log the detailed Lua error separately (not exposed to client)
            std.log.err("[fd={d}] lua handler error {s} {s} err={}", .{ self.socket, request.method, clean_path, err });
            self.logAccess(500);
            error_response.sendError(self, .server_error, "lua handler error");
            return;
        };

        switch (handler_result) {
            .completed => {
                self.lua_state.current_connection = null;

                if (exchange.upgrade_websocket) {
                    conn_ws.handleWsUpgrade(self, exchange, request) catch {
                        self.logAccess(400);
                        error_response.sendError(self, .client_error, "websocket upgrade failed");
                        return;
                    };
                    return;
                }

                if (exchange.upgrade_sse) {
                    conn_sse.handleSseUpgrade(self, exchange);
                    return;
                }

                self.logAccess(exchange.status);
                try self.writeResponse(exchange);
            },
            .yielded => {
                self.suspended = .{
                    .completion = undefined,
                    .exchange = exchange,
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
    }

    pub fn send404NotFound(self: *Connection) void {
        error_response.sendErrorStatus(self, 404, "route not found");
    }

    pub fn sendResponse(self: *Connection) !void {
        self.state = .processing;
        self.request_start_ns = std.time.nanoTimestamp();

        const request = self.parseHttpRequest() orelse return;
        const alloc = self.arena.allocator();

        const query_pos = std.mem.indexOfScalar(u8, request.path, '?');
        const clean_path = if (query_pos) |qi| request.path[0..qi] else request.path;

        self.request_method = request.method;
        self.request_path = clean_path;
        self.request_raw_len = request.raw_len;

        // Reject oversized Content-Length before reading body or routing
        if (http.getContentLength(&request)) |content_length| {
            if (content_length > config.MAX_BODY_SIZE) {
                self.logAccess(413);
                error_response.sendErrorStatus(self, 413, "body exceeds size limit");
                return;
            }
        }

        self.query_cache.clear();
        if (query_pos) |qi| {
            parseQueryString(request.path[qi + 1 ..], &self.query_cache);
        }

        self.param_cache.clear();
        const lua_ref = self.router.match(request.method, clean_path, &self.param_cache) catch {
            error_response.sendError(self, .client_error, "route match error");
            return;
        };

        if (lua_ref) |ref| {
            const exchange = try alloc.create(HttpExchange);
            exchange.* = try HttpExchange.init(alloc, &request, &self.param_cache, &self.query_cache, clean_path);
            try self.dispatchToHandler(ref, exchange, &request, clean_path);
        } else {
            self.logAccess(404);
            self.send404NotFound();
        }
    }

    /// Serialize response from exchange and submit write
    pub fn writeResponse(self: *Connection, exchange: *HttpExchange) !void {
        var response = exchange.toResponse();
        defer response.deinit();
        try self.writeResponseDirect(&response);
    }

    /// Serialize a Response and submit the write completion
    pub fn writeResponseDirect(self: *Connection, response: *http.Response) !void {
        self.state = .writing;
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

    pub fn sendRawResponse(self: *Connection, text: []const u8) void {
        self.state = .writing;
        if (!self.submitTlsAwareSend(text, onWrite, true)) {
            self.close();
        }
    }

    pub fn send400BadRequest(self: *Connection) void {
        error_response.sendError(self, .client_error, "bad request");
    }

    pub fn send500InternalError(self: *Connection) void {
        error_response.sendError(self, .server_error, "internal error");
    }

    fn onWrite(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        const self = castUserdata(Connection, userdata);
        const bytes_written = result.send catch |err| {
            std.log.err("[fd={d}] send failed err={}", .{ self.socket, err });
            self.close();
            return .disarm;
        };
        switch (self.state) {
            .websocket => self.handleWsPostWrite(bytes_written),
            .sse => self.handleSsePostWrite(),
            else => self.handleHttpPostWrite(bytes_written),
        }
        return .disarm;
    }

    /// Post-write handler for WebSocket upgrade: reset arena, consume HTTP bytes,
    /// enter WS frame read loop.
    fn handleWsPostWrite(self: *Connection, bytes_written: usize) void {
        std.debug.assert(self.ws_state != null);
        std.log.debug("ws: 101 sent ({d} bytes written), entering WS mode. raw_len={d} buf_avail_read={d} buf_avail_write={d}", .{
            bytes_written,
            self.request_raw_len,
            self.read_buffer.availableRead(),
            self.read_buffer.availableWrite(),
        });
        _ = self.arena.reset(.retain_capacity);
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
    }

    /// Post-write handler for SSE upgrade: start watching for client disconnect.
    fn handleSsePostWrite(self: *Connection) void {
        std.debug.assert(self.sse_state != null);
        conn_sse.startSseDisconnectWatch(self);
    }

    /// Post-write handler for HTTP responses: reset state for keep-alive,
    /// handle pipelining.
    fn handleHttpPostWrite(self: *Connection, bytes_written: usize) void {
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

        self.state = .reading;

        // If there's leftover data in the buffer (HTTP pipelining), process it now
        if (self.read_buffer.availableRead() > 0) {
            self.sendResponse() catch |err| {
                std.log.err("[fd={d}] pipelined response dispatch failed err={}", .{ self.socket, err });
                self.close();
            };
        } else {
            self.read_buffer.reset();
            self.startRead();
        }
    }

    pub fn close(self: *Connection) void {
        if (self.state == .closing) return;
        self.state = .closing;
        self.deinit(self.base_allocator);
    }
};
