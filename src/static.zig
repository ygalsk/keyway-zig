//! Static file serving — pread into arena + send, with ETag/Last-Modified caching.
//!
//! Zig-native, no Lua involvement. Route configuration via keyway.static.
//! Small files (< STATIC_READ_SIZE) are served in a single read+send.
//! Large files are served via pread+send loop using Content-Length (size known from stat).
//!
//! Path safety: std.fs.path.resolve + verify result starts with configured root.

const std = @import("std");
const xev = @import("xev");
const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const http = @import("http.zig");
const config = @import("config.zig");
const castUserdata = @import("helpers.zig").castUserdata;
const error_response = @import("error_response.zig");
const router_mod = @import("router.zig");

/// State for in-progress static file serving.
pub const StaticState = struct {
    fd: std.posix.fd_t,
    file_size: u64,
    bytes_sent: u64,
    read_buf: []u8,

    pub fn deinit(self: *StaticState, allocator: std.mem.Allocator) void {
        std.posix.close(self.fd);
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

    // Day of week: Jan 1 1970 was Thursday (index 0)
    const dow_idx: usize = @intCast(@mod(@as(i64, @intCast(epoch_day.day)) + 4, 7));

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
    const real_resolved = std.fs.cwd().realpathAlloc(alloc, resolved) catch {
        self.logAccess(404);
        self.send404NotFound();
        return;
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
    const file = std.fs.openFileAbsoluteZ(resolved_z, .{}) catch {
        self.logAccess(404);
        self.send404NotFound();
        return;
    };
    const fd = file.handle;

    // Stat for size + mtime
    const stat = std.posix.fstat(fd) catch {
        std.posix.close(fd);
        self.logAccess(500);
        self.send500InternalError();
        return;
    };

    // Reject directories
    if (stat.mode & std.posix.S.IFMT == std.posix.S.IFDIR) {
        std.posix.close(fd);
        self.logAccess(403);
        error_response.sendErrorStatus(self, 403, "is a directory");
        return;
    }

    const file_size: u64 = @intCast(@max(0, stat.size));

    // Size limit check
    if (file_size > config.STATIC_MAX_SIZE) {
        std.posix.close(fd);
        self.logAccess(413);
        error_response.sendErrorStatus(self, 413, "file too large");
        return;
    }

    // ETag: use inode + mtime + size
    const mtime_sec = stat.mtim.sec;
    var etag_buf: [64]u8 = undefined;
    const etag = std.fmt.bufPrint(&etag_buf, "\"{x}-{x}-{x}\"", .{
        @as(u64, @bitCast(stat.ino)),
        @as(u64, @bitCast(mtime_sec)),
        file_size,
    }) catch "";

    // Check If-None-Match (use already-parsed headers, not raw buffer)
    if (http.Parser.getHeader(request, "If-None-Match")) |inm| {
        if (std.mem.eql(u8, inm, etag)) {
            std.posix.close(fd);
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
        std.posix.close(fd);
        self.logAccess(500);
        self.send500InternalError();
        return;
    };

    self.logAccess(200);

    if (file_size == 0) {
        // Empty file — just send headers
        std.posix.close(fd);
        self.sendRawResponse(headers_text);
        return;
    }

    // Small file fast path: single allocation, pread directly into combined buffer
    if (file_size <= config.STATIC_READ_SIZE) {
        const combined = alloc.alloc(u8, headers_text.len + @as(usize, @intCast(file_size))) catch {
            std.posix.close(fd);
            self.send500InternalError();
            return;
        };
        @memcpy(combined[0..headers_text.len], headers_text);
        const bytes_read = std.posix.pread(fd, combined[headers_text.len..], 0) catch {
            std.posix.close(fd);
            self.send500InternalError();
            return;
        };
        std.posix.close(fd);
        self.sendRawResponse(combined[0 .. headers_text.len + bytes_read]);
        return;
    }

    // Large file: send headers first, then pread+send loop
    const read_buf = self.base_allocator.alloc(u8, config.STATIC_READ_SIZE) catch {
        std.posix.close(fd);
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

/// Read the next chunk from file and send it.
fn sendNextChunk(self: *Connection) void {
    const ss = &self.static_state.?;

    if (ss.bytes_sent >= ss.file_size) {
        // Done — clean up and return to keep-alive
        finishStaticFile(self);
        return;
    }

    const remaining = ss.file_size - ss.bytes_sent;
    const to_read = @min(remaining, ss.read_buf.len);

    const bytes_read = std.posix.pread(ss.fd, ss.read_buf[0..to_read], ss.bytes_sent) catch {
        self.close();
        return;
    };

    if (bytes_read == 0) {
        // EOF before expected — file truncated
        finishStaticFile(self);
        return;
    }

    ss.bytes_sent += bytes_read;

    // read_buf is stable during async send — pread overwrites it only in sendNextChunk,
    // which runs after onStaticChunkSent fires. No dupe needed.
    self.submitSend(ss.read_buf[0..bytes_read], onStaticChunkSent, false);
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
    self.handleHttpPostWrite(0);
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
