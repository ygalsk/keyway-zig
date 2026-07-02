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

return M
