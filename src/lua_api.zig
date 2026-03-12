const std = @import("std");
const Lua = @import("luajit").Lua;
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const Router = @import("router.zig").Router;
const handler = @import("handler.zig");

// === HttpExchange Metatable ===

/// Helper: Get HttpExchange from pointer-in-userdata on Lua stack.
/// Userdata contains *HttpExchange (a pointer to the arena-allocated exchange).
fn getExchange(lua: *Lua, index: i32) *HttpExchange {
    const ud = lua.toUserdata(index) orelse @panic("metatable dispatch: expected HttpExchange userdata");
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
    ) catch unreachable;

    std.log.debug("keyway lua module registered", .{});
}

// === Declarative Route Table Processing ===

const http_methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" };

fn isHttpMethod(key: []const u8) bool {
    for (http_methods) |m| {
        if (std.mem.eql(u8, key, m)) return true;
    }
    return false;
}

/// Process keyway.routes table after script load.
/// Walks the declarative route table and registers routes with the radix router.
pub fn processRouteTable(lua: *Lua, router: *Router, allocator: std.mem.Allocator) !void {
    const keyway_type = lua.getGlobal("keyway");
    if (keyway_type != .table) {
        lua.pop(1);
        std.log.err("keyway global is not a table", .{});
        return error.Runtime;
    }

    const routes_type = lua.getField(-1, "routes");
    if (routes_type != .table) {
        lua.pop(2);
        std.log.err("keyway.routes is not a table", .{});
        return error.Runtime;
    }

    const empty_mw: []const i32 = &.{};
    try walkTable(lua, router, -1, "", empty_mw, allocator);

    lua.pop(2); // pop routes + keyway
}

fn walkTable(
    lua: *Lua,
    router: *Router,
    table_idx: i32,
    path_prefix: []const u8,
    parent_middleware: []const i32,
    allocator: std.mem.Allocator,
) !void {
    // Convert to absolute index so stack pushes don't invalidate it
    const abs_idx = if (table_idx > 0) table_idx else lua.getTop() + table_idx + 1;

    // Check for middleware key at this level
    var middleware: []const i32 = parent_middleware;
    var owns_middleware = false;

    const mw_type = lua.getField(abs_idx, "middleware");
    if (mw_type == .table) {
        middleware = try collectMiddleware(lua, -1, parent_middleware, allocator);
        owns_middleware = middleware.len > parent_middleware.len;
    }
    lua.pop(1); // pop middleware value

    defer if (owns_middleware) {
        // Unref only the middleware refs collected at THIS level (not parent's)
        for (middleware[parent_middleware.len..]) |mw_ref| {
            lua.unref(Lua.PseudoIndex.Registry, mw_ref);
        }
        allocator.free(@constCast(middleware));
    };

    // Iterate table entries
    lua.pushNil();
    while (lua.next(abs_idx)) {
        // Key at -2, value at -1
        const key_cstr = lua.toString(-2) catch {
            lua.pop(1); // pop value, keep key for next
            continue;
        };
        const key = std.mem.span(key_cstr);

        // Skip middleware key (already handled above)
        if (std.mem.eql(u8, key, "middleware")) {
            lua.pop(1);
            continue;
        }

        if (lua.isFunction(-1) and isHttpMethod(key)) {
            // HTTP method -> handler function
            try registerRoute(lua, router, key, path_prefix, -1, middleware);
        } else if (lua.isTable(-1) and key.len > 0 and key[0] == '/') {
            // Nested path segment -> recurse
            const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path_prefix, key });
            defer allocator.free(full_path);
            try walkTable(lua, router, -1, full_path, middleware, allocator);
        } else {
            std.log.warn("Ignoring unknown route table key: {s}", .{key});
        }

        lua.pop(1); // pop value, keep key for next iteration
    }
}

fn collectMiddleware(
    lua: *Lua,
    array_idx: i32,
    parent_refs: []const i32,
    allocator: std.mem.Allocator,
) ![]const i32 {
    const abs_idx = if (array_idx > 0) array_idx else lua.getTop() + array_idx + 1;

    // Count array elements
    var count: usize = 0;
    while (true) : (count += 1) {
        const t = lua.getTableIndexRaw(abs_idx, @intCast(count + 1));
        if (t == .nil) {
            lua.pop(1);
            break;
        }
        lua.pop(1);
    }

    if (count == 0) return parent_refs;

    // Allocate combined slice: parent refs + new refs
    const combined = try allocator.alloc(i32, parent_refs.len + count);
    @memcpy(combined[0..parent_refs.len], parent_refs);

    // Ref each middleware function
    for (0..count) |i| {
        _ = lua.getTableIndexRaw(abs_idx, @intCast(i + 1));
        if (!lua.isFunction(-1)) {
            // Clean up already-refed entries
            for (0..i) |j| {
                lua.unref(Lua.PseudoIndex.Registry, combined[parent_refs.len + j]);
            }
            lua.pop(1);
            allocator.free(combined);
            std.log.err("middleware[{d}] is not a function", .{i + 1});
            return error.Runtime;
        }
        combined[parent_refs.len + i] = lua.ref(Lua.PseudoIndex.Registry);
    }

    return combined;
}

fn registerRoute(
    lua: *Lua,
    router: *Router,
    method: []const u8,
    path: []const u8,
    handler_idx: i32,
    middleware: []const i32,
) !void {
    // Convert handler index to absolute (stack will grow when we push things)
    const abs_handler = if (handler_idx > 0) handler_idx else lua.getTop() + handler_idx + 1;

    if (middleware.len == 0) {
        // No middleware — ref the handler directly
        lua.pushValue(abs_handler);
        const lua_ref = lua.ref(Lua.PseudoIndex.Registry);
        router.addRoute(method, path, lua_ref) catch {
            lua.unref(Lua.PseudoIndex.Registry, lua_ref);
            return error.Runtime;
        };
        std.log.debug("route registered method={s} path={s} lua_ref={d}", .{ method, path, lua_ref });
    } else {
        // Build middleware chain via __keyway_wrap_chain(handler, middleware_table)
        _ = lua.getGlobal("__keyway_wrap_chain");
        lua.pushValue(abs_handler);

        // Build middleware array table
        lua.createTable(@intCast(middleware.len), 0);
        for (middleware, 0..) |mw_ref, i| {
            _ = lua.getTableIndexRaw(Lua.PseudoIndex.Registry, mw_ref);
            lua.setTableIndexRaw(-2, @intCast(i + 1));
        }

        // Call __keyway_wrap_chain(handler, mw_table) -> wrapped_fn
        lua.callProtected(2, 1, 0) catch {
            std.log.err("Failed to build middleware chain for {s} {s}", .{ method, path });
            return error.Runtime;
        };

        // Wrapped function is on top of stack
        const lua_ref = lua.ref(Lua.PseudoIndex.Registry);
        router.addRoute(method, path, lua_ref) catch {
            lua.unref(Lua.PseudoIndex.Registry, lua_ref);
            return error.Runtime;
        };
        std.log.debug("route registered method={s} path={s} lua_ref={d} middleware={d}", .{ method, path, lua_ref, middleware.len });
    }
}
