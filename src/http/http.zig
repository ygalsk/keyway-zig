const std = @import("std");
const config = @import("../util/config.zig");
const helpers = @import("../util/helpers.zig");

// Picohttpparser C bindings
const c = @cImport({
    @cInclude("picohttpparser.h");
});

/// HTTP request
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    headers: []Header,
    body: []const u8,
    /// Total bytes consumed from input buffer (headers + body per Content-Length)
    raw_len: usize,
    /// True if the connection should be closed after this request's response
    /// is written (#204): client sent `Connection: close`, or HTTP/1.0
    /// without an explicit `Connection: keep-alive`. Defaulted so existing
    /// test call sites that build a Request directly don't need updating.
    wants_close: bool = false,
};

/// HTTP response
pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    headers: std.ArrayList(Header) = .empty,
    body: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Response {
        return Response{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
    }

    /// Add a header to the response (O(1) amortized)
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.append(self.allocator, Header{ .name = name, .value = value });
    }

    /// Comptime-generated status line table indexed by HTTP status code.
    /// Each entry is a complete "HTTP/1.1 NNN Reason\r\n" string, enabling
    /// single-memcpy serialization with no runtime formatting. Reason phrases
    /// come from std.http.Status; unmapped codes fall back to "Unknown".
    const status_lines = blk: {
        @setEvalBranchQuota(100_000);
        var table: [600][]const u8 = undefined;
        for (0..600) |code| {
            const phrase = @as(std.http.Status, @enumFromInt(code)).phrase() orelse "Unknown";
            const digits = [3]u8{
                '0' + @as(u8, @intCast(code / 100)),
                '0' + @as(u8, @intCast((code / 10) % 10)),
                '0' + @as(u8, @intCast(code % 10)),
            };
            table[code] = "HTTP/1.1 " ++ &digits ++ " " ++ phrase ++ "\r\n";
        }
        break :blk table;
    };

    /// Serialize HTTP response headers with Transfer-Encoding: chunked (no Content-Length, no body).
    /// Used for streaming responses where body is sent as subsequent chunks.
    pub fn serializeChunkedHeaders(self: *Response, writer: anytype) !void {
        const code: usize = @min(self.status, status_lines.len - 1);
        try writer.writeAll(status_lines[code]);

        for (self.headers.items) |header| {
            if (isEngineOwnedHeader(header.name)) continue;
            if (std.mem.indexOfAny(u8, header.name, "\r\n") != null) continue;
            if (std.mem.indexOfAny(u8, header.value, "\r\n") != null) continue;
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        try writer.writeAll("Transfer-Encoding: chunked\r\n\r\n");
    }

    /// Serialize response to HTTP/1.1 format
    pub fn serialize(self: *Response, writer: anytype) !void {
        // Status line — single memcpy from comptime table
        const code: usize = @min(self.status, status_lines.len - 1);
        try writer.writeAll(status_lines[code]);

        // Headers
        for (self.headers.items) |header| {
            if (isEngineOwnedHeader(header.name)) continue;
            if (std.mem.indexOfAny(u8, header.name, "\r\n") != null) continue;
            if (std.mem.indexOfAny(u8, header.value, "\r\n") != null) continue;
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        // RFC 9110 §6.6.1: an origin server with a clock SHOULD generate a
        // Date on every response it emits (#238). One vDSO read per
        // response — no per-second caching (ponytail: add if profiling ever
        // shows this line matters).
        {
            var date_buf: [29]u8 = undefined;
            helpers.formatHttpDate(&date_buf, helpers.realtimeSeconds());
            try writer.print("Date: {s}\r\n", .{&date_buf});
        }

        // RFC 9110 §6.4.1 / §15.3.5: 1xx, 204, and 304 responses carry no body.
        // Suppress the engine Content-Length too (simplest and RFC-clean for
        // all three). The 101 handshake is emitted as a raw response by
        // conn_ws (not via serialize) — this only fires if a tenant sets
        // ctx.status to one of these, in which case no-body is correct (#194, #206).
        const no_body = self.status < 200 or self.status == 204 or self.status == 304;

        if (!no_body) {
            try writer.print("Content-Length: {d}\r\n", .{self.body.len});
        }

        // Blank line
        try writer.writeAll("\r\n");

        // Body
        if (!no_body) {
            try writer.writeAll(self.body);
        }
    }
};

/// HTTP header
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Headers the engine owns and emits itself — a tenant setting these could
/// desync framing (request smuggling) or hijack keep-alive. Case-insensitive,
/// and whitespace-trimmed so "Content-Length " (a lenient-intermediary
/// smuggling obfuscation) is still recognized and stripped.
fn isEngineOwnedHeader(name: []const u8) bool {
    const n = std.mem.trim(u8, name, " \t");
    return std.ascii.eqlIgnoreCase(n, "content-length") or
        std.ascii.eqlIgnoreCase(n, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(n, "connection") or
        std.ascii.eqlIgnoreCase(n, "date");
}

/// True if `cl` could never be satisfied — the read buffer never grows past
/// config.READ_BUFFER_SIZE, so a Content-Length beyond it is either an
/// oversized body or (unchecked) an integer-overflow DoS on the
/// `bytes_consumed + cl` framing arithmetic below (#223).
fn exceedsReadBuffer(cl: usize) bool {
    return cl > config.READ_BUFFER_SIZE;
}

/// True if `s` is a valid HTTP field-value integer: 1*DIGIT, nothing else.
/// `std.fmt.parseInt` alone also accepts a leading '+', '-', and Zig's '_'
/// digit separators — none of which RFC 7230 permits for Content-Length.
fn isDigitsOnly(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |b| {
        if (!std.ascii.isDigit(b)) return false;
    }
    return true;
}

/// Convert picohttpparser's `phr_header` array into zero-copy `Header` slices,
/// rejecting obs-fold (#245).
///
/// picohttpparser *accepts* an obs-fold continuation line (a header line
/// starting with SP/HTAB) and signals it by setting `name = NULL, name_len = 0`
/// — it is the only way a NULL name reaches us, since a genuinely empty name
/// is already a -1 there. Slicing that NULL is a null deref, and letting it
/// through means the fold reaches routing and, on the proxy path, gets
/// re-emitted upstream as a bare `: value` line. RFC 9112 §5.2 says a server
/// must reject obs-fold with 400 rather than interpret it, so we do.
///
/// Both parse entry points funnel through here so the NULL can't come back:
/// the request path (client-triggered) and the response path (upstream-triggered).
fn toHeaders(allocator: std.mem.Allocator, c_headers: []const c.struct_phr_header) ![]Header {
    const headers = try allocator.alloc(Header, c_headers.len);
    for (c_headers, headers) |h, *out| {
        if (h.name == null) {
            allocator.free(headers);
            return error.InvalidRequest;
        }
        out.* = Header{
            .name = h.name[0..h.name_len],
            .value = h.value[0..h.value_len],
        };
    }
    return headers;
}

/// Parse HTTP request from buffer
/// Returns Request on success, error.Incomplete if partial, or other error
pub fn parseRequest(allocator: std.mem.Allocator, buf: []const u8) !Request {
    // Prepare C API parameters
    var method_ptr: [*c]const u8 = undefined;
    var method_len: usize = 0;
    var path_ptr: [*c]const u8 = undefined;
    var path_len: usize = 0;
    var minor_version: c_int = 0;

    // Allocate space for headers (max from config)
    const max_headers: usize = config.MAX_HEADERS;
    var c_headers: [max_headers]c.struct_phr_header = undefined;
    var num_headers: usize = max_headers;

    // Call picohttpparser
    const result = c.phr_parse_request(
        buf.ptr,
        buf.len,
        @ptrCast(&method_ptr),
        &method_len,
        @ptrCast(&path_ptr),
        &path_len,
        &minor_version,
        &c_headers,
        &num_headers,
        0, // last_len (0 for first parse)
    );

    if (result == -2) {
        return error.Incomplete; // Need more data
    }
    if (result == -1) {
        return error.InvalidRequest;
    }

    // Convert to Zig slices (zero-copy - pointers into buf)
    const method = method_ptr[0..method_len];
    const path = path_ptr[0..path_len];

    // Convert headers
    const headers = try toHeaders(allocator, c_headers[0..num_headers]);

    // Body: use Content-Length to determine exact body boundaries.
    // Without this, leftover body bytes corrupt the next keep-alive request.
    const bytes_consumed = @as(usize, @intCast(result));

    // Single pass over headers: collect Content-Length (rejecting malformed
    // values and duplicates whose parsed values disagree), the value of
    // the last Transfer-Encoding header (repeated TE headers combine per
    // RFC 7230 §3.3.2 — the final coding is what determines chunked-ness),
    // and Connection: close/keep-alive tokens (#204) — OR'd across any
    // repeated Connection headers.
    var content_length: ?usize = null;
    var transfer_encoding: ?[]const u8 = null;
    var host_count: usize = 0;
    var conn_close = false;
    var conn_keep_alive = false;
    for (headers) |h| {
        const name = h.name;
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            host_count += 1;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const val = h.value;
            if (!isDigitsOnly(val)) {
                allocator.free(headers);
                return error.InvalidRequest;
            }
            const parsed = std.fmt.parseInt(usize, val, 10) catch {
                allocator.free(headers);
                return error.InvalidRequest;
            };
            if (content_length) |existing| {
                if (existing != parsed) {
                    allocator.free(headers);
                    return error.InvalidRequest;
                }
            } else {
                content_length = parsed;
            }
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            transfer_encoding = h.value;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            var it = std.mem.splitScalar(u8, h.value, ',');
            while (it.next()) |tok| {
                const trimmed = std.mem.trim(u8, tok, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, "close")) conn_close = true;
                if (std.ascii.eqlIgnoreCase(trimmed, "keep-alive")) conn_keep_alive = true;
            }
        }
    }

    // RFC 9112 §9.6: HTTP/1.0 defaults to close unless the client asked
    // to keep-alive; any version closes if the client asked to close.
    const wants_close = conn_close or (minor_version == 0 and !conn_keep_alive);

    // RFC 9112 §3.2: an HTTP/1.1 request MUST have exactly one Host header.
    // HTTP/1.0 has no such requirement.
    if (minor_version == 1 and host_count != 1) {
        allocator.free(headers);
        return error.InvalidRequest;
    }

    // A request with both headers is the classic CL.TE/TE.CL smuggling
    // primitive — reject rather than picking a framing to trust (RFC 7230 §3.3.3).
    if (transfer_encoding != null and content_length != null) {
        allocator.free(headers);
        return error.InvalidRequest;
    }

    if (transfer_encoding) |te_val| {
        // Final coding is the last comma-separated token of the last TE header.
        const last_token = if (std.mem.lastIndexOfScalar(u8, te_val, ',')) |idx| te_val[idx + 1 ..] else te_val;
        const final_coding = std.mem.trim(u8, last_token, " \t");
        if (!std.ascii.eqlIgnoreCase(final_coding, "chunked")) {
            // Non-chunked final coding: body length is undeterminable.
            allocator.free(headers);
            return error.InvalidRequest;
        }

        // Decode chunked body: hex-size\r\n + data\r\n + ... + 0\r\n\r\n
        const chunk_data = buf[bytes_consumed..];
        const decoded = decodeChunkedBody(chunk_data, allocator) catch |err| {
            if (err == error.Incomplete) {
                allocator.free(headers);
                return error.Incomplete;
            }
            allocator.free(headers);
            return error.InvalidRequest;
        };
        return Request{
            .method = method,
            .path = path,
            .headers = headers,
            .body = decoded.body,
            .raw_len = bytes_consumed + decoded.total_consumed,
            .wants_close = wants_close,
        };
    }

    const cl = content_length orelse 0;
    if (exceedsReadBuffer(cl)) {
        allocator.free(headers);
        return error.RequestTooLarge;
    }
    const total_needed = bytes_consumed + cl;
    if (buf.len < total_needed) {
        // Body not fully received yet — need more data
        allocator.free(headers);
        return error.Incomplete;
    }

    const body = if (cl > 0) buf[bytes_consumed .. bytes_consumed + cl] else &[_]u8{};

    return Request{
        .method = method,
        .path = path,
        .headers = headers,
        .body = body,
        .raw_len = total_needed,
        .wants_close = wants_close,
    };
}

