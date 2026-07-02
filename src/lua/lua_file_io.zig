//! File I/O C-functions exposed to Lua.
//!
//! Admin-only operations — used by dashboard routes behind localhost_guard.

const std = @import("std");
const Lua = @import("luajit").Lua;
const LuaState = @import("lua_state.zig").LuaState;
const castUserdata = @import("../util/helpers.zig").castUserdata;

/// Register file I/O C functions as Lua globals.
/// Admin-only operations — used by dashboard routes behind localhost_guard.
pub fn registerFileApi(state: *LuaState) void {
    const file_funcs = .{
        .{ "__keyway_file_read", keyway_file_read },
        .{ "__keyway_file_write", keyway_file_write },
        .{ "__keyway_file_delete", keyway_file_delete },
        .{ "__keyway_file_list", keyway_file_list },
        .{ "__keyway_file_rename", keyway_file_rename },
    };
    inline for (file_funcs) |entry| {
        state.lua.pushLightUserdata(state);
        state.lua.pushCClosure(entry[1], 1);
        state.lua.setGlobal(entry[0]);
    }
}

/// Extract the LuaState pointer from upvalue(1) closure.
fn getLuaState(lua: *Lua) ?*LuaState {
    const ud = lua.toUserdata(Lua.PseudoIndex.upvalue(1)) orelse return null;
    return castUserdata(LuaState, @as(?*anyopaque, ud));
}

/// Push nil + error message and return 2 (Lua convention for value, err).
fn luaError(lua: *Lua, msg: [:0]const u8) c_int {
    lua.pushNil();
    lua.pushString(msg);
    return 2;
}

/// __keyway_file_read(path) -> string or nil, error
fn keyway_file_read(lua: *Lua) callconv(.c) c_int {
    const state = getLuaState(lua) orelse return 0;
    const path_c = lua.toString(1) catch return luaError(lua, "path argument required");
    const path = std.mem.span(path_c);

    var file_io: std.Io.Threaded = .init(state.allocator, .{});
    defer file_io.deinit();

    const content = std.Io.Dir.cwd().readFileAlloc(file_io.io(), path, state.allocator, .limited(10 * 1024 * 1024)) catch return luaError(lua, "file not found");
    defer state.allocator.free(content);

    lua.pushLString(content);
    return 1;
}

/// __keyway_file_write(path, content) -> true or nil, error
fn keyway_file_write(lua: *Lua) callconv(.c) c_int {
    const path_c = lua.toString(1) catch return luaError(lua, "path argument required");
    const content_c = lua.toString(2) catch return luaError(lua, "content argument required");
    const path = std.mem.span(path_c);
    const content = std.mem.span(content_c);

    // Atomic write: write to tmp file, then rename
    const state = getLuaState(lua) orelse return 0;
    const dir_path = std.fs.path.dirname(path) orelse ".";

    var file_io: std.Io.Threaded = .init(state.allocator, .{});
    defer file_io.deinit();
    const io = file_io.io();
    const cwd = std.Io.Dir.cwd();

    // Ensure parent directory exists
    cwd.createDirPath(io, dir_path) catch {};

    // Write tmp file and rename
    const tmp_path = std.fmt.allocPrint(state.allocator, "{s}.tmp", .{path}) catch return luaError(lua, "allocation failed");
    defer state.allocator.free(tmp_path);

    const file = cwd.createFile(io, tmp_path, .{}) catch return luaError(lua, "failed to create tmp file");
    file.writeStreamingAll(io, content) catch {
        file.close(io);
        return luaError(lua, "write error");
    };
    file.close(io);

    // Rename tmp -> target (atomic on same filesystem)
    cwd.rename(tmp_path, cwd, path, io) catch return luaError(lua, "rename failed");

    lua.pushBoolean(true);
    return 1;
}

/// __keyway_file_delete(path) -> true or nil, error
fn keyway_file_delete(lua: *Lua) callconv(.c) c_int {
    const state = getLuaState(lua) orelse return 0;
    const path_c = lua.toString(1) catch return luaError(lua, "path argument required");
    const path = std.mem.span(path_c);

    var file_io: std.Io.Threaded = .init(state.allocator, .{});
    defer file_io.deinit();

    std.Io.Dir.cwd().deleteFile(file_io.io(), path) catch return luaError(lua, "delete failed");

    lua.pushBoolean(true);
    return 1;
}

/// __keyway_file_rename(old_path, new_path) -> true or nil, error
fn keyway_file_rename(lua: *Lua) callconv(.c) c_int {
    const state = getLuaState(lua) orelse return 0;
    const old_c = lua.toString(1) catch return luaError(lua, "old_path argument required");
    const new_c = lua.toString(2) catch return luaError(lua, "new_path argument required");
    const old_path = std.mem.span(old_c);
    const new_path = std.mem.span(new_c);

    var file_io: std.Io.Threaded = .init(state.allocator, .{});
    defer file_io.deinit();
    const cwd = std.Io.Dir.cwd();

    cwd.rename(old_path, cwd, new_path, file_io.io()) catch return luaError(lua, "rename failed");

    lua.pushBoolean(true);
    return 1;
}

/// __keyway_file_list(dir) -> table of {path, name} or nil, error
fn keyway_file_list(lua: *Lua) callconv(.c) c_int {
    const state = getLuaState(lua) orelse return 0;
    const dir_c = lua.toString(1) catch return luaError(lua, "dir argument required");
    const dir_path = std.mem.span(dir_c);

    var file_io: std.Io.Threaded = .init(state.allocator, .{});
    defer file_io.deinit();

    lua.createTable(0, 0);
    var idx: i32 = 1;

    listLuaFilesRecursive(lua, file_io.io(), state.allocator, dir_path, dir_path, &idx);

    return 1;
}

fn listLuaFilesRecursive(lua: *Lua, io: std.Io, alloc: std.mem.Allocator, base: []const u8, dir_path: []const u8, idx: *i32) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            const sub = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch continue;
            defer alloc.free(sub);
            listLuaFilesRecursive(lua, io, alloc, base, sub, idx);
        } else if (entry.kind == .file and (std.mem.endsWith(u8, entry.name, ".lua") or std.mem.endsWith(u8, entry.name, ".lua.disabled"))) {
            const full = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch continue;
            defer alloc.free(full);

            // Compute relative path from base
            const rel = if (std.mem.startsWith(u8, full, base))
                if (full.len > base.len and full[base.len] == '/') full[base.len + 1 ..] else full[base.len..]
            else
                full;

            const enabled = std.mem.endsWith(u8, entry.name, ".lua");

            lua.createTable(0, 3);
            lua.pushLString(rel);
            lua.setField(-2, "path");
            lua.pushLString(entry.name);
            lua.setField(-2, "name");
            lua.pushBoolean(enabled);
            lua.setField(-2, "enabled");
            lua.setTableIndexRaw(-2, idx.*);
            idx.* += 1;
        }
    }
}
