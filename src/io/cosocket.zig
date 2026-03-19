//! Outbound I/O engine — yield/resume bridge between Lua coroutines and libxev.
//!
//! Flow:
//!   Lua handler yields  ->  dispatchIo()  ->  drainSubmissionRing()
//!       |                                         |
//!   xev async op        <-  onBatchComplete callback
//!       |
//!   batchCompletionCheck() -> dispatchResume() -> lua_resume(thread, nresults)
//!       |
//!   completed?          ->  completeHandler() -> serialize response -> write
//!   yielded again?      ->  dispatchIo() (loop)
//!
//! Unified I/O path:
//!   All I/O flows through drainSubmissionRing -> xev -> onBatchComplete -> CQEntry.
//!   Legacy single-shot cosocket ops (connect/send/recv/close) are converted to
//!   degenerate SQ entries in dispatchIo with single_shot_mode=true, so completions
//!   push results to the Lua stack instead of leaving them in the CQ.
//!
//! After kTLS: all send/recv are plaintext — the kernel handles crypto transparently.

const std = @import("std");
const xev = @import("xev");
const handler_mod = @import("../core/handler.zig");
const Connection = handler_mod.Connection;
const SuspendedState = handler_mod.SuspendedState;
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const IoEntry = ring.IoEntry;
const ring = @import("ring.zig");
const tls_mod = @import("../tls/tls.zig");
const TlsConn = tls_mod.TlsConn;
const Lua = @import("luajit").Lua;
const error_response = @import("../http/error_response.zig");
const ErrorCategory = error_response.ErrorCategory;
const castUserdata = @import("../util/helpers.zig").castUserdata;

const cosocket_ops = @import("cosocket_ops.zig");
const cosocket_tls = @import("../tls/cosocket_tls.zig");
const conn_ws = @import("../protocol/conn_ws.zig");
const prom = @import("../observability/prom.zig");

// ============================================================================
// Shared error infrastructure
// ============================================================================

/// Classify an error by xev operation tag. Used by both single-shot interpret functions
/// and the batch completion path to ensure identical error categorization.
pub fn classifyOpError(op_tag: anytype) struct { category: ErrorCategory, msg: [:0]const u8 } {
    return switch (op_tag) {
        .connect => .{ .category = .upstream_error, .msg = "connection refused" },
        .send => .{ .category = .upstream_error, .msg = "send failed" },
        .recv => .{ .category = .upstream_error, .msg = "recv failed" },
        .close => .{ .category = .upstream_error, .msg = "close failed" },
        else => .{ .category = .server_error, .msg = "unknown op" },
    };
}

// ============================================================================
// I/O dispatch
// ============================================================================

/// Dispatch I/O after a Lua yield. All I/O flows through drainSubmissionRing.
/// When Lua yields without SQ entries (legacy single-shot cosocket API), the
/// pending_io is converted to a degenerate SQ entry with single_shot_mode=true
/// so completions push results to the Lua stack instead of CQ.
pub fn dispatchIo(conn: *Connection) void {
    if (conn.cs.sq.len() == 0) {
        // Legacy single-shot path: convert pending_io to SQ entry
        const pending = conn.lua_state.pending_io orelse {
            resumeWithError(conn, .server_error, "no pending I/O operation");
            return;
        };
        conn.lua_state.pending_io = null;
        conn.cs.sq.push(pending) catch unreachable; // SQ was empty, can't be full
        conn.cs.single_shot_mode = true;
        const s = &conn.cs.suspended.?;
        s.pending_op = std.meta.activeTag(pending);
    } else {
        conn.cs.single_shot_mode = false;
    }
    drainSubmissionRing(conn);
}

// ============================================================================
// Resume helpers
// ============================================================================

