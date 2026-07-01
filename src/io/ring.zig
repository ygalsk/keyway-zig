//! Submission/completion rings for batched cosocket I/O.
//!
//! Modeled after io_uring: Lua pushes IoEntry variants into the submission ring,
//! yields, and Zig drains the ring into xev operations. Completions land in the
//! completion ring (indexed by submission order). Lua reads results via ring_api.
//!
//! Fixed-size (RING_DEPTH=16), per-connection, inline, reset per request.

const std = @import("std");
const log = @import("../observability/log.zig");
const config = @import("../util/config.zig");
const ErrorCategory = @import("../http/error_response.zig").ErrorCategory;

/// Tagged union describing a single outbound I/O intent.
/// Each variant carries only the fields relevant to that operation.
/// Exhaustive switch in the drain loop.
pub const IoEntry = union(Op) {
    send: SendInfo,
    recv: RecvInfo,
    close: CloseInfo,
    none: void,

    pub const Op = enum { send, recv, close, none };

    pub const SendInfo = struct { fd: std.posix.socket_t, data: []const u8 };
    pub const RecvInfo = struct { fd: std.posix.socket_t, max_len: usize };
    pub const CloseInfo = struct { fd: std.posix.socket_t };
};

/// Completion queue entry — result of one I/O operation.
pub const CQEntry = struct {
    result: i32, // fd for connect, byte count for send/recv, negative for error
    buf: ?[]const u8 = null, // recv: pointer to filled buffer (arena-allocated)
    err_msg: ?[*:0]const u8 = null,
    err_category: ?ErrorCategory = null, // error classification for structured Lua error tables
};

/// Fixed-size ring buffer for I/O submission entries.
/// Per-connection, inline, reset per request.
pub const SubmissionRing = struct {
    entries: [MAX_DEPTH]IoEntry = undefined,
    head: u8 = 0,
    tail: u8 = 0,

    pub const MAX_DEPTH = config.RING_DEPTH;

    pub inline fn push(self: *SubmissionRing, entry: IoEntry) error{RingFull}!void {
        if (self.len() >= MAX_DEPTH) return error.RingFull;
        self.entries[self.tail % MAX_DEPTH] = entry;
        self.tail +%= 1;
    }

    pub inline fn pop(self: *SubmissionRing) ?*const IoEntry {
        if (self.head == self.tail) return null;
        const idx = self.head % MAX_DEPTH;
        self.head +%= 1;
        return &self.entries[idx];
    }

    pub inline fn len(self: *const SubmissionRing) u8 {
        return self.tail -% self.head;
    }

    pub fn reset(self: *SubmissionRing) void {
        self.head = 0;
        self.tail = 0;
    }
};

/// Fixed-size array for I/O completion results.
/// Indexed by SQE submission order (0..N-1).
pub const CompletionRing = struct {
    entries: [MAX_DEPTH]CQEntry = undefined,
    tail: u8 = 0,

    pub const MAX_DEPTH = config.RING_DEPTH;

    pub inline fn push(self: *CompletionRing, entry: CQEntry) void {
        if (self.tail >= MAX_DEPTH) {
            log.err().string("msg", "CompletionRing overflow").int("tail", self.tail).int("max", MAX_DEPTH).log();
            return;
        }
        self.entries[self.tail] = entry;
        self.tail += 1;
    }

    /// Returns the CQE at `index`, or null if out of bounds. Real check (not a
    /// debug assert) so an invalid index can't read uninitialized/OOB memory in
    /// release builds.
    pub inline fn get(self: *const CompletionRing, index: u8) ?CQEntry {
        if (index >= self.tail) return null;
        return self.entries[index];
    }

    pub fn reset(self: *CompletionRing) void {
        self.tail = 0;
    }
};

// === Tests ===

