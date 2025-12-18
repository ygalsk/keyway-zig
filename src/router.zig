const std = @import("std");

/// Route match result - contains Lua function reference and extracted params
pub const RouteMatch = struct {
    lua_ref: i32, // Lua registry reference to handler function
    params: std.StringHashMap([]const u8),

    pub fn deinit(self: *RouteMatch) void {
        self.params.deinit();
    }
};

/// Route segment - either static or a parameter
const Segment = union(enum) {
    static: []const u8,
    param: []const u8, // Parameter name (without braces)
};

/// Single route - pattern + Lua handler reference
const Route = struct {
    method: []const u8,
    segments: []Segment,
    lua_ref: i32, // Lua registry reference to handler function
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Route) void {
        self.allocator.free(self.segments);
    }
};

/// Router - Deep module with simple interface
/// Handles route registration, pattern matching, and parameter extraction
pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),

    /// Initialize router
    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(Route).initCapacity(allocator, 0) catch unreachable,
        };
    }

    /// Register a route
    /// Pattern format: /users/{id} or /posts/{post_id}/comments/{id}
    /// lua_ref is a Lua registry reference to the handler function
    pub fn addRoute(
        self: *Router,
        method: []const u8,
        pattern: []const u8,
        lua_ref: i32,
    ) !void {
        const segments = try self.parsePattern(pattern);

        try self.routes.append(self.allocator, .{
            .method = method,
            .segments = segments,
            .lua_ref = lua_ref,
            .allocator = self.allocator,
        });
    }

    /// Match a request path against registered routes
    /// Returns RouteMatch with handler and extracted params, or null if no match
    pub fn match(
        self: *Router,
        method: []const u8,
        path: []const u8,
    ) !?RouteMatch {
        var path_segments = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable;
        defer path_segments.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try path_segments.append(self.allocator, seg);
        }

        for (self.routes.items) |route| {
            if (!std.mem.eql(u8, route.method, method)) continue;
            if (route.segments.len != path_segments.items.len) continue;

            var params = std.StringHashMap([]const u8).init(self.allocator);
            errdefer params.deinit();

            var matched = true;
            for (route.segments, path_segments.items) |pat, seg| {
                switch (pat) {
                    .static => |s| if (!std.mem.eql(u8, s, seg)) {
                        matched = false;
                        break;
                    },
                    .param => |name| try params.put(name, seg),
                }
            }

            if (matched) {
                return .{ .lua_ref = route.lua_ref, .params = params };
            }

            params.deinit();
        }

        return null;
    }

    /// Clean up router resources
    pub fn deinit(self: *Router) void {
        for (self.routes.items) |*route| {
            route.deinit();
        }
        self.routes.deinit(self.allocator);
    }

    /// Parse route pattern into segments
    /// /users/{id} -> [static("users"), param("id")]
    fn parsePattern(self: *Router, pattern: []const u8) ![]Segment {
        var segments = std.ArrayList(Segment).initCapacity(self.allocator, 0) catch unreachable;
        errdefer segments.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, pattern, '/');
        while (it.next()) |seg| {
            if (seg.len == 0) continue;

            if (seg[0] == '{' and seg[seg.len - 1] == '}') {
                const param_name = seg[1 .. seg.len - 1];
                try segments.append(self.allocator, .{ .param = param_name });
            } else {
                try segments.append(self.allocator, .{ .static = seg });
            }
        }

        return segments.toOwnedSlice(self.allocator);
    }
};

test "router pattern parsing" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users/{id}", "get_user");
    try router.addRoute("GET", "/posts/{post_id}/comments/{id}", "get_comment");

    try std.testing.expectEqual(@as(usize, 2), router.routes.items.len);
}

test "router exact match" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", "list_users");

    var result = try router.match("GET", "/users");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqualStrings("list_users", result.?.handler);
    try std.testing.expectEqual(@as(usize, 0), result.?.params.count());
}

test "router param extraction" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users/{id}", "get_user");

    var result = try router.match("GET", "/users/123");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqualStrings("get_user", result.?.handler);
    try std.testing.expectEqual(@as(usize, 1), result.?.params.count());

    const id = result.?.params.get("id").?;
    try std.testing.expectEqualStrings("123", id);
}

test "router method mismatch" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    try router.addRoute("POST", "/users", "create_user");

    const result = try router.match("GET", "/users");
    try std.testing.expectEqual(@as(?RouteMatch, null), result);
}

test "router multiple params" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/posts/{post_id}/comments/{id}", "get_comment");

    var result = try router.match("GET", "/posts/42/comments/7");
    try std.testing.expect(result != null);
    defer result.?.deinit();

    try std.testing.expectEqualStrings("get_comment", result.?.handler);
    try std.testing.expectEqual(@as(usize, 2), result.?.params.count());

    const post_id = result.?.params.get("post_id").?;
    const id = result.?.params.get("id").?;
    try std.testing.expectEqualStrings("42", post_id);
    try std.testing.expectEqualStrings("7", id);
}
