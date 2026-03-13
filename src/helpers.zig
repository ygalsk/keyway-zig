/// Unwraps an optional `*anyopaque` and casts it to a typed pointer.
/// Replaces verbose `@as(*T, @ptrCast(@alignCast(ud)))` chains.
pub fn castUserdata(comptime T: type, ud: ?*anyopaque) *T {
    return @as(*T, @ptrCast(@alignCast(ud.?)));
}

const testing = @import("std").testing;

test "castUserdata round-trips a struct pointer" {
    const Point = struct { x: i32, y: i32 };
    var p = Point{ .x = 42, .y = -7 };
    const erased: ?*anyopaque = @ptrCast(&p);
    const recovered = castUserdata(Point, erased);
    try testing.expectEqual(@as(i32, 42), recovered.x);
    try testing.expectEqual(@as(i32, -7), recovered.y);
    try testing.expect(recovered == &p);
}
