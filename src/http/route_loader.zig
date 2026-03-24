const std = @import("std");
const Lua = @import("luajit").Lua;
const log = @import("../observability/log.zig");
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
        log.err().string("msg", "keyway global is not a table").log();
        return error.Runtime;
    }

    const routes_type = lua.getField(-1, "routes");
    if (routes_type != .table) {
        lua.pop(2);
        log.err().string("msg", "keyway.routes is not a table").log();
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
            log.warn().string("msg", "ignoring unknown route table key").string("key", key).log();
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

    // Ref each middleware function (supports both function values and string names)
    for (0..count) |i| {
        _ = lua.getTableIndexRaw(abs_idx, @intCast(i + 1));

        if (lua.isString(-1)) {
            // String middleware name — resolve via keyway.middleware.resolve()
            const name_cstr = lua.toString(-1) catch {
                for (0..i) |j| lua.unref(Lua.PseudoIndex.Registry, combined[parent_refs.len + j]);
                lua.pop(1);
                allocator.free(combined);
                log.err().string("msg", "middleware string read failed").int("index", i + 1).log();
                return error.Runtime;
            };
            const name = std.mem.span(name_cstr);
            lua.pop(1); // pop the string

            // Call keyway.middleware.resolve(name)
            _ = lua.getGlobal("keyway");
            _ = lua.getField(-1, "middleware");
            _ = lua.getField(-1, "resolve");
            lua.remove(-2); // remove keyway.middleware table
            lua.remove(-2); // remove keyway table
            _ = lua.pushString(name);
            lua.callProtected(1, 1, 0) catch {
                for (0..i) |j| lua.unref(Lua.PseudoIndex.Registry, combined[parent_refs.len + j]);
                allocator.free(combined);
                log.err().string("msg", "middleware resolve failed").string("name", name).log();
                return error.Runtime;
            };
            combined[parent_refs.len + i] = lua.ref(Lua.PseudoIndex.Registry);
        } else if (lua.isFunction(-1)) {
            combined[parent_refs.len + i] = lua.ref(Lua.PseudoIndex.Registry);
        } else {
            // Clean up already-refed entries
            for (0..i) |j| {
                lua.unref(Lua.PseudoIndex.Registry, combined[parent_refs.len + j]);
            }
            lua.pop(1);
            allocator.free(combined);
            log.err().string("msg", "middleware is not a function or string").int("index", i + 1).log();
            return error.Runtime;
        }
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
        log.debug().string("msg", "route registered").stringSafe("method", method).string("path", path).int("lua_ref", lua_ref).log();
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
            log.err().string("msg", "failed to build middleware chain").stringSafe("method", method).string("path", path).log();
            return error.Runtime;
        };

        // Wrapped function is on top of stack
        const lua_ref = lua.ref(Lua.PseudoIndex.Registry);
        router.addRoute(method, path, lua_ref) catch {
            lua.unref(Lua.PseudoIndex.Registry, lua_ref);
            return error.Runtime;
        };
        log.debug().string("msg", "route registered").stringSafe("method", method).string("path", path).int("lua_ref", lua_ref).int("middleware", middleware.len).log();
    }
}

/// Walk a keyway sub-table (e.g. keyway.static or keyway.proxy).
/// For each entry with a valid "/" prefix and table value, calls the visitor with the
/// Lua state (value table on top), prefix, and router. The visitor returns true to
/// continue iteration, false to skip (already logged its own warning).
fn walkKeywaySubtable(
    lua: *Lua,
    router: *Router,
    sub_table: [:0]const u8,
    log_context: []const u8,
    visitor: *const fn (*Lua, *Router, []const u8) void,
) void {
    const keyway_type = lua.getGlobal("keyway");
    if (keyway_type != .table) {
        lua.pop(1);
        return;
    }

    const field_type = lua.getField(-1, sub_table);
    if (field_type != .table) {
        lua.pop(2);
        return;
    }

    lua.pushNil();
    while (lua.next(-2)) {
        const key_cstr = lua.toString(-2) catch {
            lua.pop(1);
            continue;
        };
        const prefix = std.mem.span(key_cstr);

        if (!lua.isTable(-1) or prefix.len == 0 or prefix[0] != '/') {
            log.warn().string("msg", "ignoring invalid entry").string("context", log_context).string("key", prefix).log();
            lua.pop(1);
            continue;
        }

        visitor(lua, router, prefix);

        lua.pop(1); // pop value, keep key
    }

    lua.pop(2); // pop sub-table + keyway
}

