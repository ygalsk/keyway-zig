//! Static file serving — async pread + send, with ETag/Last-Modified caching.
//!
//! Zig-native, no Lua involvement. Route configuration via keyway.static.
//! Headers are sent first, then the body is streamed via an async pread+send
//! loop (one chunk per STATIC_READ_SIZE) using Content-Length (size from stat).
//! pread runs on the worker's xev loop (io_uring), never blocking it.
//!
//! Path safety: std.fs.path.resolve + verify result starts with configured root.

const std = @import("std");
const xev = @import("xev");
const handler_mod = @import("../core/handler.zig");
const Connection = handler_mod.Connection;
const http = @import("http.zig");
const config = @import("../util/config.zig");
const castUserdata = @import("../util/helpers.zig").castUserdata;
const helpers = @import("../util/helpers.zig");
const error_response = @import("error_response.zig");
const router_mod = @import("router.zig");

/// State for in-progress static file serving.
pub const StaticState = struct {
    fd: std.posix.fd_t,
    file_size: u64,
    bytes_sent: u64,
    read_buf: []u8,
    pread_completion: xev.Completion = .{},

    pub fn deinit(self: *StaticState, allocator: std.mem.Allocator) void {
        helpers.closeFd(self.fd);
        allocator.free(self.read_buf);
    }
};

/// Comptime MIME type lookup table: extension → Content-Type.
const mime_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".html", "text/html; charset=utf-8" },
    .{ ".htm", "text/html; charset=utf-8" },
    .{ ".css", "text/css; charset=utf-8" },
    .{ ".js", "application/javascript; charset=utf-8" },
    .{ ".mjs", "application/javascript; charset=utf-8" },
    .{ ".json", "application/json; charset=utf-8" },
    .{ ".xml", "text/xml; charset=utf-8" },
    .{ ".txt", "text/plain; charset=utf-8" },
    .{ ".csv", "text/csv; charset=utf-8" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".jpeg", "image/jpeg" },
    .{ ".gif", "image/gif" },
    .{ ".svg", "image/svg+xml" },
    .{ ".ico", "image/x-icon" },
    .{ ".webp", "image/webp" },
    .{ ".avif", "image/avif" },
    .{ ".woff", "font/woff" },
    .{ ".woff2", "font/woff2" },
    .{ ".ttf", "font/ttf" },
    .{ ".otf", "font/otf" },
    .{ ".eot", "application/vnd.ms-fontobject" },
    .{ ".pdf", "application/pdf" },
    .{ ".zip", "application/zip" },
    .{ ".gz", "application/gzip" },
    .{ ".wasm", "application/wasm" },
    .{ ".mp4", "video/mp4" },
    .{ ".webm", "video/webm" },
    .{ ".mp3", "audio/mpeg" },
    .{ ".ogg", "audio/ogg" },
    .{ ".map", "application/json" },
});

fn getContentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return mime_types.get(ext) orelse "application/octet-stream";
}

