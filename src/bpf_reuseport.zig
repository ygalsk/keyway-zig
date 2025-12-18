const std = @import("std");

/// Classic BPF module for SO_REUSEPORT connection affinity
/// Deep module: Simple interface, complex implementation
///
/// This module generates classic BPF (cBPF) bytecode that hashes incoming
/// connections based on source IP and port, ensuring all connections from
/// the same client hit the same worker thread (and thus the same Lua state).
/// BPF instruction structure (from linux/filter.h)
pub const sock_filter = extern struct {
    code: u16, // Opcode
    jt: u8, // Jump if true
    jf: u8, // Jump if false
    k: u32, // Generic value

    pub fn stmt(code: u16, k: u32) sock_filter {
        return .{ .code = code, .jt = 0, .jf = 0, .k = k };
    }

    pub fn jump(code: u16, k: u32, jt: u8, jf: u8) sock_filter {
        return .{ .code = code, .jt = jt, .jf = jf, .k = k };
    }
};

/// BPF program structure (from linux/filter.h)
pub const sock_fprog = extern struct {
    len: u16, // Number of filter instructions
    filter: [*]const sock_filter, // Pointer to filter array
};

// BPF instruction classes (from linux/filter.h)
const BPF_LD = 0x00; // Load
const BPF_ALU = 0x04; // ALU operations
const BPF_RET = 0x06; // Return

// BPF load/store modes
const BPF_ABS = 0x20; // Absolute offset
const BPF_W = 0x00; // Word (32-bit)
const BPF_H = 0x08; // Half-word (16-bit)

// BPF ALU operations
const BPF_ADD = 0x00;
const BPF_XOR = 0x30;
const BPF_LSH = 0x60; // Left shift
const BPF_MOD = 0x90;
const BPF_A = 0x10; // Accumulator

// BPF special offsets (SKF_AD_OFF from linux/filter.h)
const SKF_AD_OFF = -0x1000;
const SKF_AD_PROTOCOL = 0; // Protocol (IPv4/IPv6)
const SKF_AD_PKTTYPE = 4;
const SKF_AD_IFINDEX = 8;
const SKF_AD_NLATTR = 12;
const SKF_AD_NLATTR_NEST = 16;
const SKF_AD_MARK = 20;
const SKF_AD_QUEUE = 24;
const SKF_AD_HATYPE = 28;
const SKF_AD_RXHASH = 32; // RX hash (from kernel)
const SKF_AD_CPU = 36;

// Socket constants
pub const SO_ATTACH_REUSEPORT_CBPF = 51; // From linux/socket.h

/// Generate classic BPF program for SO_REUSEPORT connection affinity
///
/// The BPF program hashes the connection using:
///   hash = SKF_AD_RXHASH (kernel-provided RX hash)
///   worker = hash % num_workers
///
/// This is simpler and more reliable than manually hashing IP/port fields,
/// as the kernel already provides a well-distributed hash.
pub fn generateBpfProgram(allocator: std.mem.Allocator, num_workers: u32) ![]sock_filter {
    if (num_workers == 0) return error.InvalidWorkerCount;
    if (num_workers == 1) {
        // Single worker: just return 0
        var program = try allocator.alloc(sock_filter, 1);
        program[0] = sock_filter.stmt(BPF_RET | BPF_A, 0);
        return program;
    }

    // BPF program:
    // 1. Load SKF_AD_RXHASH (kernel RX hash) into accumulator
    // 2. Modulo by num_workers
    // 3. Return accumulator (worker index)
    var program = try allocator.alloc(sock_filter, 3);

    // A = skb->rxhash (load kernel RX hash)
    program[0] = sock_filter.stmt(
        BPF_LD | BPF_W | BPF_ABS,
        @as(u32, @bitCast(@as(i32, SKF_AD_OFF + SKF_AD_RXHASH))),
    );

    // A = A % num_workers
    program[1] = sock_filter.stmt(BPF_ALU | BPF_MOD, num_workers);

    // return A
    program[2] = sock_filter.stmt(BPF_RET | BPF_A, 0);

    return program;
}

/// Attach BPF program to socket for SO_REUSEPORT affinity
///
/// This must be called on one of the SO_REUSEPORT socket group members.
/// The BPF filter will apply to all sockets in the group.
pub fn attachToSocket(socket: std.posix.socket_t, program: []const sock_filter) !void {
    if (program.len == 0) return error.EmptyBpfProgram;
    if (program.len > 4096) return error.BpfProgramTooLarge; // Kernel limit

    const fprog = sock_fprog{
        .len = @intCast(program.len),
        .filter = program.ptr,
    };

    const fprog_bytes = std.mem.asBytes(&fprog);

    std.posix.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        SO_ATTACH_REUSEPORT_CBPF,
        fprog_bytes,
    ) catch |err| {
        // Common errors:
        // - ENOPROTOOPT: Kernel doesn't support SO_ATTACH_REUSEPORT_CBPF (pre-4.5)
        // - EINVAL: BPF program validation failed
        // - EPERM: Missing CAP_NET_RAW capability
        return err;
    };
}

/// Detach BPF program from socket (set to null program)
pub fn detachFromSocket(socket: std.posix.socket_t) !void {
    const fprog = sock_fprog{
        .len = 0,
        .filter = undefined,
    };

    const fprog_bytes = std.mem.asBytes(&fprog);

    try std.posix.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        SO_ATTACH_REUSEPORT_CBPF,
        fprog_bytes,
    );
}

// Tests
test "BPF program generation - single worker" {
    const allocator = std.testing.allocator;

    const program = try generateBpfProgram(allocator, 1);
    defer allocator.free(program);

    try std.testing.expectEqual(@as(usize, 1), program.len);
    try std.testing.expectEqual(BPF_RET | BPF_A, program[0].code);
}

test "BPF program generation - multiple workers" {
    const allocator = std.testing.allocator;

    const program = try generateBpfProgram(allocator, 8);
    defer allocator.free(program);

    try std.testing.expectEqual(@as(usize, 3), program.len);

    // Check instruction 0: Load RX hash
    try std.testing.expectEqual(BPF_LD | BPF_W | BPF_ABS, program[0].code);

    // Check instruction 1: Modulo
    try std.testing.expectEqual(BPF_ALU | BPF_MOD, program[1].code);
    try std.testing.expectEqual(@as(u32, 8), program[1].k);

    // Check instruction 2: Return
    try std.testing.expectEqual(BPF_RET | BPF_A, program[2].code);
}

test "BPF program generation - zero workers" {
    const allocator = std.testing.allocator;

    const result = generateBpfProgram(allocator, 0);
    try std.testing.expectError(error.InvalidWorkerCount, result);
}

test "BPF program generation - power of two workers" {
    const allocator = std.testing.allocator;

    // Test various worker counts
    const worker_counts = [_]u32{ 2, 4, 8, 16, 32 };

    for (worker_counts) |count| {
        const program = try generateBpfProgram(allocator, count);
        defer allocator.free(program);

        try std.testing.expectEqual(@as(usize, 3), program.len);
        try std.testing.expectEqual(@as(u32, count), program[1].k);
    }
}
