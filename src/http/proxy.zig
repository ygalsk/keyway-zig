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
//! Known gaps tracked as follow-ups: no upstream deadline (#72), access status
//! always logged as 200 (#73).

const std = @import("std");
const xev = @import("xev");
const handler_mod = @import("../core/handler.zig");
const Connection = handler_mod.Connection;
const http = @import("http.zig");
const castUserdata = @import("../util/helpers.zig").castUserdata;
const error_response = @import("error_response.zig");
const router_mod = @import("router.zig");

/// Size of each upstream recv chunk (bytes), appended to the response buffer.
const RECV_CHUNK = 16384;

/// State for an in-progress reverse-proxy exchange.
///
/// Owned by base_allocator so its address is stable across the async ops.
/// Exactly one upstream completion is in flight at a time, so a single
/// `completion` drives the connect → send → recv phases — never submit a new
/// upstream op except from inside the previous op's callback.
pub const ProxyState = struct {
    upstream_fd: std.posix.socket_t,
    completion: xev.Completion = .{},
    request_buf: []const u8, // upstream request bytes (headers + body); outlives the send
    sent: usize = 0, // bytes of request_buf already sent (short-send loop)
    recv_buf: []u8, // fixed-size upstream recv chunk
    response: std.ArrayListUnmanaged(u8) = .{}, // accumulated upstream response

    pub fn deinit(self: *ProxyState, allocator: std.mem.Allocator) void {
        std.posix.close(self.upstream_fd);
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

    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        self.base_allocator.free(request_buf);
        error_response.sendErrorStatus(self, 502, "proxy socket creation failed");
        return;
    };

    const recv_buf = self.base_allocator.alloc(u8, RECV_CHUNK) catch {
        std.posix.close(sock);
        self.base_allocator.free(request_buf);
        error_response.sendErrorStatus(self, 502, "proxy buffer alloc failed");
        return;
    };

    self.proxy_state = .{
        .upstream_fd = sock,
        .request_buf = request_buf,
        .recv_buf = recv_buf,
    };
    self.state = .proxying;

    // Async connect to the pre-resolved upstream address.
    const ps = &self.proxy_state.?;
    ps.completion = .{
        .op = .{ .connect = .{ .socket = sock, .addr = route.upstream_addr } },
        .userdata = self,
        .callback = onProxyConnect,
    };
    self.pending_io_ops += 1;
    self.loop.add(&ps.completion);
}

/// Build the HTTP/1.1 request to send upstream: request line, rewritten Host,
/// forced `Connection: close`, forwarded client headers, then the body.
fn buildUpstreamRequest(
    allocator: std.mem.Allocator,
    request: *const http.Request,
    route: router_mod.ProxyRoute,
    upstream_path: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.print("{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n", .{
        request.method,
        upstream_path,
        route.upstream_host,
        route.upstream_port,
    });
    for (request.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
        try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try writer.writeAll("\r\n");
    if (request.body.len > 0) try buf.appendSlice(allocator, request.body);

    return try buf.toOwnedSlice(allocator);
}

/// Connect completed — start sending the upstream request.
fn onProxyConnect(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    self.pending_io_ops -= 1;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    _ = result.connect catch {
        proxyFail(self, 502, "proxy upstream connect failed");
        return .disarm;
    };
    submitUpstreamSend(self);
    return .disarm;
}

/// Submit a send of the not-yet-sent tail of the upstream request.
fn submitUpstreamSend(self: *Connection) void {
    const ps = &self.proxy_state.?;
    ps.completion = .{
        .op = .{ .send = .{ .fd = ps.upstream_fd, .buffer = .{ .slice = ps.request_buf[ps.sent..] } } },
        .userdata = self,
        .callback = onProxyUpstreamSent,
    };
    self.pending_io_ops += 1;
    self.loop.add(&ps.completion);
}

/// A send completed — loop on short sends, then start reading the response.
fn onProxyUpstreamSent(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    self.pending_io_ops -= 1;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    const n = result.send catch {
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
    ps.completion = .{
        .op = .{ .recv = .{ .fd = ps.upstream_fd, .buffer = .{ .slice = ps.recv_buf } } },
        .userdata = self,
        .callback = onProxyUpstreamRecv,
    };
    self.pending_io_ops += 1;
    self.loop.add(&ps.completion);
}

/// A recv completed — accumulate the chunk and keep reading until EOF.
fn onProxyUpstreamRecv(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    self.pending_io_ops -= 1;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    const n = result.recv catch |err| {
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

/// Relay the buffered upstream response to the client and tear down proxy state.
fn forwardProxyResponse(self: *Connection) void {
    const ps = &self.proxy_state.?;
    if (ps.response.items.len == 0) {
        proxyFail(self, 502, "proxy upstream empty response");
        return;
    }
    self.logAccess(200);
    // sendRawResponse arena-dupes the bytes before queuing the send, so the
    // proxy_state buffers can be freed immediately afterward. State becomes
    // .writing; onWrite → handleHttpPostWrite resumes keep-alive.
    self.sendRawResponse(ps.response.items);
    cleanupProxy(self);
}

/// Send an error to the client and tear down proxy state. Safe to call from any
/// upstream callback: we are inside the only in-flight op (already decremented),
/// so no upstream completion references the fd we close here.
fn proxyFail(self: *Connection, status: u16, internal_msg: []const u8) void {
    cleanupProxy(self);
    error_response.sendErrorStatus(self, status, internal_msg);
}

fn cleanupProxy(self: *Connection) void {
    if (self.proxy_state) |*ps| {
        ps.deinit(self.base_allocator);
        self.proxy_state = null;
    }
}
