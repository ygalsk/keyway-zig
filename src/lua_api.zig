const std = @import("std");
const Lua = @import("luajit").Lua;
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const RadixRouter = @import("radix_router.zig").RadixRouter;
const handler = @import("handler.zig");

// === HttpExchange Metatable ===

/// Helper: Get HttpExchange userdata from Lua stack
fn getExchange(lua: *Lua, index: i32) *HttpExchange {
    const ud = lua.toUserdata(index) orelse unreachable;
    return @as(*HttpExchange, @ptrCast(@alignCast(ud)));
}

/// Lua metamethod: __index for reading ctx.field
fn luaExchangeIndex(lua: *Lua) callconv(.c) c_int {
    const ex = getExchange(lua, 1);
    const key = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };
    const key_str = std.mem.span(key);

    if (std.mem.eql(u8, key_str, "method")) {
        lua.pushLString(ex.method);
    } else if (std.mem.eql(u8, key_str, "path")) {
        lua.pushLString(ex.path);
    } else if (std.mem.eql(u8, key_str, "body")) {
        lua.pushLString(ex.body);
    } else if (std.mem.eql(u8, key_str, "status")) {
        lua.pushInteger(@intCast(ex.status));
    } else if (std.mem.eql(u8, key_str, "params")) {
        pushParamsTable(lua, ex.params);
    } else if (std.mem.eql(u8, key_str, "headers")) {
        pushHeadersProxy(lua, ex);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// Lua metamethod: __newindex for writing ctx.field = value
fn luaExchangeNewIndex(lua: *Lua) callconv(.c) c_int {
    const ex = getExchange(lua, 1);
    const key = lua.toString(2) catch return 0;
    const key_str = std.mem.span(key);

    if (std.mem.eql(u8, key_str, "status")) {
        const status = lua.toInteger(3);
        ex.status = @intCast(status);
    } else if (std.mem.eql(u8, key_str, "body")) {
        const body = lua.toString(3) catch return 0;
        ex.response_body = std.mem.span(body);
        // Note: Lua string lives on stack, Zig must copy before popping
        // Copy happens in lua_state.zig after Lua call returns
    }
    // Ignore writes to read-only fields (method, path, params)
    // Headers assignment handled by HeadersProxy
    return 0;
}

// === Params Table (read-only) ===

/// Push params as a Lua table: {id = "123", name = "foo"}
/// Uses cached table from registry to avoid per-request allocation
fn pushParamsTable(lua: *Lua, params: *const handler.ParamArray) void {
    // Get cached params table from registry (stored during LuaState.init)
    _ = lua.getField(Lua.PseudoIndex.Registry, "_PARAMS_TABLE");

    // Clear existing entries (set them to nil)
    lua.pushNil();
    while (lua.next(-2)) {
        lua.pop(1); // Pop value
        lua.pushValue(-1); // Duplicate key
        lua.pushNil(); // nil value
        lua.setTable(-4); // table[key] = nil
    }

    // Populate table with current params
    for (params.items[0..params.len]) |p| {
        // Push key
        lua.pushLString(p.key);
        // Push value
        lua.pushLString(p.value);
        // Set table[key] = value
        lua.setTable(-3);
    }

    // Table is now on top of stack with current params
}

// === Headers Proxy (for ctx.headers["Key"] = "value") ===

/// Public so LuaState can create cached instance
pub const HeadersProxy = struct {
    exchange: *HttpExchange,
};

/// Push HeadersProxy userdata for ctx.headers access
/// Uses cached proxy from registry to avoid per-request allocation
fn pushHeadersProxy(lua: *Lua, exchange: *HttpExchange) void {
    // Get cached proxy from registry (stored during LuaState.init)
    _ = lua.getField(Lua.PseudoIndex.Registry, "_HEADERS_PROXY");

    // Update the cached proxy's exchange pointer to current exchange
    const proxy_ud = lua.toUserdata(-1) orelse unreachable;
    const proxy = @as(*HeadersProxy, @ptrCast(@alignCast(proxy_ud)));
    proxy.exchange = exchange;

    // Proxy is now on top of stack pointing to current exchange
}

/// Lua metamethod: HeadersProxy __index for reading ctx.headers["Key"]
fn luaHeadersIndex(lua: *Lua) callconv(.c) c_int {
    const proxy_ud = lua.toUserdata(1) orelse {
        lua.pushNil();
        return 1;
    };
    const proxy = @as(*HeadersProxy, @ptrCast(@alignCast(proxy_ud)));

    const key = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };
    const key_str = std.mem.span(key);

    // Search request headers first
    for (proxy.exchange.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, key_str)) {
            lua.pushLString(h.value);
            return 1;
        }
    }

    // Search response headers
    for (proxy.exchange.response_headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, key_str)) {
            lua.pushLString(h.value);
            return 1;
        }
    }

    lua.pushNil();
    return 1;
}

