//! Per-worker Lua state aggregation and initialization.
//!
//! Each worker thread owns one LuaState containing: the Lua VM, cached coroutine thread,
//! the async-yield bridge (pending WS send + suspended coroutine state, shared by WS/
//! SSE/stream), and an SSE registry pointer.
//!
//! Init order: Lua VM → std libs → keyway module → embedded stdlib → cached thread → package paths.
//! After init: registerAsyncApi → setWorkerGlobals → loadScript → processRouteTable.

const std = @import("std");
const Lua = @import("luajit").Lua;
const c = @import("luajit_c");
const log = @import("../observability/log.zig");
const http = @import("../http/http.zig");
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const Router = @import("../http/router.zig").Router;
const lua_api = @import("lua_api.zig");
const lua_file_io = @import("lua_file_io.zig");
const Connection = @import("../core/handler.zig").Connection;
const castUserdata = @import("../util/helpers.zig").castUserdata;
const helpers = @import("../util/helpers.zig");
const SseRegistry = @import("../protocol/sse.zig").SseRegistry;
const prom = @import("../observability/prom.zig");

// Embedded stdlib modules — compiled into the binary at build time.
// Registered as package.preload["keyway.*"] so require() resolves without disk I/O.
// scripts/keyway/stdlib.zig uses @embedFile for sibling .lua files, imported via build.zig.
const json = @import("json.zig");
const stdlib = @import("stdlib");
const embedded_modules = .{
    .{ "keyway.response", stdlib.response },
    .{ "keyway.json", stdlib.json },
};

/// Lua state manager - Deep module with simple interface
/// Manages a single long-lived Lua state for the server
/// In the future, this will be one state per worker thread
/// Result of calling or resuming a Lua handler
pub const HandlerResult = enum { completed, yielded };

