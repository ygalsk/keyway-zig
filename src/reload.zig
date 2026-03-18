//! Hot-reload coordination.
//!
//! ReloadCoordinator notifies all workers to re-execute the Lua entry point
//! and rebuild their route tables. Uses the same xev.Async (eventfd) pattern
//! as ShutdownCoordinator — one notification per worker, delivered on each
//! worker's event loop.

const std = @import("std");
const xev = @import("xev");

/// Coordinates hot-reload across all worker threads.
///
/// Owns one xev.Async per worker. signalReload() wakes all workers via eventfd.
/// Each worker arms Async.wait in its event loop; the callback triggers performReload.
pub const ReloadCoordinator = struct {
    asyncs: []xev.Async,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !ReloadCoordinator {
        const asyncs = try allocator.alloc(xev.Async, num_workers);
        errdefer allocator.free(asyncs);

        for (asyncs) |*a| {
            a.* = try xev.Async.init();
        }

        return .{
            .asyncs = asyncs,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReloadCoordinator) void {
        for (self.asyncs) |*a| {
            a.deinit();
        }
        self.allocator.free(self.asyncs);
    }

    /// Wake all workers to trigger a reload.
    pub fn signalReload(self: *ReloadCoordinator) void {
        self.notifyAll();
    }

    /// Get the Async notifier for a specific worker.
    pub fn getAsync(self: *ReloadCoordinator, worker_id: usize) *xev.Async {
        return &self.asyncs[worker_id];
    }

    fn notifyAll(self: *ReloadCoordinator) void {
        for (self.asyncs) |a| {
            a.notify() catch {};
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ReloadCoordinator init/deinit" {
    var coord = try ReloadCoordinator.init(std.testing.allocator, 4);
    defer coord.deinit();

    // Each worker ID returns a distinct valid pointer
    const a0 = coord.getAsync(0);
    const a1 = coord.getAsync(1);
    try std.testing.expect(a0 != a1);
}

test "ReloadCoordinator signalReload does not crash" {
    var coord = try ReloadCoordinator.init(std.testing.allocator, 2);
    defer coord.deinit();

    // signalReload is safe to call (eventfd writes)
    coord.signalReload();
    coord.signalReload(); // idempotent
}
