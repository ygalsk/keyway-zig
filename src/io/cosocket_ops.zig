//! Per-operation submit helpers for outbound cosocket I/O.
//!
//! All I/O flows through drainSubmissionRing in cosocket.zig.
//! Single-shot cosocket ops (connect/send/recv/close) are converted to
//! degenerate SQ entries by dispatchIo before reaching the drain loop.
//!
//! This module provides:
//!   - Batch submit helpers (submitBatchConnect, submitBatchUdpConnect)
//!   - Shared TLS/error helpers (encryptForSend, pushErrorTable, selectClientTlsCtx)
//!
//! After kTLS: send/recv are plaintext — the kernel handles crypto transparently.

const std = @import("std");
const xev = @import("xev");
const Lua = @import("luajit").Lua;

const handler_mod = @import("../core/handler.zig");
const Connection = handler_mod.Connection;

const ring = @import("ring.zig");
const IoEntry = ring.IoEntry;

const tls_mod = @import("../tls/tls.zig");
const TlsConn = tls_mod.TlsConn;

const io_request_mod = @import("io_request.zig");
const TlsMode = io_request_mod.TlsMode;

const LuaState = @import("../lua/lua_state.zig").LuaState;

const cosocket = @import("cosocket.zig");

const error_response = @import("../http/error_response.zig");
const ErrorCategory = error_response.ErrorCategory;

// ============================================================================
// Shared error infrastructure
// ============================================================================

/// Push nil, {category=..., message=...} error table to the Lua thread stack.
/// All cosocket errors flow through this function so Lua always sees structured tables.
pub fn pushErrorTable(thread: *Lua, category: ErrorCategory, msg: [:0]const u8) void {
    thread.pushNil();
    thread.createTable(0, 2);
    thread.pushString(@tagName(category));
    thread.setField(-2, "category");
    thread.pushString(msg);
    thread.setField(-2, "message");
}

// ============================================================================
// Shared TLS helpers
// ============================================================================

/// Encrypt data for outbound send if TLS is active, then arena-dupe.
/// Returns the send-ready data (encrypted or plain, arena-duped), or null on failure.
pub fn encryptForSend(alloc: std.mem.Allocator, tls_conn: ?*TlsConn, data: []const u8) ?[]const u8 {
    if (tls_conn) |tc| {
        const ct = tc.sslWrite(data) orelse return null;
        return alloc.dupe(u8, ct) catch null;
    }
    return alloc.dupe(u8, data) catch null;
}

/// Select the SSL_CTX for outbound cosocket TLS based on the requested mode.
/// Insecure mode requires KEYWAY_ALLOW_INSECURE_TLS=1 env var; falls back to verify mode without it.
pub fn selectClientTlsCtx(lua_state: *LuaState, mode: TlsMode) @TypeOf(lua_state.tls_manager.client_tls_ctx.ctx) {
    return switch (mode) {
        .verify => lua_state.tls_manager.client_tls_ctx.ctx,
        .insecure => blk: {
            if (std.posix.getenv("KEYWAY_ALLOW_INSECURE_TLS")) |v| {
                if (std.mem.eql(u8, v, "1")) break :blk lua_state.tls_manager.insecure_tls_ctx.ctx;
            }
            const log = @import("../observability/log.zig");
            log.warn().string("msg", "insecure TLS requested but KEYWAY_ALLOW_INSECURE_TLS=1 not set, using verify mode").log();
            break :blk lua_state.tls_manager.client_tls_ctx.ctx;
        },
        .custom => if (lua_state.tls_manager.custom_tls_ctx) |ctx| ctx.ctx else lua_state.tls_manager.insecure_tls_ctx.ctx,
    };
}

// ============================================================================
// Batch submit helpers (called from drainSubmissionRing in cosocket.zig)
// ============================================================================

/// Helper: create TCP socket and submit connect for batched I/O
pub fn submitBatchConnect(self: *Connection, host: []const u8, port: u16, io_index: u8, _: IoEntry.Op) void {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        self.cs.cq.push(.{ .result = -1, .err_msg = "socket creation failed", .err_category = .upstream_error });
        return;
    };

    const addr = std.net.Address.parseIp4(host, port) catch {
        std.posix.close(sock);
        self.cs.cq.push(.{ .result = -1, .err_msg = "connect: invalid address", .err_category = .upstream_error });
        return;
    };

    self.cs.batch_completions.?[io_index] = .{
        .op = .{ .connect = .{ .socket = sock, .addr = addr } },
        .userdata = self,
        .callback = cosocket.onBatchComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&self.cs.batch_completions.?[io_index]);
}

/// Helper: create UDP socket and submit connect for batched I/O
pub fn submitBatchUdpConnect(self: *Connection, host: []const u8, port: u16, timeout_ms: u32, io_index: u8) void {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        self.cs.cq.push(.{ .result = -1, .err_msg = "udp_connect: socket creation failed", .err_category = .upstream_error });
        return;
    };

    if (timeout_ms > 0) {
        const tv = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    const addr = std.net.Address.parseIp4(host, port) catch {
        std.posix.close(sock);
        self.cs.cq.push(.{ .result = -1, .err_msg = "udp_connect: invalid address", .err_category = .upstream_error });
        return;
    };

    self.cs.batch_completions.?[io_index] = .{
        .op = .{ .connect = .{ .socket = sock, .addr = addr } },
        .userdata = self,
        .callback = cosocket.onBatchComplete,
    };
    self.cs.pending_completions += 1;
    self.loop.add(&self.cs.batch_completions.?[io_index]);
}