/// Lua metamethod: HeadersProxy __newindex for writing ctx.headers["Key"] = "value"
fn luaHeadersNewIndex(lua: *Lua) callconv(.c) c_int {
    const proxy_ud = lua.toUserdata(1) orelse return 0;
    const proxy = @as(*HeadersProxy, @ptrCast(@alignCast(proxy_ud)));

    const key = lua.toString(2) catch return 0;
    const value = lua.toString(3) catch return 0;

    const key_str = std.mem.span(key);
    const value_str = std.mem.span(value);

    proxy.exchange.addResponseHeader(key_str, value_str) catch {
        lua.pushString("Failed to add header");
        lua.raiseError();
        return 0;
    };

    return 0;
}

// === Metatable Registration ===

/// Register HttpExchange metatable with Lua
pub fn registerHttpExchangeMetatable(lua: *Lua) void {
    // Main exchange metatable
    _ = lua.newMetatable("HttpExchange");

    lua.pushCFunction(luaExchangeIndex);
    lua.setField(-2, "__index");

    lua.pushCFunction(luaExchangeNewIndex);
    lua.setField(-2, "__newindex");

    lua.pop(1);

    // Headers proxy metatable
    _ = lua.newMetatable("HttpExchange.Headers");

    lua.pushCFunction(luaHeadersIndex);
    lua.setField(-2, "__index");

    lua.pushCFunction(luaHeadersNewIndex);
    lua.setField(-2, "__newindex");

    lua.pop(1);

    std.log.info("HttpExchange metatables registered", .{});
}

// === Keystone Module (add_route) ===

/// Lua function: keystone.add_route(method, pattern, handler_fn)
/// Registers a route with a Lua handler function
fn luaAddRoute(lua: *Lua) callconv(.c) c_int {
    // Get router from upvalue
    const router_ud = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse {
        lua.pushString("Internal error: router upvalue missing");
        lua.raiseError();
        return 0;
    };
    const router = @as(*RadixRouter, @ptrCast(@alignCast(router_ud)));

    // Check argument count
    if (lua.getTop() != 3) {
        lua.pushString("add_route requires 3 arguments: method, pattern, handler_fn");
        lua.raiseError();
        return 0;
    }

    // Get method (arg 1)
    const method_cstr = lua.toString(1) catch {
        lua.pushString("add_route: method must be a string");
        lua.raiseError();
        return 0;
    };
    const method = std.mem.span(method_cstr);

    // Get pattern (arg 2)
    const pattern_cstr = lua.toString(2) catch {
        lua.pushString("add_route: pattern must be a string");
        lua.raiseError();
        return 0;
    };
    const pattern = std.mem.span(pattern_cstr);

    // Get handler function (arg 3)
    if (!lua.isFunction(3)) {
        lua.pushString("add_route: handler must be a function");
        lua.raiseError();
        return 0;
    }

    // Store handler function in Lua registry
    lua.pushValue(3); // Push handler function to top
    const lua_ref = lua.ref(Lua.PseudoIndex.Registry); // Store and get reference

    // Add route to router
    router.addRoute(method, pattern, lua_ref) catch {
        lua.unref(Lua.PseudoIndex.Registry, lua_ref);
        lua.pushString("add_route: failed to register route");
        lua.raiseError();
        return 0;
    };

    std.log.info("Route registered: {s} {s} -> lua_ref:{d}", .{ method, pattern, lua_ref });

    return 0; // No return values
}

/// Register the keystone module with Lua
/// Creates global `keystone` table with add_route function
pub fn registerKeystoneModule(lua: *Lua, router: *RadixRouter) void {
    // Register HttpExchange metatables first
    registerHttpExchangeMetatable(lua);

    // Create keystone table
    lua.createTable(0, 1);

    // Register add_route function with router as upvalue
    lua.pushLightUserdata(router);
    lua.pushCClosure(luaAddRoute, 1);
    lua.setField(-2, "add_route");

    // Set as global
    lua.setGlobal("keystone");

    std.log.info("Keystone Lua module registered", .{});
}
