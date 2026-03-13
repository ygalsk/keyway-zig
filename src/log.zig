const std = @import("std");

/// Per-worker identity, set once at thread start via worker.zig
pub threadlocal var worker_id: u16 = 0;

/// Runtime log level filter. Messages above this severity are suppressed.
/// Set once at startup from CLI/env config; defaults to .info.
pub var runtime_log_level: std.log.Level = .info;

/// Format an epoch timestamp as RFC 3339 (e.g. 2026-03-11T14:30:00Z)
fn writeTimestamp(writer: anytype) void {
    const ts: u64 = @intCast(@max(0, std.time.timestamp()));
    const es = std.time.epoch.EpochSeconds{ .secs = ts };
    const ds = es.getDaySeconds();
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();

    writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch {};
}

/// Custom logFn override for std.options — formats all log output as logfmt.
/// Output: ts=<rfc3339> level=<level> worker=<id> [scope=<scope>] msg="<message>"
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Runtime log level filter: skip messages less severe than configured level
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

    const level_str = comptime level.asText();
    const scope_str = if (comptime scope != .default) @tagName(scope) else "";

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    nosuspend {
        stderr.writeAll("ts=") catch return;
        writeTimestamp(stderr);

        if (scope_str.len > 0) {
            stderr.print(" level={s} worker={d} scope={s} msg=\"", .{
                level_str, worker_id, scope_str,
            }) catch return;
        } else {
            stderr.print(" level={s} worker={d} msg=\"", .{
                level_str, worker_id,
            }) catch return;
        }

        stderr.print(format, args) catch return;
        stderr.writeAll("\"\n") catch return;
    }
}

/// Log a completed HTTP request in logfmt access format.
/// Called from handler.zig after response is ready to send.
pub fn accessLog(method: []const u8, path: []const u8, status: u16, dur_us: i64) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    nosuspend {
        stderr.writeAll("ts=") catch return;
        writeTimestamp(stderr);
        stderr.print(" level=info worker={d} scope=access method={s} path={s} status={d} dur_us={d}\n", .{
            worker_id, method, path, status, dur_us,
        }) catch return;
    }
}

test "writeTimestamp produces valid RFC 3339" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    writeTimestamp(fbs.writer());
    const written = fbs.getWritten();

    try std.testing.expectEqual(@as(usize, 20), written.len);
    try std.testing.expectEqual(@as(u8, 'T'), written[10]);
    try std.testing.expectEqual(@as(u8, 'Z'), written[19]);
}
