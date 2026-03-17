//! Prometheus metrics for Keyway, backed by karlseguin/metrics.zig.
//!
//! Single global instance shared across all workers. Thread-safe via atomics.
//! Vec (labeled) metrics use worker_id labels for per-worker breakdown.
//! Exposition via `write()` produces standard Prometheus text format.

const std = @import("std");
const m = @import("metrics");

const Allocator = std.mem.Allocator;

/// Per-worker thread-local ID. Set once in worker.zig workerMain before any I/O.
pub threadlocal var worker_id: u16 = 0;

/// Global metrics instance. Starts as noop, activated by `init()`.
pub var global: Metrics = m.initializeNoop(Metrics);

pub const Metrics = struct {
    // -- Request flow --
    http_requests_total: HttpRequestsTotal,
    http_request_duration_seconds: HttpRequestDuration,
    http_request_body_bytes: BodySizeHist,
    http_response_body_bytes: BodySizeHist,

    // -- Connections --
    connections_accepted_total: ConnectionCounter,
    connections_active: ConnectionGauge,
    connections_rejected_total: ConnectionCounter,

    // -- io_uring / Ring buffer --
    ring_submissions_total: ConnectionCounter,
    ring_completions_total: ConnectionCounter,

    // -- Lua runtime --
    lua_coroutines_active: ConnectionGauge,

    // Labeled types
    const WorkerLabels = struct { worker_id: u16 };
    const RequestLabels = struct { worker_id: u16, method: []const u8, status: u16, route: []const u8 };
    const HttpRequestsTotal = m.CounterVec(u64, RequestLabels);
    const HttpRequestDuration = m.HistogramVec(f64, WorkerLabels, &latency_buckets_seconds);
    const BodySizeHist = m.Histogram(u64, &size_buckets_bytes);
    const ConnectionCounter = m.CounterVec(u64, WorkerLabels);
    const ConnectionGauge = m.GaugeVec(i64, WorkerLabels);
};

/// Latency bucket bounds in seconds (Prometheus convention).
/// 0.5ms, 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s, 10s
const latency_buckets_seconds = [_]f64{ 0.0005, 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 5.0, 10.0 };

/// Body size bucket bounds in bytes.
/// 64, 256, 1K, 4K, 16K, 64K, 256K, 1M, 4M
const size_buckets_bytes = [_]u64{ 64, 256, 1_024, 4_096, 16_384, 65_536, 262_144, 1_048_576, 4_194_304 };

/// Initialize the global metrics instance. Call once at startup before spawning workers.
pub fn init(allocator: Allocator) !void {
    global = .{
        .http_requests_total = try Metrics.HttpRequestsTotal.init(allocator, "keyway_http_requests_total", .{
            .help = "Total HTTP requests handled",
        }, .{}),
        .http_request_duration_seconds = try Metrics.HttpRequestDuration.init(allocator, "keyway_http_request_duration_seconds", .{
            .help = "Request latency in seconds",
        }, .{}),
        .http_request_body_bytes = Metrics.BodySizeHist.init("keyway_http_request_body_bytes", .{
            .help = "Request body size in bytes",
        }, .{}),
        .http_response_body_bytes = Metrics.BodySizeHist.init("keyway_http_response_body_bytes", .{
            .help = "Response body size in bytes",
        }, .{}),
        .connections_accepted_total = try Metrics.ConnectionCounter.init(allocator, "keyway_connections_accepted_total", .{
            .help = "Total accepted connections",
        }, .{}),
        .connections_active = try Metrics.ConnectionGauge.init(allocator, "keyway_connections_active", .{
            .help = "Current active connections",
        }, .{}),
        .connections_rejected_total = try Metrics.ConnectionCounter.init(allocator, "keyway_connections_rejected_total", .{
            .help = "Total rejected connections",
        }, .{}),
        .ring_submissions_total = try Metrics.ConnectionCounter.init(allocator, "keyway_ring_submissions_total", .{
            .help = "Total ring buffer submissions",
        }, .{}),
        .ring_completions_total = try Metrics.ConnectionCounter.init(allocator, "keyway_ring_completions_total", .{
            .help = "Total ring buffer completions",
        }, .{}),
        .lua_coroutines_active = try Metrics.ConnectionGauge.init(allocator, "keyway_lua_coroutines_active", .{
            .help = "Active Lua coroutines",
        }, .{}),
    };
}

