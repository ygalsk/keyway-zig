const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const RadixRouter = @import("radix_router.zig").RadixRouter;
const lua_api = @import("lua_api.zig");
const IoRequest = @import("io_request.zig").IoRequest;
const io_request = @import("io_request.zig");
const ConnectionPool = @import("connection_pool.zig").ConnectionPool;

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

    // Reusable exchange userdata reference
    exchange_ref: i32,

    // Reusable headers proxy userdata reference (cached to avoid per-request allocation)
    headers_proxy_ref: i32,

    // Reusable params table reference (cached to avoid per-request table creation)
    params_table_ref: i32,

    // Cached reusable coroutine thread (avoids lua_newThread per request)
    cached_thread: *Lua = undefined,
    cached_thread_ref: i32 = 0,

    // Cosocket: pending I/O intent written by C yield functions, read by Zig after LUA_YIELD
    pending_io: IoRequest = .{},

    // Cosocket: temporary coroutine state (copied to Connection after yield)
    coroutine_ref: i32 = 0,
    coroutine_thread: ?*Lua = null,

    // Connection pool for cosocket keepalive (per-worker, outlives requests)
    pool: ConnectionPool,

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

        // Register keyway module (must be done before creating userdata)
        lua_api.registerKeywayModule(lua);

        // Create reusable userdata for HttpExchange
        // This avoids allocating it on every request
        const ex_ud = lua.newUserdata(@sizeOf(HttpExchange));
        _ = lua.getMetatableRegistry("HttpExchange");
        lua.setMetatable(-2);

        // Initialize the HttpExchange in the userdata with a proper ArrayList
        const ex_ptr = @as(*HttpExchange, @ptrCast(@alignCast(ex_ud)));
        ex_ptr.* = .{
            .method = "",
            .path = "",
            .headers = &[_]http.Header{},
            .params = undefined,
            .body = "",
            .status = 200,
            .response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4),
            .response_body = "",
            .allocator = allocator,
        };

        const exchange_ref = lua.ref(Lua.PseudoIndex.Registry);

        // Create reusable HeadersProxy userdata (avoids per-request allocation)
        // Store it in registry under "_HEADERS_PROXY" key for easy access in metamethods
        const proxy_ud = lua.newUserdata(@sizeOf(lua_api.HeadersProxy));
        const proxy_ptr = @as(*lua_api.HeadersProxy, @ptrCast(@alignCast(proxy_ud)));
        proxy_ptr.* = .{ .exchange = undefined }; // Will be set on each request

        _ = lua.getMetatableRegistry("HttpExchange.Headers");
        lua.setMetatable(-2);

        // Store in registry with string key (so pushHeadersProxy can find it)
        lua.pushValue(-1); // Duplicate proxy on stack
        lua.setField(Lua.PseudoIndex.Registry, "_HEADERS_PROXY");

        const headers_proxy_ref = lua.ref(Lua.PseudoIndex.Registry);

        // Create reusable params table (cached to avoid per-request table creation)
        lua.createTable(0, 4); // Initial capacity for 4 params
        lua.pushValue(-1); // Duplicate table on stack
        lua.setField(Lua.PseudoIndex.Registry, "_PARAMS_TABLE");

        const params_table_ref = lua.ref(Lua.PseudoIndex.Registry);

        // Create reusable coroutine thread (avoids lua_newThread per request)
        const cached_thread = lua.newThread();
        const cached_thread_ref = lua.ref(Lua.PseudoIndex.Registry);

        // Add scripts/?.lua, scripts/?/init.lua, and LuaRocks paths to package.path
        // so require("keyway.socket") resolves to scripts/keyway/socket.lua
        // and require("pgmoon") finds ~/.luarocks/share/lua/5.1/pgmoon/init.lua
        lua.doString(
            \\local home = os.getenv("HOME") or ""
            \\package.path = "scripts/?.lua;scripts/?/init.lua;"
            \\    .. home .. "/.luarocks/share/lua/5.1/?.lua;"
            \\    .. home .. "/.luarocks/share/lua/5.1/?/init.lua;"
            \\    .. package.path
            \\package.cpath = home .. "/.luarocks/lib/lua/5.1/?.so;"
            \\    .. package.cpath
        ) catch {};

        return LuaState{
            .lua = lua,
            .allocator = allocator,
            .exchange_ref = exchange_ref,
            .headers_proxy_ref = headers_proxy_ref,
            .params_table_ref = params_table_ref,
            .cached_thread = cached_thread,
            .cached_thread_ref = cached_thread_ref,
            .pool = ConnectionPool.init(allocator),
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
    pub fn processRouteTable(self: *LuaState, router: *RadixRouter) !void {
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

    /// Call a Lua handler with HttpExchange using coroutine dispatch.
    /// Creates a new Lua thread (coroutine), pushes handler+exchange onto it,
    /// and resumes. Non-yielding handlers complete identically to the old pcall path.
    /// When Phase 2 adds cosockets, yielding handlers will suspend here and be
    /// resumed by io_uring completion callbacks.
    pub fn callLuaHandler(
        self: *LuaState,
        lua_ref: i32,
        exchange: *HttpExchange,
    ) !HandlerResult {
        // Reuse cached thread if available, otherwise create a new one
        // (cached thread is unavailable only when a previous handler is suspended)
        const thread = if (self.cached_thread_ref != 0) blk: {
            const t = self.cached_thread;
            // Reset thread stack for reuse (clear any leftover state)
            t.setTop(0);
            break :blk t;
        } else self.lua.newThread();

        // Push handler function onto thread's stack (registry is shared across threads)
        const handler_type = thread.getTableIndexRaw(Lua.PseudoIndex.Registry, lua_ref);
        if (handler_type != .function) {
            if (self.cached_thread_ref == 0) self.lua.pop(1);
            return error.NotAFunction;
        }

        // Push reusable exchange userdata onto thread's stack and update fields
        _ = thread.getTableIndexRaw(Lua.PseudoIndex.Registry, self.exchange_ref);
        const ex_ud = thread.toUserdata(-1);
        const ex_ptr = @as(*HttpExchange, @ptrCast(@alignCast(ex_ud)));

        // Copy request fields into reusable userdata (reuse the ArrayList)
        ex_ptr.method = exchange.method;
        ex_ptr.path = exchange.path;
        ex_ptr.headers = exchange.headers;
        ex_ptr.params = exchange.params;
        ex_ptr.body = exchange.body;
        ex_ptr.status = 200;
        ex_ptr.response_body = "";
        ex_ptr.allocator = exchange.allocator;
        ex_ptr.response_headers.clearRetainingCapacity();

        // Resume the coroutine: thread stack has [handler_fn, exchange_ud]
        const status = lua_resume(@ptrCast(thread), 1);

        switch (status) {
            0 => {
                // LUA_OK — handler completed normally
                if (ex_ptr.response_body.len > 0) {
                    const body_copy = try exchange.allocator.dupe(u8, ex_ptr.response_body);
                    exchange.response_body = body_copy;
                }
                exchange.status = ex_ptr.status;
                exchange.response_headers = ex_ptr.response_headers;

                // Re-init cached ArrayList so it doesn't retain arena-allocated buffer
                // (the arena resets after each response, which would leave a dangling pointer)
                ex_ptr.response_headers = std.ArrayList(http.Header).initCapacity(self.allocator, 4) catch
                    return error.OutOfMemory;

                // If we used a fresh thread (cached was pinned), pop it and let GC collect
                if (self.cached_thread_ref == 0) self.lua.pop(1);
                return .completed;
            },
            1 => {
                // LUA_YIELD — handler wants outbound I/O
                if (self.cached_thread_ref != 0) {
                    // Pin cached thread — it's now owned by the Connection
                    self.coroutine_ref = self.cached_thread_ref;
                    self.cached_thread_ref = 0;
                } else {
                    // Fresh thread — pin it in registry
                    self.coroutine_ref = self.lua.ref(Lua.PseudoIndex.Registry);
                }
                self.coroutine_thread = thread;
                return .yielded;
            },
            else => {
                if (thread.isString(-1)) {
                    const err_msg = thread.toString(-1) catch "unknown error";
                    std.log.err("Lua handler error: {s}", .{err_msg});
                }
                if (self.cached_thread_ref == 0) self.lua.pop(1);
                return error.Runtime;
            },
        }
    }

    /// Resume a yielded handler coroutine after outbound I/O completes.
    /// Caller has already pushed result values onto the thread stack.
    /// Does NOT unref the coroutine — Connection.completeHandler handles that.
    pub fn resumeHandler(
        self: *LuaState,
        thread: *anyopaque,
        nresults: c_int,
        exchange: *HttpExchange,
    ) !HandlerResult {
        const status = lua_resume(thread, nresults);

        // Get cached exchange userdata to read response
        _ = self.lua.getTableIndexRaw(Lua.PseudoIndex.Registry, self.exchange_ref);
        const ex_ud = self.lua.toUserdata(-1);
        const ex_ptr = @as(*HttpExchange, @ptrCast(@alignCast(ex_ud)));
        self.lua.pop(1);

        switch (status) {
            0 => {
                // LUA_OK — handler completed
                if (ex_ptr.response_body.len > 0) {
                    const body_copy = try exchange.allocator.dupe(u8, ex_ptr.response_body);
                    exchange.response_body = body_copy;
                }
                exchange.status = ex_ptr.status;
                exchange.response_headers = ex_ptr.response_headers;

                // Re-init cached ArrayList so it doesn't retain arena-allocated buffer
                ex_ptr.response_headers = std.ArrayList(http.Header).initCapacity(self.allocator, 4) catch
                    return error.OutOfMemory;
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
                    std.log.err("Lua handler error on resume: {s}", .{err_msg});
                }
                return error.Runtime;
            },
        }
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
        };

        inline for (funcs) |entry| {
            self.lua.pushLightUserdata(self);
            self.lua.pushCClosure(entry[1], 1);
            self.lua.setGlobal(entry[0]);
        }
    }

    /// Clean up Lua state
    pub fn deinit(self: *LuaState) void {
        self.pool.deinit();
        // Clean up the ArrayList in the reusable exchange userdata
        _ = self.lua.getTableIndexRaw(Lua.PseudoIndex.Registry, self.exchange_ref);
        const ex_ud = self.lua.toUserdata(-1);
        if (ex_ud) |ud| {
            const ex_ptr = @as(*HttpExchange, @ptrCast(@alignCast(ud)));
            ex_ptr.response_headers.deinit(self.allocator);
        }
        self.lua.pop(1);

        self.lua.unref(Lua.PseudoIndex.Registry, self.exchange_ref);
        self.lua.unref(Lua.PseudoIndex.Registry, self.headers_proxy_ref);
        self.lua.unref(Lua.PseudoIndex.Registry, self.params_table_ref);
        if (self.cached_thread_ref != 0) {
            self.lua.unref(Lua.PseudoIndex.Registry, self.cached_thread_ref);
        }
        self.lua.deinit();
    }
};

test "lua state initialization" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
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

    var router = try RadixRouter.init(allocator);
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
    const handler = @import("handler.zig");

    var router = try RadixRouter.init(allocator);
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
    var params = handler.ParamArray{};
    const lua_ref = router.match("GET", "/test", &params);
    try std.testing.expect(lua_ref != null);

    // Build a minimal HttpExchange
    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/test",
        .headers = &[_]http.Header{},
        .params = &params,
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

    var router = try RadixRouter.init(allocator);
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
    const handler_mod = @import("handler.zig");

    var router = try RadixRouter.init(allocator);
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

    var params = handler_mod.ParamArray{};
    const lua_ref = router.match("GET", "/test", &params);
    try std.testing.expect(lua_ref != null);

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/test",
        .headers = &[_]http.Header{},
        .params = &params,
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
    const handler_mod = @import("handler.zig");

    var router = try RadixRouter.init(allocator);
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

    var params = handler_mod.ParamArray{};
    const lua_ref = router.match("GET", "/secret", &params);
    try std.testing.expect(lua_ref != null);

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/secret",
        .headers = &[_]http.Header{},
        .params = &params,
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
