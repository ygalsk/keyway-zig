//! Reverse proxy — async connect/send/recv to upstream, relay response to client.
//!
//! Zig-native, no Lua involvement. Route configuration via keyway.proxy.
//! Proactor model: every upstream I/O step runs on the worker's xev loop
//! (io_uring) and never blocks it.
//!
//! Response framing: we send `Connection: close` upstream and read until EOF,
//! buffering the whole response, then parse it (picohttpparser) to strip
//! hop-by-hop headers and regenerate Content-Length before relaying it to the
//! client (#182) — a de-chunked or as-is body copied into a fresh buffer, not
//! a streamed rewrite (see forwardProxyResponse). Upstream hosts are
//! pre-resolved to an address at route registration, so the data path never
//! does DNS.
//!
//! Connect/send/recv go through xev.TCP rather than raw xev.Completion ops
//! (the pattern the rest of this file's siblings use for the client socket):
//! building a raw `.connect` op needs libxev's internal address type, which
//! Zig 0.16's std.Io migration no longer exposes to callers. xev.TCP is the
//! only public surface that can bridge std.Io.net.IpAddress into a connect op.
//!
//! Upstream deadline (#72): one timer covers the whole exchange (connect+send+
//! recv), reusing Connection's request-timer fields (idle on this path — see
//! startProxyTimer). On fire, an io_uring `.cancel` op targets the in-flight
//! upstream completion directly rather than shutdown()ing the fd: shutdown()
//! on a socket still in SYN_SENT (mid-connect) is a documented no-op on Linux,
//! so it wouldn't bound a hung *connect* — only hung send/recv. `.cancel`
//! (IORING_OP_ASYNC_CANCEL) aborts any of the three phases uniformly.

const std = @import("std");
const xev = @import("xev");
const handler_mod = @import("../core/handler.zig");
const Connection = handler_mod.Connection;
const http = @import("http.zig");
const helpers = @import("../util/helpers.zig");
const error_response = @import("error_response.zig");
const router_mod = @import("router.zig");
const config = @import("../util/config.zig");

/// Size of each upstream recv chunk (bytes), appended to the response buffer.
const RECV_CHUNK = 16384;

/// State for an in-progress reverse-proxy exchange.
///
/// Embedded directly in Connection (stable address as long as Connection is
/// heap-alive). Exactly one upstream completion is in flight at a time, so a
/// single `completion` drives the connect → send → recv phases — never submit
/// a new upstream op except from inside the previous op's callback.
pub const ProxyState = struct {
    tcp: xev.TCP,
    completion: xev.Completion = .{},
    request_buf: []const u8, // upstream request bytes (headers + body); outlives the send
    sent: usize = 0, // bytes of request_buf already sent (short-send loop)
    recv_buf: []u8, // fixed-size upstream recv chunk
    response: std.ArrayListUnmanaged(u8) = .empty, // accumulated upstream response
    // Distinct completion for the `.cancel` op that aborts `completion` on
    // timeout (see onProxyTimeout) — a cancel op needs its own completion
    // struct, separate from the one it targets.
    cancel_completion: xev.Completion = .{},
    // Hop-by-hop-stripped, reframed response sent to the client (built by
    // forwardProxyResponse). Own base_allocator buffer, like request_buf: it
    // must outlive the async send. Empty until set.
    client_response: []const u8 = &.{},

    pub fn deinit(self: *ProxyState, allocator: std.mem.Allocator) void {
        helpers.closeFd(self.tcp.fd);
        allocator.free(self.request_buf);
        allocator.free(self.recv_buf);
        self.response.deinit(allocator);
        if (self.client_response.len > 0) allocator.free(self.client_response);
    }
};

