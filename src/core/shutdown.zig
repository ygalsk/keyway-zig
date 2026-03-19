//! Graceful shutdown coordination.
//!
//! ShutdownCoordinator manages the shutdown state machine (running -> draining -> force_shutdown)
//! and notifies all workers via xev.Async (eventfd-based, async-signal-safe).
//!
//! Signal handler registration uses POSIX sigaction. The signal handler only performs
//! async-signal-safe operations: atomic CAS + eventfd write (via Async.notify).

const std = @import("std");
const xev = @import("xev");

/// Shutdown lifecycle state.
pub const State = enum(u8) {
    running,
    draining,
    force_shutdown,
};

/// Coordinates graceful shutdown across all worker threads.
///
/// Owns one xev.Async per worker. On first signal, transitions running->draining
/// and notifies all workers. On second signal, transitions draining->force_shutdown
/// and notifies again.
pub const ShutdownCoordinator = struct {
    state: std.atomic.Value(u8),
    asyncs: []xev.Async,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !ShutdownCoordinator {
        const asyncs = try allocator.alloc(xev.Async, num_workers);
        errdefer allocator.free(asyncs);

        for (asyncs) |*a| {
            a.* = try xev.Async.init();
        }

        return .{
            .state = std.atomic.Value(u8).init(@intFromEnum(State.running)),
            .asyncs = asyncs,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ShutdownCoordinator) void {
        for (self.asyncs) |*a| {
            a.deinit();
        }
        self.allocator.free(self.asyncs);
    }

    /// Called from signal handler. Async-signal-safe (only atomics + eventfd write).
    ///
    /// First call: running -> draining, notify all workers.
    /// Second call: draining -> force_shutdown, notify all workers again.
    pub fn signalReceived(self: *ShutdownCoordinator) void {
        const running_val = @intFromEnum(State.running);
        const draining_val = @intFromEnum(State.draining);
        const force_val = @intFromEnum(State.force_shutdown);

        // Try running -> draining
        if (self.state.cmpxchgStrong(running_val, draining_val, .monotonic, .monotonic) == null) {
            // First signal: notify all workers to start draining
            self.notifyAll();
            return;
        }

        // Already draining (or force_shutdown). Try draining -> force_shutdown
        if (self.state.cmpxchgStrong(draining_val, force_val, .monotonic, .monotonic) == null) {
            // Second signal: notify all workers to force-close
            self.notifyAll();
            return;
        }

        // Already force_shutdown — nothing to do
    }

    /// Returns true when state is not running (draining or force_shutdown).
    pub fn isDraining(self: *const ShutdownCoordinator) bool {
        return self.state.load(.monotonic) != @intFromEnum(State.running);
    }

    /// Returns true when state is force_shutdown.
    pub fn isForceShutdown(self: *const ShutdownCoordinator) bool {
        return self.state.load(.monotonic) == @intFromEnum(State.force_shutdown);
    }

    /// Get the Async notifier for a specific worker.
    pub fn getAsync(self: *ShutdownCoordinator, worker_id: usize) *xev.Async {
        return &self.asyncs[worker_id];
    }

    fn notifyAll(self: *ShutdownCoordinator) void {
        for (self.asyncs) |a| {
            a.notify() catch {};
        }
    }
};

// File-scope storage for signal handler (C callback cannot capture context).
var global_coordinator: ?*ShutdownCoordinator = null;

/// Register SIGTERM and SIGINT handlers that call coordinator.signalReceived().
pub fn registerSignalHandlers(coordinator: *ShutdownCoordinator) void {
    global_coordinator = coordinator;

    const act = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };

    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn signalHandler(_: c_int) callconv(.c) void {
    if (global_coordinator) |coord| {
        coord.signalReceived();
    }
}

// =============================================================================
// Tests
// =============================================================================

test "ShutdownCoordinator state machine: init is running" {
    const coord = try ShutdownCoordinator.init(std.testing.allocator, 2);
    var coordinator = coord;
    defer coordinator.deinit();

    try std.testing.expect(!coordinator.isDraining());
    try std.testing.expect(!coordinator.isForceShutdown());
}

test "ShutdownCoordinator state machine: first signal -> draining" {
    var coordinator = try ShutdownCoordinator.init(std.testing.allocator, 2);
    defer coordinator.deinit();

    coordinator.signalReceived();
    try std.testing.expect(coordinator.isDraining());
    try std.testing.expect(!coordinator.isForceShutdown());
}

test "ShutdownCoordinator state machine: second signal -> force_shutdown" {
    var coordinator = try ShutdownCoordinator.init(std.testing.allocator, 2);
    defer coordinator.deinit();

    coordinator.signalReceived();
    coordinator.signalReceived();
    try std.testing.expect(coordinator.isDraining());
    try std.testing.expect(coordinator.isForceShutdown());
}

test "ShutdownCoordinator state machine: third signal is idempotent" {
    var coordinator = try ShutdownCoordinator.init(std.testing.allocator, 2);
    defer coordinator.deinit();

    coordinator.signalReceived();
    coordinator.signalReceived();
    coordinator.signalReceived(); // Should not crash
    try std.testing.expect(coordinator.isForceShutdown());
}

test "ShutdownCoordinator getAsync returns valid pointer" {
    var coordinator = try ShutdownCoordinator.init(std.testing.allocator, 4);
    defer coordinator.deinit();

    // Each worker ID returns a distinct valid pointer
    const a0 = coordinator.getAsync(0);
    const a1 = coordinator.getAsync(1);
    const a2 = coordinator.getAsync(2);
    const a3 = coordinator.getAsync(3);

    try std.testing.expect(a0 != a1);
    try std.testing.expect(a1 != a2);
    try std.testing.expect(a2 != a3);
}
