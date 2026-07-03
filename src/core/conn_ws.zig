const std = @import("std");
const xev = @import("xev");
const log = @import("../observability/log.zig");
const http = @import("../http/http.zig");
const ws = @import("../protocol/ws.zig");
const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const castUserdata = @import("../util/helpers.zig").castUserdata;
const Lua = @import("luajit").Lua;
const config = @import("../util/config.zig");

/// WebSocket connection state — set after successful 101 upgrade.
/// Stores Lua callback refs and reassembly buffer for fragmented messages.
pub const WsState = struct {
    on_message_ref: i32,
    on_close_ref: i32,
    /// Reassembly buffer for fragmented messages (continuation frames).
    /// Null when no fragmented message is in progress.
    fragment_buf: ?std.ArrayListUnmanaged(u8) = null,
    /// Original opcode of the first fragment (text or binary).
    fragment_opcode: ws.Opcode = .text,
};

/// True if the comma-separated header `value` contains `token` (case-insensitive).
/// RFC 6455 §4.2.1 rules 5-6 phrase the Upgrade/Connection checks this way.
fn headerHasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
    }
    return false;
}

/// Validate upgrade request, build 101 response, store WsState, send it.
pub fn handleWsUpgrade(conn: *Connection, exchange: *HttpExchange, request: *const http.Request) !void {
    // ctx.on_message/on_close are ref'd into the Lua registry before this
    // runs (lua_api.zig). The success path below moves those refs into
    // conn.ws_state and zeroes the exchange copies; every other return from
    // this function is a rejected handshake, and nothing else ever unrefs
    // the exchange copies — so free them here on any path that doesn't
    // zero them first. No-op on success.
    const lua = conn.lua_state.lua;
    defer {
        if (exchange.ws_on_message_ref != 0) lua.unref(Lua.PseudoIndex.Registry, exchange.ws_on_message_ref);
        if (exchange.ws_on_close_ref != 0) lua.unref(Lua.PseudoIndex.Registry, exchange.ws_on_close_ref);
    }

    // RFC 6455 §4.2.1 rule 1: the request line MUST be GET.
    if (!std.mem.eql(u8, request.method, "GET")) {
        return error.InvalidWsMethod;
    }

    const alloc = conn.arena.allocator();

    // RFC 6455 §4.4: on an unsupported version, respond 426 with the
    // version we support instead of failing the handshake generically.
    const version_hdr = http.getHeader(request, "Sec-WebSocket-Version");
    const version = if (version_hdr) |v| std.mem.trim(u8, v, " \t") else null;
    if (version == null or !std.mem.eql(u8, version.?, "13")) {
        // Raw response: the engine authors this handshake reply and it carries an
        // engine-owned Connection header that Response.serialize strips from
        // tenant output — so emit it verbatim here (#194).
        conn.logAccess(426);
        // Advertises Connection: close; flag so onWrite actually closes
        // instead of recycling the socket (#180).
        conn.close_after_write = true;
        conn.sendRawResponse("HTTP/1.1 426 Upgrade Required\r\nSec-WebSocket-Version: 13\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        return;
    }

    // RFC 6455 §4.2.1 rules 5-6: Upgrade/Connection headers must carry the
    // upgrade tokens (case-insensitive, possibly comma-separated).
    const upgrade_hdr = http.getHeader(request, "Upgrade") orelse return error.MissingUpgradeHeader;
    if (!headerHasToken(upgrade_hdr, "websocket")) return error.InvalidUpgradeHeader;

    const connection_hdr = http.getHeader(request, "Connection") orelse return error.MissingConnectionHeader;
    if (!headerHasToken(connection_hdr, "upgrade")) return error.InvalidConnectionHeader;

    // Validate Sec-WebSocket-Key header
    const sec_key = http.getHeader(request, "Sec-WebSocket-Key") orelse {
        return error.MissingWebSocketKey;
    };

    // Compute accept key
    var accept_key: [28]u8 = undefined;
    // picohttpparser doesn't strip trailing whitespace from header values.
    // If the key has trailing whitespace, the accept hash will be wrong and
    // the browser silently rejects the 101 -> 1006 abnormal closure.
    const sec_key_trimmed = std.mem.trim(u8, sec_key, " \t");
    log.debug().string("msg", "ws sec_key").int("len", sec_key_trimmed.len).string("val", sec_key_trimmed).log();
    ws.computeAcceptKey(sec_key_trimmed, &accept_key);
    log.debug().string("msg", "ws accept_key").string("val", &accept_key).log();

    // Build the 101 handshake as a raw response. It carries engine-owned
    // Upgrade/Connection headers that Response.serialize strips from tenant
    // output, so serialize must not see it — which also lets serialize drop its
    // status==101 special-cases entirely (#194).
    const raw_101 = try std.fmt.allocPrint(alloc, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{&accept_key});

    // Store WsState on connection (copy refs from exchange)
    conn.ws_state = .{
        .on_message_ref = exchange.ws_on_message_ref,
        .on_close_ref = exchange.ws_on_close_ref,
    };
    // Clear exchange refs so they aren't double-freed
    exchange.ws_on_message_ref = 0;
    exchange.ws_on_close_ref = 0;

    conn.logAccess(101);

    // sendRawResponse sets state to .writing; set .websocket AFTER so onWrite
    // dispatches to handleWsPostWrite (starts the WS frame read loop).
    conn.sendRawResponse(raw_101);
    conn.state = .websocket;
}

/// Start reading WebSocket frames from the client.
pub fn startWsRead(conn: *Connection) void {
    // If there's already data in the buffer (e.g., multiple frames in one TCP
    // segment), process it before blocking on recv.
    if (conn.read_buffer.availableRead() > 0) {
        processWsFrames(conn);
        return;
    }

    armWsRecv(conn);
}

/// Arm a recv even when partial frame bytes are already buffered.
fn armWsRecv(conn: *Connection) void {
    conn.read_buffer.compact();

    // After kTLS, ciphertext_buffer is null — recv goes directly to read_buffer
    const buf = if (conn.tls_state.ciphertext_buffer) |*cb| blk: {
        if (cb.availableWrite() == 0) {
            conn.close();
            return;
        }
        break :blk cb.writeSlice();
    } else blk: {
        // Defensive fallback: parseFrame now rejects any single frame whose
        // declared length exceeds ws.MAX_SINGLE_FRAME_PAYLOAD before this
        // point, so a legal frame should never fill the buffer without
        // completing (#228). A bare close() here would still mean a bug
        // upstream, not an expected path.
        if (conn.read_buffer.availableWrite() == 0) {
            conn.close();
            return;
        }
        break :blk conn.read_buffer.writeSlice();
    };

    conn.read_completion = .{
        .op = .{ .recv = .{ .fd = conn.socket, .buffer = .{ .slice = buf } } },
        .userdata = conn,
        .callback = onWsRead,
    };
    conn.pending_io_ops += 1;
    conn.loop.add(&conn.read_completion);
}

/// xev callback for WebSocket frame reads.
fn onWsRead(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const self = castUserdata(Connection, userdata);
    self.pending_io_ops -= 1;

    const bytes_read = result.recv catch |err| {
        if (self.state == .closing) {
            self.maybeFinishClose();
            return .disarm;
        }
        log.err().string("msg", "ws recv failed").err(err).log();
        self.close();
        return .disarm;
    };

    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }

    log.debug().string("msg", "ws recv").int("bytes", bytes_read).log();

    if (bytes_read == 0) {
        log.debug().string("msg", "ws recv 0 bytes, closing").log();
        self.close();
        return .disarm;
    }

    // Commit to the buffer that actually received the data.
    // With kTLS active, ciphertext_buffer is null and recv goes to read_buffer
    // with kernel-transparent decryption. Pre-kTLS TLS connections would recv
    // into ciphertext_buffer and need userspace decrypt — not yet supported for WS.
    if (self.tls_state.ciphertext_buffer) |*cb| {
        cb.commitWrite(bytes_read);
        // TODO: userspace TLS decrypt path for WS (pre-kTLS connections)
        log.err().string("msg", "ws ciphertext_buffer recv not supported (need decrypt path)").log();
        self.close();
        return .disarm;
    } else {
        self.read_buffer.commitWrite(bytes_read);
    }

    processWsFrames(self);
    return .disarm;
}

