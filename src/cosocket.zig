const std = @import("std");
const xev = @import("xev");
const http = @import("http.zig");
const HttpExchange = @import("http_exchange.zig").HttpExchange;
const LuaState = @import("lua_state.zig").LuaState;
const io_request_mod = @import("io_request.zig");
const TlsMode = io_request_mod.TlsMode;
const IoEntry = ring.IoEntry;
const ring = @import("ring.zig");
const tls_mod = @import("tls.zig");
const TlsConn = tls_mod.TlsConn;
const Lua = @import("luajit").Lua;

const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;

/// Cosocket suspend state — bundled so one `= null` replaces seven resets.
/// Non-null means a handler is yielded waiting on outbound I/O.
pub const SuspendedState = struct {
    completion: xev.Completion,
    exchange: *HttpExchange,
    recv_buf: ?[]u8,
    coroutine_ref: i32,
    coroutine_thread: *anyopaque,
    outbound_fd: std.posix.socket_t,
    pending_op: IoEntry.Op,
    outbound_tls: ?*TlsConn = null, // temporary, during handshake only
};

/// Format a TLS decrypt error into a static sentinel-terminated string for Lua.
/// Includes SSL_ERROR code and first ERR queue message if available.
fn tlsErrorMsg(comptime prefix: []const u8, de: TlsConn.DecryptError) [:0]const u8 {
    if (de.msg_len > 0) {
        return prefix ++ ": tls decrypt failed (see server log for SSL details)";
    }
    return prefix ++ ": tls decrypt failed";
}

/// Encrypt plaintext via TLS and drain into an allocated buffer.
/// Returns ciphertext slice, or null on encrypt/alloc failure.
pub fn tlsEncryptAlloc(tc: *TlsConn, plaintext: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    tc.encrypt(plaintext) catch return null;
    return tc.drainAllAlloc(allocator) catch null;
}

/// Select the SSL_CTX for outbound cosocket TLS based on the requested mode.
fn selectClientTlsCtx(lua_state: *LuaState, mode: TlsMode) @TypeOf(lua_state.tls_manager.client_tls_ctx.ctx) {
    return switch (mode) {
        .verify => lua_state.tls_manager.client_tls_ctx.ctx,
        .insecure => lua_state.tls_manager.insecure_tls_ctx.ctx,
        .custom => if (lua_state.tls_manager.custom_tls_ctx) |ctx| ctx.ctx else lua_state.tls_manager.insecure_tls_ctx.ctx,
    };
}

/// Dispatch I/O after a Lua yield: ring path (SQ has entries) or old single-shot path.
pub fn dispatchIo(conn: *Connection) void {
    if (conn.sq.len() > 0) {
        drainSubmissionRing(conn);
    } else {
        submitOutboundIO(conn);
    }
}

