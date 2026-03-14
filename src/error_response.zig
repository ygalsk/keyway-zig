//! Unified error response model.
//!
//! Every HTTP error response (4xx, 5xx) flows through this module.
//! ErrorCategory maps error classes to default status codes, plain-text bodies,
//! and severity-based log levels. Pre-serialized responses avoid runtime formatting.
//!
//! No internal details (Zig error names, file paths, stack traces) leak to clients.

const std = @import("std");
const Connection = @import("handler.zig").Connection;

const log = std.log.scoped(.error_response);

/// Error classification. Each category maps to a default HTTP status, body, and log severity.
pub const ErrorCategory = enum {
    client_error,
    server_error,
    timeout,
    upstream_error,

    /// Default HTTP status code for this error category.
    pub fn defaultStatus(self: ErrorCategory) u16 {
        return switch (self) {
            .client_error => 400,
            .server_error => 500,
            .timeout => 504,
            .upstream_error => 502,
        };
    }

    /// Default plain-text body for this error category.
    pub fn defaultBody(self: ErrorCategory) []const u8 {
        return switch (self) {
            .client_error => "Bad Request",
            .server_error => "Internal Server Error",
            .timeout => "Gateway Timeout",
            .upstream_error => "Bad Gateway",
        };
    }

    /// Log severity: warn for client-facing/timeout, err for server/upstream failures.
    pub fn logLevel(self: ErrorCategory) std.log.Level {
        return switch (self) {
            .client_error, .timeout => .warn,
            .server_error, .upstream_error => .err,
        };
    }
};

/// Comptime-generate a full HTTP error response string.
/// Format: "HTTP/1.1 {status} {reason}\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}"
fn comptimeErrorResponse(comptime status: u16, comptime reason: []const u8, comptime body: []const u8) []const u8 {
    const status_str = std.fmt.comptimePrint("{d}", .{status});
    const len_str = std.fmt.comptimePrint("{d}", .{body.len});
    return "HTTP/1.1 " ++ status_str ++ " " ++ reason ++ "\r\n" ++
        "Content-Length: " ++ len_str ++ "\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++ body;
}

/// Pre-serialized error responses for each category's default status.
const response_400 = comptimeErrorResponse(400, "Bad Request", "Bad Request");
const response_500 = comptimeErrorResponse(500, "Internal Server Error", "Internal Server Error");
const response_502 = comptimeErrorResponse(502, "Bad Gateway", "Bad Gateway");
const response_504 = comptimeErrorResponse(504, "Gateway Timeout", "Gateway Timeout");

/// Pre-serialized 413 response for oversized request bodies.
const response_413 = comptimeErrorResponse(413, "Content Too Large", "Content Too Large");

/// Pre-serialized 404 response for route misses.
const response_404 = comptimeErrorResponse(404, "Not Found", "Not Found");

/// Get pre-serialized response bytes for a category.
fn categoryResponse(category: ErrorCategory) []const u8 {
    return switch (category) {
        .client_error => response_400,
        .server_error => response_500,
        .timeout => response_504,
        .upstream_error => response_502,
    };
}

/// Get pre-serialized response bytes for a specific status code.
/// Returns null if no pre-serialized response exists for that status.
fn statusResponse(status: u16) ?[]const u8 {
    return switch (status) {
        400 => response_400,
        404 => response_404,
        413 => response_413,
        500 => response_500,
        502 => response_502,
        504 => response_504,
        else => null,
    };
}

/// Log an error with structured fields and severity based on category.
pub fn logError(
    category: ErrorCategory,
    status: u16,
    method: []const u8,
    path: []const u8,
    internal_msg: []const u8,
) void {
    switch (category.logLevel()) {
        .warn => log.warn("method={s} path={s} status={d} category={s} msg={s}", .{
            method, path, status, @tagName(category), internal_msg,
        }),
        .err => log.err("method={s} path={s} status={d} category={s} msg={s}", .{
            method, path, status, @tagName(category), internal_msg,
        }),
        else => log.info("method={s} path={s} status={d} category={s} msg={s}", .{
            method, path, status, @tagName(category), internal_msg,
        }),
    }
}

