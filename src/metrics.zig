//! Per-worker atomic metrics for health monitoring.
//!
//! Each worker thread owns a WorkerMetrics instance. All fields use
//! std.atomic.Value for lock-free concurrent access (monotonic ordering —
//! these are statistical counters, not synchronization primitives).
//!
//! AggregatedMetrics provides a point-in-time snapshot across all workers
//! for the health endpoint.

const std = @import("std");

/// Per-worker atomic counters. One instance per worker thread.
/// All operations are lock-free using monotonic ordering.
pub const WorkerMetrics = struct {
    request_count: std.atomic.Value(u64),
    error_count: std.atomic.Value(u64),
    active_connections: std.atomic.Value(u32),
    rejected_connections: std.atomic.Value(u64),
    latency_sum_us: std.atomic.Value(u64),
    latency_min_us: std.atomic.Value(u64),
    latency_max_us: std.atomic.Value(u64),

    /// Initialize with zeroed counters and latency_min at maxInt (so first request wins).
    pub fn init() WorkerMetrics {
        return .{
            .request_count = std.atomic.Value(u64).init(0),
            .error_count = std.atomic.Value(u64).init(0),
            .active_connections = std.atomic.Value(u32).init(0),
            .rejected_connections = std.atomic.Value(u64).init(0),
            .latency_sum_us = std.atomic.Value(u64).init(0),
            .latency_min_us = std.atomic.Value(u64).init(std.math.maxInt(u64)),
            .latency_max_us = std.atomic.Value(u64).init(0),
        };
    }

    /// Record a completed request. Updates all counters atomically.
    pub fn recordRequest(self: *WorkerMetrics, latency_us: u64, is_error: bool) void {
        _ = self.request_count.fetchAdd(1, .monotonic);
        if (is_error) {
            _ = self.error_count.fetchAdd(1, .monotonic);
        }
        _ = self.latency_sum_us.fetchAdd(latency_us, .monotonic);

        // Update min/max — single-writer per worker, no cmpxchg needed
        const current_min = self.latency_min_us.load(.monotonic);
        if (latency_us < current_min) self.latency_min_us.store(latency_us, .monotonic);

        const current_max = self.latency_max_us.load(.monotonic);
        if (latency_us > current_max) self.latency_max_us.store(latency_us, .monotonic);
    }

    /// Increment active connection count (called on accept).
    pub fn incrementActiveConnections(self: *WorkerMetrics) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    /// Decrement active connection count (called on close).
    pub fn decrementActiveConnections(self: *WorkerMetrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    /// Increment rejected connection count (called when over limit).
    pub fn incrementRejectedConnections(self: *WorkerMetrics) void {
        _ = self.rejected_connections.fetchAdd(1, .monotonic);
    }
};

/// Point-in-time aggregated snapshot across all workers.
pub const AggregatedMetrics = struct {
    status: []const u8,
    worker_count: usize,
    total_requests: u64,
    total_errors: u64,
    active_connections: u64,
    rejected_connections: u64,
    latency_min_us: u64,
    latency_max_us: u64,
    latency_avg_us: u64,
};

/// Aggregate metrics from all worker instances into a single snapshot.
pub fn aggregate(metrics: []const *WorkerMetrics, status: []const u8) AggregatedMetrics {
    var total_requests: u64 = 0;
    var total_errors: u64 = 0;
    var active_connections: u64 = 0;
    var rejected_connections: u64 = 0;
    var latency_sum: u64 = 0;
    var global_min: u64 = std.math.maxInt(u64);
    var global_max: u64 = 0;

    for (metrics) |m| {
        total_requests += m.request_count.load(.monotonic);
        total_errors += m.error_count.load(.monotonic);
        active_connections += m.active_connections.load(.monotonic);
        rejected_connections += m.rejected_connections.load(.monotonic);
        latency_sum += m.latency_sum_us.load(.monotonic);

        const worker_min = m.latency_min_us.load(.monotonic);
        const worker_max = m.latency_max_us.load(.monotonic);
        if (worker_min < global_min) global_min = worker_min;
        if (worker_max > global_max) global_max = worker_max;
    }

    // Handle zero-request edge case
    const avg = if (total_requests > 0) latency_sum / total_requests else 0;
    const min = if (total_requests > 0) global_min else 0;

    return .{
        .status = status,
        .worker_count = metrics.len,
        .total_requests = total_requests,
        .total_errors = total_errors,
        .active_connections = active_connections,
        .rejected_connections = rejected_connections,
        .latency_min_us = min,
        .latency_max_us = global_max,
        .latency_avg_us = avg,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "WorkerMetrics.init has correct defaults" {
    const m = WorkerMetrics.init();
    try std.testing.expectEqual(@as(u64, 0), m.request_count.raw);
    try std.testing.expectEqual(@as(u64, 0), m.error_count.raw);
    try std.testing.expectEqual(@as(u32, 0), m.active_connections.raw);
    try std.testing.expectEqual(@as(u64, 0), m.rejected_connections.raw);
    try std.testing.expectEqual(@as(u64, 0), m.latency_sum_us.raw);
    try std.testing.expectEqual(std.math.maxInt(u64), m.latency_min_us.raw);
    try std.testing.expectEqual(@as(u64, 0), m.latency_max_us.raw);
}

test "recordRequest updates all counters" {
    var m = WorkerMetrics.init();
    m.recordRequest(500, false);

    try std.testing.expectEqual(@as(u64, 1), m.request_count.raw);
    try std.testing.expectEqual(@as(u64, 0), m.error_count.raw);
    try std.testing.expectEqual(@as(u64, 500), m.latency_sum_us.raw);
    try std.testing.expectEqual(@as(u64, 500), m.latency_min_us.raw);
    try std.testing.expectEqual(@as(u64, 500), m.latency_max_us.raw);
}

test "recordRequest tracks errors" {
    var m = WorkerMetrics.init();
    m.recordRequest(100, true);
    m.recordRequest(200, false);

    try std.testing.expectEqual(@as(u64, 2), m.request_count.raw);
    try std.testing.expectEqual(@as(u64, 1), m.error_count.raw);
}

test "recordRequest min/max cmpxchg correctness" {
    var m = WorkerMetrics.init();
    m.recordRequest(500, false); // first: min=500, max=500
    m.recordRequest(100, false); // new min=100
    m.recordRequest(900, false); // new max=900
    m.recordRequest(300, false); // no change

    try std.testing.expectEqual(@as(u64, 100), m.latency_min_us.raw);
    try std.testing.expectEqual(@as(u64, 900), m.latency_max_us.raw);
    try std.testing.expectEqual(@as(u64, 4), m.request_count.raw);
    try std.testing.expectEqual(@as(u64, 1800), m.latency_sum_us.raw); // 500+100+900+300
}

test "active connections increment/decrement" {
    var m = WorkerMetrics.init();
    m.incrementActiveConnections();
    m.incrementActiveConnections();
    try std.testing.expectEqual(@as(u32, 2), m.active_connections.raw);

    m.decrementActiveConnections();
    try std.testing.expectEqual(@as(u32, 1), m.active_connections.raw);
}

test "aggregate across two workers" {
    var w1 = WorkerMetrics.init();
    var w2 = WorkerMetrics.init();

    w1.recordRequest(100, false);
    w1.recordRequest(300, true);
    w1.incrementActiveConnections();

    w2.recordRequest(200, false);
    w2.recordRequest(400, true);
    w2.incrementActiveConnections();
    w2.incrementActiveConnections();

    const workers = [_]*WorkerMetrics{ &w1, &w2 };
    const result = aggregate(&workers, "healthy");

    try std.testing.expectEqualStrings("healthy", result.status);
    try std.testing.expectEqual(@as(usize, 2), result.worker_count);
    try std.testing.expectEqual(@as(u64, 4), result.total_requests);
    try std.testing.expectEqual(@as(u64, 2), result.total_errors);
    try std.testing.expectEqual(@as(u64, 3), result.active_connections);
    try std.testing.expectEqual(@as(u64, 0), result.rejected_connections);
    try std.testing.expectEqual(@as(u64, 100), result.latency_min_us); // global min
    try std.testing.expectEqual(@as(u64, 400), result.latency_max_us); // global max
    try std.testing.expectEqual(@as(u64, 250), result.latency_avg_us); // (100+300+200+400)/4
}

test "aggregate zero-request edge case" {
    var w1 = WorkerMetrics.init();
    var w2 = WorkerMetrics.init();

    const workers = [_]*WorkerMetrics{ &w1, &w2 };
    const result = aggregate(&workers, "healthy");

    try std.testing.expectEqual(@as(u64, 0), result.total_requests);
    try std.testing.expectEqual(@as(u64, 0), result.latency_avg_us);
    try std.testing.expectEqual(@as(u64, 0), result.latency_min_us); // 0, not maxInt
    try std.testing.expectEqual(@as(u64, 0), result.latency_max_us);
}
