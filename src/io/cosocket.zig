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
//!   Results land in the completion ring; Lua is resumed once per batch with the count.
//!
//! After kTLS: all send/recv are plaintext — the kernel handles crypto transparently.

const std = @import("std");
const xev = @import("xev");
const handler_mod = @import("../core/handler.zig");
const Connection = handler_mod.Connection;
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const IoEntry = ring.IoEntry;
const ring = @import("ring.zig");
const Lua = @import("luajit").Lua;
const error_response = @import("../http/error_response.zig");
const ErrorCategory = error_response.ErrorCategory;
const castUserdata = @import("../util/helpers.zig").castUserdata;
const helpers = @import("../util/helpers.zig");

const conn_ws = @import("../protocol/conn_ws.zig");
const prom = @import("../observability/prom.zig");

// ============================================================================
// Shared error infrastructure
// ============================================================================

/// Classify an error by xev operation tag. Used by both single-shot interpret functions
/// and the batch completion path to ensure identical error categorization.
pub fn classifyOpError(op_tag: anytype) struct { category: ErrorCategory, msg: [:0]const u8 } {
    return switch (op_tag) {
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
/// A yield with no SQ entries has no work to submit — resume with an error.
pub fn dispatchIo(conn: *Connection) void {
    if (conn.cs.sq.len() == 0) {
        resumeWithError(conn, .server_error, "no pending I/O operation");
        return;
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

/// Push nil, {category=..., message=...} error table to the Lua thread stack,
/// so Lua always sees a structured error table.
fn pushErrorTable(thread: *Lua, category: ErrorCategory, msg: [:0]const u8) void {
    thread.pushNil();
    thread.createTable(0, 2);
    thread.pushString(@tagName(category));
    thread.setField(-2, "category");
    thread.pushString(msg);
    thread.setField(-2, "message");
}

/// Resume coroutine with nil, {category, message} error table for pre-submission failures.
pub fn resumeWithError(self: *Connection, category: ErrorCategory, msg: [:0]const u8) void {
    const s = &self.cs.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    pushErrorTable(thread, category, msg);
    dispatchResume(self, thread, 2, s.exchange);
}

// ============================================================================
// Batch I/O path
// ============================================================================

/// Drain the submission ring: process each IoEntry, submit async I/O to xev.
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
            .send => |snd| {
                // Arena-dupe the payload — the Lua string may be GC'd across the yield.
                const send_data = self.arena.allocator().dupe(u8, snd.data) catch {
                    self.cs.cq.push(.{ .result = -1, .err_msg = "send: alloc failed", .err_category = .upstream_error });
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
        // Nothing async was submitted (e.g. all-.none batch) — resume immediately
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

    if (op == .send) {
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
        self.cs.cq.push(.{ .result = 1 });
    } else {
        const classified = classifyOpError(op);
        self.cs.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
    }

    batchCompletionCheck(self);
    return .disarm;
}

/// Check if all batch completions have arrived; if so, resume Lua with the CQ count.
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
                    helpers.closeFd(s.outbound_fd);
                    s.outbound_fd = -1;
                }
                s.recv_buf = null;
                self.cs.suspended = null;
            }
        }
        self.maybeFinishClose();
        return;
    }
    if (self.cs.pending_completions == 0) {
        const s = &self.cs.suspended.?;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        thread.pushInteger(@intCast(self.cs.cq.tail));
        dispatchResume(self, thread, 1, s.exchange);
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