/// Resume coroutine and dispatch based on result
pub fn dispatchResume(self: *Connection, thread: *Lua, nresults: c_int, exchange: *HttpExchange) void {
    self.lua_state.current_connection = self;
    const resume_result = self.lua_state.resumeHandler(@ptrCast(thread), nresults, exchange) catch {
        self.lua_state.current_connection = null;
        // WebSocket: can't send HTTP 500 on a WS connection — return to read loop
        if (self.state == .websocket) {
            completeHandler(self);
        } else {
            self.send500InternalError();
        }
        return;
    };

    switch (resume_result) {
        .completed => {
            self.lua_state.current_connection = null;
            completeHandler(self);
        },
        .yielded => {
            // WebSocket: route through routeWsYield which handles the fd=0
            // ws:send() convention. Without this, ws:send() after a ring batch
            // (e.g. Redis cosocket I/O) would be dispatched as a raw send on
            // fd=0 (stdin) → ENOTSOCK.
            if (self.state == .websocket) {
                conn_ws.routeWsYield(self);
            } else {
                dispatchIo(self);
            }
        },
    }
}

/// Resume coroutine with nil, {category, message} error table for pre-submission failures.
pub fn resumeWithError(self: *Connection, category: ErrorCategory, msg: [:0]const u8) void {
    const s = &self.cs.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    cosocket_ops.pushErrorTable(thread, category, msg);
    dispatchResume(self, thread, 2, s.exchange);
}

// ============================================================================
// Batch I/O path
// ============================================================================

