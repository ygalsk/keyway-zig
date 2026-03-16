const std = @import("std");
const log = @import("log.zig");
const cli = @import("cli.zig");
const Server = @import("server.zig").Server;
const ThreadPool = @import("worker.zig").ThreadPool;
const shutdown = @import("shutdown.zig");

pub const version = "0.1.0";

/// Compile all log levels in; runtime filtering happens in log.logFn.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log.logFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse CLI arguments (falls back to env vars, then defaults)
    const cli_config = cli.parse(allocator) catch |err| {
        cli.printHelp();
        std.log.err("CLI parse error: {}", .{err});
        std.process.exit(1);
    };

    if (cli_config.show_help) {
        cli.printHelp();
        return;
    }

    if (cli_config.show_version) {
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();
        stderr.print("keyway {s}\n", .{version}) catch {};
        return;
    }

    // Apply runtime log level before any log output
    log.runtime_log_level = cli_config.log_level;

    std.log.info("Keyway - Starting...", .{});

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

    // Create shutdown coordinator before spawning workers (one Async per worker)
    var coordinator = try shutdown.ShutdownCoordinator.init(allocator, num_workers);
    defer coordinator.deinit();

    // Register SIGTERM/SIGINT handlers (first signal drains, second force-kills)
    shutdown.registerSignalHandlers(&coordinator);

    // Create thread pool — workers receive coordinator for drain integration
    var pool = try ThreadPool.init(allocator, server_config, cli_config.workers, &coordinator, cli_config.script);
    defer pool.deinit();

    // Block until all workers have bound sockets and are accepting connections
    pool.waitUntilReady();
    std.log.info("Keyway - Ready on {s}:{d} (press Ctrl+C to stop)", .{ server_config.host, server_config.port });

    // Wait for all workers (runs until Ctrl+C)
    pool.joinAll();
}

// Pull all modules into the test runner's import graph.
// Modules not transitively imported from main must be listed here.
comptime {
    _ = @import("metrics.zig");
    _ = @import("shutdown.zig");
    _ = @import("ws.zig");
}