/// Find header value by name (case-insensitive)
pub fn getHeader(req: *const Request, name: []const u8) ?[]const u8 {
    for (req.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header.value;
        }
    }
    return null;
}

/// Parse an HTTP response's status line + headers from a buffer via
/// picohttpparser. Mirrors parseRequest, but for responses — used by the
/// reverse-proxy response path (proxy.zig's forwardProxyResponse) to
/// parse the buffered upstream response before stripping hop-by-hop
/// headers and re-emitting it to the client (#182). Body framing is the
/// caller's job: `head_len` is where the body starts in `buf`.
pub fn parseResponseHead(allocator: std.mem.Allocator, buf: []const u8) !ResponseHead {
    var minor_version: c_int = 0;
    var status: c_int = 0;
    var msg_ptr: [*c]const u8 = undefined;
    var msg_len: usize = 0;

    const max_headers: usize = config.MAX_HEADERS;
    var c_headers: [max_headers]c.struct_phr_header = undefined;
    var num_headers: usize = max_headers;

    const result = c.phr_parse_response(
        buf.ptr,
        buf.len,
        &minor_version,
        &status,
        @ptrCast(&msg_ptr),
        &msg_len,
        &c_headers,
        &num_headers,
        0, // last_len (0 for first parse)
    );

    if (result == -2) {
        return error.Incomplete;
    }
    if (result == -1) {
        return error.InvalidRequest;
    }

    const reason = msg_ptr[0..msg_len];

    const headers = try toHeaders(allocator, c_headers[0..num_headers]);

    return ResponseHead{
        .status = @intCast(status),
        .reason = reason,
        .minor_version = minor_version,
        .headers = headers,
        .head_len = @intCast(result),
    };
}