/// Read pending_io from LuaState, create socket / submit xev operation
fn submitOutboundIO(self: *Connection) void {
    const s = &self.suspended.?;
    const pending = self.lua_state.pending_io orelse {
        resumeWithError(self, "no pending I/O operation");
        return;
    };
    self.lua_state.pending_io = null;

    switch (pending) {
        .connect => |c| {
            s.pending_op = .connect;
            const sock = std.posix.socket(
                std.posix.AF.INET,
                std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
                0,
            ) catch {
                resumeWithError(self, "socket creation failed");
                return;
            };
            s.outbound_fd = sock;

            const addr = std.net.Address.parseIp4(c.host, c.port) catch {
                std.posix.close(sock);
                s.outbound_fd = 0;
                resumeWithError(self, "connect: invalid address");
                return;
            };

            s.completion = .{
                .op = .{ .connect = .{ .socket = sock, .addr = addr } },
                .userdata = self,
                .callback = onOutboundComplete,
            };
            self.loop.add(&s.completion);
        },
        .pool_connect => |c| {
            s.pending_op = .pool_connect;
            const sock = std.posix.socket(
                std.posix.AF.INET,
                std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
                0,
            ) catch {
                resumeWithError(self, "socket creation failed");
                return;
            };
            s.outbound_fd = sock;

            const addr = std.net.Address.parseIp4(c.host, c.port) catch {
                std.posix.close(sock);
                s.outbound_fd = 0;
                resumeWithError(self, "connect: invalid address");
                return;
            };

            s.completion = .{
                .op = .{ .connect = .{ .socket = sock, .addr = addr } },
                .userdata = self,
                .callback = onOutboundComplete,
            };
            self.loop.add(&s.completion);
        },
        .udp_connect => |c| {
            s.pending_op = .udp_connect;
            const sock = std.posix.socket(
                std.posix.AF.INET,
                std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
                0,
            ) catch {
                resumeWithError(self, "udp_connect: socket creation failed");
                return;
            };
            // Set receive timeout once on the socket
            if (c.timeout_ms > 0) {
                const tv = std.posix.timeval{
                    .sec = @intCast(c.timeout_ms / 1000),
                    .usec = @intCast((c.timeout_ms % 1000) * 1000),
                };
                _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
            }

            s.outbound_fd = sock;

            const addr = std.net.Address.parseIp4(c.host, c.port) catch {
                std.posix.close(sock);
                s.outbound_fd = 0;
                resumeWithError(self, "udp_connect: invalid address");
                return;
            };

            s.completion = .{
                .op = .{ .connect = .{ .socket = sock, .addr = addr } },
                .userdata = self,
                .callback = onOutboundComplete,
            };
            self.loop.add(&s.completion);
        },
        .send => |snd| {
            // Arena-dupe send_data before async submission — Lua string may be GC'd across yield
            const data = self.arena.allocator().dupe(u8, snd.data) catch {
                resumeWithError(self, "send: arena alloc failed");
                return;
            };
            // TLS-aware send: encrypt if fd has TLS state
            if (self.lua_state.getTls(snd.fd)) |tls_conn| {
                const ciphertext = tlsEncryptAlloc(tls_conn, data, self.arena.allocator()) orelse {
                    resumeWithError(self, "send: tls encrypt failed");
                    return;
                };
                s.completion = .{
                    .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = ciphertext } } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&s.completion);
            } else {
                s.completion = .{
                    .op = .{ .send = .{ .fd = snd.fd, .buffer = .{ .slice = data } } },
                    .userdata = self,
                    .callback = onOutboundComplete,
                };
                self.loop.add(&s.completion);
            }
        },
        .recv => |r| {
            // If fd has TLS state, check if BoringSSL already has buffered plaintext
            // from a previous feedCiphertext call. Without this check, the kernel recv
            // blocks because postgres has nothing more to send — the data is already
            // inside BoringSSL's internal buffers.
            if (self.lua_state.getTls(r.fd)) |tls_conn| {
                if (tls_conn.hasPending()) {
                    var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                    switch (tls_conn.decrypt(&plaintext_buf)) {
                        .data => |n| {
                            const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
                            thread.pushLString(plaintext_buf[0..n]);
                            dispatchResume(self, thread, 1, s.exchange);
                            return;
                        },
                        .want_read => {}, // Fall through to kernel recv
                        .zero_return => {
                            resumeWithError(self, "recv: tls connection closed");
                            return;
                        },
                        .err => |de| {
                            resumeWithTlsError(self, "recv", de);
                            return;
                        },
                    }
                }
            }

            const buf = self.arena.allocator().alloc(u8, r.max_len) catch {
                resumeWithError(self, "recv: alloc failed");
                return;
            };
            s.recv_buf = buf;

            s.completion = .{
                .op = .{ .recv = .{ .fd = r.fd, .buffer = .{ .slice = buf } } },
                .userdata = self,
                .callback = onOutboundComplete,
            };
            self.loop.add(&s.completion);
        },
        .close => |c| {
            // Clean up TLS state for this fd if present
            self.lua_state.removeTls(c.fd);
            s.completion = .{
                .op = .{ .close = .{ .fd = c.fd } },
                .userdata = self,
                .callback = onOutboundComplete,
            };
            self.loop.add(&s.completion);
        },
        .tls_handshake => |th| {
            s.pending_op = .tls_handshake;
            // Allocate TlsConn from base_allocator (outlives request)
            const tls_conn = self.base_allocator.create(TlsConn) catch {
                resumeWithError(self, "sslhandshake: alloc failed");
                return;
            };
            tls_conn.* = TlsConn.init(self.base_allocator, selectClientTlsCtx(self.lua_state, th.tls_mode), .client) catch {
                self.base_allocator.destroy(tls_conn);
                resumeWithError(self, "sslhandshake: tls init failed");
                return;
            };

            // Set SNI if host provided
            if (th.sni_host) |host| {
                const host_z = self.arena.allocator().dupeZ(u8, host) catch {
                    tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                    resumeWithError(self, "sslhandshake: alloc failed");
                    return;
                };
                tls_conn.setSni(host_z);
            }

            s.outbound_tls = tls_conn;

            // Kick off handshake — produces ClientHello in wbio
            _ = tls_conn.handshake();

            // Drain wbio and send ClientHello
            const total = tls_conn.drainAll();
            if (total == 0) {
                tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                s.outbound_tls = null;
                resumeWithError(self, "sslhandshake: no handshake data produced");
                return;
            }

            s.completion = .{
                .op = .{ .send = .{ .fd = th.fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                .userdata = self,
                .callback = onTlsOutboundHandshakeSend,
            };
            s.outbound_fd = th.fd;
            self.loop.add(&s.completion);
        },
        .setkeepalive => {
            resumeWithError(self, "setkeepalive: not valid as pending I/O");
        },
        .none => {
            resumeWithError(self, "no pending I/O operation");
        },
    }
}

