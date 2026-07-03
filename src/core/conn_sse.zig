const std = @import("std");
const xev = @import("xev");
const handler = @import("handler.zig");
const Connection = handler.Connection;
const castUserdata = @import("../util/helpers.zig").castUserdata;
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const SseRegistry = @import("../protocol/sse.zig").SseRegistry;
const config = @import("../util/config.zig");
const Lua = @import("luajit").Lua;

/// SSE connection state — set after successful SSE upgrade.
/// Holds all SSE-specific fields; Connection.sse_state is ?SseState = null.
/// Lifecycle: created at upgrade, destroyed by deinit(conn) on close.
pub const SseState = struct {
    room: []const u8, // duped into base_allocator
    registry: ?*SseRegistry,
    send_queue: std.ArrayListUnmanaged([]const u8),
    drain_index: usize,
    writing: bool,
    disconnect_completion: xev.Completion,
    // Buffer currently owned by the in-flight async send (base_allocator),
    // freed by onSseSendComplete once the write finishes. (#173)
    in_flight: ?[]const u8 = null,
    // Bytes queued but not yet sent, not counting in_flight. Caps memory for
    // a slow consumer — see SSE_MAX_QUEUED_BYTES. (#173)
    queued_bytes: usize = 0,

    /// Clean up SSE state on connection close.
    /// Order: unsubscribe first (uses room as key), free room, free in-flight
    /// send buffer, free queue items, deinit queue.
    pub fn deinit(self: *SseState, conn: *Connection) void {
        if (self.registry) |reg| reg.unsubscribe(self.room, conn);
        conn.base_allocator.free(self.room);
        if (self.in_flight) |buf| conn.base_allocator.free(buf);
        for (self.send_queue.items[self.drain_index..]) |queued| conn.base_allocator.free(queued);
        self.send_queue.deinit(conn.base_allocator);
    }
};

/// Handle SSE upgrade: send headers, set state, subscribe to registry.
pub fn handleSseUpgrade(self: *Connection, exchange: *HttpExchange) void {
    // ctx.on_message/on_close are ref'd into the Lua registry before this
    // runs (lua_api.zig), but SSE never uses them — SseState has no callback
    // fields (#175 is WS's twin: it moves the refs into WsState on success).
    // Free them here on every return from this function so a handler that
    // sets both then upgrades to SSE doesn't pin them in the registry
    // forever (#192).
    const lua = self.lua_state.lua;
    defer {
        if (exchange.ws_on_message_ref != 0) lua.unref(Lua.PseudoIndex.Registry, exchange.ws_on_message_ref);
        if (exchange.ws_on_close_ref != 0) lua.unref(Lua.PseudoIndex.Registry, exchange.ws_on_close_ref);
    }

    const room = exchange.sse_room;
    if (room.len == 0) {
        self.logAccess(400);
        self.send400BadRequest();
        return;
    }

    // Dupe room name into base_allocator (arena will be reused)
    const room_dupe = self.base_allocator.dupe(u8, room) catch {
        self.send500InternalError();
        return;
    };

    // Set SSE state before sending headers (onWrite dispatches via state enum)
    self.sse_state = .{
        .room = room_dupe,
        .registry = self.sse_registry,
        .send_queue = .empty,
        .drain_index = 0,
        .writing = false,
        .disconnect_completion = undefined,
    };
    self.state = .sse;

    // Subscribe to SSE registry
    if (self.sse_registry) |reg| {
        reg.subscribe(room_dupe, self) catch {
            self.base_allocator.free(room_dupe);
            self.sse_state = null;
            self.state = .processing;
            self.send500InternalError();
            return;
        };
    }

    self.logAccess(200);

    // Manually serialize SSE headers (no Content-Length — streaming)
    const sse_headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n";
    self.submitSend(sse_headers, onWrite, true);
}

/// Start watching for client disconnect (recv that returns EOF/error).
pub fn startSseDisconnectWatch(self: *Connection) void {
    const ss = &self.sse_state.?;
    // Use read_buffer for the disconnect recv — any data from client means disconnect
    const buf = self.read_buffer.writeSlice();
    ss.disconnect_completion = .{
        .op = .{ .recv = .{ .fd = self.socket, .buffer = .{ .slice = buf } } },
        .userdata = self,
        .callback = onSseDisconnect,
    };
    self.pending_io_ops += 1;
    self.loop.add(&ss.disconnect_completion);
}

/// Callback when SSE client disconnects (or sends any data).
fn onSseDisconnect(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    self.pending_io_ops -= 1;
    const bytes = result.recv catch {
        if (self.state == .closing) {
            self.maybeFinishClose();
            return .disarm;
        }
        self.close();
        return .disarm;
    };
    // EOF (0 bytes) or unexpected client data — close the SSE connection
    _ = bytes;
    if (self.state == .closing) {
        self.maybeFinishClose();
        return .disarm;
    }
    self.close();
    return .disarm;
}

/// Queue an SSE event for sending. Called by SseRegistry.broadcast.
/// A subscriber that isn't draining fast enough (queued_bytes exceeds the
/// cap) is disconnected rather than buffered further — dropping individual
/// events would silently corrupt the stream. (#173)
pub fn submitSseSend(self: *Connection, data: []const u8) void {
    if (self.state == .closing) return;
    const ss = &self.sse_state.?;

    if (ss.queued_bytes + data.len > config.SSE_MAX_QUEUED_BYTES) {
        self.close();
        return;
    }

    // Dupe data into base_allocator (caller's data is temporary)
    const duped = self.base_allocator.dupe(u8, data) catch return;
    ss.send_queue.append(self.base_allocator, duped) catch {
        self.base_allocator.free(duped);
        return;
    };
    ss.queued_bytes += duped.len;
    if (!ss.writing) {
        drainSseQueue(self);
    }
}

/// Send the next queued SSE event.
pub fn drainSseQueue(self: *Connection) void {
    const ss = &self.sse_state.?;
    if (ss.drain_index >= ss.send_queue.items.len) {
        // Fully drained — reset queue
        ss.send_queue.items.len = 0;
        ss.drain_index = 0;
        ss.writing = false;
        return;
    }

    // O(1) dequeue: read at drain_index, advance
    const data = ss.send_queue.items[ss.drain_index];
    ss.drain_index += 1;
    ss.writing = true;
    ss.queued_bytes -= data.len;

    // No arena dupe: the SSE connection's arena is never reset for its
    // lifetime (long-lived), so an arena copy per event would leak. Send the
    // base_allocator buffer directly and free it once the write completes. (#173)
    ss.in_flight = data;
    self.submitSend(data, onSseSendComplete, false);
}

/// Callback after SSE event chunk is sent — free the in-flight buffer, then
/// drain next from queue.
fn onSseSendComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    const ss = &self.sse_state.?;
    // Free before handleSendCompletion: on error it may close+deinit self
    // synchronously, after which self is no longer safe to touch.
    if (ss.in_flight) |buf| {
        self.base_allocator.free(buf);
        ss.in_flight = null;
    }
    _ = self.handleSendCompletion(result) orelse return .disarm;
    drainSseQueue(self);
    return .disarm;
}

/// xev callback for the initial SSE headers write.
/// After headers are sent, the onWrite in handler.zig checks sse_state and calls
/// startSseDisconnectWatch via conn_sse.
fn onWrite(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;
    // SSE headers sent — start watching for client disconnect
    startSseDisconnectWatch(self);
    return .disarm;
}

// Tests for conn_sse require a fully initialized Connection (xev.Loop, socket,
// buffers, SSE registry) so unit tests are not feasible here. SSE upgrade and
// broadcast are covered by integration tests against the running server.
