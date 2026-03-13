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
    };

    /// Spawn a worker thread
    pub fn spawn(
        allocator: std.mem.Allocator,
        config: Server.Config,
        worker_id: usize,
        num_workers: usize,
        bpf_ready: *std.atomic.Value(bool),
        sse_bus: ?*SseBroadcastBus,
    ) !Worker {
        const ctx = try allocator.create(Context);
        ctx.* = Context{
            .allocator = allocator,
            .config = config,
            .worker_id = worker_id,
            .num_workers = num_workers,
            .bpf_ready = bpf_ready,
            .sse_bus = sse_bus,
        };

        const thread = try std.Thread.spawn(.{}, workerMain, .{ctx});

        return Worker{
            .allocator = allocator,
            .thread = thread,
            .config = config,
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
        );
        defer server.deinit();

        std.log.info("Worker {d} ready on port {d}", .{ ctx.worker_id, ctx.config.port });

        // Start accepting connections
        try server.start();

        // Run event loop
        try loop.run(.until_done);
    }
};

/// Thread pool manager
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    bpf_ready: *std.atomic.Value(bool),
    sse_bus: ?*SseBroadcastBus,

    /// Create thread pool with the given number of workers.
    /// Pass worker_count=0 to auto-detect (one worker per CPU core).
    pub fn init(
        allocator: std.mem.Allocator,
        config: Server.Config,
        worker_count: u16,
    ) !ThreadPool {
        const num_cpus = try std.Thread.getCpuCount();
        const num_workers: usize = if (worker_count > 0) @intCast(worker_count) else num_cpus;
        std.log.info("Detected {d} CPU cores, spawning {d} workers", .{ num_cpus, num_workers });

        const workers = try allocator.alloc(Worker, num_workers);
        errdefer allocator.free(workers);

        // Create BPF synchronization flag
        const bpf_ready = try allocator.create(std.atomic.Value(bool));
        bpf_ready.* = std.atomic.Value(bool).init(false);
        errdefer allocator.destroy(bpf_ready);

        // Create SSE broadcast bus (shared across all workers)
        const sse_bus = SseBroadcastBus.init(allocator, num_workers) catch null;

        // Spawn workers
        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.spawn(allocator, config, i, num_workers, bpf_ready, sse_bus);
        }

        return ThreadPool{
            .allocator = allocator,
            .workers = workers,
            .bpf_ready = bpf_ready,
            .sse_bus = sse_bus,
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
        self.allocator.free(self.workers);
    }
};
