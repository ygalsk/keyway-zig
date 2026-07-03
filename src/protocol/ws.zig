const std = @import("std");
const config = @import("../util/config.zig");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
};

pub const ParseResult = union(enum) {
    frame: struct { frame: Frame, consumed: usize },
    incomplete,
};

/// Parse a single WebSocket frame from data. Unmasking is done in-place.
/// Client frames MUST be masked per RFC 6455 §5.1 (unmasked -> protocol
/// error). RSV1-3 must be unset since we negotiate no extensions (§5.2).
pub fn parseFrame(data: []u8) !ParseResult {
    if (data.len < 2) return .incomplete;

    const b0 = data[0];
    const b1 = data[1];

    const fin = (b0 & 0x80) != 0;
    // RFC 6455 §5.2: RSV1-3 (bits 0x40, 0x20, 0x10) are reserved for
    // extensions; we negotiate none, so a client setting any is a protocol error.
    if (b0 & 0x70 != 0) return error.ReservedBitsSet;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = (b1 & 0x80) != 0;
    var payload_len: u64 = b1 & 0x7F;
    var pos: usize = 2;

    if (payload_len == 126) {
        if (data.len < pos + 2) return .incomplete;
        payload_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
    } else if (payload_len == 127) {
        if (data.len < pos + 8) return .incomplete;
        payload_len = std.mem.readInt(u64, data[pos..][0..8], .big);
        pos += 8;
    }

    // A single frame's payload must fit the read buffer in one shot — it can
    // never be assembled otherwise (#228). This is stricter than (and
    // supersedes) the reassembled-message limit: a fragmented message may
    // still reach WS_MAX_MESSAGE_SIZE across many frames, each ≤ this cap.
    if (payload_len > @as(u64, MAX_SINGLE_FRAME_PAYLOAD)) return error.FrameTooLarge;
    const payload_len_usize: usize = @intCast(payload_len);

    if (masked) {
        if (data.len < pos + 4) return .incomplete;
        const mask_key = data[pos..][0..4];
        pos += 4;

        const end = std.math.add(usize, pos, payload_len_usize) catch return error.FrameTooLarge;
        if (data.len < end) return .incomplete;

        const payload = data[pos..end];
        // Unmask in-place
        for (payload, 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }

        return .{ .frame = .{
            .frame = .{ .fin = fin, .opcode = opcode, .payload = payload },
            .consumed = end,
        } };
    } else {
        // RFC 6455 §5.1: a server MUST close the connection upon receiving
        // an unmasked frame from a client.
        return error.UnmaskedFrame;
    }
}

/// Serialize a server-to-client WebSocket frame (no mask).
/// Returns the number of bytes written to buf.
pub fn serializeFrame(opcode: Opcode, payload: []const u8, buf: []u8) usize {
    var pos: usize = 0;

    // FIN + opcode
    buf[pos] = 0x80 | @as(u8, @intFromEnum(opcode));
    pos += 1;

    // Payload length (no mask bit for server frames)
    if (payload.len < 126) {
        buf[pos] = @intCast(payload.len);
        pos += 1;
    } else if (payload.len <= 65535) {
        buf[pos] = 126;
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(payload.len), .big);
        pos += 2;
    } else {
        buf[pos] = 127;
        pos += 1;
        std.mem.writeInt(u64, buf[pos..][0..8], @intCast(payload.len), .big);
        pos += 8;
    }

    @memcpy(buf[pos..][0..payload.len], payload);
    pos += payload.len;

    return pos;
}

/// Maximum frame overhead: 1 (fin+opcode) + 9 (extended length) = 10 bytes
pub const MAX_FRAME_OVERHEAD = 10;

/// RFC 6455 §5.3: client frames carry a 4-byte mask key we don't emit ourselves.
const MASK_KEY_SIZE = 4;

/// Largest single (unfragmented) frame payload guaranteed to fit the read
/// buffer in one recv. `config.READ_BUFFER_SIZE` is the hard cap on how much
/// of one frame we can ever hold; a frame declaring more than this can never
/// be assembled, so parseFrame rejects it up front (clean 1009) instead of
/// spinning on `.incomplete` until the buffer fills (#228).
pub const MAX_SINGLE_FRAME_PAYLOAD = config.READ_BUFFER_SIZE - MAX_FRAME_OVERHEAD - MASK_KEY_SIZE;

