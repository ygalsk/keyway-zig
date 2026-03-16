const std = @import("std");
const xev = @import("xev");
const http = @import("http.zig");
const ws = @import("ws.zig");
const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const cosocket = @import("cosocket.zig");
const params = @import("params.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const castUserdata = @import("helpers.zig").castUserdata;
const Lua = @import("luajit").Lua;
const lua_api = @import("lua_api.zig");
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;

/// WebSocket connection state — set after successful 101 upgrade.
/// Stores Lua callback refs for the duration of the WS connection.
pub const WsState = struct {
    on_message_ref: i32,
    on_close_ref: i32,
};

/// Validate upgrade request, build 101 response, store WsState, send it.
pub fn handleWsUpgrade(conn: *Connection, exchange: *HttpExchange, request: *const http.Request) !void {
    // Validate Sec-WebSocket-Key header
    const sec_key = http.Parser.getHeader(request, "Sec-WebSocket-Key") orelse {
        return error.MissingWebSocketKey;
    };

    const alloc = conn.arena.allocator();

    // Compute accept key
    var accept_key: [28]u8 = undefined;
    // picohttpparser doesn't strip trailing whitespace from header values.
    // If the key has trailing whitespace, the accept hash will be wrong and
    // the browser silently rejects the 101 -> 1006 abnormal closure.
    const sec_key_trimmed = std.mem.trim(u8, sec_key, " \t");
    std.log.debug("ws: sec_key len={d} val=[{s}]", .{ sec_key_trimmed.len, sec_key_trimmed });
    ws.computeAcceptKey(sec_key_trimmed, &accept_key);
    std.log.debug("ws: accept_key=[{s}]", .{&accept_key});

    // Build 101 response
    var resp = http.Response.init(alloc);
    resp.status = 101;
    try resp.addHeader("Upgrade", "websocket");
    try resp.addHeader("Connection", "Upgrade");
    try resp.addHeader("Sec-WebSocket-Accept", &accept_key);

    // Store WsState on connection (copy refs from exchange)
    conn.ws_state = .{
        .on_message_ref = exchange.ws_on_message_ref,
        .on_close_ref = exchange.ws_on_close_ref,
    };
    // Clear exchange refs so they aren't double-freed
    exchange.ws_on_message_ref = 0;
    exchange.ws_on_close_ref = 0;

    conn.logAccess(101);

    // Send 101 — writeResponseDirect sets state to .writing, so we set .websocket
    // AFTER so onWrite dispatches to handleWsPostWrite (starts WS frame read loop).
    try conn.writeResponseDirect(&resp);
    conn.state = .websocket;
}

/// Start reading WebSocket frames from the client.
pub fn startWsRead(conn: *Connection) void {
    // Compact read buffer to reclaim consumed space before checking capacity
    conn.read_buffer.compact();

    // If there's already data in the buffer (e.g., multiple frames in one TCP
    // segment), process it before blocking on recv.
    if (conn.read_buffer.availableRead() > 0) {
        processWsFrames(conn);
        return;
    }

    // After kTLS, ciphertext_buffer is null — recv goes directly to read_buffer
    const buf = if (conn.tls_state.ciphertext_buffer) |*cb| blk: {
        if (cb.availableWrite() == 0) {
            conn.close();
            return;
        }
        break :blk cb.writeSlice();
    } else blk: {
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
        if (self.state == .closing) { self.maybeFinishClose(); return .disarm; }
        std.log.err("ws recv failed err={} eof={}", .{ err, @intFromBool(err == error.EOF) });
        self.close();
        return .disarm;
    };

    if (self.state == .closing) { self.maybeFinishClose(); return .disarm; }

    std.log.debug("ws: recv got {d} bytes", .{bytes_read});

    if (bytes_read == 0) {
        std.log.debug("ws: recv 0 bytes, closing", .{});
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
        std.log.err("ws: ciphertext_buffer recv not supported (need decrypt path)", .{});
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
        std.log.debug("ws: processWsFrames data.len={d}", .{data.len});
        if (data.len == 0) break;

        // parseFrame needs mutable slice for in-place unmasking
        const mutable = @as([*]u8, @constCast(data.ptr))[0..data.len];
        const parse_result = ws.parseFrame(mutable) catch {
            std.log.err("ws: frame parse error, sending close 1002", .{});
            // Send close 1002 (protocol error) and disconnect
            sendWsClose(conn, 1002);
            return;
        };

        switch (parse_result) {
            .incomplete => {
                // Need more data
                startWsRead(conn);
                return;
            },
            .frame => |f| {
                std.log.debug("ws: got frame opcode={d} fin={} payload_len={d} consumed={d}", .{
                    @intFromEnum(f.frame.opcode), f.frame.fin, f.frame.payload.len, f.consumed,
                });
                conn.read_buffer.consume(f.consumed);

                // v1: single-frame messages only
                if (!f.frame.fin) {
                    std.log.err("ws: continuation frame, closing 1003", .{});
                    // Continuation frames not supported — close 1003
                    sendWsClose(conn, 1003);
                    return;
                }

                switch (f.frame.opcode) {
                    .text, .binary => {
                        std.log.debug("ws: dispatching text/binary message", .{});
                        dispatchWsMessage(conn, f.frame.payload);
                        return; // dispatchWsMessage will call startWsRead when done
                    },
                    .ping => {
                        // Auto-pong
                        sendWsFrame(conn, .pong, f.frame.payload);
                    },
                    .pong => {
                        // Ignore unsolicited pongs
                    },
                    .close => {
                        // Echo close frame back, fire on_close callback, disconnect
                        handleWsClose(conn, f.frame.payload);
                        return;
                    },
                    else => {
                        // Unknown opcode — close 1002
                        sendWsClose(conn, 1002);
                        return;
                    },
                }
            },
        }
    }
    // Exhausted buffer, read more
    startWsRead(conn);
}

/// Dispatch a WebSocket message to the Lua on_message callback as a fresh coroutine.
fn dispatchWsMessage(conn: *Connection, payload: []const u8) void {
    std.log.debug("ws: dispatchWsMessage payload_len={d}", .{payload.len});
    const wss = conn.ws_state orelse {
        std.log.err("ws: no ws_state, closing", .{});
        conn.close();
        return;
    };

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

    // Set current_connection so cosocket/ring ops inside on_message work
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
            // Bundle suspended state with a dummy exchange for the resumeHandler interface
            const alloc = conn.arena.allocator();
            const dummy_exchange = alloc.create(HttpExchange) catch {
                conn.close();
                return;
            };
            const response_headers = std.ArrayList(http.Header).initCapacity(alloc, 0) catch {
                conn.close();
                return;
            };
            dummy_exchange.* = .{
                .method = "WS",
                .path = "",
                .headers = &[_]http.Header{},
                .params = &params.ParamArray{},
                .query = &params.QueryArray{},
                .body = "",
                .response_headers = response_headers,
                .allocator = alloc,
            };

            conn.cs.suspended = .{
                .completion = undefined,
                .exchange = dummy_exchange,
                .recv_buf = null,
                .coroutine_ref = conn.lua_state.coroutine_ref,
                .coroutine_thread = @ptrCast(conn.lua_state.coroutine_thread.?),
                .outbound_fd = -1,
                .pending_op = .none,
            };
            conn.lua_state.coroutine_ref = 0;
            conn.lua_state.coroutine_thread = null;

            routeWsYield(conn);
        },
    }
}

