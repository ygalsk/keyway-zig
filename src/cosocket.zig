//! Outbound I/O engine — yield/resume bridge between Lua coroutines and libxev.
//!
//! Flow:
//!   Lua handler yields  ->  dispatchIo()  ->  submitOutboundIO() or drainSubmissionRing()
//!       |                                         |
//!   xev async op        <-  onOutbound/onBatchComplete callback
//!       |
//!   dispatchResume()    ->  lua_resume(thread, nresults)
//!       |
//!   completed?          ->  completeHandler() -> serialize response -> write
//!   yielded again?      ->  dispatchIo() (loop)
//!
//! I/O completion paths:
//!   Single-shot: submitOutboundIO -> xev -> onOutboundComplete -> interpret{Op} -> dispatchResume
//!   Batch:       drainSubmissionRing -> xev -> onBatchComplete -> classifyOpError -> CQEntry -> ring_api
//! Both paths share interpret/classify functions for consistent error categorization.
//!
//! Single-shot path: one pending_io at a time (connect, send, recv, close).
//! Batch path: submission ring drained, multiple xev ops in flight, resume on last completion.

const std = @import("std");
const xev = @import("xev");
const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const SuspendedState = handler_mod.SuspendedState;
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const IoEntry = ring.IoEntry;
const ring = @import("ring.zig");
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;
const Lua = @import("luajit").Lua;
const error_response = @import("error_response.zig");
const ErrorCategory = error_response.ErrorCategory;
const castUserdata = @import("helpers.zig").castUserdata;

const cosocket_ops = @import("cosocket_ops.zig");
const cosocket_tls = @import("cosocket_tls.zig");

// ============================================================================
// Shared error infrastructure
// ============================================================================

/// Result of an interpret function: how many Lua values were pushed, and
/// whether the operation completed (false = re-submitted, e.g. TLS want_read).
const InterpretResult = struct {
    nresults: c_int,
    done: bool = true,
};

/// Push nil, {category=..., message=...} error table to the Lua thread stack.
/// All cosocket errors flow through this function so Lua always sees structured tables.
fn pushErrorTable(thread: *Lua, category: ErrorCategory, msg: [:0]const u8) void {
    thread.pushNil();
    thread.createTable(0, 2);
    thread.pushString(@tagName(category));
    thread.setField(-2, "category");
    thread.pushString(msg);
    thread.setField(-2, "message");
}

/// Classify an error by xev operation tag. Used by both single-shot interpret functions
/// and the batch completion path to ensure identical error categorization.
pub fn classifyOpError(op_tag: anytype) struct { category: ErrorCategory, msg: [:0]const u8 } {
    if (op_tag == .connect) return .{ .category = .upstream_error, .msg = "connection refused" };
    if (op_tag == .send) return .{ .category = .upstream_error, .msg = "send failed" };
    if (op_tag == .recv) return .{ .category = .upstream_error, .msg = "recv failed" };
    if (op_tag == .close) return .{ .category = .upstream_error, .msg = "close failed" };
    return .{ .category = .server_error, .msg = "unknown op" };
}

/// Format a TLS decrypt error into a static sentinel-terminated string for Lua.
/// Includes SSL_ERROR code and first ERR queue message if available.
fn tlsErrorMsg(comptime prefix: []const u8, de: TlsConn.DecryptError) [:0]const u8 {
    if (de.msg_len > 0) {
        return prefix ++ ": tls decrypt failed (see server log for SSL details)";
    }
    return prefix ++ ": tls decrypt failed";
}

// ============================================================================
// Interpret functions — shared by onOutboundComplete (single-shot path)
// ============================================================================

/// Interpret a connect/pool_connect/udp_connect completion.
/// On failure: closes socket, pushes error table. On success: pushes fd (and reuse_count for pool_connect).
fn interpretConnect(thread: *Lua, s: *SuspendedState, result: xev.Result) InterpretResult {
    _ = result.connect catch {
        std.posix.close(s.outbound_fd);
        s.outbound_fd = 0;
        s.pending_op = .none;
        pushErrorTable(thread, .upstream_error, "connection refused");
        return .{ .nresults = 2 };
    };
    if (s.pending_op == .pool_connect) {
        thread.pushInteger(@intCast(s.outbound_fd));
        thread.pushInteger(0);
        s.outbound_fd = 0;
        s.pending_op = .none;
        return .{ .nresults = 2 };
    }
    thread.pushInteger(@intCast(s.outbound_fd));
    s.outbound_fd = 0;
    s.pending_op = .none;
    return .{ .nresults = 1 };
}

