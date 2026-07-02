//! Zig-native JSON encode/decode exposed as Lua C functions.
//! Replaces the cjson LuaRock — no external dependencies needed.

const std = @import("std");
const Lua = @import("luajit").Lua;

const max_depth = 128;
const alloc = std.heap.c_allocator;

const Buf = std.Io.Writer.Allocating;

const EncodeError = error{
    DepthLimitExceeded,
    OutOfMemory,
    NotSerializable,
    InvalidNumber,
};

// ── Encode ──────────────────────────────────────────────────────────

/// Lua C function: json.encode(value) → string
/// Converts the Lua value at stack[1] to a JSON string.
pub fn jsonEncode(lua: *Lua) callconv(.c) c_int {
    if (lua.getTop() < 1) {
        lua.pushString("JSON encode: argument required");
        lua.raiseError();
    }
    var buf: Buf = .init(alloc);

    encodeValue(lua, 1, &buf, 0) catch |err| {
        buf.deinit();
        const msg: [*:0]const u8 = switch (err) {
            error.DepthLimitExceeded => "JSON encode: depth limit exceeded (circular reference?)",
            error.OutOfMemory => "JSON encode: out of memory",
            error.NotSerializable => "JSON encode: type is not JSON serializable",
            error.InvalidNumber => "JSON encode: NaN/Inf are not allowed in JSON",
        };
        lua.pushString(msg);
        lua.raiseError();
    };

    lua.pushLString(buf.written());
    buf.deinit();
    return 1;
}

fn encodeValue(lua: *Lua, idx: i32, buf: *Buf, depth: u32) EncodeError!void {
    if (depth >= max_depth) return error.DepthLimitExceeded;

    // Compute absolute index so stack growth during recursion doesn't shift it.
    const abs = if (idx > 0) idx else lua.getTop() + idx + 1;

    switch (lua.getType(abs)) {
        .nil, .none => buf.writer.writeAll("null") catch return error.OutOfMemory,
        .boolean => buf.writer.writeAll(if (lua.toBoolean(abs)) "true" else "false") catch return error.OutOfMemory,
        .string => {
            const str = lua.toLString(abs) catch return error.NotSerializable;
            try encodeString(str, buf);
        },
        .number => try encodeNumber(lua, abs, buf),
        .table => try encodeTable(lua, abs, buf, depth),
        else => return error.NotSerializable,
    }
}

fn encodeNumber(lua: *Lua, idx: i32, buf: *Buf) EncodeError!void {
    const n = lua.toNumber(idx);
    if (std.math.isNan(n) or std.math.isInf(n)) return error.InvalidNumber;
    buf.writer.print("{d}", .{n}) catch return error.OutOfMemory;
}

fn encodeString(str: []const u8, buf: *Buf) EncodeError!void {
    std.json.Stringify.encodeJsonString(str, .{}, &buf.writer) catch return error.OutOfMemory;
}

fn encodeTable(lua: *Lua, abs_idx: i32, buf: *Buf, depth: u32) EncodeError!void {
    // Detect array: if table[1] is non-nil, treat as array
    const first_type = lua.getTableIndexRaw(abs_idx, 1);
    if (first_type != .nil) {
        lua.pop(1);
        buf.writer.writeByte('[') catch return error.OutOfMemory;
        var i: i32 = 1;
        while (true) {
            const t = lua.getTableIndexRaw(abs_idx, i);
            if (t == .nil) {
                lua.pop(1);
                break;
            }
            if (i > 1) buf.writer.writeByte(',') catch return error.OutOfMemory;
            try encodeValue(lua, -1, buf, depth + 1);
            lua.pop(1);
            i += 1;
        }
        buf.writer.writeByte(']') catch return error.OutOfMemory;
        return;
    }
    lua.pop(1); // pop nil from table[1] check

    // Object mode (or empty table)
    lua.pushNil();
    if (!lua.next(abs_idx)) {
        buf.writer.writeAll("{}") catch return error.OutOfMemory;
        return;
    }

    buf.writer.writeByte('{') catch return error.OutOfMemory;
    var first = true;
    // First key-value pair already on stack from next() above
    while (true) {
        // key at -2, value at -1
        if (lua.isString(-2)) {
            if (!first) buf.writer.writeByte(',') catch return error.OutOfMemory;
            first = false;

            const key = lua.toLString(-2) catch {
                lua.pop(2);
                return error.NotSerializable;
            };
            try encodeString(key, buf);
            buf.writer.writeByte(':') catch return error.OutOfMemory;
            try encodeValue(lua, -1, buf, depth + 1);
        }
        lua.pop(1); // pop value, keep key for next()
        if (!lua.next(abs_idx)) break;
    }
    buf.writer.writeByte('}') catch return error.OutOfMemory;
}

// ── Decode ──────────────────────────────────────────────────────────