/// Parsed HTTP response status line + headers (see parseResponseHead).
pub const ResponseHead = struct {
    status: u16,
    reason: []const u8, // slice into buf
    minor_version: c_int,
    headers: []Header, // caller frees with the allocator passed to parseRequest/parseResponseHead
    head_len: usize, // byte offset in buf where the body begins
};

test "response serialization" {
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();

    response.status = 200;
    response.body = "Hello, World!";

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try response.serialize(&buf.writer);

    // Date's value is nondeterministic (#238), so this checks structure
    // rather than a single exact-match string.
    const out = buf.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Date: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 13\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\nHello, World!"));
}

test "serialize emits an RFC 7231 IMF-fixdate Date header (#238)" {
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();
    response.status = 200;
    response.body = "hi";

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try response.serialize(&buf.writer);

    const out = buf.writer.buffered();
    const marker = "Date: ";
    const marker_idx = std.mem.indexOf(u8, out, marker);
    try std.testing.expect(marker_idx != null);
    const value_start = marker_idx.? + marker.len;
    try std.testing.expect(out.len >= value_start + 29);
    const value = out[value_start..][0..29];

    // "Xxx, DD Xxx YYYY HH:MM:SS GMT" — shape checks on the fixed-width IMF-fixdate.
    try std.testing.expectEqual(@as(u8, ','), value[3]);
    try std.testing.expectEqual(@as(u8, ' '), value[4]);
    try std.testing.expectEqual(@as(u8, ' '), value[7]);
    try std.testing.expectEqual(@as(u8, ' '), value[11]);
    try std.testing.expectEqual(@as(u8, ' '), value[16]);
    try std.testing.expectEqual(@as(u8, ':'), value[19]);
    try std.testing.expectEqual(@as(u8, ':'), value[22]);
    try std.testing.expect(std.mem.endsWith(u8, value, " GMT"));

    // Header line is terminated and precedes the blank line separating body.
    try std.testing.expect(std.mem.indexOf(u8, out, "\r\n\r\n") != null);
}

