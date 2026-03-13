//! Per-worker Lua state aggregation and initialization.
//!
//! Each worker thread owns one LuaState containing: the Lua VM, cached coroutine thread,
//! cosocket pending I/O staging, connection pool, TLS manager, and SSE registry pointer.
//!
//! Init order: Lua VM → std libs → keyway module → cached thread → package paths → TLS manager.
//! After init: registerCosocketApi → setWorkerGlobals → loadScript → processRouteTable.

const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const Router = @import("router.zig").Router;
const lua_api = @import("lua_api.zig");
const IoEntry = @import("ring.zig").IoEntry;
const io_request = @import("io_request.zig");
const ring_api = @import("ring_api.zig");
const ring = @import("ring.zig");
const ConnectionPool = @import("connection_pool.zig").ConnectionPool;
const Connection = @import("handler.zig").Connection;
const tls = @import("tls.zig");
const castUserdata = @import("helpers.zig").castUserdata;
const TlsConn = tls.TlsConn;
const ClientTlsContext = tls.ClientTlsContext;
const TlsManager = tls.TlsManager;
const SseRegistry = @import("sse.zig").SseRegistry;

// zig-luajit marks resumeCoroutine as private — call C API directly.
// Lua is an opaque type that maps 1:1 to lua_State*, so @ptrCast is safe.
extern "c" fn lua_resume(L: *anyopaque, narg: c_int) c_int;

/// Lua state manager - Deep module with simple interface
/// Manages a single long-lived Lua state for the server
/// In the future, this will be one state per worker thread
/// Result of calling or resuming a Lua handler
pub const HandlerResult = enum { completed, yielded };

