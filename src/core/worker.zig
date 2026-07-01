const std = @import("std");
const xev = @import("xev");
const log = @import("../observability/log.zig");
const Server = @import("server.zig").Server;
const Router = @import("../http/router.zig").Router;
const LuaState = @import("../lua/lua_state.zig").LuaState;
const lua_api = @import("../lua/lua_api.zig");
const sse = @import("../protocol/sse.zig");
const SseRegistry = sse.SseRegistry;
const SseBroadcastBus = sse.SseBroadcastBus;
const ShutdownCoordinator = @import("shutdown.zig").ShutdownCoordinator;
const ReloadCoordinator = @import("reload.zig").ReloadCoordinator;
const FileWatcher = @import("../io/file_watcher.zig").FileWatcher;
const metrics_mod = @import("../observability/metrics.zig");
const WorkerMetrics = metrics_mod.WorkerMetrics;
const config = @import("../util/config.zig");
const prom = @import("../observability/prom.zig");

/// Pin calling thread to specified CPU core (Linux-only).
/// Returns true if pinning succeeded, false if it failed (e.g. inside a
/// container whose cgroup doesn't include the target core).
///
/// When pinning works, the proactor chain is fully aligned:
/// - Cache locality (L1/L2 stays hot)
/// - NUMA-local memory allocation
/// - eBPF routing alignment (connection routed to core N reaches worker on core N)
/// - Zero thread migrations (validates via perf stat -e migrations)
///
/// When it fails, the worker runs unpinned — correctness is preserved,
/// only the performance edge (cache/NUMA affinity) is lost.
inline fn pinThreadToCore(core_id: usize) bool {
    var cpuset: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);

    const bits_per_elem = @bitSizeOf(usize);
    const elem_index = core_id / bits_per_elem;
    const bit_index = core_id % bits_per_elem;
    cpuset[elem_index] = @as(usize, 1) << @intCast(bit_index);

    std.os.linux.sched_setaffinity(0, &cpuset) catch |err| {
        log.warn().string("msg", "CPU pinning failed, running without affinity")
            .int("core", core_id)
            .string("err", @errorName(err)).log();
        return false;
    };
    return true;
}