pub const LuaState = struct {
    lua: *Lua,
    allocator: std.mem.Allocator,

    // Cached reusable coroutine thread (avoids lua_newThread per request)
    cached_thread: *Lua = undefined,
    cached_thread_ref: i32 = 0,

    // WS send payload written by keyway_ws_send during lua_resume, read by
    // conn_ws.submitWsSend after LUA_YIELD. libxev is single-threaded per
    // worker — no concurrent access between write and read.
    pending_ws_send: ?[]const u8 = null,

    // Temporary coroutine state (copied to Connection after yield)
    coroutine_ref: i32 = 0,
    coroutine_thread: ?*Lua = null,

    // Current connection being served (set during handler call/resume, cleared on completion)
    // Used by the async C bridge functions (ws_send, sse_broadcast) to reach the Connection.
    current_connection: ?*Connection = null,

    // Lua script timing: duration + route label for the currently-running coroutine,
    // consumed by recordCoroutineDuration() for the Prometheus histogram.
    timing: struct {
        start_us: ?i64 = null,
        route: []const u8 = "",
    } = .{},

    // SSE: per-worker registry for broadcast (set by worker.zig)
    sse_registry: ?*SseRegistry = null,

    /// Initialize Lua state with standard libraries
    pub fn init(allocator: std.mem.Allocator) !LuaState {
        const lua = try Lua.init(allocator);
        errdefer lua.deinit();

        // Load standard libraries
        lua.openBaseLib();
        lua.openStringLib();
        lua.openTableLib();
        lua.openMathLib();
        lua.openPackageLib();
        lua.openIOLib(); // Required for LuaRocks to load modules from disk
        lua.openOSLib(); // Required for some LuaRocks modules (time, execute, etc.)
        lua.openDebugLib(); // Required for some LuaRocks modules (debug introspection)
        lua.openBitLib(); // Required for pgmoon and other LuaJIT modules (bit operations)
        lua.openJITLib(); // Required for JIT control (jit.on/off, jit.opt, etc.)
        lua.openFFILib(); // Required for FFI (ffi.cdef, ffi.C, ffi.new, etc.)

        // Register keyway module (must be done before creating userdata)
        lua_api.registerKeywayModule(lua);

        // Embed stdlib modules as package.preload entries (always available, no disk I/O)
        registerEmbeddedModules(lua);

        // Register JSON C functions as globals (used by lua/json.lua wrapper)
        lua.pushCFunction(json.jsonEncode);
        lua.setGlobal("__keyway_json_encode");
        lua.pushCFunction(json.jsonDecode);
        lua.setGlobal("__keyway_json_decode");

        // Create reusable coroutine thread (avoids lua_newThread per request)
        const cached_thread = lua.newThread();
        const cached_thread_ref = lua.ref(Lua.PseudoIndex.Registry);

        // Configure package.path for app-local requires and LuaRocks.
        // Stdlib modules are preloaded (above), so no scripts/ prefix needed.
        // KEYWAY_LUA_PATH / KEYWAY_LUA_CPATH override defaults if set.
        lua.doString(
            \\local custom_path = os.getenv("KEYWAY_LUA_PATH")
            \\local custom_cpath = os.getenv("KEYWAY_LUA_CPATH")
            \\if custom_path then
            \\    package.path = custom_path .. ";" .. package.path
            \\else
            \\    local home = os.getenv("HOME") or ""
            \\    package.path = "./?.lua;./?/init.lua;"
            \\        .. home .. "/.luarocks/share/lua/5.1/?.lua;"
            \\        .. home .. "/.luarocks/share/lua/5.1/?/init.lua;"
            \\        .. "/usr/share/lua/5.1/?.lua;"
            \\        .. "/usr/share/lua/5.1/?/init.lua;"
            \\        .. package.path
            \\end
            \\if custom_cpath then
            \\    package.cpath = custom_cpath .. ";" .. package.cpath
            \\else
            \\    local home = os.getenv("HOME") or ""
            \\    package.cpath = home .. "/.luarocks/lib/lua/5.1/?.so;"
            \\        .. "/usr/lib/lua/5.1/?.so;"
            \\        .. "/usr/lib64/lua/5.1/?.so;"
            \\        .. "/usr/share/lua/5.1/?.so;"
            \\        .. "/usr/local/lib/lua/5.1/?.so;"
            \\        .. package.cpath
            \\end
        ) catch |err| {
            log.warn().string("msg", "failed to configure Lua package paths").err(err).log();
        };

        return LuaState{
            .lua = lua,
            .allocator = allocator,
            .cached_thread = cached_thread,
            .cached_thread_ref = cached_thread_ref,
        };
    }

    /// Load and execute a Lua script file
    pub fn loadScript(self: *LuaState, path: []const u8) !void {
        // doFile expects sentinel-terminated string, allocate one
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        // Try to load and capture error if it fails
        self.lua.doFile(path_z) catch |err| {
            // Get error message from Lua stack
            if (self.lua.isString(-1)) {
                const err_msg = self.lua.toString(-1) catch "unknown error";
                log.err().string("msg", "Lua error loading script").string("path", path).string("error", std.mem.span(err_msg)).log();
                self.lua.pop(1); // Pop error message
            }
            return err;
        };
    }

    /// Load Lua code from string
    pub fn loadString(self: *LuaState, code: [:0]const u8) !void {
        try self.lua.doString(code);
    }

    /// Process keyway.routes declarative table after script load.
    /// Walks the nested table and registers routes with the radix router.
    pub fn processRouteTable(self: *LuaState, router: *Router) !void {
        try @import("../http/route_loader.zig").processRouteTable(self.lua, router, self.allocator);
    }

    /// Process keyway.static declarative table after script load.
    /// Registers static file serving routes with the router.
    pub fn processStaticTable(self: *LuaState, router: *Router) !void {
        try @import("../http/route_loader.zig").processStaticTable(self.lua, router);
    }

    /// Process keyway.proxy declarative table after script load.
    /// Registers reverse proxy routes with the router.
    pub fn processProxyTable(self: *LuaState, router: *Router) !void {
        try @import("../http/route_loader.zig").processProxyTable(self.lua, router);
    }

    /// Userdata variant for dispatchCoroutine — determines what gets pushed onto the thread stack.
    pub const UserdataKind = union(enum) {
        http: *HttpExchange,
        ws: lua_api.WsContext,
    };

    /// Generic coroutine dispatch: get/reuse thread, push handler + userdata, resume.
    /// Used by both HTTP handler dispatch and WebSocket on_message dispatch.
    pub fn dispatchCoroutine(self: *LuaState, lua_ref: i32, ud_kind: UserdataKind) !HandlerResult {
        // Reuse cached thread if available, otherwise create a new one
        // (cached thread is unavailable only when a previous handler is suspended)
        const thread = if (self.cached_thread_ref != 0) blk: {
            const t = self.cached_thread;
            t.setTop(0);
            break :blk t;
        } else self.lua.newThread();

        // Push handler function onto thread's stack (registry is shared across threads)
        const handler_type = thread.getTableIndexRaw(Lua.PseudoIndex.Registry, lua_ref);
        if (handler_type != .function) {
            if (self.cached_thread_ref == 0) self.lua.pop(1);
            return error.NotAFunction;
        }

        // Create userdata appropriate to the dispatch kind
        switch (ud_kind) {
            .http => |exchange| {
                const ud = thread.newUserdata(@sizeOf(*HttpExchange));
                castUserdata(*HttpExchange, @as(?*anyopaque, ud)).* = exchange;
                _ = thread.getMetatableRegistry("HttpExchange");
                thread.setMetatable(-2);
            },
            .ws => |ws_ctx| {
                const ud = thread.newUserdata(@sizeOf(lua_api.WsContext));
                castUserdata(lua_api.WsContext, @as(?*anyopaque, ud)).* = ws_ctx;
                _ = thread.getMetatableRegistry("WsContext");
                thread.setMetatable(-2);
            },
        }

        // Resume the coroutine: thread stack has [handler_fn, userdata]
        prom.luaCoroutineStarted();
        self.timing.start_us = @divTrunc(helpers.monotonicNanos(), std.time.ns_per_us);
        // Capture route for duration labeling from Connection's http_state
        if (self.current_connection) |conn| {
            self.timing.route = conn.http_state.route_pattern;
        } else {
            self.timing.route = "";
        }
        const status = c.lua_resume(@ptrCast(thread), 1);

        switch (status) {
            0 => {
                // LUA_OK — handler completed normally
                prom.luaCoroutineFinished();
                self.recordCoroutineDuration();
                if (self.cached_thread_ref == 0) self.lua.pop(1);
                return .completed;
            },
            1 => {
                // LUA_YIELD — handler wants outbound I/O (coroutine still active)
                if (self.cached_thread_ref != 0) {
                    self.coroutine_ref = self.cached_thread_ref;
                    self.cached_thread_ref = 0;
                } else {
                    self.coroutine_ref = self.lua.ref(Lua.PseudoIndex.Registry);
                }
                self.coroutine_thread = thread;
                return .yielded;
            },
            else => {
                prom.luaCoroutineFinished();
                if (thread.isString(-1)) {
                    const err_msg = thread.toString(-1) catch "unknown error";
                    // Attempt debug.traceback(msg, 2) for a full stack trace
                    const dbg_type = thread.getGlobal("debug");
                    if (dbg_type == .table) {
                        const tb_type = thread.getField(-1, "traceback");
                        if (tb_type == .function) {
                            thread.pushValue(-3); // push original error msg
                            thread.pushInteger(2); // skip 2 frames
                            thread.callProtected(2, 1, 0) catch {
                                log.err().string("msg", "coroutine error").int("ref", lua_ref).string("error", std.mem.span(err_msg)).log();
                                thread.setTop(0);
                                if (self.cached_thread_ref == 0) self.lua.pop(1);
                                return error.Runtime;
                            };
                            const tb_msg = thread.toString(-1) catch err_msg;
                            log.err().string("msg", "coroutine error").int("ref", lua_ref).string("traceback", std.mem.span(tb_msg)).log();
                            thread.setTop(0);
                            if (self.cached_thread_ref == 0) self.lua.pop(1);
                            return error.Runtime;
                        }
                        thread.pop(2); // pop non-function + debug table
                    } else {
                        thread.pop(1); // pop non-table
                    }
                    log.err().string("msg", "coroutine error").int("ref", lua_ref).string("error", std.mem.span(err_msg)).log();
                }
                if (self.cached_thread_ref == 0) self.lua.pop(1);
                return error.Runtime;
            },
        }
    }

    /// Call a Lua handler with HttpExchange using coroutine dispatch.
    /// Thin wrapper around dispatchCoroutine with HTTP userdata.
    pub fn callLuaHandler(
        self: *LuaState,
        lua_ref: i32,
        exchange: *HttpExchange,
    ) !HandlerResult {
        return self.dispatchCoroutine(lua_ref, .{ .http = exchange });
    }

    /// Resume a yielded handler coroutine after WS/SSE/stream flow control completes.
    /// Caller has already pushed result values onto the thread stack.
    /// Does NOT unref the coroutine — Connection.completeHandler handles that.
    pub fn resumeHandler(
        self: *LuaState,
        thread: *anyopaque,
        nresults: c_int,
    ) !HandlerResult {
        const status = c.lua_resume(@ptrCast(thread), nresults);

        switch (status) {
            0 => {
                // LUA_OK — handler completed
                prom.luaCoroutineFinished();
                self.recordCoroutineDuration();
                return .completed;
            },
            1 => {
                // LUA_YIELD — handler suspended for WS/SSE/stream flow control
                return .yielded;
            },
            else => {
                prom.luaCoroutineFinished();
                self.recordCoroutineDuration();
                const lua_thread: *Lua = @ptrCast(@alignCast(thread));
                if (lua_thread.isString(-1)) {
                    const err_msg = lua_thread.toString(-1) catch "unknown error";
                    log.err().string("msg", "lua resume error").string("error", std.mem.span(err_msg)).log();
                }
                return error.Runtime;
            },
        }
    }

    /// Set per-worker Lua globals (called once after init, before loadScript).
    /// Exposes keyway.worker_id so handlers can include it in page output.
    pub fn setWorkerGlobals(self: *LuaState, worker_id: usize) void {
        _ = self.lua.getGlobal("keyway"); // push keyway table
        self.lua.pushInteger(@intCast(worker_id)); // push value
        self.lua.setField(-2, "worker_id"); // keyway.worker_id = N
        self.lua.pop(1); // pop keyway table
    }

    /// Record coroutine execution duration for Prometheus metrics.
    fn recordCoroutineDuration(self: *LuaState) void {
        if (self.timing.start_us) |start| {
            const elapsed = @divTrunc(helpers.monotonicNanos(), std.time.ns_per_us) - start;
            prom.luaScriptDuration(self.timing.route, elapsed);
            self.timing.start_us = null;
        }
    }

    /// Register file I/O C functions as Lua globals.
    /// Admin-only operations — used by dashboard routes behind localhost_guard.
    pub fn registerFileApi(self: *LuaState) void {
        lua_file_io.registerFileApi(self);
    }

    /// Register async-yield C functions (ws_send, sse_broadcast) as Lua globals
    /// with *LuaState as upvalue. Must be called after init (needs stable *LuaState pointer).
    pub fn registerAsyncApi(self: *LuaState) void {
        const funcs = .{
            .{ "__keyway_ws_send", keyway_ws_send },
            .{ "__keyway_sse_broadcast", keyway_sse_broadcast },
        };

        inline for (funcs) |entry| {
            self.lua.pushLightUserdata(self);
            self.lua.pushCClosure(entry[1], 1);
            self.lua.setGlobal(entry[0]);
        }
    }

    /// __keyway_ws_send(data) → yields, resumes after WS frame is sent.
    /// arg 1 = self (WsContext userdata, from ws:send() colon syntax), arg 2 = data string.
    fn keyway_ws_send(lua: *Lua) callconv(.c) c_int {
        const ud = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse {
            lua.pushString("ws_send: expected LuaState upvalue");
            lua.raiseError();
            unreachable;
        };
        const state = castUserdata(LuaState, @as(?*anyopaque, ud));

        const data = lua.toLString(2) catch {
            lua.pushString("ws_send: data must be a string");
            lua.raiseError();
            return 0;
        };

        state.pending_ws_send = data;

        return c.lua_yield(@ptrCast(lua), 0);
    }

    /// SSE broadcast C function: __keyway_sse_broadcast(room, data)
    /// Non-yielding — broadcasts data to all SSE subscribers in a room.
    fn keyway_sse_broadcast(lua: *Lua) callconv(.c) c_int {
        const state: *LuaState = blk: {
            const ud = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse return 0;
            break :blk castUserdata(LuaState, @as(?*anyopaque, ud));
        };
        const registry = state.sse_registry orelse return 0;

        const room = lua.toString(1) catch return 0;
        const data = lua.toString(2) catch return 0;

        registry.broadcast(std.mem.span(room), std.mem.span(data));
        return 0;
    }

    /// Register embedded stdlib modules as package.preload entries.
    /// Each module source is compiled into the binary via @embedFile and loaded as
    /// a chunk (function) — require("keyway.X") returns it without touching disk.
    fn registerEmbeddedModules(lua: *Lua) void {
        // Get package.preload table
        _ = lua.getGlobal("package");
        _ = lua.getField(-1, "preload");

        inline for (embedded_modules) |mod| {
            // loadBuffer compiles the source into a Lua chunk (function).
            // These are embedded at build time so syntax errors are bugs, not user errors.
            lua.loadBuffer(mod[1], mod[0]) catch unreachable;
            lua.setField(-2, mod[0]); // package.preload[name] = chunk
        }

        lua.pop(2); // pop preload + package
    }

    /// Hot-reload: unref old routes, reset router, clear package.loaded, re-execute script.
    /// On script error: logs the error and leaves the router empty (all requests 404).
    /// Returns true on success, false on failure — callers use this to gate the
    /// script-generation counter (see prom.scriptReloadSucceeded), since a
    /// fire-and-forget reload otherwise leaves failures invisible (#117).
    pub fn reload(self: *LuaState, router: *Router, script_path: []const u8) bool {
        // 1. Collect old lua_refs from router and unref each
        var refs: std.ArrayListUnmanaged(i32) = .empty;
        defer refs.deinit(self.allocator);
        router.collectLuaRefs(self.allocator, &refs) catch {};
        for (refs.items) |ref| {
            self.lua.unref(Lua.PseudoIndex.Registry, ref);
        }

        // 2. Reset router (free trie + static routes)
        router.reset() catch |err| {
            log.err().string("msg", "reload: router reset failed").err(err).log();
            return false;
        };

        // 3. Clear package.loaded for non-stdlib modules
        self.lua.doString(
            \\local keep = {
            \\    ["keyway"] = true, ["keyway.response"] = true,
            \\    ["string"] = true, ["table"] = true, ["math"] = true, ["io"] = true,
            \\    ["os"] = true, ["debug"] = true, ["coroutine"] = true, ["package"] = true,
            \\    ["bit"] = true, ["ffi"] = true, ["jit"] = true, ["jit.opt"] = true,
            \\    ["jit.util"] = true, ["keyway.json"] = true,
            \\}
            \\for name in pairs(package.loaded) do
            \\    if not keep[name] and not name:match("^keyway%.") then
            \\        package.loaded[name] = nil
            \\    end
            \\end
        ) catch |err| {
            log.warn().string("msg", "reload: failed to clear package.loaded").err(err).log();
        };

        // 4. Re-execute the entry point script
        self.loadScript(script_path) catch |err| {
            log.err().string("msg", "reload: script load failed").string("path", script_path).err(err).log();
            return false;
        };

        // 5. Rebuild route table from fresh keyway.routes
        self.processRouteTable(router) catch |err| {
            log.err().string("msg", "reload: processRouteTable failed").err(err).log();
            return false;
        };
        self.processStaticTable(router) catch |err| {
            log.err().string("msg", "reload: processStaticTable failed").err(err).log();
            return false;
        };
        self.processProxyTable(router) catch |err| {
            log.err().string("msg", "reload: processProxyTable failed").err(err).log();
            return false;
        };

        log.info().string("msg", "reload complete").string("script", script_path).log();
        return true;
    }

    /// Clean up Lua state
    pub fn deinit(self: *LuaState) void {
        if (self.cached_thread_ref != 0) {
            self.lua.unref(Lua.PseudoIndex.Registry, self.cached_thread_ref);
        }
        self.lua.deinit();
    }
};