/// Lua C function: json.decode(string) → value
/// Parses a JSON string and pushes the corresponding Lua value.
pub fn jsonDecode(lua: *Lua) callconv(.c) c_int {
    if (lua.getTop() < 1 or !lua.isString(1)) {
        lua.pushString("JSON decode: string argument required");
        lua.raiseError();
    }
    const input = lua.toLString(1) catch {
        lua.pushString("JSON decode: string argument required");
        lua.raiseError();
    };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, input, .{}) catch {
        lua.pushString("JSON decode: invalid JSON");
        lua.raiseError();
    };
    defer parsed.deinit();

    pushJsonValue(lua, parsed.value);
    return 1;
}

fn pushJsonValue(lua: *Lua, value: std.json.Value) void {
    switch (value) {
        .null => lua.pushNil(),
        .bool => |b| lua.pushBoolean(b),
        .integer => |i| lua.pushInteger(@intCast(i)),
        .float => |f| lua.pushNumber(f),
        .string => |s| lua.pushLString(s),
        .number_string => |s| lua.pushLString(s),
        .array => |arr| {
            lua.createTable(@intCast(arr.items.len), 0);
            for (arr.items, 1..) |item, i| {
                pushJsonValue(lua, item);
                lua.setTableIndexRaw(-2, @intCast(i));
            }
        },
        .object => |obj| {
            lua.createTable(0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                lua.pushLString(entry.key_ptr.*);
                pushJsonValue(lua, entry.value_ptr.*);
                lua.setTable(-3); // table[key] = value, pops both
            }
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────

test "encode primitives" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonEncode);
    lua.setGlobal("json_encode");

    try state.loadString("assert(json_encode(nil) == 'null')");
    try state.loadString("assert(json_encode(true) == 'true')");
    try state.loadString("assert(json_encode(false) == 'false')");
    try state.loadString("assert(json_encode(42) == '42')");
    try state.loadString("assert(json_encode(0) == '0')");
    try state.loadString("assert(json_encode(-7) == '-7')");
    try state.loadString("assert(json_encode(3.14) == '3.14')");
    try state.loadString("assert(json_encode('hello') == '\"hello\"')");
    try state.loadString("assert(json_encode('') == '\"\"')");
}

test "encode string escaping" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonEncode);
    lua.setGlobal("json_encode");

    try state.loadString("assert(json_encode('a\"b') == '\"a\\\\\"b\"')");
    try state.loadString("assert(json_encode('a\\\\b') == '\"a\\\\\\\\b\"')");
    try state.loadString("assert(json_encode('a\\nb') == '\"a\\\\nb\"')");
    try state.loadString("assert(json_encode('a\\tb') == '\"a\\\\tb\"')");
}

test "encode tables" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonEncode);
    lua.setGlobal("json_encode");

    try state.loadString("assert(json_encode({}) == '{}')");
    try state.loadString("assert(json_encode({1,2,3}) == '[1,2,3]')");
    try state.loadString("assert(json_encode({1,{2,3}}) == '[1,[2,3]]')");
    try state.loadString("assert(json_encode({a=1}) == '{\"a\":1}')");
}

test "decode primitives" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonDecode);
    lua.setGlobal("json_decode");

    try state.loadString("assert(json_decode('null') == nil)");
    try state.loadString("assert(json_decode('true') == true)");
    try state.loadString("assert(json_decode('false') == false)");
    try state.loadString("assert(json_decode('42') == 42)");
    try state.loadString("assert(json_decode('3.14') == 3.14)");
    try state.loadString("assert(json_decode('\"hello\"') == 'hello')");
}

test "decode objects and arrays" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonDecode);
    lua.setGlobal("json_decode");

    try state.loadString(
        \\local t = json_decode('[1,2,3]')
        \\assert(t[1] == 1 and t[2] == 2 and t[3] == 3)
    );

    try state.loadString(
        \\local t = json_decode('{"name":"keyway","version":1}')
        \\assert(t.name == "keyway")
        \\assert(t.version == 1)
    );
}

test "roundtrip encode/decode" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonEncode);
    lua.setGlobal("json_encode");
    lua.pushCFunction(jsonDecode);
    lua.setGlobal("json_decode");

    try state.loadString(
        \\local t = {1, "two", true, false}
        \\local json = json_encode(t)
        \\local t2 = json_decode(json)
        \\assert(t2[1] == 1)
        \\assert(t2[2] == "two")
        \\assert(t2[3] == true)
        \\assert(t2[4] == false)
    );

    try state.loadString(
        \\local t = {status = 200, message = "ok"}
        \\local json = json_encode(t)
        \\local t2 = json_decode(json)
        \\assert(t2.status == 200)
        \\assert(t2.message == "ok")
    );
}

// Note: error paths (NaN/Inf, depth limit, invalid JSON) use raiseError (longjmp)
// which crashes Zig's test runner in debug builds. Tested via integration tests.