/// Reverse proxy a request to its upstream. Called from handler.zig routeRequest.
pub fn serveProxy(self: *Connection, request: *const http.Request, proxy_match: router_mod.Router.ProxyMatch) void {
    const route = proxy_match.route;
    const prefix = route.prefix;

    // Bare prefix with a configured redirect → 302 (synchronous, no upstream).
    if (route.redirect) |redirect| {
        if (proxy_match.suffix.len == 0 or std.mem.eql(u8, proxy_match.suffix, "/")) {
            const resp = std.fmt.allocPrint(self.arena.allocator(), "HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\n\r\n", .{redirect}) catch {
                error_response.sendError(self, .server_error, "proxy redirect failed");
                return;
            };
            self.logAccess(302);
            self.sendRawResponse(resp);
            return;
        }
    }

    // Compute the upstream request-target path.
    const raw_path = request.path;
    const upstream_path: []const u8 = if (route.strip_prefix)
        (if (raw_path.len >= prefix.len and std.mem.startsWith(u8, raw_path, prefix))
            (if (raw_path[prefix.len..].len == 0) "/" else raw_path[prefix.len..])
        else
            "/")
    else
        raw_path;

    // Build the upstream request bytes on base_allocator: they must outlive the
    // per-request arena and keep a stable address for the async send.
    const request_buf = buildUpstreamRequest(self.base_allocator, request, route, upstream_path) catch {
        error_response.sendErrorStatus(self, 502, "proxy request build failed");
        return;
    };

    const tcp = xev.TCP.init(route.upstream_addr) catch {
        self.base_allocator.free(request_buf);
        error_response.sendErrorStatus(self, 502, "proxy socket creation failed");
        return;
    };

    const recv_buf = self.base_allocator.alloc(u8, RECV_CHUNK) catch {
        helpers.closeFd(tcp.fd);
        self.base_allocator.free(request_buf);
        error_response.sendErrorStatus(self, 502, "proxy buffer alloc failed");
        return;
    };

    self.proxy_state = .{
        .tcp = tcp,
        .request_buf = request_buf,
        .recv_buf = recv_buf,
    };

    startProxyTimer(self);

    // Async connect to the pre-resolved upstream address.
    self.pending_io_ops += 1;
    tcp.connect(self.loop, &self.proxy_state.?.completion, route.upstream_addr, Connection, self, onProxyConnect);
}

/// Arm the deadline covering the whole upstream exchange (connect+send+recv).
/// Reuses Connection's request-timer fields (timer_completion, timer_armed,
/// pending_timer_ops) — idle here since dispatchToHandler's startRequestTimer
/// is never reached on the proxy short-circuit path (see routeRequest). Timer
/// removal reuses cancelRequestTimer, which is agnostic to which logical
/// deadline is currently armed on the shared completion.
fn startProxyTimer(self: *Connection) void {
    self.timer_armed = true;
    self.pending_timer_ops += 1;
    self.loop.timer(&self.timer_completion, config.PROXY_UPSTREAM_TIMEOUT_MS, self, onProxyTimeout);
}

/// Upstream deadline fired — cancel the in-flight upstream op so its callback
/// (onProxyConnect/onProxyUpstreamSent/onProxyUpstreamRecv) runs with an
/// error, sending 504 through the ordinary proxyFail path exactly once.
/// Mirrors handler.zig's onRequestTimeout guard structure.
fn onProxyTimeout(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = helpers.castUserdata(Connection, userdata);
    // ECANCELED here means cancelRequestTimer's timer_remove fired (normal
    // exit) — not a real deadline. Ignore it, matching onRequestTimeout.
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
    if (self.state == .closing) return .disarm;
    // Stale fire that raced an already-in-flight cancellation: the exchange
    // finished (forwardProxyResponse or proxyFail already ran cleanupProxy)
    // before this expiry was processed. Nothing left to time out.
    if (self.proxy_state == null) return .disarm;
    self.timed_out = true;
    self.pending_io_ops += 1;
    const ps = &self.proxy_state.?;
    // cancel_completion's address stays valid even after cleanupProxy runs
    // (from the op it's cancelling) and nulls proxy_state: nulling an
    // optional writes only the tag, not the payload bytes, and
    // onProxyCancelComplete never dereferences proxy_state — it only
    // touches self. pending_io_ops (bumped above) defers Connection deinit
    // until this op is reaped either way.
    ps.cancel_completion = .{
        .op = .{ .cancel = .{ .c = &ps.completion } },
        .userdata = self,
        .callback = onProxyCancelComplete,
    };
    self.loop.add(&ps.cancel_completion);
    return .disarm;
}

/// The cancel op itself completed. Best-effort — the cancelled op's own
/// callback (not this one) drives the actual cleanup and 504 response.
fn onProxyCancelComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = result;
    const self = helpers.castUserdata(Connection, userdata);
    self.pending_io_ops -= 1;
    self.maybeFinishClose();
    return .disarm;
}

