const std = @import("std");
const log = @import("../observability/log.zig");
const params = @import("params.zig");

/// Radix tree node for efficient route matching
/// O(path_length) lookup instead of O(n) linear search
const Node = struct {
    allocator: std.mem.Allocator,

    // Children for static segments (map segment -> node)
    children: std.StringHashMap(*Node),

    // Parameter child (e.g., {id} parameter)
    param_child: ?*ParamChild,

    // HTTP method -> Lua registry reference map at this leaf node (if any)
    methods: ?std.StringHashMap(i32),

    // Route pattern string (e.g., "/users/{id}"), set on leaf nodes by addRoute
    pattern: []const u8 = "",

    const ParamChild = struct {
        param_name: []const u8,
        node: *Node,
    };

    fn init(allocator: std.mem.Allocator) !*Node {
        const node = try allocator.create(Node);
        node.* = Node{
            .allocator = allocator,
            .children = std.StringHashMap(*Node).init(allocator),
            .param_child = null,
            .methods = null,
        };
        return node;
    }

    fn deinit(self: *Node) void {
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

        // pattern is NOT freed here — it's an interned string owned by the
        // Router's intern pool (see Router.internPattern), which deliberately
        // outlives reset()/node teardown so callers who capture a matched
        // pattern (route_pattern, timing.route, Prometheus labels) don't hold
        // a dangling slice across a hot-reload (#225).

        // Free handler methods map
        if (self.methods) |*m| {
            var mit = m.iterator();
            while (mit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            m.deinit();
        }

        self.allocator.destroy(self);
    }
};

const MountMatch = struct { index: usize, suffix: []const u8 };

/// Longest-prefix match over a mount routes slice (T must have a `prefix:
/// []const u8` field), aligned on a path segment boundary — "/abc" does not
/// match mount "/a". O(mounts): real configs have a handful, indistinguishable
/// from a trie at that scale.
fn matchMountPrefix(comptime T: type, routes: []const T, path: []const u8) ?MountMatch {
    var best: ?MountMatch = null;
    for (routes, 0..) |route, i| {
        const p = route.prefix;
        if (path.len < p.len or !std.mem.startsWith(u8, path, p)) continue;
        const at_boundary = path.len == p.len or path[p.len] == '/' or (p.len > 0 and p[p.len - 1] == '/');
        if (!at_boundary) continue;
        if (best == null or p.len >= routes[best.?.index].prefix.len) {
            best = .{ .index = i, .suffix = path[p.len..] };
        }
    }
    return best;
}

/// Static file route configuration (from keyway.static).
pub const StaticRoute = struct {
    prefix: []const u8,
    root: []const u8,
    real_root: []const u8, // resolved at registration (avoids per-request realpathAlloc)
    index: []const u8,
};

/// Reverse proxy route configuration.
pub const ProxyRoute = struct {
    prefix: []const u8, // e.g. "/__keyway/grafana"
    upstream_host: []const u8, // e.g. "127.0.0.1" — kept for the upstream Host header
    upstream_port: u16, // e.g. 3000
    upstream_addr: std.Io.net.IpAddress, // resolved once at registration (no per-request DNS)
    redirect: ?[]const u8 = null, // if set, bare prefix requests 302 to this URL
    strip_prefix: bool = true, // if false, forward the full path to upstream
};

/// Segment-level trie router — O(path_length) route matching
pub const Router = struct {
    allocator: std.mem.Allocator,
    root: *Node,
    static_routes: std.ArrayListUnmanaged(StaticRoute) = .empty,
    proxy_routes: std.ArrayListUnmanaged(ProxyRoute) = .empty,

    // Route pattern strings, deduped and owned independently of the trie.
    // Patterns are a small, bounded set fixed at route-load time, so this
    // stays small even under repeated `--watch` reloads. Deliberately NOT
    // freed by reset() — see internPattern() and node.pattern (#225).
    intern: std.StringHashMapUnmanaged(void) = .empty,

    /// Initialize radix router
    pub fn init(allocator: std.mem.Allocator) !Router {
        const root = try Node.init(allocator);
        return Router{
            .allocator = allocator,
            .root = root,
        };
    }

    /// Register a static file serving route.
    /// Resolves the real root path at registration time to avoid per-request realpathAlloc.
    pub fn addStaticRoute(self: *Router, prefix: []const u8, root_dir: []const u8, index: []const u8) !void {
        const prefix_copy = try self.allocator.dupe(u8, prefix);
        const root_copy = try self.allocator.dupe(u8, root_dir);
        var route_io: std.Io.Threaded = .init(self.allocator, .{});
        defer route_io.deinit();
        var root_handle = try std.Io.Dir.cwd().openDir(route_io.io(), root_dir, .{});
        defer root_handle.close(route_io.io());
        var real_root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_root_len = try root_handle.realPath(route_io.io(), &real_root_buf);
        const real_root = try self.allocator.dupe(u8, real_root_buf[0..real_root_len]);
        const index_copy = try self.allocator.dupe(u8, index);
        try self.static_routes.append(self.allocator, .{
            .prefix = prefix_copy,
            .root = root_copy,
            .real_root = real_root,
            .index = index_copy,
        });
    }

    pub const StaticMatch = PrefixMatch(StaticRoute);

    /// Match a path against static route prefixes (longest prefix wins).
    pub fn matchStatic(self: *const Router, path: []const u8) ?StaticMatch {
        const m = matchMountPrefix(StaticRoute, self.static_routes.items, path) orelse return null;
        return .{ .route = self.static_routes.items[m.index], .suffix = m.suffix };
    }

    /// Register a reverse proxy route.
    /// Resolves the upstream host to an address at registration time (blocking here
    /// is fine — it's config load, not the request hot path) so the proactor data
    /// path never blocks on DNS. Mirrors nginx's resolve-at-config default.
    pub fn addProxyRoute(self: *Router, prefix: []const u8, upstream_host: []const u8, upstream_port: u16, redirect: []const u8, strip_prefix: bool) !void {
        const upstream_addr = try resolveUpstream(self.allocator, upstream_host, upstream_port);

        const prefix_copy = try self.allocator.dupe(u8, prefix);
        const host_copy = try self.allocator.dupe(u8, upstream_host);
        const redirect_copy: ?[]const u8 = if (redirect.len > 0) try self.allocator.dupe(u8, redirect) else null;
        try self.proxy_routes.append(self.allocator, .{
            .prefix = prefix_copy,
            .upstream_host = host_copy,
            .upstream_port = upstream_port,
            .upstream_addr = upstream_addr,
            .redirect = redirect_copy,
            .strip_prefix = strip_prefix,
        });
    }

    /// Resolve an upstream host:port to an address once, at route registration.
    /// Literal IPs parse without I/O; hostnames fall back to a blocking DNS
    /// lookup (registration-time only — the request hot path never resolves).
    fn resolveUpstream(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.Io.net.IpAddress {
        if (std.Io.net.IpAddress.parse(host, port)) |addr| return addr else |_| {}

        const hostname = try std.Io.net.HostName.init(host);
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var lookup_buf: [8]std.Io.net.HostName.LookupResult = undefined;
        var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buf);
        var lookup_future = io.async(std.Io.net.HostName.lookup, .{ hostname, io, &queue, .{ .port = port } });
        defer lookup_future.cancel(io) catch {};

        while (queue.getOne(io)) |result| {
            switch (result) {
                .address => |addr| return addr,
                .canonical_name => {},
            }
        } else |_| {}

        log.err().string("msg", "proxy upstream has no address").string("host", host).log();
        return error.UnknownHostName;
    }

    pub const ProxyMatch = PrefixMatch(ProxyRoute);

    /// Match a path against proxy route prefixes (longest prefix wins).
    pub fn matchProxy(self: *const Router, path: []const u8) ?ProxyMatch {
        const m = matchMountPrefix(ProxyRoute, self.proxy_routes.items, path) orelse return null;
        return .{ .route = self.proxy_routes.items[m.index], .suffix = m.suffix };
    }

    /// Add a route to the radix tree
    /// Pattern format: /users/{id} or /posts/{post_id}/comments
    /// lua_ref is the Lua registry reference to the handler function
    pub fn addRoute(
        self: *Router,
        method: []const u8,
        pattern: []const u8,
        lua_ref: i32,
    ) !void {
        // Validate param count doesn't exceed ParamArray capacity
        var param_count: usize = 0;
        var count_it = std.mem.splitScalar(u8, pattern, '/');
        while (count_it.next()) |seg| {
            if (seg.len >= 2 and seg[0] == '{' and seg[seg.len - 1] == '}') {
                param_count += 1;
            }
        }
        if (param_count > params.MAX_ROUTE_PARAMS) {
            log.err().string("msg", "route has too many params").string("pattern", pattern).int("count", param_count).int("max", params.MAX_ROUTE_PARAMS).log();
            return error.TooManyParams;
        }

        var node = self.root;
        var it = std.mem.splitScalar(u8, pattern, '/');

        while (it.next()) |segment| {
            if (segment.len == 0) continue; // Skip empty segments (leading /)

            // Check if this is a parameter segment {id}
            if (segment[0] == '{' and segment[segment.len - 1] == '}') {
                const param_name = segment[1 .. segment.len - 1];

                // Get or create param child
                if (node.param_child == null) {
                    const param_node = try Node.init(self.allocator);
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
                    // HashMap owns the duplicated segment key.
                    gop.key_ptr.* = segment_copy; // Update HashMap key to use our copy
                    const child_node = try Node.init(self.allocator);
                    gop.value_ptr.* = child_node;
                }
                node = gop.value_ptr.*;
            }
        }

        // At leaf node - add handler for this method
        if (node.methods == null) {
            node.methods = std.StringHashMap(i32).init(self.allocator);
        }

        // Store pattern on the leaf node (for Prometheus route labels).
        // Interned rather than node-owned so it survives Router.reset() (#225).
        if (node.pattern.len == 0) {
            node.pattern = try self.internPattern(pattern);
        }

        const method_copy = try self.allocator.dupe(u8, method);
        try node.methods.?.put(method_copy, lua_ref);
    }

    /// Return a stable, deduped copy of `pattern` owned by the Router's intern
    /// pool. Unlike trie-node-owned strings, interned strings are not freed by
    /// reset() — they live as long as the Router itself, so a pattern handed
    /// out via RouteMatch stays valid across a hot-reload even after the trie
    /// node that produced it is torn down (#225).
    fn internPattern(self: *Router, pattern: []const u8) ![]const u8 {
        const gop = try self.intern.getOrPut(self.allocator, pattern);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, pattern);
        }
        return gop.key_ptr.*;
    }

    pub const RouteMatch = struct { lua_ref: i32, pattern: []const u8 };

    /// Match a request against the radix tree
    /// Returns RouteMatch if match found, null otherwise
    /// params_out is an inline ParamArray that will be populated with parameters
    /// This function does ZERO allocations
    pub inline fn match(
        self: *Router,
        method: []const u8,
        path: []const u8,
        params_out: *params.ParamArray,
    ) error{TooManyParams}!?RouteMatch {
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
                // Parameter match - store in inline array (zero allocations!)
                try params_out.put(param.param_name, segment);
                node = param.node;
            } else {
                // No match found
                return null;
            }

            start = end + 1;
        }

        // Check if we have a handler for this method at this node
        if (node.methods) |mt| {
            if (mt.get(method)) |ref| {
                return .{ .lua_ref = ref, .pattern = node.pattern };
            }
        }

        return null;
    }

    /// Cold-path 405 helper: after `match` returns null, report whether `path`
    /// resolves to a routed node that has *some* method registered (→ 405 + Allow)
    /// vs no such path (→ 404). Walks the trie again — only on the miss path, so
    /// `match`'s hot path is untouched. Returns the leaf's method map, or null.
    pub fn methodsForPath(self: *Router, path: []const u8) ?*const std.StringHashMap(i32) {
        var node = self.root;
        var start: usize = 1; // skip leading '/'
        while (start < path.len) {
            const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
            const segment = path[start..end];
            if (node.children.get(segment)) |child| {
                node = child;
            } else if (node.param_child) |param| {
                node = param.node;
            } else {
                return null;
            }
            start = end + 1;
        }
        if (node.methods) |*mt| {
            if (mt.count() > 0) return mt;
        }
        return null;
    }

    /// Collect all lua_ref values from the trie (for unreffing before reset).
    pub fn collectLuaRefs(self: *const Router, alloc: std.mem.Allocator, refs: *std.ArrayListUnmanaged(i32)) !void {
        try collectNodeRefs(self.root, alloc, refs);
    }

    fn collectNodeRefs(node: *Node, alloc: std.mem.Allocator, refs: *std.ArrayListUnmanaged(i32)) !void {
        if (node.methods) |mt| {
            var it = mt.iterator();
            while (it.next()) |entry| {
                try refs.append(alloc, entry.value_ptr.*);
            }
        }
        var child_it = node.children.iterator();
        while (child_it.next()) |entry| {
            try collectNodeRefs(entry.value_ptr.*, alloc, refs);
        }
        if (node.param_child) |param| {
            try collectNodeRefs(param.node, alloc, refs);
        }
    }

    /// Free all static route string allocations.
    fn freeStaticRoutes(self: *Router) void {
        for (self.static_routes.items) |sr| {
            self.allocator.free(sr.prefix);
            self.allocator.free(sr.root);
            self.allocator.free(sr.real_root);
            self.allocator.free(sr.index);
        }
    }

    /// Free all proxy route string allocations.
    fn freeProxyRoutes(self: *Router) void {
        for (self.proxy_routes.items) |pr| {
            self.allocator.free(pr.prefix);
            self.allocator.free(pr.upstream_host);
            if (pr.redirect) |r| self.allocator.free(r);
        }
    }

    /// Reset the router: free the entire trie and all static/proxy routes, reinit fresh.
    pub fn reset(self: *Router) !void {
        self.freeStaticRoutes();
        self.static_routes.clearRetainingCapacity();
        self.freeProxyRoutes();
        self.proxy_routes.clearRetainingCapacity();

        // Free trie
        self.root.deinit();

        // Reinit fresh root
        self.root = try Node.init(self.allocator);
    }

    /// Returns true if no routes have been registered
    pub fn isEmpty(self: *const Router) bool {
        return self.root.children.count() == 0 and
            self.root.param_child == null and
            self.root.methods == null;
    }

    /// Clean up router resources
    pub fn deinit(self: *Router) void {
        self.freeStaticRoutes();
        self.static_routes.deinit(self.allocator);
        self.freeProxyRoutes();
        self.proxy_routes.deinit(self.allocator);
        self.root.deinit();

        // Intern pool outlives reset() by design — free it only here, on
        // Router teardown (process/worker shutdown), not on every reload.
        var it = self.intern.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.intern.deinit(self.allocator);
    }
};