/// Worker thread - owns its own event loop and Lua state
/// Each worker accepts connections independently using SO_REUSEPORT
pub const Worker = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    config: Server.Config,
    router: *Router,
    worker_id: usize,

    /// Worker context passed to thread
    const Context = struct {
        allocator: std.mem.Allocator,
        config: Server.Config,
        worker_id: usize,
        num_workers: usize,
        bpf_ready: *std.atomic.Value(bool),
        sse_bus: ?*SseBroadcastBus,
        coordinator: ?*ShutdownCoordinator,
        reload_coordinator: ?*ReloadCoordinator,
        metrics: *WorkerMetrics,
        ready_count: *std.atomic.Value(usize),
        script_path: []const u8,
        watch: bool,
    };

    /// Spawn a worker thread
    pub fn spawn(allocator: std.mem.Allocator, context: Context) !Worker {
        const ctx = try allocator.create(Context);
        ctx.* = context;

        const thread = try std.Thread.spawn(.{}, workerMain, .{ctx});

        return Worker{
            .allocator = allocator,
            .thread = thread,
            .config = context.config,
            .router = undefined, // Each worker creates its own router
            .worker_id = context.worker_id,
        };
    }

    /// Wait for worker thread to finish
    pub fn join(self: *Worker) void {
        self.thread.join();
    }

    /// Worker thread entry point
    fn workerMain(ctx: *Context) !void {
        // Pin thread to core BEFORE any allocations for NUMA-local memory.
        // Non-fatal: in containers without cpuset access, workers run unpinned.
        const pinned = pinThreadToCore(ctx.worker_id);
        log.worker_id = @intCast(ctx.worker_id);
        prom.worker_id = @intCast(ctx.worker_id);

        defer ctx.allocator.destroy(ctx);

        if (pinned) {
            log.debug().string("msg", "worker pinned to core").int("core", ctx.worker_id).log();
        }
        log.info().string("msg", "worker starting").log();

        // === Worker Initialization Sequence ===
        // 1. Pin thread to CPU core (NUMA locality, cache affinity)
        // 2. Create xev event loop (per-core, no sharing)
        // 3. Create Router (per-worker, lua_ref values are Lua-state-specific)
        // 4. Create SseRegistry (per-worker subscriber tracking)
        // 5. Wire SSE broadcast bus (cross-worker pub/sub, if enabled)
        // 6. Create LuaState (Lua VM + std libs + metatables + cached thread)
        // 7. Set SSE registry on LuaState (for broadcast C function)
        // 8. Register cosocket API (C closures with *LuaState upvalue)
        // 9. Set worker globals (keyway.worker_id)
        // 10. Load Lua script + process route table
        // 11. Create Server (socket, bind, listen, TLS context)
        // 12. Start accept loop → run event loop
        //
        // Invariants:
        // - CPU pinning MUST happen before any allocations (NUMA locality)
        // - registerCosocketApi needs stable *LuaState pointer (after init)
        // - setWorkerGlobals must precede loadScript (scripts may read worker_id)
        // - processRouteTable must follow loadScript (reads keyway.routes)

        // Each worker has its own event loop
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();

        // Each worker creates its own router (lua_ref values are Lua-state-specific)
        var router = try Router.init(ctx.allocator);
        defer router.deinit();

        // Each worker has its own SSE registry (per-worker, no sharing)
        var sse_registry = SseRegistry.init(ctx.allocator);
        defer sse_registry.deinit();

        // Wire SSE bus for cross-worker broadcast
        if (ctx.sse_bus) |bus| {
            sse_registry.bus = bus;
            sse_registry.worker_id = ctx.worker_id;
            bus.registerWorker(ctx.worker_id, &sse_registry, &loop);
        }

        // Each worker has its own Lua state (one per thread!)
        var lua_state = try LuaState.init(ctx.allocator);
        defer lua_state.deinit();

        // Set SSE registry on LuaState (for broadcast C function)
        lua_state.sse_registry = &sse_registry;

        // Register cosocket API (needs stable *LuaState pointer)
        lua_state.registerCosocketApi();

        // Register file I/O API (admin operations, behind localhost_guard)
        lua_state.registerFileApi();

        // Expose per-worker globals to Lua (must be before loadScript)
        lua_state.setWorkerGlobals(ctx.worker_id);

        // Load Lua handlers and process declarative route table
        try lua_state.loadScript(ctx.script_path);
        try lua_state.processRouteTable(&router);
        try lua_state.processStaticTable(&router);
        try lua_state.processProxyTable(&router);

        if (router.isEmpty()) {
            log.warn().string("msg", "no routes registered — all requests will 404").log();
        }

        // Create server (shares socket via SO_REUSEPORT)
        var server = try Server.init(
            ctx.allocator,
            &loop,
            ctx.config,
            &router,
            &lua_state,
            @intCast(ctx.num_workers),
            @intCast(ctx.worker_id),
            ctx.bpf_ready,
            &sse_registry,
            ctx.metrics,
        );
        defer server.deinit();

        // Register shutdown Async watcher (fires when coordinator signals drain)
        var shutdown_completion: xev.Completion = undefined;
        var drain_timer_completion: xev.Completion = .{};
        if (ctx.coordinator) |coord| {
            const async_watcher = coord.getAsync(ctx.worker_id);
            const shutdown_ctx = try ctx.allocator.create(ShutdownContext);
            shutdown_ctx.* = .{
                .server = &server,
                .coordinator = coord,
                .drain_timer_completion = &drain_timer_completion,
                .allocator = ctx.allocator,
            };
            async_watcher.wait(&loop, &shutdown_completion, ShutdownContext, shutdown_ctx, onShutdownSignal);
            server.coordinator = coord;
            server.worker_id = ctx.worker_id;
            server.drain_timer_completion = &drain_timer_completion;
        }
        server.reload_coordinator = ctx.reload_coordinator;

        // Register reload Async watcher (fires when ReloadCoordinator signals reload)
        var reload_completion: xev.Completion = undefined;
        if (ctx.reload_coordinator) |reload_coord| {
            const reload_async = reload_coord.getAsync(ctx.worker_id);
            const reload_ctx = try ctx.allocator.create(ReloadContext);
            reload_ctx.* = .{
                .lua_state = &lua_state,
                .router = &router,
                .script_path = ctx.script_path,
                .server = &server,
                .allocator = ctx.allocator,
            };
            reload_async.wait(&loop, &reload_completion, ReloadContext, reload_ctx, onReloadSignal);
        }

        // Start file watcher if --watch enabled
        var file_watcher: ?FileWatcher = null;
        if (ctx.watch) {
            file_watcher = FileWatcher.init(ctx.allocator, ctx.script_path, &lua_state, &router) catch |err| blk: {
                log.warn().string("msg", "file watcher init failed — continuing without watch").err(err).log();
                break :blk null;
            };
            if (file_watcher) |*fw| {
                fw.start(&loop);
                server.file_watcher = fw;
                log.info().string("msg", "file watcher started").string("script", ctx.script_path).log();
            }
        }
        defer if (file_watcher) |*fw| fw.deinit();

        // Start accepting connections
        try server.start();

        log.info().string("msg", "worker ready").int("port", ctx.config.port).log();

        // Signal readiness to main thread
        _ = ctx.ready_count.fetchAdd(1, .release);

        // Run event loop
        try loop.run(.until_done);
    }
};