/// xev callback for all outbound I/O completions
fn onOutboundComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;

    const self: *Connection = @ptrCast(@alignCast(userdata.?));
    const s = &self.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    const exchange_ptr = s.exchange;

    // Determine what completed based on the op that was submitted
    const op = completion.op;
    var nresults: c_int = 1;

    if (op == .connect) {
        _ = result.connect catch {
            std.posix.close(s.outbound_fd);
            s.outbound_fd = 0;
            thread.pushNil();
            thread.pushString("connection refused");
            nresults = 2;
            s.pending_op = .none;
            dispatchResume(self, thread, nresults, exchange_ptr);
            return .disarm;
        };
        if (s.pending_op == .pool_connect) {
            // pool_connect returns (fd, reuse_count=0)
            thread.pushInteger(@intCast(s.outbound_fd));
            thread.pushInteger(0);
            nresults = 2;
        } else {
            // connect and udp_connect both return fd only
            thread.pushInteger(@intCast(s.outbound_fd));
        }
        s.outbound_fd = 0; // ownership transferred to Lua; completeHandler must not close it
        s.pending_op = .none;
    } else if (op == .send) {
        const bytes_sent = result.send catch {
            thread.pushNil();
            thread.pushString("send failed");
            nresults = 2;
            dispatchResume(self, thread, nresults, exchange_ptr);
            return .disarm;
        };
        thread.pushInteger(@intCast(bytes_sent));
    } else if (op == .recv) {
        const bytes_read = result.recv catch {
            thread.pushNil();
            thread.pushString("recv failed");
            nresults = 2;
            s.recv_buf = null;
            dispatchResume(self, thread, nresults, exchange_ptr);
            return .disarm;
        };
        if (s.recv_buf) |buf| {
            // Check if this fd has TLS state — decrypt before pushing to Lua
            if (self.lua_state.getTls(completion.op.recv.fd)) |tls_conn| {
                tls_conn.feedCiphertext(buf[0..bytes_read]);
                var plaintext_buf: [tls_mod.TLS_RECORD_MAX_SIZE]u8 = undefined;
                switch (tls_conn.decrypt(&plaintext_buf)) {
                    .data => |n| {
                        thread.pushLString(plaintext_buf[0..n]);
                    },
                    .want_read => {
                        // Need more ciphertext — re-submit recv without resuming Lua
                        s.completion = .{
                            .op = .{ .recv = .{ .fd = completion.op.recv.fd, .buffer = .{ .slice = buf } } },
                            .userdata = self,
                            .callback = onOutboundComplete,
                        };
                        self.loop.add(&s.completion);
                        return .disarm;
                    },
                    .zero_return => {
                        thread.pushNil();
                        thread.pushString("recv: tls connection closed");
                        nresults = 2;
                        s.recv_buf = null;
                        dispatchResume(self, thread, nresults, exchange_ptr);
                        return .disarm;
                    },
                    .err => |de| {
                        thread.pushNil();
                        thread.pushString(tlsErrorMsg("recv", de));
                        nresults = 2;
                        s.recv_buf = null;
                        dispatchResume(self, thread, nresults, exchange_ptr);
                        return .disarm;
                    },
                }
            } else {
                thread.pushLString(buf[0..bytes_read]);
            }
        } else {
            thread.pushNil();
        }
        s.recv_buf = null;
    } else if (op == .close) {
        _ = result.close catch {
            thread.pushNil();
            thread.pushString("close failed");
            nresults = 2;
            dispatchResume(self, thread, nresults, exchange_ptr);
            return .disarm;
        };
        s.outbound_fd = 0; // fd is now closed; prevent completeHandler double-close
        thread.pushInteger(1);
    } else {
        thread.pushNil();
        thread.pushString("unknown outbound op");
        nresults = 2;
    }

    dispatchResume(self, thread, nresults, exchange_ptr);
    return .disarm;
}

