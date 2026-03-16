const std = @import("std");
const Lua = @import("luajit").Lua;
const router_mod = @import("router.zig");
const Router = router_mod.Router;

// === Declarative Route Table Processing ===
// Extracted from lua_api.zig — walks keyway.routes and registers with the Router.

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

/// Process keyway.static table after script load.
/// Registers static file serving routes with the router.
pub fn processStaticTable(lua: *Lua, router: *Router) !void {
    const keyway_type = lua.getGlobal("keyway");
    if (keyway_type != .table) {
        lua.pop(1);
        return; // no keyway table — not an error
    }

    const static_type = lua.getField(-1, "static");
    if (static_type != .table) {
        lua.pop(2);
        return; // no keyway.static — not an error, static serving is optional
    }

    // Iterate keyway.static entries: { ["/prefix"] = { root = "...", index = "..." } }
    lua.pushNil();
    while (lua.next(-2)) {
        const key_cstr = lua.toString(-2) catch {
            lua.pop(1);
            continue;
        };
        const prefix = std.mem.span(key_cstr);

        if (!lua.isTable(-1) or prefix.len == 0 or prefix[0] != '/') {
            std.log.warn("keyway.static: ignoring invalid entry key={s}", .{prefix});
            lua.pop(1);
            continue;
        }

        // Read root (required)
        const root_type = lua.getField(-1, "root");
        const root_str = if (root_type == .string) std.mem.span(lua.toString(-1) catch "") else "";
        lua.pop(1);

        if (root_str.len == 0) {
            std.log.warn("keyway.static[{s}]: missing 'root' field", .{prefix});
            lua.pop(1);
            continue;
        }

        // Read index (optional, defaults to "index.html")
        const index_type = lua.getField(-1, "index");
        const index_str = if (index_type == .string) std.mem.span(lua.toString(-1) catch "index.html") else "index.html";
        lua.pop(1);

        router.addStaticRoute(prefix, root_str, index_str) catch |err| {
            std.log.err("keyway.static[{s}]: failed to register: {}", .{ prefix, err });
            lua.pop(1);
            continue;
        };

        std.log.info("static route registered prefix={s} root={s} index={s}", .{ prefix, root_str, index_str });
        lua.pop(1); // pop value, keep key
    }

    lua.pop(2); // pop static + keyway
}