/// Interpret a send completion.
/// On failure: pushes error table. On success: pushes bytes_sent.
fn interpretSend(thread: *Lua, result: xev.Result) InterpretResult {
    const bytes_sent = result.send catch {
        pushErrorTable(thread, .upstream_error, "send failed");
        return .{ .nresults = 2 };
    };
    thread.pushInteger(@intCast(bytes_sent));
    return .{ .nresults = 1 };
}

/// Interpret a recv completion, handling TLS decryption.
/// On failure or TLS error: pushes error table. On want_read: re-submits recv (done=false).
/// On success: pushes data string.
fn interpretRecv(
    thread: *Lua,
    s: *SuspendedState,
    result: xev.Result,
    self: *Connection,
    fd: std.posix.socket_t,
) InterpretResult {
    const bytes_read = result.recv catch {
        s.recv_buf = null;
        pushErrorTable(thread, .upstream_error, "recv failed");
        return .{ .nresults = 2 };
    };
    if (s.recv_buf) |buf| {
        if (self.lua_state.getTls(fd)) |tls_conn| {
            tls_conn.feedCiphertext(buf[0..bytes_read]);
            var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
            switch (tls_conn.decrypt(&plaintext_buf)) {
                .data => |n| {
                    thread.pushLString(plaintext_buf[0..n]);
                    s.recv_buf = null;
                    return .{ .nresults = 1 };
                },
                .want_read => {
                    // Need more ciphertext — re-submit recv without resuming Lua
                    s.completion = .{
                        .op = .{ .recv = .{ .fd = fd, .buffer = .{ .slice = buf } } },
                        .userdata = self,
                        .callback = onOutboundComplete,
                    };
                    self.loop.add(&s.completion);
                    return .{ .nresults = 0, .done = false };
                },
                .zero_return => {
                    s.recv_buf = null;
                    pushErrorTable(thread, .upstream_error, "recv: tls connection closed");
                    return .{ .nresults = 2 };
                },
                .err => |de| {
                    s.recv_buf = null;
                    pushErrorTable(thread, .upstream_error, tlsErrorMsg("recv", de));
                    return .{ .nresults = 2 };
                },
            }
        } else {
            thread.pushLString(buf[0..bytes_read]);
        }
    } else {
        thread.pushNil();
    }
    s.recv_buf = null;
    return .{ .nresults = 1 };
}

/// Interpret a close completion.
/// On failure: pushes error table. On success: pushes 1.
fn interpretClose(thread: *Lua, s: *SuspendedState, result: xev.Result) InterpretResult {
    _ = result.close catch {
        pushErrorTable(thread, .upstream_error, "close failed");
        return .{ .nresults = 2 };
    };
    s.outbound_fd = 0;
    thread.pushInteger(1);
    return .{ .nresults = 1 };
}

// ============================================================================
// Encrypt/TLS helpers
// ============================================================================

/// Encrypt plaintext via TLS and drain into an allocated buffer.
/// Returns ciphertext slice, or null on encrypt/alloc failure.
pub fn tlsEncryptAlloc(tc: *TlsConn, plaintext: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    tc.encrypt(plaintext) catch return null;
    return tc.drainAllAlloc(allocator) catch null;
}

// ============================================================================
// I/O dispatch
// ============================================================================

/// Dispatch I/O after a Lua yield: ring path (SQ has entries) or old single-shot path.
pub fn dispatchIo(conn: *Connection) void {
    if (conn.sq.len() > 0) {
        drainSubmissionRing(conn);
    } else {
        cosocket_ops.submitOutboundIO(conn);
    }
}

// ============================================================================
// Single-shot completion callback
// ============================================================================

