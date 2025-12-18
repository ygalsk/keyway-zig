const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const router = @import("router.zig");
const Router = router.Router;
const RouteMatch = router.RouteMatch;
const lua_request = @import("lua_request.zig");
const lua_response = @import("lua_response.zig");

/// Lua state manager - Deep module with simple interface
/// Manages a single long-lived Lua state for the server
/// In the future, this will be one state per worker thread
pub const LuaState = struct {
    lua: *Lua,
    allocator: std.mem.Allocator,

    /// Initialize Lua state with standard libraries
    pub fn init(allocator: std.mem.Allocator) !LuaState {
        const lua = try Lua.init(allocator);
        errdefer lua.deinit();

        // Load standard libraries
        lua.openBaseLib();
        lua.openStringLib();
        lua.openTableLib();
        lua.openMathLib();

        // std.log.info("Lua state initialized", .{});

        return LuaState{
            .lua = lua,
            .allocator = allocator,
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

    /// Helper: Push a Zig string to Lua (zero-copy)
    fn pushStr(self: *LuaState, str: []const u8) void {
        self.lua.pushLString(str);
    }

    /// Push HTTP request to Lua as a table
    fn pushRequest(self: *LuaState, request: *const http.Request, route_match: ?RouteMatch) void {
        self.lua.createTable(0, 0); // Create request table

        // Set method
        self.pushStr(request.method);
        self.lua.setField(-2, "method");

        // Set path
        self.pushStr(request.path);
        self.lua.setField(-2, "path");

        // Set version
        self.lua.pushInteger(@as(i64, request.version));
        self.lua.setField(-2, "version");

        // Set params table if route matched
        if (route_match) |match| {
            self.lua.createTable(0, 0);
            var it = match.params.iterator();
            while (it.next()) |entry| {
                self.pushStr(entry.key_ptr.*); // Push key
                self.pushStr(entry.value_ptr.*); // Push value
                self.lua.setTable(-3); // Set table[key] = value
            }
            self.lua.setField(-2, "params");
        } else {
            self.lua.createTable(0, 0);
            self.lua.setField(-2, "params");
        }

        // Set headers table
        self.lua.createTable(0, 0);
        for (request.headers) |header| {
            self.pushStr(header.name); // Push key
            self.pushStr(header.value); // Push value
            self.lua.setTable(-3); // Set table[key] = value
        }
        self.lua.setField(-2, "headers");

        // Set body
        self.pushStr(request.body);
        self.lua.setField(-2, "body");
    }

    /// Call a Lua handler via the framework
    /// Returns HTTP response or error
    pub fn callHandler(
        self: *LuaState,
        handler_name: []const u8,
        request: *const http.Request,
        route_match: ?RouteMatch,
        allocator: std.mem.Allocator,
    ) !http.Response {
        // Get framework.handle_request function
        _ = self.lua.getGlobal("framework");
        if (!self.lua.isTable(-1)) {
            self.lua.pop(1);
            return error.FrameworkNotLoaded;
        }

        _ = self.lua.getField(-1, "handle_request");
        if (!self.lua.isFunction(-1)) {
            self.lua.pop(2);
            return error.HandleRequestNotFound;
        }

        // Push arguments: handler_name and request table
        self.pushStr(handler_name);
        self.pushRequest(request, route_match);

        // Call framework.handle_request(handler_name, request)
        try self.lua.callProtected(2, 2, 0); // 2 args, 2 results (result, error)

        // Check if error (second return value)
        if (!self.lua.isNil(-1)) {
            const err_msg = self.lua.toString(-1) catch "Unknown Lua error";
            std.log.err("Lua handler error: {s}", .{err_msg});
            self.lua.pop(3); // Pop error, result, framework table
            return error.LuaHandlerError;
        }
        self.lua.pop(1); // Pop nil error

        // Parse response table
        if (!self.lua.isTable(-1)) {
            self.lua.pop(2);
            return error.InvalidResponse;
        }

        var response = http.Response.init(allocator);
        errdefer response.deinit();

        // Get status code
        _ = self.lua.getField(-1, "status");
        if (self.lua.isNumber(-1)) {
            response.status = @as(u16, @intCast(self.lua.toInteger(-1)));
        }
        self.lua.pop(1);

        // Get body
        _ = self.lua.getField(-1, "body");
        if (self.lua.isString(-1)) {
            const body_ptr = self.lua.toString(-1) catch null;
            if (body_ptr) |ptr| {
                const body = std.mem.span(ptr);
                // Allocate and copy body
                const body_copy = try allocator.alloc(u8, body.len);
                @memcpy(body_copy, body);
                response.body = body_copy;
            }
        }
        self.lua.pop(1);

        self.lua.pop(2); // Pop response table and framework table

        return response;
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

        // Push request userdata
        const req_ud = self.lua.newUserdata(@sizeOf(lua_request.LuaRequest));
        const req_ptr = @as(*lua_request.LuaRequest, @ptrCast(@alignCast(req_ud)));
        req_ptr.* = req.*;
        _ = self.lua.getMetatableRegistry("Request");
        self.lua.setMetatable(-2);

        // Push response userdata
        const resp_ud = self.lua.newUserdata(@sizeOf(lua_response.LuaResponse));
        const resp_ptr = @as(*lua_response.LuaResponse, @ptrCast(@alignCast(resp_ud)));
        resp_ptr.* = resp.*;
        _ = self.lua.getMetatableRegistry("Response");
        self.lua.setMetatable(-2);

        // Call handler: handler_fn(req, resp)
        try self.lua.callProtected(2, 0, 0);
    }

    /// Clean up Lua state
    pub fn deinit(self: *LuaState) void {
        self.lua.deinit();
    }
};

test "lua state initialization" {
    const allocator = std.testing.allocator;

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