pub fn deinit() void {
    global.http_requests_total.deinit();
    global.http_request_duration_seconds.deinit();
    global.connections_accepted_total.deinit();
    global.connections_active.deinit();
    global.connections_rejected_total.deinit();
    global.ring_submissions_total.deinit();
    global.ring_completions_total.deinit();
    global.lua_coroutines_active.deinit();
}

/// Write all metrics in Prometheus text exposition format.
pub fn write(writer: *std.Io.Writer) !void {
    return m.write(&global, writer);
}

// =============================================================================
// Convenience recording functions (called from hot path)
// =============================================================================

fn wlabels() Metrics.WorkerLabels {
    return .{ .worker_id = worker_id };
}

/// Record a completed HTTP request.
pub fn recordRequest(method: []const u8, status: u16, latency_us: u64, route: []const u8) void {
    global.http_requests_total.incr(.{ .worker_id = worker_id, .method = method, .status = status, .route = route }) catch {};
    const latency_seconds: f64 = @as(f64, @floatFromInt(latency_us)) / 1_000_000.0;
    global.http_request_duration_seconds.observe(wlabels(), latency_seconds) catch {};
}

/// Record request body size.
pub fn recordRequestBodySize(size: u64) void {
    global.http_request_body_bytes.observe(size);
}

/// Record response body size.
pub fn recordResponseBodySize(size: u64) void {
    global.http_response_body_bytes.observe(size);
}

/// Connection accepted.
pub fn connectionAccepted() void {
    global.connections_accepted_total.incr(wlabels()) catch {};
    global.connections_active.incr(wlabels()) catch {};
}

/// Connection closed.
pub fn connectionClosed() void {
    global.connections_active.incrBy(wlabels(), -1) catch {};
}

/// Connection rejected (over limit).
pub fn connectionRejected() void {
    global.connections_rejected_total.incr(wlabels()) catch {};
}

/// Ring buffer submission(s).
pub fn ringSubmissions(count: u64) void {
    global.ring_submissions_total.incrBy(wlabels(), count) catch {};
}

/// Ring buffer completion(s).
pub fn ringCompletions(count: u64) void {
    global.ring_completions_total.incrBy(wlabels(), count) catch {};
}

/// Lua coroutine started.
pub fn luaCoroutineStarted() void {
    global.lua_coroutines_active.incr(wlabels()) catch {};
}

/// Lua coroutine finished (completed or errored).
pub fn luaCoroutineFinished() void {
    global.lua_coroutines_active.incrBy(wlabels(), -1) catch {};
}

// =============================================================================
// Tests
// =============================================================================

test "prom: init and record" {
    const allocator = std.testing.allocator;
    try init(allocator);
    defer deinit();

    recordRequest("GET", 200, 1500, "/users");
    recordRequest("POST", 201, 3000, "/users");
    connectionAccepted();
    connectionAccepted();
    connectionClosed();
    recordRequestBodySize(512);
    recordResponseBodySize(2048);
}

test "prom: write produces output with worker_id labels" {
    const allocator = std.testing.allocator;
    try init(allocator);
    defer deinit();

    recordRequest("GET", 200, 500, "/test");
    connectionAccepted();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try write(&writer.writer);

    const buf = writer.writer.buffered();
    // Verify HELP/TYPE headers present
    try std.testing.expect(std.mem.indexOf(u8, buf, "# TYPE keyway_http_requests_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "# TYPE keyway_connections_active gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "# TYPE keyway_http_request_duration_seconds histogram") != null);
    // Verify worker_id label is present
    try std.testing.expect(std.mem.indexOf(u8, buf, "worker_id=") != null);
    // Verify route label is present on requests counter
    try std.testing.expect(std.mem.indexOf(u8, buf, "route=") != null);
}
