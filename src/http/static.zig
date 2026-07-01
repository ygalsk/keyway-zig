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

/// Format a Unix timestamp as HTTP-date (RFC 7231).
fn formatHttpDate(buf: *[29]u8, epoch_secs: i64) void {
    const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epoch_secs)) };
    const day_seconds = epoch.getDaySeconds();
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Day of week: Jan 1 1970 was Thursday (days[0])
    const dow_idx: usize = @intCast(@mod(@as(i64, @intCast(epoch_day.day)), 7));

    _ = std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days[dow_idx],
        month_day.day_index + 1,
        months[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch {};
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

/// Serve a static file. Called from handler.zig routeRequest.
pub fn serveStaticFile(
    self: *Connection,
    request: *const http.Request,
    route: router_mod.StaticRoute,
    suffix: []const u8,
) void {
    const alloc = self.arena.allocator();

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
            return;
        }
    }

    // Resolve to absolute path and verify it's within root
    const components = [_][]const u8{ route.root, rel_path };
    const resolved = std.fs.path.resolve(alloc, &components) catch {
        self.logAccess(500);
        self.send500InternalError();
        return;
    };

    // Verify resolved path starts with root (prevent traversal)
    const root_resolved = std.fs.path.resolve(alloc, &[_][]const u8{route.root}) catch {
        self.logAccess(500);
        self.send500InternalError();
        return;
    };
    if (!std.mem.startsWith(u8, resolved, root_resolved)) {
        self.logAccess(403);
        error_response.sendErrorStatus(self, 403, "path traversal blocked");
        return;
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
            return;
        };
        break :blk alloc.dupe(u8, pbuf[0..n]) catch {
            self.logAccess(500);
            self.send500InternalError();
            return;
        };
    };
    if (!std.mem.startsWith(u8, real_resolved, route.real_root)) {
        self.logAccess(403);
        error_response.sendErrorStatus(self, 403, "symlink traversal blocked");
        return;
    }

    // Open the file (use real_resolved — it's always absolute after realpathAlloc)
    const resolved_z = alloc.dupeZ(u8, real_resolved) catch {
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

    // Check If-None-Match (use already-parsed headers, not raw buffer)
    if (http.Parser.getHeader(request, "If-None-Match")) |inm| {
        if (std.mem.eql(u8, inm, etag)) {
            helpers.closeFd(fd);
            self.logAccess(304);
            self.sendRawResponse("HTTP/1.1 304 Not Modified\r\nContent-Length: 0\r\n\r\n");
            return;
        }
    }

    const content_type = getContentType(resolved);

    // Build response headers
    var last_modified_buf: [29]u8 = undefined;
    formatHttpDate(&last_modified_buf, mtime_sec);

    const headers_text = std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nETag: {s}\r\nLast-Modified: {s}\r\nCache-Control: public, max-age=3600\r\n\r\n", .{
        content_type,
        file_size,
        etag,
        &last_modified_buf,
    }) catch {
        helpers.closeFd(fd);
        self.logAccess(500);
        self.send500InternalError();
        return;
    };

    self.logAccess(200);

    if (file_size == 0) {
        // Empty file — just send headers
        helpers.closeFd(fd);
        self.sendRawResponse(headers_text);
        return;
    }

    // Send headers first, then drive an async pread+send loop. Files up to
    // STATIC_READ_SIZE complete in a single chunk; larger files span several.
    const read_buf = self.base_allocator.alloc(u8, config.STATIC_READ_SIZE) catch {
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

    const bytes_read = result.pread catch |err| {
        if (err == error.EOF) {
            // File truncated under us — stop, send what was already delivered.
            finishStaticFile(self);
        } else {
            self.close();
        }
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

test "formatHttpDate produces valid format" {
    var buf: [29]u8 = undefined;
    // Unix epoch: Thu, 01 Jan 1970 00:00:00 GMT
    formatHttpDate(&buf, 0);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &buf);
}
