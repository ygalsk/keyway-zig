const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const Router = @import("router.zig").Router;
const handler = @import("handler.zig");
const route_loader = @import("route_loader.zig");

// Re-export route table processing (now lives in route_loader.zig)
pub const processRouteTable = route_loader.processRouteTable;

// === HttpExchange Metatable ===

/// Helper: Get HttpExchange from pointer-in-userdata on Lua stack.
/// Userdata contains *HttpExchange (a pointer to the arena-allocated exchange).
fn getExchange(lua: *Lua, index: i32) *HttpExchange {
    const ud = lua.toUserdata(index) orelse {
        lua.pushString("metatable dispatch: expected HttpExchange userdata");
        lua.raiseError();
        unreachable;
    };
    return @as(**HttpExchange, @ptrCast(@alignCast(ud))).*;
}

/// Helper: Get HeadersProxy from userdata at given stack index.
inline fn getProxy(lua: *Lua, index: i32) ?*HeadersProxy {
    const ud = lua.toUserdata(index) orelse return null;
    return @as(*HeadersProxy, @ptrCast(@alignCast(ud)));
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
    } else if (std.mem.eql(u8, key_str, "query")) {
        pushQueryTable(lua, ex.query);
    } else if (std.mem.eql(u8, key_str, "headers")) {
        pushHeadersProxy(lua, ex);
    } else if (std.mem.eql(u8, key_str, "request_headers")) {
        pushRequestHeadersTable(lua, ex.headers);
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
        const body_span = std.mem.span(body);
        // Arena-dupe immediately — Lua string lifetime is unpredictable across yields.
        // This eliminates the use-after-free class entirely.
        // Free previous body if any (no-op on arena allocator, needed for test allocator)
        if (ex.response_body.len > 0) {
            ex.allocator.free(ex.response_body);
        }
        ex.response_body = ex.allocator.dupe(u8, body_span) catch {
            lua.pushString("body assignment: arena alloc failed");
            lua.raiseError();
            return 0;
        };
    } else if (std.mem.eql(u8, key_str, "upgrade")) {
        const val = lua.toString(3) catch return 0;
        const val_str = std.mem.span(val);
        if (std.mem.eql(u8, val_str, "websocket")) {
            ex.upgrade_websocket = true;
        } else if (std.mem.eql(u8, val_str, "sse")) {
            ex.upgrade_sse = true;
        }
    } else if (std.mem.eql(u8, key_str, "sse_room")) {
        const val = lua.toString(3) catch return 0;
        const val_str = std.mem.span(val);
        ex.sse_room = ex.allocator.dupe(u8, val_str) catch return 0;
    } else if (std.mem.eql(u8, key_str, "on_message")) {
        if (lua.isFunction(3)) {
            lua.pushValue(3);
            ex.ws_on_message_ref = lua.ref(Lua.PseudoIndex.Registry);
        }
    } else if (std.mem.eql(u8, key_str, "on_close")) {
        if (lua.isFunction(3)) {
            lua.pushValue(3);
            ex.ws_on_close_ref = lua.ref(Lua.PseudoIndex.Registry);
        }
    }
    // Ignore writes to read-only fields (method, path, params)
    // Headers assignment handled by HeadersProxy
    return 0;
}

// === Params Table (read-only) ===

/// Push params as a fresh Lua table: {id = "123", name = "foo"}
/// Creates a new table per request (max 4 entries — negligible cost).
fn pushParamsTable(lua: *Lua, params: *const handler.ParamArray) void {
    lua.createTable(0, @intCast(params.len));

    for (params.items[0..params.len]) |p| {
        lua.pushLString(p.key);
        lua.pushLString(p.value);
        lua.setTable(-3);
    }
}

// === Query Table (read-only) ===

/// Push query params as a fresh Lua table: {foo = "bar", page = "2"}
/// Creates a new table per request (max 4 entries — negligible cost).
fn pushQueryTable(lua: *Lua, query: *const handler.QueryArray) void {
    lua.createTable(0, @intCast(query.len));

    for (query.items[0..query.len]) |p| {
        lua.pushLString(p.key);
        lua.pushLString(p.value);
        lua.setTable(-3);
    }
}

// === Request Headers Table (read-only array) ===