/// Headers stripped before forwarding upstream, per RFC 7230 §6.1: hop-by-hop
/// headers plus framing headers (Content-Length/Transfer-Encoding, which we
/// regenerate below rather than forward — request.body is already decoded,
/// so a forwarded Transfer-Encoding: chunked would corrupt the upstream read).
/// `host` isn't actually hop-by-hop — it's stripped because the request line
/// above already re-emits a rewritten Host for the upstream.
const HOP_BY_HOP_HEADERS = [_][]const u8{
    "host",
    "connection",
    "content-length",
    "transfer-encoding",
    "te",
    "trailer",
    "upgrade",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
};

/// True if `name` is a hop-by-hop header: one of HOP_BY_HOP_HEADERS, or named
/// as a connection-option token in any of the client's Connection headers
/// (RFC 7230 §6.1, e.g. `Connection: keep-alive, X-Hop`). Checks every header
/// named `connection` rather than just one — RFC 7230 §3.2.2 allows repeated
/// headers to be combined, and a header nominated by an earlier Connection
/// header must not leak upstream just because a later one didn't repeat it.
fn isHopByHop(name: []const u8, headers: []const http.Header) bool {
    for (HOP_BY_HOP_HEADERS) |hop| {
        if (std.ascii.eqlIgnoreCase(name, hop)) return true;
    }
    for (headers) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
        var it = std.mem.splitScalar(u8, h.value, ',');
        while (it.next()) |token| {
            if (std.ascii.eqlIgnoreCase(name, std.mem.trim(u8, token, " \t"))) return true;
        }
    }
    return false;
}

/// Build the HTTP/1.1 request to send upstream: request line, rewritten Host,
/// forced `Connection: close`, forwarded client headers (minus hop-by-hop),
/// regenerated framing, then the body.
fn buildUpstreamRequest(
    allocator: std.mem.Allocator,
    request: *const http.Request,
    route: router_mod.ProxyRoute,
    upstream_path: []const u8,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    defer aw.deinit();
    const w = &aw.writer;

    try w.print("{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n", .{
        request.method,
        upstream_path,
        route.upstream_host,
        route.upstream_port,
    });

    // Whether the original request carried framing, checked before the write
    // loop below strips/emits headers.
    var had_framing = false;
    for (request.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-length") or std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) had_framing = true;
    }

    for (request.headers) |h| {
        if (isHopByHop(h.name, request.headers)) continue;
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    // Regenerate framing rather than forwarding the client's CL/TE (already
    // stripped above): request.body is always the fully-decoded payload.
    if (request.body.len > 0 or had_framing) {
        try w.print("Content-Length: {d}\r\n", .{request.body.len});
    }
    try w.writeAll("\r\n");
    if (request.body.len > 0) try w.writeAll(request.body);

    return aw.toOwnedSlice();
}

/// Connect completed — start sending the upstream request.
fn onProxyConnect(
    ud: ?*Connection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    tcp: xev.TCP,
    result: xev.ConnectError!void,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = tcp;
    const self = ud.?;
    self.pending_io_ops -= 1;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    result catch {
        proxyFail(self, 502, "proxy upstream connect failed");
        return .disarm;
    };
    submitUpstreamSend(self);
    return .disarm;
}

/// Submit a send of the not-yet-sent tail of the upstream request.
fn submitUpstreamSend(self: *Connection) void {
    const ps = &self.proxy_state.?;
    self.pending_io_ops += 1;
    ps.tcp.write(self.loop, &ps.completion, .{ .slice = ps.request_buf[ps.sent..] }, Connection, self, onProxyUpstreamSent);
}

/// A send completed — loop on short sends, then start reading the response.
fn onProxyUpstreamSent(
    ud: ?*Connection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    tcp: xev.TCP,
    buf: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = tcp;
    _ = buf;
    const self = ud.?;
    self.pending_io_ops -= 1;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    const n = result catch {
        proxyFail(self, 502, "proxy upstream write failed");
        return .disarm;
    };
    const ps = &self.proxy_state.?;
    ps.sent += n;
    if (ps.sent < ps.request_buf.len) {
        submitUpstreamSend(self); // short send — send the remainder
        return .disarm;
    }
    submitUpstreamRecv(self);
    return .disarm;
}

/// Submit a recv of the next upstream response chunk.
fn submitUpstreamRecv(self: *Connection) void {
    const ps = &self.proxy_state.?;
    self.pending_io_ops += 1;
    ps.tcp.read(self.loop, &ps.completion, .{ .slice = ps.recv_buf }, Connection, self, onProxyUpstreamRecv);
}

/// A recv completed — accumulate the chunk and keep reading until EOF.
fn onProxyUpstreamRecv(
    ud: ?*Connection,
    loop: *xev.Loop,
    completion: *xev.Completion,
    tcp: xev.TCP,
    buf: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = tcp;
    _ = buf;
    const self = ud.?;
    self.pending_io_ops -= 1;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    const n = result catch |err| {
        // EOF (upstream honored Connection: close) means the response is complete.
        if (err == error.EOF) {
            forwardProxyResponse(self);
        } else {
            proxyFail(self, 502, "proxy upstream read failed");
        }
        return .disarm;
    };
    const ps = &self.proxy_state.?;
    ps.response.appendSlice(self.base_allocator, ps.recv_buf[0..n]) catch {
        proxyFail(self, 502, "proxy response buffer failed");
        return .disarm;
    };
    // Cap accumulated upstream response (#129): an adversarial/huge upstream
    // otherwise grows this buffer unbounded on base_allocator.
    if (ps.response.items.len > config.MAX_PROXY_RESPONSE_SIZE) {
        proxyFail(self, 502, "proxy upstream response too large");
        return .disarm;
    }
    submitUpstreamRecv(self);
    return .disarm;
}

/// True if `headers`' final Transfer-Encoding coding is "chunked" (RFC 7230
/// §3.3.2/§3.3.3: repeated TE headers combine, so the *last* header's *last*
/// comma-separated token is what determines chunked-ness). Mirrors the
/// identical check in Parser.parseRequest, duplicated here rather than
/// shared: that one operates inline over raw picohttpparser output while
/// parsing a request, this one over an already-parsed Header slice.
fn isChunkedResponse(headers: []const http.Header) bool {
    var te_val: ?[]const u8 = null;
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) te_val = h.value;
    }
    const val = te_val orelse return false;
    const last_token = if (std.mem.lastIndexOfScalar(u8, val, ',')) |idx| val[idx + 1 ..] else val;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, last_token, " \t"), "chunked");
}

