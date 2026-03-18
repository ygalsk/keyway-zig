const std = @import("std");

/// Per-worker connection pool for cosocket connections.
/// Keyed by destination string (e.g. "127.0.0.1:6379"), LIFO retrieval,
/// lazy reaping of expired entries, max size enforcement.
/// Uses the worker's base allocator (NOT per-request arena).
///
/// After kTLS: pooled connections are plain fds — the kernel handles
/// crypto transparently, so no TLS state needs to be stored or restored.
pub const ConnectionPool = struct {
    pub const DEFAULT_POOL_SIZE: u32 = 32;
    pub const DEFAULT_IDLE_TIMEOUT_MS: u32 = 60_000;

    allocator: std.mem.Allocator,
    pools: std.StringHashMapUnmanaged(Pool),

    pub const PoolEntry = struct {
        fd: std.posix.socket_t,
        reuse_count: u32,
        inserted_at_ms: i64,
    };

    const Pool = struct {
        entries: std.ArrayListUnmanaged(PoolEntry),
        max_size: u32,
        max_idle_ms: u32,
    };

    pub fn init(allocator: std.mem.Allocator) ConnectionPool {
        return .{
            .allocator = allocator,
            .pools = .{},
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        var it = self.pools.iterator();
        while (it.next()) |entry| {
            // Close all pooled fds
            for (entry.value_ptr.entries.items) |pool_entry| {
                std.posix.close(pool_entry.fd);
            }
            entry.value_ptr.entries.deinit(self.allocator);
            // Free duped key
            self.allocator.free(entry.key_ptr.*);
        }
        self.pools.deinit(self.allocator);
    }

    /// Retrieve a connection from the pool (LIFO). Lazy-reaps expired entries.
    /// Returns null if no live connection available.
    pub fn get(self: *ConnectionPool, key: []const u8) ?PoolEntry {
        const pool = self.pools.getPtr(key) orelse return null;
        const now = std.time.milliTimestamp();

        // Pop from back (LIFO) — most recently returned connection reused first
        while (pool.entries.items.len > 0) {
            const len = pool.entries.items.len;
            const entry = pool.entries.items[len - 1];
            pool.entries.items.len = len - 1;
            if (@max(0, now - entry.inserted_at_ms) > @as(i64, pool.max_idle_ms)) {
                // Expired — close and continue
                std.posix.close(entry.fd);
                continue;
            }
            return entry;
        }
        return null;
    }

    /// Sweep all pools, closing expired entries. Called periodically by the worker timer.
    pub fn sweep(self: *ConnectionPool) void {
        const now = std.time.milliTimestamp();
        var it = self.pools.iterator();
        while (it.next()) |entry| {
            const pool = entry.value_ptr;
            // Walk backward so we can swap-remove without invalidating indices
            var i: usize = pool.entries.items.len;
            while (i > 0) {
                i -= 1;
                const pe = pool.entries.items[i];
                if (@max(0, now - pe.inserted_at_ms) > @as(i64, pool.max_idle_ms)) {
                    std.posix.close(pe.fd);
                    _ = pool.entries.swapRemove(i);
                }
            }
        }
    }

    /// Return a connection to the pool. Closes the fd if pool is full.
    /// timeout_ms == 0 means use DEFAULT_IDLE_TIMEOUT_MS.
    /// max_size == 0 means use DEFAULT_POOL_SIZE.
    pub fn put(
        self: *ConnectionPool,
        key: []const u8,
        fd: std.posix.socket_t,
        reuse_count: u32,
        timeout_ms: u32,
        max_size: u32,
    ) !void {
        const effective_timeout = if (timeout_ms == 0) DEFAULT_IDLE_TIMEOUT_MS else timeout_ms;
        const effective_size = if (max_size == 0) DEFAULT_POOL_SIZE else max_size;

        const gop = try self.pools.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            // First insertion — dupe the key, initialize the pool
            gop.key_ptr.* = try self.allocator.dupe(u8, key);
            gop.value_ptr.* = .{
                .entries = .{},
                .max_size = effective_size,
                .max_idle_ms = effective_timeout,
            };
        }

        const pool = gop.value_ptr;

        // Enforce max size
        if (pool.entries.items.len >= pool.max_size) {
            std.posix.close(fd);
            return;
        }

        try pool.entries.append(self.allocator, .{
            .fd = fd,
            .reuse_count = reuse_count,
            .inserted_at_ms = std.time.milliTimestamp(),
        });
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "connection pool init/deinit" {
    var pool = ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();
}

test "connection pool get returns null on empty pool" {
    var pool = ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();

    const result = pool.get("127.0.0.1:6379");
    try std.testing.expect(result == null);
}

test "connection pool put and get roundtrip" {
    var pool = ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();

    // Use a pipe fd as a stand-in for a real socket (safe to close)
    const pipes = try std.posix.pipe();
    std.posix.close(pipes[0]); // close read end, keep write end as our "fd"
    const fake_fd = pipes[1];

    try pool.put("127.0.0.1:6379", fake_fd, 0, 0, 0);

    const entry = pool.get("127.0.0.1:6379");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(fake_fd, entry.?.fd);
    try std.testing.expectEqual(@as(u32, 0), entry.?.reuse_count);

    // Second get should return null (pool drained)
    const entry2 = pool.get("127.0.0.1:6379");
    try std.testing.expect(entry2 == null);

    // Close the fd we got back
    std.posix.close(fake_fd);
}

test "connection pool LIFO order" {
    var pool = ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();

    // Create two pipe fds
    const pipes1 = try std.posix.pipe();
    std.posix.close(pipes1[0]);
    const fd1 = pipes1[1];

    const pipes2 = try std.posix.pipe();
    std.posix.close(pipes2[0]);
    const fd2 = pipes2[1];

    try pool.put("host:1234", fd1, 0, 0, 0);
    try pool.put("host:1234", fd2, 1, 0, 0);

    // LIFO: fd2 (inserted last) should come out first
    const first = pool.get("host:1234");
    try std.testing.expect(first != null);
    try std.testing.expectEqual(fd2, first.?.fd);

    const second = pool.get("host:1234");
    try std.testing.expect(second != null);
    try std.testing.expectEqual(fd1, second.?.fd);

    std.posix.close(fd1);
    std.posix.close(fd2);
}

test "connection pool max size enforcement" {
    var pool = ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();

    // Put with max_size=1
    const pipes1 = try std.posix.pipe();
    std.posix.close(pipes1[0]);
    const fd1 = pipes1[1];

    const pipes2 = try std.posix.pipe();
    std.posix.close(pipes2[0]);
    const fd2 = pipes2[1];

    try pool.put("host:80", fd1, 0, 0, 1); // max_size=1
    try pool.put("host:80", fd2, 0, 0, 1); // should close fd2 (pool full)

    // Only fd1 should be in the pool
    const entry = pool.get("host:80");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(fd1, entry.?.fd);

    const entry2 = pool.get("host:80");
    try std.testing.expect(entry2 == null);

    std.posix.close(fd1);
    // fd2 was closed by put() — do not close again
}

test "connection pool default values for zero args" {
    var pool = ConnectionPool.init(std.testing.allocator);
    defer pool.deinit();

    const pipes = try std.posix.pipe();
    std.posix.close(pipes[0]);
    const fd = pipes[1];

    // Put with 0,0 — should use defaults
    try pool.put("host:80", fd, 0, 0, 0);

    const p = pool.pools.getPtr("host:80").?;
    try std.testing.expectEqual(ConnectionPool.DEFAULT_POOL_SIZE, p.max_size);
    try std.testing.expectEqual(ConnectionPool.DEFAULT_IDLE_TIMEOUT_MS, p.max_idle_ms);

    // Clean up
    const entry = pool.get("host:80");
    if (entry) |e| std.posix.close(e.fd);
}
