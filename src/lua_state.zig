const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const lua_request = @import("lua_request.zig");
const lua_response = @import("lua_response.zig");
const RadixRouter = @import("radix_router.zig").RadixRouter;
const lua_api = @import("lua_api.zig");

/// Lua state manager - Deep module with simple interface
/// Manages a single long-lived Lua state for the server
/// In the future, this will be one state per worker thread
pub const LuaState = struct {
    lua: *Lua,
    allocator: std.mem.Allocator,

    // Reusable userdata references
    req_ref: i32,
    resp_ref: i32,

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

        // Register keystone module (must be done before creating userdata)
        lua_api.registerKeystoneModule(lua, router);

        // Create reusable userdata for request and response
        // This avoids allocating them on every request
        _ = lua.newUserdata(@sizeOf(lua_request.LuaRequest));
        _ = lua.getMetatableRegistry("Request");
        lua.setMetatable(-2);
        const req_ref = lua.ref(Lua.PseudoIndex.Registry);

        _ = lua.newUserdata(@sizeOf(lua_response.LuaResponse));
        _ = lua.getMetatableRegistry("Response");
        lua.setMetatable(-2);
        const resp_ref = lua.ref(Lua.PseudoIndex.Registry);

        return LuaState{
            .lua = lua,
            .allocator = allocator,
            .req_ref = req_ref,
            .resp_ref = resp_ref,
        };
    }

    /// Load and execute a Lua script file
    pub fn loadScript(self: *LuaState, path: []const u8) !void {
        // std.log.info("Loading Lua script: {s}", .{path});
        // doFile expects sentinel-terminated string, allocate one
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        try self.lua.doFile(path_z);
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

    /// Call a Lua handler with userdata (zero-copy)
    /// Pushes request/response userdata to Lua and calls handler function
    pub fn callLuaHandler(
        self: *LuaState,
        lua_ref: i32,
        req: *lua_request.LuaRequest,
        resp: *lua_response.LuaResponse,
    ) !void {
        // Get handler function from registry
        _ = self.lua.getTableIndexRaw(Lua.PseudoIndex.Registry, lua_ref);

        if (!self.lua.isFunction(-1)) {
            self.lua.pop(1);
            return error.NotAFunction;
        }

        // Push reusable request userdata
        _ = self.lua.getTableIndexRaw(Lua.PseudoIndex.Registry, self.req_ref);
        const req_ud = self.lua.toUserdata(-1);
        const req_ptr = @as(*lua_request.LuaRequest, @ptrCast(@alignCast(req_ud)));
        req_ptr.* = req.*;

        // Push reusable response userdata
        _ = self.lua.getTableIndexRaw(Lua.PseudoIndex.Registry, self.resp_ref);
        const resp_ud = self.lua.toUserdata(-1);
        const resp_ptr = @as(*lua_response.LuaResponse, @ptrCast(@alignCast(resp_ud)));
        resp_ptr.* = resp.*;

        // Call handler: handler_fn(req, resp)
        try self.lua.callProtected(2, 0, 0);
    }

    /// Clean up Lua state
    pub fn deinit(self: *LuaState) void {
        self.lua.unref(Lua.PseudoIndex.Registry, self.req_ref);
        self.lua.unref(Lua.PseudoIndex.Registry, self.resp_ref);
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
