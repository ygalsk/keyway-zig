//! Per-worker Lua state aggregation and initialization.
//!
//! Each worker thread owns one LuaState containing: the Lua VM, cached coroutine thread,
//! cosocket pending I/O staging, connection pool, TLS manager, and SSE registry pointer.
//!
//! Init order: Lua VM → std libs → keyway module → embedded stdlib → cached thread → package paths → TLS manager.
//! After init: registerCosocketApi → setWorkerGlobals → loadScript → processRouteTable.

const std = @import("std");
const Lua = @import("luajit").Lua;
const log = @import("../observability/log.zig");
const http = @import("../http/http.zig");
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const Router = @import("../http/router.zig").Router;
const lua_api = @import("lua_api.zig");
const IoEntry = @import("../io/ring.zig").IoEntry;
const io_request = @import("../io/io_request.zig");
const ring_api = @import("../io/ring_api.zig");
const ring = @import("../io/ring.zig");
const ConnectionPool = @import("../io/connection_pool.zig").ConnectionPool;
const Connection = @import("../core/handler.zig").Connection;
const tls = @import("../tls/tls.zig");
const castUserdata = @import("../util/helpers.zig").castUserdata;
const TlsManager = tls.TlsManager;
const SseRegistry = @import("../protocol/sse.zig").SseRegistry;
const prom = @import("../observability/prom.zig");

// zig-luajit marks resumeCoroutine as private — call C API directly.
// Lua is an opaque type that maps 1:1 to lua_State*, so @ptrCast is safe.
pub extern "c" fn lua_resume(L: *anyopaque, narg: c_int) c_int;

