const std = @import("std");
const http = @import("http.zig");
const handler = @import("handler.zig");

/// HttpExchange - The ONLY object Lua touches
/// Represents a complete HTTP request/response exchange
/// Lives in Connection, populated before Lua call, read after
pub const HttpExchange = struct {
    // === REQUEST (read-only from Lua, zero-copy slices) ===
    method: []const u8,
    path: []const u8,
    headers: []http.Header,
    params: *const handler.ParamArray,
    body: []const u8,

    // === RESPONSE (write-only from Lua) ===
    status: u16 = 200,
    response_headers: std.ArrayList(http.Header),
    response_body: []const u8 = "",

    // === INTERNAL ===
    allocator: std.mem.Allocator,

    /// Initialize HttpExchange from Request and ParamArray
    /// Request fields are zero-copy slices into RingBuffer
    pub fn init(
        allocator: std.mem.Allocator,
        request: *const http.Request,
        params: *const handler.ParamArray,
    ) !HttpExchange {
        return .{
            .method = request.method,
            .path = request.path,
            .headers = request.headers,
            .params = params,
            .body = request.body,
            .response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4),
            .allocator = allocator,
        };
    }

    /// Add a response header
    pub fn addResponseHeader(self: *HttpExchange, name: []const u8, value: []const u8) !void {
        try self.response_headers.append(self.allocator, .{ .name = name, .value = value });
    }

    /// Convert HttpExchange to Response for serialization
    /// Transfers ownership of response_headers ArrayList to Response
    pub fn toResponse(self: *HttpExchange) http.Response {
        var resp = http.Response.init(self.allocator);
        resp.status = self.status;

        // Transfer ownership of ArrayList if headers were added
        if (self.response_headers.items.len > 0) {
            resp.headers = self.response_headers;
        } else {
            // No headers added, clean up empty ArrayList
            self.response_headers.deinit(self.allocator);
        }

        resp.body = self.response_body;
        return resp;
    }

    /// Cleanup (called if Lua handler fails before toResponse)
    pub fn deinit(self: *HttpExchange) void {
        self.response_headers.deinit(self.allocator);
    }
};