/// TLS outbound handshake: send completed -> check if done or recv more
fn onTlsOutboundHandshakeSend(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const self: *Connection = @ptrCast(@alignCast(userdata.?));
    const s = &self.suspended.?;
    const tls_conn = s.outbound_tls orelse {
        resumeWithError(self, "sslhandshake: missing tls state");
        return .disarm;
    };

    _ = result.send catch {
        cleanupOutboundTls(self);
        resumeWithError(self, "sslhandshake: send failed");
        return .disarm;
    };

    // If handshake already completed (we were just flushing final wbio), finish now
    if (tls_conn.isEstablished()) {
        finishOutboundHandshake(self, tls_conn);
        return .disarm;
    }

    // Need more data from server — recv
    submitTlsHandshakeRecv(self);
    return .disarm;
}

/// TLS outbound handshake: recv completed -> feed to SSL, continue or complete
fn onTlsOutboundHandshakeRecv(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;

    const self: *Connection = @ptrCast(@alignCast(userdata.?));
    const s = &self.suspended.?;
    const tls_conn = s.outbound_tls orelse {
        resumeWithError(self, "sslhandshake: missing tls state");
        return .disarm;
    };

    const bytes_read = result.recv catch {
        cleanupOutboundTls(self);
        resumeWithError(self, "sslhandshake: recv failed");
        return .disarm;
    };

    if (bytes_read == 0) {
        cleanupOutboundTls(self);
        resumeWithError(self, "sslhandshake: connection closed");
        return .disarm;
    }

    // Feed received ciphertext to TLS engine
    if (s.recv_buf) |buf| {
        tls_conn.feedCiphertext(buf[0..bytes_read]);
    }

    const hs_result = tls_conn.handshake();

    // Drain any outbound data the handshake produced (e.g. Finished)
    if (tls_conn.needsWrite()) {
        const total = tls_conn.drainAll();
        if (total > 0) {
            // Send it — onTlsOutboundHandshakeSend checks .established to know if done
            s.completion = .{
                .op = .{ .send = .{ .fd = s.outbound_fd, .buffer = .{ .slice = tls_conn.encrypt_buf[0..total] } } },
                .userdata = self,
                .callback = onTlsOutboundHandshakeSend,
            };
            self.loop.add(&s.completion);
            return .disarm;
        }
    }

    switch (hs_result) {
        .complete => finishOutboundHandshake(self, tls_conn),
        .want_read => submitTlsHandshakeRecv(self),
        .failed => {
            cleanupOutboundTls(self);
            resumeWithError(self, "sslhandshake: handshake failed");
        },
    }
    return .disarm;
}

/// Finish a successful outbound TLS handshake — store in tls_map, resume Lua
fn finishOutboundHandshake(self: *Connection, tls_conn: *TlsConn) void {
    const s = &self.suspended.?;
    self.lua_state.registerTls(s.outbound_fd, tls_conn) catch {
        cleanupOutboundTls(self);
        resumeWithError(self, "sslhandshake: map put failed");
        return;
    };
    s.outbound_tls = null;
    s.outbound_fd = 0;
    s.pending_op = .none;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushInteger(1);
    dispatchResume(self, thread, 1, s.exchange);
}

/// Submit a recv for handshake data, reusing existing recv_buf or allocating one
fn submitTlsHandshakeRecv(self: *Connection) void {
    const s = &self.suspended.?;
    const buf = s.recv_buf orelse blk: {
        const b = self.arena.allocator().alloc(u8, tls_mod.TLS_RECORD_MAX_SIZE) catch {
            cleanupOutboundTls(self);
            resumeWithError(self, "sslhandshake: alloc failed");
            return;
        };
        s.recv_buf = b;
        break :blk b;
    };
    s.completion = .{
        .op = .{ .recv = .{ .fd = s.outbound_fd, .buffer = .{ .slice = buf } } },
        .userdata = self,
        .callback = onTlsOutboundHandshakeRecv,
    };
    self.loop.add(&s.completion);
}