// Embedded stdlib modules — compiled into the binary at build time.
// Registered as package.preload["keyway.*"] so require() resolves without disk I/O.
// scripts/keyway/stdlib.zig uses @embedFile for sibling .lua files, imported via build.zig.
const stdlib = @import("stdlib");
const embedded_modules = .{
    .{ "keyway.socket", stdlib.socket },
    .{ "keyway.ring", stdlib.ring },
    .{ "keyway.dns", stdlib.dns },
    .{ "keyway.db_socket", stdlib.db_socket },
    .{ "keyway.form", stdlib.form },
    .{ "keyway.response", stdlib.response },
    .{ "keyway.crypto", stdlib.crypto },
    .{ "keyway.http", stdlib.http },
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

    // Cosocket: pending I/O intent written by C yield functions, read by Zig after LUA_YIELD.
    // Safe because: written by C yield functions during lua_resume, read by dispatchIo
    // in the same stack frame. libxev is single-threaded per worker — no concurrent access.
    pending_io: ?IoEntry = null,

    // Cosocket: temporary coroutine state (copied to Connection after yield)
    coroutine_ref: i32 = 0,
    coroutine_thread: ?*Lua = null,

    // Connection pool for cosocket keepalive (per-worker, outlives requests)
    pool: ConnectionPool,

    // Current connection being served (set during handler call/resume, cleared on completion)
    // Used by ring C bridge functions to access the Connection's SQ/CQ.
    current_connection: ?*anyopaque = null,

    // Lua script timing: start timestamp for duration histogram
    coroutine_start_us: ?i64 = null,
    // Route pattern for the current coroutine (for Prometheus labels)
    coroutine_route: []const u8 = "",

    // SSE: per-worker registry for broadcast (set by worker.zig)
    sse_registry: ?*SseRegistry = null,

    // Outbound TLS: per-worker context + fd→TLS mapping (persists across yields)
    tls_manager: TlsManager,

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

        const tls_manager = TlsManager.init(allocator) catch return error.TlsInitFailed;

        return LuaState{
            .lua = lua,
            .allocator = allocator,
            .cached_thread = cached_thread,
            .cached_thread_ref = cached_thread_ref,
            .pool = ConnectionPool.init(allocator),
            .tls_manager = tls_manager,
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
        try lua_api.processRouteTable(self.lua, router, self.allocator);
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

    /// Call a Lua function by name
    /// The function should be at the global scope
    pub fn callGlobalFunction(self: *LuaState, name: [:0]const u8) !void {
        _ = self.lua.getGlobal(name);
        if (!self.lua.isFunction(-1)) {
            self.lua.pop(1);
            return error.NotAFunction;
        }
        try self.lua.callProtected(0, 0, 0); // 0 args, 0 results
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
        self.coroutine_start_us = std.time.microTimestamp();
        // Capture route for duration labeling from Connection's http_state
        if (self.current_connection) |conn_ptr| {
            const conn: *Connection = @ptrCast(@alignCast(conn_ptr));
            self.coroutine_route = conn.http_state.route_pattern;
        } else {
            self.coroutine_route = "";
        }
        const status = lua_resume(@ptrCast(thread), 1);

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

    /// Resume a yielded handler coroutine after outbound I/O completes.
    /// Caller has already pushed result values onto the thread stack.
    /// Does NOT unref the coroutine — Connection.completeHandler handles that.
    /// The exchange pointer comes from Connection.exchange (set during yield).
    pub fn resumeHandler(
        self: *LuaState,
        thread: *anyopaque,
        nresults: c_int,
        _: *HttpExchange,
    ) !HandlerResult {
        const status = lua_resume(thread, nresults);

        switch (status) {
            0 => {
                // LUA_OK — handler completed
                prom.luaCoroutineFinished();
                self.recordCoroutineDuration();
                return .completed;
            },
            1 => {
                // LUA_YIELD — handler wants more I/O (pending_io already populated)
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
        _ = self.lua.getGlobal("keyway");          // push keyway table
        self.lua.pushInteger(@intCast(worker_id)); // push value
        self.lua.setField(-2, "worker_id");        // keyway.worker_id = N
        self.lua.pop(1);                           // pop keyway table
    }

    /// Record coroutine execution duration for Prometheus metrics.
    fn recordCoroutineDuration(self: *LuaState) void {
        if (self.coroutine_start_us) |start| {
            const elapsed = std.time.microTimestamp() - start;
            prom.luaScriptDuration(self.coroutine_route, elapsed);
            self.coroutine_start_us = null;
        }
    }

    /// Extract the LuaState pointer from upvalue(1) closure.
    fn getLuaState(lua: *Lua) ?*LuaState {
        const ud = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse return null;
        return castUserdata(LuaState, @as(?*anyopaque, ud));
    }

    /// Push nil + error message and return 2 (Lua convention for value, err).
    fn luaError(lua: *Lua, msg: [:0]const u8) c_int {
        lua.pushNil();
        lua.pushString(msg);
        return 2;
    }

    /// Register file I/O C functions as Lua globals.
    /// Admin-only operations — used by dashboard routes behind localhost_guard.
    pub fn registerFileApi(self: *LuaState) void {
        const file_funcs = .{
            .{ "__keyway_file_read", keyway_file_read },
            .{ "__keyway_file_write", keyway_file_write },
            .{ "__keyway_file_delete", keyway_file_delete },
            .{ "__keyway_file_list", keyway_file_list },
            .{ "__keyway_file_rename", keyway_file_rename },
        };
        inline for (file_funcs) |entry| {
            self.lua.pushLightUserdata(self);
            self.lua.pushCClosure(entry[1], 1);
            self.lua.setGlobal(entry[0]);
        }
    }

    /// __keyway_file_read(path) -> string or nil, error
    fn keyway_file_read(lua: *Lua) callconv(.c) c_int {
        const state = getLuaState(lua) orelse return 0;
        const path_c = lua.toString(1) catch return luaError(lua, "path argument required");
        const path = std.mem.span(path_c);

        const file = std.fs.cwd().openFile(path, .{}) catch return luaError(lua, "file not found");
        defer file.close();

        const content = file.readToEndAlloc(state.allocator, 10 * 1024 * 1024) catch return luaError(lua, "read error");
        defer state.allocator.free(content);

        lua.pushLString(content);
        return 1;
    }

    /// __keyway_file_write(path, content) -> true or nil, error
    fn keyway_file_write(lua: *Lua) callconv(.c) c_int {
        const path_c = lua.toString(1) catch return luaError(lua, "path argument required");
        const content_c = lua.toString(2) catch return luaError(lua, "content argument required");
        const path = std.mem.span(path_c);
        const content = std.mem.span(content_c);

        // Atomic write: write to tmp file, then rename
        const state = getLuaState(lua) orelse return 0;
        const dir_path = std.fs.path.dirname(path) orelse ".";

        // Ensure parent directory exists
        std.fs.cwd().makePath(dir_path) catch {};

        // Write tmp file and rename
        const tmp_path = std.fmt.allocPrint(state.allocator, "{s}.tmp", .{path}) catch return luaError(lua, "allocation failed");
        defer state.allocator.free(tmp_path);

        const file = std.fs.cwd().createFile(tmp_path, .{}) catch return luaError(lua, "failed to create tmp file");
        file.writeAll(content) catch {
            file.close();
            return luaError(lua, "write error");
        };
        file.close();

        // Rename tmp -> target (atomic on same filesystem)
        std.fs.cwd().rename(tmp_path, path) catch return luaError(lua, "rename failed");

        lua.pushBoolean(true);
        return 1;
    }

    /// __keyway_file_delete(path) -> true or nil, error
    fn keyway_file_delete(lua: *Lua) callconv(.c) c_int {
        const path_c = lua.toString(1) catch return luaError(lua, "path argument required");
        const path = std.mem.span(path_c);

        std.fs.cwd().deleteFile(path) catch return luaError(lua, "delete failed");

        lua.pushBoolean(true);
        return 1;
    }

    /// __keyway_file_rename(old_path, new_path) -> true or nil, error
    fn keyway_file_rename(lua: *Lua) callconv(.c) c_int {
        const old_c = lua.toString(1) catch return luaError(lua, "old_path argument required");
        const new_c = lua.toString(2) catch return luaError(lua, "new_path argument required");
        const old_path = std.mem.span(old_c);
        const new_path = std.mem.span(new_c);

        std.fs.cwd().rename(old_path, new_path) catch return luaError(lua, "rename failed");

        lua.pushBoolean(true);
        return 1;
    }

    /// __keyway_file_list(dir) -> table of {path, name} or nil, error
    fn keyway_file_list(lua: *Lua) callconv(.c) c_int {
        const state = getLuaState(lua) orelse return 0;
        const dir_c = lua.toString(1) catch return luaError(lua, "dir argument required");
        const dir_path = std.mem.span(dir_c);

        lua.createTable(0, 0);
        var idx: i32 = 1;

        listLuaFilesRecursive(lua, state.allocator, dir_path, dir_path, &idx);

        return 1;
    }

    fn listLuaFilesRecursive(lua: *Lua, alloc: std.mem.Allocator, base: []const u8, dir_path: []const u8, idx: *i32) void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                const sub = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch continue;
                defer alloc.free(sub);
                listLuaFilesRecursive(lua, alloc, base, sub, idx);
            } else if (entry.kind == .file and (std.mem.endsWith(u8, entry.name, ".lua") or std.mem.endsWith(u8, entry.name, ".lua.disabled"))) {
                const full = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch continue;
                defer alloc.free(full);

                // Compute relative path from base
                const rel = if (std.mem.startsWith(u8, full, base))
                    if (full.len > base.len and full[base.len] == '/') full[base.len + 1 ..] else full[base.len..]
                else
                    full;

                const enabled = std.mem.endsWith(u8, entry.name, ".lua");

                lua.createTable(0, 3);
                lua.pushLString(rel);
                lua.setField(-2, "path");
                lua.pushLString(entry.name);
                lua.setField(-2, "name");
                lua.pushBoolean(enabled);
                lua.setField(-2, "enabled");
                lua.setTableIndexRaw(-2, idx.*);
                idx.* += 1;
            }
        }
    }

    /// Register cosocket C functions as Lua globals with *LuaState as upvalue.
    /// Must be called after init (needs stable *LuaState pointer).
    pub fn registerCosocketApi(self: *LuaState) void {
        const funcs = .{
            .{ "__keyway_io_connect", io_request.keyway_io_connect },
            .{ "__keyway_io_send", io_request.keyway_io_send },
            .{ "__keyway_io_recv", io_request.keyway_io_recv },
            .{ "__keyway_io_close", io_request.keyway_io_close },
            .{ "__keyway_pool_connect", io_request.keyway_pool_connect },
            .{ "__keyway_pool_setkeepalive", io_request.keyway_pool_setkeepalive },
            .{ "__keyway_io_udp_connect", io_request.keyway_io_udp_connect },
            .{ "__keyway_io_sslhandshake", io_request.keyway_io_sslhandshake },
            .{ "__keyway_ws_send", io_request.keyway_ws_send },
            // Ring API: batched I/O
            .{ "__keyway_ring_push", ring_api.keyway_ring_push },
            .{ "__keyway_ring_submit", ring_api.keyway_ring_submit },
            .{ "__keyway_ring_result", ring_api.keyway_ring_result },
            .{ "__keyway_sse_broadcast", keyway_sse_broadcast },
        };

        inline for (funcs) |entry| {
            self.lua.pushLightUserdata(self);
            self.lua.pushCClosure(entry[1], 1);
            self.lua.setGlobal(entry[0]);
        }
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

    // --- Ring API delegation methods ---
    // These let ring_api.zig access the current Connection's SQ/CQ
    // without importing handler.zig, sealing the proactor boundary.

    /// Push an IoEntry onto the current Connection's submission ring.
    /// Returns error.NoActiveRequest if no connection is active.
    pub fn pushSqEntry(self: *LuaState, entry: ring.IoEntry) error{ RingFull, NoActiveRequest }!void {
        const conn = self.currentConnection() orelse return error.NoActiveRequest;
        try conn.cs.sq.push(entry);
    }

    /// Read a completion entry by index from the current Connection's CQ.
    /// Returns null if no connection is active or index is out of range.
    pub fn getCqEntry(self: *LuaState, index: u8) ?ring.CQEntry {
        const conn = self.currentConnection() orelse return null;
        if (index >= conn.cs.cq.tail) return null;
        return conn.cs.cq.get(index);
    }

    /// Return the number of pending SQ entries, or null if no connection is active.
    pub fn sqLen(self: *LuaState) ?u8 {
        const conn = self.currentConnection() orelse return null;
        return conn.cs.sq.len();
    }

    /// Return the CQ tail (number of completions), or null if no connection is active.
    pub fn cqTail(self: *LuaState) ?u8 {
        const conn = self.currentConnection() orelse return null;
        return conn.cs.cq.tail;
    }

    /// Cast current_connection to *Connection. Internal helper.
    inline fn currentConnection(self: *LuaState) ?*Connection {
        const ptr = self.current_connection orelse return null;
        return @ptrCast(@alignCast(ptr));
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
    pub fn reload(self: *LuaState, router: *Router, script_path: []const u8) void {
        // 1. Collect old lua_refs from router and unref each
        var refs: std.ArrayListUnmanaged(i32) = .{};
        defer refs.deinit(self.allocator);
        router.collectLuaRefs(self.allocator, &refs) catch {};
        for (refs.items) |ref| {
            self.lua.unref(Lua.PseudoIndex.Registry, ref);
        }

        // 2. Reset router (free trie + static routes)
        router.reset() catch |err| {
            log.err().string("msg", "reload: router reset failed").err(err).log();
            return;
        };

        // 3. Clear package.loaded for non-stdlib modules
        self.lua.doString(
            \\local keep = {
            \\    ["keyway"] = true, ["keyway.socket"] = true, ["keyway.ring"] = true,
            \\    ["keyway.dns"] = true, ["keyway.db_socket"] = true, ["keyway.form"] = true,
            \\    ["keyway.response"] = true, ["keyway.crypto"] = true, ["keyway.http"] = true,
            \\    ["string"] = true, ["table"] = true, ["math"] = true, ["io"] = true,
            \\    ["os"] = true, ["debug"] = true, ["coroutine"] = true, ["package"] = true,
            \\    ["bit"] = true, ["ffi"] = true, ["jit"] = true, ["jit.opt"] = true,
            \\    ["jit.util"] = true, ["cjson"] = true,
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
            return;
        };

        // 5. Rebuild route table from fresh keyway.routes
        self.processRouteTable(router) catch |err| {
            log.err().string("msg", "reload: processRouteTable failed").err(err).log();
            return;
        };
        self.processStaticTable(router) catch |err| {
            log.err().string("msg", "reload: processStaticTable failed").err(err).log();
            return;
        };
        self.processProxyTable(router) catch |err| {
            log.err().string("msg", "reload: processProxyTable failed").err(err).log();
            return;
        };

        log.info().string("msg", "reload complete").string("script", script_path).log();
    }

    /// Clean up Lua state
    pub fn deinit(self: *LuaState) void {
        self.tls_manager.deinit();
        self.pool.deinit();
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

test "lua function call" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    var state = try LuaState.init(allocator);
    defer state.deinit();

    // Define a simple function
    try state.loadString(
        \\function greet()
        \\  message = "Hello from Lua"
        \\end
    );

    // Call the function
    try state.callGlobalFunction("greet");

    // Verify it ran
    _ = state.lua.getGlobal("message");
    const msg = state.lua.toString(-1) catch unreachable;
    try std.testing.expectEqualStrings("Hello from Lua", std.mem.span(msg));
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
    try state.loadString("assert(type(package.preload['keyway.socket']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.ring']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.dns']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.db_socket']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.form']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.response']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.crypto']) == 'function')");
    try state.loadString("assert(type(package.preload['keyway.http']) == 'function')");
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
