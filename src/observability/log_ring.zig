//! In-memory ring buffer for engine log events (Lua tracebacks, warnings,
//! errors), surfaced via `GET /__keyway/api/log` for the dashboard console
//! (#230).
//!
//! Single global instance shared across all workers — the same documented
//! exception as `observability/prom.zig` (see MANIFEST.md): an inbound HTTP
//! GET lands on one arbitrary worker (SO_REUSEPORT) and keep-alive pins the
//! dashboard to it, so a per-worker ring would be unreadable from the other
//! workers.
//!
//! Thread-safe via a per-slot seqlock rather than a mutex: `push()` runs on
//! the warn/err path, not the request hot path, so write cost is
//! irrelevant — but `collectSince()` must tolerate concurrent writers
//! without blocking and must never hand back a torn (half-written) entry.
//! Each slot carries a generation counter: even = stable/readable, odd =
//! write in progress. A reader takes the generation before and after
//! copying a slot's fields; if it's odd, or changed between the two reads,
//! the slot was (or is being) written concurrently and the reader drops it
//! rather than risk returning a mix of two writes.
//!
//! Deliberately generic — level/worker/msg are plain values, not tied to
//! the logz dependency — so a future consumer (e.g. a request tape) can
//! reuse this same ring/endpoint pattern.

const std = @import("std");
const config = @import("../util/config.zig");
const helpers = @import("../util/helpers.zig");

pub const RING_SIZE: usize = config.LOG_RING_ENTRIES;
pub const MSG_CAP: usize = config.LOG_RING_MSG_CAP;

const Slot = struct {
    /// Seqlock generation. 0 = never written. Even = stable. Odd = a write
    /// is currently in progress on this slot.
    gen: std.atomic.Value(u64) = .init(0),
    entry_seq: u64 = 0,
    ts_ms: i64 = 0,
    level: std.log.Level = .info,
    worker: u16 = 0,
    len: u16 = 0,
    msg: [MSG_CAP]u8 = undefined,
};

var slots: [RING_SIZE]Slot = blk: {
    @setEvalBranchQuota(RING_SIZE * 4);
    var s: [RING_SIZE]Slot = undefined;
    for (&s) |*slot| slot.* = .{};
    break :blk s;
};

/// Next sequence number to assign. Starts at 1 so seq 0 is never a real
/// entry — `since=0` means "everything recorded so far".
var next_seq: std.atomic.Value(u64) = .init(1);

/// Write a log event into the ring. Never allocates and never blocks
/// (beyond the atomic RMWs below); safe to call from any worker thread.
/// `msg` longer than `MSG_CAP` is truncated, not overflowed.
pub fn push(level: std.log.Level, worker: u16, msg: []const u8) void {
    const seq = next_seq.fetchAdd(1, .monotonic);
    const idx: usize = @intCast((seq - 1) % RING_SIZE);
    const slot = &slots[idx];

    // Enter the write: bump gen to odd so a concurrent reader knows a write
    // is in progress and skips this slot instead of reading torn data.
    _ = slot.gen.fetchAdd(1, .release);

    slot.entry_seq = seq;
    slot.ts_ms = helpers.realtimeMillis();
    slot.level = level;
    slot.worker = worker;
    const n = @min(msg.len, MSG_CAP);
    @memcpy(slot.msg[0..n], msg[0..n]);
    slot.len = @intCast(n);

    // Leave the write: bump gen back to even (stable, readable).
    _ = slot.gen.fetchAdd(1, .release);
}

pub const Entry = struct {
    seq: u64,
    ts_ms: i64,
    level: std.log.Level,
    worker: u16,
    msg: []const u8,
};

/// Seqlock-validated read of one slot. Returns null if the slot has never
/// been written, a write is currently in progress, or a write happened
/// concurrently with this read (torn read) — callers drop such slots
/// rather than see garbage. On success, `entry.msg` is a copy allocated
/// from `alloc` (the ring's own storage is reused on the next wrap).
fn readSlot(idx: usize, alloc: std.mem.Allocator) !?Entry {
    const slot = &slots[idx];

    const gen_before = slot.gen.load(.acquire);
    if (gen_before == 0 or gen_before % 2 != 0) return null;

    const seq = slot.entry_seq;
    const ts_ms = slot.ts_ms;
    const level = slot.level;
    const worker = slot.worker;
    const len = slot.len;
    var buf: [MSG_CAP]u8 = undefined;
    @memcpy(buf[0..len], slot.msg[0..len]);

    const gen_after = slot.gen.load(.acquire);
    if (gen_after != gen_before) return null; // torn read — writer touched this slot mid-copy

    return Entry{
        .seq = seq,
        .ts_ms = ts_ms,
        .level = level,
        .worker = worker,
        .msg = try alloc.dupe(u8, buf[0..len]),
    };
}

pub const CollectResult = struct { entries: []Entry, latest: u64 };

/// Collect all entries with seq > `since`, oldest first. `latest` is the
/// most recent seq assigned so far (0 if the ring is empty) — reported even
/// when `entries` is empty, so a caught-up client can still advance its
/// cursor.
pub fn collectSince(alloc: std.mem.Allocator, since: u64) !CollectResult {
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer freeEntries(alloc, list.items);

    for (0..RING_SIZE) |i| {
        const entry = (try readSlot(i, alloc)) orelse continue;
        if (entry.seq <= since) {
            alloc.free(entry.msg);
            continue;
        }
        try list.append(alloc, entry);
    }

    const entries = try list.toOwnedSlice(alloc);
    std.mem.sort(Entry, entries, {}, lessThanSeq);
    return .{ .entries = entries, .latest = latestSeq() };
}

