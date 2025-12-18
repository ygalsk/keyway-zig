const std = @import("std");
const xev = @import("xev");

/// Event loop wrapper - Deep module with simple interface
/// Hides libxev complexity behind 3 methods: init, run, stop
pub const Loop = struct {
    xev_loop: xev.Loop,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),

    /// Initialize event loop
    pub fn init(allocator: std.mem.Allocator) !Loop {
        return Loop{
            .xev_loop = try xev.Loop.init(.{}),
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// Run event loop until stopped
    /// This blocks until stop() is called or all work is complete
    pub fn run(self: *Loop) !void {
        self.running.store(true, .release);

        // Run the event loop until all work is done
        // .until_done already loops internally, no need for outer loop
        try self.xev_loop.run(.until_done);
    }

    /// Stop the event loop
    pub fn stop(self: *Loop) void {
        self.running.store(false, .release);
        self.xev_loop.stop();
    }

    /// Clean up event loop resources
    pub fn deinit(self: *Loop) void {
        self.xev_loop.deinit();
    }
};

test "loop init and deinit" {
    const allocator = std.testing.allocator;

    var loop = try Loop.init(allocator);
    defer loop.deinit();

    try std.testing.expect(loop.running.load(.acquire) == false);
}