test "serialize strips a tenant-set Date header, emitting exactly one engine Date (#238)" {
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();
    response.status = 200;
    response.body = "ok";
    try response.addHeader("Date", "bogus-tenant-date");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try response.serialize(&buf.writer);

    const out = buf.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "bogus-tenant-date") == null);

    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, out, pos, "Date: ")) |i| {
        count += 1;
        pos = i + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "serialize suppresses Content-Length and body for 204 (#206)" {
    // RFC 9110 §15.3.5: 204 No Content MUST NOT include a message body.
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();
    response.status = 204;
    response.body = "should never be sent";

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try response.serialize(&buf.writer);

    // Date's value is nondeterministic (#238), so this checks structure
    // rather than a single exact-match string.
    const out = buf.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 204 No Content\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Date: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "should never be sent") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
}

test "serialize suppresses Content-Length and body for 304 (#206)" {
    // RFC 9110 §15.4.5: 304 Not Modified MUST NOT include a message body.
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();
    response.status = 304;
    response.body = "should never be sent";

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try response.serialize(&buf.writer);

    const out = buf.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 304 Not Modified\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Date: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "should never be sent") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
}

test "serialize suppresses Content-Length and body for 1xx (#206)" {
    // RFC 9110 §6.4.1: 1xx informational responses MUST NOT include content.
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();
    response.status = 102;
    response.body = "should never be sent";

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try response.serialize(&buf.writer);

    const out = buf.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 102 Processing\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Date: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "should never be sent") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
}

test "isEngineOwnedHeader matches content-length, transfer-encoding, connection case-insensitively" {
    try std.testing.expect(isEngineOwnedHeader("Content-Length"));
    try std.testing.expect(isEngineOwnedHeader("content-length"));
    try std.testing.expect(isEngineOwnedHeader("CONTENT-LENGTH"));
    try std.testing.expect(isEngineOwnedHeader("Transfer-Encoding"));
    try std.testing.expect(isEngineOwnedHeader("transfer-encoding"));
    try std.testing.expect(isEngineOwnedHeader("Connection"));
    try std.testing.expect(isEngineOwnedHeader("connection"));
    try std.testing.expect(isEngineOwnedHeader("Date"));
    try std.testing.expect(isEngineOwnedHeader("date"));
    try std.testing.expect(isEngineOwnedHeader("DATE"));
    try std.testing.expect(!isEngineOwnedHeader("X-Foo"));
    // Whitespace-padded framing names are the classic smuggling obfuscation —
    // still recognized so they can't ride alongside the engine's own header.
    try std.testing.expect(isEngineOwnedHeader("Content-Length "));
    try std.testing.expect(isEngineOwnedHeader(" content-length"));
    try std.testing.expect(isEngineOwnedHeader("\tTransfer-Encoding"));
}

