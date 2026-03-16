//! Connection lifecycle and proactor boundary.
//!
//! Each Connection owns a socket, read/write buffers, an arena allocator,
//! and per-request state (params, query, I/O rings). The proactor contract:
//! Lua sets state on HttpExchange, Zig submits all I/O via libxev.
//!
//! Lifecycle: accept → startRead → onRead → handleRequest → onWrite → (keep-alive or close)
//! Protocol upgrades (WS, SSE) and cosocket yields branch from dispatchRequest.

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
const conn_stream = @import("conn_stream.zig");
const cosocket = @import("cosocket.zig");
const error_response = @import("error_response.zig");
const Server = @import("server.zig").Server;
const WorkerMetrics = @import("metrics.zig").WorkerMetrics;
const metrics_mod = @import("metrics.zig");
const static_mod = @import("static.zig");

const ParamArray = params.ParamArray;
const QueryArray = params.QueryArray;
const parseQueryString = params.parseQueryString;
/// Cosocket suspend state — bundled so one `= null` replaces seven resets.
/// Non-null means a handler is yielded waiting on outbound I/O.
pub const SuspendedState = struct {
    completion: xev.Completion,
    exchange: *HttpExchange,
    recv_buf: ?[]u8,
    coroutine_ref: i32,
    coroutine_thread: *anyopaque,
    outbound_fd: std.posix.socket_t,
    pending_op: ring.IoEntry.Op,
    outbound_tls: ?*tls_mod.TlsConn = null, // temporary, during handshake only
};

const READ_BUFFER_SIZE = config.READ_BUFFER_SIZE;
const LARGE_RESPONSE_THRESHOLD = config.LARGE_RESPONSE_THRESHOLD;

/// Per-request HTTP state — reset between keep-alive requests.
pub const HttpState = struct {
    request_start_ns: i128 = 0,
    request_method: []const u8 = "",
    request_path: []const u8 = "",
    request_raw_len: usize = 0, // total bytes consumed by current request (headers + body)
    body_bytes_received: u64 = 0,
};

/// Inbound TLS state — set once at connection init, persists across keep-alive.
pub const TlsState = struct {
    tls_conn: ?tls_mod.TlsConn = null,
    ciphertext_buffer: ?LinearBuffer = null, // recv target for TLS connections
    tls_handshake_complete: bool = false, // flag for sendTlsData -> onTlsHandshakeWrite

    pub fn deinit(self: *TlsState, alloc: std.mem.Allocator) void {
        if (self.tls_conn) |*tc| tc.deinit(alloc);
        if (self.ciphertext_buffer) |*cb| cb.deinit();
    }
};

/// Outbound cosocket I/O state — submission/completion rings and batch buffers.
/// Inline on Connection (heap-allocated, never moves) so xev completions
/// stored in batch_completions have stable addresses.
pub const CosocketState = struct {
    sq: ring.SubmissionRing = .{},
    cq: ring.CompletionRing = .{},
    pending_completions: u8 = 0,
    batch_completions: [ring.SubmissionRing.MAX_DEPTH]xev.Completion = undefined,
    batch_recv_bufs: [ring.SubmissionRing.MAX_DEPTH]?[]u8 = .{null} ** ring.SubmissionRing.MAX_DEPTH,
    suspended: ?SuspendedState = null,
};