/// Parse an RFC 7231 IMF-fixdate ("Sun, 06 Nov 1994 08:49:37 GMT") to epoch
/// seconds. Returns null on any deviation (caller then serves 200).
// ponytail: IMF-fixdate only (the format we emit); other HTTP-date forms fall through to 200
fn parseHttpDate(s: []const u8) ?i64 {
    // "Www, DD Mon YYYY HH:MM:SS GMT"
    if (s.len < 29) return null;
    const day = std.fmt.parseInt(u32, std.mem.trim(u8, s[5..7], " "), 10) catch return null;
    const month = monthIndex(s[8..11]) orelse return null;
    const year = std.fmt.parseInt(i64, s[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    const min = std.fmt.parseInt(i64, s[20..22], 10) catch return null;
    const sec = std.fmt.parseInt(i64, s[23..25], 10) catch return null;
    const days = daysFromCivil(year, month, day);
    return days * 86400 + hour * 3600 + min * 60 + sec;
}

fn monthIndex(m: []const u8) ?u32 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (names, 1..) |name, i| if (std.mem.eql(u8, m, name)) return @intCast(i);
    return null;
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    const y = y_in - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp: i64 = @intCast((m + (if (m > 2) @as(u32, 0) else 12) - 3)); // Mar=0..Feb=11
    const doy = @divTrunc(153 * mp + 2, 5) + @as(i64, d) - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Map a static-file I/O error to an HTTP response.
/// A missing entry is the client's problem (404); permissions, I/O, fd
/// exhaustion, etc. are the server failing to read its own files (500).
fn sendStaticError(self: *Connection, err: anyerror, server_msg: []const u8) void {
    switch (err) {
        error.FileNotFound, error.NotDir => {
            self.logAccess(404);
            error_response.sendErrorStatus(self, 404, "static file not found");
        },
        else => {
            self.logAccess(500);
            error_response.sendErrorStatus(self, 500, server_msg);
        },
    }
}

/// Result of resolving a requested suffix to a file on disk.
const StaticPath = struct {
    /// Route-root + suffix, traversal-checked, NOT symlink-resolved. Content-type
    /// is derived from this — a symlink's target extension (e.g. a `.css` route
    /// pointing at a `.txt` file) shouldn't override what the client requested.
    requested: []const u8,
    /// Symlink-resolved absolute path — used to open the file.
    real: []const u8,
};

/// True if `path` is `root` itself or a descendant — startsWith plus a segment
/// boundary, so "/x/public-secret" is NOT within "/x/public".
fn isWithinRoot(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == std.fs.path.sep;
}

/// Resolve `suffix` against `route` to an absolute, symlink-resolved path
/// verified to stay within the route root. Returns null after sending an
/// error response (400/403/500) if resolution fails.
fn resolveStaticPath(
    self: *Connection,
    alloc: std.mem.Allocator,
    route: router_mod.StaticRoute,
    suffix: []const u8,
) ?StaticPath {
    // Determine the file path within root
    const rel_path = if (suffix.len == 0 or std.mem.eql(u8, suffix, "/"))
        route.index
    else if (suffix[0] == '/')
        suffix[1..] // strip leading /
    else
        suffix;

    // Path safety: reject null bytes and obvious traversal
    for (rel_path) |ch| {
        if (ch == 0) {
            self.logAccess(400);
            error_response.sendErrorStatus(self, 400, "null byte in path");
            return null;
        }
    }

    // Resolve to absolute path and verify it's within root
    const components = [_][]const u8{ route.root, rel_path };
    const resolved = std.fs.path.resolve(alloc, &components) catch {
        self.logAccess(500);
        self.send500InternalError();
        return null;
    };

    // Verify resolved path starts with root (prevent traversal)
    const root_resolved = std.fs.path.resolve(alloc, &[_][]const u8{route.root}) catch {
        self.logAccess(500);
        self.send500InternalError();
        return null;
    };
    if (!isWithinRoot(resolved, root_resolved)) {
        self.logAccess(403);
        error_response.sendErrorStatus(self, 403, "path traversal blocked");
        return null;
    }

    // Resolve symlinks and verify the real path is still within root.
    // real_root was resolved once at route registration (avoids per-request realpathAlloc).
    var resolve_io: std.Io.Threaded = .init(alloc, .{});
    defer resolve_io.deinit();
    const real_resolved = blk: {
        // realPathFile canonicalizes a file path (openDir would fail with NotDir on a regular file).
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPathFile(resolve_io.io(), resolved, &pbuf) catch |err| {
            sendStaticError(self, err, "static realpath failed");
            return null;
        };
        break :blk alloc.dupe(u8, pbuf[0..n]) catch {
            self.logAccess(500);
            self.send500InternalError();
            return null;
        };
    };
    if (!isWithinRoot(real_resolved, route.real_root)) {
        self.logAccess(403);
        error_response.sendErrorStatus(self, 403, "symlink traversal blocked");
        return null;
    }

    return .{ .requested = resolved, .real = real_resolved };
}

/// Build the response headers text: status line, content-type, length, ETag,
/// Last-Modified, cache-control. Pure formatting — no I/O, no error response.
fn buildStaticHeaders(
    alloc: std.mem.Allocator,
    content_type: []const u8,
    file_size: u64,
    etag: []const u8,
    mtime_sec: i64,
) ![]const u8 {
    var last_modified_buf: [29]u8 = undefined;
    helpers.formatHttpDate(&last_modified_buf, mtime_sec);
    var date_buf: [29]u8 = undefined;
    helpers.formatHttpDate(&date_buf, helpers.realtimeSeconds());

    return std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nETag: {s}\r\nLast-Modified: {s}\r\nDate: {s}\r\nCache-Control: public, max-age=3600\r\n\r\n", .{
        content_type,
        file_size,
        etag,
        &last_modified_buf,
        &date_buf,
    });
}

/// RFC 9110 §13.1.2: If-None-Match is a comma-separated list of entity-tags
/// or "*". The GET/HEAD 304 check uses weak comparison, so a "W/" weak
/// indicator is ignored. Our own ETag is strong (no W/ prefix).
fn ifNoneMatchMatches(header_value: []const u8, etag: []const u8) bool {
    var it = std.mem.splitScalar(u8, header_value, ',');
    while (it.next()) |raw| {
        var tok = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, tok, "*")) return true;
        if (std.mem.startsWith(u8, tok, "W/")) tok = tok[2..];
        if (etag.len != 0 and std.mem.eql(u8, tok, etag)) return true;
    }
    return false;
}

