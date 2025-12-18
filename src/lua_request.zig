const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const handler = @import("handler.zig");

/// LuaRequest - Request userdata exposed to Lua
/// Lua gets a pointer to this struct (lightuserdata) and calls methods
pub const LuaRequest = struct {
    request: *const http.Request,
    params: *const handler.ParamArray,
    allocator: std.mem.Allocator,

    // Zig methods - exposed to Lua via accessor functions
    pub fn getMethod(self: *const LuaRequest) []const u8 {
        return self.request.method;
    }

    pub fn getPath(self: *const LuaRequest) []const u8 {
        return self.request.path;
    }

    pub fn getParam(self: *const LuaRequest, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn getHeader(self: *const LuaRequest, name: []const u8) ?[]const u8 {
        for (self.request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }

    pub fn getBody(self: *const LuaRequest) []const u8 {
        return self.request.body;
    }
};

/// Helper: Get LuaRequest userdata from Lua stack
fn getUserdata(lua: *Lua, index: i32) *LuaRequest {
    const ud = lua.toUserdata(index) orelse unreachable;
    return @as(*LuaRequest, @ptrCast(@alignCast(ud)));
}

/// Lua accessor: req:get_method()
fn luaReqGetMethod(lua: *Lua) callconv(.c) c_int {
    const req = getUserdata(lua, 1);
    const method = req.getMethod();
    lua.pushLString(method); // Zero-copy: points to Zig memory
    return 1;
}

/// Lua accessor: req:get_path()
fn luaReqGetPath(lua: *Lua) callconv(.c) c_int {
    const req = getUserdata(lua, 1);
    const path = req.getPath();
    lua.pushLString(path); // Zero-copy
    return 1;
}

/// Lua accessor: req:get_param(name)
fn luaReqGetParam(lua: *Lua) callconv(.c) c_int {
    const req = getUserdata(lua, 1);

    // Get parameter name from Lua
    const name_cstr = lua.toString(2) catch {
        lua.pushString("get_param: name must be a string");
        lua.raiseError();
        return 0;
    };
    const name = std.mem.span(name_cstr);

    // Get parameter value
    if (req.getParam(name)) |value| {
        lua.pushLString(value); // Zero-copy
        return 1;
    }

    lua.pushNil();
    return 1;
}

/// Lua accessor: req:get_header(name)
fn luaReqGetHeader(lua: *Lua) callconv(.c) c_int {
    const req = getUserdata(lua, 1);

    // Get header name from Lua
    const name_cstr = lua.toString(2) catch {
        lua.pushString("get_header: name must be a string");
        lua.raiseError();
        return 0;
    };
    const name = std.mem.span(name_cstr);

    // Get header value (case-insensitive)
    if (req.getHeader(name)) |value| {
        lua.pushLString(value); // Zero-copy
        return 1;
    }

    lua.pushNil();
    return 1;
}

/// Lua accessor: req:get_body()
fn luaReqGetBody(lua: *Lua) callconv(.c) c_int {
    const req = getUserdata(lua, 1);
    const body = req.getBody();
    lua.pushLString(body); // Zero-copy
    return 1;
}

/// Register Request metatable with Lua
/// This makes req:get_method() syntax work
pub fn registerRequestMetatable(lua: *Lua) void {
    // Create metatable
    _ = lua.newMetatable("Request");

    // Set __index to self (enables method syntax)
    lua.pushValue(-1);
    lua.setField(-2, "__index");

    // Register methods
    lua.pushCFunction(luaReqGetMethod);
    lua.setField(-2, "get_method");

    lua.pushCFunction(luaReqGetPath);
    lua.setField(-2, "get_path");

    lua.pushCFunction(luaReqGetParam);
    lua.setField(-2, "get_param");

    lua.pushCFunction(luaReqGetHeader);
    lua.setField(-2, "get_header");

    lua.pushCFunction(luaReqGetBody);
    lua.setField(-2, "get_body");

    // Pop metatable
    lua.pop(1);

    std.log.info("Request metatable registered", .{});
}
