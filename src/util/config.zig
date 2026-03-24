/// Centralized tunable constants for the Keyway server.
/// All buffer sizes, limits, and capacity values live here.
/// Constraints are co-located with each constant as comptime blocks.

/// Read buffer for inbound HTTP data (headers + body).
pub const READ_BUFFER_SIZE = 65536;
comptime {
    if (READ_BUFFER_SIZE < 4096) @compileError("READ_BUFFER_SIZE must be >= 4096");
}

/// Write buffer for pre-serialized error responses.
pub const WRITE_BUFFER_SIZE = 8192;
comptime {
    if (WRITE_BUFFER_SIZE < 4096) @compileError("WRITE_BUFFER_SIZE must be >= 4096");
}

/// Ciphertext receive buffer for inbound TLS connections.
pub const CIPHERTEXT_BUFFER_SIZE = 8192;

/// Free arena if response exceeds this size (prevents unbounded growth on keep-alive).
pub const LARGE_RESPONSE_THRESHOLD = 1024 * 1024;

/// Maximum route parameters per request (e.g., /users/{id}/posts/{post_id}).
pub const MAX_ROUTE_PARAMS = 4;
comptime {
    if (MAX_ROUTE_PARAMS > 8) @compileError("MAX_ROUTE_PARAMS must be <= 8");
}

/// Maximum query string parameters per request.
pub const MAX_QUERY_PARAMS = 16;
comptime {
    if (MAX_QUERY_PARAMS > 32) @compileError("MAX_QUERY_PARAMS must be <= 32");
}

/// Submission/completion ring depth for batched cosocket I/O.
/// Must be a power of 2 (ring buffer wrapping requires it).
pub const RING_DEPTH = 16;
comptime {
    if (RING_DEPTH == 0 or (RING_DEPTH & (RING_DEPTH - 1)) != 0)
        @compileError("RING_DEPTH must be a power of 2");
}

/// Encrypt buffer for draining wbio ciphertext (handshake, small sends).
pub const TLS_ENCRYPT_BUF_SIZE = 20 * 1024;

/// Max TLS record plaintext (RFC 8449).
pub const TLS_RECORD_MAX_SIZE = 16384;

/// Max workers for SSE broadcast bus.
pub const SSE_MAX_WORKERS = 128;

/// TCP listen backlog depth.
pub const DEFAULT_BACKLOG: u31 = 128;

/// Maximum HTTP request headers (picohttpparser limit).
pub const MAX_HEADERS: usize = 100;

/// HTTP request timeout in milliseconds. Requests exceeding this are terminated.
pub const REQUEST_TIMEOUT_MS: u64 = 30_000;
comptime {
    if (REQUEST_TIMEOUT_MS == 0) @compileError("REQUEST_TIMEOUT_MS must be > 0");
}

/// Graceful shutdown drain deadline in milliseconds. In-flight requests get this long to complete.
pub const DRAIN_DEADLINE_MS: u64 = 30_000;
comptime {
    if (DRAIN_DEADLINE_MS == 0) @compileError("DRAIN_DEADLINE_MS must be > 0");
}

/// Maximum HTTP request body size in bytes (1 MB). Bodies exceeding this get 413.
pub const MAX_BODY_SIZE: u64 = 1_048_576;
comptime {
    if (MAX_BODY_SIZE < 1024) @compileError("MAX_BODY_SIZE must be >= 1024");
}

/// Maximum connections per worker before rejecting. Prevents OOM under connection flood.
pub const MAX_CONNECTIONS_PER_WORKER: u32 = 10_000;
comptime {
    if (MAX_CONNECTIONS_PER_WORKER == 0) @compileError("MAX_CONNECTIONS_PER_WORKER must be > 0");
}

/// Timeout for receiving complete HTTP headers (ms). Protects against slowloris attacks.
pub const HEADER_TIMEOUT_MS: u64 = 10_000;
comptime {
    if (HEADER_TIMEOUT_MS == 0) @compileError("HEADER_TIMEOUT_MS must be > 0");
}

/// Maximum reassembled WebSocket message size (fragmented messages). 1 MB.
pub const WS_MAX_MESSAGE_SIZE: usize = 1_048_576;

/// Read buffer size for static file pread+send loop.
pub const STATIC_READ_SIZE: usize = 65536;
comptime {
    if (STATIC_READ_SIZE < 4096) @compileError("STATIC_READ_SIZE must be >= 4096");
}

/// Maximum static file size (100 MB). Files larger than this get 413.
pub const STATIC_MAX_SIZE: u64 = 100 * 1024 * 1024;