/// Push all request headers as a Lua array of {name, value} pairs.
/// Returns: { {"Content-Type", "application/json"}, {"Host", "localhost"}, ... }
fn pushRequestHeadersTable(lua: *Lua, headers: []const http.Header) void {
    lua.createTable(@intCast(headers.len), 0);
    for (headers, 0..) |h, i| {
        lua.createTable(2, 0);
        lua.pushLString(h.name);
        lua.setTableIndexRaw(-2, 1);
        lua.pushLString(h.value);
        lua.setTableIndexRaw(-2, 2);
        lua.setTableIndexRaw(-2, @intCast(i + 1));
    }
}

// === Headers Proxy (for ctx.headers["Key"] = "value") ===

/// Public so LuaState can create cached instance
pub const HeadersProxy = struct {
    exchange: *HttpExchange,
};

/// Push a fresh HeadersProxy userdata for ctx.headers access.
/// Creates a new proxy per request — no singleton sharing across connections.
fn pushHeadersProxy(lua: *Lua, exchange: *HttpExchange) void {
    const proxy_ud = lua.newUserdata(@sizeOf(HeadersProxy));
    const proxy = @as(*HeadersProxy, @ptrCast(@alignCast(proxy_ud)));
    proxy.* = .{ .exchange = exchange };

    _ = lua.getMetatableRegistry("HttpExchange.Headers");
    lua.setMetatable(-2);
}

/// Lua metamethod: HeadersProxy __index for reading ctx.headers["Key"]
fn luaHeadersIndex(lua: *Lua) callconv(.c) c_int {
    const proxy = getProxy(lua, 1) orelse {
        lua.pushNil();
        return 1;
    };

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
    const proxy = getProxy(lua, 1) orelse return 0;

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

// === WsContext (WebSocket message context for on_message callbacks) ===

/// WsContext userdata — holds a pointer to the current message payload.
/// Created fresh per WS message dispatch.
pub const WsContext = struct {
    message: []const u8,
};

/// Helper: Get WsContext from userdata at given stack index.
fn getWsContext(lua: *Lua, index: i32) ?*WsContext {
    const ud = lua.toUserdata(index) orelse return null;
    return @as(*WsContext, @ptrCast(@alignCast(ud)));
}

/// Lua metamethod: __index for reading ws.message and ws:send()
fn luaWsContextIndex(lua: *Lua) callconv(.c) c_int {
    const key = lua.toString(2) catch {
        lua.pushNil();
        return 1;
    };
    const key_str = std.mem.span(key);

    if (std.mem.eql(u8, key_str, "message")) {
        const ws_ctx = getWsContext(lua, 1) orelse {
            lua.pushNil();
            return 1;
        };
        lua.pushLString(ws_ctx.message);
    } else if (std.mem.eql(u8, key_str, "send")) {
        // Return the __keyway_ws_send global (C closure with LuaState upvalue)
        _ = lua.getGlobal("__keyway_ws_send");
    } else {
        lua.pushNil();
    }
    return 1;
}

/// ws:send(data) — Lua wrapper calls __keyway_ws_send(data) which is a C closure with LuaState upvalue.
/// This is registered via registerCosocketApi in lua_state.zig, same pattern as other cosocket ops.

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

    // WsContext metatable (for WebSocket on_message callbacks)
    _ = lua.newMetatable("WsContext");

    lua.pushCFunction(luaWsContextIndex);
    lua.setField(-2, "__index");

    lua.pop(1);

    std.log.debug("HttpExchange metatables registered", .{});
}

// === Keyway Module ===

/// Register the keyway module with Lua
/// Creates global `keyway` table (script assigns keyway.routes = {...})
pub fn registerKeywayModule(lua: *Lua) void {
    // Register HttpExchange metatables first
    registerHttpExchangeMetatable(lua);

    // Create empty keyway table (script populates keyway.routes)
    lua.createTable(0, 1);
    lua.setGlobal("keyway");

    // Register middleware chain builder as a global helper
    lua.doString(
        \\__keyway_wrap_chain = function(handler, middleware_list)
        \\    local chain = handler
        \\    for i = #middleware_list, 1, -1 do
        \\        local mw = middleware_list[i]
        \\        local next_fn = chain
        \\        chain = function(ctx)
        \\            local ok, err = pcall(mw, ctx, function() next_fn(ctx) end)
        \\            if not ok then
        \\                io.stderr:write("middleware error: " .. tostring(err) .. "\n")
        \\                ctx.status = 500
        \\                ctx.body = "Internal Server Error"
        \\            end
        \\        end
        \\    end
        \\    return chain
        \\end
    ) catch |err| {
        std.log.err("failed to register middleware wrapper: {}", .{err});
        return;
    };

    std.log.debug("keyway lua module registered", .{});
}

