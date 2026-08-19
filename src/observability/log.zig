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

/// #248: stop a stalled log consumer from freezing the data plane.
///
/// logz writes synchronously to fd 2 from whichever thread calls it, holding a
/// process-global mutex across the write. If whatever reads keyway's stderr
/// stops reading, the pipe fills, the first worker blocks in `write(2)` *while
/// holding that lock*, and every other worker freezes on its next log call —
/// measured 0/12 requests served with `--workers 4`, recovering the instant the
/// pipe was drained. That is a blocking syscall on the proactor thread
/// (zig-gotchas, MANIFEST §1) with the whole server's availability behind it.
///
/// A log line is an observation about a request, not part of it, so the data
/// plane must never wait on it. No buffer size fixes that — a bigger buffer
/// only moves the wall — so the only real question is what happens when the
/// sink is full, and the answer everywhere else is drop: HAProxy logs over UDP,
/// Envoy and Rust's tracing-appender use a bounded queue that discards,
/// journald reports "Suppressed N messages".
///
/// logz cannot express that (`Output` is a closed `stdout | stderr | file`, and
/// we are pinned to its upstream HEAD), so we interpose one level down: fd 2
/// becomes the write end of a non-blocking pipe we own, and one thread drains
/// that pipe into the real stderr and is free to block there. logz keeps
/// writing to "stderr", unaware, and fails fast with EAGAIN instead of
/// blocking — its own handler for a failed write already drops the line.
///
/// Interposing on the fd rather than teaching logz a new sink covers every
/// stderr writer at once — panics, LuaJIT, dependencies — and needs no change
/// at the ~100 call sites. O_NONBLOCK is set on the pipe *we* created, never on
/// the stderr the parent handed us, so a shared terminal is unaffected.
const StderrPump = struct {
    /// The stderr we were started with; the drain thread's destination.
    real_stderr: i32,
    /// Read end of the interposing pipe.
    read_fd: i32,
    thread: std.Thread,
};

var pump: ?StderrPump = null;

/// Lines logz could not write because the pipe was full. Reported by the drain
/// thread, since a dropped line cannot report itself.
var dropped = std.atomic.Value(u64).init(0);

/// Re-entry guard for `logFn`. logz reports a failed write with `std.log.err`,
/// which lands back in `logFn` and tries to log through logz again — which
/// fails again, recursing until the stack is gone. Depth 2 is where we catch
/// it: the first entry is the failure report, the second means that report
/// itself could not be written, i.e. a genuine drop.
threadlocal var in_log = false;

fn installStderrPump() !void {
    const linux = std.os.linux;

    // Both ends blocking for now; only the write end goes non-blocking, so the
    // drain thread can just block in read(2) instead of spinning.
    var fds: [2]i32 = undefined;
    if (linux.pipe2(&fds, .{}) != 0) return error.PipeFailed;
    errdefer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }

    const real_stderr: i32 = @intCast(linux.dup(linux.STDERR_FILENO));
    if (real_stderr < 0) return error.DupFailed;
    errdefer _ = linux.close(real_stderr);

    if (@as(isize, @bitCast(linux.dup2(fds[1], linux.STDERR_FILENO))) < 0) return error.Dup2Failed;
    _ = linux.close(fds[1]); // fd 2 now refers to the same description

    const flags = linux.fcntl(linux.STDERR_FILENO, linux.F.GETFL, 0);
    if (@as(isize, @bitCast(flags)) < 0) return error.FcntlFailed;
    const O_NONBLOCK: usize = 0o4000;
    if (@as(isize, @bitCast(linux.fcntl(linux.STDERR_FILENO, linux.F.SETFL, flags | O_NONBLOCK))) < 0) {
        return error.FcntlFailed;
    }

    pump = .{ .real_stderr = real_stderr, .read_fd = fds[0], .thread = undefined };
    pump.?.thread = std.Thread.spawn(.{}, drainStderr, .{}) catch |e| {
        // Put the original stderr back rather than leave the process writing
        // into a pipe with no reader.
        _ = linux.dup2(real_stderr, linux.STDERR_FILENO);
        pump = null;
        return e;
    };
}

/// Drain the interposing pipe into the real stderr. Runs off the workers, so
/// blocking here is correct — that is the whole point: backpressure stops at
/// this thread instead of reaching the data plane.
fn drainStderr() void {
    const linux = std.os.linux;
    const p = &pump.?;
    var buf: [16 * 1024]u8 = undefined;
    var reported: u64 = 0;

    while (true) {
        const n = linux.read(p.read_fd, &buf, buf.len);
        const signed: isize = @bitCast(n);
        if (signed < 0) {
            const e: linux.E = @enumFromInt(@as(usize, @bitCast(-signed)));
            if (e == .INTR) continue;
            return;
        }
        if (n == 0) return; // write end closed — shutting down

        writeAllTo(p.real_stderr, buf[0..n]);

        // Surface losses next to the surviving lines, journald-style. A
        // dropped line cannot report itself, and logz swallows the failure.
        const total = dropped.load(.monotonic);
        if (total != reported) {
            var note: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &note,
                "@l=WARN msg=\"log lines dropped, stderr consumer too slow\" dropped={d}\n",
                .{total},
            ) catch continue;
            writeAllTo(p.real_stderr, msg);
            reported = total;
        }
    }
}

/// Blocking write-all to a raw fd, retrying short writes and EINTR. Gives up on
/// any other error — there is nowhere left to report it.
fn writeAllTo(fd: i32, bytes: []const u8) void {
    const linux = std.os.linux;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        const signed: isize = @bitCast(n);
        if (signed < 0) {
            const e: linux.E = @enumFromInt(@as(usize, @bitCast(-signed)));
            if (e == .INTR) continue;
            return;
        }
        if (n == 0) return;
        off += n;
    }
}

/// Restore the original stderr and let the drain thread finish. Called after
/// logz.deinit(), so nothing is still writing when the pipe is closed.
fn removeStderrPump() void {
    const linux = std.os.linux;
    const p = pump orelse return;
    // Putting the real stderr back on fd 2 drops the last reference to the
    // pipe's write end, so the drain thread reads EOF and returns after
    // flushing whatever is still buffered.
    _ = linux.dup2(p.real_stderr, linux.STDERR_FILENO);
    p.thread.join();
    _ = linux.close(p.read_fd);
    _ = linux.close(p.real_stderr);
    pump = null;
}

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
    // Before logz takes hold of fd 2 (#248). Failing to interpose is not fatal
    // — it only means we keep the old blocking behaviour — but it must be
    // reported, and it cannot be reported through logz, which is not up yet.
    installStderrPump() catch |e| {
        std.debug.print("keyway: could not interpose on stderr ({s}); " ++
            "a stalled log consumer can block the workers (#248)\n", .{@errorName(e)});
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
    // After logz is down, so nothing is mid-write when the pipe closes (#248).
    removeStderrPump();
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
    // logz reports a failed write via std.log.err, landing right here. Logging
    // that through logz recurses until the stack is gone, so a re-entry means
    // the sink is full and this line is a drop (#248).
    if (in_log) {
        _ = dropped.fetchAdd(1, .monotonic);
        return;
    }
    in_log = true;
    defer in_log = false;

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