/// Context for shutdown signal callback.
const ShutdownContext = struct {
    server: *Server,
    coordinator: *ShutdownCoordinator,
    drain_timer_completion: *xev.Completion,
    allocator: std.mem.Allocator,
};

/// xev.Async callback — fires on the worker's event loop when shutdown signal received.
fn onShutdownSignal(
    ctx_opt: ?*ShutdownContext,
    loop: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    const ctx = ctx_opt orelse return .disarm;

    // Already shut down (woken by forceCloseAll to self-disarm)
    if (ctx.server.socket == -1) {
        ctx.allocator.destroy(ctx);
        return .disarm;
    }

    if (ctx.coordinator.isForceShutdown()) {
        log.info().string("msg", "force shutdown — closing all connections immediately").log();
        ctx.server.forceCloseAll();
        ctx.allocator.destroy(ctx);
        return .disarm;
    }

    // stopAccepting sets draining; a second wake (last connection closed during
    // drain) re-enters here to finish early — don't re-log the banner.
    if (!ctx.server.draining) log.info().string("msg", "shutting down").log();
    ctx.server.stopAccepting();

    const active = ctx.server.metrics.active_connections.load(.monotonic);
    log.info().string("msg", "draining active connections").int("active", active).int("deadline_ms", config.DRAIN_DEADLINE_MS).log();

    if (active == 0) {
        log.info().string("msg", "shutdown complete — no active connections").log();
        ctx.server.forceCloseAll();
        ctx.allocator.destroy(ctx);
        return .disarm;
    }

    // Start drain deadline timer
    loop.timer(ctx.drain_timer_completion, config.DRAIN_DEADLINE_MS, ctx.server, onDrainDeadline);

    // Re-arm to catch second signal (force shutdown)
    return .rearm;
}

/// Drain deadline expired — force-close all remaining connections.
fn onDrainDeadline(
    userdata: ?*anyopaque,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Result,
) xev.CallbackAction {
    if (userdata) |ud| {
        const server: *Server = @ptrCast(@alignCast(ud));
        const remaining = server.metrics.active_connections.load(.monotonic);
        if (remaining > 0) {
            log.info().string("msg", "drain deadline expired — force-closing connections").int("remaining", remaining).log();
        }
        // Always call forceCloseAll — closes listen socket + any remaining connections.
        // Idempotent: safe if force shutdown already ran.
        server.forceCloseAll();
    }
    log.info().string("msg", "shutdown complete").log();
    return .disarm;
}

/// Context for reload signal callback.
const ReloadContext = struct {
    lua_state: *LuaState,
    router: *Router,
    script_path: []const u8,
    server: *Server,
    allocator: std.mem.Allocator,
};

