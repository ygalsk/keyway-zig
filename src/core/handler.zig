//! Connection lifecycle and proactor boundary.
//!
//! Each Connection owns a socket, read/write buffers, an arena allocator,
//! and per-request state (params, query, suspended coroutine). The proactor
//! contract: Lua sets state on HttpExchange, Zig submits all I/O via libxev.
//!
//! Lifecycle: accept → startRead → onRead → handleRequest → onWrite → (keep-alive or close)
//! Protocol upgrades (WS, SSE, stream) branch from dispatchRequest; the yield/resume
//! bridge for WS/SSE/stream flow control lives on Connection (dispatchResume,
//! resumeWithError, completeHandler).

const std = @import("std");
const xev = @import("xev");
const log = @import("../observability/log.zig");
const LinearBuffer = @import("../util/buffer.zig").LinearBuffer;
const http = @import("../http/http.zig");
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const Router = @import("../http/router.zig").Router;
const LuaState = @import("../lua/lua_state.zig").LuaState;
const tls_mod = @import("../tls/tls.zig");
const TlsContext = tls_mod.TlsContext;
const Lua = @import("luajit").Lua;
const SseRegistry = @import("../protocol/sse.zig").SseRegistry;
const config = @import("../util/config.zig");
const params = @import("../http/params.zig");
const conn_tls = @import("../tls/conn_tls.zig");
const castUserdata = @import("../util/helpers.zig").castUserdata;
const helpers = @import("../util/helpers.zig");
// ponytail: conn_* are Connection adapters; action objects would just wrap these calls.
const conn_sse = @import("conn_sse.zig");
const conn_ws = @import("conn_ws.zig");
const conn_stream = @import("conn_stream.zig");
const error_response = @import("../http/error_response.zig");
const ErrorCategory = error_response.ErrorCategory;
const Server = @import("server.zig").Server;
const prom = @import("../observability/prom.zig");
const static_mod = @import("../http/static.zig");
const proxy_mod = @import("../http/proxy.zig");

const ParamArray = params.ParamArray;
const QueryArray = params.QueryArray;
const parseQueryString = params.parseQueryString;
/// Suspend state for a coroutine yielded on WS/SSE/stream flow control.
/// Non-null means a handler is yielded waiting to be resumed.
pub const SuspendedState = struct {
    // ponytail: WebSocket resumes do not serialize an HTTP response; null beats a dummy exchange.
    exchange: ?*HttpExchange,
    coroutine_ref: i32,
    coroutine_thread: *anyopaque,
};

const READ_BUFFER_SIZE = config.READ_BUFFER_SIZE;
const ARENA_RETAIN_LIMIT = config.ARENA_RETAIN_LIMIT;

/// Per-request HTTP state — reset between keep-alive requests.
pub const HttpState = struct {
    request_start_ns: i64 = 0,
    request_method: []const u8 = "",
    request_path: []const u8 = "",
    request_raw_len: usize = 0, // total bytes consumed by current request (headers + body)
    route_pattern: []const u8 = "", // matched route pattern for Prometheus labels (e.g. "/users/{id}")
    wants_close: bool = false, // client asked to close, or HTTP/1.0 implicit close (#204)
};

/// Inbound TLS state — set once at connection init, persists across keep-alive.
pub const TlsState = struct {
    tls_conn: ?tls_mod.TlsConn = null,
    ciphertext_buffer: ?LinearBuffer = null, // recv target for TLS connections
    tls_handshake_complete: bool = false, // flag for sendTlsData -> onTlsHandshakeWrite
    ktls_active: bool = false, // true after kTLS offload; marks a plaintext-socket recv as TLS

    pub fn deinit(self: *TlsState, alloc: std.mem.Allocator) void {
        if (self.tls_conn) |*tc| tc.deinit(alloc);
        if (self.ciphertext_buffer) |*cb| cb.deinit();
    }
};

/// RFC 9112 §3.2.2 absolute-form: "scheme://authority/path?query" → "/path?query".
/// Returns the target unchanged if it isn't absolute-form. Does not enforce
/// that the authority agrees with the Host header (RFC says a server
/// "should" check this; skipped as low-value extra strictness).
fn originForm(target: []const u8) []const u8 {
    // Origin-form always starts with '/'; absolute-form starts with a scheme
    // letter. This discriminator keeps a query string containing "://"
    // (e.g. "/redirect?url=http://x") from being misparsed as absolute-form.
    if (target.len == 0 or target[0] == '/') return target;
    const sep = std.mem.indexOf(u8, target, "://") orelse return target;
    const after_authority_start = sep + 3;
    if (after_authority_start >= target.len) return "/"; // "http://" with nothing after
    const rel = std.mem.indexOfScalarPos(u8, target, after_authority_start, '/');
    return if (rel) |i| target[i..] else "/"; // authority with no path → "/"
}