test "serialize drops a tenant-set Content-Length and a CRLF-injected header" {
    const allocator = std.testing.allocator;

    var response = Response.init(allocator);
    defer response.deinit();
    response.status = 200;
    response.body = "ok";
    try response.addHeader("Content-Length", "999");
    try response.addHeader("X-Bad", "a\r\nX-Injected: evil");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try response.serialize(&buf.writer);

    const result = buf.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, result, "X-Injected") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Length: 999") == null);
    // Engine's own Content-Length for the real 2-byte body is still present.
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Length: 2\r\n") != null);
}

test "status_lines: known phrase and unmapped-code fallback" {
    // Non-200 known code takes its std.http.Status phrase.
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found\r\n", Response.status_lines[404]);
    // Unmapped code falls back to "Unknown" with correct 3-digit extraction.
    try std.testing.expectEqualStrings("HTTP/1.1 599 Unknown\r\n", Response.status_lines[599]);
}

test "http parser - simple GET request" {
    const allocator = std.testing.allocator;

    const http_request = "GET /test HTTP/1.1\r\nHost: localhost\r\nUser-Agent: test\r\n\r\n";
    const request = try parseRequest(allocator, http_request);
    defer allocator.free(request.headers);

    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("/test", request.path);
    try std.testing.expectEqual(@as(usize, 2), request.headers.len);
}

test "http parser - incomplete request" {
    const allocator = std.testing.allocator;

    const partial_request = "GET /test HTTP";
    const result = parseRequest(allocator, partial_request);
    try std.testing.expectError(error.Incomplete, result);
}

test "http parser - rejects Content-Length and Transfer-Encoding together" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nping\r\n0\r\n\r\n";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.InvalidRequest, result);
}

test "http parser - rejects duplicate Content-Length with distinct values" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nhello";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.InvalidRequest, result);
}

test "http parser - accepts duplicate Content-Length with identical values" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nContent-Length: 04\r\n\r\nping";
    const request_result = try parseRequest(allocator, request);
    defer allocator.free(request_result.headers);
    try std.testing.expectEqualStrings("ping", request_result.body);
}

test "http parser - rejects malformed Content-Length" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\nping";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.InvalidRequest, result);
}

test "http parser - rejects signed Content-Length" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: +4\r\n\r\nping";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.InvalidRequest, result);
}

test "http parser - rejects Content-Length with digit separator" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1_0\r\n\r\nping";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.InvalidRequest, result);
}

test "http parser - rejects Content-Length that would overflow bytes_consumed + cl (#223)" {
    const allocator = std.testing.allocator;

    // 18446744073709551600 is a valid u64 value on its own, but adding
    // bytes_consumed (the header length) to it overflows usize — this is
    // the exact DoS primitive #223 fixes.
    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 18446744073709551600\r\n\r\n";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.RequestTooLarge, result);
}

test "http parser - rejects Content-Length just above READ_BUFFER_SIZE (#223)" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65537\r\n\r\n";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.RequestTooLarge, result);
}

test "http parser - accepts a normal small Content-Length" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nping";
    const request_result = try parseRequest(allocator, request);
    defer allocator.free(request_result.headers);
    try std.testing.expectEqualStrings("ping", request_result.body);
}

test "http parser - plain Transfer-Encoding: chunked decodes" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nping\r\n0\r\n\r\n";
    const request_result = try parseRequest(allocator, request);
    defer allocator.free(request_result.headers);
    defer allocator.free(request_result.body);
    try std.testing.expectEqualStrings("ping", request_result.body);
}

test "http parser - Transfer-Encoding with chunked as final coding decodes" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip, chunked\r\n\r\n4\r\nping\r\n0\r\n\r\n";
    const request_result = try parseRequest(allocator, request);
    defer allocator.free(request_result.headers);
    defer allocator.free(request_result.body);
    try std.testing.expectEqualStrings("ping", request_result.body);
}

test "http parser - rejects Transfer-Encoding with non-chunked final coding" {
    const allocator = std.testing.allocator;

    const request = "POST /test HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked, gzip\r\n\r\n4\r\nping\r\n0\r\n\r\n";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.InvalidRequest, result);
}

