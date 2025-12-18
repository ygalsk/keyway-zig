const std = @import("std");
const Loop = @import("loop.zig").Loop;
const Server = @import("server.zig").Server;
const RadixRouter = @import("radix_router.zig").RadixRouter;
const LuaState = @import("lua_state.zig").LuaState;
const lua_api = @import("lua_api.zig");

/// Worker thread - owns its own event loop and Lua state
/// Each worker accepts connections independently using SO_REUSEPORT
pub const Worker = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    config: Server.Config,
    router: *RadixRouter,
    worker_id: usize,

    /// Worker context passed to thread
    const Context = struct {
        allocator: std.mem.Allocator,
        config: Server.Config,
        worker_id: usize,
        num_workers: usize,
        bpf_ready: *std.atomic.Value(bool),
    };

    /// Spawn a worker thread
    pub fn spawn(
        allocator: std.mem.Allocator,
        config: Server.Config,
        worker_id: usize,
        num_workers: usize,
        bpf_ready: *std.atomic.Value(bool),
    ) !Worker {
        const ctx = try allocator.create(Context);
        ctx.* = Context{
            .allocator = allocator,
            .config = config,
            .worker_id = worker_id,
            .num_workers = num_workers,
            .bpf_ready = bpf_ready,
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
        defer ctx.allocator.destroy(ctx);

        std.log.info("Worker {d} starting...", .{ctx.worker_id});

        // Each worker has its own event loop
        var loop = try Loop.init(ctx.allocator);
        defer loop.deinit();

        // Each worker creates its own router (lua_ref values are Lua-state-specific)
        var router = try RadixRouter.init(ctx.allocator);
        defer router.deinit();

        // Each worker has its own Lua state (one per thread!)
        var lua_state = try LuaState.init(ctx.allocator, &router);
        defer lua_state.deinit();

        // Load Lua handlers (registers routes in this worker's router)
        try lua_state.loadScript("scripts/handlers.lua");

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
        );
        defer server.deinit();

        std.log.info("Worker {d} ready on port {d}", .{ ctx.worker_id, ctx.config.port });

        // Start accepting connections
        try server.start();

        // Run event loop
        try loop.run();
    }
};

/// Thread pool manager
pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    bpf_ready: *std.atomic.Value(bool),

    /// Create thread pool with one worker per CPU core
    pub fn init(
        allocator: std.mem.Allocator,
        config: Server.Config,
    ) !ThreadPool {
        const num_cpus = try std.Thread.getCpuCount();
        std.log.info("Detected {d} CPU cores, spawning {d} workers", .{ num_cpus, num_cpus });

        const workers = try allocator.alloc(Worker, num_cpus);
        errdefer allocator.free(workers);

        // Create BPF synchronization flag
        const bpf_ready = try allocator.create(std.atomic.Value(bool));
        bpf_ready.* = std.atomic.Value(bool).init(false);
        errdefer allocator.destroy(bpf_ready);

        // Spawn workers
        for (workers, 0..) |*worker, i| {
            worker.* = try Worker.spawn(allocator, config, i, num_cpus, bpf_ready);
        }

        return ThreadPool{
            .allocator = allocator,
            .workers = workers,
            .bpf_ready = bpf_ready,
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
        self.allocator.destroy(self.bpf_ready);
        self.allocator.free(self.workers);
    }
};
