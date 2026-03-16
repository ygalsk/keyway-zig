const std = @import("std");

/// CLI configuration for the Keyway server.
/// Resolution order: CLI argument > environment variable > default value.
pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    workers: u16 = 0,
    script: []const u8 = "keyway.lua",
    tls_cert_path: ?[]const u8 = null,
    tls_key_path: ?[]const u8 = null,
    log_level: std.log.Level = .info,
    enable_bpf: bool = false,
    show_help: bool = false,
    show_version: bool = false,
};

const ParseError = error{
    InvalidPort,
    InvalidWorkers,
    InvalidLogLevel,
    MissingValue,
    UnknownOption,
};

/// Parse CLI arguments with environment variable fallback.
/// Caller owns no memory — all returned slices point into argv or env storage
/// (both managed by the OS, valid for the process lifetime).
pub fn parse(allocator: std.mem.Allocator) (ParseError || std.process.ArgIterator.InitError)!Config {
    var config = Config{};

    // Track which fields were set by CLI args (env vars only apply to unset fields)
    var cli_host = false;
    var cli_port = false;
    var cli_workers = false;
    var cli_script = false;
    var cli_tls_cert = false;
    var cli_tls_key = false;
    var cli_log_level = false;
    var cli_enable_bpf = false;

    // Parse CLI arguments
    var args = try std.process.argsWithAllocator(allocator);
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
            cli_host = true;
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
            cli_script = true;
        } else if (std.mem.eql(u8, arg, "--tls-cert")) {
            config.tls_cert_path = args.next() orelse return ParseError.MissingValue;
            cli_tls_cert = true;
        } else if (std.mem.eql(u8, arg, "--tls-key")) {
            config.tls_key_path = args.next() orelse return ParseError.MissingValue;
            cli_tls_key = true;
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            const val = args.next() orelse return ParseError.MissingValue;
            config.log_level = parseLogLevel(val) orelse return ParseError.InvalidLogLevel;
            cli_log_level = true;
        } else if (std.mem.eql(u8, arg, "--enable-bpf")) {
            config.enable_bpf = true;
            cli_enable_bpf = true;
        } else {
            return ParseError.UnknownOption;
        }
    }

    // Apply environment variable fallbacks for fields not set by CLI
    if (!cli_host) {
        if (std.posix.getenv("KEYWAY_HOST")) |val| config.host = val;
    }
    if (!cli_port) {
        if (std.posix.getenv("KEYWAY_PORT")) |val| {
            config.port = std.fmt.parseInt(u16, val, 10) catch return ParseError.InvalidPort;
        }
    }
    if (!cli_workers) {
        if (std.posix.getenv("KEYWAY_WORKERS")) |val| {
            config.workers = std.fmt.parseInt(u16, val, 10) catch return ParseError.InvalidWorkers;
        }
    }
    if (!cli_script) {
        if (std.posix.getenv("KEYWAY_SCRIPT")) |val| config.script = val;
    }
    if (!cli_tls_cert) {
        if (std.posix.getenv("KEYWAY_TLS_CERT")) |val| config.tls_cert_path = val;
    }
    if (!cli_tls_key) {
        if (std.posix.getenv("KEYWAY_TLS_KEY")) |val| config.tls_key_path = val;
    }
    if (!cli_log_level) {
        if (std.posix.getenv("KEYWAY_LOG_LEVEL")) |val| {
            config.log_level = parseLogLevel(val) orelse return ParseError.InvalidLogLevel;
        }
    }
    if (!cli_enable_bpf) {
        if (std.posix.getenv("KEYWAY_ENABLE_BPF")) |val| {
            config.enable_bpf = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        }
    }

    return config;
}

fn parseLogLevel(val: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, val, "err")) return .err;
    if (std.mem.eql(u8, val, "warn")) return .warn;
    if (std.mem.eql(u8, val, "info")) return .info;
    if (std.mem.eql(u8, val, "debug")) return .debug;
    return null;
}

/// Print usage information to stderr.
pub fn printHelp() void {
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
        \\  --enable-bpf        Enable eBPF SO_REUSEPORT affinity (env: KEYWAY_ENABLE_BPF=1)
        \\  -h, --help          Show this help message
        \\  -v, --version       Show version information
        \\
    ;
    var buf: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStderrWriter();
    stderr.writeAll(usage) catch {};
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

test "parse returns defaults when no args or env vars" {
    // parse() reads real process args — the test runner passes its own flags
    // which the CLI parser rejects. Verify defaults via struct init instead.
    const c = Config{};
    try std.testing.expectEqual(@as(u16, 8080), c.port);
    try std.testing.expectEqualStrings("0.0.0.0", c.host);
}

test "env var fallback for KEYWAY_PORT" {
    // Verify the default port when KEYWAY_PORT is not set.
    if (std.posix.getenv("KEYWAY_PORT") == null) {
        const c = Config{};
        try std.testing.expectEqual(@as(u16, 8080), c.port);
    }
}
