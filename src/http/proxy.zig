//! Reverse proxy — async connect/send/recv to upstream, relay response to client.
//!
//! Zig-native, no Lua involvement. Route configuration via keyway.proxy.
//! Proactor model: every upstream I/O step runs on the worker's xev loop
//! (io_uring) and never blocks it.
//!
//! Response framing: we send `Connection: close` upstream and read until EOF,
//! buffering the whole response before relaying it (no Content-Length/chunked
//! parsing). Upstream hosts are pre-resolved to an address at route
//! registration, so the data path never does DNS.
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

    pub fn deinit(self: *ProxyState, allocator: std.mem.Allocator) void {
        helpers.closeFd(self.tcp.fd);
        allocator.free(self.request_buf);
        allocator.free(self.recv_buf);
        self.response.deinit(allocator);
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

/// Build the HTTP/1.1 request to send upstream: request line, rewritten Host,
/// forced `Connection: close`, forwarded client headers, then the body.
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
    for (request.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try w.writeAll("\r\n");
    if (request.body.len > 0) try w.writeAll(request.body);

    var list = aw.toArrayList();
    return try list.toOwnedSlice(allocator);
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
    submitUpstreamRecv(self);
    return .disarm;
}

/// Parse the 3-digit status code from a buffered upstream response's status
/// line (e.g. "HTTP/1.1 502 Bad Gateway\r\n" -> 502). Returns null if the
/// buffer is too short or doesn't start with a well-formed status line.
/// Never allocates.
fn parseUpstreamStatus(response: []const u8) ?u16 {
    if (response.len < 12) return null;
    if (!std.mem.startsWith(u8, response, "HTTP/1.")) return null;
    if (!std.ascii.isDigit(response[7]) or response[8] != ' ') return null;
    return std.fmt.parseInt(u16, response[9..12], 10) catch null;
}

/// Relay the buffered upstream response to the client.
fn forwardProxyResponse(self: *Connection) void {
    self.cancelRequestTimer();
    const ps = &self.proxy_state.?;
    if (ps.response.items.len == 0) {
        proxyFail(self, 502, "proxy upstream empty response");
        return;
    }
    // Log the real upstream status rather than a hardcoded 200 (#73). The
    // response bytes are relayed to the client verbatim regardless; if the
    // status line doesn't parse, the upstream didn't send valid HTTP, so we
    // log 502 (bad gateway) rather than lie with 200.
    self.logAccess(parseUpstreamStatus(ps.response.items) orelse 502);
    // Send directly from proxy_state's base_allocator buffer (arena_dupe=false)
    // rather than through sendRawResponse: that buffer must stay valid until
    // the write completion actually fires (io_uring reads it asynchronously),
    // so cleanupProxy runs from handler.zig's onWrite once the send is
    // confirmed done — not here. Freeing it at submission time would race the
    // in-flight send; also avoids a full copy of a possibly large response.
    self.state = .writing;
    self.submitSend(ps.response.items, handler_mod.Connection.onWrite, false);
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

test "parseUpstreamStatus: well-formed status lines" {
    try std.testing.expectEqual(@as(?u16, 200), parseUpstreamStatus("HTTP/1.1 200 OK\r\n\r\n"));
    try std.testing.expectEqual(@as(?u16, 404), parseUpstreamStatus("HTTP/1.1 404 Not Found\r\n\r\n"));
    try std.testing.expectEqual(@as(?u16, 502), parseUpstreamStatus("HTTP/1.0 502 Bad Gateway\r\n\r\n"));
}

test "parseUpstreamStatus: 3-digit boundary codes" {
    try std.testing.expectEqual(@as(?u16, 100), parseUpstreamStatus("HTTP/1.1 100 Continue\r\n\r\n"));
    try std.testing.expectEqual(@as(?u16, 999), parseUpstreamStatus("HTTP/1.1 999 X\r\n\r\n"));
    try std.testing.expectEqual(@as(?u16, 200), parseUpstreamStatus("HTTP/1.1 200")); // exact len == 12, no trailing bytes
}

test "parseUpstreamStatus: malformed status line" {
    try std.testing.expectEqual(@as(?u16, null), parseUpstreamStatus("not an http response at all"));
    try std.testing.expectEqual(@as(?u16, null), parseUpstreamStatus("HTTP/1.1-200 OK\r\n\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseUpstreamStatus("HTTP/1.1 abc OK\r\n\r\n"));
    try std.testing.expectEqual(@as(?u16, null), parseUpstreamStatus("HTTP/2 200 OK\r\n\r\n")); // not HTTP/1.x
}

test "parseUpstreamStatus: short buffer" {
    try std.testing.expectEqual(@as(?u16, null), parseUpstreamStatus(""));
    try std.testing.expectEqual(@as(?u16, null), parseUpstreamStatus("HTTP/1.1 2"));
}
