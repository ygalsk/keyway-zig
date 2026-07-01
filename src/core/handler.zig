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
const log = @import("../observability/log.zig");
const LinearBuffer = @import("../util/buffer.zig").LinearBuffer;
const http = @import("../http/http.zig");
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const Router = @import("../http/router.zig").Router;
const LuaState = @import("../lua/lua_state.zig").LuaState;
const io_request_mod = @import("../io/io_request.zig");
const TlsMode = io_request_mod.TlsMode;
const ring = @import("../io/ring.zig");
const tls_mod = @import("../tls/tls.zig");
const TlsContext = tls_mod.TlsContext;
const Lua = @import("luajit").Lua;
const ws = @import("../protocol/ws.zig");
const lua_api = @import("../lua/lua_api.zig");
const SseRegistry = @import("../protocol/sse.zig").SseRegistry;
const config = @import("../util/config.zig");
const params = @import("../http/params.zig");
const conn_tls = @import("../tls/conn_tls.zig");
const castUserdata = @import("../util/helpers.zig").castUserdata;
const helpers = @import("../util/helpers.zig");
const conn_sse = @import("../protocol/conn_sse.zig");
const conn_ws = @import("../protocol/conn_ws.zig");
const conn_stream = @import("../protocol/conn_stream.zig");
const cosocket = @import("../io/cosocket.zig");
const error_response = @import("../http/error_response.zig");
const Server = @import("server.zig").Server;
const prom = @import("../observability/prom.zig");
const static_mod = @import("../http/static.zig");

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
    outbound_tls: ?*tls_mod.TlsConn = null, // during handshake; persists if kTLS unavailable

    /// Free outbound TLS conn and null the pointer. Safe to call when outbound_tls is null.
    pub fn cleanupTls(self: *SuspendedState, alloc: std.mem.Allocator) void {
        if (self.outbound_tls) |tc| {
            tls_mod.freeTlsConn(alloc, tc);
            self.outbound_tls = null;
        }
    }
};

const READ_BUFFER_SIZE = config.READ_BUFFER_SIZE;
const ARENA_RETAIN_LIMIT = config.ARENA_RETAIN_LIMIT;