/// True if a response to this exchange carries no body, per RFC 9110
/// §6.4.1: the request was HEAD, or status is 1xx/204/304.
fn responseHasNoBody(request_method: []const u8, status: u16) bool {
    if (std.mem.eql(u8, request_method, "HEAD")) return true;
    if (status >= 100 and status <= 199) return true;
    if (status == 204 or status == 304) return true;
    return false;
}

/// Parse the buffered upstream response, strip hop-by-hop headers, and
/// relay it to the client.
///
/// ponytail: buffered relay — the whole body is copied into a fresh
/// base_allocator buffer rather than rewritten in place/streamed. Simple and
/// correct for the read-to-EOF buffering this file already does; a
/// zero-copy/streaming relay is future work (out of scope for #182).
fn forwardProxyResponse(self: *Connection) void {
    self.cancelRequestTimer();
    const ps = &self.proxy_state.?;
    if (ps.response.items.len == 0) {
        proxyFail(self, 502, "proxy upstream empty response");
        return;
    }

    var parser = http.Parser.init(self.base_allocator);
    const head = parser.parseResponseHead(ps.response.items) catch {
        proxyFail(self, 502, "proxy upstream invalid response");
        return;
    };
    defer self.base_allocator.free(head.headers);

    // Log the real upstream status rather than a hardcoded 200 (#73).
    self.logAccess(head.status);

    var chunked_body: ?[]const u8 = null;
    defer if (chunked_body) |cb| self.base_allocator.free(cb);

    const body: []const u8 = if (responseHasNoBody(self.http_state.request_method, head.status))
        ""
    else if (isChunkedResponse(head.headers)) blk: {
        const decoded = http.decodeChunkedBody(ps.response.items[head.head_len..], self.base_allocator) catch {
            proxyFail(self, 502, "proxy upstream invalid chunked body");
            return;
        };
        chunked_body = decoded.body;
        break :blk decoded.body;
    } else
        // Read-to-EOF already gives the full body; the upstream's own
        // Content-Length (if any) is not authoritative — these bytes are.
        ps.response.items[head.head_len..];

    // Re-emit into a fresh base_allocator buffer: normalized status line,
    // every parsed header that isn't hop-by-hop (isHopByHop already strips
    // framing headers too, so Content-Length/Transfer-Encoding below are the
    // only ones emitted), regenerated framing, then the body.
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.base_allocator, ps.response.items.len) catch {
        proxyFail(self, 502, "proxy response build failed");
        return;
    };
    defer aw.deinit();
    const w = &aw.writer;
    const build_ok = blk: {
        w.print("HTTP/1.1 {d} {s}\r\n", .{ head.status, head.reason }) catch break :blk false;
        for (head.headers) |h| {
            if (isHopByHop(h.name, head.headers)) continue;
            w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch break :blk false;
        }
        w.print("Content-Length: {d}\r\n\r\n", .{body.len}) catch break :blk false;
        w.writeAll(body) catch break :blk false;
        break :blk true;
    };
    if (!build_ok) {
        proxyFail(self, 502, "proxy response build failed");
        return;
    }

    ps.client_response = aw.toOwnedSlice() catch {
        proxyFail(self, 502, "proxy response build failed");
        return;
    };
    // Send directly from proxy_state's base_allocator buffer (arena_dupe=false)
    // rather than through sendRawResponse: that buffer must stay valid until
    // the write completion actually fires (io_uring reads it asynchronously),
    // so cleanupProxy runs from handler.zig's onWrite once the send is
    // confirmed done — not here. Freeing it at submission time would race the
    // in-flight send.
    self.state = .writing;
    self.submitSend(ps.client_response, handler_mod.Connection.onWrite, false);
}

