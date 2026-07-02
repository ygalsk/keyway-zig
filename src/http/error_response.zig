//! Unified error response model.
//!
//! Every HTTP error response (4xx, 5xx) flows through this module.
//! ErrorCategory maps error classes to default status codes and severity-based
//! log levels. Pre-serialized responses avoid runtime formatting.
//!
//! No internal details (Zig error names, file paths, stack traces) leak to clients.

const std = @import("std");
const log = @import("../observability/log.zig");
const Connection = @import("../core/handler.zig").Connection;

/// Error classification. Each category maps to a default HTTP status, body, and log severity.
pub const ErrorCategory = enum {
    client_error,
    server_error,
    timeout,

    /// Default HTTP status code for this error category.
    pub fn defaultStatus(self: ErrorCategory) u16 {
        return switch (self) {
            .client_error => 400,
            .server_error => 500,
            .timeout => 504,
        };
    }

    /// Log severity: warn for client-facing/timeout, err for server failures.
    pub fn logLevel(self: ErrorCategory) std.log.Level {
        return switch (self) {
            .client_error, .timeout => .warn,
            .server_error => .err,
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

/// Pre-serialized error responses. Reason phrase (and body) come from
/// std.http.Status, so the numeric code and phrase can't desync — registering
/// a status is one line and there's no hand-typed table (a missing row is
/// exactly what caused #161).
fn cannedResponse(comptime s: std.http.Status) []const u8 {
    return comptimeErrorResponse(@intFromEnum(s), s.phrase().?, s.phrase().?);
}

const response_400 = cannedResponse(.bad_request);
const response_403 = cannedResponse(.forbidden);
const response_404 = cannedResponse(.not_found);
const response_500 = cannedResponse(.internal_server_error);
const response_502 = cannedResponse(.bad_gateway);
const response_504 = cannedResponse(.gateway_timeout);

// 413: std's phrase is the older "Payload Too Large"; keep the RFC 9110 name
// "Content Too Large" deliberately, so this one stays explicit.
const response_413 = comptimeErrorResponse(413, "Content Too Large", "Content Too Large");

/// Get pre-serialized response bytes for a specific status code.
/// Returns null if no pre-serialized response exists for that status.
/// Every ErrorCategory.defaultStatus() is present here, so category dispatch
/// routes through this too.
fn statusResponse(status: u16) ?[]const u8 {
    return switch (status) {
        400 => response_400,
        403 => response_403,
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
    const logger = switch (category.logLevel()) {
        .warn => log.warn(),
        .err => log.err(),
        else => log.info(),
    };
    logger
        .stringSafe("scope", "error_response")
        .stringSafe("method", method)
        .string("path", path)
        .int("status", status)
        .stringSafe("category", @tagName(category))
        .string("msg", internal_msg)
        .log();
}

/// Send an error response for a category. Logs the error and sends the pre-serialized response.
pub fn sendError(conn: *Connection, category: ErrorCategory, internal_msg: []const u8) void {
    logError(category, category.defaultStatus(), conn.http_state.request_method, conn.http_state.request_path, internal_msg);
    conn.sendRawResponse(statusResponse(category.defaultStatus()).?);
}

/// Send an error response for a specific status code.
/// Uses pre-serialized response for known statuses, falls back to category default.
pub fn sendErrorStatus(conn: *Connection, status: u16, internal_msg: []const u8) void {
    const category: ErrorCategory = if (status >= 500) .server_error else .client_error;
    logError(category, status, conn.http_state.request_method, conn.http_state.request_path, internal_msg);
    if (statusResponse(status)) |resp| {
        conn.sendRawResponse(resp);
    } else {
        conn.sendRawResponse(statusResponse(category.defaultStatus()).?);
    }
}

/// Send 405 Method Not Allowed with an Allow header (RFC 7231 §6.5.5).
/// `allow` is the header value, e.g. "GET, HEAD".
pub fn send405(conn: *Connection, allow: []const u8) void {
    logError(.client_error, 405, conn.http_state.request_method, conn.http_state.request_path, "method not allowed");
    const body = "Method Not Allowed";
    const resp = std.fmt.allocPrint(conn.arena.allocator(), "HTTP/1.1 405 Method Not Allowed\r\nAllow: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ allow, body.len, body }) catch {
        conn.sendRawResponse(statusResponse(400).?);
        return;
    };
    conn.sendRawResponse(resp);
}

// =============================================================================
// Tests
// =============================================================================

test "ErrorCategory.defaultStatus maps correctly" {
    try std.testing.expectEqual(@as(u16, 400), ErrorCategory.client_error.defaultStatus());
    try std.testing.expectEqual(@as(u16, 500), ErrorCategory.server_error.defaultStatus());
    try std.testing.expectEqual(@as(u16, 504), ErrorCategory.timeout.defaultStatus());
}

test "ErrorCategory.logLevel maps correctly" {
    try std.testing.expectEqual(std.log.Level.warn, ErrorCategory.client_error.logLevel());
    try std.testing.expectEqual(std.log.Level.warn, ErrorCategory.timeout.logLevel());
    try std.testing.expectEqual(std.log.Level.err, ErrorCategory.server_error.logLevel());
}

test "pre-serialized responses are valid HTTP" {
    const responses = [_][]const u8{ response_400, response_403, response_404, response_413, response_500, response_502, response_504 };
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