/// Process keyway.static table after script load.
/// Registers static file serving routes with the router.
pub fn processStaticTable(lua: *Lua, router: *Router) void {
    walkKeywaySubtable(lua, router, "static", "keyway.static", registerStaticEntry);
}

fn registerStaticEntry(lua: *Lua, router: *Router, prefix: []const u8) void {
    // Read root (required)
    const root_type = lua.getField(-1, "root");
    const root_str = if (root_type == .string) std.mem.span(lua.toString(-1) catch "") else "";
    lua.pop(1);

    if (root_str.len == 0) {
        log.warn().string("msg", "keyway.static missing 'root' field").string("prefix", prefix).log();
        return;
    }

    // Read index (optional, defaults to "index.html")
    const index_type = lua.getField(-1, "index");
    const index_str = if (index_type == .string) std.mem.span(lua.toString(-1) catch "index.html") else "index.html";
    lua.pop(1);

    router.addStaticRoute(prefix, root_str, index_str) catch |err| {
        log.err().string("msg", "keyway.static failed to register").string("prefix", prefix).err(err).log();
        return;
    };

    log.info().string("msg", "static route registered").string("prefix", prefix).string("root", root_str).string("index", index_str).log();
}

/// Process keyway.proxy table after script load.
/// Registers reverse proxy routes with the router.
/// Format: keyway.proxy = { ["/__keyway/grafana"] = { host = "127.0.0.1", port = 3000 } }
pub fn processProxyTable(lua: *Lua, router: *Router) void {
    walkKeywaySubtable(lua, router, "proxy", "keyway.proxy", registerProxyEntry);
}

fn registerProxyEntry(lua: *Lua, router: *Router, prefix: []const u8) void {
    // Read host (required)
    const host_type = lua.getField(-1, "host");
    const host_str = if (host_type == .string) std.mem.span(lua.toString(-1) catch "") else "";
    lua.pop(1);

    if (host_str.len == 0) {
        log.warn().string("msg", "keyway.proxy missing 'host' field").string("prefix", prefix).log();
        return;
    }

    // Read port (required)
    const port_type = lua.getField(-1, "port");
    const port: u16 = if (port_type == .number) blk: {
        const n = lua.toInteger(-1);
        break :blk if (n >= 1 and n <= 65535) @intCast(n) else 0;
    } else 0;
    lua.pop(1);

    if (port == 0) {
        log.warn().string("msg", "keyway.proxy missing or invalid 'port' field").string("prefix", prefix).log();
        return;
    }

    // Read redirect (optional)
    const redirect_type = lua.getField(-1, "redirect");
    const redirect_str = if (redirect_type == .string) std.mem.span(lua.toString(-1) catch "") else "";
    lua.pop(1);

    // Read strip_prefix (optional, defaults to true)
    const sp_type = lua.getField(-1, "strip_prefix");
    const strip_prefix = if (sp_type == .boolean) lua.toBoolean(-1) else true;
    lua.pop(1);

    router.addProxyRoute(prefix, host_str, port, redirect_str, strip_prefix) catch |err| {
        log.err().string("msg", "keyway.proxy failed to register").string("prefix", prefix).err(err).log();
        return;
    };

    log.info().string("msg", "proxy route registered").string("prefix", prefix).string("host", host_str).int("port", port).log();
}