/// Send an error response for a category. Logs the error and sends the pre-serialized response.
pub fn sendError(conn: *Connection, category: ErrorCategory, internal_msg: []const u8) void {
    logError(category, category.defaultStatus(), conn.request_method, conn.request_path, internal_msg);
    conn.sendRawResponse(categoryResponse(category));
}

/// Send an error response for a specific status code.
/// Uses pre-serialized response for known statuses, falls back to category default.
pub fn sendErrorStatus(conn: *Connection, status: u16, internal_msg: []const u8) void {
    const category: ErrorCategory = if (status >= 500) .server_error else .client_error;
    logError(category, status, conn.request_method, conn.request_path, internal_msg);
    if (statusResponse(status)) |resp| {
        conn.sendRawResponse(resp);
    } else {
        conn.sendRawResponse(categoryResponse(category));
    }
}

// =============================================================================
// Tests
// =============================================================================

test "ErrorCategory.defaultStatus maps correctly" {
    try std.testing.expectEqual(@as(u16, 400), ErrorCategory.client_error.defaultStatus());
    try std.testing.expectEqual(@as(u16, 500), ErrorCategory.server_error.defaultStatus());
    try std.testing.expectEqual(@as(u16, 504), ErrorCategory.timeout.defaultStatus());
    try std.testing.expectEqual(@as(u16, 502), ErrorCategory.upstream_error.defaultStatus());
}

test "ErrorCategory.defaultBody maps correctly" {
    try std.testing.expectEqualStrings("Bad Request", ErrorCategory.client_error.defaultBody());
    try std.testing.expectEqualStrings("Internal Server Error", ErrorCategory.server_error.defaultBody());
    try std.testing.expectEqualStrings("Gateway Timeout", ErrorCategory.timeout.defaultBody());
    try std.testing.expectEqualStrings("Bad Gateway", ErrorCategory.upstream_error.defaultBody());
}

test "ErrorCategory.logLevel maps correctly" {
    try std.testing.expectEqual(std.log.Level.warn, ErrorCategory.client_error.logLevel());
    try std.testing.expectEqual(std.log.Level.warn, ErrorCategory.timeout.logLevel());
    try std.testing.expectEqual(std.log.Level.err, ErrorCategory.server_error.logLevel());
    try std.testing.expectEqual(std.log.Level.err, ErrorCategory.upstream_error.logLevel());
}

test "pre-serialized responses are valid HTTP" {
    const responses = [_][]const u8{ response_400, response_404, response_413, response_500, response_502, response_504 };
    for (responses) |resp| {
        try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1"));
        try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length:") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "Connection: close") != null);
        // Has double CRLF separating headers from body
        try std.testing.expect(std.mem.indexOf(u8, resp, "\r\n\r\n") != null);
    }
}

test "sendErrorStatus(404) produces Not Found response" {
    // Verify the 404 pre-serialized response directly
    const resp = statusResponse(404).?;
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length:") != null);
}

test "statusResponse(413) produces Content Too Large response" {
    const resp = statusResponse(413).?;
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 413 Content Too Large"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length:") != null);
    // Verify body
    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n").? + 4;
    const body = resp[body_start..];
    try std.testing.expectEqualStrings("Content Too Large", body);
}

test "pre-serialized 404 body is Not Found with correct Content-Length" {
    const resp = response_404;
    // Find body after \r\n\r\n
    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n").? + 4;
    const body = resp[body_start..];
    try std.testing.expectEqualStrings("Not Found", body);
    try std.testing.expectEqual(@as(usize, 9), body.len);
    // Verify Content-Length header matches
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 9") != null);
}