/// Serve a static file. Called from handler.zig routeRequest.
pub fn serveStaticFile(
    self: *Connection,
    request: *const http.Request,
    route: router_mod.StaticRoute,
    suffix: []const u8,
) void {
    const alloc = self.arena.allocator();

    const path = resolveStaticPath(self, alloc, route, suffix) orelse return;

    // Open the file (use path.real — it's always absolute after realpathAlloc)
    const resolved_z = alloc.dupeZ(u8, path.real) catch {
        self.logAccess(500);
        self.send500InternalError();
        return;
    };
    var open_io: std.Io.Threaded = .init(alloc, .{});
    defer open_io.deinit();
    const file = std.Io.Dir.openFileAbsolute(open_io.io(), resolved_z, .{}) catch |err| {
        sendStaticError(self, err, "static file open failed");
        return;
    };
    const fd = file.handle;

    // Stat for size + mtime
    const stat = file.stat(open_io.io()) catch {
        helpers.closeFd(fd);
        self.logAccess(500);
        self.send500InternalError();
        return;
    };

    // Reject directories
    if (stat.kind == .directory) {
        helpers.closeFd(fd);
        self.logAccess(403);
        error_response.sendErrorStatus(self, 403, "is a directory");
        return;
    }

    const file_size: u64 = stat.size;

    // Size limit check
    if (file_size > config.STATIC_MAX_SIZE) {
        helpers.closeFd(fd);
        self.logAccess(413);
        error_response.sendErrorStatus(self, 413, "file too large");
        return;
    }

    // ETag: use inode + mtime + size
    const mtime_ns: i96 = stat.mtime.nanoseconds;
    const mtime_sec: i64 = @intCast(@divFloor(mtime_ns, std.time.ns_per_s));
    var etag_buf: [64]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "\"{x}-{x}-{x}\"", .{
        stat.inode,
        mtime_ns,
        file_size,
    }) catch "";

    // Check If-None-Match (use already-parsed headers, not raw buffer).
    // If-None-Match takes precedence over If-Modified-Since (RFC 7232 §6):
    // when present but not matching, serve full — do not consult IMS.
    if (http.getHeader(request, "If-None-Match")) |inm| {
        if (ifNoneMatchMatches(inm, etag)) {
            helpers.closeFd(fd);
            self.logAccess(304);
            self.sendRawResponse("HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\n\r\n");
            return;
        }
    } else if (http.getHeader(request, "If-Modified-Since")) |ims| {
        if (parseHttpDate(ims)) |ims_secs| {
            if (mtime_sec <= ims_secs) {
                helpers.closeFd(fd);
                self.logAccess(304);
                self.sendRawResponse("HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\n\r\n");
                return;
            }
        }
    }

    const content_type = getContentType(path.requested);
    const headers_text = buildStaticHeaders(alloc, content_type, file_size, etag, mtime_sec) catch {
        helpers.closeFd(fd);
        self.logAccess(500);
        self.send500InternalError();
        return;
    };

    self.logAccess(200);

    if (std.mem.eql(u8, request.method, "HEAD") or file_size == 0) {
        // HEAD: RFC 7231 §4.3.2 — identical headers to GET, no message body.
        helpers.closeFd(fd);
        self.sendRawResponse(headers_text);
        return;
    }

    // Send headers first, then drive an async pread+send loop. Files up to
    // STATIC_READ_SIZE complete in a single chunk; larger files span several.
    // read_buf is sized to the smaller of the two so small files don't pay
    // for a full 64 KB allocation.
    const read_buf = self.base_allocator.alloc(u8, @min(file_size, config.STATIC_READ_SIZE)) catch {
        helpers.closeFd(fd);
        self.send500InternalError();
        return;
    };

    self.static_state = .{
        .fd = fd,
        .file_size = file_size,
        .bytes_sent = 0,
        .read_buf = read_buf,
    };
    self.state = .static_file;
    self.submitSend(headers_text, onStaticHeadersSent, false);
}

/// Callback after headers are sent — start pread+send loop.
fn onStaticHeadersSent(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;
    sendNextChunk(self);
    return .disarm;
}

/// Submit an async pread for the next chunk from the file.
fn sendNextChunk(self: *Connection) void {
    const ss = &self.static_state.?;

    if (ss.bytes_sent >= ss.file_size) {
        // Done — clean up and return to keep-alive
        finishStaticFile(self);
        return;
    }

    const remaining = ss.file_size - ss.bytes_sent;
    const to_read = @min(remaining, ss.read_buf.len);

    // Async pread on the worker's xev loop (io_uring) — never blocks. The
    // completion lives in StaticState (stable address until the read fires).
    ss.pread_completion = .{
        .op = .{ .pread = .{
            .fd = ss.fd,
            .buffer = .{ .slice = ss.read_buf[0..to_read] },
            .offset = ss.bytes_sent,
        } },
        .userdata = self,
        .callback = onStaticPreadComplete,
    };
    self.pending_io_ops += 1;
    self.loop.add(&ss.pread_completion);
}

