const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const RingBuffer = @import("buffer.zig").RingBuffer;
const http = @import("http.zig");
const RadixRouter = @import("radix_router.zig").RadixRouter;
const LuaState = @import("lua_state.zig").LuaState;
const lua_request = @import("lua_request.zig");
const lua_response = @import("lua_response.zig");

// Buffer size constants
const READ_BUFFER_SIZE = 8192;
const WRITE_BUFFER_SIZE = 8192;
const MAX_ROUTE_PARAMS = 4; // Typical routes have 1-4 params

/// Lightweight param storage - replaces HashMap for route params
/// O(n) lookup but n ≤ 4, cache-friendly, zero allocations
pub const ParamArray = struct {
    items: [MAX_ROUTE_PARAMS]Param = undefined,
    len: usize = 0,

    const Param = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn put(self: *ParamArray, key: []const u8, value: []const u8) void {
        if (self.len >= MAX_ROUTE_PARAMS) return; // Silently ignore overflow
        self.items[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    pub fn get(self: *const ParamArray, key: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |param| {
            if (std.mem.eql(u8, param.key, key)) return param.value;
        }
        return null;
    }

    pub fn clear(self: *ParamArray) void {
        self.len = 0;
    }
};

/// Connection handler - manages HTTP request/response lifecycle
pub const Connection = struct {
    base_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    loop: *xev.Loop,
    socket: std.posix.socket_t,
    router: *RadixRouter,
    lua_state: *LuaState,

    // Completions (must have stable address!)
    read_completion: xev.Completion,
    write_completion: xev.Completion,

    // Buffers (allocated from base_allocator, persist across requests)
    read_buffer: RingBuffer,
    write_buffer: []u8,
    write_pos: usize,

    // Inline param storage (reused across requests, zero allocations, cache-friendly)
    param_cache: ParamArray,

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        socket: std.posix.socket_t,
        router: *RadixRouter,
        lua_state: *LuaState,
    ) !*Connection {
        const conn = try allocator.create(Connection);
        errdefer allocator.destroy(conn);

        // Allocate buffers from base allocator (persist across requests)
        const write_buf = try allocator.alloc(u8, WRITE_BUFFER_SIZE);
        errdefer allocator.free(write_buf);

        const read_buf = try RingBuffer.init(allocator, READ_BUFFER_SIZE);
        errdefer allocator.free(read_buf.data);

        // Initialize arena for per-request allocations
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        // Assign everything at once
        conn.* = Connection{
            .base_allocator = allocator,
            .arena = arena,
            .loop = loop,
            .socket = socket,
            .router = router,
            .lua_state = lua_state,
            .read_completion = undefined,
            .write_completion = undefined,
            .read_buffer = read_buf,
            .write_buffer = write_buf,
            .write_pos = 0,
            .param_cache = ParamArray{},  // Inline struct, zero allocations
        };

        return conn;
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        std.posix.close(self.socket);
        self.arena.deinit();
        // param_cache is inline struct, no deinit needed
        self.base_allocator.free(self.write_buffer);
        self.base_allocator.free(self.read_buffer.data);
        allocator.destroy(self);
    }

    /// Start reading from connection
    pub fn startRead(self: *Connection) void {
        const buf = self.read_buffer.writeSlice();
        self.read_completion = .{
            .op = .{
                .recv = .{
                    .fd = self.socket,
                    .buffer = .{ .slice = buf },
                },
            },
            .userdata = self,
            .callback = onRead,
        };
        self.loop.add(&self.read_completion);
    }

    fn onRead(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));

        const bytes_read = result.recv catch |err| {
            // EOF is expected when client closes connection
            if (err != error.EOF) {
                std.log.err("Read failed: {}", .{err});
            }
            self.close();
            return .disarm;
        };

        if (bytes_read == 0) {
            // Client closed connection
            self.close();
            return .disarm;
        }

        self.read_buffer.commitWrite(bytes_read);

        // For now, just send a simple HTTP response
        self.sendResponse() catch |err| {
            std.log.err("Send response failed: {}", .{err});
            self.close();
            return .disarm;
        };

        return .disarm;
    }

    fn sendResponse(self: *Connection) !void {
        // Parse HTTP request using picohttpparser
        const request_data = self.read_buffer.readSlice();

        var parser = http.Parser.init(self.arena.allocator());
        const request = parser.parseRequest(request_data) catch |err| {
            if (err == error.Incomplete) {
                // Need more data - continue reading
                self.startRead();
                return;
            }
            // Invalid request - send 400
            std.log.err("Failed to parse request: {}", .{err});
            try self.send400BadRequest();
            return;
        };
        defer self.arena.allocator().free(request.headers);

        // Clear param cache and match route (zero allocations!)
        self.param_cache.clear();
        const lua_ref = self.router.match(request.method, request.path, &self.param_cache);

        // Execute Lua handler with userdata (zero-copy)
        var response = if (lua_ref) |ref| blk: {
            // Create request userdata (params come from pre-allocated cache)
            var lua_req = lua_request.LuaRequest{
                .request = &request,
                .params = &self.param_cache,
                .allocator = self.arena.allocator(),
            };

            // Create response object
            var resp = http.Response.init(self.arena.allocator());
            var lua_resp = lua_response.LuaResponse{
                .response = &resp,
                .allocator = self.arena.allocator(),
            };

            // Call Lua handler with userdata (no table marshalling!)
            self.lua_state.callLuaHandler(ref, &lua_req, &lua_resp) catch |err| {
                std.log.err("Lua handler error: {}", .{err});
                try self.send500InternalError();
                return;
            };

            break :blk resp;
        } else blk: {
            // No route matched - send 404
            var resp = http.Response.init(self.arena.allocator());
            resp.status = 404;
            const body404 = try self.arena.allocator().alloc(u8, 9);
            @memcpy(body404, "Not Found");
            resp.body = body404;
            break :blk resp;
        };
        defer response.deinit();

        // Serialize response to buffer
        var response_buf = std.ArrayList(u8).initCapacity(self.arena.allocator(), 0) catch unreachable;
        try response.serialize(response_buf.writer(self.arena.allocator()));

        // Copy to write buffer
        const response_text = response_buf.items;
        @memcpy(self.write_buffer[0..response_text.len], response_text);
        self.write_pos = response_text.len;

        // Start write
        self.write_completion = .{
            .op = .{
                .send = .{
                    .fd = self.socket,
                    .buffer = .{ .slice = self.write_buffer[0..self.write_pos] },
                },
            },
            .userdata = self,
            .callback = onWrite,
        };
        self.loop.add(&self.write_completion);
    }

    fn send400BadRequest(self: *Connection) !void {
        const response_text = "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
        @memcpy(self.write_buffer[0..response_text.len], response_text);
        self.write_pos = response_text.len;

        self.write_completion = .{
            .op = .{
                .send = .{
                    .fd = self.socket,
                    .buffer = .{ .slice = self.write_buffer[0..self.write_pos] },
                },
            },
            .userdata = self,
            .callback = onWrite,
        };
        self.loop.add(&self.write_completion);
    }

    fn send500InternalError(self: *Connection) !void {
        const response_text = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error";
        @memcpy(self.write_buffer[0..response_text.len], response_text);
        self.write_pos = response_text.len;

        self.write_completion = .{
            .op = .{
                .send = .{
                    .fd = self.socket,
                    .buffer = .{ .slice = self.write_buffer[0..self.write_pos] },
                },
            },
            .userdata = self,
            .callback = onWrite,
        };
        self.loop.add(&self.write_completion);
    }

    fn onWrite(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;
        _ = completion;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));

        const bytes_written = result.send catch |err| {
            std.log.err("Write failed: {}", .{err});
            self.close();
            return .disarm;
        };
        _ = bytes_written;
        // std.log.info("Wrote {} bytes", .{bytes_written});

        // Reset arena and buffer for next request (HTTP/1.1 keep-alive)
        _ = self.arena.reset(.retain_capacity);
        self.read_buffer.reset();

        // Continue reading for next request on same connection
        self.startRead();
        return .disarm;
    }

    fn close(self: *Connection) void {
        const allocator = self.arena.child_allocator;
        self.deinit(allocator);
    }
};