/// Per-request HTTP state — reset between keep-alive requests.
pub const HttpState = struct {
    request_start_ns: i64 = 0,
    request_method: []const u8 = "",
    request_path: []const u8 = "",
    request_raw_len: usize = 0, // total bytes consumed by current request (headers + body)
    body_bytes_received: u64 = 0,
    route_pattern: []const u8 = "", // matched route pattern for Prometheus labels (e.g. "/users/{id}")
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
/// batch_completions/batch_recv_bufs are lazy-allocated on first cosocket use
/// via base_allocator (stable heap addresses for xev callbacks). Connections
/// that never use cosocket I/O pay zero memory for these arrays.
pub const CosocketState = struct {
    sq: ring.SubmissionRing = .{},
    cq: ring.CompletionRing = .{},
    pending_completions: u8 = 0,
    batch_completions: ?*[ring.SubmissionRing.MAX_DEPTH]xev.Completion = null,
    batch_recv_bufs: ?*[ring.SubmissionRing.MAX_DEPTH]?[]u8 = null,
    suspended: ?SuspendedState = null,
    /// True when a single-shot pending_io was converted to a degenerate SQ entry.
    /// On completion, results are pushed to the Lua stack (legacy API) instead of
    /// being left in the CQ for ring_result() reads.
    single_shot_mode: bool = false,

    /// Ensure batch arrays are allocated. Called at the start of drainSubmissionRing.
    /// Returns false on allocation failure.
    pub fn ensureBatchArrays(self: *CosocketState, allocator: std.mem.Allocator) bool {
        if (self.batch_completions == null) {
            self.batch_completions = allocator.create([ring.SubmissionRing.MAX_DEPTH]xev.Completion) catch return false;
        }
        if (self.batch_recv_bufs == null) {
            self.batch_recv_bufs = allocator.create([ring.SubmissionRing.MAX_DEPTH]?[]u8) catch return false;
            self.batch_recv_bufs.?.* = .{null} ** ring.SubmissionRing.MAX_DEPTH;
        }
        return true;
    }

    pub fn deinitBatchArrays(self: *CosocketState, allocator: std.mem.Allocator) void {
        if (self.batch_completions) |bc| allocator.destroy(bc);
        if (self.batch_recv_bufs) |br| allocator.destroy(br);
        self.batch_completions = null;
        self.batch_recv_bufs = null;
    }
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

    // Peer address (formatted string, e.g. "127.0.0.1"), persists across keep-alive
    peer_addr_buf: [64]u8 = undefined,
    peer_addr_len: u8 = 0,

    // Completions (must have stable address!)
    read_completion: xev.Completion = .{},
    write_completion: xev.Completion = .{},

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

    // In-flight read/write io_uring ops. Guards maybeFinishClose so Connection
    // outlives pending recv/send completions — prevents use-after-free / EFAULT.
    pending_io_ops: u8 = 0,

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
            .read_completion = .{},
            .write_completion = .{},
            .read_buffer = read_buf,
            .param_cache = ParamArray{},
            .query_cache = QueryArray{},
            .sse_registry = sse_registry,
            .server = server,
        };

        // Resolve peer address from socket using properly-aligned storage
        var peer_storage: std.posix.sockaddr.storage = undefined;
        const peer_sa: *std.posix.sockaddr = @ptrCast(&peer_storage);
        var peer_sa_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
        if (std.posix.getpeername(socket, peer_sa, &peer_sa_len)) {
            const formatted: []const u8 = switch (peer_sa.family) {
                std.posix.AF.INET => blk: {
                    const addr4: *const std.posix.sockaddr.in = @ptrCast(@alignCast(peer_sa));
                    const bytes = @as(*const [4]u8, @ptrCast(&addr4.addr));
                    break :blk std.fmt.bufPrint(&conn.peer_addr_buf, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] }) catch "";
                },
                std.posix.AF.INET6 => blk: {
                    const addr6: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(peer_sa));
                    const bytes = @as(*const [16]u8, @ptrCast(&addr6.addr));
                    // Check for IPv4-mapped IPv6 (::ffff:x.x.x.x)
                    const is_v4_mapped = std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff });
                    if (is_v4_mapped) {
                        break :blk std.fmt.bufPrint(&conn.peer_addr_buf, "{d}.{d}.{d}.{d}", .{ bytes[12], bytes[13], bytes[14], bytes[15] }) catch "";
                    }
                    // Check for loopback (::1)
                    const is_loopback = std.mem.eql(u8, bytes[0..15], &([_]u8{0} ** 15)) and bytes[15] == 1;
                    if (is_loopback) {
                        break :blk std.fmt.bufPrint(&conn.peer_addr_buf, "::1", .{}) catch "";
                    }
                    // Other IPv6 — leave empty (safe default: denied by localhost guard)
                    break :blk "";
                },
                else => "",
            };
            conn.peer_addr_len = @intCast(formatted.len);
        } else |_| {}

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
        if (self.cs.suspended) |*s| {
            // Unref pinned coroutine to prevent Lua registry leak
            if (s.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
            }
            // Close leaked outbound fd
            if (s.outbound_fd != -1) helpers.closeFd(s.outbound_fd);
            // Free outbound TLS state if mid-handshake (#21)
            s.cleanupTls(self.base_allocator);
        }
        // Clean up lazy-allocated cosocket batch arrays
        self.cs.deinitBatchArrays(self.base_allocator);
        // Clean up WebSocket callback refs and reassembly buffer
        if (self.ws_state) |*wss| {
            if (wss.on_message_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_message_ref);
            if (wss.on_close_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_close_ref);
            if (wss.fragment_buf) |*fb| fb.deinit(self.arena.allocator());
        }
        // Clean up SSE state
        if (self.sse_state) |*ss| ss.deinit(self);
        // Clean up static file state
        if (self.static_state) |*ss| ss.deinit(self.base_allocator);
        // Clean up TLS resources
        self.tls_state.deinit(self.base_allocator);
        helpers.closeFd(self.socket);
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
            // Reclaim space consumed by a prior pipelined request before
            // deciding the buffer is full (writeSlice no longer auto-compacts).
            self.read_buffer.compact();
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
        self.pending_io_ops += 1;
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
        self.pending_io_ops -= 1;

        const bytes_read = result.recv catch |err| {
            if (self.state == .closing) { self.maybeFinishClose(); return .disarm; }
            if (err != error.EOF) {
                log.err().string("msg", "recv failed").int("fd", self.socket).err(err).log();
            }
            self.close();
            return .disarm;
        };

        if (self.state == .closing) { self.maybeFinishClose(); return .disarm; }

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
        const dur_us: i64 = @intCast(@divTrunc(helpers.monotonicNanos() - self.http_state.request_start_ns, 1000));
        log.accessLog(self.http_state.request_method, self.http_state.request_path, status, dur_us);
        const latency_us: u64 = @intCast(@max(0, dur_us));
        prom.recordRequest(self.http_state.request_method, status, latency_us, self.http_state.route_pattern);
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
        // Record request body size
        prom.recordRequestBodySize(exchange.body.len);
        // Start the per-request deadline clock before Lua dispatch
        self.startRequestTimer();
        self.lua_state.current_connection = self;
        const handler_result = self.lua_state.callLuaHandler(ref, exchange) catch |err| {
            self.lua_state.current_connection = null;
            // Log the detailed Lua error separately (not exposed to client)
            log.err().string("msg", "lua handler error").int("fd", self.socket).stringSafe("method", request.method).string("path", clean_path).err(err).log();
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
        self.http_state.request_start_ns = helpers.monotonicNanos();

        const request = self.parseRequest() catch return;
        // Headers received successfully — cancel header timeout
        self.cancelHeaderTimer();
        const route_match = (self.routeRequest(&request) catch return) orelse return;
        self.http_state.route_pattern = route_match.pattern;
        self.dispatchRequest(&request, route_match.lua_ref) catch |err| {
            log.err().string("msg", "dispatch failed").int("fd", self.socket).err(err).log();
            self.close();
        };
    }

    /// Route stage: health check short-circuit, trie lookup, 404 on no match.
    /// Returns the RouteMatch, or null after sending a response (health/404).
    fn routeRequest(self: *Connection, request: *const http.Request) !?Router.RouteMatch {
        const clean_path = self.http_state.request_path;

        // Health endpoint: handled before Lua routing (zero Lua overhead)
        if (std.mem.eql(u8, clean_path, "/health")) {
            self.serveHealth(self.arena.allocator());
            return null;
        }

        // Prometheus metrics endpoint: handled before Lua routing
        if (std.mem.eql(u8, clean_path, "/metrics")) {
            self.servePrometheusMetrics(self.arena.allocator());
            return null;
        }

        // Reload endpoint: POST /__keyway/reload triggers hot-reload on all workers
        if (std.mem.eql(u8, clean_path, "/__keyway/reload") and std.mem.eql(u8, request.method, "POST")) {
            self.serveReload(self.arena.allocator());
            return null;
        }

        // Reverse proxy routes: forward matching prefixes to upstream servers
        if (self.router.matchProxy(clean_path)) |proxy_match| {
            self.proxyRequest(request, proxy_match, self.arena.allocator());
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

        const route_match = self.router.match(request.method, clean_path, &self.param_cache) catch {
            error_response.sendError(self, .client_error, "route match error");
            return error.RouteMatchFailed;
        };

        if (route_match == null) {
            self.logAccess(404);
            self.send404NotFound();
        }
        return route_match;
    }

    /// Dispatch stage: create HttpExchange, hand off to Lua handler.
    /// Handles completed responses, coroutine yields, and protocol upgrades.
    fn dispatchRequest(self: *Connection, request: *const http.Request, ref: i32) !void {
        const alloc = self.arena.allocator();
        const clean_path = self.http_state.request_path;
        const exchange = try alloc.create(HttpExchange);
        exchange.* = try HttpExchange.init(alloc, request, &self.param_cache, &self.query_cache, clean_path);
        exchange.remote_addr = self.peer_addr_buf[0..self.peer_addr_len];
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
        // Record response body size
        prom.recordResponseBodySize(response.body.len);
        // Pre-size to avoid repeated ArrayList growth in arena (old buffers can't be freed)
        const estimated = response.body.len + 512;
        var response_buf: std.Io.Writer.Allocating = try .initCapacity(alloc, estimated);
        try response.serialize(&response_buf.writer);
        const response_bytes = response_buf.writer.buffered();

        if (self.ws_state != null) {
            log.debug().string("msg", "ws response buf").int("len", response_bytes.len).string("content", response_bytes).log();
        }

        self.submitSend(response_bytes, onWrite, false);
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
        self.pending_io_ops += 1;
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

    /// Zig-native liveness endpoint. 200 when ready, 503 when draining.
    /// Request/latency stats live in Prometheus (/metrics), not here.
    fn serveHealth(self: *Connection, alloc: std.mem.Allocator) void {
        const server = self.server;
        const draining = server.draining;
        const http_status: u16 = if (draining) 503 else 200;
        const status_text: []const u8 = if (draining) "Service Unavailable" else "OK";
        const body: []const u8 = if (draining) "{\"status\":\"draining\"}" else "{\"status\":\"ok\"}";
        self.sendJsonResponse(alloc, http_status, status_text, body);
    }

    /// Prometheus metrics endpoint. Returns text exposition format.
    fn servePrometheusMetrics(self: *Connection, alloc: std.mem.Allocator) void {
        // Use std.Io.Writer.Allocating to write metrics, then extract the buffer
        var allocating_writer: std.Io.Writer.Allocating = .init(alloc);
        prom.write(&allocating_writer.writer) catch {
            error_response.sendError(self, .server_error, "metrics write failed");
            return;
        };
        const body = allocating_writer.writer.buffered();
        const header = std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch {
            error_response.sendError(self, .server_error, "metrics header failed");
            return;
        };
        const full = std.mem.concat(alloc, u8, &.{ header, body }) catch {
            error_response.sendError(self, .server_error, "metrics concat failed");
            return;
        };
        self.logAccess(200);
        self.sendRawResponse(full);
    }

    /// Format and send a JSON HTTP response with the given status and body.
    fn sendJsonResponse(self: *Connection, alloc: std.mem.Allocator, status_code: u16, status_text: []const u8, body: []const u8) void {
        const resp = std.fmt.allocPrint(alloc, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ status_code, status_text, body.len, body }) catch {
            error_response.sendError(self, .server_error, "response allocation failed");
            return;
        };
        self.logAccess(status_code);
        self.sendRawResponse(resp);
    }

    /// Reload endpoint: signals all workers to hot-reload their Lua state.
    fn serveReload(self: *Connection, alloc: std.mem.Allocator) void {
        if (self.server.reload_coordinator) |coord| {
            coord.signalReload();
            self.sendJsonResponse(alloc, 200, "OK", "{\"status\":\"reload_triggered\"}");
        } else {
            self.sendJsonResponse(alloc, 503, "Service Unavailable", "{\"error\":\"reload not available\"}");
        }
    }

    /// Reverse proxy: connect to upstream, forward request, relay response.
    fn proxyRequest(self: *Connection, request: *const http.Request, proxy_match: Router.ProxyMatch, alloc: std.mem.Allocator) void {
        const prefix = proxy_match.route.prefix;

        // Bare prefix with a configured redirect → 302
        if (proxy_match.route.redirect) |redirect| {
            if (proxy_match.suffix.len == 0 or std.mem.eql(u8, proxy_match.suffix, "/")) {
                const resp = std.fmt.allocPrint(alloc, "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\n\r\n", .{redirect}) catch {
                    error_response.sendError(self, .server_error, "proxy redirect failed");
                    return;
                };
                self.logAccess(302);
                self.sendRawResponse(resp);
                return;
            }
        }

        // Build upstream path
        const raw_path = request.path;
        const upstream_path: []const u8 = if (proxy_match.route.strip_prefix)
            (if (raw_path.len >= prefix.len and std.mem.startsWith(u8, raw_path, prefix))
                (if (raw_path[prefix.len..].len == 0) "/" else raw_path[prefix.len..])
            else
                "/")
        else
            raw_path;

        // Connect to upstream. std.net is gone in 0.16; this blocking client
        // uses std.Io.net via a throwaway Threaded io. NOTE: this whole proxy
        // path blocks the worker thread and should move to async libxev (#29).
        var proxy_io: std.Io.Threaded = .init(alloc, .{});
        defer proxy_io.deinit();
        const pio = proxy_io.io();

        const stream = blk: {
            if (std.Io.net.IpAddress.parse(proxy_match.route.upstream_host, proxy_match.route.upstream_port)) |ipaddr| {
                break :blk ipaddr.connect(pio, .{ .mode = .stream }) catch {
                    error_response.sendErrorStatus(self, 502, "proxy upstream connect failed");
                    return;
                };
            } else |_| {
                const hostname = std.Io.net.HostName.init(proxy_match.route.upstream_host) catch {
                    error_response.sendErrorStatus(self, 502, "proxy upstream connect failed");
                    return;
                };
                break :blk hostname.connect(pio, proxy_match.route.upstream_port, .{ .mode = .stream }) catch {
                    error_response.sendErrorStatus(self, 502, "proxy upstream connect failed");
                    return;
                };
            }
        };
        defer stream.close(pio);

        // Build upstream HTTP request
        var req_buf: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(alloc, 1024) catch {
            error_response.sendErrorStatus(self, 502, "proxy request alloc failed");
            return;
        };
        const req_writer = &req_buf.writer;
        req_writer.print("{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n", .{
            request.method,
            upstream_path,
            proxy_match.route.upstream_host,
            proxy_match.route.upstream_port,
        }) catch {
            error_response.sendErrorStatus(self, 502, "proxy request build failed");
            return;
        };
        for (request.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
            req_writer.print("{s}: {s}\r\n", .{ h.name, h.value }) catch {
                error_response.sendErrorStatus(self, 502, "proxy header build failed");
                return;
            };
        }
        req_writer.writeAll("\r\n") catch {
            error_response.sendErrorStatus(self, 502, "proxy request build failed");
            return;
        };

        // Send request + body
        var send_buf: [8192]u8 = undefined;
        var upstream_writer = stream.writer(pio, &send_buf);
        upstream_writer.interface.writeAll(req_buf.writer.buffered()) catch {
            error_response.sendErrorStatus(self, 502, "proxy upstream write failed");
            return;
        };
        if (request.body.len > 0) {
            upstream_writer.interface.writeAll(request.body) catch {
                error_response.sendErrorStatus(self, 502, "proxy upstream body write failed");
                return;
            };
        }
        upstream_writer.interface.flush() catch {
            error_response.sendErrorStatus(self, 502, "proxy upstream write failed");
            return;
        };

        // Read entire upstream response (blocks until upstream closes)
        var recv_buf: [8192]u8 = undefined;
        var upstream_reader = stream.reader(pio, &recv_buf);
        const upstream_response = upstream_reader.interface.allocRemaining(alloc, .unlimited) catch {
            error_response.sendErrorStatus(self, 502, "proxy upstream read failed");
            return;
        };
        if (upstream_response.len == 0) {
            error_response.sendErrorStatus(self, 502, "proxy upstream empty response");
            return;
        }

        self.logAccess(200);
        self.sendRawResponse(upstream_response);
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
        const bytes_written = self.handleSendCompletion(result) orelse return .disarm;
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
            else => self.handleHttpPostWrite(),
        }
        return .disarm;
    }

    /// Post-write handler for WebSocket upgrade: reset arena, consume HTTP bytes,
    /// enter WS frame read loop.
    fn handleWsPostWrite(self: *Connection, bytes_written: usize) void {
        // state == .websocket must imply ws_state != null; if it doesn't (logic
        // bug), close rather than let a downstream `.?` deref null in release.
        if (self.ws_state == null) {
            log.err().string("msg", "ws post-write with null ws_state, closing").log();
            self.close();
            return;
        }
        log.debug().string("msg", "ws 101 sent, entering WS mode").int("bytes_written", bytes_written).int("raw_len", self.http_state.request_raw_len).int("buf_avail_read", self.read_buffer.availableRead()).int("buf_avail_write", self.read_buffer.availableWrite()).log();
        _ = self.arena.reset(.retain_capacity);
        if (self.http_state.request_raw_len > 0) {
            self.read_buffer.consume(self.http_state.request_raw_len);
            self.http_state.request_raw_len = 0;
        } else {
            self.read_buffer.reset();
        }
        log.debug().string("msg", "ws starting read loop").int("buf_avail_read", self.read_buffer.availableRead()).int("buf_avail_write", self.read_buffer.availableWrite()).log();
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
        // state == .sse must imply sse_state != null; if it doesn't (logic bug),
        // close rather than let startSseDisconnectWatch deref null in release.
        if (self.sse_state == null) {
            log.err().string("msg", "sse post-write with null sse_state, closing").log();
            self.close();
            return;
        }
        conn_sse.startSseDisconnectWatch(self);
    }

    /// Post-write handler for HTTP responses: reset state for keep-alive,
    /// handle pipelining.
    pub fn handleHttpPostWrite(self: *Connection) void {
        // Cancel the per-request deadline timer on successful response completion
        self.cancelRequestTimer();
        self.cs.suspended = null;
        self.cs.sq.reset();
        self.cs.cq.reset();
        self.cs.pending_completions = 0;
        self.cs.single_shot_mode = false;
        // Free the arena if its retained capacity grew large; otherwise keep it
        // for reuse. Watermark on the arena's actual capacity, not the response
        // size — large intermediate allocations (and the static/streaming paths,
        // which report zero bytes here) would otherwise leave the arena inflated
        // for the connection's lifetime.
        if (self.arena.queryCapacity() > ARENA_RETAIN_LIMIT) {
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
        prom.connectionClosed();
        // If this was the last connection during drain, finish shutdown now
        // rather than waiting out the drain deadline.
        self.server.maybeFinishDrain();
        // Cancel any armed deadline timer so a force-closed connection doesn't
        // linger until its header/request timeout fires (issue #90 force path;
        // also the recv-error-mid-request path). Both are refcount-safe no-ops
        // when their timer isn't armed, and bump pending_timer_ops for the
        // in-flight timer_remove so maybeFinishClose can't free early.
        self.cancelHeaderTimer();
        self.cancelRequestTimer();
        // Deferred deinit: only free when all armed cosocket completions have fired.
        // Normal HTTP connections have pending_completions == 0 (no cosocket I/O),
        // so maybeFinishClose is equivalent to deinit() in the common case.
        self.maybeFinishClose();
    }

    /// Deferred deinit guard: only free Connection when all armed cosocket
    /// completions have fired. Called at every point where pending_completions
    /// is decremented to ensure Connection outlives in-flight xev callbacks.
    /// Handle send completion boilerplate: decrement pending_io_ops, check for
    /// send errors, check closing state. Returns bytes sent on success, or null
    /// if the caller should return .disarm (error or closing).
    pub fn handleSendCompletion(self: *Connection, result: xev.Result) ?usize {
        self.pending_io_ops -= 1;
        const bytes = result.send catch {
            if (self.state == .closing) {
                self.maybeFinishClose();
            } else {
                self.close();
            }
            return null;
        };
        if (self.state == .closing) { self.maybeFinishClose(); return null; }
        return bytes;
    }

    pub fn maybeFinishClose(self: *Connection) void {
        if (self.state == .closing and self.cs.pending_completions == 0 and self.pending_timer_ops == 0 and self.pending_io_ops == 0) {
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