/// Take framed WS data from pending_io and send it.
fn submitWsSend(conn: *Connection) void {
    const pending = conn.lua_state.pending_io orelse {
        resumeWithError(conn, "ws_send: no pending I/O");
        return;
    };
    conn.lua_state.pending_io = null;

    // ws_send uses send variant with fd=0 as signal
    const snd = switch (pending) {
        .send => |s| s,
        else => {
            // Unexpected op during WS — close
            conn.close();
            return;
        },
    };

    const raw_data = snd.data;

    // Arena-dupe send_data (Lua string may be GC'd across yield)
    const data = conn.arena.allocator().dupe(u8, raw_data) catch {
        resumeWithError(conn,"ws_send: arena alloc failed");
        return;
    };

    // Serialize as WS text frame
    const frame_buf = conn.arena.allocator().alloc(u8, data.len + ws.MAX_FRAME_OVERHEAD) catch {
        resumeWithError(conn,"ws_send: arena alloc failed");
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
    const s = &self.cs.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushInteger(1);
    wsDispatchResume(self, thread, 1);
    return .disarm;
}

/// Route a WS coroutine yield to the correct I/O path.
/// Ring batch (SQ has entries) vs WS send (pending_io) vs cosocket single-shot.
pub fn routeWsYield(conn: *Connection) void {
    if (conn.lua_state.pending_io != null and conn.cs.sq.len() == 0) {
        submitWsSend(conn);
    } else {
        cosocket.dispatchIo(conn);
    }
}

/// Resume WS coroutine and handle result.
fn wsDispatchResume(conn: *Connection, thread: *Lua, nresults: c_int) void {
    conn.lua_state.current_connection = conn;
    const s = &conn.cs.suspended.?;
    const resume_result = conn.lua_state.resumeHandler(@ptrCast(thread), nresults, s.exchange) catch {
        cosocket.completeHandler(conn);
        return;
    };

    switch (resume_result) {
        .completed => {
            cosocket.completeHandler(conn);
        },
        .yielded => {
            routeWsYield(conn);
        },
    }
}

/// Send a WS frame directly (for pong, close responses).
fn sendWsFrame(conn: *Connection, opcode: ws.Opcode, payload: []const u8) void {
    var frame_buf: [128 + ws.MAX_FRAME_OVERHEAD]u8 = undefined;
    const truncated = if (payload.len > 128) payload[0..128] else payload;
    const frame_len = ws.serializeFrame(opcode, truncated, &frame_buf);

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
    if (self.state == .closing) { self.maybeFinishClose(); return .disarm; }
    self.close();
    return .disarm;
}

/// Handle incoming close frame — fire on_close, echo close back, disconnect.
fn handleWsClose(conn: *Connection, payload: []const u8) void {
    // Fire on_close callback if registered
    if (conn.ws_state) |wss| {
        if (wss.on_close_ref != 0) {
            const lua = conn.lua_state.lua;
            _ = lua.getTableIndexRaw(Lua.PseudoIndex.Registry, wss.on_close_ref);
            lua.callProtected(0, 0, 0) catch {};
        }
    }

    // Extract status code from payload (first 2 bytes) or default to 1000
    const status_code: u16 = if (payload.len >= 2)
        std.mem.readInt(u16, payload[0..2], .big)
    else
        1000;

    // Echo close frame back, then disconnect (onWsCloseSent calls conn.close())
    sendWsClose(conn, status_code);
}

/// Resume coroutine with nil, error_message for pre-submission failures (WS context).
fn resumeWithError(conn: *Connection, msg: [:0]const u8) void {
    const s = &conn.cs.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushNil();
    thread.pushString(msg);
    cosocket.dispatchResume(conn, thread, 2, s.exchange);
}
