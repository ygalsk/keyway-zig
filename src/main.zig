const std = @import("std");
const Server = @import("server.zig").Server;
const ThreadPool = @import("worker.zig").ThreadPool;

pub fn main() !void {
    std.log.info("Keystone Gateway (Zig) - Starting...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Server configuration
    const config = Server.Config{
        .host = "127.0.0.1",
        .port = 8080,
    };

    // Create thread pool (one worker per CPU core)
    // Each worker creates its own router, Lua state, and event loop
    var pool = try ThreadPool.init(allocator, config);
    defer pool.deinit();

    std.log.info("Keystone Gateway - Ready on {s}:{d} (press Ctrl+C to stop)", .{ config.host, config.port });

    // Wait for all workers (runs until Ctrl+C)
    pool.joinAll();
}

test "basic test" {
    try std.testing.expectEqual(2 + 2, 4);
}
