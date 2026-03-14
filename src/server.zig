const std = @import("std");
const xev = @import("xev");
const Connection = @import("handler.zig").Connection;
const Router = @import("router.zig").Router;
const LuaState = @import("lua_state.zig").LuaState;
const bpf_reuseport = @import("bpf_reuseport.zig");
const TlsContext = @import("tls.zig").TlsContext;
const castUserdata = @import("helpers.zig").castUserdata;
const SseRegistry = @import("sse.zig").SseRegistry;
const tuning = @import("config.zig");
const WorkerMetrics = @import("metrics.zig").WorkerMetrics;

// TCP socket configuration
const DEFAULT_BACKLOG = tuning.DEFAULT_BACKLOG;

/// TCP Server - Deep module with simple interface
/// Handles socket creation, binding, listening, and accepting connections
pub const Server = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    socket: std.posix.socket_t,
    address: std.net.Address,
    accept_completion: xev.Completion,
    router: *Router,
    lua_state: *LuaState,
    tls_ctx: ?TlsContext,
    sse_registry: ?*SseRegistry,
    metrics: *WorkerMetrics,
    draining: bool = false,
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Server configuration
    pub const Config = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 8080,
        enable_bpf_affinity: bool = false,
        tls_cert_path: ?[*:0]const u8 = null,
        tls_key_path: ?[*:0]const u8 = null,
    };

    /// Initialize server
    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        config: Config,
        router: *Router,
        lua_state: *LuaState,
        num_workers: u32,
        worker_id: u32,
        bpf_ready: ?*std.atomic.Value(bool),
        sse_registry: ?*SseRegistry,
        metrics: *WorkerMetrics,
    ) !Server {
        // Parse address
        const addr = try std.net.Address.parseIp(config.host, config.port);

        // Create socket
        const socket = try std.posix.socket(
            addr.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        );
        errdefer std.posix.close(socket);

        // Set socket options
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        // Enable SO_REUSEPORT for multi-threading
        // Allows multiple threads to bind to the same port
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        // BPF affinity requires ordered startup:
        // Worker 0 must attach BPF -> bind -> listen BEFORE other workers bind.
        // The kernel requires BPF to be attached before bind() on the first socket
        // (see kernel selftest tools/testing/selftests/net/reuseport_bpf.c).
        if (config.enable_bpf_affinity and num_workers > 1) {
            if (worker_id == 0) {
                // Worker 0: attach BPF, then bind, then listen, then signal others
                bpf_reuseport.attachAffinity(socket, num_workers) catch |err| {
                    std.log.warn("BPF affinity unavailable: {} (connections may hit different Lua states)", .{err});
                };
                std.log.info("BPF connection affinity enabled for {} workers", .{num_workers});

                try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
                try std.posix.listen(socket, DEFAULT_BACKLOG);

                if (bpf_ready) |ready| {
                    ready.store(true, .release);
                }
            } else {
                // Non-zero workers: wait for Worker 0 to fully establish the group
                if (bpf_ready) |ready| {
                    while (!ready.load(.acquire)) {
                        std.atomic.spinLoopHint();
                    }
                }
                try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
                try std.posix.listen(socket, DEFAULT_BACKLOG);
            }
        } else {
            // No BPF: all workers bind+listen independently (SO_REUSEPORT handles distribution)
            try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
            try std.posix.listen(socket, DEFAULT_BACKLOG);
        }

        // Initialize TLS context if cert+key are configured
        const tls_ctx: ?TlsContext = if (config.tls_cert_path != null and config.tls_key_path != null)
            try TlsContext.init(config.tls_cert_path.?, config.tls_key_path.?)
        else
            null;

        if (tls_ctx == null and (config.tls_cert_path != null or config.tls_key_path != null)) {
            std.log.warn("TLS disabled: both --tls-cert and --tls-key are required", .{});
        }

        return Server{
            .allocator = allocator,
            .loop = loop,
            .socket = socket,
            .address = addr,
            .accept_completion = undefined,
            .router = router,
            .lua_state = lua_state,
            .tls_ctx = tls_ctx,
            .sse_registry = sse_registry,
            .metrics = metrics,
        };
    }

    /// Start accepting connections
    pub fn start(self: *Server) !void {
        self.acceptNext();
    }

    fn acceptNext(self: *Server) void {
        self.accept_completion = .{
            .op = .{
                .accept = .{
                    .socket = self.socket,
                },
            },
            .userdata = self,
            .callback = onAccept,
        };
        self.loop.add(&self.accept_completion);
    }

    fn onAccept(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = completion;

        const self = castUserdata(Server, userdata);

        const client_socket = result.accept catch |err| {
            // During shutdown, accept errors are expected (listen socket closed)
            if (self.draining) return .disarm;
            std.log.err("accept failed err={}", .{err});
            self.acceptNext();
            return .disarm;
        };

        // If draining, reject new connections
        if (self.draining) {
            std.posix.close(client_socket);
            return .disarm;
        }

        // Set TCP_NODELAY to disable Nagle's algorithm (reduce latency)
        std.posix.setsockopt(
            client_socket,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch |err| {
            std.log.err("setsockopt TCP_NODELAY failed err={}", .{err});
        };

        // Track active connections (for health endpoint and drain logging)
        _ = self.active_connections.fetchAdd(1, .monotonic);
        self.metrics.incrementActiveConnections();

        // Create connection handler
        const conn = Connection.init(
            self.allocator,
            loop,
            client_socket,
            self.router,
            self.lua_state,
            self.sse_registry,
        ) catch |err| {
            std.log.err("connection init failed err={}", .{err});
            std.posix.close(client_socket);
            self.acceptNext();
            return .disarm;
        };

        // Initialize TLS if configured
        if (self.tls_ctx) |*tc| {
            conn.initTls(tc) catch |err| {
                std.log.err("TLS init failed err={}", .{err});
                conn.deinit(self.allocator);
                self.acceptNext();
                return .disarm;
            };
        }

        // Start reading from connection
        conn.startRead();

        // Register next accept
        self.acceptNext();
        return .disarm;
    }

    /// Stop accepting new connections (called on drain signal).
    pub fn stopAccepting(self: *Server) void {
        self.draining = true;
    }

    /// Close idle keep-alive connections (no in-flight request).
    /// Currently a no-op; connections check draining flag in post-write path.
    pub fn closeIdleConnections(_: *Server) void {
        // Idle keep-alive connections will close after their current request
        // completes, because handleHttpPostWrite checks server.draining.
        // There's no connection list to iterate — xev tracks armed completions.
    }

    /// Force-close all connections by closing the listen socket.
    /// Armed completions on the listen fd will fail, cascading cleanup.
    pub fn forceCloseAll(self: *Server) void {
        // Closing the listen socket causes pending accept to fail.
        // Individual connections will get errors on their next I/O.
        std.posix.close(self.socket);
        // Re-assign to invalid fd to prevent double-close in deinit
        self.socket = -1;
    }

    /// Clean up server resources
    pub fn deinit(self: *Server) void {
        if (self.tls_ctx) |*tc| tc.deinit();
        if (self.socket != -1) std.posix.close(self.socket);
    }
};

test "server init and deinit" {
    const allocator = std.testing.allocator;

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var router = try Router.init(allocator);
    defer router.deinit();

    var lua_state = try LuaState.init(allocator);
    defer lua_state.deinit();

    const server_config = Server.Config{
        .host = "127.0.0.1",
        .port = 0, // Let OS assign port
    };

    var test_metrics = WorkerMetrics.init();
    var server = try Server.init(allocator, &loop, server_config, &router, &lua_state, 1, 0, null, null, &test_metrics);
    defer server.deinit();
}
