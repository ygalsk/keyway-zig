const std = @import("std");
const log = @import("observability/log.zig");
const cli = @import("util/cli.zig");
const Server = @import("core/server.zig").Server;
const ThreadPool = @import("core/worker.zig").ThreadPool;
const shutdown = @import("core/shutdown.zig");
const reload = @import("core/reload.zig");
const prom = @import("observability/prom.zig");

pub const version = "0.1.0";

/// Compile all log levels in; runtime filtering happens in log.logFn.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log.logFn,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments (falls back to env vars, then defaults)
    const cli_config = cli.parse(allocator, init.args) catch |err| {
        cli.printStderr("keyway: error parsing arguments: {}\n", .{err}) catch {};
        cli.printHelp() catch {}; // best-effort: already exiting non-zero
        std.process.exit(1);
    };

    if (cli_config.show_help) {
        try cli.printHelp();
        return;
    }

    if (cli_config.show_version) {
        try cli.printStderr("keyway {s}\n", .{version});
        return;
    }

    // Initialize Prometheus metrics (before spawning workers)
    try prom.init(allocator);
    defer prom.deinit();

    // Convert CLI config to Server.Config
    // TLS paths: cli.Config has ?[]const u8, Server.Config needs ?[*:0]const u8
    const tls_cert: ?[*:0]const u8 = if (cli_config.tls_cert_path) |p|
        @ptrCast(p.ptr)
    else
        null;

    const tls_key: ?[*:0]const u8 = if (cli_config.tls_key_path) |p|
        @ptrCast(p.ptr)
    else
        null;

    const server_config = Server.Config{
        .host = cli_config.host,
        .port = cli_config.port,
        .enable_bpf_affinity = cli_config.enable_bpf,
        .tls_cert_path = tls_cert,
        .tls_key_path = tls_key,
    };

    // Determine worker count (0 means auto-detect CPU count)
    const num_cpus = try std.Thread.getCpuCount();
    const num_workers: usize = if (cli_config.workers > 0) @intCast(cli_config.workers) else num_cpus;

    // Initialize structured logging (needs worker count for pool sizing)
    try log.init(allocator, cli_config.log_level, cli_config.log_format, num_workers);
    defer log.deinit();

    log.info().string("msg", "Keyway - Starting...").log();

    // Create shutdown coordinator before spawning workers (one Async per worker)
    var coordinator = try shutdown.ShutdownCoordinator.init(allocator, num_workers);
    defer coordinator.deinit();

    // Register SIGTERM/SIGINT handlers (first signal drains, second force-kills)
    shutdown.registerSignalHandlers(&coordinator);

    // Create reload coordinator (one Async per worker for hot-reload notifications)
    var reload_coordinator = try reload.ReloadCoordinator.init(allocator, num_workers);
    defer reload_coordinator.deinit();

    // Create thread pool — workers receive coordinator for drain integration
    var pool = try ThreadPool.init(allocator, server_config, cli_config.workers, &coordinator, &reload_coordinator, cli_config.script, cli_config.watch);
    defer pool.deinit();

    // Block until all workers have bound sockets and are accepting connections
    pool.waitUntilReady();
    log.info().string("msg", "Keyway - Ready").stringSafe("host", server_config.host).int("port", server_config.port).log();

    // Wait for all workers (runs until Ctrl+C)
    pool.joinAll();
}

// Pull all modules into the test runner's import graph.
// Zig's lazy compilation only discovers tests in modules reached by
// the comptime/runtime code path. Explicitly referencing every test-bearing
// module here ensures `zig build test` runs the full suite.
comptime {
    _ = @import("io/bpf_reuseport.zig");
    _ = @import("util/buffer.zig");
    _ = @import("util/cli.zig");
    _ = @import("io/connection_pool.zig");
    _ = @import("io/cosocket.zig");
    _ = @import("io/cosocket_ops.zig");
    _ = @import("http/error_response.zig");
    _ = @import("io/file_watcher.zig");
    _ = @import("core/handler.zig");
    _ = @import("util/helpers.zig");
    _ = @import("http/http.zig");
    _ = @import("observability/log.zig");
    _ = @import("lua/lua_state.zig");
    _ = @import("observability/metrics.zig");
    _ = @import("http/params.zig");
    _ = @import("observability/prom.zig");
    _ = @import("core/reload.zig");
    _ = @import("io/ring.zig");
    _ = @import("http/router.zig");
    _ = @import("core/server.zig");
    _ = @import("core/shutdown.zig");
    _ = @import("protocol/sse.zig");
    _ = @import("http/static.zig");
    _ = @import("tls/tls.zig");
    _ = @import("protocol/ws.zig");
}