comptime {
    // Defined here (not config.zig) to avoid an import cycle: ws.zig already
    // imports config.zig for READ_BUFFER_SIZE.
    if (config.READ_BUFFER_SIZE <= MAX_FRAME_OVERHEAD + MASK_KEY_SIZE)
        @compileError("READ_BUFFER_SIZE too small to hold even an empty WS frame");
}

/// Compute the Sec-WebSocket-Accept value per RFC 6455 Section 4.2.2.
/// sec_key: the client's Sec-WebSocket-Key header value
/// out: 28-byte buffer for the base64-encoded result
pub fn computeAcceptKey(sec_key: []const u8, out: *[28]u8) void {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(sec_key);
    hasher.update(magic);
    const digest = hasher.finalResult();

    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Build a close frame with status code.
pub fn serializeCloseFrame(status_code: u16, buf: []u8) usize {
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, status_code, .big);
    return serializeFrame(.close, &payload, buf);
}

// === Tests ===

test "parseFrame - text frame masked" {
    // Build a masked text frame: "Hi"
    var data = [_]u8{
        0x81, // FIN + text
        0x82, // MASK + len=2
        0x37, 0xfa, 0x21, 0x3d, // mask key
        'H' ^ 0x37, 'i' ^ 0xfa, // masked payload
    };

    const result = try parseFrame(&data);
    switch (result) {
        .frame => |f| {
            try std.testing.expect(f.frame.fin);
            try std.testing.expectEqual(Opcode.text, f.frame.opcode);
            try std.testing.expectEqualStrings("Hi", f.frame.payload);
            try std.testing.expectEqual(@as(usize, 8), f.consumed);
        },
        .incomplete => return error.TestUnexpectedResult,
    }
}

test "parseFrame - incomplete" {
    var data = [_]u8{0x81};
    const result = try parseFrame(&data);
    try std.testing.expectEqual(ParseResult.incomplete, result);
}

test "parseFrame - rejects oversized 64-bit length" {
    var data = [_]u8{ 0x81, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.FrameTooLarge, parseFrame(&data));
}

test "parseFrame - unmasked frame rejected (#175)" {
    // RFC 6455 §5.1: server MUST close on an unmasked client frame.
    var data = [_]u8{
        0x89, // FIN + ping
        0x00, // no mask, len=0
    };
    try std.testing.expectError(error.UnmaskedFrame, parseFrame(&data));
}

test "parseFrame - RSV bit set rejected (#175)" {
    // RFC 6455 §5.2: RSV1-3 must be unset; we negotiate no extensions.
    var data = [_]u8{
        0xC1, // FIN + RSV1 + text
        0x82, // MASK + len=2
        0x37, 0xfa, 0x21, 0x3d, // mask key
        'H' ^ 0x37, 'i' ^ 0xfa, // masked payload
    };
    try std.testing.expectError(error.ReservedBitsSet, parseFrame(&data));
}

test "serializeFrame - small text" {
    var buf: [128]u8 = undefined;
    const n = serializeFrame(.text, "Hello", &buf);
    try std.testing.expectEqual(@as(usize, 7), n); // 2 header + 5 payload
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 5), buf[1]); // len=5
    try std.testing.expectEqualStrings("Hello", buf[2..7]);
}

test "serializeFrame - medium payload (126 bytes)" {
    const payload = "a" ** 200;
    var buf: [256]u8 = undefined;
    const n = serializeFrame(.text, payload, &buf);
    try std.testing.expectEqual(@as(usize, 204), n); // 1 + 1 + 2 + 200
    try std.testing.expectEqual(@as(u8, 126), buf[1]); // extended 16-bit length
}

test "computeAcceptKey" {
    // RFC 6455 Section 4.2.2 example
    var out: [28]u8 = undefined;
    computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &out);
}

test "serializeCloseFrame" {
    var buf: [16]u8 = undefined;
    const n = serializeCloseFrame(1000, &buf);
    try std.testing.expectEqual(@as(usize, 4), n); // 2 header + 2 status
    try std.testing.expectEqual(@as(u8, 0x88), buf[0]); // FIN + close
    try std.testing.expectEqual(@as(u8, 2), buf[1]); // len=2
    // Status code 1000 in big-endian
    try std.testing.expectEqual(@as(u8, 0x03), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xE8), buf[3]);
}