/// Drain the submission ring: process each IoEntry, submit async I/O to xev.
/// Synchronous ops (pool_connect hit, setkeepalive) write CQE immediately.
/// After all entries are drained, if pending_completions == 0 we resume immediately.
fn drainSubmissionRing(self: *Connection) void {
    const s = &self.cs.suspended.?;
    self.cs.cq.reset();

    // Lazy-allocate batch arrays on first cosocket use (connections that never
    // use cosocket I/O pay zero memory for these arrays).
    if (!self.cs.ensureBatchArrays(self.base_allocator)) {
        resumeWithError(self, .server_error, "cosocket: batch array alloc failed");
        return;
    }

    var io_index: u8 = 0;

    while (self.cs.sq.pop()) |entry| {
        switch (entry.*) {
            .connect => |cn| {
                cosocket_ops.submitBatchConnect(self, cn.host, cn.port, io_index, .connect);
                io_index += 1;
            },
            .pool_connect => |cn| {
                // Sync pool hit -> write CQE immediately, no xev submission
                if (self.lua_state.pool.get(cn.pool_name)) |hit| {
                    self.cs.cq.push(.{ .result = @intCast(hit.fd) });
                } else {
                    cosocket_ops.submitBatchConnect(self, cn.host, cn.port, io_index, .pool_connect);
                }
                io_index += 1;
            },
            .send => |snd| {
                const send_data = cosocket_ops.encryptForSend(self.arena.allocator(), s.outbound_tls, snd.data) orelse {
                    self.cs.cq.push(.{ .result = -1, .err_msg = "send: encrypt/alloc failed", .err_category = .upstream_error });
                    io_index += 1;
                    continue;
                };
                self.cs.batch_completions.?[io_index] = .{
                    .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = send_data } } },
                    .userdata = self,
                    .callback = onBatchComplete,
                };
                self.cs.pending_completions += 1;
                self.loop.add(&self.cs.batch_completions.?[io_index]);
                io_index += 1;
            },
            .recv => |r| {
                // Plaintext recv — kernel decrypts if kTLS is active
                const buf = self.arena.allocator().alloc(u8, r.max_len) catch {
                    self.cs.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed", .err_category = .server_error });
                    io_index += 1;
                    continue;
                };
                self.cs.batch_recv_bufs.?[io_index] = buf;
                self.cs.batch_completions.?[io_index] = .{
                    .op = .{ .recv = .{ .fd = r.fd, .buffer = .{ .slice = buf } } },
                    .userdata = self,
                    .callback = onBatchComplete,
                };
                self.cs.pending_completions += 1;
                self.loop.add(&self.cs.batch_completions.?[io_index]);
                io_index += 1;
            },
            .close => |cl| {
                self.cs.batch_completions.?[io_index] = .{
                    .op = .{ .close = .{ .fd = cl.fd } },
                    .userdata = self,
                    .callback = onBatchComplete,
                };
                self.cs.pending_completions += 1;
                self.loop.add(&self.cs.batch_completions.?[io_index]);
                io_index += 1;
            },
            .setkeepalive => |k| {
                // Free userspace TLS state — can't pool non-kTLS connections
                s.cleanupTls(self.base_allocator);
                // Always synchronous — put fd into pool
                self.lua_state.pool.put(
                    k.pool_name,
                    k.fd,
                    @intCast(k.reuse_count),
                    @intCast(k.timeout_ms),
                    @intCast(k.pool_size),
                ) catch {
                    self.cs.cq.push(.{ .result = -1, .err_msg = "setkeepalive: pool put failed", .err_category = .server_error });
                    io_index += 1;
                    continue;
                };
                self.cs.cq.push(.{ .result = 1 });
                io_index += 1;
            },
            .tls_handshake => |t| {
                // TLS handshake is multi-step — submit as a sequence via the existing mechanism
                const tls_conn = self.base_allocator.create(TlsConn) catch {
                    self.cs.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed", .err_category = .upstream_error });
                    io_index += 1;
                    continue;
                };
                tls_conn.* = TlsConn.init(self.base_allocator, cosocket_ops.selectClientTlsCtx(self.lua_state, t.tls_mode), .client) catch {
                    self.base_allocator.destroy(tls_conn);
                    self.cs.cq.push(.{ .result = -1, .err_msg = "tls_handshake: tls init failed", .err_category = .upstream_error });
                    io_index += 1;
                    continue;
                };
                tls_conn.fixupExData();
                if (t.sni_host) |host| {
                    const host_z = self.arena.allocator().dupeZ(u8, host) catch {
                        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                        self.cs.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed", .err_category = .upstream_error });
                        io_index += 1;
                        continue;
                    };
                    tls_conn.setSni(host_z);
                }

                _ = tls_conn.handshake();
                const total = tls_conn.drainAll();
                if (total == 0) {
                    tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                    self.cs.cq.push(.{ .result = -1, .err_msg = "tls_handshake: no data produced", .err_category = .upstream_error });
                    io_index += 1;
                    continue;
                }

                // Store tls_conn for the handshake continuation
                s.outbound_tls = tls_conn;
                s.outbound_fd = t.fd;
                s.pending_op = .tls_handshake;
                self.cs.batch_completions.?[io_index] = .{
                    .op = .{ .send = .{ .fd = t.fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                    .userdata = self,
                    .callback = cosocket_tls.onSendComplete,
                };
                // TLS handshake hijacks the suspended state — can only have one per batch
                self.cs.pending_completions += 1;
                self.loop.add(&self.cs.batch_completions.?[io_index]);
                io_index += 1;
            },
            .udp_connect => |u| {
                cosocket_ops.submitBatchUdpConnect(self, u.host, u.port, u.timeout_ms, io_index);
                io_index += 1;
            },
            .none => {
                io_index += 1;
            },
        }
    }
    self.cs.sq.reset();
    if (io_index > 0) {
        prom.ringSubmissions(io_index);
        prom.ringBatchSize(io_index);
    }

    if (self.cs.pending_completions == 0) {
        // All ops were synchronous (pool hits, setkeepalive) — resume immediately
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        thread.pushInteger(@intCast(self.cs.cq.tail));
        dispatchResume(self, thread, 1, s.exchange);
    }
    // else: wait for onBatchComplete callbacks to decrement pending_completions
}

