-- routes/tls_test.lua — Raw cosocket TLS test endpoint
local dns    = require("keyway.dns")
local socket = require("keyway.socket")
local resp   = require("keyway.response")

return {
    ["/tls-test"] = {
        GET = function(ctx)
            local host = ctx.query.host or "www.google.com"
            local timings = {}

            -- 1. DNS resolve
            local t0 = resp.now_us()
            local ip, resolve_err = dns.resolve_host(host)
            timings[#timings + 1] = string.format("DNS resolve:   %d us", resp.now_us() - t0)
            if not ip then
                ctx.status = 502
                ctx.body = "DNS failed: " .. (resolve_err or "unknown")
                return
            end

            -- 2. TCP connect
            local tcp = socket.tcp()
            t0 = resp.now_us()
            local connect_ok, connect_err = tcp:connect(ip, 443)
            timings[#timings + 1] = string.format("TCP connect:   %d us", resp.now_us() - t0)
            if not connect_ok then
                ctx.status = 502
                ctx.body = "connect failed: " .. (connect_err or "unknown")
                return
            end

            -- 3. TLS handshake with SNI
            t0 = resp.now_us()
            local tls_ok, tls_err = tcp:sslhandshake(nil, host)
            timings[#timings + 1] = string.format("TLS handshake: %d us", resp.now_us() - t0)
            if not tls_ok then
                tcp:close()
                ctx.status = 502
                ctx.body = "tls handshake failed: " .. (tls_err or "unknown")
                return
            end

            -- 4. Send HTTP request
            t0 = resp.now_us()
            tcp:send("GET / HTTP/1.1\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
            timings[#timings + 1] = string.format("HTTP send:     %d us", resp.now_us() - t0)

            -- 5. Read status line + headers
            t0 = resp.now_us()
            local status_line = tcp:receive("*l")
            local headers = {}
            while true do
                local line = tcp:receive("*l")
                if not line or line == "" then break end
                headers[#headers + 1] = line
            end
            timings[#timings + 1] = string.format("HTTP recv:     %d us", resp.now_us() - t0)

            tcp:close()

            ctx.status = 200
            ctx.headers["Content-Type"] = "text/plain; charset=utf-8"
            ctx.body = "=== Outbound TLS Cosocket Test ===\n\n"
                .. "Target: https://" .. host .. "/\n"
                .. "Status: " .. (status_line or "(nil)") .. "\n\n"
                .. "Timings:\n" .. table.concat(timings, "\n") .. "\n\n"
                .. "Response Headers:\n" .. table.concat(headers, "\n") .. "\n"
        end,
    },
}
