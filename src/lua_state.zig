const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const RadixRouter = @import("radix_router.zig").RadixRouter;
const lua_api = @import("lua_api.zig");

/// Lua state manager - Deep module with simple interface
/// Manages a single long-lived Lua state for the server
/// In the future, this will be one state per worker thread
pub const LuaState = struct {
    lua: *Lua,
    allocator: std.mem.Allocator,

    // Reusable exchange userdata reference
    exchange_ref: i32,

    // Reusable headers proxy userdata reference (cached to avoid per-request allocation)
    headers_proxy_ref: i32,

    // Reusable params table reference (cached to avoid per-request table creation)
    params_table_ref: i32,

    /// Initialize Lua state with standard libraries
    pub fn init(allocator: std.mem.Allocator, router: *RadixRouter) !LuaState {
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

        // Register keystone module (must be done before creating userdata)
        lua_api.registerKeystoneModule(lua, router);

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

        return LuaState{
            .lua = lua,
            .allocator = allocator,
            .exchange_ref = exchange_ref,
            .headers_proxy_ref = headers_proxy_ref,
            .params_table_ref = params_table_ref,
        };
    }

    /// Load and execute a Lua script file
    pub fn loadScript(self: *LuaState, path: []const u8) !void {
        // std.log.info("Loading Lua script: {s}", .{path});
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

    /// Call a Lua handler with HttpExchange
    /// Pushes exchange userdata to Lua and calls handler function
    pub fn callLuaHandler(
        self: *LuaState,
        lua_ref: i32,
        exchange: *HttpExchange,
    ) !void {
        // Get handler function from registry
        _ = self.lua.getTableIndexRaw(Lua.PseudoIndex.Registry, lua_ref);

        if (!self.lua.isFunction(-1)) {
            self.lua.pop(1);
            return error.NotAFunction;
        }

        // Push reusable exchange userdata
        _ = self.lua.getTableIndexRaw(Lua.PseudoIndex.Registry, self.exchange_ref);
        const ex_ud = self.lua.toUserdata(-1);
        const ex_ptr = @as(*HttpExchange, @ptrCast(@alignCast(ex_ud)));

        // Instead of copying the entire struct (which leaks the ArrayList),
        // copy fields individually and reuse the existing response_headers ArrayList
        ex_ptr.method = exchange.method;
        ex_ptr.path = exchange.path;
        ex_ptr.headers = exchange.headers;
        ex_ptr.params = exchange.params;
        ex_ptr.body = exchange.body;
        ex_ptr.status = 200; // Reset to default
        ex_ptr.response_body = "";
        ex_ptr.allocator = exchange.allocator;
        // Clear previous response headers (reuse the ArrayList)
        ex_ptr.response_headers.clearRetainingCapacity();

        // Call handler: handler_fn(ctx)
        try self.lua.callProtected(1, 0, 0);

        // Copy response body from Lua string (now safe, Lua stack still valid)
        if (ex_ptr.response_body.len > 0) {
            const body_copy = try exchange.allocator.dupe(u8, ex_ptr.response_body);
            exchange.response_body = body_copy;
        }

        // Copy response data back to caller's exchange
        exchange.status = ex_ptr.status;
        // Transfer response headers ownership
        exchange.response_headers = ex_ptr.response_headers;
    }

    /// Clean up Lua state
    pub fn deinit(self: *LuaState) void {
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
        self.lua.deinit();
    }
};

test "lua state initialization" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator, &router);
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

    var state = try LuaState.init(allocator, &router);
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

test "lua package library and require" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator, &router);
    defer state.deinit();

    // Test that package library is loaded
    try state.loadString("assert(package ~= nil)");
    try state.loadString("assert(package.path ~= nil)");
    try state.loadString("assert(package.cpath ~= nil)");

    // Test that require function exists
    try state.loadString("assert(type(require) == 'function')");
}
