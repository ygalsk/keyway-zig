const std = @import("std");
const http = @import("http.zig");
const params_mod = @import("params.zig");

/// HttpExchange - The ONLY object Lua touches
/// Represents a complete HTTP request/response exchange
/// Lives in Connection, populated before Lua call, read after
pub const HttpExchange = struct {
    // === REQUEST (read-only from Lua, zero-copy slices) ===
    method: []const u8,
    path: []const u8,
    headers: []http.Header,
    params: *const params_mod.ParamArray,
    query: *const params_mod.QueryArray,
    body: []const u8,

    // === PEER INFO ===
    remote_addr: []const u8 = "",

    // === RESPONSE (write-only from Lua) ===
    status: u16 = 200,
    response_headers: std.ArrayList(http.Header),
    response_body: []const u8 = "",

    // === WEBSOCKET UPGRADE ===
    upgrade_websocket: bool = false,
    ws_on_message_ref: i32 = 0, // Lua registry ref for on_message callback
    ws_on_close_ref: i32 = 0, // Lua registry ref for on_close callback

    // === SSE UPGRADE ===
    upgrade_sse: bool = false,
    sse_room: []const u8 = "",

    // === STREAM UPGRADE (chunked transfer encoding) ===
    upgrade_stream: bool = false,

    // === HANDLER ERROR (set by __newindex on invalid ctx writes, e.g. bad ctx.status) ===
    // Sticky: first error wins. Checked after a normal (non-yielding) handler return.
    // ponytail: stream-upgrade and async-resume completions don't consume this —
    // they proceed with the default status instead of a 500 (no crash either way,
    // the guard is at the assignment site). Hoist into those paths with #173.
    handler_error: ?[]const u8 = null,

    // === INTERNAL ===
    allocator: std.mem.Allocator,

    /// Initialize HttpExchange from Request and ParamArray
    /// Request fields are zero-copy slices into LinearBuffer
    pub fn init(
        allocator: std.mem.Allocator,
        request: *const http.Request,
        params: *const params_mod.ParamArray,
        query: *const params_mod.QueryArray,
        clean_path: []const u8,
    ) !HttpExchange {
        return .{
            .method = request.method,
            .path = clean_path,
            .headers = request.headers,
            .params = params,
            .query = query,
            .body = request.body,
            .response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4),
            .allocator = allocator,
        };
    }

    /// Add a response header.
    ///
    /// Ownership: `name` and `value` are copied into the exchange allocator, so
    /// the caller keeps ownership of its input buffers and may free or reuse
    /// them immediately after this returns. The copies live for the exchange's
    /// lifetime (freed via `toResponse` transfer or `deinit`).
    pub fn addResponseHeader(self: *HttpExchange, name: []const u8, value: []const u8) !void {
        // Copy strings from Lua memory into arena (Lua strings are temporary)
        const name_copy = try self.allocator.dupe(u8, name);
        const value_copy = try self.allocator.dupe(u8, value);

        try self.response_headers.append(self.allocator, .{ .name = name_copy, .value = value_copy });
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
