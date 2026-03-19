-- response.lua — Universal response helpers (stdlib)
local json = require("keyway.json")

local M = {}

--- JSON API response
function M.json_response(ctx, status, data)
    ctx.status = status
    ctx.headers["Content-Type"] = "application/json; charset=utf-8"
    ctx.body = json.encode(data)
end

--- Case-insensitive header lookup
function M.get_header(ctx, name)
    local lower_name = name:lower()
    for _, h in ipairs(ctx.request_headers) do
        if h[1]:lower() == lower_name then return h[2] end
    end
    return nil
end

--- Trim leading/trailing whitespace
function M.trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

--- Split comma-separated string into table
function M.split_csv(str)
    if not str or str == "" then return {} end
    local t = {}
    for v in str:gmatch("[^,]+") do
        t[#t + 1] = M.trim(v)
    end
    return t
end

--- Monotonic clock in microseconds (cached timespec)
local ffi = require("ffi")
pcall(ffi.cdef, [[
    typedef long time_t;
    struct timespec { time_t tv_sec; long tv_nsec; };
    int clock_gettime(int clockid, struct timespec *tp);
]])
local _ts = ffi.new("struct timespec")
function M.now_us()
    ffi.C.clock_gettime(1, _ts) -- CLOCK_MONOTONIC
    return tonumber(_ts.tv_sec) * 1000000 + tonumber(_ts.tv_nsec) / 1000
end

--- Broadcast an SSE event with automatic JSON encoding
function M.broadcast_event(room, data)
    __keyway_sse_broadcast(room, "data: " .. json.encode(data) .. "\n")
end

--- Broadcast a typed SSE event with raw data (e.g. pre-rendered HTML)
function M.broadcast_html(room, event_type, html)
    __keyway_sse_broadcast(room, "event: " .. event_type .. "\ndata: " .. html .. "\n")
end

--- 404 JSON shorthand
function M.json_not_found(ctx)
    M.json_response(ctx, 404, { error = "not found" })
end

--- Parse JSON body, send 400 on failure. Returns (data, nil) or (nil, true).
function M.parse_json_body(ctx)
    local ok, data = pcall(json.decode, ctx.body)
    if not ok then
        M.json_response(ctx, 400, { error = "invalid JSON" })
        return nil, true
    end
    return data, nil
end

-- Upgrade type constants
M.UPGRADE_SSE = "sse"
M.UPGRADE_WS  = "websocket"

return M