/// xev.Async callback — fires on the worker's event loop when reload signal received.
fn onReloadSignal(
    ctx_opt: ?*ReloadContext,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    const ctx = ctx_opt orelse return .disarm;

    // Shutdown woke us to self-disarm (forceCloseAll set socket = -1). Without
    // this the always-rearming wait keeps loop.active > 0 and the worker never
    // exits — see issue #90.
    if (ctx.server.socket == -1) {
        ctx.allocator.destroy(ctx);
        return .disarm;
    }

    log.info().string("msg", "performing hot reload").log();
    ctx.lua_state.reload(ctx.router, ctx.script_path);

    return .rearm;
}

/// Thread pool manager
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    bpf_ready: *std.atomic.Value(bool),
    sse_bus: ?*SseBroadcastBus,
    coordinator: ?*ShutdownCoordinator = null,
    reload_coordinator: ?*ReloadCoordinator = null,
    worker_metrics: []WorkerMetrics,
    ready_count: *std.atomic.Value(usize),

    /// Create thread pool with the given number of workers.
    /// Pass worker_count=0 to auto-detect (one worker per CPU core).
    pub fn init(
        allocator: std.mem.Allocator,
        server_config: Server.Config,
        worker_count: u16,
        coordinator: ?*ShutdownCoordinator,
        reload_coordinator: ?*ReloadCoordinator,
        script_path: []const u8,
        watch: bool,
    ) !ThreadPool {
        const num_cpus = try std.Thread.getCpuCount();
        const num_workers: usize = if (worker_count > 0) @intCast(worker_count) else num_cpus;
        log.info().string("msg", "spawning workers").int("cpu_cores", num_cpus).int("workers", num_workers).log();

        const workers = try allocator.alloc(Worker, num_workers);
        errdefer allocator.free(workers);

        // Create per-worker metrics (allocated here so pointers remain stable)
        const worker_metrics = try allocator.alloc(WorkerMetrics, num_workers);
        errdefer allocator.free(worker_metrics);
        for (worker_metrics) |*m| {
            m.* = WorkerMetrics.init();
        }

        // Create BPF synchronization flag
        const bpf_ready = try allocator.create(std.atomic.Value(bool));
        bpf_ready.* = std.atomic.Value(bool).init(false);
        errdefer allocator.destroy(bpf_ready);

        // Create worker readiness counter (workers increment after bind+listen)
        const ready_count = try allocator.create(std.atomic.Value(usize));
        ready_count.* = std.atomic.Value(usize).init(0);
        errdefer allocator.destroy(ready_count);

        // Create SSE broadcast bus (shared across all workers)
        const sse_bus = SseBroadcastBus.init(allocator, num_workers) catch null;

        // Spawn workers
        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.spawn(allocator, .{
                .allocator = allocator,
                .config = server_config,
                .worker_id = i,
                .num_workers = num_workers,
                .bpf_ready = bpf_ready,
                .sse_bus = sse_bus,
                .coordinator = coordinator,
                .reload_coordinator = reload_coordinator,
                .metrics = &worker_metrics[i],
                .ready_count = ready_count,
                .script_path = script_path,
                .watch = watch,
            });
        }

        return ThreadPool{
            .allocator = allocator,
            .workers = workers,
            .bpf_ready = bpf_ready,
            .sse_bus = sse_bus,
            .coordinator = coordinator,
            .reload_coordinator = reload_coordinator,
            .worker_metrics = worker_metrics,
            .ready_count = ready_count,
        };
    }

    /// Block until all workers have bound their sockets and are accepting connections.
    pub fn waitUntilReady(self: *ThreadPool) void {
        while (self.ready_count.load(.acquire) < self.workers.len) {
            std.atomic.spinLoopHint();
        }
    }

    /// Wait for all workers to finish
    pub fn joinAll(self: *ThreadPool) void {
        for (self.workers) |*worker| {
            worker.join();
        }
    }

    /// Cleanup thread pool
    pub fn deinit(self: *ThreadPool) void {
        if (self.sse_bus) |bus| bus.deinit();
        self.allocator.destroy(self.bpf_ready);
        self.allocator.destroy(self.ready_count);
        self.allocator.free(self.worker_metrics);
        self.allocator.free(self.workers);
    }
};