/// Send an error to the client and tear down proxy state. Safe to call from any
/// upstream callback: we are inside the only in-flight op (already decremented),
/// so no upstream completion references the fd we close here.
///
/// If the upstream deadline (#72) fired, `self.timed_out` is already set by
/// onProxyTimeout — the caller's status/message (e.g. 502 for a connect
/// failure) is overridden to 504, since the real cause was the timeout's
/// cancel, not whatever error the cancelled op happened to report.
fn proxyFail(self: *Connection, status: u16, internal_msg: []const u8) void {
    self.cancelRequestTimer();
    cleanupProxy(self);
    const actual_status: u16 = if (self.timed_out) 504 else status;
    const msg = if (self.timed_out) "proxy upstream timeout" else internal_msg;
    error_response.sendErrorStatus(self, actual_status, msg);
}

/// Tear down proxy_state (closes the upstream fd, frees buffers). Called from
/// any upstream-failure callback and from handler.zig's onWrite once the
/// final response send has completed.
pub fn cleanupProxy(self: *Connection) void {
    if (self.proxy_state) |*ps| {
        ps.deinit(self.base_allocator);
        self.proxy_state = null;
    }
}

// =============================================================================
// Tests
// =============================================================================

fn testRoute() router_mod.ProxyRoute {
    return .{
        .prefix = "/api",
        .upstream_host = "127.0.0.1",
        .upstream_port = 3000,
        .upstream_addr = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable,
    };
}

