const std = @import("std");
const xev = @import("xev");
const config = @import("config.zig");
const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const conn_sse = handler_mod.conn_sse;

/// Per-worker registry mapping room names to lists of SSE connections.
/// No cross-thread sharing — each worker has its own SseRegistry.
pub const SseRegistry = struct {
    rooms: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*Connection)),
    allocator: std.mem.Allocator,
    bus: ?*SseBroadcastBus = null,
    worker_id: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SseRegistry {
        return .{
            .rooms = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SseRegistry) void {
        var it = self.rooms.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.rooms.deinit(self.allocator);
    }

    /// Add a connection to a room's subscriber list.
    pub fn subscribe(self: *SseRegistry, room: []const u8, conn: *Connection) !void {
        const gop = try self.rooms.getOrPut(self.allocator, room);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, room);
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(self.allocator, conn);
    }

    /// Remove a connection from a room's subscriber list.
    pub fn unsubscribe(self: *SseRegistry, room: []const u8, conn: *Connection) void {
        const list = self.rooms.getPtr(room) orelse return;
        for (list.items, 0..) |item, i| {
            if (item == conn) {
                _ = list.swapRemove(i);
                return;
            }
        }
    }

    /// Broadcast to THIS worker's SSE subscribers only (called from event loop).
    fn broadcastLocal(self: *SseRegistry, room: []const u8, data: []const u8) void {
        const list = self.rooms.getPtr(room) orelse return;

        // Format SSE event: "data: {payload}\n\n"
        const formatted = std.fmt.allocPrint(self.allocator, "data: {s}\n\n", .{data}) catch return;
        defer self.allocator.free(formatted);

        var i: usize = list.items.len;
        while (i > 0) {
            i -= 1;
            conn_sse.submitSseSend(list.items[i], formatted);
        }
    }

    /// Broadcast to ALL workers via the shared bus.
    /// Called from handler context (any worker thread).
    pub fn broadcast(self: *SseRegistry, room: []const u8, data: []const u8) void {
        if (self.bus) |bus| {
            bus.publish(room, data);
        } else {
            // No bus (single-worker or test) — local only
            self.broadcastLocal(room, data);
        }
    }
};