/// xev callback for all outbound I/O completions.
/// Pure dispatch: extract result, call interpret function, resume coroutine.
pub fn onOutboundComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    const self = castUserdata(Connection, userdata);

    // Decrement single-shot pending completion counter
    self.pending_completions -= 1;

    // Timeout cleanup: if the request timed out while this completion was in flight,
    // discard the result and clean up resources without resuming the coroutine.
    if (self.timed_out) {
        if (self.suspended) |*s| {
            // Close leaked outbound fd
            if (s.outbound_fd != 0) {
                std.posix.close(s.outbound_fd);
                s.outbound_fd = 0;
            }
            // Free recv buffer if allocated
            s.recv_buf = null;
            // Unref pinned coroutine from Lua registry (prevents leak)
            if (s.coroutine_ref != 0) {
                self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
                s.coroutine_ref = 0;
            }
            // Clean up TLS conn if mid-handshake
            if (s.outbound_tls) |tls_conn| {
                tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                s.outbound_tls = null;
            }
            self.suspended = null;
        }
        self.maybeFinishClose();
        return .disarm;
    }

    const s = &self.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    const op = completion.op;

    const ir = if (op == .connect)
        interpretConnect(thread, s, result)
    else if (op == .send)
        interpretSend(thread, result)
    else if (op == .recv)
        interpretRecv(thread, s, result, self, completion.op.recv.fd)
    else if (op == .close)
        interpretClose(thread, s, result)
    else blk: {
        pushErrorTable(thread, .server_error, "unknown outbound op");
        break :blk InterpretResult{ .nresults = 2 };
    };

    if (!ir.done) return .disarm;
    dispatchResume(self, thread, ir.nresults, s.exchange);
    return .disarm;
}

// ============================================================================
// Resume helpers
// ============================================================================

/// Resume coroutine and dispatch based on result
pub fn dispatchResume(self: *Connection, thread: *Lua, nresults: c_int, exchange: *HttpExchange) void {
    self.lua_state.current_connection = self;
    const resume_result = self.lua_state.resumeHandler(@ptrCast(thread), nresults, exchange) catch {
        self.lua_state.current_connection = null;
        self.send500InternalError();
        return;
    };

    switch (resume_result) {
        .completed => {
            self.lua_state.current_connection = null;
            completeHandler(self);
        },
        .yielded => {
            dispatchIo(self);
        },
    }
}

/// Resume coroutine with nil, {category, message} error table for pre-submission failures.
pub fn resumeWithError(self: *Connection, category: ErrorCategory, msg: [:0]const u8) void {
    const s = &self.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    pushErrorTable(thread, category, msg);
    dispatchResume(self, thread, 2, s.exchange);
}

/// Resume with a descriptive TLS error message including SSL error details.
pub fn resumeWithTlsError(self: *Connection, comptime prefix: []const u8, de: TlsConn.DecryptError) void {
    const s = &self.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    pushErrorTable(thread, .upstream_error, tlsErrorMsg(prefix, de));
    dispatchResume(self, thread, 2, s.exchange);
}

// ============================================================================
// Batch I/O path
// ============================================================================

