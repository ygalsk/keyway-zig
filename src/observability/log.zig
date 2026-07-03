const std = @import("std");
const logz = @import("logz");
const cli = @import("../util/cli.zig");
const log_ring = @import("log_ring.zig");

/// Per-worker identity, set once at thread start via worker.zig
pub threadlocal var worker_id: u16 = 0;

/// Track whether logz has been initialized (guards against pre-init logging in tests).
var initialized = false;

/// Backing I/O for the logz pool. The 0.16 logz dep drives its pool through a
/// `std.Io` rather than managing threads itself; this owns that io for the
/// process lifetime. logz was already a self-threaded subsystem pre-0.16.
var log_io: std.Io.Threaded = undefined;

/// Map std.log.Level to logz.Level.
fn toLogzLevel(level: std.log.Level) logz.Level {
    return switch (level) {
        .debug => .Debug,
        .info => .Info,
        .warn => .Warn,
        .err => .Error,
    };
}

/// Initialize the logz pool. Call after worker count is known.
pub fn init(allocator: std.mem.Allocator, level: std.log.Level, log_format: cli.Config.LogFormat, num_workers: usize) !void {
    const encoding: logz.Config.Encoding = switch (log_format) {
        .logfmt => .logfmt,
        .json => .json,
    };
    log_io = .init(allocator, .{});
    try logz.setup(log_io.io(), allocator, .{
        .level = toLogzLevel(level),
        .pool_size = @intCast(num_workers * 4),
        .output = .stderr,
        .encoding = encoding,
    });
    initialized = true;
}

/// Tear down the logz pool.
pub fn deinit() void {
    if (initialized) {
        logz.deinit();
        log_io.deinit();
        initialized = false;
    }
}

/// Wraps logz.Logger so every call site's `.log()` also tees the fully
/// formatted line into the shared log ring (log_ring.zig, #230) before
/// flushing to the real sink — the ring surfaces Lua tracebacks and other
/// warn/error events in the dashboard console without a log aggregator.
///
/// Forwards exactly the five builder methods this codebase actually chains
/// (string/stringSafe/int/err/fmt — verified across every call site). Add
/// more only when a call site needs them.
pub const Logger = struct {
    inner: logz.Logger,
    lvl: std.log.Level,

    pub fn string(self: Logger, key: []const u8, value: ?[]const u8) Logger {
        return .{ .inner = self.inner.string(key, value), .lvl = self.lvl };
    }

    pub fn stringSafe(self: Logger, key: []const u8, value: ?[]const u8) Logger {
        return .{ .inner = self.inner.stringSafe(key, value), .lvl = self.lvl };
    }

    pub fn int(self: Logger, key: []const u8, value: anytype) Logger {
        return .{ .inner = self.inner.int(key, value), .lvl = self.lvl };
    }

    pub fn err(self: Logger, value: anyerror) Logger {
        return .{ .inner = self.inner.err(value), .lvl = self.lvl };
    }

    pub fn fmt(self: Logger, key: []const u8, comptime format: []const u8, values: anytype) Logger {
        return .{ .inner = self.inner.fmt(key, format, values), .lvl = self.lvl };
    }

    /// Flush to the real sink (stderr, per logz config) and, first, tee the
    /// fully-formatted line into the log ring.
    ///
    /// The capture calls the concrete logger's own `logTo` (LogFmt/Json)
    /// directly — NOT the outer `logz.Logger.logTo`/`.log()` wrappers.
    /// Those release the pooled logger back to logz's pool as a side
    /// effect; logz's pool has no reentrancy guard, so calling two of them
    /// on the same value would release it twice (use-after-free / a
    /// duplicate pool entry another thread could then hand out twice).
    /// Calling the concrete type's `logTo` directly writes bytes with no
    /// such side effect, so it's safe to do here before the real `.log()`.
    pub fn log(self: Logger) void {
        var buf: [log_ring.MSG_CAP]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        switch (self.inner.inner) {
            .noop => {},
            inline else => |l| l.logTo(&w) catch {},
        }
        const captured = std.mem.trimEnd(u8, w.buffered(), " \n");
        if (captured.len > 0) log_ring.push(self.lvl, worker_id, captured);
        self.inner.log();
    }
};

pub fn info() Logger {
    return .{ .inner = if (!initialized) logz.noop else logz.info().int("worker", worker_id), .lvl = .info };
}

pub fn err() Logger {
    return .{ .inner = if (!initialized) logz.noop else logz.err().int("worker", worker_id), .lvl = .err };
}

pub fn warn() Logger {
    return .{ .inner = if (!initialized) logz.noop else logz.warn().int("worker", worker_id), .lvl = .warn };
}

pub fn debug() Logger {
    return .{ .inner = if (!initialized) logz.noop else logz.debug().int("worker", worker_id), .lvl = .debug };
}

/// Log a completed HTTP request in structured access format.
///
/// Deliberately bypasses the Logger wrapper above — every request
/// (including a dashboard poll of GET /__keyway/api/log itself) completes
/// with an access log line, so teeing this into the ring would make each
/// poll's response perpetually "one behind": the poll's own access log
/// entry lands in the ring just after the response snapshot is taken, and
/// shows up as a spurious "new" entry on the very next poll. Access
/// volume/detail already lives in /metrics; the ring is for the
/// warn/error-level engine events (Lua tracebacks) that metrics can't show.
pub fn accessLog(method: []const u8, path: []const u8, status: u16, dur_us: i64) void {
    if (!initialized) return;
    logz.info()
        .int("worker", worker_id)
        .stringSafe("scope", "access")
        .stringSafe("method", method)
        .string("path", path)
        .int("status", status)
        .int("dur_us", dur_us)
        .log();
}

/// Bridge: route std.log calls through logz so dependency/stdlib logging is consistent.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!initialized) return;
    const logz_level = comptime toLogzLevel(level);
    var logger: Logger = .{ .inner = logz.loggerL(logz_level).int("worker", worker_id), .lvl = level };

    const scope_str = if (comptime scope != .default) @tagName(scope) else "";
    if (scope_str.len > 0) {
        logger = logger.stringSafe("scope", scope_str);
    }

    logger.fmt("msg", format, args).log();
}

// =============================================================================
// Tests
// =============================================================================

test "log: err() tees the formatted line into the shared log ring" {
    const allocator = std.testing.allocator;
    try init(allocator, .debug, .logfmt, 1);
    defer deinit();

    err().string("msg", "boom-test-marker").int("code", 42).log();

    const result = try log_ring.collectSince(allocator, 0);
    defer log_ring.freeEntries(allocator, result.entries);

    var found = false;
    for (result.entries) |e| {
        if (std.mem.indexOf(u8, e.msg, "boom-test-marker") != null) {
            found = true;
            try std.testing.expectEqual(std.log.Level.err, e.level);
        }
    }
    try std.testing.expect(found);
}
