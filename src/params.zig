const std = @import("std");
const log = @import("log.zig");
const config = @import("config.zig");

pub const MAX_ROUTE_PARAMS = config.MAX_ROUTE_PARAMS;
pub const MAX_QUERY_PARAMS = config.MAX_QUERY_PARAMS;

/// Generic inline key-value map with fixed capacity.
/// O(n) lookup but n is small, cache-friendly, zero allocations.
pub fn InlineMap(comptime max: usize) type {
    return struct {
        const Self = @This();

        items: [max]Entry = undefined,
        len: usize = 0,

        pub const Entry = struct {
            key: []const u8,
            value: []const u8,
        };

        pub fn put(self: *Self, key: []const u8, value: []const u8) error{TooManyParams}!void {
            if (self.len >= max) return error.TooManyParams;
            self.items[self.len] = .{ .key = key, .value = value };
            self.len += 1;
        }

        pub inline fn get(self: *const Self, key: []const u8) ?[]const u8 {
            for (self.items[0..self.len]) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return null;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

pub const ParamArray = InlineMap(MAX_ROUTE_PARAMS);
pub const QueryArray = InlineMap(MAX_QUERY_PARAMS);

/// Parse a query string (everything after '?') into a QueryArray.
/// Splits on '&', then each pair on '='. Values are zero-copy slices.
/// Does NOT perform percent-decoding; callers get raw slices.
pub fn parseQueryString(raw: []const u8, out: *QueryArray) void {
    var pairs = std.mem.splitScalar(u8, raw, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            out.put(pair[0..eq], pair[eq + 1 ..]) catch {
                log.warn().string("msg", "query string exceeds max params, truncating").int("max", MAX_QUERY_PARAMS).log();
                return;
            };
        } else {
            out.put(pair, "") catch {
                log.warn().string("msg", "query string exceeds max params, truncating").int("max", MAX_QUERY_PARAMS).log();
                return;
            };
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ParamArray put and get" {
    var p = ParamArray{};
    try p.put("id", "42");
    try p.put("name", "alice");

    try std.testing.expectEqualStrings("42", p.get("id").?);
    try std.testing.expectEqualStrings("alice", p.get("name").?);
    try std.testing.expect(p.get("missing") == null);
}

test "ParamArray clear resets length" {
    var p = ParamArray{};
    try p.put("a", "1");
    p.clear();
    try std.testing.expectEqual(@as(usize, 0), p.len);
    try std.testing.expect(p.get("a") == null);
}

test "ParamArray rejects overflow" {
    var p = ParamArray{};
    for (0..MAX_ROUTE_PARAMS) |i| {
        const key: []const u8 = switch (i) {
            0 => "a",
            1 => "b",
            2 => "c",
            3 => "d",
            else => unreachable,
        };
        try p.put(key, "v");
    }
    try std.testing.expectError(error.TooManyParams, p.put("overflow", "v"));
}

test "parseQueryString normal input" {
    var q = QueryArray{};
    parseQueryString("foo=bar&baz=qux", &q);

    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqualStrings("bar", q.get("foo").?);
    try std.testing.expectEqualStrings("qux", q.get("baz").?);
}

test "parseQueryString empty input" {
    var q = QueryArray{};
    parseQueryString("", &q);
    try std.testing.expectEqual(@as(usize, 0), q.len);
}

test "parseQueryString key without value" {
    var q = QueryArray{};
    parseQueryString("flag&key=val", &q);

    try std.testing.expectEqual(@as(usize, 2), q.len);
    try std.testing.expectEqualStrings("", q.get("flag").?);
    try std.testing.expectEqualStrings("val", q.get("key").?);
}

test "parseQueryString truncates on overflow" {
    var q = QueryArray{};
    // MAX_QUERY_PARAMS is 4, so 5 params should truncate
    parseQueryString("a=1&b=2&c=3&d=4&e=5", &q);
    try std.testing.expectEqual(@as(usize, MAX_QUERY_PARAMS), q.len);
    // The 5th param should not be present
    try std.testing.expect(q.get("e") == null);
}