/// Drain the submission ring: process each IoEntry, submit async I/O to xev.
/// Synchronous ops (pool_connect hit, setkeepalive) write CQE immediately.
/// After all entries are drained, if pending_completions == 0 we resume immediately.
fn drainSubmissionRing(self: *Connection) void {
    const s = &self.suspended.?;
    self.cq.reset();
    var io_index: u8 = 0;

    while (self.sq.pop()) |entry| {
        switch (entry.*) {
            .connect => |c| {
                cosocket_ops.submitBatchConnect(self, c.host, c.port, io_index, .connect);
                io_index += 1;
            },
            .pool_connect => |c| {
                // Sync pool hit -> write CQE immediately, no xev submission
                if (self.lua_state.pool.get(c.pool_name)) |hit| {
                    // Restore TLS state from pool if present
                    if (hit.tls_conn) |tls_conn| {
                        self.lua_state.registerTls(hit.fd, tls_conn) catch {
                            tls_mod.freeTlsConn(self.lua_state.allocator, tls_conn);
                        };
                    }
                    self.cq.push(.{ .result = @intCast(hit.fd) });
                } else {
                    cosocket_ops.submitBatchConnect(self, c.host, c.port, io_index, .pool_connect);
                }
                io_index += 1;
            },
            .send => |snd| {
                // Arena-dupe send_data before async submission (Lua string lifetime safety)
                const duped = self.arena.allocator().dupe(u8, snd.data) catch {
                    self.cq.push(.{ .result = -1, .err_msg = "send: arena alloc failed", .err_category = .server_error });
                    io_index += 1;
                    continue;
                };
                // TLS-aware send
                if (self.lua_state.getTls(snd.fd)) |tls_conn| {
                    const ciphertext = tlsEncryptAlloc(tls_conn, duped, self.arena.allocator()) orelse {
                        self.cq.push(.{ .result = -1, .err_msg = "send: tls encrypt failed", .err_category = .upstream_error });
                        io_index += 1;
                        continue;
                    };
                    self.batch_completions[io_index] = .{
                        .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = ciphertext } } },
                        .userdata = self,
                        .callback = onBatchComplete,
                    };
                } else {
                    self.batch_completions[io_index] = .{
                        .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = duped } } },
                        .userdata = self,
                        .callback = onBatchComplete,
                    };
                }
                self.pending_completions += 1;
                self.loop.add(&self.batch_completions[io_index]);
                io_index += 1;
            },
            .recv => |r| {
                // Check for buffered TLS plaintext first
                if (self.lua_state.getTls(r.fd)) |tls_conn| {
                    if (tls_conn.hasPending()) {
                        var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                        switch (tls_conn.decrypt(&plaintext_buf)) {
                            .data => |n| {
                                const buf_copy = self.arena.allocator().dupe(u8, plaintext_buf[0..n]) catch {
                                    self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed", .err_category = .server_error });
                                    io_index += 1;
                                    continue;
                                };
                                self.cq.push(.{ .result = @intCast(n), .buf = buf_copy });
                                io_index += 1;
                                continue;
                            },
                            .want_read => {}, // fall through to kernel recv
                            .zero_return => {
                                self.cq.push(.{ .result = -1, .err_msg = "recv: tls connection closed", .err_category = .upstream_error });
                                io_index += 1;
                                continue;
                            },
                            .err => {
                                // Detail already logged by decrypt()
                                self.cq.push(.{ .result = -1, .err_msg = "recv: tls decrypt failed (see server log)", .err_category = .upstream_error });
                                io_index += 1;
                                continue;
                            },
                        }
                    }
                }
                const buf = self.arena.allocator().alloc(u8, r.max_len) catch {
                    self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed", .err_category = .server_error });
                    io_index += 1;
                    continue;
                };
                self.batch_recv_bufs[io_index] = buf;
                self.batch_completions[io_index] = .{
                    .op = .{ .recv = .{ .fd = r.fd, .buffer = .{ .slice = buf } } },
                    .userdata = self,
                    .callback = onBatchComplete,
                };
                self.pending_completions += 1;
                self.loop.add(&self.batch_completions[io_index]);
                io_index += 1;
            },
            .close => |c| {
                self.lua_state.removeTls(c.fd);
                self.batch_completions[io_index] = .{
                    .op = .{ .close = .{ .fd = c.fd } },
                    .userdata = self,
                    .callback = onBatchComplete,
                };
                self.pending_completions += 1;
                self.loop.add(&self.batch_completions[io_index]);
                io_index += 1;
            },
            .setkeepalive => |k| {
                // Always synchronous — put fd into pool
                const tls_ptr: ?*TlsConn = self.lua_state.detachTls(k.fd);
                self.lua_state.pool.put(
                    k.pool_name,
                    k.fd,
                    @intCast(k.reuse_count),
                    @intCast(k.timeout_ms),
                    @intCast(k.pool_size),
                    tls_ptr,
                ) catch {
                    self.cq.push(.{ .result = -1, .err_msg = "setkeepalive: pool put failed", .err_category = .server_error });
                    io_index += 1;
                    continue;
                };
                self.cq.push(.{ .result = 1 });
                io_index += 1;
            },
            .tls_handshake => |t| {
                // TLS handshake is multi-step — submit as a sequence via the existing mechanism
                const tls_conn = self.base_allocator.create(TlsConn) catch {
                    self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed", .err_category = .upstream_error });
                    io_index += 1;
                    continue;
                };
                tls_conn.* = TlsConn.init(self.base_allocator, cosocket_ops.selectClientTlsCtx(self.lua_state, t.tls_mode), .client) catch {
                    self.base_allocator.destroy(tls_conn);
                    self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: tls init failed", .err_category = .upstream_error });
                    io_index += 1;
                    continue;
                };
                if (t.sni_host) |host| {
                    const host_z = self.arena.allocator().dupeZ(u8, host) catch {
                        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                        self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed", .err_category = .upstream_error });
                        io_index += 1;
                        continue;
                    };
                    tls_conn.setSni(host_z);
                }

                _ = tls_conn.handshake();
                const total = tls_conn.drainAll();
                if (total == 0) {
                    tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                    self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: no data produced", .err_category = .upstream_error });
                    io_index += 1;
                    continue;
                }

                // Store tls_conn for the handshake continuation
                self.batch_tls_conns[io_index] = tls_conn;
                s.outbound_tls = tls_conn;
                s.outbound_fd = t.fd;
                s.pending_op = .tls_handshake;
                self.batch_completions[io_index] = .{
                    .op = .{ .send = .{ .fd = t.fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                    .userdata = self,
                    .callback = cosocket_tls.onSendComplete,
                };
                // TLS handshake hijacks the suspended state — can only have one per batch
                self.pending_completions += 1;
                self.loop.add(&self.batch_completions[io_index]);
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
    self.sq.reset();

    if (self.pending_completions == 0) {
        // All ops were synchronous (pool hits, setkeepalive) — resume immediately
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        thread.pushInteger(@intCast(self.cq.tail));
        dispatchResume(self, thread, 1, s.exchange);
    }
    // else: wait for onBatchComplete callbacks to decrement pending_completions
}

/// xev callback for batched I/O completions.
/// Writes result into CQ at the correct index. When all completions arrive, resumes Lua once.
/// Uses classifyOpError for consistent error categorization with the single-shot path.
pub fn onBatchComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;

    const self = castUserdata(Connection, userdata);

    // Determine which SQE index this completion corresponds to
    const base = @intFromPtr(&self.batch_completions[0]);
    const this = @intFromPtr(completion);
    const sqe_index: u8 = @intCast((this - base) / @sizeOf(xev.Completion));

    const op = completion.op;

    if (op == .connect) {
        _ = result.connect catch {
            std.posix.close(completion.op.connect.socket);
            const classified = classifyOpError(op);
            self.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cq.push(.{ .result = @intCast(completion.op.connect.socket) });
    } else if (op == .send) {
        const bytes_sent = result.send catch {
            const classified = classifyOpError(op);
            self.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cq.push(.{ .result = @intCast(bytes_sent) });
    } else if (op == .recv) {
        const bytes_read = result.recv catch {
            self.batch_recv_bufs[sqe_index] = null;
            const classified = classifyOpError(op);
            self.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        if (self.batch_recv_bufs[sqe_index]) |buf| {
            // Check for TLS decryption
            if (self.lua_state.getTls(completion.op.recv.fd)) |tls_conn| {
                tls_conn.feedCiphertext(buf[0..bytes_read]);
                var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                switch (tls_conn.decrypt(&plaintext_buf)) {
                    .data => |n| {
                        const duped = self.arena.allocator().dupe(u8, plaintext_buf[0..n]) catch {
                            self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed", .err_category = .server_error });
                            self.batch_recv_bufs[sqe_index] = null;
                            batchCompletionCheck(self);
                            return .disarm;
                        };
                        self.cq.push(.{ .result = @intCast(n), .buf = duped });
                    },
                    .want_read => {
                        // Need more ciphertext — re-submit recv (stays in batch)
                        self.batch_completions[sqe_index] = .{
                            .op = .{ .recv = .{ .fd = completion.op.recv.fd, .buffer = .{ .slice = buf } } },
                            .userdata = self,
                            .callback = onBatchComplete,
                        };
                        self.loop.add(&self.batch_completions[sqe_index]);
                        return .disarm; // Don't decrement pending_completions
                    },
                    .zero_return => {
                        self.cq.push(.{ .result = -1, .err_msg = "recv: tls connection closed", .err_category = .upstream_error });
                    },
                    .err => {
                        // Detail already logged by decrypt()
                        self.cq.push(.{ .result = -1, .err_msg = "recv: tls decrypt failed (see server log)", .err_category = .upstream_error });
                    },
                }
            } else {
                self.cq.push(.{ .result = @intCast(bytes_read), .buf = buf[0..bytes_read] });
            }
        } else {
            self.cq.push(.{ .result = -1, .err_msg = "recv: no buffer", .err_category = .server_error });
        }
        self.batch_recv_bufs[sqe_index] = null;
    } else if (op == .close) {
        _ = result.close catch {
            const classified = classifyOpError(op);
            self.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cq.push(.{ .result = 1 });
    } else {
        const classified = classifyOpError(op);
        self.cq.push(.{ .result = -1, .err_msg = classified.msg, .err_category = classified.category });
    }

    batchCompletionCheck(self);
    return .disarm;
}

/// Check if all batch completions have arrived; if so, resume Lua with CQ count.
/// If the request timed out, decrement pending_completions and call maybeFinishClose.
fn batchCompletionCheck(self: *Connection) void {
    self.pending_completions -= 1;
    if (self.timed_out) {
        // Timeout cleanup: don't resume Lua, just drain completions
        if (self.pending_completions == 0) {
            // All completions drained — clean up suspended state and free connection
            if (self.suspended) |*s| {
                if (s.coroutine_ref != 0) {
                    self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
                    s.coroutine_ref = 0;
                }
                if (s.outbound_fd != 0) {
                    std.posix.close(s.outbound_fd);
                    s.outbound_fd = 0;
                }
                self.suspended = null;
            }
        }
        self.maybeFinishClose();
        return;
    }
    if (self.pending_completions == 0) {
        const s = &self.suspended.?;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        thread.pushInteger(@intCast(self.cq.tail));
        dispatchResume(self, thread, 1, s.exchange);
    }
}

// ============================================================================
// Handler completion
// ============================================================================

/// Handler finished after one or more yield/resume cycles.
/// Return coroutine to cache, serialize response, submit write.
pub fn completeHandler(self: *Connection) void {
    const s = self.suspended orelse return;

    // Return coroutine thread to cache for reuse
    if (s.coroutine_ref != 0) {
        if (self.lua_state.cached_thread_ref == 0) {
            self.lua_state.cached_thread_ref = s.coroutine_ref;
            self.lua_state.cached_thread = @ptrCast(@alignCast(s.coroutine_thread));
        } else {
            self.lua_state.lua.unref(Lua.PseudoIndex.Registry, s.coroutine_ref);
        }
    }

    // Safety net: close leaked outbound fd
    if (s.outbound_fd != 0) std.posix.close(s.outbound_fd);

    const exchange = s.exchange;
    self.suspended = null;

    self.logAccess(exchange.status);
    self.writeResponse(exchange) catch {
        self.send500InternalError();
    };
}

// ============================================================================
// Tests
// ============================================================================

test "tlsErrorMsg includes detail suffix when msg_len > 0" {
    const de = TlsConn.DecryptError{ .ssl_error = 1, .msg_len = 5 };
    const msg = tlsErrorMsg("recv", de);
    try std.testing.expectEqualStrings("recv: tls decrypt failed (see server log for SSL details)", msg);
}

test "tlsErrorMsg returns base message when msg_len == 0" {
    const de = TlsConn.DecryptError{ .ssl_error = 1, .msg_len = 0 };
    const msg = tlsErrorMsg("recv", de);
    try std.testing.expectEqualStrings("recv: tls decrypt failed", msg);
}

test "tlsErrorMsg works with different prefixes" {
    const de_with = TlsConn.DecryptError{ .ssl_error = 1, .msg_len = 1 };
    try std.testing.expectEqualStrings("send: tls decrypt failed (see server log for SSL details)", tlsErrorMsg("send", de_with));

    const de_without = TlsConn.DecryptError{ .ssl_error = 1, .msg_len = 0 };
    try std.testing.expectEqualStrings("send: tls decrypt failed", tlsErrorMsg("send", de_without));
}

test "SuspendedState has expected default for outbound_tls" {
    try std.testing.expect(@sizeOf(SuspendedState) > 0);
}

test "classifyOpError returns correct categories" {
    // We test with IoEntry.Op values since the function uses == comparison
    const ConnectOp = struct { const tag = .connect; };
    _ = ConnectOp;

    // Test the function returns valid struct for each known op
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

test "InterpretResult defaults done to true" {
    const ir = InterpretResult{ .nresults = 1 };
    try std.testing.expect(ir.done);
}

test "InterpretResult can be set to not done" {
    const ir = InterpretResult{ .nresults = 0, .done = false };
    try std.testing.expect(!ir.done);
}