test "http parser - rejects obs-fold continuation line, SP (#245)" {
    const allocator = std.testing.allocator;

    // RFC 9112 §5.2: obs-fold in a request is a 400. picohttpparser accepts
    // the fold and reports it as a header with a NULL name, which is both a
    // null deref and a smuggling primitive if it reaches the upstream.
    const request = "POST /a HTTP/1.1\r\nHost: x\r\nX-Y: 1\r\n  2\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, request));
}

test "http parser - rejects obs-fold continuation line, HTAB (#245)" {
    const allocator = std.testing.allocator;

    const request = "POST /a HTTP/1.1\r\nHost: x\r\nX-Y: 1\r\n\t2\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, request));
}

test "http parser - rejects HTTP/1.1 request with no Host header" {
    const allocator = std.testing.allocator;

    const request = "GET /test HTTP/1.1\r\nUser-Agent: test\r\n\r\n";
    const result = parseRequest(allocator, request);
    try std.testing.expectError(error.InvalidRequest, result);
}

test "http parser - HTTP/1.0 request with no Host header parses OK" {
    const allocator = std.testing.allocator;

    const request = "GET /test HTTP/1.0\r\nUser-Agent: test\r\n\r\n";
    const request_result = try parseRequest(allocator, request);
    defer allocator.free(request_result.headers);
    try std.testing.expectEqualStrings("/test", request_result.path);
}

test "parseRequest wants_close (#204): HTTP/1.0 implicit close" {
    const allocator = std.testing.allocator;

    const request = "GET /test HTTP/1.0\r\n\r\n";
    const result = try parseRequest(allocator, request);
    defer allocator.free(result.headers);
    try std.testing.expect(result.wants_close);
}

test "parseRequest wants_close (#204): HTTP/1.0 with Connection: keep-alive stays open" {
    const allocator = std.testing.allocator;

    const request = "GET /test HTTP/1.0\r\nConnection: keep-alive\r\n\r\n";
    const result = try parseRequest(allocator, request);
    defer allocator.free(result.headers);
    try std.testing.expect(!result.wants_close);
}

test "parseRequest wants_close (#204): HTTP/1.1 default keep-alive" {
    const allocator = std.testing.allocator;

    const request = "GET /test HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const result = try parseRequest(allocator, request);
    defer allocator.free(result.headers);
    try std.testing.expect(!result.wants_close);
}

test "parseRequest wants_close (#204): HTTP/1.1 with Connection: close" {
    const allocator = std.testing.allocator;

    const request = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const result = try parseRequest(allocator, request);
    defer allocator.free(result.headers);
    try std.testing.expect(result.wants_close);
}

test "parseRequest wants_close (#204): case-insensitive header name and token, whitespace-trimmed" {
    const allocator = std.testing.allocator;

    const request = "GET /test HTTP/1.1\r\nHost: localhost\r\nCONNECTION:  CLOSE \r\n\r\n";
    const result = try parseRequest(allocator, request);
    defer allocator.free(result.headers);
    try std.testing.expect(result.wants_close);
}

test "parseRequest wants_close (#204): repeated Connection headers OR their tokens" {
    const allocator = std.testing.allocator;

    // First Connection header names an unrelated hop-by-hop token, second
    // carries close — both headers' tokens must be scanned, not just the last.
    const request = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: X-Foo\r\nConnection: close\r\n\r\n";
    const result = try parseRequest(allocator, request);
    defer allocator.free(result.headers);
    try std.testing.expect(result.wants_close);
}

test "serialize no longer special-cases 101 — a tenant ctx.status=101 is framed, not desynced (#194, #206)" {
    // The real WebSocket 101 handshake is now emitted as a raw response by
    // conn_ws (verified end-to-end by the WS integration tests), so serialize
    // only ever sees a 101 from a misused Lua handler. 101 is a 1xx, so per
    // #206 it now gets the RFC 9110 no-body treatment: no Content-Length, no
    // body — and the engine-owned Connection header is still stripped.
    const allocator = std.testing.allocator;

    var resp = Response.init(allocator);
    defer resp.deinit();
    resp.status = 101;
    resp.body = "oops";
    try resp.addHeader("Connection", "Upgrade"); // engine-owned → stripped
    try resp.addHeader("X-Keep", "1");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try resp.serialize(&buf.writer);

    const out = buf.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 101 Switching Protocols\r\n"));
    // 1xx → no Content-Length, no body (#206).
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "oops") == null);
    // Engine-owned Connection stripped even at 101 (exemption removed).
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection:") == null);
    // A non-engine tenant header is still emitted.
    try std.testing.expect(std.mem.indexOf(u8, out, "X-Keep: 1\r\n") != null);
}