/// Clean up outbound TLS state on handshake failure
fn cleanupOutboundTls(self: *Connection) void {
    const s = &self.suspended.?;
    if (s.outbound_tls) |tls_conn| {
        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
        s.outbound_tls = null;
    }
}

/// Resume coroutine and dispatch based on result
pub fn dispatchResume(self: *Connection, thread: *Lua, nresults: c_int, exchange_ptr: *HttpExchange) void {
    self.lua_state.current_connection = self;
    const resume_result = self.lua_state.resumeHandler(@ptrCast(thread), nresults, exchange_ptr) catch {
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
                submitBatchConnect(self, c.host, c.port, io_index, .connect);
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
                    submitBatchConnect(self, c.host, c.port, io_index, .pool_connect);
                }
                io_index += 1;
            },
            .send => |snd| {
                // Arena-dupe send_data before async submission (Lua string lifetime safety)
                const duped = self.arena.allocator().dupe(u8, snd.data) catch {
                    self.cq.push(.{ .result = -1, .err_msg = "send: arena alloc failed" });
                    io_index += 1;
                    continue;
                };
                // TLS-aware send
                if (self.lua_state.getTls(snd.fd)) |tls_conn| {
                    const ciphertext = tlsEncryptAlloc(tls_conn, duped, self.arena.allocator()) orelse {
                        self.cq.push(.{ .result = -1, .err_msg = "send: tls encrypt failed" });
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
                                    self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed" });
                                    io_index += 1;
                                    continue;
                                };
                                self.cq.push(.{ .result = @intCast(n), .buf = buf_copy });
                                io_index += 1;
                                continue;
                            },
                            .want_read => {}, // fall through to kernel recv
                            .zero_return => {
                                self.cq.push(.{ .result = -1, .err_msg = "recv: tls connection closed" });
                                io_index += 1;
                                continue;
                            },
                            .err => {
                                // Detail already logged by decrypt()
                                self.cq.push(.{ .result = -1, .err_msg = "recv: tls decrypt failed (see server log)" });
                                io_index += 1;
                                continue;
                            },
                        }
                    }
                }
                const buf = self.arena.allocator().alloc(u8, r.max_len) catch {
                    self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed" });
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
                    self.cq.push(.{ .result = -1, .err_msg = "setkeepalive: pool put failed" });
                    io_index += 1;
                    continue;
                };
                self.cq.push(.{ .result = 1 });
                io_index += 1;
            },
            .tls_handshake => |t| {
                // TLS handshake is multi-step — submit as a sequence via the existing mechanism
                const tls_conn = self.base_allocator.create(TlsConn) catch {
                    self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed" });
                    io_index += 1;
                    continue;
                };
                tls_conn.* = TlsConn.init(self.base_allocator, selectClientTlsCtx(self.lua_state, t.tls_mode), .client) catch {
                    self.base_allocator.destroy(tls_conn);
                    self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: tls init failed" });
                    io_index += 1;
                    continue;
                };
                if (t.sni_host) |host| {
                    const host_z = self.arena.allocator().dupeZ(u8, host) catch {
                        tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                        self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: alloc failed" });
                        io_index += 1;
                        continue;
                    };
                    tls_conn.setSni(host_z);
                }

                _ = tls_conn.handshake();
                const total = tls_conn.drainAll();
                if (total == 0) {
                    tls_mod.freeTlsConn(self.base_allocator, tls_conn);
                    self.cq.push(.{ .result = -1, .err_msg = "tls_handshake: no data produced" });
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
                    .callback = onTlsOutboundHandshakeSend,
                };
                // TLS handshake hijacks the suspended state — can only have one per batch
                self.pending_completions += 1;
                self.loop.add(&self.batch_completions[io_index]);
                io_index += 1;
            },
            .udp_connect => |u| {
                submitBatchUdpConnect(self, u.host, u.port, u.timeout_ms, io_index);
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

/// Helper: create TCP socket and submit connect for batched I/O
fn submitBatchConnect(self: *Connection, host: []const u8, port: u16, io_index: u8, _: IoEntry.Op) void {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        self.cq.push(.{ .result = -1, .err_msg = "socket creation failed" });
        return;
    };

    const addr = std.net.Address.parseIp4(host, port) catch {
        std.posix.close(sock);
        self.cq.push(.{ .result = -1, .err_msg = "connect: invalid address" });
        return;
    };

    self.batch_completions[io_index] = .{
        .op = .{ .connect = .{ .socket = sock, .addr = addr } },
        .userdata = self,
        .callback = onBatchComplete,
    };
    self.pending_completions += 1;
    self.loop.add(&self.batch_completions[io_index]);
}