test "originForm strips scheme and authority from absolute-form" {
    try std.testing.expectEqualStrings("/path", originForm("http://host/path"));
    try std.testing.expectEqualStrings("/path?q=1", originForm("http://host:8080/path?q=1"));
    try std.testing.expectEqualStrings("/", originForm("http://host"));
    try std.testing.expectEqualStrings("/", originForm("http://"));
}

test "originForm leaves origin-form untouched" {
    try std.testing.expectEqualStrings("/path", originForm("/path"));
    try std.testing.expectEqualStrings("/redirect?url=http://x", originForm("/redirect?url=http://x"));
    try std.testing.expectEqualStrings("", originForm(""));
}

/// Reset a connection's per-exchange arena, freeing it outright once its
/// retained capacity outgrows ARENA_RETAIN_LIMIT and keeping the capacity
/// otherwise.
///
/// The watermark is on the arena's capacity rather than on how much the
/// exchange actually used: a large intermediate allocation — or a path that
/// reports zero bytes here, like static files and streaming — would otherwise
/// leave the arena inflated for the connection's lifetime.
///
/// Lives here, and takes the arena rather than the Connection, because both the
/// HTTP and the WebSocket path reset the same arena between exchanges. Holding
/// the policy in one place is the point: the WS path had its own copy that
/// never consulted the limit, so one big message ratcheted that connection's
/// floor up for good (#260).
pub fn resetArena(arena: *std.heap.ArenaAllocator) void {
    _ = arena.reset(.retain_capacity);
}

test "resetArena releases an arena that outgrew the retain limit (#260)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try arena.allocator().alloc(u8, ARENA_RETAIN_LIMIT + 1);
    try std.testing.expect(arena.queryCapacity() > ARENA_RETAIN_LIMIT);

    resetArena(&arena);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
}

