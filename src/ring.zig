const std = @import("std");

/// Tagged union describing a single outbound I/O intent.
/// Each variant carries only the fields relevant to that operation.
/// ~48 bytes vs ~112 for a flat struct; exhaustive switch in drain loop.
pub const IoEntry = union(Op) {
    connect: ConnectInfo,
    pool_connect: PoolConnectInfo,
    udp_connect: UdpConnectInfo,
    send: SendInfo,
    recv: RecvInfo,
    close: CloseInfo,
    setkeepalive: KeepaliveInfo,
    tls_handshake: TlsHandshakeInfo,

    pub const Op = enum { connect, pool_connect, udp_connect, send, recv, close, setkeepalive, tls_handshake };

    pub const ConnectInfo = struct { host: []const u8, port: u16 };
    pub const PoolConnectInfo = struct { host: []const u8, port: u16, pool_name: []const u8 };
    pub const UdpConnectInfo = struct { host: []const u8, port: u16, timeout_ms: u32 };
    pub const SendInfo = struct { fd: std.posix.socket_t, data: []const u8 };
    pub const RecvInfo = struct { fd: std.posix.socket_t, max_len: usize };
    pub const CloseInfo = struct { fd: std.posix.socket_t };
    pub const KeepaliveInfo = struct {
        fd: std.posix.socket_t,
        pool_name: []const u8,
        timeout_ms: u32,
        pool_size: u32,
        reuse_count: u32,
    };
    pub const TlsHandshakeInfo = struct { fd: std.posix.socket_t, sni_host: ?[]const u8 };
};

/// Completion queue entry — result of one I/O operation.
pub const CQEntry = struct {
    result: i32, // fd for connect, byte count for send/recv, negative for error
    buf: ?[]const u8 = null, // recv: pointer to filled buffer (arena-allocated)
    err_msg: ?[*:0]const u8 = null,
};

/// Fixed-size ring buffer for I/O submission entries.
/// Per-connection, inline, reset per request.
pub const SubmissionRing = struct {
    entries: [MAX_DEPTH]IoEntry = undefined,
    head: u8 = 0,
    tail: u8 = 0,

    pub const MAX_DEPTH = 16;

    pub fn push(self: *SubmissionRing, entry: IoEntry) error{RingFull}!void {
        if (self.len() >= MAX_DEPTH) return error.RingFull;
        self.entries[self.tail % MAX_DEPTH] = entry;
        self.tail +%= 1;
    }

    pub fn pop(self: *SubmissionRing) ?*const IoEntry {
        if (self.head == self.tail) return null;
        const idx = self.head % MAX_DEPTH;
        self.head +%= 1;
        return &self.entries[idx];
    }

    pub fn len(self: *const SubmissionRing) u8 {
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

    pub const MAX_DEPTH = 16;

    pub fn push(self: *CompletionRing, entry: CQEntry) void {
        std.debug.assert(self.tail < MAX_DEPTH);
        self.entries[self.tail] = entry;
        self.tail += 1;
    }

    pub fn get(self: *const CompletionRing, index: u8) CQEntry {
        std.debug.assert(index < self.tail);
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

    // Push a connect entry
    try sq.push(.{ .connect = .{ .host = "127.0.0.1", .port = 6379 } });
    try std.testing.expectEqual(@as(u8, 1), sq.len());

    // Push a send entry
    try sq.push(.{ .send = .{ .fd = 5, .data = "PING\r\n" } });
    try std.testing.expectEqual(@as(u8, 2), sq.len());

    // Pop in FIFO order
    const e1 = sq.pop().?;
    try std.testing.expectEqual(IoEntry.Op.connect, std.meta.activeTag(e1.*));
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

    try std.testing.expectEqual(@as(i32, 5), cq.get(0).result);
    try std.testing.expectEqual(@as(i32, 6), cq.get(1).result);
    try std.testing.expectEqualStrings("PONG\r\n", cq.get(1).buf.?);
    try std.testing.expect(cq.get(0).buf == null);

    cq.reset();
    try std.testing.expectEqual(@as(u8, 0), cq.tail);
}

test "IoEntry: tagged union active field" {
    const entry: IoEntry = .{ .pool_connect = .{
        .host = "10.0.0.1",
        .port = 5432,
        .pool_name = "postgres",
    } };

    switch (entry) {
        .pool_connect => |pc| {
            try std.testing.expectEqualStrings("postgres", pc.pool_name);
            try std.testing.expectEqual(@as(u16, 5432), pc.port);
        },
        else => try std.testing.expect(false),
    }
}
