//! Chunked transfer encoding streaming — yield-to-flush abstraction.
//!
//! Modeled on conn_sse.zig. Lua sets ctx.upgrade = "stream", optionally sets
//! status/headers/body, then each coroutine.yield() flushes ctx.body as a chunk.
//! Handler return sends the terminal chunk and returns to keep-alive.
//!
//! Wire format: "{hex_len}\r\n{data}\r\n" per chunk, "0\r\n\r\n" terminal.

const std = @import("std");
const xev = @import("xev");
const log = @import("../observability/log.zig");
const handler_mod = @import("handler.zig");
const Connection = handler_mod.Connection;
const HttpExchange = @import("../http/http_exchange.zig").HttpExchange;
const http = @import("../http/http.zig");
const castUserdata = @import("../util/helpers.zig").castUserdata;
const Lua = @import("luajit").Lua;
const c = @import("luajit_c");
const prom = @import("../observability/prom.zig");

/// Stream connection state — set after successful stream upgrade.
pub const StreamState = struct {
    exchange: *HttpExchange,
    coroutine_ref: i32,
    coroutine_thread: *anyopaque,
    empty_yield_count: u8 = 0,
};

/// Handle stream upgrade: send chunked headers, then resume coroutine for first chunk.
pub fn handleStreamUpgrade(self: *Connection, exchange: *HttpExchange) void {
    self.logAccess(exchange.status);

    // Build chunked response headers
    var response = exchange.toResponse();
    defer response.deinit();

    const alloc = self.arena.allocator();
    const estimated: usize = 512;
    var header_buf: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(alloc, estimated) catch {
        self.send500InternalError();
        return;
    };
    response.serializeChunkedHeaders(&header_buf.writer) catch {
        self.send500InternalError();
        return;
    };

    // Save stream state — coroutine info comes from the LuaState's yield
    self.stream_state = .{
        .exchange = exchange,
        .coroutine_ref = self.lua_state.coroutine_ref,
        .coroutine_thread = @ptrCast(self.lua_state.coroutine_thread.?),
    };
    self.lua_state.coroutine_ref = 0;
    self.lua_state.coroutine_thread = null;
    self.state = .streaming;

    // Check if there's a first chunk (ctx.body set before first yield)
    if (exchange.response_body.len > 0) {
        // Send headers + first chunk together
        const chunk = http.encodeChunk(alloc, exchange.response_body) catch {
            self.send500InternalError();
            return;
        };
        header_buf.writer.writeAll(chunk) catch {
            self.send500InternalError();
            return;
        };
    }

    self.submitSend(header_buf.writer.buffered(), onStreamWrite, false);
}

/// Callback after a stream write completes — resume coroutine for next chunk.
fn onStreamWrite(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;
    handleStreamPostWrite(self);
    return .disarm;
}

/// Post-write handler for streaming: resume the coroutine.
pub fn handleStreamPostWrite(self: *Connection) void {
    const ss = &self.stream_state.?;
    const thread: *Lua = @ptrCast(@alignCast(ss.coroutine_thread));

    while (true) {
        // Resume coroutine (0 return values from yield)
        self.lua_state.current_connection = self;
        const status = c.lua_resume(@ptrCast(thread), 0);
        self.lua_state.current_connection = null;

        switch (status) {
            0 => {
                // LUA_OK — handler returned, send terminal chunk
                sendTerminalChunk(self);
                return;
            },
            1 => {
                // LUA_YIELD — handler yielded again, flush ctx.body as chunk
                const exchange = ss.exchange;
                if (exchange.response_body.len > 0) {
                    ss.empty_yield_count = 0;
                    const alloc = self.arena.allocator();
                    const chunk = http.encodeChunk(alloc, exchange.response_body) catch {
                        self.close();
                        return;
                    };
                    self.submitSend(chunk, onStreamWrite, false);
                    return;
                } else {
                    ss.empty_yield_count += 1;
                    if (ss.empty_yield_count >= 64) {
                        log.err().string("msg", "stream 64 consecutive empty yields, closing").int("fd", self.socket).log();
                        self.close();
                        return;
                    }
                    continue;
                }
            },
            else => {
                // Lua error
                if (thread.isString(-1)) {
                    const err_msg = thread.toString(-1) catch "unknown error";
                    log.err().string("msg", "stream handler error").int("fd", self.socket).string("error", std.mem.span(err_msg)).log();
                }
                // Errored coroutine is permanently dead (not reusable) — unref
                // it and match dispatchCoroutine's start-of-request increment.
                // Must happen before close(), which can synchronously deinit
                // (deinit would otherwise see stream_state still set and
                // double-handle it).
                prom.luaCoroutineFinished();
                self.lua_state.recycleThread(ss.coroutine_ref, ss.coroutine_thread);
                self.stream_state = null;
                self.close();
                return;
            },
        }
    }
}

/// Send the terminal chunk "0\r\n\r\n" and transition back to keep-alive.
fn sendTerminalChunk(self: *Connection) void {
    // Return coroutine to cache
    const ss = self.stream_state.?;
    // Match dispatchCoroutine's start-of-request increment (prom.luaCoroutineStarted).
    prom.luaCoroutineFinished();
    self.lua_state.recycleThread(ss.coroutine_ref, ss.coroutine_thread);
    self.stream_state = null;

    // Send terminal chunk — onWrite will dispatch to handleHttpPostWrite for keep-alive
    self.state = .writing;
    self.submitSend(http.terminal_chunk, onTerminalWrite, true);
}

/// Callback after terminal chunk write — transition back to HTTP keep-alive.
fn onTerminalWrite(
    userdata: ?*anyopaque,
    loop: *xev.Loop,
    completion: *xev.Completion,
    result: xev.Result,
) xev.CallbackAction {
    _ = loop;
    _ = completion;
    const self = castUserdata(Connection, userdata);
    _ = self.handleSendCompletion(result) orelse return .disarm;
    // Reuse handleHttpPostWrite for keep-alive/pipelining reset
    self.handleHttpPostWrite();
    return .disarm;
}