test "SubmissionRing: push/pop/len/reset" {
    var sq = SubmissionRing{};
    try std.testing.expectEqual(@as(u8, 0), sq.len());

    // Push a recv entry
    try sq.push(.{ .recv = .{ .fd = 5, .max_len = 4096 } });
    try std.testing.expectEqual(@as(u8, 1), sq.len());

    // Push a send entry
    try sq.push(.{ .send = .{ .fd = 5, .data = "PING\r\n" } });
    try std.testing.expectEqual(@as(u8, 2), sq.len());

    // Pop in FIFO order
    const e1 = sq.pop().?;
    try std.testing.expectEqual(IoEntry.Op.recv, std.meta.activeTag(e1.*));
    try std.testing.expectEqual(@as(u8, 1), sq.len());

    const e2 = sq.pop().?;
    try std.testing.expectEqual(IoEntry.Op.send, std.meta.activeTag(e2.*));
    try std.testing.expectEqual(@as(u8, 0), sq.len());

    // Pop on empty returns null
    try std.testing.expect(sq.pop() == null);

    // Reset
    try sq.push(.{ .recv = .{ .fd = 5, .max_len = 4096 } });
    sq.reset();
    try std.testing.expectEqual(@as(u8, 0), sq.len());
    try std.testing.expect(sq.pop() == null);
}

test "SubmissionRing: overflow returns RingFull" {
    var sq = SubmissionRing{};

    // Fill to capacity
    for (0..SubmissionRing.MAX_DEPTH) |_| {
        try sq.push(.{ .close = .{ .fd = 1 } });
    }
    try std.testing.expectEqual(@as(u8, SubmissionRing.MAX_DEPTH), sq.len());

    // One more should fail
    try std.testing.expectError(error.RingFull, sq.push(.{ .close = .{ .fd = 1 } }));
}

test "CompletionRing: push/get/reset" {
    var cq = CompletionRing{};
    try std.testing.expectEqual(@as(u8, 0), cq.tail);

    cq.push(.{ .result = 5 }); // fd from connect
    cq.push(.{ .result = 6, .buf = "PONG\r\n" }); // recv result

    try std.testing.expectEqual(@as(i32, 5), cq.get(0).?.result);
    try std.testing.expectEqual(@as(i32, 6), cq.get(1).?.result);
    try std.testing.expectEqualStrings("PONG\r\n", cq.get(1).?.buf.?);
    try std.testing.expect(cq.get(0).?.buf == null);
    try std.testing.expect(cq.get(2) == null); // out of bounds returns null

    cq.reset();
    try std.testing.expectEqual(@as(u8, 0), cq.tail);
}

test "CQEntry: err_category round-trips correctly" {
    var cq = CompletionRing{};

    // Push entry with err_category
    cq.push(.{ .result = -1, .err_msg = "connection refused", .err_category = .upstream_error });
    cq.push(.{ .result = -1, .err_msg = "recv: alloc failed", .err_category = .server_error });
    cq.push(.{ .result = 5 }); // success entry, no category

    const e0 = cq.get(0).?;
    try std.testing.expectEqual(@as(i32, -1), e0.result);
    try std.testing.expectEqual(ErrorCategory.upstream_error, e0.err_category.?);
    try std.testing.expectEqualStrings("connection refused", std.mem.span(e0.err_msg.?));

    const e1 = cq.get(1).?;
    try std.testing.expectEqual(ErrorCategory.server_error, e1.err_category.?);

    const e2 = cq.get(2).?;
    try std.testing.expect(e2.err_category == null);
    try std.testing.expect(e2.err_msg == null);
}

test "IoEntry: tagged union active field" {
    const entry: IoEntry = .{ .send = .{ .fd = 5, .data = "PING\r\n" } };

    switch (entry) {
        .send => |s| {
            try std.testing.expectEqualStrings("PING\r\n", s.data);
            try std.testing.expectEqual(@as(std.posix.socket_t, 5), s.fd);
        },
        else => try std.testing.expect(false),
    }
}