pub const LuaState = struct {
    lua: *Lua,
    allocator: std.mem.Allocator,

    // Cached reusable coroutine thread (avoids lua_newThread per request)
    cached_thread: *Lua = undefined,
    cached_thread_ref: i32 = 0,

    // Cosocket: pending I/O intent written by C yield functions, read by Zig after LUA_YIELD.
    // Safe because: written by C yield functions during lua_resume, read by submitOutboundIO
    // in the same stack frame. libxev is single-threaded per worker — no concurrent access.
    pending_io: ?IoEntry = null,

    // Cosocket: temporary coroutine state (copied to Connection after yield)
    coroutine_ref: i32 = 0,
    coroutine_thread: ?*Lua = null,

    // Connection pool for cosocket keepalive (per-worker, outlives requests)
    pool: ConnectionPool,

    // Current connection being served (set during handler call/resume, cleared on completion)
    // Used by ring C bridge functions to access the Connection's SQ/CQ.
    current_connection: ?*anyopaque = null,

    // SSE: per-worker registry for broadcast (set by worker.zig)
    sse_registry: ?*SseRegistry = null,

    // Outbound TLS: per-worker context + fd→TLS mapping (persists across yields)
    tls_manager: TlsManager,

    /// Initialize Lua state with standard libraries
    pub fn init(allocator: std.mem.Allocator) !LuaState {
        const lua = try Lua.init(allocator);
        errdefer lua.deinit();

        // Load standard libraries
        lua.openBaseLib();
        lua.openStringLib();
        lua.openTableLib();
        lua.openMathLib();
        lua.openPackageLib();
        lua.openIOLib(); // Required for LuaRocks to load modules from disk
        lua.openOSLib(); // Required for some LuaRocks modules (time, execute, etc.)
        lua.openDebugLib(); // Required for some LuaRocks modules (debug introspection)
        lua.openBitLib(); // Required for pgmoon and other LuaJIT modules (bit operations)
        lua.openJITLib(); // Required for JIT control (jit.on/off, jit.opt, etc.)
        lua.openFFILib(); // Required for FFI (ffi.cdef, ffi.C, ffi.new, etc.)

        // Register keyway module (must be done before creating userdata)
        lua_api.registerKeywayModule(lua);

        // Create reusable coroutine thread (avoids lua_newThread per request)
        const cached_thread = lua.newThread();
        const cached_thread_ref = lua.ref(Lua.PseudoIndex.Registry);

        // Add scripts/?.lua, scripts/?/init.lua, and LuaRocks paths to package.path
        // so require("keyway.socket") resolves to scripts/keyway/socket.lua
        // and require("pgmoon") finds ~/.luarocks/share/lua/5.1/pgmoon/init.lua
        // KEYWAY_LUA_PATH / KEYWAY_LUA_CPATH override defaults if set.
        lua.doString(
            \\local custom_path = os.getenv("KEYWAY_LUA_PATH")
            \\local custom_cpath = os.getenv("KEYWAY_LUA_CPATH")
            \\if custom_path then
            \\    package.path = custom_path .. ";" .. package.path
            \\else
            \\    local home = os.getenv("HOME") or ""
            \\    package.path = "scripts/?.lua;scripts/?/init.lua;"
            \\        .. home .. "/.luarocks/share/lua/5.1/?.lua;"
            \\        .. home .. "/.luarocks/share/lua/5.1/?/init.lua;"
            \\        .. "/usr/share/lua/5.1/?.lua;"
            \\        .. "/usr/share/lua/5.1/?/init.lua;"
            \\        .. package.path
            \\end
            \\if custom_cpath then
            \\    package.cpath = custom_cpath .. ";" .. package.cpath
            \\else
            \\    local home = os.getenv("HOME") or ""
            \\    package.cpath = home .. "/.luarocks/lib/lua/5.1/?.so;"
            \\        .. "/usr/lib/lua/5.1/?.so;"
            \\        .. "/usr/lib64/lua/5.1/?.so;"
            \\        .. "/usr/share/lua/5.1/?.so;"
            \\        .. "/usr/local/lib/lua/5.1/?.so;"
            \\        .. package.cpath
            \\end
        ) catch |err| {
            std.log.warn("failed to configure Lua package paths: {}", .{err});
        };

        const tls_manager = TlsManager.init(allocator) catch return error.TlsInitFailed;

        return LuaState{
            .lua = lua,
            .allocator = allocator,
            .cached_thread = cached_thread,
            .cached_thread_ref = cached_thread_ref,
            .pool = ConnectionPool.init(allocator),
            .tls_manager = tls_manager,
        };
    }

    /// Load and execute a Lua script file
    pub fn loadScript(self: *LuaState, path: []const u8) !void {
        // doFile expects sentinel-terminated string, allocate one
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        // Try to load and capture error if it fails
        self.lua.doFile(path_z) catch |err| {
            // Get error message from Lua stack
            if (self.lua.isString(-1)) {
                const err_msg = self.lua.toString(-1) catch "unknown error";
                std.log.err("Lua error loading {s}: {s}", .{path, err_msg});
                self.lua.pop(1); // Pop error message
            }
            return err;
        };
    }

    /// Load Lua code from string
    pub fn loadString(self: *LuaState, code: []const u8) !void {
        try self.lua.doString(code);
    }

    /// Process keyway.routes declarative table after script load.
    /// Walks the nested table and registers routes with the radix router.
    pub fn processRouteTable(self: *LuaState, router: *Router) !void {
        try lua_api.processRouteTable(self.lua, router, self.allocator);
    }

    /// Call a Lua function by name
    /// The function should be at the global scope
    pub fn callGlobalFunction(self: *LuaState, name: []const u8) !void {
        _ = self.lua.getGlobal(name);
        if (!self.lua.isFunction(-1)) {
            self.lua.pop(1);
            return error.NotAFunction;
        }
        try self.lua.callProtected(0, 0, 0); // 0 args, 0 results
    }

    /// Userdata variant for dispatchCoroutine — determines what gets pushed onto the thread stack.
    pub const UserdataKind = union(enum) {
        http: *HttpExchange,
        ws: lua_api.WsContext,
    };

    /// Generic coroutine dispatch: get/reuse thread, push handler + userdata, resume.
    /// Used by both HTTP handler dispatch and WebSocket on_message dispatch.
    pub fn dispatchCoroutine(self: *LuaState, lua_ref: i32, ud_kind: UserdataKind) !HandlerResult {
        // Reuse cached thread if available, otherwise create a new one
        // (cached thread is unavailable only when a previous handler is suspended)
        const thread = if (self.cached_thread_ref != 0) blk: {
            const t = self.cached_thread;
            t.setTop(0);
            break :blk t;
        } else self.lua.newThread();

        // Push handler function onto thread's stack (registry is shared across threads)
        const handler_type = thread.getTableIndexRaw(Lua.PseudoIndex.Registry, lua_ref);
        if (handler_type != .function) {
            if (self.cached_thread_ref == 0) self.lua.pop(1);
            return error.NotAFunction;
        }

        // Create userdata appropriate to the dispatch kind
        switch (ud_kind) {
            .http => |exchange| {
                const ud = thread.newUserdata(@sizeOf(*HttpExchange));
                castUserdata(*HttpExchange, @as(?*anyopaque, ud)).* = exchange;
                _ = thread.getMetatableRegistry("HttpExchange");
                thread.setMetatable(-2);
            },
            .ws => |ws_ctx| {
                const ud = thread.newUserdata(@sizeOf(lua_api.WsContext));
                castUserdata(lua_api.WsContext, @as(?*anyopaque, ud)).* = ws_ctx;
                _ = thread.getMetatableRegistry("WsContext");
                thread.setMetatable(-2);
            },
        }

        // Resume the coroutine: thread stack has [handler_fn, userdata]
        const status = lua_resume(@ptrCast(thread), 1);

        switch (status) {
            0 => {
                // LUA_OK — handler completed normally
                if (self.cached_thread_ref == 0) self.lua.pop(1);
                return .completed;
            },
            1 => {
                // LUA_YIELD — handler wants outbound I/O
                if (self.cached_thread_ref != 0) {
                    self.coroutine_ref = self.cached_thread_ref;
                    self.cached_thread_ref = 0;
                } else {
                    self.coroutine_ref = self.lua.ref(Lua.PseudoIndex.Registry);
                }
                self.coroutine_thread = thread;
                return .yielded;
            },
            else => {
                if (thread.isString(-1)) {
                    const err_msg = thread.toString(-1) catch "unknown error";
                    // Attempt debug.traceback(msg, 2) for a full stack trace
                    const dbg_type = thread.getGlobal("debug");
                    if (dbg_type == .table) {
                        const tb_type = thread.getField(-1, "traceback");
                        if (tb_type == .function) {
                            thread.pushValue(-3); // push original error msg
                            thread.pushInteger(2); // skip 2 frames
                            thread.callProtected(2, 1, 0) catch {
                                std.log.err("coroutine error ref={d} err=\"{s}\"", .{ lua_ref, err_msg });
                                thread.setTop(0);
                                if (self.cached_thread_ref == 0) self.lua.pop(1);
                                return error.Runtime;
                            };
                            const tb_msg = thread.toString(-1) catch err_msg;
                            std.log.err("coroutine error ref={d}\n{s}", .{ lua_ref, tb_msg });
                            thread.setTop(0);
                            if (self.cached_thread_ref == 0) self.lua.pop(1);
                            return error.Runtime;
                        }
                        thread.pop(2); // pop non-function + debug table
                    } else {
                        thread.pop(1); // pop non-table
                    }
                    std.log.err("coroutine error ref={d} err=\"{s}\"", .{ lua_ref, err_msg });
                }
                if (self.cached_thread_ref == 0) self.lua.pop(1);
                return error.Runtime;
            },
        }
    }

    /// Call a Lua handler with HttpExchange using coroutine dispatch.
    /// Thin wrapper around dispatchCoroutine with HTTP userdata.
    pub fn callLuaHandler(
        self: *LuaState,
        lua_ref: i32,
        exchange: *HttpExchange,
    ) !HandlerResult {
        return self.dispatchCoroutine(lua_ref, .{ .http = exchange });
    }

    /// Resume a yielded handler coroutine after outbound I/O completes.
    /// Caller has already pushed result values onto the thread stack.
    /// Does NOT unref the coroutine — Connection.completeHandler handles that.
    /// The exchange pointer comes from Connection.exchange (set during yield).
    pub fn resumeHandler(
        self: *LuaState,
        thread: *anyopaque,
        nresults: c_int,
        _: *HttpExchange,
    ) !HandlerResult {
        _ = self;
        const status = lua_resume(thread, nresults);

        switch (status) {
            0 => {
                // LUA_OK — handler completed
                // Response body already arena-duped on ctx.body assignment (lua_api.zig newindex)
                return .completed;
            },
            1 => {
                // LUA_YIELD — handler wants more I/O (pending_io already populated)
                return .yielded;
            },
            else => {
                const lua_thread: *Lua = @ptrCast(@alignCast(thread));
                if (lua_thread.isString(-1)) {
                    const err_msg = lua_thread.toString(-1) catch "unknown error";
                    std.log.err("lua resume error err=\"{s}\"", .{err_msg});
                }
                return error.Runtime;
            },
        }
    }

    /// Set per-worker Lua globals (called once after init, before loadScript).
    /// Exposes keyway.worker_id so handlers can include it in page output.
    pub fn setWorkerGlobals(self: *LuaState, worker_id: usize) void {
        _ = self.lua.getGlobal("keyway");          // push keyway table
        self.lua.pushInteger(@intCast(worker_id)); // push value
        self.lua.setField(-2, "worker_id");        // keyway.worker_id = N
        self.lua.pop(1);                           // pop keyway table
    }

    /// Register cosocket C functions as Lua globals with *LuaState as upvalue.
    /// Must be called after init (needs stable *LuaState pointer).
    pub fn registerCosocketApi(self: *LuaState) void {
        const funcs = .{
            .{ "__keyway_io_connect", io_request.keyway_io_connect },
            .{ "__keyway_io_send", io_request.keyway_io_send },
            .{ "__keyway_io_recv", io_request.keyway_io_recv },
            .{ "__keyway_io_close", io_request.keyway_io_close },
            .{ "__keyway_pool_connect", io_request.keyway_pool_connect },
            .{ "__keyway_pool_setkeepalive", io_request.keyway_pool_setkeepalive },
            .{ "__keyway_io_udp_connect", io_request.keyway_io_udp_connect },
            .{ "__keyway_io_sslhandshake", io_request.keyway_io_sslhandshake },
            .{ "__keyway_ws_send", io_request.keyway_ws_send },
            // Ring API: batched I/O
            .{ "__keyway_ring_push", ring_api.keyway_ring_push },
            .{ "__keyway_ring_submit", ring_api.keyway_ring_submit },
            .{ "__keyway_ring_result", ring_api.keyway_ring_result },
            .{ "__keyway_sse_broadcast", keyway_sse_broadcast },
        };

        inline for (funcs) |entry| {
            self.lua.pushLightUserdata(self);
            self.lua.pushCClosure(entry[1], 1);
            self.lua.setGlobal(entry[0]);
        }
    }

    /// SSE broadcast C function: __keyway_sse_broadcast(room, data)
    /// Non-yielding — broadcasts data to all SSE subscribers in a room.
    fn keyway_sse_broadcast(lua: *Lua) callconv(.c) c_int {
        const state: *LuaState = blk: {
            const ud = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse return 0;
            break :blk castUserdata(LuaState, @as(?*anyopaque, ud));
        };
        const registry = state.sse_registry orelse return 0;

        const room = lua.toString(1) catch return 0;
        const data = lua.toString(2) catch return 0;

        registry.broadcast(std.mem.span(room), std.mem.span(data));
        return 0;
    }

    /// Ownership transfers to TlsManager.
    pub fn registerTls(self: *LuaState, fd: std.posix.socket_t, tls_conn: *TlsConn) !void {
        try self.tls_manager.registerTls(fd, tls_conn);
    }

    /// Borrow — returns null for plain TCP.
    pub fn getTls(self: *LuaState, fd: std.posix.socket_t) ?*TlsConn {
        return self.tls_manager.getTls(fd);
    }

    /// Ownership transfers to caller. Used for pool transfer or manual cleanup.
    pub fn detachTls(self: *LuaState, fd: std.posix.socket_t) ?*TlsConn {
        return self.tls_manager.detachTls(fd);
    }

    /// Remove and free. Used on close paths.
    pub fn removeTls(self: *LuaState, fd: std.posix.socket_t) void {
        self.tls_manager.removeTls(fd);
    }

    // --- Ring API delegation methods ---
    // These let ring_api.zig access the current Connection's SQ/CQ
    // without importing handler.zig, sealing the proactor boundary.

    /// Push an IoEntry onto the current Connection's submission ring.
    /// Returns error.NoActiveRequest if no connection is active.
    pub fn pushSqEntry(self: *LuaState, entry: ring.IoEntry) error{ RingFull, NoActiveRequest }!void {
        const conn = self.currentConnection() orelse return error.NoActiveRequest;
        try conn.sq.push(entry);
    }

    /// Read a completion entry by index from the current Connection's CQ.
    /// Returns null if no connection is active or index is out of range.
    pub fn getCqEntry(self: *LuaState, index: u8) ?ring.CQEntry {
        const conn = self.currentConnection() orelse return null;
        if (index >= conn.cq.tail) return null;
        return conn.cq.get(index);
    }

    /// Return the number of pending SQ entries, or null if no connection is active.
    pub fn sqLen(self: *LuaState) ?u8 {
        const conn = self.currentConnection() orelse return null;
        return conn.sq.len();
    }

    /// Return the CQ tail (number of completions), or null if no connection is active.
    pub fn cqTail(self: *LuaState) ?u8 {
        const conn = self.currentConnection() orelse return null;
        return conn.cq.tail;
    }

    /// Cast current_connection to *Connection. Internal helper.
    inline fn currentConnection(self: *LuaState) ?*Connection {
        const ptr = self.current_connection orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    /// Clean up Lua state
    pub fn deinit(self: *LuaState) void {
        self.tls_manager.deinit();
        self.pool.deinit();
        if (self.cached_thread_ref != 0) {
            self.lua.unref(Lua.PseudoIndex.Registry, self.cached_thread_ref);
        }
        self.lua.deinit();
    }
};

test "lua state initialization" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Test basic Lua execution
    try state.loadString("x = 42");

    // Verify the value was set
    _ = state.lua.getGlobal("x");
    const value = state.lua.toInteger(-1);
    try std.testing.expectEqual(@as(i64, 42), value);
    state.lua.pop(1);
}