/// Result of a prefix mount match: the matched route and the path suffix after
/// its prefix.
fn PrefixMatch(comptime T: type) type {
    return struct { route: T, suffix: []const u8 };
}

// Tests
test "prefix scan: longest match, suffix, and segment boundary" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    // Static routes are cheap to register and exercise the same scan as
    // matchProxy; addStaticRoute needs a real directory to resolve.
    try router.addStaticRoute("/a", ".", "index.html");
    try router.addStaticRoute("/a/b", ".", "index.html");

    // Shorter prefix matches, suffix is the remainder after the segment.
    const m1 = router.matchStatic("/a/x").?;
    try std.testing.expectEqualStrings("/a", m1.route.prefix);
    try std.testing.expectEqualStrings("/x", m1.suffix);

    // Longest prefix wins when nested.
    const m2 = router.matchStatic("/a/b/c").?;
    try std.testing.expectEqualStrings("/a/b", m2.route.prefix);
    try std.testing.expectEqualStrings("/c", m2.suffix);

    // Exact mount → empty suffix.
    const m3 = router.matchStatic("/a").?;
    try std.testing.expectEqualStrings("/a", m3.route.prefix);
    try std.testing.expectEqualStrings("", m3.suffix);

    // Must align on a segment boundary: "/abc" does not match "/a".
    try std.testing.expect(router.matchStatic("/abc") == null);

    // Unrelated path → no match.
    try std.testing.expect(router.matchStatic("/z") == null);
}

