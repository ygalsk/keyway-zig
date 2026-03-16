-- probe.lua — HTTP probe logic using keyway.http_client
local response = require("keyway.response")
local cjson = require("cjson")
local http = require("keyway.http_client")

local M = {}

-- Header classification
local SECURITY_HEADERS = {
    ["strict-transport-security"] = true, ["content-security-policy"] = true,
    ["x-content-type-options"] = true, ["x-frame-options"] = true,
    ["x-xss-protection"] = true, ["referrer-policy"] = true,
    ["permissions-policy"] = true,
}
local CACHE_HEADERS = {
    ["cache-control"] = true, ["etag"] = true, ["last-modified"] = true,
    ["expires"] = true, ["age"] = true, ["vary"] = true,
}

function M.classify_header(name)
    local lower = name:lower()
    if SECURITY_HEADERS[lower] then return "security" end
    if CACHE_HEADERS[lower] then return "cache" end
    return "general"
end

-- Execute probe and return structured result (or nil, error_string)
function M.execute(url)
    local result, err = http.probe(url)
    if not result then
        return nil, err
    end
    -- Add header classification and reshape to dashboard format
    local classified_headers = {}
    for _, h in ipairs(result.headers) do
        classified_headers[#classified_headers + 1] = {
            name = h[1], value = h[2],
            category = M.classify_header(h[1]),
        }
    end
    local host, port = host_port:match("^(.+):(%d+)$")
    if not host then
        host = host_port
        port = (scheme == "https") and 443 or 80
    else
        port = tonumber(port)
    end
    if host:lower() == "localhost" or host:match("^127%.") or host:match("^10%.") or host:match("^192%.168%.") then
        return nil, "Private/loopback addresses not allowed"
    end
    local ip, dns_err = dns.resolve_host(host)
    if not ip then
        return nil, dns_err or "DNS resolution failed"
    end
    local t0 = response.now_us()
    local tcp = socket.tcp()
    tcp:settimeout(10000)
    local conn_ok, conn_err = tcp:connect(ip, port)
    if not conn_ok then
        return nil, "connect failed: " .. (conn_err or "unknown")
    end
    if scheme == "https" then
        local tls_ok, tls_err = tcp:sslhandshake(nil, host)
        if not tls_ok then
            tcp:close()
            return nil, "TLS failed: " .. tostring(tls_err or "unknown")
        end
    end
    local default_port = (scheme == "https") and 443 or 80
    local host_hdr = (port == default_port) and host or (host .. ":" .. port)
    local request = string.format(
        "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Keyway/1.0\r\nConnection: close\r\n\r\n",
        path_query, host_hdr
    )
    local sent, send_err = tcp:send(request)
    if not sent then
        tcp:close()
        return nil, "send failed: " .. (send_err or "unknown")
    end
    local status_line, recv_err = tcp:receive("*l")
    if not status_line then
        tcp:close()
        return nil, "no response: " .. (recv_err or "unknown")
    end
    local status_code = status_line:match("^HTTP/%S+ (%d+)")
    local resp_headers = {}
    local content_length
    while true do
        local line = tcp:receive("*l")
        if not line or line == "" then break end
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name then
            resp_headers[#resp_headers + 1] = {
                name = name, value = value,
                category = M.classify_header(name),
            }
            if name:lower() == "content-length" then
                content_length = tonumber(value)
            end
        end
    end
    local resp_body = ""
    if content_length and content_length > 0 then
        local read_len = math.min(content_length, 4096)
        resp_body = tcp:receive(read_len) or ""
    end
    local timing_us = math.floor(response.now_us() - t0)
    local timing_ms = math.floor(timing_us / 1000)
    tcp:close()
    return {
        url          = url,
        status       = result.status,
        headers      = classified_headers,
        timing_ms    = result.timing_ms,
        timing_us    = timing_us,
        body_preview = (result.body or ""):sub(1, 500),
    }
end

function M.probe(ctx)
    local ok, body = pcall(cjson.decode, ctx.body)
    if not ok or not body.url then
        response.json_response(ctx, 400, { error = "JSON body with 'url' field required" })
        return
    end
    local result, err = M.execute(body.url)
    if not result then
        response.json_response(ctx, 200, { error = err })
        return
    end
    response.json_response(ctx, 200, {
        status       = result.status,
        headers      = result.headers,
        timing_ms    = result.timing_ms,
        body_preview = result.body_preview,
    })
end

return M