/// Process complete WebSocket frames from the read buffer.
pub fn processWsFrames(conn: *Connection) void {
    while (true) {
        const data = conn.read_buffer.readSlice();
        log.debug().string("msg", "ws processWsFrames").int("data_len", data.len).log();
        if (data.len == 0) break;

        // parseFrame needs mutable slice for in-place unmasking
        const mutable = @as([*]u8, @constCast(data.ptr))[0..data.len];
        const parse_result = ws.parseFrame(mutable) catch |err| {
            if (err == error.FrameTooLarge) {
                log.err().string("msg", "ws frame too large, sending close 1009").log();
                sendWsClose(conn, 1009);
            } else {
                log.err().string("msg", "ws frame parse error, sending close 1002").log();
                sendWsClose(conn, 1002);
            }
            return;
        };

        switch (parse_result) {
            .incomplete => {
                // Need more data
                armWsRecv(conn);
                return;
            },
            .frame => |f| {
                log.debug().string("msg", "ws got frame").int("opcode", @intFromEnum(f.frame.opcode)).int("payload_len", f.frame.payload.len).int("consumed", f.consumed).log();
                conn.read_buffer.consume(f.consumed);
                const wss = &conn.ws_state.?;

                // Handle control frames immediately (RFC 6455 §5.5):
                // control frames can be interleaved during fragmentation
                if ((f.frame.opcode == .ping or f.frame.opcode == .pong or f.frame.opcode == .close) and
                    (!f.frame.fin or f.frame.payload.len > 125))
                {
                    // RFC 6455 §5.5: control frames MUST NOT be fragmented
                    // and MUST carry a payload of 125 bytes or fewer.
                    sendWsClose(conn, 1002);
                    return;
                }

                switch (f.frame.opcode) {
                    .ping => {
                        // sendWsFrame submits a send — must return, not continue
                        // (#224): looping straight to the next buffered frame
                        // would process it while the pong send is still in
                        // flight, clobbering write_completion. onWsControlSent
                        // re-enters processWsFrames once the pong actually lands.
                        sendWsFrame(conn, .pong, f.frame.payload) catch {
                            sendWsClose(conn, 1002);
                            return;
                        };
                        return;
                    },
                    .pong => continue, // no send submitted — safe to keep draining buffered frames
                    .close => {
                        handleWsClose(conn, f.frame.payload);
                        return;
                    },
                    else => {},
                }

                // Data frames: handle fragmentation (RFC 6455 §5.4)
                if (f.frame.opcode == .text or f.frame.opcode == .binary) {
                    if (f.frame.fin) {
                        // Single-frame message (common case)
                        if (wss.fragment_buf != null) {
                            // Protocol error: new message while fragmented message in progress
                            sendWsClose(conn, 1002);
                            return;
                        }
                        dispatchWsMessage(conn, f.frame.payload, f.frame.opcode == .text);
                        return;
                    }
                    // First fragment of a multi-frame message
                    if (wss.fragment_buf != null) {
                        sendWsClose(conn, 1002); // already in a fragmented message
                        return;
                    }
                    wss.fragment_opcode = f.frame.opcode;
                    const alloc = conn.arena.allocator();
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    buf.appendSlice(alloc, f.frame.payload) catch {
                        sendWsClose(conn, 1011);
                        return;
                    };
                    wss.fragment_buf = buf;
                } else if (f.frame.opcode == .continuation) {
                    var fb = wss.fragment_buf orelse {
                        // Continuation without a starting fragment
                        sendWsClose(conn, 1002);
                        return;
                    };
                    // Check reassembled size limit
                    if (fb.items.len + f.frame.payload.len > config.WS_MAX_MESSAGE_SIZE) {
                        fb.deinit(conn.arena.allocator());
                        wss.fragment_buf = null;
                        sendWsClose(conn, 1009); // message too big
                        return;
                    }
                    fb.appendSlice(conn.arena.allocator(), f.frame.payload) catch {
                        fb.deinit(conn.arena.allocator());
                        wss.fragment_buf = null;
                        sendWsClose(conn, 1011);
                        return;
                    };
                    wss.fragment_buf = fb;
                    if (f.frame.fin) {
                        // Final fragment — dispatch the reassembled message
                        const payload = conn.base_allocator.dupe(u8, fb.items) catch {
                            fb.deinit(conn.arena.allocator());
                            wss.fragment_buf = null;
                            sendWsClose(conn, 1011);
                            return;
                        };
                        defer conn.base_allocator.free(payload);
                        fb.deinit(conn.arena.allocator());
                        wss.fragment_buf = null;
                        dispatchWsMessage(conn, payload, wss.fragment_opcode == .text);
                        return;
                    }
                } else {
                    // Unknown data opcode
                    sendWsClose(conn, 1002);
                    return;
                }
            },
        }
    }
    // Exhausted buffer, read more
    startWsRead(conn);
}

