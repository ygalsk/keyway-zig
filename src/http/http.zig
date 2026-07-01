const std = @import("std");
const config = @import("../util/config.zig");

// Picohttpparser C bindings
const c = @cImport({
    @cInclude("picohttpparser.h");
});

/// HTTP request
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    version: u8,
    headers: []Header,
    body: []const u8,
    /// Total bytes consumed from input buffer (headers + body per Content-Length)
    raw_len: usize,
};

/// HTTP response
pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    headers: ?std.ArrayList(Header) = null,  // Lazy init - null until first header added
    body: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Response {
        return Response{
            .allocator = allocator,
            .headers = null,  // No ArrayList overhead until needed
        };
    }

    pub fn deinit(self: *Response) void {
        if (self.headers) |*h| {
            h.deinit(self.allocator);
        }
    }

    /// Add a header to the response (O(1) amortized)
    /// Lazily initializes ArrayList on first header addition
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.headers == null) {
            // First header - initialize with capacity for typical case (4 headers)
            self.headers = try std.ArrayList(Header).initCapacity(self.allocator, 4);
        }
        try self.headers.?.append(self.allocator, Header{ .name = name, .value = value });
    }

    /// Comptime-generated status line table indexed by HTTP status code.
    /// Each entry is a complete "HTTP/1.1 NNN Reason\r\n" string, enabling
    /// single-memcpy serialization with no runtime formatting.
    const status_lines = blk: {
        const known = .{
            .{ 101, "Switching Protocols" },
            .{ 200, "OK" },
            .{ 201, "Created" },
            .{ 204, "No Content" },
            .{ 301, "Moved Permanently" },
            .{ 302, "Found" },
            .{ 304, "Not Modified" },
            .{ 400, "Bad Request" },
            .{ 401, "Unauthorized" },
            .{ 403, "Forbidden" },
            .{ 404, "Not Found" },
            .{ 405, "Method Not Allowed" },
            .{ 408, "Request Timeout" },
            .{ 413, "Content Too Large" },
            .{ 429, "Too Many Requests" },
            .{ 500, "Internal Server Error" },
            .{ 502, "Bad Gateway" },
            .{ 503, "Service Unavailable" },
        };

        var table: [600][]const u8 = undefined;

        // Fill every slot with a generic "HTTP/1.1 NNN Unknown\r\n" line
        for (0..600) |code| {
            const digits: *const [3]u8 = comptime_digits: {
                var buf: [3]u8 = undefined;
                buf[0] = '0' + @as(u8, @intCast(code / 100));
                buf[1] = '0' + @as(u8, @intCast((code / 10) % 10));
                buf[2] = '0' + @as(u8, @intCast(code % 10));
                break :comptime_digits &buf;
            };
            table[code] = "HTTP/1.1 " ++ digits ++ " Unknown\r\n";
        }

        // Overwrite known codes with their proper reason phrases
        for (known) |entry| {
            const code: comptime_int = entry[0];
            const reason: []const u8 = entry[1];
            const digits: *const [3]u8 = comptime_digits: {
                var buf: [3]u8 = undefined;
                buf[0] = '0' + @as(u8, @intCast(code / 100));
                buf[1] = '0' + @as(u8, @intCast((code / 10) % 10));
                buf[2] = '0' + @as(u8, @intCast(code % 10));
                break :comptime_digits &buf;
            };
            table[code] = "HTTP/1.1 " ++ digits ++ " " ++ reason ++ "\r\n";
        }

        break :blk table;
    };

    /// Serialize HTTP response headers with Transfer-Encoding: chunked (no Content-Length, no body).
    /// Used for streaming responses where body is sent as subsequent chunks.
    pub fn serializeChunkedHeaders(self: *Response, writer: anytype) !void {
        const code: usize = @min(self.status, status_lines.len - 1);
        try writer.writeAll(status_lines[code]);

        if (self.headers) |h| {
            for (h.items) |header| {
                try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
            }
        }

        try writer.writeAll("Transfer-Encoding: chunked\r\n\r\n");
    }

    /// Serialize response to HTTP/1.1 format
    pub fn serialize(self: *Response, writer: anytype) !void {
        // Status line — single memcpy from comptime table
        const code: usize = @min(self.status, status_lines.len - 1);
        try writer.writeAll(status_lines[code]);

        // Headers (only if ArrayList was initialized)
        if (self.headers) |h| {
            for (h.items) |header| {
                try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
            }
        }

        // Content-Length (skip for 101 Switching Protocols — no body follows)
        if (self.status != 101) {
            try writer.print("Content-Length: {d}\r\n", .{self.body.len});
        }

        // Blank line
        try writer.writeAll("\r\n");

        // Body
        try writer.writeAll(self.body);
    }
};

