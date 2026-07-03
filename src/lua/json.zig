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
    StackOverflow,
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
            error.StackOverflow => "JSON encode: stack overflow",
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
    try lua.checkStack(1);
    const first_type = lua.getTableIndexRaw(abs_idx, 1);
    if (first_type != .nil) {
        lua.pop(1);
        buf.writer.writeByte('[') catch return error.OutOfMemory;
        var i: i32 = 1;
        while (true) {
            try lua.checkStack(1);
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
    try lua.checkStack(1);
    lua.pushNil();
    try lua.checkStack(2); // next() pops the key, pushes key+value
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
        try lua.checkStack(2);
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

    // Not `defer parsed.deinit()`: raiseError() below longjmps, which would
    // skip a defer and leak the parsed tree. Free it explicitly on both the
    // success and error path, before ever raising.
    const result = pushJsonValue(lua, parsed.value, 0);
    parsed.deinit();
    result catch |err| {
        const msg: [*:0]const u8 = switch (err) {
            error.DepthLimitExceeded => "JSON decode: depth limit exceeded (deeply nested input)",
            error.OutOfMemory => "JSON decode: out of memory",
            error.StackOverflow => "JSON decode: stack overflow",
        };
        lua.pushString(msg);
        lua.raiseError();
    };
    return 1;
}

const DecodeError = error{
    DepthLimitExceeded,
    OutOfMemory,
    StackOverflow,
};

fn pushJsonValue(lua: *Lua, value: std.json.Value, depth: u32) DecodeError!void {
    switch (value) {
        .null => {
            try lua.checkStack(1);
            lua.pushNil();
        },
        .bool => |b| {
            try lua.checkStack(1);
            lua.pushBoolean(b);
        },
        .integer => |i| {
            try lua.checkStack(1);
            lua.pushInteger(@intCast(i));
        },
        .float => |f| {
            try lua.checkStack(1);
            lua.pushNumber(f);
        },
        .string => |s| {
            try lua.checkStack(1);
            lua.pushLString(s);
        },
        .number_string => |s| {
            try lua.checkStack(1);
            lua.pushLString(s);
        },
        .array => |arr| {
            if (depth >= max_depth) return error.DepthLimitExceeded;
            try lua.checkStack(1);
            lua.createTable(@intCast(arr.items.len), 0);
            for (arr.items, 1..) |item, i| {
                try pushJsonValue(lua, item, depth + 1);
                lua.setTableIndexRaw(-2, @intCast(i));
            }
        },
        .object => |obj| {
            if (depth >= max_depth) return error.DepthLimitExceeded;
            try lua.checkStack(1);
            lua.createTable(0, @intCast(obj.count()));
            var it = obj.iterator();
            while (it.next()) |entry| {
                try lua.checkStack(1);
                lua.pushLString(entry.key_ptr.*);
                try pushJsonValue(lua, entry.value_ptr.*, depth + 1);
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

test "encode of realistic deep nesting (under max_depth) still succeeds (#226)" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonEncode);
    lua.setGlobal("json_encode");

    // 120 levels is under max_depth (128) — a regression guard against a
    // future "fix" that clamps max_depth so low it breaks legitimate
    // deeply-nested payloads.
    try state.loadString(
        \\local t = {}
        \\local cur = t
        \\for i = 1, 120 do
        \\    cur[1] = {}
        \\    cur = cur[1]
        \\end
        \\cur[1] = "leaf"
        \\assert(type(json_encode(t)) == "string")
    );
}

test "decode of realistic deep nesting (under max_depth) still succeeds (#226)" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    lua.pushCFunction(jsonDecode);
    lua.setGlobal("json_decode");

    // Same 120-deep bound as the encode test above.
    const nested = ("[" ** 120) ++ ("]" ** 120);
    const code = "local t = json_decode('" ++ nested ++ "')\n" ++
        "assert(type(t) == \"table\")\n";
    try state.loadString(code);
}

test "pushJsonValue rejects input at or past max_depth (#226)" {
    const testing_alloc = std.testing.allocator;
    const LuaState = @import("lua_state.zig").LuaState;

    var state = try LuaState.init(testing_alloc);
    defer state.deinit();
    const lua = state.lua;

    // Call pushJsonValue directly on a synthetic (not parsed-from-text)
    // std.json.Value tree, bypassing jsonDecode's raiseError() wrapper
    // entirely — this is the one depth-limit assertion that doesn't longjmp,
    // so it's safe to check in a Zig unit test rather than an integration test.
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();

    var value: std.json.Value = .null;
    var depth: u32 = 0;
    while (depth <= max_depth) : (depth += 1) {
        var arr = std.json.Array.init(arena.allocator());
        try arr.append(value);
        value = .{ .array = arr };
    }

    try std.testing.expectError(error.DepthLimitExceeded, pushJsonValue(lua, value, 0));
}

// Note: error paths reached through jsonEncode/jsonDecode (NaN/Inf, invalid
// JSON, and the depth-limit/stack-overflow errors once raised as Lua errors)
// use raiseError (longjmp), which crashes Zig's test runner in debug builds.
// Tested via integration tests instead.
