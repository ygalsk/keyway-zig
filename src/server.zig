const std = @import("std");
const xev = @import("xev");
const Loop = @import("loop.zig").Loop;
const Connection = @import("handler.zig").Connection;
const RadixRouter = @import("radix_router.zig").RadixRouter;
const LuaState = @import("lua_state.zig").LuaState;
const bpf_reuseport = @import("bpf_reuseport.zig");

// TCP socket configuration
const DEFAULT_BACKLOG: u31 = 128;

/// TCP Server - Deep module with simple interface
/// Handles socket creation, binding, listening, and accepting connections
pub const Server = struct {
    allocator: std.mem.Allocator,
    loop: *Loop,
    socket: std.posix.socket_t,
    address: std.net.Address,
    accept_completion: xev.Completion,
    router: *RadixRouter,
    lua_state: *LuaState,

    /// Server configuration
    pub const Config = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
        enable_bpf_affinity: bool = false, // Enable BPF connection affinity (disabled by default due to race conditions)
    };

    /// Initialize server
    pub fn init(
        allocator: std.mem.Allocator,
        loop: *Loop,
        config: Config,
        router: *RadixRouter,
        lua_state: *LuaState,
        num_workers: u32,
        worker_id: u32,
        bpf_ready: ?*std.atomic.Value(bool),
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

        // Bind
        try std.posix.bind(socket, &addr.any, addr.getOsSockLen());

        // Synchronization: All workers must reach this point before Worker 0 attaches BPF
        // This ensures Worker 0 calls listen() FIRST
        if (config.enable_bpf_affinity and num_workers > 1) {
            if (bpf_ready) |ready| {
                if (worker_id != 0) {
                    // Other workers: Wait for Worker 0 to attach BPF
                    while (!ready.load(.acquire)) {
                        std.atomic.spinLoopHint();
                    }
                }
                // Worker 0 continues immediately to attach BPF
            }
        }

        // Attach BPF filter for connection affinity (only first worker)
        // BPF filter applies to all sockets in SO_REUSEPORT group
        // CRITICAL: Must attach BPF BEFORE any worker calls listen()
        blk: {
            if (!config.enable_bpf_affinity or worker_id != 0 or num_workers <= 1) break :blk;

            const bpf_prog = bpf_reuseport.generateBpfProgram(allocator, num_workers) catch |err| {
                std.log.warn("BPF affinity unavailable: {} (connections may hit different Lua states)", .{err});
                break :blk;
            };
            defer allocator.free(bpf_prog);

            bpf_reuseport.attachToSocket(socket, bpf_prog) catch |err| {
                std.log.warn("BPF attachment failed: {} (connections may hit different Lua states)", .{err});
                break :blk;
            };

            std.log.info("BPF connection affinity enabled for {} workers", .{num_workers});
        }

        // Worker 0 signals completion, allowing other workers to proceed to listen()
        if (config.enable_bpf_affinity and num_workers > 1 and worker_id == 0) {
            if (bpf_ready) |ready| {
                ready.store(true, .release);
            }
        }

        // Listen
        try std.posix.listen(socket, DEFAULT_BACKLOG);

        // std.log.info("Server listening on {s}:{d}", .{ config.host, config.port });

        return Server{
            .allocator = allocator,
            .loop = loop,
            .socket = socket,
            .address = addr,
            .accept_completion = undefined,
            .router = router,
            .lua_state = lua_state,
        };
    }

    /// Start accepting connections
    pub fn start(self: *Server) !void {
        // std.log.info("Server ready to accept connections", .{});
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
        self.loop.xev_loop.add(&self.accept_completion);
    }

    fn onAccept(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        completion: *xev.Completion,
        result: xev.Result,
    ) xev.CallbackAction {
        _ = completion;

        const self: *Server = @ptrCast(@alignCast(userdata.?));

        const client_socket = result.accept catch |err| {
            std.log.err("Accept failed: {}", .{err});
            self.acceptNext();
            return .disarm;
        };

        // std.log.info("Accepted connection: {}", .{client_socket});

        // Set TCP_NODELAY to disable Nagle's algorithm (reduce latency)
        std.posix.setsockopt(
            client_socket,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch |err| {
            std.log.err("Failed to set TCP_NODELAY: {}", .{err});
        };

        // Create connection handler
        const conn = Connection.init(
            self.allocator,
            loop,
            client_socket,
            self.router,
            self.lua_state,
        ) catch |err| {
            std.log.err("Connection init failed: {}", .{err});
            std.posix.close(client_socket);
            self.acceptNext();
            return .disarm;
        };

        // Start reading from connection
        conn.startRead();

        // Register next accept
        self.acceptNext();
        return .disarm;
    }

    /// Stop server
    pub fn stop(self: *Server) void {
        _ = self;
        // std.log.info("Server stopping...", .{});
    }

    /// Clean up server resources
    pub fn deinit(self: *Server) void {
        std.posix.close(self.socket);
    }
};

test "server init and deinit" {
    const allocator = std.testing.allocator;

    var loop = try Loop.init(allocator);
    defer loop.deinit();

    var router = try RadixRouter.init(allocator);
    defer router.deinit();

    var lua_state = try LuaState.init(allocator, &router);
    defer lua_state.deinit();

    const config = Server.Config{
        .host = "127.0.0.1",
        .port = 0, // Let OS assign port
    };

    var server = try Server.init(allocator, &loop, config, &router, &lua_state, 1, 0, null);
    defer server.deinit();
}
