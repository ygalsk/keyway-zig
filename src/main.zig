const std = @import("std");
const log = @import("log.zig");
const Server = @import("server.zig").Server;
const ThreadPool = @import("worker.zig").ThreadPool;

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = log.logFn,
};

pub fn main() !void {
    std.log.info("Keyway - Starting...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Server configuration
    const config = Server.Config{
        .host = "0.0.0.0",
        .port = 8080,
        .enable_bpf_affinity = true,
        .tls_cert_path = "certs/server.crt",
        .tls_key_path = "certs/server.key",
    };

    // Create thread pool (one worker per CPU core)
    // Each worker creates its own router, Lua state, and event loop
    var pool = try ThreadPool.init(allocator, config);
    defer pool.deinit();

    std.log.info("Keyway - Ready on {s}:{d} (press Ctrl+C to stop)", .{ config.host, config.port });

    // Wait for all workers (runs until Ctrl+C)
    pool.joinAll();
}

test "basic test" {
    try std.testing.expectEqual(2 + 2, 4);
}
