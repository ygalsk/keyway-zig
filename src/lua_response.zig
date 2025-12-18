const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");

/// LuaResponse - Response userdata exposed to Lua
/// Lua gets a pointer to this struct and calls methods to build the response
pub const LuaResponse = struct {
    response: *http.Response,
    allocator: std.mem.Allocator,

    // Zig methods - exposed to Lua via accessor functions
    pub fn setStatus(self: *LuaResponse, status: u16) void {
        self.response.status = status;
    }

    pub fn setBody(self: *LuaResponse, body: []const u8) !void {
        // Allocate and copy body (Lua string might be temporary)
        const body_copy = try self.allocator.dupe(u8, body);
        self.response.body = body_copy;
    }

    pub fn addHeader(self: *LuaResponse, name: []const u8, value: []const u8) !void {
        try self.response.addHeader(name, value);
    }
};

/// Helper: Get LuaResponse userdata from Lua stack
fn getUserdata(lua: *Lua, index: i32) *LuaResponse {
    const ud = lua.toUserdata(index) orelse unreachable;
    return @as(*LuaResponse, @ptrCast(@alignCast(ud)));
}

/// Lua accessor: resp:set_status(code)
fn luaRespSetStatus(lua: *Lua) callconv(.c) c_int {
    const resp = getUserdata(lua, 1);

    // Get status code from Lua
    if (!lua.isNumber(2)) {
        lua.pushString("set_status: status must be a number");
        lua.raiseError();
        return 0;
    }

    const status = lua.toInteger(2);
    resp.setStatus(@intCast(status));

    return 0; // No return values
}

/// Lua accessor: resp:set_body(str)
fn luaRespSetBody(lua: *Lua) callconv(.c) c_int {
    const resp = getUserdata(lua, 1);

    // Get body string from Lua
    const body_cstr = lua.toString(2) catch {
        lua.pushString("set_body: body must be a string");
        lua.raiseError();
        return 0;
    };
    const body = std.mem.span(body_cstr);

    // Allocate and copy body
    resp.setBody(body) catch {
        lua.pushString("set_body: failed to allocate response body");
        lua.raiseError();
        return 0;
    };

    return 0; // No return values
}

/// Lua accessor: resp:add_header(name, value)
fn luaRespAddHeader(lua: *Lua) callconv(.c) c_int {
    const resp = getUserdata(lua, 1);

    // Get header name
    const name_cstr = lua.toString(2) catch {
        lua.pushString("add_header: name must be a string");
        lua.raiseError();
        return 0;
    };
    const name = std.mem.span(name_cstr);

    // Get header value
    const value_cstr = lua.toString(3) catch {
        lua.pushString("add_header: value must be a string");
        lua.raiseError();
        return 0;
    };
    const value = std.mem.span(value_cstr);

    // Add header
    resp.addHeader(name, value) catch {
        lua.pushString("add_header: failed to add header");
        lua.raiseError();
        return 0;
    };

    return 0; // No return values
}

/// Register Response metatable with Lua
/// This makes resp:set_status() syntax work
pub fn registerResponseMetatable(lua: *Lua) void {
    // Create metatable
    _ = lua.newMetatable("Response");

    // Set __index to self (enables method syntax)
    lua.pushValue(-1);
    lua.setField(-2, "__index");

    // Register methods
    lua.pushCFunction(luaRespSetStatus);
    lua.setField(-2, "set_status");

    lua.pushCFunction(luaRespSetBody);
    lua.setField(-2, "set_body");

    lua.pushCFunction(luaRespAddHeader);
    lua.setField(-2, "add_header");

    // Pop metatable
    lua.pop(1);

    std.log.info("Response metatable registered", .{});
}