test "radix router: simple static route" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", 1);

    var p = params.ParamArray{};

    const result = try router.match("GET", "/users", &p);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 1), result.?.lua_ref);
    try std.testing.expectEqual(@as(usize, 0), p.len);
}

test "radix router: parameterized route" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users/{id}", 2);

    var p = params.ParamArray{};

    const result = try router.match("GET", "/users/123", &p);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 2), result.?.lua_ref);
    try std.testing.expectEqual(@as(usize, 1), p.len);

    const id = p.get("id").?;
    try std.testing.expectEqualStrings("123", id);
}

test "radix router: multiple params" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/posts/{post_id}/comments/{id}", 3);

    var p = params.ParamArray{};

    const result = try router.match("GET", "/posts/42/comments/7", &p);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 3), result.?.lua_ref);
    try std.testing.expectEqual(@as(usize, 2), p.len);

    try std.testing.expectEqualStrings("42", p.get("post_id").?);
    try std.testing.expectEqualStrings("7", p.get("id").?);
}

test "radix router: method mismatch" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("POST", "/users", 4);

    var p = params.ParamArray{};

    const result = try router.match("GET", "/users", &p);
    try std.testing.expect(result == null);
}

test "radix router: shared prefix" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", 1);
    try router.addRoute("GET", "/users/{id}", 2);
    try router.addRoute("GET", "/users/{id}/posts", 3);

    var p = params.ParamArray{};

    // Test /users
    const r1 = try router.match("GET", "/users", &p);
    try std.testing.expectEqual(@as(i32, 1), r1.?.lua_ref);
    p.clear();

    // Test /users/123
    const r2 = try router.match("GET", "/users/123", &p);
    try std.testing.expectEqual(@as(i32, 2), r2.?.lua_ref);
    try std.testing.expectEqualStrings("123", p.get("id").?);
    p.clear();

    // Test /users/456/posts
    const r3 = try router.match("GET", "/users/456/posts", &p);
    try std.testing.expectEqual(@as(i32, 3), r3.?.lua_ref);
    try std.testing.expectEqualStrings("456", p.get("id").?);
}