/// Callback after an async pread completes — send the chunk we just read.
fn onStaticPreadComplete(
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

    const bytes_read = result.pread catch {
        // pread failed, or hit EOF before file_size (file shrank mid-transfer):
        // either way fewer bytes than the promised Content-Length were sent, so
        // the client's framing is desynced and unrecoverable — close instead of
        // returning to keep-alive. (A pread is only submitted while
        // bytes_sent < file_size, so EOF here always means a short body.)
        self.close();
        return .disarm;
    };

    const ss = &self.static_state.?;
    ss.bytes_sent += bytes_read;

    // read_buf is stable during the async send — it is overwritten only by the
    // next pread, which is submitted from onStaticChunkSent after the send fires.
    self.submitSend(ss.read_buf[0..bytes_read], onStaticChunkSent, false);
    return .disarm;
}

/// Callback after a static file chunk is sent — continue or finish.
fn onStaticChunkSent(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;
    sendNextChunk(self);
    return .disarm;
}

/// Clean up static file state and return to HTTP keep-alive.
fn finishStaticFile(self: *Connection) void {
    if (self.static_state) |*ss| {
        ss.deinit(self.base_allocator);
        self.static_state = null;
    }
    self.state = .writing;
    // Reuse handleHttpPostWrite for keep-alive/pipelining reset
    self.handleHttpPostWrite();
}

// =============================================================================
// Tests
// =============================================================================

test "getContentType returns correct MIME types" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", getContentType("/index.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", getContentType("/app.js"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", getContentType("/style.css"));
    try std.testing.expectEqualStrings("image/png", getContentType("/logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", getContentType("/unknown.xyz"));
    try std.testing.expectEqualStrings("application/wasm", getContentType("/module.wasm"));
}

test "getContentType handles no extension" {
    try std.testing.expectEqualStrings("application/octet-stream", getContentType("/Makefile"));
}

test "buildStaticHeaders formats status line and cache headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const headers = try buildStaticHeaders(arena.allocator(), "text/plain; charset=utf-8", 42, "\"abc\"", 0);
    try std.testing.expect(std.mem.startsWith(u8, headers, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, headers, "Content-Type: text/plain; charset=utf-8\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "Content-Length: 42\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "ETag: \"abc\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "Last-Modified: Thu, 01 Jan 1970 00:00:00 GMT\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "Date: ") != null);
}

test "isWithinRoot enforces a segment boundary, not just a string prefix" {
    try std.testing.expect(isWithinRoot("/x/public", "/x/public"));
    try std.testing.expect(isWithinRoot("/x/public/a.css", "/x/public"));
    try std.testing.expect(!isWithinRoot("/x/public-secret/s.txt", "/x/public"));
    try std.testing.expect(!isWithinRoot("/x/pub", "/x/public"));
}

test "ifNoneMatchMatches: exact match" {
    try std.testing.expect(ifNoneMatchMatches("\"abc\"", "\"abc\""));
    try std.testing.expect(!ifNoneMatchMatches("\"xyz\"", "\"abc\""));
}

test "ifNoneMatchMatches: comma-separated list" {
    try std.testing.expect(ifNoneMatchMatches("\"wrong-one\", \"abc\"", "\"abc\""));
    try std.testing.expect(ifNoneMatchMatches("\"abc\", \"wrong-one\"", "\"abc\""));
    try std.testing.expect(!ifNoneMatchMatches("\"wrong-one\", \"also-wrong\"", "\"abc\""));
}

test "ifNoneMatchMatches: wildcard matches anything" {
    try std.testing.expect(ifNoneMatchMatches("*", "\"abc\""));
}

test "ifNoneMatchMatches: weak indicator is ignored" {
    try std.testing.expect(ifNoneMatchMatches("W/\"abc\"", "\"abc\""));
    try std.testing.expect(ifNoneMatchMatches("\"wrong\", W/\"abc\"", "\"abc\""));
}

test "parseHttpDate round-trips formatHttpDate" {
    // 784111777 = Sun, 06 Nov 1994 08:49:37 GMT
    var buf: [29]u8 = undefined;
    helpers.formatHttpDate(&buf, 784111777);
    try std.testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", &buf);
    try std.testing.expectEqual(@as(?i64, 784111777), parseHttpDate(&buf));

    var epoch_buf: [29]u8 = undefined;
    helpers.formatHttpDate(&epoch_buf, 0);
    try std.testing.expectEqual(@as(?i64, 0), parseHttpDate(&epoch_buf));

    try std.testing.expectEqual(@as(?i64, null), parseHttpDate("not a date"));
}