test "resetArena keeps capacity that is still under the retain limit (#260)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try arena.allocator().alloc(u8, 4096);
    const retained = arena.queryCapacity();
    try std.testing.expect(retained > 0);
    try std.testing.expect(retained <= ARENA_RETAIN_LIMIT);

    resetArena(&arena);
    try std.testing.expectEqual(retained, arena.queryCapacity());
}

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
    // Enforces "at most one send in flight" on write_completion: submitSend
    // refuses to overwrite/re-add it while this is true. A violation means
    // two sends raced onto the same Completion — double io_uring add and a
    // clobbered buffer (#224). Cleared in handleSendCompletion.
    send_in_flight: bool = false,

    // Buffers (allocated from base_allocator, persist across requests)
    read_buffer: LinearBuffer,

    // Inline param/query storage (reused across requests, zero allocations, cache-friendly)
    param_cache: ParamArray,
    query_cache: QueryArray,

    // Sub-struct: per-request HTTP fields (reset on keep-alive)
    http_state: HttpState = .{},

    // Non-null when a handler is yielded waiting for WS/SSE/stream flow control.
    suspended: ?SuspendedState = null,

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

    // Reverse proxy: non-null while an upstream exchange is in flight
    proxy_state: ?proxy_mod.ProxyState = null,

    // Per-request timeout: timer fires after REQUEST_TIMEOUT_MS, sending 504
    // Completions initialized to .{} per xev requirements (Pitfall 3: never undefined)
    timer_completion: xev.Completion = .{},
    timer_cancel_completion: xev.Completion = .{},
    timed_out: bool = false,
    timer_armed: bool = false,
    // Set by an error/reject response funnel (error_response.zig, WS 426) whose
    // canned response advertises `Connection: close`. onWrite closes instead of
    // recycling the socket once this write completes, so the header isn't a
    // protocol lie (#180). Never reset — a set flag always leads to close().
    close_after_write: bool = false,
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

    pub fn init(server: *Server, socket: std.posix.socket_t) !*Connection {
        const allocator = server.allocator;
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
            .loop = server.loop,
            .socket = socket,
            .router = server.router,
            .lua_state = server.lua_state,
            .read_completion = .{},
            .write_completion = .{},
            .read_buffer = read_buf,
            .param_cache = ParamArray{},
            .query_cache = QueryArray{},
            .sse_registry = server.sse_registry,
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
        if (self.suspended) |*s| {
            // Unref pinned coroutine to prevent Lua registry leak
            if (s.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
            }
        }
        // Clean up WebSocket callback refs and reassembly buffer
        if (self.ws_state) |*wss| {
            if (wss.on_message_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_message_ref);
            if (wss.on_close_ref != 0) self.lua_state.lua.unref(Lua.PseudoIndex.Registry, wss.on_close_ref);
            if (wss.fragment_buf) |*fb| fb.deinit(self.arena.allocator());
        }
        // Clean up stream state if connection closes while a stream coroutine
        // is still suspended mid-yield (never reached sendTerminalChunk or the
        // Lua-error path, which both already unref + decrement themselves).
        // Unref the pinned coroutine (Lua registry leak) and match
        // dispatchCoroutine's start-of-request increment (#173).
        if (self.stream_state) |*ss| {
            prom.luaCoroutineFinished();
            if (ss.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, ss.coroutine_ref);
            }
        }
        // Clean up SSE state
        if (self.sse_state) |*ss| ss.deinit(self);
        // Clean up static file state
        if (self.static_state) |*ss| ss.deinit(self.base_allocator);
        // Clean up reverse-proxy state (closes upstream fd, frees buffers).
        // pending_io_ops gates maybeFinishClose, so any in-flight upstream op
        // has already fired before deinit runs.
        if (self.proxy_state) |*ps| ps.deinit(self.base_allocator);
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
    /// pub: also cancels proxy.zig's upstream deadline (#72), which reuses this
    /// same timer_completion — the request timer is never armed on the proxy
    /// path, so the field is idle and safe to share.
    pub fn cancelRequestTimer(self: *Connection) void {
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
    /// all armed timer/I/O completions (pending_timer_ops, pending_io_ops).
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
                // READ_BUFFER_SIZE caps the whole request (headers + body); a
                // still-incomplete parse with a full buffer means the request
                // doesn't fit, not that it's malformed.
                error_response.sendErrorStatus(self, 413, "request exceeds buffer");
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
            if (self.state == .closing) {
                self.maybeFinishClose();
                return .disarm;
            }
            if (err != error.EOF) {
                // On a kTLS socket a control record — typically the peer's
                // close_notify at teardown — surfaces to recv as EIO, which
                // libxev maps to error.Unexpected, not EOF. That's a normal TLS
                // close, not a failure: log it at debug instead of a spurious
                // ERROR on every HTTPS connection. We can't process a
                // post-handshake record here regardless (the SSL object was
                // freed after the handshake) — surviving a KeyUpdate needs the
                // userspace data path (#196).
                if (self.tls_state.ktls_active) {
                    log.debug().string("msg", "kTLS connection closed by peer (control record)").int("fd", self.socket).log();
                } else {
                    log.err().string("msg", "recv failed").int("fd", self.socket).err(err).log();
                }
            }
            self.close();
            return .disarm;
        };

        if (self.state == .closing) {
            self.maybeFinishClose();
            return .disarm;
        }

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
        const request = http.parseRequest(self.arena.allocator(), request_data) catch |err| {
            if (err == error.Incomplete) {
                self.startRead();
            } else if (err == error.RequestTooLarge) {
                error_response.sendErrorStatus(self, 413, "content-length exceeds buffer");
            } else {
                error_response.sendError(self, .client_error, "http parse failed");
            }
            return err;
        };

        // RFC 9112 §3.2.2: normalize absolute-form ("http://host/path") to
        // origin-form before routing. Authority-vs-Host agreement is
        // intentionally not enforced (RFC says "should"; low-value here).
        const target = originForm(request.path);

        const query_pos = std.mem.indexOfScalar(u8, target, '?');
        const clean_path = if (query_pos) |qi| target[0..qi] else target;

        self.http_state.request_method = request.method;
        self.http_state.request_path = clean_path;
        self.http_state.request_raw_len = request.raw_len;
        self.http_state.wants_close = request.wants_close;

        // Parse query string and clear param cache for route matching
        self.query_cache.clear();
        if (query_pos) |qi| {
            parseQueryString(target[qi + 1 ..], &self.query_cache);
        }
        self.param_cache.clear();

        return request;
    }

    /// WS/SSE upgrade check for a completed handler. Both are long-lived —
    /// exempt from the request timeout — so the cancel is centralized here
    /// instead of repeated per-protocol. Returns true if the request was
    /// consumed by the upgrade (caller must not log/write a normal response).
    fn tryUpgrade(self: *Connection, exchange: *HttpExchange, request: *const http.Request) bool {
        if (!exchange.upgrade_websocket and !exchange.upgrade_sse) return false;

        self.cancelRequestTimer();

        if (exchange.upgrade_websocket) {
            conn_ws.handleWsUpgrade(self, exchange, request) catch {
                self.logAccess(400);
                error_response.sendError(self, .client_error, "websocket upgrade failed");
            };
        } else {
            conn_sse.handleSseUpgrade(self, exchange);
        }
        return true;
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

                if (exchange.handler_error) |msg| {
                    log.err().string("msg", "lua handler error").int("fd", self.socket).stringSafe("method", request.method).string("path", clean_path).string("error", msg).log();
                    self.logAccess(500);
                    error_response.sendError(self, .server_error, "lua handler error");
                    return;
                }

                if (self.tryUpgrade(exchange, request)) return;

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
                self.suspended = .{
                    .exchange = exchange,
                    .coroutine_ref = self.lua_state.coroutine_ref,
                    .coroutine_thread = @ptrCast(self.lua_state.coroutine_thread.?),
                };
                self.lua_state.coroutine_ref = 0;
                self.lua_state.coroutine_thread = null;
                // A bare coroutine.yield() outside WS/SSE/stream flow control has
                // nothing to wait on — resume immediately with an error.
                self.resumeWithError(.server_error, "no pending I/O operation");
            },
        }
    }

    // =========================================================================
    // WS/SSE/stream yield/resume bridge
    // =========================================================================
    // A yielded coroutine is resumed by pushing result values onto its thread
    // stack, then dispatching on whether it completed or yielded again.

    /// Resume a suspended coroutine and dispatch based on the result.
    pub fn dispatchResume(self: *Connection, thread: *Lua, nresults: c_int) void {
        self.lua_state.current_connection = self;
        const resume_result = self.lua_state.resumeHandler(@ptrCast(thread), nresults) catch {
            self.lua_state.current_connection = null;
            // WebSocket: can't send HTTP 500 on a WS connection — return to read loop
            if (self.state == .websocket) {
                self.completeHandler();
            } else {
                self.send500InternalError();
            }
            return;
        };

        switch (resume_result) {
            .completed => {
                self.lua_state.current_connection = null;
                self.completeHandler();
            },
            .yielded => {
                if (self.state == .websocket) {
                    conn_ws.routeWsYield(self);
                } else {
                    // Nothing left to wait on outside WS flow control.
                    self.resumeWithError(.server_error, "no pending I/O operation");
                }
            },
        }
    }

    /// Push nil, {category=..., message=...} error table onto the thread stack,
    /// so Lua always sees a structured error table.
    fn pushErrorTable(thread: *Lua, category: ErrorCategory, msg: [:0]const u8) void {
        thread.pushNil();
        thread.createTable(0, 2);
        thread.pushString(@tagName(category));
        thread.setField(-2, "category");
        thread.pushString(msg);
        thread.setField(-2, "message");
    }

    /// Resume the suspended coroutine with nil, {category, message} error table.
    pub fn resumeWithError(self: *Connection, category: ErrorCategory, msg: [:0]const u8) void {
        const s = &self.suspended.?;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        pushErrorTable(thread, category, msg);
        self.dispatchResume(thread, 2);
    }

    /// Handler finished after one or more yield/resume cycles.
    /// Return coroutine to cache, serialize response, submit write.
    /// For WebSocket connections, returns to WS read loop instead of HTTP response.
    pub fn completeHandler(self: *Connection) void {
        const s = self.suspended orelse return;

        // Return the coroutine thread for reuse. dispatchResume also lands here
        // after a *failed* resume on a WS connection, where the thread is dead —
        // recycleThread checks the thread's status rather than trusting the
        // caller, so the corpse is dropped instead of cached (#242).
        self.lua_state.recycleThread(s.coroutine_ref, s.coroutine_thread);

        self.suspended = null;

        // WebSocket: return to WS read loop instead of serializing HTTP response
        if (self.state == .websocket) {
            self.lua_state.current_connection = null;
            conn_ws.startWsRead(self);
            return;
        }

        const exchange = s.exchange.?;
        self.logAccess(exchange.status);
        self.writeResponse(exchange) catch {
            self.send500InternalError();
        };
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
            proxy_mod.serveProxy(self, request, proxy_match);
            return null;
        }

        // Static file routes: handled before Lua routing (zero Lua overhead)
        if (self.router.matchStatic(clean_path)) |match| {
            if (!std.mem.eql(u8, request.method, "GET") and !std.mem.eql(u8, request.method, "HEAD")) {
                self.logAccess(405);
                error_response.send405(self, "GET, HEAD");
                return null;
            }
            static_mod.serveStaticFile(self, request, match.route, match.suffix);
            return null;
        }

        var route_match = self.router.match(request.method, clean_path, &self.param_cache) catch {
            error_response.sendError(self, .client_error, "route match error");
            return error.RouteMatchFailed;
        };

        // RFC 9110 §9.1: HEAD must be supported wherever GET is. Fall back to
        // the GET handler when no explicit HEAD route matched. `match` already
        // populated param_cache while walking the trie above (regardless of
        // the method miss), and `put` APPENDS rather than overwriting by key
        // (src/http/params.zig) — clear before the retry or a parameterized
        // route ends up with duplicate param entries.
        if (route_match == null and std.mem.eql(u8, request.method, "HEAD")) {
            self.param_cache.clear();
            route_match = self.router.match("GET", clean_path, &self.param_cache) catch {
                error_response.sendError(self, .client_error, "route match error");
                return error.RouteMatchFailed;
            };
        }

        if (route_match == null) {
            if (self.router.methodsForPath(clean_path)) |methods| {
                var allow: std.ArrayListUnmanaged(u8) = .empty;
                var it = methods.keyIterator();
                var first = true;
                while (it.next()) |k| {
                    if (!first) allow.appendSlice(self.arena.allocator(), ", ") catch break;
                    allow.appendSlice(self.arena.allocator(), k.*) catch break;
                    first = false;
                }
                self.logAccess(405);
                error_response.send405(self, allow.items);
                return null;
            }
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

        self.submitSend(self.stripBodyForHead(response_bytes), onWrite, false);
    }

    /// A HEAD response carries the headers (incl. Content-Length) a GET would
    /// have sent, but no body (RFC 9110 §8.6, §9.3.2). Truncate an
    /// already-serialized response right after its header block when the
    /// request was HEAD; otherwise return it unchanged. Not folded into
    /// submitSend: that function also carries WS/SSE/streaming frames and the
    /// proxy relay, where a blanket strip would corrupt the payload.
    fn stripBodyForHead(self: *Connection, bytes: []const u8) []const u8 {
        if (!std.mem.eql(u8, self.http_state.request_method, "HEAD")) return bytes;
        const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return bytes;
        return bytes[0 .. header_end + 4];
    }

    /// Submit a send on this connection's socket.
    /// After kTLS setup, all sends are plaintext — the kernel encrypts transparently.
    /// If arena_dupe is true, data is copied into the arena (for stack-local buffers).
    pub fn submitSend(self: *Connection, data: []const u8, callback: *const fn (?*anyopaque, *xev.Loop, *xev.Completion, xev.Result) xev.CallbackAction, arena_dupe: bool) void {
        if (self.send_in_flight) {
            // Invariant violation, not a std.debug.assert (stripped in release,
            // see zig-gotchas.md): a caller tried to submit a second send while
            // one was still in flight, which would clobber write_completion and
            // double-add it to the loop (#224). Fail loud and closed instead.
            log.err().string("msg", "submitSend: send already in flight, closing connection").int("fd", self.socket).log();
            self.close();
            return;
        }
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
        self.send_in_flight = true;
        self.pending_io_ops += 1;
        self.loop.add(&self.write_completion);
    }

    pub fn sendRawResponse(self: *Connection, text: []const u8) void {
        self.state = .writing;
        self.submitSend(self.stripBodyForHead(text), onWrite, true);
    }

    pub fn send400BadRequest(self: *Connection) void {
        error_response.sendError(self, .client_error, "bad request");
    }

    pub fn send500InternalError(self: *Connection) void {
        error_response.sendError(self, .server_error, "internal error");
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
        var date_buf: [29]u8 = undefined;
        helpers.formatHttpDate(&date_buf, helpers.realtimeSeconds());
        const full = std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nDate: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ &date_buf, body.len, body }) catch {
            error_response.sendError(self, .server_error, "metrics response failed");
            return;
        };
        self.logAccess(200);
        self.sendRawResponse(full);
    }

    /// Format and send a JSON HTTP response with the given status and body.
    fn sendJsonResponse(self: *Connection, alloc: std.mem.Allocator, status_code: u16, status_text: []const u8, body: []const u8) void {
        var date_buf: [29]u8 = undefined;
        helpers.formatHttpDate(&date_buf, helpers.realtimeSeconds());
        const resp = std.fmt.allocPrint(alloc, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nDate: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ status_code, status_text, &date_buf, body.len, body }) catch {
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

    /// pub: proxy.zig passes this directly as the completion callback for the
    /// final proxy response send (submitSend with arena_dupe=false), so the
    /// upstream buffers stay alive until the send actually completes.
    pub fn onWrite(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;
        const self = castUserdata(Connection, userdata);
        const bytes_written = self.handleSendCompletion(result) orelse return .disarm;
        // Tear down proxy_state now that its response buffer's send has
        // completed (safe: handleSendCompletion already returned on error/
        // closing, so this doesn't run on a send that failed mid-flight —
        // that path is cleaned up once by Connection.deinit instead).
        if (self.proxy_state != null) {
            proxy_mod.cleanupProxy(self);
        }
        // If this write was the 504 timeout response, or any other error/reject
        // response whose canned reply advertises `Connection: close`, close
        // instead of recycling (#180). pending_timer_ops/pending_io_ops may
        // still be non-zero (in-flight completions), so close() ->
        // maybeFinishClose() defers deinit until they drain.
        // (Honoring the *client's* Connection: close request header — and the
        // HTTP/1.0 implicit-close default — on success responses is handled
        // in handleHttpPostWrite via http_state.wants_close, not here: this
        // check runs before the state switch, so it would wrongly close a
        // WS/SSE/stream upgrade response too. See #204.)
        if (self.timed_out or self.close_after_write) {
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
        _ = bytes_written;
        _ = self.arena.reset(.retain_capacity);
        if (self.http_state.request_raw_len > 0) {
            self.read_buffer.consume(self.http_state.request_raw_len);
            self.http_state.request_raw_len = 0;
        } else {
            self.read_buffer.reset();
        }
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
        self.suspended = null;
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

        // Reset timeout flags for next request on keep-alive
        self.timed_out = false;
        self.timer_armed = false;
        self.header_timer_armed = false;

        self.state = .reading;

        // During drain: close keep-alive connections after current request completes
        if (self.server.draining) {
            self.close();
            return;
        }

        // Client asked to close (Connection: close), or HTTP/1.0 implicit
        // close (#204) — close instead of recycling for keep-alive. No
        // `Connection: close` response header is added; the client already
        // initiated the close expectation.
        if (self.http_state.wants_close) {
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
        _ = self.server.metrics.fetchSub(1, .monotonic);
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
        // Deferred deinit: only free when all armed timer/I/O completions have fired.
        // Normal HTTP connections have both counters at 0 by the time close() runs,
        // so maybeFinishClose is equivalent to deinit() in the common case.
        self.maybeFinishClose();
    }

    /// Deferred deinit guard: only free Connection when all armed timer/I/O
    /// completions have fired. Called at every point where pending_timer_ops or
    /// pending_io_ops is decremented to ensure Connection outlives in-flight xev callbacks.
    /// Handle send completion boilerplate: decrement pending_io_ops, check for
    /// send errors, check closing state. Returns bytes sent on success, or null
    /// if the caller should return .disarm (error or closing).
    pub fn handleSendCompletion(self: *Connection, result: xev.Result) ?usize {
        self.pending_io_ops -= 1;
        self.send_in_flight = false;
        const bytes = result.send catch {
            if (self.state == .closing) {
                self.maybeFinishClose();
            } else {
                self.close();
            }
            return null;
        };
        if (self.state == .closing) {
            self.maybeFinishClose();
            return null;
        }
        return bytes;
    }

    pub fn maybeFinishClose(self: *Connection) void {
        if (self.state == .closing and self.pending_timer_ops == 0 and self.pending_io_ops == 0) {
            self.deinit(self.base_allocator);
        }
    }
};
