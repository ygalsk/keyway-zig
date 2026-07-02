//! Lua metatable strategy and pointer-in-userdata pattern.
//!
//! Three metatables: HttpExchange (ctx), HttpExchange.Headers (ctx.headers), WsContext (ws).
//! Userdata contains a pointer (*HttpExchange or *WsContext), not the struct itself.
//! Fresh userdata per request/message — no singleton sharing across connections.
//!
//! Read path:  ctx.field → __index metamethod → reads from HttpExchange
//! Write path: ctx.field = val → __newindex → sets on HttpExchange (status, body, headers)

const std = @import("std");
const log = @import("../observability/log.zig");
const Lua = @import("luajit").Lua;
const http = @import("../http/http.zig");
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const params = @import("../http/params.zig");
const castUserdata = @import("../util/helpers.zig").castUserdata;

// === HttpExchange Metatable ===

/// Helper: Get HttpExchange from pointer-in-userdata on Lua stack.
/// Userdata contains *HttpExchange (a pointer to the arena-allocated exchange).
fn getExchange(lua: *Lua, index: i32) *HttpExchange {
    const ud = lua.toUserdata(index) orelse {
        lua.pushString("metatable dispatch: expected HttpExchange userdata");
        lua.raiseError();
        unreachable;
    };
    return castUserdata(*HttpExchange, @as(?*anyopaque, ud)).*;
}

/// Helper: Get HeadersProxy from userdata at given stack index.
inline fn getProxy(lua: *Lua, index: i32) ?*HeadersProxy {
    const ud = lua.toUserdata(index) orelse return null;
    return castUserdata(HeadersProxy, @as(?*anyopaque, ud));
}

/// Helper: convert the value at `index` to a string span, or raise a Lua error.
/// Metamethod keys/values must be string-convertible; a non-convertible value is
/// a caller bug, so surface it instead of silently returning nil/0 (issue #56).
fn checkString(lua: *Lua, index: i32, what: [*:0]const u8) [:0]const u8 {
    const s = lua.toString(index) catch {
        lua.pushString(what);
        lua.raiseError();
    };
    return std.mem.span(s);
}

/// Lua metamethod: __index for reading ctx.field
fn luaExchangeIndex(lua: *Lua) callconv(.c) c_int {
    const ex = getExchange(lua, 1);
    const key_str = checkString(lua, 2, "ctx index: key must be a string");

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
    } else if (std.mem.eql(u8, key_str, "remote_addr")) {
        lua.pushLString(ex.remote_addr);
    } else {
        lua.pushNil();
    }
    return 1;
}