test "picohttpparser websocket upgrade headers" {
    const allocator = std.testing.allocator;

    const ws_request = "GET /ws HTTP/1.1\r\nHost: localhost:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: VRr1Px7jQfIhHCVGc+tb4w==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    const request = try parseRequest(allocator, ws_request);
    defer allocator.free(request.headers);

    // Verify picohttpparser returns exact header value (no trailing whitespace)
    const sec_key = getHeader(&request, "Sec-WebSocket-Key").?;
    try std.testing.expectEqualStrings("VRr1Px7jQfIhHCVGc+tb4w==", sec_key);
    try std.testing.expectEqual(@as(usize, 24), sec_key.len);

    const upgrade = getHeader(&request, "Upgrade").?;
    try std.testing.expectEqualStrings("websocket", upgrade);

    // Verify accept key computation with this specific key
    const ws = @import("../protocol/ws.zig");
    const trimmed = std.mem.trim(u8, sec_key, " \t");
    var accept_key: [28]u8 = undefined;
    ws.computeAcceptKey(trimmed, &accept_key);

    // Verify the accept key is valid base64 (28 chars)
    try std.testing.expectEqual(@as(usize, 28), accept_key.len);
}

/// Encode data as a chunked transfer encoding chunk: "{hex_len}\r\n{data}\r\n"
pub fn encodeChunk(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{x}\r\n{s}\r\n", .{ data.len, data });
}

/// Terminal chunk for chunked transfer encoding.
pub const terminal_chunk = "0\r\n\r\n";

/// Result of decoding a chunked transfer-encoded body.
pub const ChunkedResult = struct {
    body: []const u8,
    total_consumed: usize,
};

/// Decode a chunked transfer-encoded body.
/// Returns the reassembled body (allocated with the passed allocator) and
/// total bytes consumed. Returns error.Incomplete if the terminal chunk
/// hasn't been received yet. Public: also used by proxy.zig to decode a
/// chunked upstream response body (#182).
pub fn decodeChunkedBody(data: []const u8, allocator: std.mem.Allocator) !ChunkedResult {
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_buf.deinit(allocator);
    var pos: usize = 0;

    while (pos < data.len) {
        // Find end of chunk-size line
        const crlf_pos = std.mem.indexOf(u8, data[pos..], "\r\n") orelse return error.Incomplete;
        const size_str = std.mem.trim(u8, data[pos .. pos + crlf_pos], " \t");
        // Strip chunk extensions (everything after ';')
        const pure_size = if (std.mem.indexOfScalar(u8, size_str, ';')) |semi| size_str[0..semi] else size_str;
        // RFC 9112 §7.1: chunk-size is strictly 1*HEXDIG — reject empty,
        // '+'/'-' signs, and '_' digit separators that parseInt would accept.
        if (pure_size.len == 0) return error.InvalidRequest;
        for (pure_size) |ch| {
            if (!std.ascii.isHex(ch)) return error.InvalidRequest;
        }
        const chunk_size = std.fmt.parseInt(usize, pure_size, 16) catch return error.InvalidRequest;
        pos += crlf_pos + 2; // skip past size line + CRLF

        if (chunk_size == 0) {
            // Trailer section: zero or more trailer-field lines, ended by a
            // blank line (RFC 9112 §7.1.2). We consume and ignore the fields.
            while (true) {
                const line_end = std.mem.indexOf(u8, data[pos..], "\r\n") orelse return error.Incomplete;
                pos += line_end + 2;
                if (line_end == 0) break; // blank line → end of trailer section
            }
            return .{
                .body = body_buf.toOwnedSlice(allocator) catch return error.InvalidRequest,
                .total_consumed = pos,
            };
        }

        // Ensure full chunk data + trailing CRLF is available
        if (pos + chunk_size + 2 > data.len) return error.Incomplete;

        try body_buf.appendSlice(allocator, data[pos .. pos + chunk_size]);
        pos += chunk_size;
        if (!std.mem.eql(u8, data[pos .. pos + 2], "\r\n")) return error.InvalidRequest;
        pos += 2;
    }

    return error.Incomplete;
}

test "encodeChunk produces correct wire format" {
    const allocator = std.testing.allocator;
    const chunk = try encodeChunk(allocator, "Hello");
    defer allocator.free(chunk);
    try std.testing.expectEqualStrings("5\r\nHello\r\n", chunk);
}

test "encodeChunk with larger data" {
    const allocator = std.testing.allocator;
    const data = "a" ** 256;
    const chunk = try encodeChunk(allocator, data);
    defer allocator.free(chunk);
    try std.testing.expect(std.mem.startsWith(u8, chunk, "100\r\n")); // 256 = 0x100
    try std.testing.expect(std.mem.endsWith(u8, chunk, "\r\n"));
}

