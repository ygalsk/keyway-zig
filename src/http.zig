const std = @import("std");

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

    // Populated by router
    params: ?std.StringHashMap([]const u8) = null,
    query: ?std.StringHashMap([]const u8) = null,
};

/// HTTP response
pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16 = 200,
    headers: []Header = &[_]Header{},
    body: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Response {
        return Response{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        if (self.headers.len > 0) {
            self.allocator.free(self.headers);
        }
    }

    /// Add a header to the response
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        const new_headers = try self.allocator.realloc(self.headers, self.headers.len + 1);
        new_headers[self.headers.len] = Header{ .name = name, .value = value };
        self.headers = new_headers;
    }

    /// Serialize response to HTTP/1.1 format
    pub fn serialize(self: *Response, writer: anytype) !void {
        // Status line
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{
            self.status,
            self.statusText(),
        });

        // Headers
        for (self.headers) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        // Content-Length
        try writer.print("Content-Length: {d}\r\n", .{self.body.len});

        // Blank line
        try writer.writeAll("\r\n");

        // Body
        try writer.writeAll(self.body);
    }

    fn statusText(self: Response) []const u8 {
        return switch (self.status) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };
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

        // Allocate space for headers (max 100 headers)
        const max_headers: usize = 100;
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

        // Body starts after headers (result is bytes consumed)
        const bytes_consumed = @as(usize, @intCast(result));
        const body = if (bytes_consumed < buf.len) buf[bytes_consumed..] else &[_]u8{};

        return Request{
            .method = method,
            .path = path,
            .version = @as(u8, @intCast(minor_version)),
            .headers = headers,
            .body = body,
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

    var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer buf.deinit(allocator);

    try response.serialize(buf.writer(allocator));

    const expected = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!";
    try std.testing.expectEqualStrings(expected, buf.items);
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