/// xev callback for batched I/O completions.
/// Writes result into CQ at the correct index. When all completions arrive, resumes Lua once.
/// After kTLS, recv data is already plaintext — no decryption needed.
pub fn onBatchComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;

    const self = castUserdata(Connection, userdata);
    prom.ringCompletions(1);

    // Determine which SQE index this completion corresponds to
    const base = @intFromPtr(&self.cs.batch_completions.?[0]);
    const this = @intFromPtr(completion);
    const sqe_index: u8 = @intCast((this - base) / @sizeOf(xev.Completion));

    const op = completion.op;

    if (op == .connect) {
        _ = result.connect catch {
            std.posix.close(completion.op.connect.socket);
            const classified = classifyOpError(op);
            self.cs.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cs.cq.push(.{ .result = @intCast(completion.op.connect.socket) });
    } else if (op == .send) {
        const bytes_sent = result.send catch {
            const classified = classifyOpError(op);
            self.cs.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cs.cq.push(.{ .result = @intCast(bytes_sent) });
    } else if (op == .recv) {
        const bytes_read = result.recv catch {
            self.cs.batch_recv_bufs.?[sqe_index] = null;
            const classified = classifyOpError(op);
            self.cs.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        if (self.cs.batch_recv_bufs.?[sqe_index]) |buf| {
            // Userspace TLS: decrypt ciphertext from the wire
            if (self.cs.suspended) |*ss| {
                if (ss.outbound_tls) |tls_conn| {
                    if (tls_conn.sslRead(buf[0..bytes_read], buf)) |pt| {
                        self.cs.cq.push(.{ .result = @intCast(pt.len), .buf = pt });
                    } else {
                        self.cs.cq.push(.{ .result = -1, .err_msg = "recv: TLS decrypt failed", .err_category = .upstream_error });
                    }
                    self.cs.batch_recv_bufs.?[sqe_index] = null;
                    batchCompletionCheck(self);
                    return .disarm;
                }
            }
            self.cs.cq.push(.{ .result = @intCast(bytes_read), .buf = buf[0..bytes_read] });
        } else {
            self.cs.cq.push(.{ .result = -1, .err_msg = "recv: no buffer", .err_category = .server_error });
        }
        self.cs.batch_recv_bufs.?[sqe_index] = null;
    } else if (op == .close) {
        _ = result.close catch {
            const classified = classifyOpError(op);
            self.cs.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        // Free userspace TLS state if present
        if (self.cs.suspended) |*ss| ss.cleanupTls(self.base_allocator);
        self.cs.cq.push(.{ .result = 1 });
    } else {
        const classified = classifyOpError(op);
        self.cs.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
    }

    batchCompletionCheck(self);
    return .disarm;
}

/// Check if all batch completions have arrived; if so, resume Lua.
/// Single-shot mode: push result values to stack (legacy cosocket API).
/// Batch mode: push CQ count (ring API).
/// If the request timed out, decrement pending_completions and call maybeFinishClose.
fn batchCompletionCheck(self: *Connection) void {
    self.cs.pending_completions -= 1;
    if (self.timed_out) {
        // Timeout cleanup: don't resume Lua, just drain completions
        if (self.cs.pending_completions == 0) {
            // All completions drained — clean up suspended state and free connection
            if (self.cs.suspended) |*s| {
                if (s.coroutine_ref != 0) {
                    self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
                    s.coroutine_ref = 0;
                }
                if (s.outbound_fd != -1) {
                    std.posix.close(s.outbound_fd);
                    s.outbound_fd = -1;
                }
                s.recv_buf = null;
                s.cleanupTls(self.base_allocator);
                self.cs.suspended = null;
            }
        }
        self.maybeFinishClose();
        return;
    }
    if (self.cs.pending_completions == 0) {
        const s = &self.cs.suspended.?;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        if (self.cs.single_shot_mode) {
            self.cs.single_shot_mode = false;
            resumeSingleShot(self, s, thread);
        } else {
            thread.pushInteger(@intCast(self.cs.cq.tail));
            dispatchResume(self, thread, 1, s.exchange);
        }
    }
}

/// Convert a single CQE result back to Lua stack values for the legacy
/// single-shot cosocket API (connect/send/recv/close yield and resume with
/// result values on the stack, not a CQ count).
fn resumeSingleShot(self: *Connection, s: *SuspendedState, thread: *Lua) void {
    const cqe = self.cs.cq.get(0);

    if (cqe.err_msg) |err_msg| {
        // Error: push nil, {category=, message=}
        cosocket_ops.pushErrorTable(thread, cqe.err_category orelse .server_error, std.mem.span(err_msg));
        dispatchResume(self, thread, 2, s.exchange);
        return;
    }

    switch (s.pending_op) {
        .pool_connect => {
            // pool_connect returns (fd, reuse_count) — fresh connection has reuse_count=0
            thread.pushInteger(@intCast(cqe.result));
            thread.pushInteger(0);
            dispatchResume(self, thread, 2, s.exchange);
        },
        .recv => {
            // recv returns data string or nil
            if (cqe.buf) |buf| {
                thread.pushLString(buf);
            } else {
                thread.pushNil();
            }
            dispatchResume(self, thread, 1, s.exchange);
        },
        else => {
            // connect, udp_connect, send, close: push integer result
            thread.pushInteger(@intCast(cqe.result));
            dispatchResume(self, thread, 1, s.exchange);
        },
    }
}

// ============================================================================
// Handler completion
// ============================================================================

/// Handler finished after one or more yield/resume cycles.
/// Return coroutine to cache, serialize response, submit write.
/// For WebSocket connections, returns to WS read loop instead of HTTP response.
pub fn completeHandler(self: *Connection) void {
    const s = self.cs.suspended orelse return;

    // Return coroutine thread to cache for reuse
    if (s.coroutine_ref != 0) {
        if (self.lua_state.cached_thread_ref == 0) {
            self.lua_state.cached_thread_ref = s.coroutine_ref;
            self.lua_state.cached_thread = @ptrCast(@alignCast(s.coroutine_thread));
        } else {
            self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
        }
    }

    // Safety net: close leaked outbound fd (use raw syscall — std.posix.close
    // treats EBADF as unreachable, but double-close is a legitimate cleanup race)
    if (s.outbound_fd != -1) _ = std.os.linux.close(s.outbound_fd);

    self.cs.suspended = null;

    // WebSocket: return to WS read loop instead of serializing HTTP response
    if (self.state == .websocket) {
        self.lua_state.current_connection = null;
        conn_ws.startWsRead(self);
        return;
    }

    const exchange = s.exchange;
    self.logAccess(exchange.status);
    self.writeResponse(exchange) catch {
        self.send500InternalError();
    };
}

// ============================================================================
// Tests
// ============================================================================

test "classifyOpError returns correct categories" {
    const connect_err = classifyOpError(@as(IoEntry.Op, .connect));
    try std.testing.expectEqual(ErrorCategory.upstream_error, connect_err.category);
    try std.testing.expectEqualStrings("connection refused", connect_err.msg);

    const send_err = classifyOpError(@as(IoEntry.Op, .send));
    try std.testing.expectEqual(ErrorCategory.upstream_error, send_err.category);
    try std.testing.expectEqualStrings("send failed", send_err.msg);

    const recv_err = classifyOpError(@as(IoEntry.Op, .recv));
    try std.testing.expectEqual(ErrorCategory.upstream_error, recv_err.category);
    try std.testing.expectEqualStrings("recv failed", recv_err.msg);

    const close_err = classifyOpError(@as(IoEntry.Op, .close));
    try std.testing.expectEqual(ErrorCategory.upstream_error, close_err.category);
    try std.testing.expectEqualStrings("close failed", close_err.msg);

    const unknown_err = classifyOpError(@as(IoEntry.Op, .none));
    try std.testing.expectEqual(ErrorCategory.server_error, unknown_err.category);
    try std.testing.expectEqualStrings("unknown op", unknown_err.msg);
}
