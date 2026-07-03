/// Unwraps an optional `*anyopaque` and casts it to a typed pointer.
/// Replaces verbose `@as(*T, @ptrCast(@alignCast(ud)))` chains.
pub fn castUserdata(comptime T: type, ud: ?*anyopaque) *T {
    return @as(*T, @ptrCast(@alignCast(ud.?)));
}

/// Look up an environment variable via libc. `std.posix.getenv` was removed in
/// Zig 0.16; libc is always linked (see build.zig addSharedDeps). The returned
/// slice is valid for the process lifetime.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

/// Close a raw file descriptor. `std.posix.close` was removed in Zig 0.16;
/// libc is always linked (see build.zig addSharedDeps).
pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

/// Monotonic clock in nanoseconds. `std.time.*Timestamp` were removed in Zig
/// 0.16; this reads CLOCK_MONOTONIC via the vDSO (no syscall). keyway only ever
/// measures durations, so a monotonic (not wall-clock) source is correct.
pub fn monotonicNanos() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ns_per_s + @as(i64, @intCast(ts.nsec));
}

/// Wall-clock time in whole seconds since the Unix epoch. `std.time.timestamp`
/// was removed in Zig 0.16; this reads CLOCK_REALTIME via the vDSO (no
/// syscall) — safe to call per-response, not a proactor violation.
pub fn realtimeSeconds() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec));
}

/// Format a Unix timestamp as an RFC 7231 IMF-fixdate HTTP-date, e.g.
/// "Sun, 06 Nov 1994 08:49:37 GMT". Shared by the Date response header and
/// static file Last-Modified.
pub fn formatHttpDate(buf: *[29]u8, epoch_secs: i64) void {
    const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, epoch_secs)) };
    const day_seconds = epoch.getDaySeconds();
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // Day of week: Jan 1 1970 was Thursday (days[0])
    const dow_idx: usize = @intCast(@mod(@as(i64, @intCast(epoch_day.day)), 7));

    _ = std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        days[dow_idx],
        month_day.day_index + 1,
        months[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch {};
}

// -- Raw syscall wrappers ---------------------------------------------------
// Zig 0.16 removed most `std.posix.*` syscall wrappers. These reimplement the
// few keyway needs via raw `std.os.linux` / libc calls.

/// Decode errno from a raw Linux syscall return value.
/// Raw syscalls return -errno as usize on failure. std.posix.errno() doesn't
/// reliably decode all values (e.g. small negative values can slip through),
/// so we decode manually: negate the signed value to get the errno integer.
/// Also used directly by src/tls/tls.zig for its raw setsockopt/getsockopt calls.
pub fn syscallErrno(rc: usize) std.posix.E {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed > -4096) return @enumFromInt(@as(u16, @intCast(-signed)));
    return .SUCCESS;
}

/// Best-effort SHUT_RDWR; `std.posix.shutdown` was removed in 0.16.
pub fn shutdownBoth(fd: std.posix.fd_t) void {
    _ = std.os.linux.shutdown(fd, 2); // 2 = SHUT_RDWR
}

/// `std.posix.inotify_init1` replacement (removed in 0.16).
pub fn inotifyInit1(flags: u32) !std.posix.fd_t {
    const rc = std.os.linux.inotify_init1(flags);
    if (syscallErrno(rc) != .SUCCESS) return error.InotifyInitFailed;
    return @intCast(rc);
}

/// `std.posix.inotify_add_watch` replacement (removed in 0.16).
pub fn inotifyAddWatch(fd: std.posix.fd_t, path: [*:0]const u8, mask: u32) !i32 {
    const rc = std.os.linux.inotify_add_watch(fd, path, mask);
    if (syscallErrno(rc) != .SUCCESS) return error.InotifyAddWatchFailed;
    return @intCast(rc);
}

const std = @import("std");
const testing = std.testing;

test "castUserdata round-trips a struct pointer" {
    const Point = struct { x: i32, y: i32 };
    var p = Point{ .x = 42, .y = -7 };
    const erased: ?*anyopaque = @ptrCast(&p);
    const recovered = castUserdata(Point, erased);
    try testing.expectEqual(@as(i32, 42), recovered.x);
    try testing.expectEqual(@as(i32, -7), recovered.y);
    try testing.expect(recovered == &p);
}

test "formatHttpDate produces valid format" {
    var buf: [29]u8 = undefined;
    // Unix epoch: Thu, 01 Jan 1970 00:00:00 GMT
    formatHttpDate(&buf, 0);
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &buf);
}
