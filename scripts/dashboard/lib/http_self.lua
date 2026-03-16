-- http_self.lua — Helper for making HTTP requests to the local Keyway instance
local socket = require("keyway.socket")

local M = {}

--- Make an HTTP request to the local server.
-- @param host_hdr string  Host header value (e.g. "localhost:8080")
-- @param port number       Port to connect to
-- @param method string     HTTP method
-- @param path string       Request path
-- @return status_code, headers_table, body_string  or nil, error_string
function M.request(host_hdr, port, method, path)
    local tcp = socket.tcp()
    tcp:settimeout(5000)
    local ok, err = tcp:connect("127.0.0.1", port)
    if not ok then
        return nil, "connect failed: " .. (err or "unknown")
    end

    tcp:send(string.format("%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n",
        method, path, host_hdr))

    local status_line = tcp:receive("*l")
    if not status_line then
        tcp:close()
        return nil, "no response"
    end

    local status_code = tonumber(status_line:match("^HTTP/%S+ (%d+)")) or 0

    local headers = {}
    local content_length
    while true do
        local line = tcp:receive("*l")
        if not line or line == "" then break end
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name then
            headers[#headers + 1] = { name, value }
            if name:lower() == "content-length" then
                content_length = tonumber(value)
            end
        end
    end

    local body = ""
    if content_length and content_length > 0 then
        body = tcp:receive(content_length) or ""
    end
    tcp:close()

    return status_code, headers, body
end

return M