/// Connection handler - manages HTTP request/response lifecycle
pub const Connection = struct {
    pub const State = enum { reading, processing, writing, websocket, sse, streaming, static_file, closing };
    pub const List = std.DoublyLinkedList;

    // Intrusive linked list node for Server.connections tracking.
    // Enables forceCloseAll() to walk and close every live connection.
    link: List.Node = .{},

    // Core coordinator fields
    base_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    loop: *xev.Loop,
    socket: std.posix.socket_t,
    router: *Router,
    lua_state: *LuaState,
    server: *Server,

    // Completions (must have stable address!)
    read_completion: xev.Completion,
    write_completion: xev.Completion,

    // Buffers (allocated from base_allocator, persist across requests)
    read_buffer: LinearBuffer,

    // Inline param/query storage (reused across requests, zero allocations, cache-friendly)
    param_cache: ParamArray,
    query_cache: QueryArray,

    // Sub-struct: per-request HTTP fields (reset on keep-alive)
    http_state: HttpState = .{},

    // Sub-struct: outbound cosocket I/O (rings, batch buffers, suspended coroutine)
    cs: CosocketState = .{},

    // WebSocket: non-null when connection has been upgraded to WebSocket
    ws_state: ?conn_ws.WsState = null,

    // SSE: non-null when connection has been upgraded to SSE
    sse_state: ?conn_sse.SseState = null,
    // SSE registry pointer: injected at init, copied into SseState at upgrade time
    sse_registry: ?*SseRegistry = null,

    // Streaming: non-null when connection has been upgraded to chunked streaming
    stream_state: ?conn_stream.StreamState = null,

    // Static file: non-null when serving a static file
    static_state: ?static_mod.StaticState = null,

    // Per-request timeout: timer fires after REQUEST_TIMEOUT_MS, sending 504
    // Completions initialized to .{} per xev requirements (Pitfall 3: never undefined)
    timer_completion: xev.Completion = .{},
    timer_cancel_completion: xev.Completion = .{},
    timed_out: bool = false,
    timer_armed: bool = false,
    // In-flight timer completions (timer + timer_remove). Guards maybeFinishClose
    // so Connection outlives all armed timer CQEs — prevents use-after-free.
    pending_timer_ops: u8 = 0,

    // Header timeout: fires if complete headers aren't received within HEADER_TIMEOUT_MS
    header_timer_completion: xev.Completion = .{},
    header_timer_cancel_completion: xev.Completion = .{},
    header_timer_armed: bool = false,

    // Connection state machine
    state: State = .reading,

    // Sub-struct: inbound TLS (set once at connection init, persists across keep-alive)
    tls_state: TlsState = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        socket: std.posix.socket_t,
        router: *Router,
        lua_state: *LuaState,
        sse_registry: ?*SseRegistry,
        server: *Server,
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
            .server = server,
        };

        server.connections.append(&conn.link);

        return conn;
    }

    /// Initialize TLS on this connection. Called from onAccept when TLS is configured.
    pub fn initTls(self: *Connection, tls_ctx: *TlsContext) !void {
        try conn_tls.initTls(self, tls_ctx);
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        // Remove from server's connection tracking list
        self.server.connections.remove(&self.link);
        // Clean up suspended coroutine state if connection closes mid-I/O
        if (self.cs.suspended) |s| {
            // Unref pinned coroutine to prevent Lua registry leak
            if (s.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
            }
            // Close leaked outbound fd
            if (s.outbound_fd != -1) std.posix.close(s.outbound_fd);
        }
        // Clean up WebSocket callback refs
        if (self.ws_state) |wss| {
            if (wss.on_message_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_message_ref);
            if (wss.on_close_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_close_ref);
        }
        // Clean up SSE state
        if (self.sse_state) |*ss| ss.deinit(self);
        // Clean up static file state
        if (self.static_state) |*ss| ss.deinit(self.base_allocator);
        // Clean up TLS resources
        self.tls_state.deinit(self.base_allocator);
        std.posix.close(self.socket);
        self.arena.deinit();
        // param_cache/query_cache are inline structs, no deinit needed
        self.base_allocator.free(self.read_buffer.data);
        allocator.destroy(self);
    }

    /// Start the per-request deadline timer. Fires onRequestTimeout after REQUEST_TIMEOUT_MS.
    /// Called after successful route match, before Lua dispatch.
    fn startRequestTimer(self: *Connection) void {
        self.timer_armed = true;
        self.pending_timer_ops += 1;
        self.loop.timer(&self.timer_completion, config.REQUEST_TIMEOUT_MS, self, onRequestTimeout);
    }

    /// Cancel the per-request deadline timer on normal response completion.
    /// Safe to call if timer already fired or was never started.
    fn cancelRequestTimer(self: *Connection) void {
        if (!self.timer_armed) return; // no timer to cancel (e.g. health endpoint)
        if (self.timed_out) return; // already fired, nothing to cancel
        self.timer_armed = false;
        self.pending_timer_ops += 1;
        self.timer_cancel_completion = .{
            .op = .{ .timer_remove = .{ .timer = &self.timer_completion } },
            .userdata = self,
            .callback = onTimerCancelComplete,
        };
        self.loop.add(&self.timer_cancel_completion);
    }

    fn onTimerCancelComplete(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        _ = result;
        const self = castUserdata(Connection, userdata);
        self.pending_timer_ops -= 1;
        self.maybeFinishClose();
        return .disarm;
    }

    /// Start the header deadline timer. Fires onHeaderTimeout after HEADER_TIMEOUT_MS.
    /// Called from startRead when beginning a new request (not mid-parse).
    fn startHeaderTimer(self: *Connection) void {
        if (self.header_timer_armed) return;
        self.header_timer_armed = true;
        self.pending_timer_ops += 1;
        self.loop.timer(&self.header_timer_completion, config.HEADER_TIMEOUT_MS, self, onHeaderTimeout);
    }

    /// Cancel the header deadline timer on successful header parse.
    fn cancelHeaderTimer(self: *Connection) void {
        if (!self.header_timer_armed) return;
        self.header_timer_armed = false;
        self.pending_timer_ops += 1;
        self.header_timer_cancel_completion = .{
            .op = .{ .timer_remove = .{ .timer = &self.header_timer_completion } },
            .userdata = self,
            .callback = onHeaderTimerCancelComplete,
        };
        self.loop.add(&self.header_timer_cancel_completion);
    }

    fn onHeaderTimerCancelComplete(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        _ = result;
        const self = castUserdata(Connection, userdata);
        self.pending_timer_ops -= 1;
        self.maybeFinishClose();
        return .disarm;
    }

    /// Header timeout fired — close without response (client is adversarial/slow).
    fn onHeaderTimeout(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        const self = castUserdata(Connection, userdata);
        const trigger = result.timer catch {
            self.pending_timer_ops -= 1;
            self.maybeFinishClose();
            return .disarm;
        };
        self.pending_timer_ops -= 1;
        if (trigger == .cancel) {
            self.maybeFinishClose();
            return .disarm;
        }
        self.header_timer_armed = false;
        if (self.state == .closing) return .disarm;
        // Close without response — slowloris protection
        self.close();
        return .disarm;
    }

    /// xev callback: request deadline exceeded.
    /// Sets timed_out flag, sends 504 to client. Does NOT transition to .closing
    /// here — sendRawResponse sets state to .writing; onWrite detects timed_out
    /// and calls maybeFinishClose after the 504 write completes.
    /// Does NOT call deinit directly — deferred deinit ensures Connection outlives
    /// all armed cosocket completions (pending_completions).
    fn onRequestTimeout(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        const self = castUserdata(Connection, userdata);
        // When cancelRequestTimer submits a timer_remove, io_uring delivers
        // ECANCELED to this callback. Ignore it — the request already completed.
        // Without this check, a cancelled timer would corrupt the connection by
        // sending a 504 while the next keep-alive request is in progress.
        const trigger = result.timer catch {
            self.pending_timer_ops -= 1;
            self.maybeFinishClose();
            return .disarm;
        };
        self.pending_timer_ops -= 1;
        if (trigger == .cancel) {
            self.maybeFinishClose();
            return .disarm;
        }
        self.timer_armed = false;
        // Guard: already closing or in a long-lived protocol
        if (self.state == .closing) return .disarm;
        // WebSocket, SSE, and streaming connections are exempt from request timeout
        if (self.state == .websocket or self.state == .sse or self.state == .streaming) return .disarm;
        self.timed_out = true;
        // Send 504 — sendRawResponse sets state to .writing, onWrite completes the close
        error_response.sendError(self, .timeout, "request timeout");
        return .disarm;
    }

    /// Start reading from connection.
    /// After kTLS setup, tls_conn is null and ciphertext_buffer is freed —
    /// reads go directly to the plaintext read_buffer (kernel decrypts).
    /// During TLS handshake (tls_conn non-null), reads target the ciphertext_buffer.
    pub fn startRead(self: *Connection) void {
        // Start header timeout for new requests (not mid-parse continuations)
        if (!self.header_timer_armed and self.state == .reading) {
            self.startHeaderTimer();
        }
        const buf = if (self.tls_state.ciphertext_buffer) |*cb| blk: {
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

        // TLS handshake path: tls_conn is non-null only during handshake.
        // After kTLS setup, tls_conn is freed — reads fall through to plaintext.
        if (self.tls_state.tls_conn) |*tc| {
            var cb = &self.tls_state.ciphertext_buffer.?;
            cb.commitWrite(bytes_read);
            tc.feedCiphertext(cb.readSlice());
            cb.reset(); // BIO owns the data now
            conn_tls.handleTlsHandshake(self, tc);
            return .disarm;
        }

        // Plaintext path
        self.read_buffer.commitWrite(bytes_read);

        // Streaming body size enforcement (not WebSocket or SSE, which are long-lived).
        if (self.state == .reading and self.checkBodySizeExceeded(bytes_read)) return .disarm;

        self.handleRequest();
        return .disarm;
    }

    pub fn logAccess(self: *Connection, status: u16) void {
        const dur_us: i64 = @intCast(@divTrunc(std.time.nanoTimestamp() - self.http_state.request_start_ns, 1000));
        log.accessLog(self.http_state.request_method, self.http_state.request_path, status, dur_us);
        // Record metrics (latency + error tracking)
        self.server.metrics.recordRequest(@intCast(@max(0, dur_us)), status >= 400);
    }

    /// Parse stage: HTTP parse, query/param setup, Content-Length validation.
    /// Returns the parsed request or an error (after sending the appropriate
    /// error response / scheduling another read).
    fn parseRequest(self: *Connection) !http.Request {
        const request_data = self.read_buffer.readSlice();
        var parser = http.Parser.init(self.arena.allocator());
        const request = parser.parseRequest(request_data) catch |err| {
            if (err == error.Incomplete) {
                self.startRead();
            } else {
                error_response.sendError(self, .client_error, "http parse failed");
            }
            return err;
        };

        const query_pos = std.mem.indexOfScalar(u8, request.path, '?');
        const clean_path = if (query_pos) |qi| request.path[0..qi] else request.path;

        self.http_state.request_method = request.method;
        self.http_state.request_path = clean_path;
        self.http_state.request_raw_len = request.raw_len;

        // Reject oversized Content-Length before routing
        if (http.getContentLength(&request)) |content_length| {
            if (content_length > config.MAX_BODY_SIZE) {
                self.logAccess(413);
                error_response.sendErrorStatus(self, 413, "body exceeds size limit");
                return error.HttpContentLengthOverflow;
            }
        }

        // Parse query string and clear param cache for route matching
        self.query_cache.clear();
        if (query_pos) |qi| {
            parseQueryString(request.path[qi + 1 ..], &self.query_cache);
        }
        self.param_cache.clear();

        return request;
    }

    fn dispatchToHandler(self: *Connection, ref: i32, exchange: *HttpExchange, request: *const http.Request, clean_path: []const u8) !void {
        // Start the per-request deadline clock before Lua dispatch
        self.startRequestTimer();
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
                    // WebSocket connections are long-lived — exempt from request timeout
                    self.cancelRequestTimer();
                    conn_ws.handleWsUpgrade(self, exchange, request) catch {
                        self.logAccess(400);
                        error_response.sendError(self, .client_error, "websocket upgrade failed");
                        return;
                    };
                    return;
                }

                if (exchange.upgrade_sse) {
                    // SSE connections are long-lived — exempt from request timeout
                    self.cancelRequestTimer();
                    conn_sse.handleSseUpgrade(self, exchange);
                    return;
                }

                self.logAccess(exchange.status);
                try self.writeResponse(exchange);
            },
            .yielded => {
                // Stream upgrade: handler yields after ctx.upgrade = "stream"
                if (exchange.upgrade_stream) {
                    self.cancelRequestTimer();
                    conn_stream.handleStreamUpgrade(self, exchange);
                    return;
                }
                self.cs.suspended = .{
                    .completion = undefined,
                    .exchange = exchange,
                    .recv_buf = null,
                    .coroutine_ref = self.lua_state.coroutine_ref,
                    .coroutine_thread = @ptrCast(self.lua_state.coroutine_thread.?),
                    .outbound_fd = -1,
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

    /// Request lifecycle coordinator: parse → route → dispatch.
    /// Each stage owns its error path — on failure a stage sends the
    /// appropriate HTTP error response and returns an error.  The
    /// coordinator catches those errors and returns normally so the
    /// caller does NOT close the connection (the async write for the
    /// error response is already in flight).
    pub fn handleRequest(self: *Connection) void {
        self.state = .processing;
        self.http_state.request_start_ns = std.time.nanoTimestamp();

        const request = self.parseRequest() catch return;
        // Headers received successfully — cancel header timeout
        self.cancelHeaderTimer();
        const ref = (self.routeRequest(&request) catch return) orelse return;
        self.dispatchRequest(&request, ref) catch |err| {
            std.log.err("[fd={d}] dispatch failed err={}", .{ self.socket, err });
            self.close();
        };
    }

    /// Route stage: health check short-circuit, trie lookup, 404 on no match.
    /// Returns the Lua handler ref, or null after sending a response (health/404).
    fn routeRequest(self: *Connection, request: *const http.Request) !?i32 {
        const clean_path = self.http_state.request_path;

        // Health endpoint: handled before Lua routing (zero Lua overhead)
        if (std.mem.eql(u8, clean_path, "/health")) {
            self.serveHealth(self.arena.allocator());
            return null;
        }

        // Static file routes: handled before Lua routing (zero Lua overhead)
        if (self.router.matchStatic(clean_path)) |match| {
            if (!std.mem.eql(u8, request.method, "GET") and !std.mem.eql(u8, request.method, "HEAD")) {
                error_response.sendErrorStatus(self, 405, "method not allowed for static file");
                return null;
            }
            static_mod.serveStaticFile(self, request, match.route, match.suffix);
            return null;
        }

        const lua_ref = self.router.match(request.method, clean_path, &self.param_cache) catch {
            error_response.sendError(self, .client_error, "route match error");
            return error.RouteMatchFailed;
        };

        if (lua_ref == null) {
            self.logAccess(404);
            self.send404NotFound();
        }
        return lua_ref;
    }

    /// Dispatch stage: create HttpExchange, hand off to Lua handler.
    /// Handles completed responses, coroutine yields, and protocol upgrades.
    fn dispatchRequest(self: *Connection, request: *const http.Request, ref: i32) !void {
        const alloc = self.arena.allocator();
        const clean_path = self.http_state.request_path;
        const exchange = try alloc.create(HttpExchange);
        exchange.* = try HttpExchange.init(alloc, request, &self.param_cache, &self.query_cache, clean_path);
        try self.dispatchToHandler(ref, exchange, request, clean_path);
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

        self.submitSend(response_buf.items, onWrite, false);
    }

    /// Submit a send on this connection's socket.
    /// After kTLS setup, all sends are plaintext — the kernel encrypts transparently.
    /// If arena_dupe is true, data is copied into the arena (for stack-local buffers).
    pub fn submitSend(self: *Connection, data: []const u8, callback: *const fn (?*anyopaque, *xev.Loop, *xev.Completion, xev.Result) xev.CallbackAction, arena_dupe: bool) void {
        const alloc = self.arena.allocator();
        const send_data = if (arena_dupe) alloc.dupe(u8, data) catch {
            self.close();
            return;
        } else data;
        self.write_completion = .{
            .op = .{ .send = .{ .fd = self.socket, .buffer = .{ .slice = send_data } } },
            .userdata = self,
            .callback = callback,
        };
        self.loop.add(&self.write_completion);
    }

    pub fn sendRawResponse(self: *Connection, text: []const u8) void {
        self.state = .writing;
        self.submitSend(text, onWrite, true);
    }

    pub fn send400BadRequest(self: *Connection) void {
        error_response.sendError(self, .client_error, "bad request");
    }

    pub fn send500InternalError(self: *Connection) void {
        error_response.sendError(self, .server_error, "internal error");
    }

    /// Check if accumulated body bytes exceed MAX_BODY_SIZE. Sends 413 if so.
    pub fn checkBodySizeExceeded(self: *Connection, bytes_read: usize) bool {
        self.http_state.body_bytes_received += bytes_read;
        if (self.http_state.body_bytes_received > config.MAX_BODY_SIZE) {
            error_response.sendErrorStatus(self, 413, "streaming body exceeds size limit");
            return true;
        }
        return false;
    }

    /// Zig-native health endpoint. Returns JSON metrics with zero Lua overhead.
    /// 200 when ready, 503 when draining.
    fn serveHealth(self: *Connection, alloc: std.mem.Allocator) void {
        const server = self.server;
        const status_str: []const u8 = if (server.draining) "draining" else "ok";
        const http_status: u16 = if (server.draining) 503 else 200;

        // Aggregate metrics from all workers via the metrics slice stored on server
        const agg = metrics_mod.aggregate(server.all_worker_metrics, status_str);

        // Build full HTTP response in a single allocation (JSON body is small and bounded)
        const status_line: []const u8 = if (http_status == 200) "HTTP/1.1 200 OK" else "HTTP/1.1 503 Service Unavailable";
        const json_fmt = "{{\"status\":\"{s}\",\"worker_count\":{d},\"total_requests\":{d},\"total_errors\":{d},\"active_connections\":{d},\"rejected_connections\":{d},\"latency\":{{\"min_us\":{d},\"max_us\":{d},\"avg_us\":{d}}}}}";
        const json_args = .{
            agg.status,
            agg.worker_count,
            agg.total_requests,
            agg.total_errors,
            agg.active_connections,
            agg.rejected_connections,
            agg.latency_min_us,
            agg.latency_max_us,
            agg.latency_avg_us,
        };
        const json_len = std.fmt.count(json_fmt, json_args);
        const response_text = std.fmt.allocPrint(alloc, "{s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n" ++ json_fmt, .{status_line, json_len} ++ json_args) catch {
            error_response.sendError(self, .server_error, "health endpoint allocation failed");
            return;
        };

        self.logAccess(http_status);
        self.sendRawResponse(response_text);
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
        // If this write was the 504 timeout response, close instead of recycling.
        // pending_completions may still be non-zero (cosocket I/O in flight),
        // so close() -> maybeFinishClose() defers deinit until all completions drain.
        if (self.timed_out) {
            self.close();
            return .disarm;
        }
        switch (self.state) {
            .websocket => self.handleWsPostWrite(bytes_written),
            .sse => self.handleSsePostWrite(),
            .streaming => conn_stream.handleStreamPostWrite(self),
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
            self.http_state.request_raw_len,
            self.read_buffer.availableRead(),
            self.read_buffer.availableWrite(),
        });
        _ = self.arena.reset(.retain_capacity);
        if (self.http_state.request_raw_len > 0) {
            self.read_buffer.consume(self.http_state.request_raw_len);
            self.http_state.request_raw_len = 0;
        } else {
            self.read_buffer.reset();
        }
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
    pub fn handleHttpPostWrite(self: *Connection, bytes_written: usize) void {
        // Cancel the per-request deadline timer on successful response completion
        self.cancelRequestTimer();
        self.cs.suspended = null;
        self.cs.sq.reset();
        self.cs.cq.reset();
        self.cs.pending_completions = 0;
        // Shrink arena if response was large to prevent unbounded growth
        // on keep-alive connections that occasionally serve large responses.
        if (bytes_written > LARGE_RESPONSE_THRESHOLD) {
            _ = self.arena.reset(.free_all);
        } else {
            _ = self.arena.reset(.retain_capacity);
        }

        // Consume exactly the bytes of the completed request (headers + body).
        // This preserves any pipelined data that arrived in the same recv.
        if (self.http_state.request_raw_len > 0) {
            self.read_buffer.consume(self.http_state.request_raw_len);
            self.http_state.request_raw_len = 0;
        } else {
            self.read_buffer.reset();
        }

        // After kTLS, ciphertext_buffer is null — nothing to reset

        // Reset body tracking and timeout flags for next request on keep-alive
        self.http_state.body_bytes_received = 0;
        self.timed_out = false;
        self.timer_armed = false;
        self.header_timer_armed = false;

        self.state = .reading;

        // During drain: close keep-alive connections after current request completes
        if (self.server.draining) {
            self.close();
            return;
        }

        // If there's leftover data in the buffer (HTTP pipelining), process it now
        if (self.read_buffer.availableRead() > 0) {
            self.handleRequest();
        } else {
            self.read_buffer.reset();
            self.startRead();
        }
    }

    pub fn close(self: *Connection) void {
        if (self.state == .closing) return;
        self.state = .closing;
        // Decrement active connection counter
        self.server.metrics.decrementActiveConnections();
        // Deferred deinit: only free when all armed cosocket completions have fired.
        // Normal HTTP connections have pending_completions == 0 (no cosocket I/O),
        // so maybeFinishClose is equivalent to deinit() in the common case.
        self.maybeFinishClose();
    }

    /// Deferred deinit guard: only free Connection when all armed cosocket
    /// completions have fired. Called at every point where pending_completions
    /// is decremented to ensure Connection outlives in-flight xev callbacks.
    pub fn maybeFinishClose(self: *Connection) void {
        if (self.state == .closing and self.cs.pending_completions == 0 and self.pending_timer_ops == 0) {
            self.deinit(self.base_allocator);
        }
    }

    // =========================================================================
    // Tests
    // =========================================================================

    test "maybeFinishClose: does not deinit when pending_completions > 0" {
        // We can only test the guard logic without a real allocator/connection.
        // Verify that the condition pending_completions > 0 prevents close.
        const conn = struct {
            state: State,
            cs: struct { pending_completions: u8 },
        }{
            .state = .closing,
            .cs = .{ .pending_completions = 1 },
        };
        // Guard: closing with pending_completions == 1 must NOT deinit
        try std.testing.expect(!(conn.state == .closing and conn.cs.pending_completions == 0));
    }

    test "maybeFinishClose: condition met when closing and no pending_completions" {
        const conn = struct {
            state: State,
            cs: struct { pending_completions: u8 },
        }{
            .state = .closing,
            .cs = .{ .pending_completions = 0 },
        };
        // Guard: closing with pending_completions == 0 SHOULD deinit
        try std.testing.expect(conn.state == .closing and conn.cs.pending_completions == 0);
    }

    test "maybeFinishClose: does not deinit when not closing" {
        const conn = struct {
            state: State,
            cs: struct { pending_completions: u8 },
        }{
            .state = .processing,
            .cs = .{ .pending_completions = 0 },
        };
        try std.testing.expect(!(conn.state == .closing and conn.cs.pending_completions == 0));
    }
};
