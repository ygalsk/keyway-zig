//! File watcher for hot-reload via inotify + xev.
//!
//! Each worker creates its own inotify fd, watches the script directory tree
//! for .lua file changes. Debounces events (200ms) and triggers a reload
//! callback when the timer fires.
//!
//! Per-core isolation: each worker has an independent inotify instance.
//! The kernel delivers events to all watchers independently.

const std = @import("std");
const helpers = @import("../util/helpers.zig");
const xev = @import("xev");
const log = @import("../observability/log.zig");
const LuaState = @import("../lua/lua_state.zig").LuaState;
const Router = @import("../http/router.zig").Router;

const DEBOUNCE_MS = 200;

/// Watch events: create, modify, delete, move, self-delete
const WATCH_MASK: u32 = std.os.linux.IN.CREATE |
    std.os.linux.IN.MODIFY |
    std.os.linux.IN.DELETE |
    std.os.linux.IN.MOVED_TO |
    std.os.linux.IN.MOVED_FROM |
    std.os.linux.IN.DELETE_SELF;

pub const FileWatcher = struct {
    inotify_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,

    // Watch descriptor -> directory path mapping (for recursive watch)
    watch_dirs: std.AutoHashMap(i32, []const u8),

    // Debounce state
    debounce_armed: bool = false,
    debounce_completion: xev.Completion = .{},

    // Reload target
    lua_state: *LuaState,
    router: *Router,
    script_path: []const u8,

    // xev poll state
    poll_completion: xev.Completion = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        script_path: []const u8,
        lua_state: *LuaState,
        router: *Router,
    ) !FileWatcher {
        const fd = try helpers.inotifyInit1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        errdefer helpers.closeFd(fd);

        var watcher = FileWatcher{
            .inotify_fd = fd,
            .allocator = allocator,
            .watch_dirs = std.AutoHashMap(i32, []const u8).init(allocator),
            .lua_state = lua_state,
            .router = router,
            .script_path = script_path,
        };

        // Determine the directory to watch: parent of the script file
        const dir_path = std.fs.path.dirname(script_path) orelse ".";
        try watcher.addWatchRecursive(dir_path);

        return watcher;
    }

    pub fn deinit(self: *FileWatcher) void {
        var it = self.watch_dirs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.watch_dirs.deinit();
        helpers.closeFd(self.inotify_fd);
    }

    /// Add a watch on a directory and recurse into subdirectories.
    fn addWatchRecursive(self: *FileWatcher, dir_path: []const u8) !void {
        const dir_path_z = try self.allocator.dupeZ(u8, dir_path);
        defer self.allocator.free(dir_path_z);

        const wd = helpers.inotifyAddWatch(self.inotify_fd, dir_path_z, WATCH_MASK) catch |err| {
            log.warn().string("msg", "inotify_add_watch failed").string("path", dir_path).err(err).log();
            return;
        };

        const owned_path = try self.allocator.dupe(u8, dir_path);
        try self.watch_dirs.put(wd, owned_path);

        // Recurse into subdirectories
        var walk_io: std.Io.Threaded = .init(self.allocator, .{});
        defer walk_io.deinit();
        const io = walk_io.io();
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .directory) {
                const sub_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(sub_path);
                try self.addWatchRecursive(sub_path);
            }
        }
    }

    /// Start watching by registering the inotify fd with xev.
    /// Uses a timer-based poll since xev may not directly support arbitrary fd polling.
    pub fn start(self: *FileWatcher, loop: *xev.Loop) void {
        // Poll inotify fd every 500ms via timer
        self.armPollTimer(loop);
    }

    fn armPollTimer(self: *FileWatcher, loop: *xev.Loop) void {
        loop.timer(&self.poll_completion, 500, self, onPollTimer);
    }

    fn onPollTimer(
        userdata: ?*anyopaque,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.Result,
    ) xev.CallbackAction {
        const self: *FileWatcher = @ptrCast(@alignCast(userdata orelse return .disarm));

        // Read all pending inotify events
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        var has_lua_change = false;

        while (true) {
            const len = std.posix.read(self.inotify_fd, &buf) catch break;
            if (len == 0) break;

            var offset: usize = 0;
            while (offset < len) {
                const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(buf[offset..]));
                const name_len = event.len;
                if (name_len > 0) {
                    const name_start = offset + @sizeOf(std.os.linux.inotify_event);
                    const name_slice = buf[name_start..name_start + name_len];
                    // Name is null-terminated within the len bytes
                    const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(name_slice.ptr)), 0);

                    // Check if it's a .lua file
                    if (std.mem.endsWith(u8, name, ".lua")) {
                        has_lua_change = true;
                    }

                    // New directory created — add recursive watch
                    if (event.mask & std.os.linux.IN.CREATE != 0 and event.mask & std.os.linux.IN.ISDIR != 0) {
                        if (self.watch_dirs.get(event.wd)) |dir_path| {
                            const sub = std.fs.path.join(self.allocator, &.{ dir_path, name }) catch break;
                            defer self.allocator.free(sub);
                            self.addWatchRecursive(sub) catch {};
                        }
                    }
                }

                // Watched directory deleted or watch removed — clean up stale entry
                if (event.mask & (std.os.linux.IN.DELETE_SELF | std.os.linux.IN.IGNORED) != 0) {
                    if (self.watch_dirs.fetchRemove(event.wd)) |kv| {
                        self.allocator.free(kv.value);
                    }
                }

                offset += @sizeOf(std.os.linux.inotify_event) + name_len;
            }
        }

        if (has_lua_change and !self.debounce_armed) {
            self.debounce_armed = true;
            loop.timer(&self.debounce_completion, DEBOUNCE_MS, self, onDebounceTimer);
        }

        // Re-arm poll timer
        self.armPollTimer(loop);
        return .disarm;
    }

    fn onDebounceTimer(
        userdata: ?*anyopaque,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.Result,
    ) xev.CallbackAction {
        const self: *FileWatcher = @ptrCast(@alignCast(userdata orelse return .disarm));
        self.debounce_armed = false;

        log.info().string("msg", "file change detected — reloading").log();
        self.lua_state.reload(self.router, self.script_path);

        return .disarm;
    }
};
