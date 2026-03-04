-- keyway.http_client — Outbound HTTP probe module
-- Parses URLs with net.url, blocks SSRF, fetches via cosocket TCP,
-- returns status code, response headers, and round-trip timing.

local socket  = require("keyway.socket")
local url_lib = require("net.url")

local ffi = require("ffi")
pcall(ffi.cdef, [[
    typedef long time_t;
    struct timespec { time_t tv_sec; long tv_nsec; };
    int clock_gettime(int clockid, struct timespec *tp);

    struct addrinfo_hint {
        int ai_flags;
        int ai_family;
        int ai_socktype;
        int ai_protocol;
        unsigned int ai_addrlen;
        void *ai_addr;
        char *ai_canonname;
        void *ai_next;
    };
    struct sockaddr_in {
        unsigned short sin_family;
        unsigned short sin_port;
        unsigned char sin_addr[4];
        char sin_zero[8];
    };
    int getaddrinfo(const char *node, const char *service,
        const struct addrinfo_hint *hints, struct addrinfo_hint **res);
    void freeaddrinfo(struct addrinfo_hint *res);
    const char* inet_ntop(int af, const void* src, char* dst, unsigned int size);
]])
local CLOCK_MONOTONIC = 1
local AF_INET = 2
local SOCK_STREAM = 1

-- Reusable timespec for now_ms() (avoids per-call allocation)
local ts_buf = ffi.new("struct timespec")

local function now_ms()
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts_buf)
    return tonumber(ts_buf.tv_sec) * 1000 + tonumber(ts_buf.tv_nsec) / 1e6
end

-- Resolve hostname to IPv4 address string. Returns ip or nil + error.
local function resolve_host(hostname)
    local res = ffi.new("struct addrinfo_hint*[1]")
    local hints = ffi.new("struct addrinfo_hint")
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    local err = ffi.C.getaddrinfo(hostname, nil, hints, res)
    if err ~= 0 then
        return nil, "DNS resolution failed for: " .. hostname
    end
    local sa = ffi.cast("struct sockaddr_in*", res[0].ai_addr)
    local buf = ffi.new("char[16]")
    ffi.C.inet_ntop(AF_INET, sa.sin_addr, buf, 16)
    local ip = ffi.string(buf)
    ffi.C.freeaddrinfo(res[0])
    return ip
end

local M = {}

-- Returns true if the host is a private/loopback address or hostname.
local function is_private(host)
    if host:lower() == "localhost" then return true end
    local a, b = host:match("^(%d+)%.(%d+)%.")
    if a then
        a, b = tonumber(a), tonumber(b)
        if a == 127 then return true end
        if a == 10  then return true end
        if a == 192 and b == 168 then return true end
        if a == 169 and b == 254 then return true end
    end
    return false
end

-- Parse and validate a URL string.
-- Returns (parsed_table) or (nil, error_string).
-- parsed_table = { host, port, path_and_query }
local function parse_url(raw)
    if not raw or raw == "" then
        return nil, "URL is required"
    end
    local u = url_lib.parse(raw)
    if not u or not u.host or u.host == "" then
        return nil, "Invalid URL: could not parse host"
    end
    if u.scheme ~= "http" then
        return nil, "Only HTTP URLs are supported (not HTTPS or other schemes)"
    end
    -- Use parsed path from url library, fall back to "/"
    local path_and_query = tostring(u.path) or "/"
    if path_and_query == "" then path_and_query = "/" end
    if u.query and tostring(u.query) ~= "" then
        path_and_query = path_and_query .. "?" .. tostring(u.query)
    end
    return {
        host           = u.host,
        port           = tonumber(u.port) or 80,
        path_and_query = path_and_query,
    }
end

-- Probe a URL. Returns result table or nil + error string.
-- result = {
--   status      = 200,
--   status_text = "OK",
--   headers     = { {"Content-Type", "text/html"}, ... },
--   timing_ms   = 123,
-- }
function M.probe(raw_url)
    -- Parse and validate
    local parsed, parse_err = parse_url(raw_url)
    if not parsed then
        return nil, parse_err
    end

    -- SSRF protection: check hostname first
    if is_private(parsed.host) then
        return nil, "Private IP ranges and localhost are not allowed"
    end

    -- Resolve hostname to IP (cosocket connect requires an IP literal)
    local ip, dns_err = resolve_host(parsed.host)
    if not ip then
        return nil, dns_err
    end

    -- SSRF protection: also check the resolved IP (prevents DNS rebinding to a degree)
    if is_private(ip) then
        return nil, "Hostname resolves to a private address"
    end

    -- Build request
    local host_header = parsed.port == 80
        and parsed.host
        or (parsed.host .. ":" .. parsed.port)
    local request = string.format(
        "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Keyway/1.0\r\nConnection: close\r\n\r\n",
        parsed.path_and_query,
        host_header
    )

    -- Connect (use resolved IP, not hostname)
    local tcp = socket.tcp()
    tcp:settimeout(10000)
    local t0 = now_ms()
    local ok, conn_err = tcp:connect(ip, parsed.port)
    if not ok then
        return nil, "Could not connect to host: " .. (conn_err or "connection failed")
    end

    -- Send request
    local sent, send_err = tcp:send(request)
    if not sent then
        tcp:close()
        return nil, "Failed to send request: " .. (send_err or "send failed")
    end

    -- Read status line
    local status_line, recv_err = tcp:receive("*l")
    if not status_line then
        tcp:close()
        return nil, "No response from server: " .. (recv_err or "receive failed")
    end
    local status_code, status_text = status_line:match("^HTTP/%S+ (%d+)%s*(.-)%s*$")
    if not status_code then
        tcp:close()
        return nil, "Unexpected response format (not HTTP)"
    end

    -- Read headers until blank line
    local headers = {}
    while true do
        local line, line_err = tcp:receive("*l")
        if not line or line == "" then break end
        if line_err then break end
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name then
            headers[#headers + 1] = { name, value }
        end
    end

    local elapsed = math.floor(now_ms() - t0)
    tcp:close()

    return {
        status      = tonumber(status_code),
        status_text = status_text,
        headers     = headers,
        timing_ms   = elapsed,
    }
end

return M