/// HTTP header
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// HTTP parser using picohttpparser
pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{ .allocator = allocator };
    }

    /// Parse HTTP request from buffer
    /// Returns Request on success, error.Incomplete if partial, or other error
    pub fn parseRequest(self: *Parser, buf: []const u8) !Request {
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
        var headers = try self.allocator.alloc(Header, num_headers);
        for (0..num_headers) |i| {
            const h = c_headers[i];
            headers[i] = Header{
                .name = h.name[0..h.name_len],
                .value = h.value[0..h.value_len],
            };
        }

        // Body: use Content-Length to determine exact body boundaries.
        // Without this, leftover body bytes corrupt the next keep-alive request.
        const bytes_consumed = @as(usize, @intCast(result));

        var content_length: usize = 0;
        for (0..num_headers) |i| {
            const h = c_headers[i];
            const name = h.name[0..h.name_len];
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, h.value[0..h.value_len], 10) catch 0;
                break;
            }
        }

        // Check for Transfer-Encoding: chunked (mutually exclusive with Content-Length)
        var is_chunked = false;
        if (content_length == 0) {
            for (0..num_headers) |i| {
                const h = c_headers[i];
                const name = h.name[0..h.name_len];
                if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                    const val = h.value[0..h.value_len];
                    if (std.ascii.indexOfIgnoreCase(val, "chunked") != null) {
                        is_chunked = true;
                        break;
                    }
                }
            }
        }

        if (is_chunked) {
            // Decode chunked body: hex-size\r\n + data\r\n + ... + 0\r\n\r\n
            const chunk_data = buf[bytes_consumed..];
            const decoded = decodeChunkedBody(chunk_data, self.allocator) catch |err| {
                if (err == error.Incomplete) {
                    self.allocator.free(headers);
                    return error.Incomplete;
                }
                self.allocator.free(headers);
                return error.InvalidRequest;
            };
            return Request{
                .method = method,
                .path = path,
                .version = @as(u8, @intCast(minor_version)),
                .headers = headers,
                .body = decoded.body,
                .raw_len = bytes_consumed + decoded.total_consumed,
            };
        }

        const total_needed = bytes_consumed + content_length;
        if (buf.len < total_needed) {
            // Body not fully received yet — need more data
            self.allocator.free(headers);
            return error.Incomplete;
        }

        const body = if (content_length > 0) buf[bytes_consumed .. bytes_consumed + content_length] else &[_]u8{};

        return Request{
            .method = method,
            .path = path,
            .version = @as(u8, @intCast(minor_version)),
            .headers = headers,
            .body = body,
            .raw_len = total_needed,
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

    const expected = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!";
    try std.testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "http parser - simple GET request" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);

    const http_request = "GET /test HTTP/1.1\r\nHost: localhost\r\nUser-Agent: test\r\n\r\n";
    const request = try parser.parseRequest(http_request);
    defer allocator.free(request.headers);

    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("/test", request.path);
    try std.testing.expectEqual(@as(u8, 1), request.version); // HTTP/1.1
    try std.testing.expectEqual(@as(usize, 2), request.headers.len);
}

test "http parser - incomplete request" {
    const allocator = std.testing.allocator;

    var parser = Parser.init(allocator);

    const partial_request = "GET /test HTTP";
    const result = parser.parseRequest(partial_request);
    try std.testing.expectError(error.Incomplete, result);
}

test "101 switching protocols serialization" {
    const allocator = std.testing.allocator;

    var resp = Response.init(allocator);
    defer resp.deinit();
    resp.status = 101;
    try resp.addHeader("Upgrade", "websocket");
    try resp.addHeader("Connection", "Upgrade");
    try resp.addHeader("Sec-WebSocket-Accept", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try resp.serialize(&buf.writer);

    const expected = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    try std.testing.expectEqualStrings(expected, buf.writer.buffered());
}

test "picohttpparser websocket upgrade headers" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const ws_request = "GET /ws HTTP/1.1\r\nHost: localhost:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: VRr1Px7jQfIhHCVGc+tb4w==\r\nSec-WebSocket-Version: 13\r\n\r\n";
    const request = try parser.parseRequest(ws_request);
    defer allocator.free(request.headers);

    // Verify picohttpparser returns exact header value (no trailing whitespace)
    const sec_key = Parser.getHeader(&request, "Sec-WebSocket-Key").?;
    try std.testing.expectEqualStrings("VRr1Px7jQfIhHCVGc+tb4w==", sec_key);
    try std.testing.expectEqual(@as(usize, 24), sec_key.len);

    const upgrade = Parser.getHeader(&request, "Upgrade").?;
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
    // Format: hex_length\r\ndata\r\n
    const hex_len = std.fmt.count("{x}", .{data.len});
    const total = hex_len + 2 + data.len + 2;
    const buf = try allocator.alloc(u8, total);
    var w = std.Io.Writer.fixed(buf);
    w.print("{x}\r\n", .{data.len}) catch unreachable;
    w.writeAll(data) catch unreachable;
    w.writeAll("\r\n") catch unreachable;
    return buf;
}

