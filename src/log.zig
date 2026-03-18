const std = @import("std");
const logz = @import("logz");
const cli = @import("cli.zig");

/// Per-worker identity, set once at thread start via worker.zig
pub threadlocal var worker_id: u16 = 0;

/// Track whether logz has been initialized (guards against pre-init logging in tests).
var initialized = false;

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
    try logz.setup(allocator, .{
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
        initialized = false;
    }
}

pub fn info() logz.Logger {
    if (!initialized) return logz.noop;
    return logz.info().int("worker", worker_id);
}

pub fn err() logz.Logger {
    if (!initialized) return logz.noop;
    return logz.err().int("worker", worker_id);
}

pub fn warn() logz.Logger {
    if (!initialized) return logz.noop;
    return logz.warn().int("worker", worker_id);
}

pub fn debug() logz.Logger {
    if (!initialized) return logz.noop;
    return logz.debug().int("worker", worker_id);
}

/// Log a completed HTTP request in structured access format.
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
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!initialized) return;
    const logz_level = comptime toLogzLevel(level);
    var logger = logz.loggerL(logz_level).int("worker", worker_id);

    const scope_str = if (comptime scope != .default) @tagName(scope) else "";
    if (scope_str.len > 0) {
        logger = logger.stringSafe("scope", scope_str);
    }

    logger.fmt("msg", format, args).log();
}
