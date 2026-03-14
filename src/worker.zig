const std = @import("std");
const xev = @import("xev");
const log = @import("log.zig");
const Server = @import("server.zig").Server;
const Router = @import("router.zig").Router;
const LuaState = @import("lua_state.zig").LuaState;
const lua_api = @import("lua_api.zig");
const sse = @import("sse.zig");
const SseRegistry = sse.SseRegistry;
const SseBroadcastBus = sse.SseBroadcastBus;
const ShutdownCoordinator = @import("shutdown.zig").ShutdownCoordinator;
const metrics_mod = @import("metrics.zig");
const WorkerMetrics = metrics_mod.WorkerMetrics;
const config = @import("config.zig");

/// Pin calling thread to specified CPU core (Linux-only)
/// This is architecturally required for proactor systems to ensure:
/// - Cache locality (L1/L2 stays hot)
/// - NUMA-local memory allocation
/// - eBPF routing alignment (connection routed to core N reaches worker on core N)
/// - Zero thread migrations (validates via perf stat -e migrations)
inline fn pinThreadToCore(core_id: usize) !void {
    // Initialize cpu_set_t (array of usize) to zero
    var cpuset: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);

    // Set the bit for the target core
    // cpu_set_t is [CPU_SETSIZE / @sizeOf(usize)]usize
    const bits_per_elem = @bitSizeOf(usize);
    const elem_index = core_id / bits_per_elem;
    const bit_index = core_id % bits_per_elem;
    cpuset[elem_index] = @as(usize, 1) << @intCast(bit_index);

    // Set affinity for current thread (pid 0)
    try std.os.linux.sched_setaffinity(0, &cpuset);
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
        metrics: *WorkerMetrics,
    };

    /// Spawn a worker thread
    pub fn spawn(
        allocator: std.mem.Allocator,
        server_config: Server.Config,
        worker_id: usize,
        num_workers: usize,
        bpf_ready: *std.atomic.Value(bool),
        sse_bus: ?*SseBroadcastBus,
        coordinator: ?*ShutdownCoordinator,
        worker_metrics: *WorkerMetrics,
    ) !Worker {
        const ctx = try allocator.create(Context);
        ctx.* = Context{
            .allocator = allocator,
            .config = server_config,
            .worker_id = worker_id,
            .num_workers = num_workers,
            .bpf_ready = bpf_ready,
            .sse_bus = sse_bus,
            .coordinator = coordinator,
            .metrics = worker_metrics,
        };

        const thread = try std.Thread.spawn(.{}, workerMain, .{ctx});

        return Worker{
            .allocator = allocator,
            .thread = thread,
            .config = server_config,
            .router = undefined, // Each worker creates its own router
            .worker_id = worker_id,
        };
    }

    /// Wait for worker thread to finish
    pub fn join(self: *Worker) void {
        self.thread.join();
    }

    /// Worker thread entry point
    fn workerMain(ctx: *Context) !void {
        // CRITICAL: Pin thread to core BEFORE any allocations
        // This ensures NUMA-local memory and cache locality
        try pinThreadToCore(ctx.worker_id);
        log.worker_id = @intCast(ctx.worker_id);

        defer ctx.allocator.destroy(ctx);

        std.log.debug("Worker {d} pinned to core {d}", .{ ctx.worker_id, ctx.worker_id });
        std.log.info("Worker {d} starting...", .{ctx.worker_id});

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

        // Expose per-worker globals to Lua (must be before loadScript)
        lua_state.setWorkerGlobals(ctx.worker_id);

        // Load Lua handlers and process declarative route table
        try lua_state.loadScript("scripts/handlers.lua");
        try lua_state.processRouteTable(&router);

        if (router.isEmpty()) {
            std.log.warn("Worker {d}: no routes registered — all requests will 404", .{ctx.worker_id});
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
            };
            async_watcher.wait(&loop, &shutdown_completion, ShutdownContext, shutdown_ctx, onShutdownSignal);
        }

        std.log.info("Worker {d} ready on port {d}", .{ ctx.worker_id, ctx.config.port });

        // Start accepting connections
        try server.start();

        // Run event loop
        try loop.run(.until_done);
    }
};

/// Context for shutdown signal callback.
const ShutdownContext = struct {
    server: *Server,
    coordinator: *ShutdownCoordinator,
    drain_timer_completion: *xev.Completion,
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

    if (ctx.coordinator.isForceShutdown()) {
        std.log.info("Force shutdown — closing all connections immediately", .{});
        ctx.server.forceCloseAll();
        return .disarm;
    }

    std.log.info("Shutting down...", .{});
    ctx.server.stopAccepting();
    ctx.server.closeIdleConnections();

    const active = ctx.server.active_connections.load(.monotonic);
    std.log.info("Draining {d} active connections (deadline {d}ms)", .{ active, config.DRAIN_DEADLINE_MS });

    if (active == 0) {
        std.log.info("Shutdown complete — no active connections", .{});
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
        const remaining = server.active_connections.load(.monotonic);
        if (remaining > 0) {
            std.log.info("Drain deadline expired — force-closing {d} connections", .{remaining});
            server.forceCloseAll();
        }
    }
    std.log.info("Shutdown complete", .{});
    return .disarm;
}

/// Thread pool manager
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    bpf_ready: *std.atomic.Value(bool),
    sse_bus: ?*SseBroadcastBus,
    coordinator: ?*ShutdownCoordinator = null,
    worker_metrics: []WorkerMetrics,

    /// Create thread pool with the given number of workers.
    /// Pass worker_count=0 to auto-detect (one worker per CPU core).
    pub fn init(
        allocator: std.mem.Allocator,
        server_config: Server.Config,
        worker_count: u16,
        coordinator: ?*ShutdownCoordinator,
    ) !ThreadPool {
        const num_cpus = try std.Thread.getCpuCount();
        const num_workers: usize = if (worker_count > 0) @intCast(worker_count) else num_cpus;
        std.log.info("Detected {d} CPU cores, spawning {d} workers", .{ num_cpus, num_workers });

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

        // Create SSE broadcast bus (shared across all workers)
        const sse_bus = SseBroadcastBus.init(allocator, num_workers) catch null;

        // Spawn workers
        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.spawn(allocator, server_config, i, num_workers, bpf_ready, sse_bus, coordinator, &worker_metrics[i]);
        }

        return ThreadPool{
            .allocator = allocator,
            .workers = workers,
            .bpf_ready = bpf_ready,
            .sse_bus = sse_bus,
            .coordinator = coordinator,
            .worker_metrics = worker_metrics,
        };
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
        self.allocator.free(self.worker_metrics);
        self.allocator.free(self.workers);
    }
};
