//! Per-worker atomic connection counter.
//!
//! Each worker thread owns a WorkerMetrics instance. active_connections uses
//! std.atomic.Value for lock-free reads (monotonic — a statistical counter, not
//! a synchronization primitive). It drives graceful-drain completion and the
//! per-worker connection limit. Request/latency stats live in Prometheus (prom.zig).

const std = @import("std");

/// Per-worker active-connection counter. One instance per worker thread.
pub const WorkerMetrics = struct {
    active_connections: std.atomic.Value(u32),

    pub fn init() WorkerMetrics {
        return .{ .active_connections = std.atomic.Value(u32).init(0) };
    }

    /// Increment active connection count (called on accept).
    pub fn incrementActiveConnections(self: *WorkerMetrics) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    /// Decrement active connection count (called on close).
    pub fn decrementActiveConnections(self: *WorkerMetrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "WorkerMetrics.init has zeroed active_connections" {
    const m = WorkerMetrics.init();
    try std.testing.expectEqual(@as(u32, 0), m.active_connections.raw);
}

test "active connections increment/decrement" {
    var m = WorkerMetrics.init();
    m.incrementActiveConnections();
    m.incrementActiveConnections();
    try std.testing.expectEqual(@as(u32, 2), m.active_connections.raw);

    m.decrementActiveConnections();
    try std.testing.expectEqual(@as(u32, 1), m.active_connections.raw);
}
