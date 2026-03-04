const std = @import("std");

/// Classic BPF module for SO_REUSEPORT connection affinity.
///
/// Single public function: `attachAffinity` builds a BPF program on the stack
/// and attaches it to a socket so the kernel routes connections deterministically
/// to worker threads based on RX hash.

const sock_filter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,

    fn stmt(code: u16, k: u32) sock_filter {
        return .{ .code = code, .jt = 0, .jf = 0, .k = k };
    }
};

const sock_fprog = extern struct {
    len: u16,
    filter: [*]const sock_filter,
};

// BPF instruction classes
const BPF_LD = 0x00;
const BPF_ALU = 0x04;
const BPF_RET = 0x06;

// BPF load/store modes
const BPF_ABS = 0x20;
const BPF_W = 0x00;

// BPF ALU operations
const BPF_MOD = 0x90;
const BPF_A = 0x10;

// BPF special offsets
const SKF_AD_OFF = -0x1000;
const SKF_AD_RXHASH = 32;

// Socket constants
const SO_ATTACH_REUSEPORT_CBPF = 51;

const BpfProgram = struct {
    insns: [3]sock_filter,
    len: u16,
};

fn buildProgram(num_workers: u32) error{InvalidWorkerCount}!BpfProgram {
    if (num_workers == 0) return error.InvalidWorkerCount;
    if (num_workers == 1) {
        // Single worker: return constant 0
        return .{
            .insns = .{
                sock_filter.stmt(BPF_RET, 0),
                undefined,
                undefined,
            },
            .len = 1,
        };
    }

    return .{
        .insns = .{
            // A = skb->rxhash
            sock_filter.stmt(
                BPF_LD | BPF_W | BPF_ABS,
                @as(u32, @bitCast(@as(i32, SKF_AD_OFF + SKF_AD_RXHASH))),
            ),
            // A = A % num_workers
            sock_filter.stmt(BPF_ALU | BPF_MOD, num_workers),
            // return A
            sock_filter.stmt(BPF_RET | BPF_A, 0),
        },
        .len = 3,
    };
}

/// Attach a BPF program to `socket` that routes connections to one of
/// `num_workers` workers based on the kernel RX hash. No allocator needed.
pub fn attachAffinity(socket: std.posix.socket_t, num_workers: u32) !void {
    var prog = try buildProgram(num_workers);

    const fprog = sock_fprog{
        .len = prog.len,
        .filter = &prog.insns,
    };

    try std.posix.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        SO_ATTACH_REUSEPORT_CBPF,
        std.mem.asBytes(&fprog),
    );
}

// Tests

test "buildProgram - single worker returns constant 0" {
    const prog = try buildProgram(1);
    try std.testing.expectEqual(@as(u16, 1), prog.len);
    // BPF_RET with k=0 (return constant 0, not accumulator)
    try std.testing.expectEqual(BPF_RET, prog.insns[0].code);
    try std.testing.expectEqual(@as(u32, 0), prog.insns[0].k);
}

test "buildProgram - multiple workers" {
    const prog = try buildProgram(8);
    try std.testing.expectEqual(@as(u16, 3), prog.len);

    // Instruction 0: Load RX hash
    try std.testing.expectEqual(BPF_LD | BPF_W | BPF_ABS, prog.insns[0].code);

    // Instruction 1: Modulo by worker count
    try std.testing.expectEqual(BPF_ALU | BPF_MOD, prog.insns[1].code);
    try std.testing.expectEqual(@as(u32, 8), prog.insns[1].k);

    // Instruction 2: Return accumulator
    try std.testing.expectEqual(BPF_RET | BPF_A, prog.insns[2].code);
}

test "buildProgram - zero workers is error" {
    try std.testing.expectError(error.InvalidWorkerCount, buildProgram(0));
}

test "buildProgram - various worker counts" {
    const counts = [_]u32{ 2, 4, 8, 16, 32 };
    for (counts) |count| {
        const prog = try buildProgram(count);
        try std.testing.expectEqual(@as(u16, 3), prog.len);
        try std.testing.expectEqual(@as(u32, count), prog.insns[1].k);
    }
}