test "buildUpstreamRequest: regenerates Content-Length for a decoded chunked body" {
    var headers = [_]http.Header{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    };
    const request = http.Request{
        .method = "POST",
        .path = "/upload",
        .headers = &headers,
        .body = "hello world",
        .raw_len = 0,
    };
    const built = try buildUpstreamRequest(std.testing.allocator, &request, testRoute(), "/upload");
    defer std.testing.allocator.free(built);

    try std.testing.expect(std.mem.indexOf(u8, built, "Content-Length: 11\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "Transfer-Encoding") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, built, "hello world"));
}

test "buildUpstreamRequest: strips hop-by-hop headers, keeps ordinary ones" {
    var headers = [_]http.Header{
        .{ .name = "TE", .value = "trailers" },
        .{ .name = "Trailer", .value = "X-Foo" },
        .{ .name = "Upgrade", .value = "websocket" },
        .{ .name = "Keep-Alive", .value = "timeout=5" },
        .{ .name = "Proxy-Authorization", .value = "Basic xyz" },
        .{ .name = "X-Custom", .value = "keep-me" },
        .{ .name = "Accept", .value = "*/*" },
    };
    const request = http.Request{
        .method = "GET",
        .path = "/",
        .headers = &headers,
        .body = "",
        .raw_len = 0,
    };
    const built = try buildUpstreamRequest(std.testing.allocator, &request, testRoute(), "/");
    defer std.testing.allocator.free(built);

    for ([_][]const u8{ "TE:", "Trailer:", "Upgrade:", "Keep-Alive:", "Proxy-Authorization:" }) |hop| {
        try std.testing.expect(std.mem.indexOf(u8, built, hop) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, built, "X-Custom: keep-me\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, built, "Accept: */*\r\n") != null);
}

test "buildUpstreamRequest: strips headers named as Connection tokens, keeps unnamed ones" {
    var headers = [_]http.Header{
        .{ .name = "Connection", .value = "keep-alive, X-Hop" },
        .{ .name = "X-Hop", .value = "strip-me" },
        .{ .name = "X-Hop2", .value = "keep-me" },
    };
    const request = http.Request{
        .method = "GET",
        .path = "/",
        .headers = &headers,
        .body = "",
        .raw_len = 0,
    };
    const built = try buildUpstreamRequest(std.testing.allocator, &request, testRoute(), "/");
    defer std.testing.allocator.free(built);

    try std.testing.expect(std.mem.indexOf(u8, built, "X-Hop:") == null);
    try std.testing.expect(std.mem.indexOf(u8, built, "X-Hop2: keep-me\r\n") != null);
}

test "buildUpstreamRequest: honors every Connection header, not just the last" {
    var headers = [_]http.Header{
        .{ .name = "Connection", .value = "X-First" },
        .{ .name = "X-First", .value = "strip-me" },
        .{ .name = "Connection", .value = "X-Second" },
        .{ .name = "X-Second", .value = "strip-me-too" },
    };
    const request = http.Request{
        .method = "GET",
        .path = "/",
        .headers = &headers,
        .body = "",
        .raw_len = 0,
    };
    const built = try buildUpstreamRequest(std.testing.allocator, &request, testRoute(), "/");
    defer std.testing.allocator.free(built);

    try std.testing.expect(std.mem.indexOf(u8, built, "X-First:") == null);
    try std.testing.expect(std.mem.indexOf(u8, built, "X-Second:") == null);
}

test "buildUpstreamRequest: GET with no body and no framing headers emits no Content-Length" {
    var headers = [_]http.Header{
        .{ .name = "Accept", .value = "*/*" },
    };
    const request = http.Request{
        .method = "GET",
        .path = "/",
        .headers = &headers,
        .body = "",
        .raw_len = 0,
    };
    const built = try buildUpstreamRequest(std.testing.allocator, &request, testRoute(), "/");
    defer std.testing.allocator.free(built);

    try std.testing.expect(std.mem.indexOf(u8, built, "Content-Length") == null);
}

test "isChunkedResponse: last Transfer-Encoding header's last coding determines chunked-ness" {
    try std.testing.expect(isChunkedResponse(&[_]http.Header{
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    }));
    try std.testing.expect(isChunkedResponse(&[_]http.Header{
        .{ .name = "Transfer-Encoding", .value = "gzip, chunked" },
    }));
    try std.testing.expect(!isChunkedResponse(&[_]http.Header{
        .{ .name = "Transfer-Encoding", .value = "chunked, gzip" },
    }));
    try std.testing.expect(!isChunkedResponse(&[_]http.Header{}));
    // Repeated headers combine (RFC 7230 §3.3.2) — the last one wins.
    try std.testing.expect(isChunkedResponse(&[_]http.Header{
        .{ .name = "Transfer-Encoding", .value = "gzip" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
    }));
}

test "responseHasNoBody: HEAD, 1xx, 204, 304 have no body; everything else does" {
    try std.testing.expect(responseHasNoBody("HEAD", 200));
    try std.testing.expect(responseHasNoBody("GET", 100));
    try std.testing.expect(responseHasNoBody("GET", 199));
    try std.testing.expect(responseHasNoBody("GET", 204));
    try std.testing.expect(responseHasNoBody("GET", 304));
    try std.testing.expect(!responseHasNoBody("GET", 200));
    try std.testing.expect(!responseHasNoBody("POST", 404));
}
