const std = @import("std");
const helpers = @import("helpers.zig");

/// CLI configuration for the Keyway server.
/// Resolution order: CLI argument > environment variable > default value.
pub const Config = struct {
    pub const LogFormat = enum { logfmt, json };

    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    workers: u16 = 0,
    script: []const u8 = "keyway.lua",
    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,
    log_level: std.log.Level = .info,
    log_format: LogFormat = .logfmt,
    enable_bpf: bool = false,
    watch: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

const ParseError = error{
    InvalidPort,
    InvalidWorkers,
    InvalidLogLevel,
    InvalidLogFormat,
    MissingValue,
    UnknownOption,
};

/// Parse CLI arguments with environment variable fallback.
/// Caller owns no memory — all returned slices point into argv or env storage
/// (both managed by the OS, valid for the process lifetime).
pub fn parse(allocator: std.mem.Allocator, args_ctx: std.process.Args) (ParseError || std.process.Args.Iterator.InitError)!Config {
    var config = Config{};

    // host/script/tls-*/enable-bpf/watch never fail to parse from env, so
    // applying them before CLI args (which unconditionally overwrite below)
    // is a safe reorder: still CLI > env > default, zero presence tracking.
    if (helpers.getenv("KEYWAY_HOST")) |val| config.host = val;
    if (helpers.getenv("KEYWAY_SCRIPT")) |val| config.script = val;
    if (helpers.getenv("KEYWAY_TLS_CERT")) |val| config.tls_cert_path = val;
    if (helpers.getenv("KEYWAY_TLS_KEY")) |val| config.tls_key_path = val;
    if (helpers.getenv("KEYWAY_ENABLE_BPF")) |val| {
        config.enable_bpf = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
    }
    if (helpers.getenv("KEYWAY_WATCH")) |val| {
        config.watch = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
    }

    // port/workers/log-level/log-format *can* fail to parse. Applying their
    // env fallback up front like the fields above would make a malformed env
    // value raise an error even when a valid CLI flag was about to override
    // it — a precedence violation. Keep presence tracking for just these four
    // so env is only consulted when CLI never supplies the field.
    var cli_port = false;
    var cli_workers = false;
    var cli_log_level = false;
    var cli_log_format = false;

    var args = try args_ctx.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.show_help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            config.show_version = true;
            return config;
        } else if (std.mem.eql(u8, arg, "--host")) {
            config.host = args.next() orelse return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse return ParseError.MissingValue;
            config.port = std.fmt.parseInt(u16, val, 10) catch return ParseError.InvalidPort;
            cli_port = true;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const val = args.next() orelse return ParseError.MissingValue;
            config.workers = std.fmt.parseInt(u16, val, 10) catch return ParseError.InvalidWorkers;
            cli_workers = true;
        } else if (std.mem.eql(u8, arg, "--script")) {
            config.script = args.next() orelse return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tls-cert")) {
            config.tls_cert_path = args.next() orelse return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tls-key")) {
            config.tls_key_path = args.next() orelse return ParseError.MissingValue;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            const val = args.next() orelse return ParseError.MissingValue;
            config.log_level = parseLogLevel(val) orelse return ParseError.InvalidLogLevel;
            cli_log_level = true;
        } else if (std.mem.eql(u8, arg, "--log-format")) {
            const val = args.next() orelse return ParseError.MissingValue;
            config.log_format = parseLogFormat(val) orelse return ParseError.InvalidLogFormat;
            cli_log_format = true;
        } else if (std.mem.eql(u8, arg, "--enable-bpf")) {
            config.enable_bpf = true;
        } else if (std.mem.eql(u8, arg, "--watch")) {
            config.watch = true;
        } else {
            return ParseError.UnknownOption;
        }
    }

    if (!cli_port) {
        if (helpers.getenv("KEYWAY_PORT")) |val| {
            config.port = std.fmt.parseInt(u16, val, 10) catch return ParseError.InvalidPort;
        }
    }
    if (!cli_workers) {
        if (helpers.getenv("KEYWAY_WORKERS")) |val| {
            config.workers = std.fmt.parseInt(u16, val, 10) catch return ParseError.InvalidWorkers;
        }
    }
    if (!cli_log_level) {
        if (helpers.getenv("KEYWAY_LOG_LEVEL")) |val| {
            config.log_level = parseLogLevel(val) orelse return ParseError.InvalidLogLevel;
        }
    }
    if (!cli_log_format) {
        if (helpers.getenv("KEYWAY_LOG_FORMAT")) |val| {
            config.log_format = parseLogFormat(val) orelse return ParseError.InvalidLogFormat;
        }
    }

    return config;
}

