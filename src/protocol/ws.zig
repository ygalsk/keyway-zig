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

/// A frame's header, parsed without requiring its payload to be buffered.
/// `payload_len` is the declared length; the payload may still be arriving.
pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    payload_len: usize,
    mask_key: [4]u8,
    header_len: usize,
};

/// Parse just the frame header, which is 2-14 bytes. Returns null when fewer
/// than that many bytes are buffered.
///
/// Split out from parseFrame (#244) so a frame larger than the read buffer can
/// be recognised and drained incrementally instead of being rejected: the
/// header is all you need to start streaming the payload.
pub fn parseFrameHeader(data: []const u8) !?FrameHeader {
    if (data.len < 2) return null;

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
        if (data.len < pos + 2) return null;
        payload_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
    } else if (payload_len == 127) {
        if (data.len < pos + 8) return null;
        payload_len = std.mem.readInt(u64, data[pos..][0..8], .big);
        pos += 8;
    }

    // A frame is at most a whole message, so the message limit bounds it.
    // Rejecting on the declared length means an absurd 64-bit length is a
    // clean 1009 before a single payload byte is buffered.
    if (payload_len > @as(u64, config.WS_MAX_MESSAGE_SIZE)) return error.FrameTooLarge;

    // RFC 6455 §5.1: a server MUST close the connection upon receiving
    // an unmasked frame from a client.
    if (!masked) return error.UnmaskedFrame;
    if (data.len < pos + 4) return null;
    const mask_key = data[pos..][0..4].*;
    pos += 4;

    return FrameHeader{
        .fin = fin,
        .opcode = opcode,
        .payload_len = @intCast(payload_len),
        .mask_key = mask_key,
        .header_len = pos,
    };
}

/// Unmask `payload` in place. `offset` is how many bytes of this frame's
/// payload were already unmasked, so the 4-byte mask phase carries correctly
/// across a chunk boundary that isn't a multiple of 4 (#244).
pub fn unmask(payload: []u8, mask_key: [4]u8, offset: usize) void {
    for (payload, 0..) |*b, i| {
        b.* ^= mask_key[(offset + i) % 4];
    }
}

/// Parse a single WebSocket frame whose payload is fully buffered. Unmasking
/// is done in-place, so the payload is a zero-copy slice of `data`. Callers
/// with a frame too large to buffer use parseFrameHeader + unmask instead.
pub fn parseFrame(data: []u8) !ParseResult {
    const hdr = try parseFrameHeader(data) orelse return .incomplete;

    const end = std.math.add(usize, hdr.header_len, hdr.payload_len) catch return error.FrameTooLarge;
    if (data.len < end) return .incomplete;

    const payload = data[hdr.header_len..end];
    unmask(payload, hdr.mask_key, 0);

    return .{ .frame = .{
        .frame = .{ .fin = hdr.fin, .opcode = hdr.opcode, .payload = payload },
        .consumed = end,
    } };
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

comptime {
    // A frame header (up to 14 bytes) must fit the read buffer, or no frame
    // could ever be parsed. Defined here rather than config.zig to avoid an
    // import cycle: ws.zig already imports config.zig.
    //
    // There is deliberately no cap tying a frame's *payload* to
    // READ_BUFFER_SIZE (#244). A payload larger than the buffer is drained
    // across recvs; the only ceiling is config.WS_MAX_MESSAGE_SIZE, which
    // applies to the message however the sender chose to frame it.
    if (config.READ_BUFFER_SIZE <= MAX_FRAME_OVERHEAD + MASK_KEY_SIZE)
        @compileError("READ_BUFFER_SIZE too small to hold a WS frame header");
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
