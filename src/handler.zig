const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const RingBuffer = @import("buffer.zig").RingBuffer;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const RadixRouter = @import("radix_router.zig").RadixRouter;
const LuaState = @import("lua_state.zig").LuaState;
const IoRequest = @import("io_request.zig").IoRequest;
const Lua = @import("luajit").Lua;

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

/// Connection lifecycle state — preparation for Phase 2 cosocket suspend/resume
pub const ConnectionState = enum {
    reading,
    executing,
    suspended,
    writing_response,
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

    // Connection lifecycle state
    state: ConnectionState,

    // Cosocket: outbound I/O fields (persist across yields)
    outbound_completion: xev.Completion = undefined,
    exchange: ?*HttpExchange = null,
    outbound_recv_buf: ?[]u8 = null,
    coroutine_ref: i32 = 0,
    coroutine_thread: ?*anyopaque = null,
    outbound_fd: std.posix.socket_t = 0,
    pending_op: IoRequest.Op = .none,

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
            .state = .reading,
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
        const alloc = self.arena.allocator();

        var parser = http.Parser.init(alloc);
        const request = parser.parseRequest(request_data) catch |err| {
            if (err == error.Incomplete) {
                self.startRead();
                return;
            }
            std.log.err("Failed to parse request: {}", .{err});
            try self.send400BadRequest();
            return;
        };
        // headers are arena-allocated, freed on arena reset in onWrite

        // Clear param cache and match route
        self.param_cache.clear();
        const lua_ref = self.router.match(request.method, request.path, &self.param_cache);

        self.state = .executing;

        if (lua_ref) |ref| {
            // Arena-allocate exchange (must persist across yields)
            const exchange_ptr = try alloc.create(HttpExchange);
            exchange_ptr.* = try HttpExchange.init(alloc, &request, &self.param_cache);

            const handler_result = self.lua_state.callLuaHandler(ref, exchange_ptr) catch |err| {
                std.log.err("Lua handler error: {}", .{err});
                try self.send500InternalError();
                return;
            };

            switch (handler_result) {
                .completed => {
                    try self.writeResponse(exchange_ptr);
                },
                .yielded => {
                    // Handler wants outbound I/O — save coroutine state on Connection
                    self.coroutine_ref = self.lua_state.coroutine_ref;
                    self.coroutine_thread = @ptrCast(self.lua_state.coroutine_thread);
                    self.exchange = exchange_ptr;
                    self.state = .suspended;
                    self.lua_state.coroutine_ref = 0;
                    self.lua_state.coroutine_thread = null;
                    self.submitOutboundIO();
                },
            }
        } else {
            // No route matched — 404
            var resp = http.Response.init(alloc);
            resp.status = 404;
            const body404 = try alloc.alloc(u8, 9);
            @memcpy(body404, "Not Found");
            resp.body = body404;
            try self.writeResponseDirect(&resp);
        }
    }

    /// Serialize response from exchange and submit write
    fn writeResponse(self: *Connection, exchange_ptr: *HttpExchange) !void {
        var response = exchange_ptr.toResponse();
        defer response.deinit();
        try self.writeResponseDirect(&response);
    }

    /// Serialize a Response and submit the write completion
    fn writeResponseDirect(self: *Connection, response: *http.Response) !void {
        const alloc = self.arena.allocator();
        // Pre-size to avoid repeated ArrayList growth in arena (old buffers can't be freed)
        const estimated = response.body.len + 512;
        var response_buf = std.ArrayList(u8).initCapacity(alloc, estimated) catch unreachable;
        try response.serialize(response_buf.writer(alloc));

        self.state = .writing_response;
        self.write_completion = .{
            .op = .{
                .send = .{
                    .fd = self.socket,
                    .buffer = .{ .slice = response_buf.items },
                },
            },
            .userdata = self,
            .callback = onWrite,
        };
        self.loop.add(&self.write_completion);
    }

    /// Read pending_io from LuaState, create socket / submit xev operation
    fn submitOutboundIO(self: *Connection) void {
        const pending = self.lua_state.pending_io;
        self.lua_state.pending_io = .{};

        switch (pending.op) {
            .connect, .pool_connect => {
                self.pending_op = pending.op;
                const sock = std.posix.socket(
                    std.posix.AF.INET,
                    std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
                    0,
                ) catch {
                    self.resumeWithError("socket creation failed");
                    return;
                };
                self.outbound_fd = sock;

                const host = pending.host orelse {
                    std.posix.close(sock);
                    self.resumeWithError("connect: missing host");
                    return;
                };
                const addr = std.net.Address.parseIp4(host, pending.port) catch {
                    std.posix.close(sock);
                    self.resumeWithError("connect: invalid address");
                    return;
                };

                self.outbound_completion = .{
                    .op = .{ .connect = .{ .socket = sock, .addr = addr } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&self.outbound_completion);
            },
            .send => {
                const data = pending.send_data orelse {
                    self.resumeWithError("send: missing data");
                    return;
                };
                self.outbound_completion = .{
                    .op = .{ .send = .{ .fd = pending.fd, .buffer = .{ .slice = data } } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&self.outbound_completion);
            },
            .recv => {
                const buf = self.arena.allocator().alloc(u8, pending.max_len) catch {
                    self.resumeWithError("recv: alloc failed");
                    return;
                };
                self.outbound_recv_buf = buf;
                self.outbound_completion = .{
                    .op = .{ .recv = .{ .fd = pending.fd, .buffer = .{ .slice = buf } } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&self.outbound_completion);
            },
            .close => {
                self.outbound_completion = .{
                    .op = .{ .close = .{ .fd = pending.fd } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&self.outbound_completion);
            },
            .none => {
                self.resumeWithError("no pending I/O operation");
            },
        }
    }

    /// xev callback for all outbound I/O completions
    fn onOutboundComplete(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = loop;

        const self: *Connection = @ptrCast(@alignCast(userdata.?));
        const thread: *Lua = @ptrCast(@alignCast(self.coroutine_thread.?));
        const exchange_ptr = self.exchange.?;

        // Determine what completed based on the op that was submitted
        const op = completion.op;
        var nresults: c_int = 1;

        if (op == .connect) {
            _ = result.connect catch {
                std.posix.close(self.outbound_fd);
                thread.pushNil();
                thread.pushString("connection refused");
                nresults = 2;
                self.pending_op = .none;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            if (self.pending_op == .pool_connect) {
                // pool_connect returns (fd, reuse_count=0)
                thread.pushInteger(@intCast(self.outbound_fd));
                thread.pushInteger(0);
                nresults = 2;
            } else {
                thread.pushInteger(@intCast(self.outbound_fd));
            }
            self.pending_op = .none;
        } else if (op == .send) {
            const bytes_sent = result.send catch {
                thread.pushNil();
                thread.pushString("send failed");
                nresults = 2;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            thread.pushInteger(@intCast(bytes_sent));
        } else if (op == .recv) {
            const bytes_read = result.recv catch {
                thread.pushNil();
                thread.pushString("recv failed");
                nresults = 2;
                self.outbound_recv_buf = null;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            if (self.outbound_recv_buf) |buf| {
                thread.pushLString(buf[0..bytes_read]);
            } else {
                thread.pushNil();
            }
            self.outbound_recv_buf = null;
        } else if (op == .close) {
            _ = result.close catch {
                thread.pushNil();
                thread.pushString("close failed");
                nresults = 2;
                self.dispatchResume(thread, nresults, exchange_ptr);
                return .disarm;
            };
            thread.pushInteger(1);
        } else {
            thread.pushNil();
            thread.pushString("unknown outbound op");
            nresults = 2;
        }

        self.dispatchResume(thread, nresults, exchange_ptr);
        return .disarm;
    }

    /// Resume coroutine and dispatch based on result
    fn dispatchResume(self: *Connection, thread: *Lua, nresults: c_int, exchange_ptr: *HttpExchange) void {
        const resume_result = self.lua_state.resumeHandler(@ptrCast(thread), nresults, exchange_ptr) catch {
            self.send500InternalError() catch {};
            return;
        };

        switch (resume_result) {
            .completed => self.completeHandler(),
            .yielded => self.submitOutboundIO(),
        }
    }

    /// Handler finished after one or more yield/resume cycles.
    /// Return coroutine to cache, serialize response, submit write.
    fn completeHandler(self: *Connection) void {
        if (self.coroutine_ref != 0) {
            if (self.lua_state.cached_thread_ref == 0) {
                // Return thread to cache for reuse
                self.lua_state.cached_thread_ref = self.coroutine_ref;
                self.lua_state.cached_thread = @ptrCast(@alignCast(self.coroutine_thread.?));
            } else {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, self.coroutine_ref);
            }
            self.coroutine_ref = 0;
        }
        self.coroutine_thread = null;

        const exchange_ptr = self.exchange orelse return;
        self.exchange = null;

        self.writeResponse(exchange_ptr) catch {
            self.send500InternalError() catch {};
        };
    }

    /// Resume coroutine with nil, error_message for pre-submission failures
    fn resumeWithError(self: *Connection, msg: [:0]const u8) void {
        const thread: *Lua = @ptrCast(@alignCast(self.coroutine_thread.?));
        const exchange_ptr = self.exchange.?;
        thread.pushNil();
        thread.pushString(msg);
        self.dispatchResume(thread, 2, exchange_ptr);
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

        // Reset cosocket fields and arena for next request (HTTP/1.1 keep-alive)
        self.exchange = null;
        self.outbound_recv_buf = null;
        self.coroutine_ref = 0;
        self.coroutine_thread = null;
        self.pending_op = .none;
        _ = self.arena.reset(.retain_capacity);
        self.read_buffer.reset();
        self.state = .reading;

        // Continue reading for next request on same connection
        self.startRead();
        return .disarm;
    }

    fn close(self: *Connection) void {
        const allocator = self.arena.child_allocator;
        self.deinit(allocator);
    }
};