test "lua state initialization" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

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

test "coroutine dispatch - non-yielding handler" {
    const allocator = std.testing.allocator;
    const params_mod = @import("../http/params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Register a handler via declarative route table
    try state.loadString(
        \\keyway.routes = {
        \\    ["/test"] = {
        \\        GET = function(ctx)
        \\            ctx.status = 201
        \\            ctx.body = "coroutine works"
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    // Look up the route to get the lua_ref
    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = (try router.match("GET", "/test", &url_params)).?.lua_ref;
    // lua_ref is valid (unwrapped from RouteMatch)

    // Build a minimal HttpExchange
    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
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

    // Call via coroutine dispatch
    const result = try state.callLuaHandler(lua_ref, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);

    // Verify response was set correctly
    try std.testing.expectEqual(@as(u16, 201), exchange.status);
    try std.testing.expectEqualStrings("coroutine works", exchange.response_body);

    // Clean up the duped body
    allocator.free(exchange.response_body);
}

test "lua package library and require" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Test that package library is loaded
    try state.loadString("assert(package ~= nil)");
    try state.loadString("assert(package.path ~= nil)");
    try state.loadString("assert(package.cpath ~= nil)");

    // Test that require function exists
    try state.loadString("assert(type(require) == 'function')");
}

test "embedded stdlib modules are preloaded" {
    const allocator = std.testing.allocator;

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // All embedded modules should be available in package.preload
    try state.loadString("assert(type(package.preload['keyway.response']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.json']) == 'function')");
}

test "middleware execution order" {
    const allocator = std.testing.allocator;
    const params_mod = @import("../http/params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Route with two middleware layers: global (mw1) and path-level (mw2)
    // Uses a Lua global to track order since ctx only accepts status/body/headers
    try state.loadString(
        \\keyway.routes = {
        \\    middleware = {
        \\        function(ctx, next)
        \\            _order = "mw1_before"
        \\            next()
        \\            _order = _order .. ",mw1_after"
        \\            ctx.body = _order
        \\        end,
        \\    },
        \\    ["/test"] = {
        \\        middleware = {
        \\            function(ctx, next)
        \\                _order = _order .. ",mw2_before"
        \\                next()
        \\                _order = _order .. ",mw2_after"
        \\            end,
        \\        },
        \\        GET = function(ctx)
        \\            _order = _order .. ",handler"
        \\            ctx.status = 200
        \\            ctx.body = _order
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = (try router.match("GET", "/test", &url_params)).?.lua_ref;
    // lua_ref is valid (unwrapped from RouteMatch)

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
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

    const result = try state.callLuaHandler(lua_ref, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    try std.testing.expectEqual(@as(u16, 200), exchange.status);
    try std.testing.expectEqualStrings("mw1_before,mw2_before,handler,mw2_after,mw1_after", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "middleware short-circuit" {
    const allocator = std.testing.allocator;
    const params_mod = @import("../http/params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Middleware sets 401 and does NOT call next() — handler never runs
    try state.loadString(
        \\keyway.routes = {
        \\    ["/secret"] = {
        \\        middleware = {
        \\            function(ctx, next)
        \\                ctx.status = 401
        \\                ctx.body = "unauthorized"
        \\            end,
        \\        },
        \\        GET = function(ctx)
        \\            ctx.status = 200
        \\            ctx.body = "should not reach"
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = (try router.match("GET", "/secret", &url_params)).?.lua_ref;
    // lua_ref is valid (unwrapped from RouteMatch)

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/secret",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    try std.testing.expectEqual(@as(u16, 401), exchange.status);
    try std.testing.expectEqualStrings("unauthorized", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "security: request body with lua code is not executed" {
    const allocator = std.testing.allocator;
    const params_mod = @import("../http/params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Handler echoes body back — body content must never be evaluated as Lua
    try state.loadString(
        \\keyway.routes = {
        \\    ["/echo"] = {
        \\        POST = function(ctx)
        \\            ctx.status = 200
        \\            ctx.body = ctx.body
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = (try router.match("POST", "/echo", &url_params)).?.lua_ref;
    // lua_ref is valid (unwrapped from RouteMatch)

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "POST",
        .path = "/echo",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "os.execute('touch /tmp/pwned')",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    try std.testing.expectEqual(@as(u16, 200), exchange.status);
    // Body is the literal string, never evaluated as Lua code
    try std.testing.expectEqualStrings("os.execute('touch /tmp/pwned')", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "security: param with lua code is literal string" {
    const allocator = std.testing.allocator;
    const params_mod = @import("../http/params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Handler reads param and sets it as response body
    try state.loadString(
        \\keyway.routes = {
        \\    ["/h/{id}"] = {
        \\        GET = function(ctx)
        \\            ctx.status = 200
        \\            ctx.body = ctx.params.id
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = (try router.match("GET", "/h/os.execute('id')", &url_params)).?.lua_ref;
    // lua_ref is valid (unwrapped from RouteMatch)

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
    defer response_headers.deinit(allocator);

    var exchange = HttpExchange{
        .method = "GET",
        .path = "/h/os.execute('id')",
        .headers = &[_]http.Header{},
        .params = &url_params,
        .query = &query,
        .body = "",
        .status = 200,
        .response_headers = response_headers,
        .response_body = "",
        .allocator = allocator,
    };

    const result = try state.callLuaHandler(lua_ref, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    // Param value is literal string, never evaluated
    try std.testing.expectEqualStrings("os.execute('id')", exchange.response_body);

    allocator.free(exchange.response_body);
}

test "security: ctx.method and ctx.path are read-only" {
    const allocator = std.testing.allocator;
    const params_mod = @import("../http/params.zig");

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Handler tries to overwrite method and path, then reads them back
    try state.loadString(
        \\keyway.routes = {
        \\    ["/test"] = {
        \\        GET = function(ctx)
        \\            ctx.method = "EVIL"
        \\            ctx.path = "/evil"
        \\            ctx.status = 200
        \\            ctx.body = ctx.method .. " " .. ctx.path
        \\        end,
        \\    },
        \\}
    );
    try state.processRouteTable(&router);

    var url_params = params_mod.ParamArray{};
    var query = params_mod.QueryArray{};
    const lua_ref = (try router.match("GET", "/test", &url_params)).?.lua_ref;
    // lua_ref is valid (unwrapped from RouteMatch)

    var response_headers = try std.ArrayList(http.Header).initCapacity(allocator, 4);
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

    const result = try state.callLuaHandler(lua_ref, &exchange);
    try std.testing.expectEqual(HandlerResult.completed, result);
    // Writes to method/path are silently ignored — original values preserved
    try std.testing.expectEqualStrings("GET /test", exchange.response_body);

    allocator.free(exchange.response_body);
}