fn lessThanSeq(_: void, a: Entry, b: Entry) bool {
    return a.seq < b.seq;
}

/// Most recent seq assigned so far (0 if nothing has ever been pushed).
pub fn latestSeq() u64 {
    return next_seq.load(.monotonic) -| 1;
}

/// Free entries returned by `collectSince` (each `msg` was individually
/// duped from the ring).
pub fn freeEntries(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| alloc.free(e.msg);
    alloc.free(entries);
}

// =============================================================================
// Tests
// =============================================================================

/// Test-only: reset module-global ring state. Tests share process-global
/// state (this ring is a singleton by design, see module docs), so each
/// test starts from a clean slate.
fn resetForTest() void {
    next_seq.store(1, .monotonic);
    for (&slots) |*s| s.* = .{};
}

test "log_ring: wraps and keeps seq monotonic" {
    resetForTest();
    const alloc = std.testing.allocator;

    var i: usize = 0;
    while (i < RING_SIZE + 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "entry-{d}", .{i}) catch unreachable;
        push(.info, 0, msg);
    }

    const result = try collectSince(alloc, 0);
    defer freeEntries(alloc, result.entries);

    try std.testing.expectEqual(RING_SIZE, result.entries.len);
    try std.testing.expectEqual(@as(u64, RING_SIZE + 10), result.latest);
    // The ring wrapped once — the oldest 10 pushes (seq 1..10) were
    // overwritten, so the oldest surviving entry is seq 11 (i=10).
    try std.testing.expectEqual(@as(u64, 11), result.entries[0].seq);
    try std.testing.expectEqualStrings("entry-10", result.entries[0].msg);
    // seq keeps climbing across the wrap, never resets.
    try std.testing.expectEqual(@as(u64, RING_SIZE + 10), result.entries[result.entries.len - 1].seq);
}

test "log_ring: truncates oversized messages" {
    resetForTest();
    const alloc = std.testing.allocator;

    var big: [MSG_CAP * 2]u8 = undefined;
    @memset(&big, 'x');
    push(.err, 7, &big);

    const result = try collectSince(alloc, 0);
    defer freeEntries(alloc, result.entries);

    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqual(MSG_CAP, result.entries[0].msg.len);
    try std.testing.expectEqual(@as(u16, 7), result.entries[0].worker);
}

test "log_ring: since cursor filters and reports latest" {
    resetForTest();
    const alloc = std.testing.allocator;

    push(.info, 0, "a");
    push(.info, 0, "b");
    push(.info, 0, "c");

    const from_zero = try collectSince(alloc, 0);
    defer freeEntries(alloc, from_zero.entries);
    try std.testing.expectEqual(@as(usize, 3), from_zero.entries.len);
    try std.testing.expectEqual(@as(u64, 3), from_zero.latest);

    const from_two = try collectSince(alloc, 2);
    defer freeEntries(alloc, from_two.entries);
    try std.testing.expectEqual(@as(usize, 1), from_two.entries.len);
    try std.testing.expectEqual(@as(u64, 3), from_two.entries[0].seq);
    try std.testing.expectEqualStrings("c", from_two.entries[0].msg);

    const caught_up = try collectSince(alloc, 3);
    defer freeEntries(alloc, caught_up.entries);
    try std.testing.expectEqual(@as(usize, 0), caught_up.entries.len);
    try std.testing.expectEqual(@as(u64, 3), caught_up.latest);
}

test "log_ring: empty ring reports latest 0" {
    resetForTest();
    const result = try collectSince(std.testing.allocator, 0);
    defer freeEntries(std.testing.allocator, result.entries);
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    try std.testing.expectEqual(@as(u64, 0), result.latest);
}

test "log_ring: a write-in-progress slot is not returned as garbage" {
    resetForTest();
    const alloc = std.testing.allocator;

    push(.warn, 1, "stable-entry");

    // Simulate a concurrent writer that entered but hasn't yet left the
    // write for this same slot: bump gen to odd without touching the
    // payload fields. A correct reader must skip the slot outright rather
    // than return (or half-return) whatever is currently in the fields.
    slots[0].gen.store(slots[0].gen.load(.monotonic) + 1, .monotonic);

    const result = try collectSince(alloc, 0);
    defer freeEntries(alloc, result.entries);
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
}

test "log_ring: concurrent writer never yields a torn message" {
    resetForTest();
    const alloc = std.testing.allocator;

    const short: []const u8 = "S" ** 16;
    const long: []const u8 = "L" ** (MSG_CAP - 1);

    const Writer = struct {
        fn run() void {
            var i: usize = 0;
            while (i < 8_000) : (i += 1) {
                push(.info, 0, if (i % 2 == 0) short else long);
            }
        }
    };

    var thread = try std.Thread.spawn(.{}, Writer.run, .{});

    var reads: usize = 0;
    while (reads < 400) : (reads += 1) {
        const result = try collectSince(alloc, 0);
        defer freeEntries(alloc, result.entries);
        for (result.entries) |e| {
            const ok = std.mem.eql(u8, e.msg, short) or std.mem.eql(u8, e.msg, long);
            try std.testing.expect(ok);
        }
    }

    thread.join();
}