/// Dispatch a WebSocket message to the Lua on_message callback as a fresh coroutine.
/// `is_text` is true for a (possibly reassembled) text message; binary messages
/// are exempt from UTF-8 validation.
fn dispatchWsMessage(conn: *Connection, payload: []const u8, is_text: bool) void {
    log.debug().string("msg", "ws dispatchWsMessage").int("payload_len", payload.len).log();
    const wss = conn.ws_state orelse {
        log.err().string("msg", "ws no ws_state, closing").log();
        conn.close();
        return;
    };

    // RFC 6455 §8.1: a text message — including one reassembled from
    // continuation frames — must be valid UTF-8, checked on the reassembled
    // result since a multi-byte codepoint may split across fragments.
    if (is_text and !std.unicode.utf8ValidateSlice(payload)) {
        sendWsClose(conn, 1007);
        return;
    }

    if (wss.on_message_ref == 0) {
        // No callback registered — just continue reading
        startWsRead(conn);
        return;
    }

    _ = conn.arena.reset(.retain_capacity);

    // After WS upgrade, request_method/request_path are stale slices into the
    // overwritten read buffer. Set stable string literals so error logging
    // (e.g. error_response.sendError) doesn't read garbage.
    conn.http_state.request_method = "WS";
    conn.http_state.request_path = "/ws";

    const payload_copy = conn.arena.allocator().dupe(u8, payload) catch {
        conn.close();
        return;
    };

    // Set current_connection so ws_send/sse_broadcast calls inside on_message work
    conn.lua_state.current_connection = conn;

    // Dispatch via shared coroutine infrastructure
    const result = conn.lua_state.dispatchCoroutine(
        wss.on_message_ref,
        .{ .ws = .{ .message = payload_copy } },
    ) catch {
        conn.lua_state.current_connection = null;
        startWsRead(conn);
        return;
    };

    switch (result) {
        .completed => {
            conn.lua_state.current_connection = null;
            startWsRead(conn);
        },
        .yielded => {
            conn.suspended = .{
                .exchange = null,
                .coroutine_ref = conn.lua_state.coroutine_ref,
                .coroutine_thread = @ptrCast(conn.lua_state.coroutine_thread.?),
            };
            conn.lua_state.coroutine_ref = 0;
            conn.lua_state.coroutine_thread = null;

            routeWsYield(conn);
        },
    }
}

