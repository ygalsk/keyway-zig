-- keyway.http_client — Outbound HTTP module
-- Parses URLs with net.url, blocks SSRF, fetches via cosocket TCP.
-- Supports GET (probe) and POST requests.

local socket  = require("keyway.socket")
-- Minimal URL parser (replaces net.url LuaRock)
local dns     = require("keyway.dns")

local ffi = require("ffi")
pcall(ffi.cdef, [[
    typedef long time_t;
    struct timespec { time_t tv_sec; long tv_nsec; };
    int clock_gettime(int clockid, struct timespec *tp);
]])
local CLOCK_MONOTONIC = 1

-- Reusable timespec for now_ms() (avoids per-call allocation)
local ts_buf = ffi.new("struct timespec")

local function now_ms()
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts_buf)
    return tonumber(ts_buf.tv_sec) * 1000 + tonumber(ts_buf.tv_nsec) / 1e6
end

local resolve_host = dns.resolve_host

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
-- parsed_table = { host, port, path_and_query, scheme }
local function parse_url(raw)
    if not raw or raw == "" then
        return nil, "URL is required"
    end
    local scheme, rest = raw:match("^(https?)://(.+)$")
    if not scheme then
        return nil, "Only HTTP and HTTPS URLs are supported"
    end
    -- Split authority from path
    local authority, path_query = rest:match("^([^/]+)(.*)$")
    if not authority or authority == "" then
        return nil, "Invalid URL: could not parse host"
    end
    -- Split host:port
    local host, port_str = authority:match("^(.+):(%d+)$")
    if not host then host = authority end
    if host == "" then
        return nil, "Invalid URL: could not parse host"
    end
    local default_port = (scheme == "https") and 443 or 80
    local path_and_query = (path_query and path_query ~= "") and path_query or "/"
    return {
        host           = host,
        port           = tonumber(port_str) or default_port,
        path_and_query = path_and_query,
        scheme         = scheme,
    }
end

-- Validate URL, resolve DNS, check SSRF. Returns (parsed, ip) or (nil, err).
local function resolve_and_validate(raw_url)
    local parsed, parse_err = parse_url(raw_url)
    if not parsed then
        return nil, nil, parse_err
    end

    if is_private(parsed.host) then
        return nil, nil, "Private IP ranges and localhost are not allowed"
    end

    local ip, dns_err = resolve_host(parsed.host)
    if not ip then
        return nil, nil, dns_err
    end

    if is_private(ip) then
        return nil, nil, "Hostname resolves to a private address"
    end

    return parsed, ip
end

-- Build Host header value
local function host_header(parsed)
    local default_port = (parsed.scheme == "https") and 443 or 80
    if parsed.port == default_port then
        return parsed.host
    end
    return parsed.host .. ":" .. parsed.port
end

-- Execute an HTTP request. Connects, optionally does TLS, sends raw request,
-- reads response (status, headers, body). Returns result table or nil + error.
local function execute_request(parsed, ip, raw_request)
    local tcp = socket.tcp()
    tcp:settimeout(10000)
    local t0 = now_ms()

    local ok, conn_err = tcp:connect(ip, parsed.port)
    if not ok then
        return nil, "Could not connect to host: " .. (conn_err or "connection failed")
    end

    -- TLS handshake for HTTPS
    if parsed.scheme == "https" then
        local tls_ok, tls_err = tcp:sslhandshake(nil, parsed.host)
        if not tls_ok then
            tcp:close()
            return nil, "TLS handshake failed: " .. (tls_err or "unknown error")
        end
    end

    -- Send request
    local sent, send_err = tcp:send(raw_request)
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

    -- Read response body via Content-Length
    local content_length
    for _, h in ipairs(headers) do
        if h[1]:lower() == "content-length" then
            content_length = tonumber(h[2])
            break
        end
    end
    local body = ""
    if content_length and content_length > 0 then
        body = tcp:receive(content_length) or ""
    end

    local elapsed = math.floor(now_ms() - t0)
    tcp:close()

    return {
        status      = tonumber(status_code),
        status_text = status_text,
        headers     = headers,
        body        = body,
        timing_ms   = elapsed,
    }
end

-- Probe a URL (GET). Returns result table or nil + error string.
function M.probe(raw_url)
    local parsed, ip, err = resolve_and_validate(raw_url)
    if not parsed then
        return nil, err
    end

    local request = string.format(
        "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Keyway/1.0\r\nConnection: close\r\n\r\n",
        parsed.path_and_query,
        host_header(parsed)
    )

    return execute_request(parsed, ip, request)
end

-- POST to a URL. Returns result table or nil + error string.
-- extra_headers is an optional table of {name, value} pairs.
function M.post(raw_url, body, extra_headers)
    local parsed, ip, err = resolve_and_validate(raw_url)
    if not parsed then
        return nil, err
    end

    body = body or ""

    local lines = {
        string.format("POST %s HTTP/1.1", parsed.path_and_query),
        "Host: " .. host_header(parsed),
        "User-Agent: Keyway/1.0",
        "Connection: close",
        "Content-Length: " .. #body,
    }
    if extra_headers then
        for _, h in ipairs(extra_headers) do
            lines[#lines + 1] = h[1] .. ": " .. h[2]
        end
    end
    lines[#lines + 1] = ""  -- blank line ends headers

    local request = table.concat(lines, "\r\n") .. "\r\n" .. body

    return execute_request(parsed, ip, request)
end

return M
