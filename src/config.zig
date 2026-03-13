/// Centralized tunable constants for the Keyway server.
/// All buffer sizes, limits, and capacity values live here.

/// Read buffer for inbound HTTP data (headers + body).
pub const READ_BUFFER_SIZE = 65536;

/// Write buffer for pre-serialized error responses.
pub const WRITE_BUFFER_SIZE = 8192;

/// Ciphertext receive buffer for inbound TLS connections.
pub const CIPHERTEXT_BUFFER_SIZE = 8192;

/// Free arena if response exceeds this size (prevents unbounded growth on keep-alive).
pub const LARGE_RESPONSE_THRESHOLD = 1024 * 1024;

/// Maximum route parameters per request (e.g., /users/{id}/posts/{post_id}).
pub const MAX_ROUTE_PARAMS = 4;

/// Maximum query string parameters per request.
pub const MAX_QUERY_PARAMS = 4;

/// Submission/completion ring depth for batched cosocket I/O.
pub const RING_DEPTH = 16;

/// Encrypt buffer for draining wbio ciphertext (handshake, small sends).
pub const TLS_ENCRYPT_BUF_SIZE = 20 * 1024;

/// Max TLS record plaintext (RFC 8449).
pub const TLS_RECORD_MAX_SIZE = 16384;

/// Max workers for SSE broadcast bus.
pub const SSE_MAX_WORKERS = 128;