/// Helper: create UDP socket and submit connect for batched I/O
fn submitBatchUdpConnect(self: *Connection, host: []const u8, port: u16, timeout_ms: u32, io_index: u8) void {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch {
        self.cq.push(.{ .result = -1, .err_msg = "udp_connect: socket creation failed" });
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
        self.cq.push(.{ .result = -1, .err_msg = "udp_connect: invalid address" });
        return;
    };

    self.batch_completions[io_index] = .{
        .op = .{ .connect = .{ .socket = sock, .addr = addr } },
        .userdata = self,
        .callback = onBatchComplete,
    };
    self.pending_completions += 1;
    self.loop.add(&self.batch_completions[io_index]);
}

/// xev callback for batched I/O completions.
/// Writes result into CQ at the correct index. When all completions arrive, resumes Lua once.
fn onBatchComplete(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;

    const self: *Connection = @ptrCast(@alignCast(userdata.?));

    // Determine which SQE index this completion corresponds to
    const base = @intFromPtr(&self.batch_completions[0]);
    const this = @intFromPtr(completion);
    const sqe_index: u8 = @intCast((this - base) / @sizeOf(xev.Completion));

    const op = completion.op;

    if (op == .connect) {
        _ = result.connect catch {
            // Close the socket on connect failure
            std.posix.close(completion.op.connect.socket);
            self.cq.push(.{ .result = -1, .err_msg = "connection refused" });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cq.push(.{ .result = @intCast(completion.op.connect.socket) });
    } else if (op == .send) {
        const bytes_sent = result.send catch {
            self.cq.push(.{ .result = -1, .err_msg = "send failed" });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cq.push(.{ .result = @intCast(bytes_sent) });
    } else if (op == .recv) {
        const bytes_read = result.recv catch {
            self.batch_recv_bufs[sqe_index] = null;
            self.cq.push(.{ .result = -1, .err_msg = "recv failed" });
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
                            self.cq.push(.{ .result = -1, .err_msg = "recv: alloc failed" });
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
                        self.cq.push(.{ .result = -1, .err_msg = "recv: tls connection closed" });
                    },
                    .err => {
                        // Detail already logged by decrypt()
                        self.cq.push(.{ .result = -1, .err_msg = "recv: tls decrypt failed (see server log)" });
                    },
                }
            } else {
                self.cq.push(.{ .result = @intCast(bytes_read), .buf = buf[0..bytes_read] });
            }
        } else {
            self.cq.push(.{ .result = -1, .err_msg = "recv: no buffer" });
        }
        self.batch_recv_bufs[sqe_index] = null;
    } else if (op == .close) {
        _ = result.close catch {
            self.cq.push(.{ .result = -1, .err_msg = "close failed" });
            batchCompletionCheck(self);
            return .disarm;
        };
        self.cq.push(.{ .result = 1 });
    } else {
        self.cq.push(.{ .result = -1, .err_msg = "unknown op" });
    }

    batchCompletionCheck(self);
    return .disarm;
}

/// Check if all batch completions have arrived; if so, resume Lua with CQ count.
fn batchCompletionCheck(self: *Connection) void {
    self.pending_completions -= 1;
    if (self.pending_completions == 0) {
        const s = &self.suspended.?;
        const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
        thread.pushInteger(@intCast(self.cq.tail));
        dispatchResume(self, thread, 1, s.exchange);
    }
}

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

    const exchange_ptr = s.exchange;
    self.suspended = null;

    self.logAccess(exchange_ptr.status);
    self.writeResponse(exchange_ptr) catch {
        self.send500InternalError();
    };
}

/// Resume coroutine with nil, error_message for pre-submission failures
fn resumeWithError(self: *Connection, msg: [:0]const u8) void {
    const s = &self.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushNil();
    thread.pushString(msg);
    dispatchResume(self, thread, 2, s.exchange);
}

/// Resume with a descriptive TLS error message including SSL error details.
fn resumeWithTlsError(self: *Connection, comptime prefix: []const u8, de: TlsConn.DecryptError) void {
    const s = &self.suspended.?;
    const thread: *Lua = @ptrCast(@alignCast(s.coroutine_thread));
    thread.pushNil();
    thread.pushString(tlsErrorMsg(prefix, de));
    dispatchResume(self, thread, 2, s.exchange);
}
