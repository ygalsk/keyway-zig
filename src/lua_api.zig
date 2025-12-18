
const std = @import("std");
const Lua = @import("luajit").Lua;
const RadixRouter = @import("radix_router.zig").RadixRouter;
const lua_request = @import("lua_request.zig");
const lua_response = @import("lua_response.zig");

/// Register the keystone module with Lua
/// Creates global `keystone` table with add_route function
pub fn registerKeystoneModule(lua: *Lua, router: *RadixRouter) void {
    // Create keystone table
    lua.createTable(0, 0);

    // Register add_route function with router as upvalue
    lua.pushLightUserdata(router);
    lua.pushCClosure(luaAddRoute, 1);
    lua.setField(-2, "add_route");

    // Set as global
    lua.setGlobal("keystone");

    // Register Request and Response metatables
    lua_request.registerRequestMetatable(lua);
    lua_response.registerResponseMetatable(lua);

    std.log.info("Keystone Lua module registered", .{});
}

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