test "decodeChunkedBody decodes simple chunked body" {
    const allocator = std.testing.allocator;
    // "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n"
    const data = "5\r\nHello\r\n6\r\n World\r\n0\r\n\r\n";
    const result = try decodeChunkedBody(data, allocator);
    defer allocator.free(result.body);
    try std.testing.expectEqualStrings("Hello World", result.body);
    try std.testing.expectEqual(data.len, result.total_consumed);
}

test "decodeChunkedBody returns Incomplete for partial data" {
    const allocator = std.testing.allocator;
    const data = "5\r\nHel";
    try std.testing.expectError(error.Incomplete, decodeChunkedBody(data, allocator));
}

test "decodeChunkedBody handles hex sizes" {
    const allocator = std.testing.allocator;
    // 0xa = 10 bytes
    const data = "a\r\n0123456789\r\n0\r\n\r\n";
    const result = try decodeChunkedBody(data, allocator);
    defer allocator.free(result.body);
    try std.testing.expectEqualStrings("0123456789", result.body);
}

test "decodeChunkedBody consumes trailer section" {
    const allocator = std.testing.allocator;
    const data = "5\r\nHello\r\n0\r\nX-Trailer: v\r\n\r\n";
    const result = try decodeChunkedBody(data, allocator);
    defer allocator.free(result.body);
    try std.testing.expectEqualStrings("Hello", result.body);
    try std.testing.expectEqual(data.len, result.total_consumed);
}

test "decodeChunkedBody rejects missing data CRLF" {
    const allocator = std.testing.allocator;
    // After "Hello" the next two bytes are "!!" instead of CRLF. Unvalidated,
    // this desyncs and reinterprets "!!6\r\nWorld!\r\n0\r\n\r\n" as further
    // chunk framing, silently producing "HelloWorld!" instead of erroring.
    const data = "5\r\nHello!!6\r\nWorld!\r\n0\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, decodeChunkedBody(data, allocator));
}

test "decodeChunkedBody rejects chunk size with leading plus" {
    const allocator = std.testing.allocator;
    const data = "+4\r\nping\r\n0\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, decodeChunkedBody(data, allocator));
}

test "decodeChunkedBody rejects chunk size with digit separator" {
    const allocator = std.testing.allocator;
    // "1_0" in hex with '_' ignored as a digit separator is 0x10 = 16, and
    // the 16-byte body below matches that length exactly, so unvalidated
    // this decodes "successfully" instead of being rejected.
    const data = "1_0\r\n0123456789012345\r\n0\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, decodeChunkedBody(data, allocator));
}

test "decodeChunkedBody returns Incomplete for trailer missing final blank line" {
    const allocator = std.testing.allocator;
    const data = "5\r\nHello\r\n0\r\nX-Trailer: v\r\n";
    try std.testing.expectError(error.Incomplete, decodeChunkedBody(data, allocator));
}

test "parseResponseHead parses status, reason, headers, and head_len" {
    const allocator = std.testing.allocator;
    const buf = "HTTP/1.1 200 OK\r\nX-Foo: bar\r\nContent-Length: 5\r\n\r\nhello";
    const head = try parseResponseHead(allocator, buf);
    defer allocator.free(head.headers);

    try std.testing.expectEqual(@as(u16, 200), head.status);
    try std.testing.expectEqualStrings("OK", head.reason);
    try std.testing.expectEqual(@as(usize, 2), head.headers.len);
    try std.testing.expectEqualStrings("X-Foo", head.headers[0].name);
    try std.testing.expectEqualStrings("bar", head.headers[0].value);
    try std.testing.expectEqualStrings("Content-Length", head.headers[1].name);
    try std.testing.expectEqualStrings("hello", buf[head.head_len..]);
}

test "parseResponseHead rejects a malformed status line" {
    const allocator = std.testing.allocator;
    const buf = "not an http response at all\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, parseResponseHead(allocator, buf));
}

test "parseResponseHead rejects an obs-fold continuation line (#245)" {
    const allocator = std.testing.allocator;
    // Same NULL-name hazard as the request path, but triggered by the
    // upstream: a folded response header would crash the proxy.
    const buf = "HTTP/1.1 200 OK\r\nX-Y: 1\r\n  2\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectError(error.InvalidRequest, parseResponseHead(allocator, buf));
}

test "serializeChunkedHeaders omits Content-Length" {
    const allocator = std.testing.allocator;
    var response = Response.init(allocator);
    defer response.deinit();
    response.status = 200;
    try response.addHeader("Content-Type", "application/x-ndjson");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try response.serializeChunkedHeaders(&buf.writer);

    const result = buf.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, result, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Type: application/x-ndjson") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Content-Length") == null);
    try std.testing.expect(std.mem.endsWith(u8, result, "\r\n\r\n"));
}
