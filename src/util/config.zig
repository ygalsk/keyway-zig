/// Centralized tunable constants for the Keyway server.
/// All buffer sizes, limits, and capacity values live here.

/// Read buffer for inbound HTTP data (headers + body).
pub const READ_BUFFER_SIZE = 65536;

/// Ciphertext receive buffer for inbound TLS connections.
pub const CIPHERTEXT_BUFFER_SIZE = 8192;

/// Free the per-request arena between requests if its retained capacity exceeds
/// this size; otherwise keep the capacity for reuse. Prevents unbounded growth on
/// keep-alive connections that occasionally serve a large response.
pub const ARENA_RETAIN_LIMIT = 1024 * 1024;

/// Maximum route parameters per request (e.g., /users/{id}/posts/{post_id}).
pub const MAX_ROUTE_PARAMS = 4;

/// Maximum query string parameters per request.
pub const MAX_QUERY_PARAMS = 16;

/// Encrypt buffer for draining wbio ciphertext (handshake, small sends).
pub const TLS_ENCRYPT_BUF_SIZE = 20 * 1024;

/// TCP listen backlog depth.
pub const DEFAULT_BACKLOG: u31 = 128;

/// Maximum HTTP request headers (picohttpparser limit).
pub const MAX_HEADERS: usize = 100;

/// HTTP request timeout in milliseconds. Requests exceeding this are terminated.
pub const REQUEST_TIMEOUT_MS: u64 = 30_000;

/// Graceful shutdown drain deadline in milliseconds. In-flight requests get this long to complete.
pub const DRAIN_DEADLINE_MS: u64 = 30_000;

/// Maximum HTTP request body size in bytes (1 MB). Bodies exceeding this get 413.
pub const MAX_BODY_SIZE: u64 = 1_048_576;

/// Maximum connections per worker before rejecting. Prevents OOM under connection flood.
pub const MAX_CONNECTIONS_PER_WORKER: u32 = 10_000;

/// Timeout for receiving complete HTTP headers (ms). Protects against slowloris attacks.
pub const HEADER_TIMEOUT_MS: u64 = 10_000;

/// Maximum reassembled WebSocket message size (fragmented messages). 1 MB.
pub const WS_MAX_MESSAGE_SIZE: usize = 1_048_576;

/// Read buffer size for static file pread+send loop.
pub const STATIC_READ_SIZE: usize = 65536;

/// Maximum static file size (100 MB). Files larger than this get 413.
pub const STATIC_MAX_SIZE: u64 = 100 * 1024 * 1024;

/// Deadline for the whole reverse-proxy upstream exchange (connect+send+recv
/// combined, not per-op). Requests exceeding this get 504.
pub const PROXY_UPSTREAM_TIMEOUT_MS: u64 = 30_000;

comptime {
    // Buffer sizes must be at least 4096 for reasonable HTTP operation
    if (READ_BUFFER_SIZE < 4096)
        @compileError("READ_BUFFER_SIZE must be >= 4096");
    // Param limits sanity check
    if (MAX_ROUTE_PARAMS > 8)
        @compileError("MAX_ROUTE_PARAMS must be <= 8");
    if (MAX_QUERY_PARAMS > 32)
        @compileError("MAX_QUERY_PARAMS must be <= 32");
    // Production safety constants
    if (REQUEST_TIMEOUT_MS == 0)
        @compileError("REQUEST_TIMEOUT_MS must be > 0");
    if (DRAIN_DEADLINE_MS == 0)
        @compileError("DRAIN_DEADLINE_MS must be > 0");
    if (MAX_BODY_SIZE < 1024)
        @compileError("MAX_BODY_SIZE must be >= 1024");
    if (MAX_CONNECTIONS_PER_WORKER == 0)
        @compileError("MAX_CONNECTIONS_PER_WORKER must be > 0");
    if (HEADER_TIMEOUT_MS == 0)
        @compileError("HEADER_TIMEOUT_MS must be > 0");
    if (STATIC_READ_SIZE < 4096)
        @compileError("STATIC_READ_SIZE must be >= 4096");
    if (PROXY_UPSTREAM_TIMEOUT_MS == 0)
        @compileError("PROXY_UPSTREAM_TIMEOUT_MS must be > 0");
}