/// Take the pending WS send payload and frame+send it.
fn submitWsSend(conn: *Connection) void {
    const raw_data = conn.lua_state.pending_ws_send orelse {
        conn.resumeWithError(.server_error, "ws_send: no pending I/O");
        return;
    };
    conn.lua_state.pending_ws_send = null;

    // Arena-dupe send_data (Lua string may be GC'd across yield)
    const data = conn.arena.allocator().dupe(u8, raw_data) catch {
        conn.resumeWithError(.server_error, "ws_send: arena alloc failed");
        return;
    };

    // Serialize as WS text frame
    const frame_buf = conn.arena.allocator().alloc(u8, data.len + ws.MAX_FRAME_OVERHEAD) catch {
        conn.resumeWithError(.server_error, "ws_send: arena alloc failed");
        return;
    };
    const frame_len = ws.serializeFrame(.text, data, frame_buf);
    const frame_data = frame_buf[0..frame_len];

    // frame_data is arena-owned, no dupe needed
    conn.submitSend(frame_data, onWsSendComplete, false);
}

/// xev callback after WS frame send completes.
fn onWsSendComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;

    // Resume coroutine with success
    const s = &self.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushInteger(1);
    self.dispatchResume(thread, 1);
    return .disarm;
}

/// Route a WS coroutine yield to the correct path: a pending ws:send() gets
/// framed and sent; a bare yield with nothing pending resumes with an error.
pub fn routeWsYield(conn: *Connection) void {
    if (conn.lua_state.pending_ws_send != null) {
        submitWsSend(conn);
    } else {
        conn.resumeWithError(.server_error, "no pending I/O operation");
    }
}

