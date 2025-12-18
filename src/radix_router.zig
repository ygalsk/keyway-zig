const std = @import("std");

/// Radix tree node for efficient route matching
/// O(path_length) lookup instead of O(n) linear search
const Node = struct {
    allocator: std.mem.Allocator,

    // Static path segment prefix (e.g., "users", "posts")
    prefix: []const u8,

    // Children for static segments (map segment -> node)
    children: std.StringHashMap(*Node),

    // Parameter child (e.g., {id} parameter)
    param_child: ?*ParamChild,

    // Handler at this leaf node (if any)
    handler: ?Handler,

    const ParamChild = struct {
        param_name: []const u8,
        node: *Node,
    };

    const Handler = struct {
        // Map HTTP method -> Lua registry reference
        methods: std.StringHashMap(i32),
    };

    fn init(allocator: std.mem.Allocator, prefix: []const u8) !*Node {
        const node = try allocator.create(Node);
        node.* = Node{
            .allocator = allocator,
            .prefix = prefix,
            .children = std.StringHashMap(*Node).init(allocator),
            .param_child = null,
            .handler = null,
        };
        return node;
    }

    fn deinit(self: *Node) void {
        // Free prefix if allocated
        if (self.prefix.len > 0) {
            self.allocator.free(self.prefix);
        }

        // Recursively free children (and their keys)
        var it = self.children.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*); // Free HashMap key
            entry.value_ptr.*.deinit(); // Recursively free child node
        }
        self.children.deinit();

        // Free param child
        if (self.param_child) |param| {
            self.allocator.free(param.param_name);
            param.node.deinit();
            self.allocator.destroy(param);
        }

        // Free handler methods map
        if (self.handler) |*h| {
            var mit = h.methods.iterator();
            while (mit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            h.methods.deinit();
        }

        self.allocator.destroy(self);
    }
};

/// Radix tree router - O(path_length) route matching
pub const RadixRouter = struct {
    allocator: std.mem.Allocator,
    root: *Node,

    /// Initialize radix router
    pub fn init(allocator: std.mem.Allocator) !RadixRouter {
        const root = try Node.init(allocator, "");
        return RadixRouter{
            .allocator = allocator,
            .root = root,
        };
    }

    /// Add a route to the radix tree
    /// Pattern format: /users/{id} or /posts/{post_id}/comments
    /// lua_ref is the Lua registry reference to the handler function
    pub fn addRoute(
        self: *RadixRouter,
        method: []const u8,
        pattern: []const u8,
        lua_ref: i32,
    ) !void {
        var node = self.root;
        var it = std.mem.splitScalar(u8, pattern, '/');

        while (it.next()) |segment| {
            if (segment.len == 0) continue; // Skip empty segments (leading /)

            // Check if this is a parameter segment {id}
            if (segment[0] == '{' and segment[segment.len - 1] == '}') {
                const param_name = segment[1 .. segment.len - 1];

                // Get or create param child
                if (node.param_child == null) {
                    const param_node = try Node.init(self.allocator, "");
                    const param = try self.allocator.create(Node.ParamChild);
                    param.* = .{
                        .param_name = try self.allocator.dupe(u8, param_name),
                        .node = param_node,
                    };
                    node.param_child = param;
                }

                node = node.param_child.?.node;
            } else {
                // Static segment - get or create child
                const gop = try node.children.getOrPut(segment);
                if (!gop.found_existing) {
                    // Create new node with duplicated segment (owned by us)
                    const segment_copy = try self.allocator.dupe(u8, segment);
                    gop.key_ptr.* = segment_copy; // Update HashMap key to use our copy
                    const child_node = try Node.init(self.allocator, segment_copy);
                    gop.value_ptr.* = child_node;
                }
                node = gop.value_ptr.*;
            }
        }

        // At leaf node - add handler for this method
        if (node.handler == null) {
            node.handler = .{
                .methods = std.StringHashMap(i32).init(self.allocator),
            };
        }

        const method_copy = try self.allocator.dupe(u8, method);
        try node.handler.?.methods.put(method_copy, lua_ref);
    }

    /// Match a request against the radix tree
    /// Returns lua_ref if match found, null otherwise
    /// params_out is a pre-allocated HashMap that will be populated with parameters
    /// This function does ZERO allocations (except HashMap.put for params)
    pub fn match(
        self: *RadixRouter,
        method: []const u8,
        path: []const u8,
        params_out: *std.StringHashMap([]const u8),
    ) ?i32 {
        var node = self.root;
        var start: usize = 1; // Skip leading '/'

        // Walk the tree without allocating
        while (start < path.len) {
            const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
            const segment = path[start..end];

            // Try static children first (exact match)
            if (node.children.get(segment)) |child| {
                node = child;
            } else if (node.param_child) |param| {
                // Parameter match - store in caller's hashmap
                params_out.put(param.param_name, segment) catch return null;
                node = param.node;
            } else {
                // No match found
                return null;
            }

            start = end + 1;
        }

        // Check if we have a handler for this method at this node
        if (node.handler) |h| {
            return h.methods.get(method);
        }

        return null;
    }

    /// Clean up router resources
    pub fn deinit(self: *RadixRouter) void {
        self.root.deinit();
    }
};

// Tests
test "radix router: simple static route" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", 1);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();

    const result = router.match("GET", "/users", &params);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 1), result.?);
    try std.testing.expectEqual(@as(usize, 0), params.count());
}

test "radix router: parameterized route" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users/{id}", 2);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();

    const result = router.match("GET", "/users/123", &params);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 2), result.?);
    try std.testing.expectEqual(@as(usize, 1), params.count());

    const id = params.get("id").?;
    try std.testing.expectEqualStrings("123", id);
}

test "radix router: multiple params" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/posts/{post_id}/comments/{id}", 3);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();

    const result = router.match("GET", "/posts/42/comments/7", &params);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 3), result.?);
    try std.testing.expectEqual(@as(usize, 2), params.count());

    try std.testing.expectEqualStrings("42", params.get("post_id").?);
    try std.testing.expectEqualStrings("7", params.get("id").?);
}

test "radix router: method mismatch" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    try router.addRoute("POST", "/users", 4);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();

    const result = router.match("GET", "/users", &params);
    try std.testing.expect(result == null);
}

test "radix router: shared prefix" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", 1);
    try router.addRoute("GET", "/users/{id}", 2);
    try router.addRoute("GET", "/users/{id}/posts", 3);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();

    // Test /users
    const r1 = router.match("GET", "/users", &params);
    try std.testing.expectEqual(@as(i32, 1), r1.?);
    params.clearRetainingCapacity();

    // Test /users/123
    const r2 = router.match("GET", "/users/123", &params);
    try std.testing.expectEqual(@as(i32, 2), r2.?);
    try std.testing.expectEqualStrings("123", params.get("id").?);
    params.clearRetainingCapacity();

    // Test /users/456/posts
    const r3 = router.match("GET", "/users/456/posts", &params);
    try std.testing.expectEqual(@as(i32, 3), r3.?);
    try std.testing.expectEqualStrings("456", params.get("id").?);
}

test "radix router: no match" {
    const allocator = std.testing.allocator;

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", 1);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();

    const result = router.match("GET", "/posts", &params);
    try std.testing.expect(result == null);
}