test "lua function call" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Define a simple function
    try state.loadString(
        \\function greet()
        \\  message = "Hello from Lua"
        \\end
    );

    // Call the function
    try state.callGlobalFunction("greet");

    // Verify it ran
    _ = state.lua.getGlobal("message");
    const msg = state.lua.toString(-1) catch unreachable;
    try std.testing.expectEqualStrings("Hello from Lua", msg);
    state.lua.pop(1);
}

test "coroutine dispatch - non-yielding handler" {
    const allocator = std.testing.allocator;
    const params_mod = @import("params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Register a handler via declarative route table
    try state.loadString(
        \\keyway.routes = {
        \\    ["/test"] = {
        \\        GET = function(ctx)
        \\            ctx.status = 201
        \\            ctx.body = "coroutine works"
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    // Look up the route to get the lua_ref
    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = router.match("GET", "/test", &url_params);
    try std.testing.expect(lua_ref != null);

    // Build a minimal HttpExchange
    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/test",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    // Call via coroutine dispatch
    const result = try state.callLuaHandler(lua_ref.?, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);

    // Verify response was set correctly
    try std.testing.expectEqual(@as(u16, 201), exchange.status);
    try std.testing.expectEqualStrings("coroutine works", exchange.response_body);

    // Clean up the duped body
    allocator.free(exchange.response_body);
}

test "lua package library and require" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Test that package library is loaded
    try state.loadString("assert(package ~= nil)");
    try state.loadString("assert(package.path ~= nil)");
    try state.loadString("assert(package.cpath ~= nil)");

    // Test that require function exists
    try state.loadString("assert(type(require) == 'function')");
}

test "middleware execution order" {
    const allocator = std.testing.allocator;
    const params_mod = @import("params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Route with two middleware layers: global (mw1) and path-level (mw2)
    // Uses a Lua global to track order since ctx only accepts status/body/headers
    try state.loadString(
        \\keyway.routes = {
        \\    middleware = {
        \\        function(ctx, next)
        \\            _order = "mw1_before"
        \\            next()
        \\            _order = _order .. ",mw1_after"
        \\            ctx.body = _order
        \\        end,
        \\    },
        \\    ["/test"] = {
        \\        middleware = {
        \\            function(ctx, next)
        \\                _order = _order .. ",mw2_before"
        \\                next()
        \\                _order = _order .. ",mw2_after"
        \\            end,
        \\        },
        \\        GET = function(ctx)
        \\            _order = _order .. ",handler"
        \\            ctx.status = 200
        \\            ctx.body = _order
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = router.match("GET", "/test", &url_params);
    try std.testing.expect(lua_ref != null);

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/test",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref.?, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    try std.testing.expectEqual(@as(u16, 200), exchange.status);
    try std.testing.expectEqualStrings("mw1_before,mw2_before,handler,mw2_after,mw1_after", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "middleware short-circuit" {
    const allocator = std.testing.allocator;
    const params_mod = @import("params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Middleware sets 401 and does NOT call next() — handler never runs
    try state.loadString(
        \\keyway.routes = {
        \\    ["/secret"] = {
        \\        middleware = {
        \\            function(ctx, next)
        \\                ctx.status = 401
        \\                ctx.body = "unauthorized"
        \\            end,
        \\        },
        \\        GET = function(ctx)
        \\            ctx.status = 200
        \\            ctx.body = "should not reach"
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = router.match("GET", "/secret", &url_params);
    try std.testing.expect(lua_ref != null);

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/secret",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref.?, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    try std.testing.expectEqual(@as(u16, 401), exchange.status);
    try std.testing.expectEqualStrings("unauthorized", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "security: request body with lua code is not executed" {
    const allocator = std.testing.allocator;
    const params_mod = @import("params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Handler echoes body back — body content must never be evaluated as Lua
    try state.loadString(
        \\keyway.routes = {
        \\    ["/echo"] = {
        \\        POST = function(ctx)
        \\            ctx.status = 200
        \\            ctx.body = ctx.body
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = router.match("POST", "/echo", &url_params);
    try std.testing.expect(lua_ref != null);

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "POST",
        .path = "/echo",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "os.execute('touch /tmp/pwned')",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref.?, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    try std.testing.expectEqual(@as(u16, 200), exchange.status);
    // Body is the literal string, never evaluated as Lua code
    try std.testing.expectEqualStrings("os.execute('touch /tmp/pwned')", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "security: param with lua code is literal string" {
    const allocator = std.testing.allocator;
    const params_mod = @import("params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Handler reads param and sets it as response body
    try state.loadString(
        \\keyway.routes = {
        \\    ["/h/{id}"] = {
        \\        GET = function(ctx)
        \\            ctx.status = 200
        \\            ctx.body = ctx.params.id
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = router.match("GET", "/h/os.execute('id')", &url_params);
    try std.testing.expect(lua_ref != null);

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/h/os.execute('id')",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref.?, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    // Param value is literal string, never evaluated
    try std.testing.expectEqualStrings("os.execute('id')", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "security: ctx.method and ctx.path are read-only" {
    const allocator = std.testing.allocator;
    const params_mod = @import("params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Handler tries to overwrite method and path, then reads them back
    try state.loadString(
        \\keyway.routes = {
        \\    ["/test"] = {
        \\        GET = function(ctx)
        \\            ctx.method = "EVIL"
        \\            ctx.path = "/evil"
        \\            ctx.status = 200
        \\            ctx.body = ctx.method .. " " .. ctx.path
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = router.match("GET", "/test", &url_params);
    try std.testing.expect(lua_ref != null);

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/test",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref.?, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    // Writes to method/path are silently ignored — original values preserved
    try std.testing.expectEqualStrings("GET /test", exchange.response_body);

    allocator.free(exchange.response_body);
}
