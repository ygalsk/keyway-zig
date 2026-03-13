const std = @import("std");
const xev = @import("xev");
const handler = @import("handler.zig");
const Connection = handler.Connection;
const castUserdata = @import("helpers.zig").castUserdata;
const HttpExchange = @import("http_exchange.zig").HttpExchange;

/// SSE connection state — set after successful SSE upgrade.
/// Stores room name for unsubscribe on disconnect.
pub const SseState = struct {
    room: []const u8, // duped into base_allocator
};

/// Handle SSE upgrade: send headers, set state, subscribe to registry.
pub fn handleSseUpgrade(self: *Connection, exchange: *HttpExchange) void {
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

    // Set SSE state before sending headers (onWrite checks this)
    self.sse_state = .{ .room = room_dupe };

    // Subscribe to SSE registry
    if (self.sse_registry) |reg| {
        reg.subscribe(room_dupe, self) catch {
            self.base_allocator.free(room_dupe);
            self.sse_state = null;
            self.send500InternalError();
            return;
        };
    }

    self.logAccess(200);

    // Manually serialize SSE headers (no Content-Length — streaming)
    const sse_headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n";
    if (!self.submitTlsAwareSend(sse_headers, onWrite, true)) {
        self.close();
    }
}

/// Start watching for client disconnect (recv that returns EOF/error).
pub fn startSseDisconnectWatch(self: *Connection) void {
    // Use read_buffer for the disconnect recv — any data from client means disconnect
    const buf = self.read_buffer.writeSlice();
    self.sse_disconnect_completion = .{
        .op = .{ .recv = .{ .fd = self.socket, .buffer = .{ .slice = buf } } },
        .userdata = self,
        .callback = onSseDisconnect,
    };
    self.loop.add(&self.sse_disconnect_completion);
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
    const bytes = result.recv catch {
        self.close();
        return .disarm;
    };
    // EOF (0 bytes) or unexpected client data — close the SSE connection
    _ = bytes;
    self.close();
    return .disarm;
}

/// Queue an SSE event for sending. Called by SseRegistry.broadcast.
pub fn submitSseSend(self: *Connection, data: []const u8) void {
    if (self.state == .closing) return;

    // Dupe data into base_allocator (caller's data is temporary)
    const duped = self.base_allocator.dupe(u8, data) catch return;
    self.sse_send_queue.append(self.base_allocator, duped) catch {
        self.base_allocator.free(duped);
        return;
    };
    if (!self.sse_writing) {
        drainSseQueue(self);
    }
}

/// Send the next queued SSE event.
pub fn drainSseQueue(self: *Connection) void {
    if (self.sse_drain_index >= self.sse_send_queue.items.len) {
        // Fully drained — reset queue
        self.sse_send_queue.items.len = 0;
        self.sse_drain_index = 0;
        self.sse_writing = false;
        return;
    }

    // O(1) dequeue: read at drain_index, advance
    const data = self.sse_send_queue.items[self.sse_drain_index];
    self.sse_drain_index += 1;
    self.sse_writing = true;

    if (!self.submitTlsAwareSend(data, onSseSendComplete, true)) {
        self.base_allocator.free(data);
        self.close();
        return;
    }
    self.base_allocator.free(data);
}

/// Callback after SSE event chunk is sent — drain next from queue.
fn onSseSendComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    _ = result.send catch {
        self.close();
        return .disarm;
    };
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
    _ = result.send catch {
        self.close();
        return .disarm;
    };
    // SSE headers sent — start watching for client disconnect
    startSseDisconnectWatch(self);
    return .disarm;
}

// Tests for conn_sse require a fully initialized Connection (xev.Loop, socket,
// buffers, SSE registry) so unit tests are not feasible here. SSE upgrade and
// broadcast are covered by integration tests against the running server.

/// Clean up SSE state on connection close.
pub fn deinitSse(self: *Connection) void {
    if (self.sse_state) |sss| {
        if (self.sse_registry) |reg| reg.unsubscribe(sss.room, self);
        self.base_allocator.free(sss.room);
    }
    for (self.sse_send_queue.items) |queued| {
        self.base_allocator.free(queued);
    }
    self.sse_send_queue.deinit(self.base_allocator);
}