/// Lua metamethod: __newindex for writing ctx.field = value
fn luaExchangeNewIndex(lua: *Lua) callconv(.c) c_int {
    const ex = getExchange(lua, 1);
    const key_str = checkString(lua, 2, "ctx newindex: key must be a string");

    if (std.mem.eql(u8, key_str, "status")) {
        const status = lua.toInteger(3);
        if (status < 100 or status > 599) {
            // Reject, don't clamp or crash: leave ex.status untouched and mark the
            // exchange failed. dispatchToHandler checks handler_error after a normal
            // return and sends 500 — a Lua-raised error here can't be safely unwound
            // through the coroutine (see #186).
            if (ex.handler_error == null) {
                ex.handler_error = std.fmt.allocPrint(ex.allocator, "ctx.status: {d} out of range (100-599)", .{status}) catch "ctx.status: out of range (100-599)";
            }
        } else {
            ex.status = @intCast(status);
        }
    } else if (std.mem.eql(u8, key_str, "body")) {
        const body_span = checkString(lua, 3, "ctx.body: value must be a string");
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
        const val_str = checkString(lua, 3, "ctx.upgrade: value must be a string");
        if (std.mem.eql(u8, val_str, "websocket")) {
            ex.upgrade_websocket = true;
        } else if (std.mem.eql(u8, val_str, "sse")) {
            ex.upgrade_sse = true;
        } else if (std.mem.eql(u8, val_str, "stream")) {
            ex.upgrade_stream = true;
        }
    } else if (std.mem.eql(u8, key_str, "sse_room")) {
        const val_str = checkString(lua, 3, "ctx.sse_room: value must be a string");
        ex.sse_room = ex.allocator.dupe(u8, val_str) catch {
            lua.pushString("ctx.sse_room: arena alloc failed");
            lua.raiseError();
        };
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
fn pushParamsTable(lua: *Lua, url_params: *const params.ParamArray) void {
    lua.createTable(0, @intCast(url_params.len));

    for (url_params.items[0..url_params.len]) |p| {
        lua.pushLString(p.key);
        lua.pushLString(p.value);
        lua.setTable(-3);
    }
}

// === Query Table (read-only) ===

/// Push query params as a fresh Lua table: {foo = "bar", page = "2"}
/// Creates a new table per request (max 4 entries — negligible cost).
fn pushQueryTable(lua: *Lua, query: *const params.QueryArray) void {
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

const HeadersProxy = struct {
    exchange: *HttpExchange,
};

/// Push a fresh HeadersProxy userdata for ctx.headers access.
/// Creates a new proxy per request — no singleton sharing across connections.
fn pushHeadersProxy(lua: *Lua, exchange: *HttpExchange) void {
    const proxy_ud = lua.newUserdata(@sizeOf(HeadersProxy));
    const proxy = castUserdata(HeadersProxy, @as(?*anyopaque, proxy_ud));
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
    return castUserdata(WsContext, @as(?*anyopaque, ud));
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
/// Registered via registerAsyncApi in lua_state.zig.

// === Metatable Registration ===

/// Register a Lua metatable with optional __index and __newindex metamethods.
fn registerMetatable(
    lua: *Lua,
    name: [:0]const u8,
    index_fn: ?*const fn (*Lua) callconv(.c) c_int,
    newindex_fn: ?*const fn (*Lua) callconv(.c) c_int,
) void {
    _ = lua.newMetatable(name);
    if (index_fn) |f| {
        lua.pushCFunction(f);
        lua.setField(-2, "__index");
    }
    if (newindex_fn) |f| {
        lua.pushCFunction(f);
        lua.setField(-2, "__newindex");
    }
    lua.pop(1);
}

/// Register HttpExchange metatable with Lua
pub fn registerHttpExchangeMetatable(lua: *Lua) void {
    registerMetatable(lua, "HttpExchange", luaExchangeIndex, luaExchangeNewIndex);
    registerMetatable(lua, "HttpExchange.Headers", luaHeadersIndex, luaHeadersNewIndex);
    registerMetatable(lua, "WsContext", luaWsContextIndex, null);
    log.debug().string("msg", "HttpExchange metatables registered").log();
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
        log.err().string("msg", "failed to register middleware wrapper").err(err).log();
        return;
    };

    log.debug().string("msg", "keyway lua module registered").log();
}

// (#172) ctx.status out of range must not raise (unsafe to unwind through a coroutine,
// see #186) — it should leave ex.status untouched and set the sticky handler_error flag.
test "ctx.status rejects out-of-range values via handler_error, not raiseError" {
    const allocator = std.testing.allocator;

    const lua = try Lua.init(allocator);
    defer lua.deinit();
    registerHttpExchangeMetatable(lua);

    var url_params = params.ParamArray{};
    var query = params.QueryArray{};
    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 0);
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

    const ud = lua.newUserdata(@sizeOf(*HttpExchange));
    castUserdata(*HttpExchange, @as(?*anyopaque, ud)).* = &exchange;
    lua.getMetatableRegistry("HttpExchange");
    lua.setMetatable(-2);
    lua.setGlobal("ctx");

    try lua.doString("ctx.status = 70000");
    try std.testing.expectEqual(@as(u16, 200), exchange.status);
    try std.testing.expect(exchange.handler_error != null);
    try std.testing.expect(std.mem.indexOf(u8, exchange.handler_error.?, "70000") != null);

    // Sticky: a second out-of-range write must not overwrite the first error.
    try lua.doString("ctx.status = -1");
    try std.testing.expect(std.mem.indexOf(u8, exchange.handler_error.?, "70000") != null);
    allocator.free(exchange.handler_error.?);
    exchange.handler_error = null;

    // A fresh, valid assignment still works and leaves handler_error null.
    try lua.doString("ctx.status = 204");
    try std.testing.expectEqual(@as(u16, 204), exchange.status);
    try std.testing.expect(exchange.handler_error == null);
}