test "radix router: no match" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", 1);

    var p = params.ParamArray{};

    const result = try router.match("GET", "/posts", &p);
    try std.testing.expect(result == null);
}

test "security: path traversal in param is literal string" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/h/{id}", 1);

    var p = params.ParamArray{};

    // ".." is captured as a literal param value, not interpreted as directory traversal
    const r1 = try router.match("GET", "/h/..", &p);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("..", p.get("id").?);
    p.clear();

    // Extra segments beyond the route pattern → no match
    const r2 = try router.match("GET", "/h/../../etc/passwd", &p);
    try std.testing.expect(r2 == null);
    p.clear();

    // URL-encoded traversal is a literal string (picohttpparser doesn't decode)
    const r3 = try router.match("GET", "/h/..%2F..%2Fetc%2Fpasswd", &p);
    try std.testing.expect(r3 != null);
    try std.testing.expectEqualStrings("..%2F..%2Fetc%2Fpasswd", p.get("id").?);
}

test "router reset clears all routes" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users", 1);
    try router.addRoute("POST", "/users/{id}", 2);
    try std.testing.expect(!router.isEmpty());

    try router.reset();
    try std.testing.expect(router.isEmpty());

    // After reset, no routes match
    var p = params.ParamArray{};
    const result = try router.match("GET", "/users", &p);
    try std.testing.expect(result == null);
}

