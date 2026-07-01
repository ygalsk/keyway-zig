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

// -- Raw syscall wrappers ---------------------------------------------------
// Zig 0.16 removed most `std.posix.*` syscall wrappers. These reimplement the
// few keyway needs via raw `std.os.linux` / libc calls. Errno decode mirrors
// the manual decoder in src/tls/tls.zig (raw syscalls return -errno as usize).

fn syscallErrno(rc: usize) std.posix.E {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed > -4096) return @enumFromInt(@as(u16, @intCast(-signed)));
    return .SUCCESS;
}

/// `std.posix.pipe` replacement (removed in 0.16).
pub fn pipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (syscallErrno(std.os.linux.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
    return fds;
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

/// `std.posix.socket` replacement (removed in 0.16).
pub fn socket(domain: u32, sock_type: u32, protocol: u32) !std.posix.fd_t {
    const rc = std.os.linux.socket(domain, sock_type, protocol);
    if (syscallErrno(rc) != .SUCCESS) return error.SocketCreationFailed;
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