fn parseLogFormat(val: []const u8) ?Config.LogFormat {
    return std.meta.stringToEnum(Config.LogFormat, val);
}

fn parseLogLevel(val: []const u8) ?std.log.Level {
    return std.meta.stringToEnum(std.log.Level, val);
}

/// Write formatted output to stderr, propagating write errors instead of
/// silently discarding them the way `std.debug.print` does. Used for CLI
/// diagnostics (help, version) that must not vanish. Bypasses the `Io`
/// interface, which is not yet set up during argument parsing.
pub fn printStderr(comptime fmt: []const u8, args: anytype) !void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    try w.print(fmt, args);
    try w.flush();
}

/// Print usage information to stderr.
pub fn printHelp() !void {
    const usage =
        \\Usage: keyway [OPTIONS]
        \\
        \\Keyway - Programmable HTTP engine (Zig + LuaJIT + io_uring)
        \\
        \\Options:
        \\  --host <addr>       Listen address (default: 0.0.0.0, env: KEYWAY_HOST)
        \\  --port <port>       Listen port (default: 8080, env: KEYWAY_PORT)
        \\  --workers <n>       Worker thread count, 0 = auto-detect (default: 0, env: KEYWAY_WORKERS)
        \\  --script <path>     Lua handler script (default: keyway.lua, env: KEYWAY_SCRIPT)
        \\  --tls-cert <path>   TLS certificate file (env: KEYWAY_TLS_CERT)
        \\  --tls-key <path>    TLS private key file (env: KEYWAY_TLS_KEY)
        \\  --log-level <level> Log level: err, warn, info, debug (default: info, env: KEYWAY_LOG_LEVEL)
        \\  --log-format <fmt>  Log encoding: logfmt, json (default: logfmt, env: KEYWAY_LOG_FORMAT)
        \\  --enable-bpf        Enable eBPF SO_REUSEPORT affinity (env: KEYWAY_ENABLE_BPF=1)
        \\  --watch             Watch script directory for .lua changes and hot-reload (env: KEYWAY_WATCH=1)
        \\  -h, --help          Show this help message
        \\  -v, --version       Show version information
        \\
    ;
    try printStderr("{s}", .{usage});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "default config values" {
    const c = Config{};
    try std.testing.expectEqualStrings("0.0.0.0", c.host);
    try std.testing.expectEqual(@as(u16, 8080), c.port);
    try std.testing.expectEqual(@as(u16, 0), c.workers);
    try std.testing.expectEqualStrings("keyway.lua", c.script);
    try std.testing.expectEqual(@as(?[]const u8, null), c.tls_cert_path);
    try std.testing.expectEqual(@as(?[]const u8, null), c.tls_key_path);
    try std.testing.expectEqual(std.log.Level.info, c.log_level);
    try std.testing.expect(!c.enable_bpf);
    try std.testing.expect(!c.show_help);
    try std.testing.expect(!c.show_version);
}

test "parseLogLevel valid values" {
    try std.testing.expectEqual(std.log.Level.err, parseLogLevel("err").?);
    try std.testing.expectEqual(std.log.Level.warn, parseLogLevel("warn").?);
    try std.testing.expectEqual(std.log.Level.info, parseLogLevel("info").?);
    try std.testing.expectEqual(std.log.Level.debug, parseLogLevel("debug").?);
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLogLevel("invalid"));
}

test "parseLogFormat valid values" {
    try std.testing.expectEqual(Config.LogFormat.logfmt, parseLogFormat("logfmt").?);
    try std.testing.expectEqual(Config.LogFormat.json, parseLogFormat("json").?);
    try std.testing.expectEqual(@as(?Config.LogFormat, null), parseLogFormat("invalid"));
}