/// Cross-worker SSE broadcast bus.
/// Each worker has an inbox (mutex-protected) and an xev.Async notifier.
/// publish() pushes to all inboxes and notifies all workers.
/// Workers drain their inbox in the event loop callback.
pub const SseBroadcastBus = struct {
    const MAX_WORKERS = config.SSE_MAX_WORKERS;

    const Message = struct {
        room: []const u8,
        data: []const u8,
    };

    const WorkerSlot = struct {
        inbox: std.ArrayListUnmanaged(Message) = .{},
        mutex: std.Thread.Mutex = .{},
        notifier: xev.Async = undefined,
        completion: xev.Completion = undefined,
        registry: ?*SseRegistry = null,
        loop: ?*xev.Loop = null,
        allocator: std.mem.Allocator = undefined,
        ready: bool = false,
    };

    slots: []WorkerSlot,
    num_workers: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_workers: usize) !*SseBroadcastBus {
        const bus = try allocator.create(SseBroadcastBus);
        errdefer allocator.destroy(bus);

        const slots = try allocator.alloc(WorkerSlot, num_workers);
        for (slots) |*slot| {
            slot.* = .{ .allocator = allocator };
            slot.notifier = try xev.Async.init();
        }

        bus.* = .{
            .slots = slots,
            .num_workers = num_workers,
            .allocator = allocator,
        };
        return bus;
    }

    pub fn deinit(self: *SseBroadcastBus) void {
        for (self.slots) |*slot| {
            slot.mutex.lock();
            for (slot.inbox.items) |msg| {
                self.allocator.free(msg.room);
                self.allocator.free(msg.data);
            }
            slot.inbox.deinit(self.allocator);
            slot.mutex.unlock();
            slot.notifier.deinit();
        }
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    /// Called by each worker during setup to register itself.
    pub fn registerWorker(
        self: *SseBroadcastBus,
        worker_id: usize,
        registry: *SseRegistry,
        loop: *xev.Loop,
    ) void {
        const slot = &self.slots[worker_id];
        slot.registry = registry;
        slot.loop = loop;
        slot.notifier.wait(loop, &slot.completion, SseBroadcastBus, self, onNotify);
        slot.ready = true;
    }

    /// Publish a message to all workers' inboxes and wake their event loops.
    pub fn publish(self: *SseBroadcastBus, room: []const u8, data: []const u8) void {
        for (self.slots[0..self.num_workers]) |*slot| {
            if (!slot.ready) continue;

            // Dupe per-slot (each worker frees its own copy)
            const room_dupe = self.allocator.dupe(u8, room) catch continue;
            const data_dupe = self.allocator.dupe(u8, data) catch {
                self.allocator.free(room_dupe);
                continue;
            };

            slot.mutex.lock();
            slot.inbox.append(self.allocator, .{ .room = room_dupe, .data = data_dupe }) catch {
                self.allocator.free(room_dupe);
                self.allocator.free(data_dupe);
                slot.mutex.unlock();
                continue;
            };
            slot.mutex.unlock();

            slot.notifier.notify() catch {};
        }
    }

    /// Return subscriber count for a room (used in tests).
    pub fn subscriberCount(self: *SseRegistry, room: []const u8) usize {
        const list = self.rooms.getPtr(room) orelse return 0;
        return list.items.len;
    }

    /// xev.Async callback — fires on the worker's event loop thread.
    fn onNotify(
        self_opt: ?*SseBroadcastBus,
        loop: *xev.Loop,
        completion: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch return .disarm;
        const self = self_opt orelse return .disarm;

        // Find which slot this completion belongs to
        for (self.slots[0..self.num_workers]) |*slot| {
            if (completion == &slot.completion) {
                const registry = slot.registry orelse continue;

                // Drain inbox under lock
                slot.mutex.lock();
                // Swap out the inbox for a fresh one so we can release the lock quickly
                var messages = slot.inbox;
                slot.inbox = .{};
                slot.mutex.unlock();

                for (messages.items) |msg| {
                    registry.broadcastLocal(msg.room, msg.data);
                    self.allocator.free(msg.room);
                    self.allocator.free(msg.data);
                }
                messages.deinit(self.allocator);

                // Re-arm the async watcher
                slot.notifier.wait(loop, &slot.completion, SseBroadcastBus, self, onNotify);
                return .disarm;
            }
        }
        return .disarm;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SseRegistry subscribe and unsubscribe" {
    const allocator = std.testing.allocator;
    var reg = SseRegistry.init(allocator);
    defer reg.deinit();

    // Use opaque pointers as fake Connection handles (never dereferenced)
    const fake_conn_a: *Connection = @ptrFromInt(0xDEAD_0001);
    const fake_conn_b: *Connection = @ptrFromInt(0xDEAD_0002);

    try reg.subscribe("chat", fake_conn_a);
    try reg.subscribe("chat", fake_conn_b);
    try std.testing.expectEqual(@as(usize, 2), reg.subscriberCount("chat"));

    reg.unsubscribe("chat", fake_conn_a);
    try std.testing.expectEqual(@as(usize, 1), reg.subscriberCount("chat"));

    reg.unsubscribe("chat", fake_conn_b);
    try std.testing.expectEqual(@as(usize, 0), reg.subscriberCount("chat"));
}

test "SseRegistry unsubscribe nonexistent is no-op" {
    const allocator = std.testing.allocator;
    var reg = SseRegistry.init(allocator);
    defer reg.deinit();

    const fake_conn: *Connection = @ptrFromInt(0xDEAD_0003);
    // Unsubscribe from room that doesn't exist — should not crash
    reg.unsubscribe("nonexistent", fake_conn);
}

test "SseRegistry multiple rooms" {
    const allocator = std.testing.allocator;
    var reg = SseRegistry.init(allocator);
    defer reg.deinit();

    const fake_conn: *Connection = @ptrFromInt(0xDEAD_0004);

    try reg.subscribe("room_a", fake_conn);
    try reg.subscribe("room_b", fake_conn);

    try std.testing.expectEqual(@as(usize, 1), reg.subscriberCount("room_a"));
    try std.testing.expectEqual(@as(usize, 1), reg.subscriberCount("room_b"));
    try std.testing.expectEqual(@as(usize, 0), reg.subscriberCount("room_c"));
}
