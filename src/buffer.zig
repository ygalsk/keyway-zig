const std = @import("std");

/// Ring buffer for streaming I/O
/// Provides efficient buffering for HTTP parsing
pub const RingBuffer = struct {
    data: []u8,
    read_pos: usize,
    write_pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size: usize) !RingBuffer {
        const data = try allocator.alloc(u8, size);
        return RingBuffer{
            .data = data,
            .read_pos = 0,
            .write_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.data);
    }

    /// Get slice available for writing
    pub fn writeSlice(self: *RingBuffer) []u8 {
        return self.data[self.write_pos..];
    }

    /// Mark bytes as written (advance write position)
    pub fn commitWrite(self: *RingBuffer, n: usize) void {
        self.write_pos += n;
    }

    /// Get slice available for reading
    pub fn readSlice(self: *RingBuffer) []const u8 {
        return self.data[self.read_pos..self.write_pos];
    }

    /// Mark bytes as consumed (advance read position)
    pub fn consume(self: *RingBuffer, n: usize) void {
        self.read_pos += n;

        // Reset positions when buffer is empty
        if (self.read_pos == self.write_pos) {
            self.read_pos = 0;
            self.write_pos = 0;
        }
    }

    /// Get available space for writing
    pub fn availableWrite(self: *RingBuffer) usize {
        return self.data.len - self.write_pos;
    }

    /// Get available data for reading
    pub fn availableRead(self: *RingBuffer) usize {
        return self.write_pos - self.read_pos;
    }

    /// Reset buffer to empty state
    pub fn reset(self: *RingBuffer) void {
        self.read_pos = 0;
        self.write_pos = 0;
    }
};

test "ring buffer basic operations" {
    const allocator = std.testing.allocator;

    var buf = try RingBuffer.init(allocator, 1024);
    defer buf.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), buf.availableRead());
    try std.testing.expectEqual(@as(usize, 1024), buf.availableWrite());

    // Write some data
    const write_slice = buf.writeSlice();
    @memcpy(write_slice[0..5], "Hello");
    buf.commitWrite(5);

    try std.testing.expectEqual(@as(usize, 5), buf.availableRead());
    try std.testing.expectEqualStrings("Hello", buf.readSlice());

    // Consume data
    buf.consume(5);
    try std.testing.expectEqual(@as(usize, 0), buf.availableRead());

    // Positions should be reset
    try std.testing.expectEqual(@as(usize, 0), buf.read_pos);
    try std.testing.expectEqual(@as(usize, 0), buf.write_pos);
}

test "ring buffer partial consume" {
    const allocator = std.testing.allocator;

    var buf = try RingBuffer.init(allocator, 1024);
    defer buf.deinit();

    // Write "Hello World"
    const write_slice = buf.writeSlice();
    @memcpy(write_slice[0..11], "Hello World");
    buf.commitWrite(11);

    // Read first 5 bytes
    try std.testing.expectEqualStrings("Hello World", buf.readSlice());
    buf.consume(6); // Consume "Hello "

    // Remaining should be "World"
    try std.testing.expectEqualStrings("World", buf.readSlice());
}