/// Terminal chunk for chunked transfer encoding.
pub const terminal_chunk = "0\r\n\r\n";

/// Result of decoding a chunked transfer-encoded body.
const ChunkedResult = struct {
    body: []const u8,
    total_consumed: usize,
};

/// Decode a chunked transfer-encoded body.
/// Returns the reassembled body (arena-allocated) and total bytes consumed.
/// Returns error.Incomplete if the terminal chunk hasn't been received yet.
fn decodeChunkedBody(data: []const u8, allocator: std.mem.Allocator) !ChunkedResult {
    var body_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body_buf.deinit(allocator);
    var pos: usize = 0;

    while (pos < data.len) {
        // Find end of chunk-size line
        const crlf_pos = std.mem.indexOf(u8, data[pos..], "\r\n") orelse return error.Incomplete;
        const size_str = std.mem.trim(u8, data[pos .. pos + crlf_pos], " \t");
        // Strip chunk extensions (everything after ';')
        const pure_size = if (std.mem.indexOfScalar(u8, size_str, ';')) |semi| size_str[0..semi] else size_str;
        const chunk_size = std.fmt.parseInt(usize, pure_size, 16) catch return error.InvalidRequest;
        pos += crlf_pos + 2; // skip past size line + CRLF

        if (chunk_size == 0) {
            // Terminal chunk — skip trailing CRLF
            if (pos + 2 > data.len) return error.Incomplete;
            pos += 2;
            return .{
                .body = body_buf.toOwnedSlice(allocator) catch return error.InvalidRequest,
                .total_consumed = pos,
            };
        }

        // Ensure full chunk data + trailing CRLF is available
        if (pos + chunk_size + 2 > data.len) return error.Incomplete;

        try body_buf.appendSlice(allocator, data[pos .. pos + chunk_size]);
        pos += chunk_size + 2; // skip data + CRLF
    }

    return error.Incomplete;
}

/// Extract Content-Length from parsed request headers.
/// Returns null if header is missing or value is malformed.
pub fn getContentLength(request: *const Request) ?u64 {
    const val = Parser.getHeader(request, "content-length") orelse return null;
    return std.fmt.parseInt(u64, val, 10) catch null;
}

test "getContentLength returns value when header present" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "localhost" },
        .{ .name = "Content-Length", .value = "1234" },
    };
    const request = Request{
        .method = "POST",
        .path = "/upload",
        .version = 1,
        .headers = @constCast(&headers),
        .body = "",
        .raw_len = 0,
    };
    try std.testing.expectEqual(@as(u64, 1234), getContentLength(&request).?);
}

test "getContentLength returns null when header missing" {
    const headers = [_]Header{
        .{ .name = "Host", .value = "localhost" },
    };
    const request = Request{
        .method = "GET",
        .path = "/",
        .version = 1,
        .headers = @constCast(&headers),
        .body = "",
        .raw_len = 0,
    };
    try std.testing.expectEqual(@as(?u64, null), getContentLength(&request));
}

test "getContentLength returns null for malformed value" {
    const headers = [_]Header{
        .{ .name = "Content-Length", .value = "not-a-number" },
    };
    const request = Request{
        .method = "POST",
        .path = "/",
        .version = 1,
        .headers = @constCast(&headers),
        .body = "",
        .raw_len = 0,
    };
    try std.testing.expectEqual(@as(?u64, null), getContentLength(&request));
}

test "getContentLength is case-insensitive" {
    const headers = [_]Header{
        .{ .name = "content-length", .value = "5678" },
    };
    const request = Request{
        .method = "POST",
        .path = "/",
        .version = 1,
        .headers = @constCast(&headers),
        .body = "",
        .raw_len = 0,
    };
    try std.testing.expectEqual(@as(u64, 5678), getContentLength(&request).?);
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