/// Send a WS control frame (currently only pong). RFC 6455 §5.5: control-frame
/// payloads MUST be 125 bytes or fewer — reject rather than silently
/// truncate, since truncating a pong would echo the wrong payload back.
fn sendWsFrame(conn: *Connection, opcode: ws.Opcode, payload: []const u8) !void {
    if (payload.len > 125) return error.ControlFramePayloadTooLarge;
    var frame_buf: [125 + ws.MAX_FRAME_OVERHEAD]u8 = undefined;
    const frame_len = ws.serializeFrame(opcode, payload, &frame_buf);

    conn.submitSend(frame_buf[0..frame_len], onWsControlSent, true);
}

/// Callback after sending a WS control frame (pong). Continue reading.
fn onWsControlSent(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;
    processWsFrames(self);
    return .disarm;
}

/// Send a close frame with status code and disconnect.
pub fn sendWsClose(conn: *Connection, status_code: u16) void {
    var buf: [16]u8 = undefined;
    const n = ws.serializeCloseFrame(status_code, &buf);

    conn.submitSend(buf[0..n], onWsCloseSent, true);
}

/// Callback after sending close frame — disconnect.
fn onWsCloseSent(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    _ = result;
    const self = castUserdata(Connection, userdata);
    self.pending_io_ops -= 1;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    self.close();
    return .disarm;
}

/// RFC 6455 §7.4.1: valid application close codes. 1004-1006 and 1012-1015
/// are reserved and MUST NOT appear on the wire; 3000-4999 are
/// library/framework-registered or private-use.
fn isValidCloseCode(code: u16) bool {
    return switch (code) {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011 => true,
        3000...4999 => true,
        else => false,
    };
}

/// Handle incoming close frame — fire on_close, echo close back, disconnect.
fn handleWsClose(conn: *Connection, payload: []const u8) void {
    // RFC 6455 §7.4.1: a close code, if present, must be a 2-byte payload;
    // a lone 1-byte payload is a protocol error.
    if (payload.len == 1) {
        sendWsClose(conn, 1002);
        return;
    }

    const status_code: u16 = if (payload.len >= 2)
        std.mem.readInt(u16, payload[0..2], .big)
    else
        1000;

    if (payload.len >= 2 and !isValidCloseCode(status_code)) {
        sendWsClose(conn, 1002);
        return;
    }

    // RFC 6455 §7.4.1 / Autobahn 7.5.1: the close reason, if present, must
    // be valid UTF-8.
    if (payload.len > 2 and !std.unicode.utf8ValidateSlice(payload[2..])) {
        sendWsClose(conn, 1007);
        return;
    }

    // Fire on_close callback if registered
    if (conn.ws_state) |wss| {
        if (wss.on_close_ref != 0) {
            const lua = conn.lua_state.lua;
            _ = lua.getTableIndexRaw(Lua.PseudoIndex.Registry, wss.on_close_ref);
            lua.callProtected(0, 0, 0) catch {};
        }
    }

    // Echo close frame back, then disconnect (onWsCloseSent calls conn.close())
    sendWsClose(conn, status_code);
}
