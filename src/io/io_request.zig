const Lua = @import("luajit").Lua;
const LuaState = @import("../lua/lua_state.zig").LuaState;
const castUserdata = @import("../util/helpers.zig").castUserdata;

extern "c" fn lua_yield(L: *anyopaque, nresults: c_int) c_int;

/// Helper: extract *LuaState from closure upvalue(1)
inline fn getState(lua: *Lua) *LuaState {
    const ptr = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse {
        lua.pushString("cosocket: expected LuaState upvalue");
        lua.raiseError();
        unreachable;
    };
    return castUserdata(LuaState, @as(?*anyopaque, ptr));
}

/// __keyway_ws_send(data) → yields, resumes after WS frame is sent.
/// arg 1 = self (WsContext userdata, from ws:send() colon syntax), arg 2 = data string.
/// Uses the send variant with fd=0 as the ws_send signal (conn_ws checks for this).
pub fn keyway_ws_send(lua: *Lua) callconv(.c) c_int {
    const state = getState(lua);

    const data = lua.toLString(2) catch {
        lua.pushString("ws_send: data must be a string");
        lua.raiseError();
        return 0;
    };

    state.pending_io = .{ .send = .{
        .fd = 0,
        .data = data,
    } };

    return lua_yield(@ptrCast(lua), 0);
}