test "matched route pattern outlives Router.reset() (#225)" {
    // A WebSocket/SSE connection captures RouteMatch.pattern once at handshake
    // and never refreshes it, so if reset() frees the memory backing it, the
    // next read after a hot-reload is a use-after-free. Uses page_allocator
    // (not std.testing.allocator) because it munmaps on free with no bucket
    // reuse to mask the bug — a regression here crashes this test outright
    // instead of silently reading stale-but-still-mapped bytes.
    var router = try Router.init(std.heap.page_allocator);
    defer router.deinit();

    try router.addRoute("GET", "/users/{id}", 1);
    var p = params.ParamArray{};
    const before = (try router.match("GET", "/users/42", &p)).?;
    const captured: []const u8 = before.pattern;
    p.clear();

    try router.reset();
    try router.addRoute("GET", "/users/{id}", 2); // reload re-registers the same route

    try std.testing.expectEqualStrings("/users/{id}", captured);
}

test "collectLuaRefs gathers all refs" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/a", 10);
    try router.addRoute("POST", "/a", 20);
    try router.addRoute("GET", "/b/{id}", 30);

    var refs: std.ArrayListUnmanaged(i32) = .empty;
    defer refs.deinit(allocator);
    try router.collectLuaRefs(allocator, &refs);

    try std.testing.expectEqual(@as(usize, 3), refs.items.len);

    // All three refs should be present (order not guaranteed)
    var found: [3]bool = .{ false, false, false };
    for (refs.items) |ref| {
        if (ref == 10) found[0] = true;
        if (ref == 20) found[1] = true;
        if (ref == 30) found[2] = true;
    }
    try std.testing.expect(found[0] and found[1] and found[2]);
}

test "security: traversal does not escape route tree" {
    const allocator = std.testing.allocator;

    var router = try Router.init(allocator);
    defer router.deinit();

    try router.addRoute("GET", "/hooks/{id}", 1);

    var p = params.ParamArray{};

    // 3 segments vs 2-segment route → no match
    const r1 = try router.match("GET", "/hooks/../kv", &p);
    try std.testing.expect(r1 == null);
    p.clear();

    // 4 segments vs 2-segment route → no match
    const r2 = try router.match("GET", "/hooks/foo/../../", &p);
    try std.testing.expect(r2 == null);
}
