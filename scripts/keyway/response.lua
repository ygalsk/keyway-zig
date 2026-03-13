-- response.lua — Shared response helpers for route modules
local template = require("keyway.template")
local cjson    = require("cjson")

local M = {}

--- Render a full page through the layout template
function M.render_page(page_name, vars)
    vars = vars or {}
    vars.worker_id = keyway.worker_id
    vars.page = page_name
    vars.content = template.render(page_name, vars)
    return template.render("layout", vars)
end

--- Set ctx for an error page response
function M.error_response(ctx, page, status, msg)
    ctx.status = status
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = M.render_page(page, { error_msg = msg })
end

--- Set ctx for an HTML page response (200 OK)
function M.html_response(ctx, page, vars)
    ctx.status = 200
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = M.render_page(page, vars)
end

--- JSON API response
function M.json_response(ctx, status, data)
    ctx.status = status
    ctx.headers["Content-Type"] = "application/json; charset=utf-8"
    ctx.body = cjson.encode(data)
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

--- Build EVAL args table from script, keys list, and argv list
function M.build_eval_args(script, keys_list, argv_list)
    local args = { script, #keys_list }
    for _, k in ipairs(keys_list) do args[#args + 1] = k end
    for _, a in ipairs(argv_list) do args[#args + 1] = a end
    return args
end

--- HTTP status class for badge coloring
function M.status_class(code)
    if code >= 200 and code < 300 then return "2xx"
    elseif code >= 300 and code < 400 then return "3xx"
    else return "4xx5xx"
    end
end

--- Broadcast an SSE event with automatic JSON encoding
function M.broadcast_event(room, data)
    __keyway_sse_broadcast(room, cjson.encode(data))
end

--- Relative time formatting for ISO/Postgres timestamps
function M.relative_time(iso_str)
    local y, mo, d, h, mi, s = iso_str:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)")
    if not y then return iso_str end
    local utc_t = { year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }
    local ts = os.time(utc_t)
    local local_now = os.time()
    local utc_now = os.time(os.date("!*t", local_now))
    local tz_offset = local_now - utc_now
    ts = ts - tz_offset
    local diff = local_now - ts
    if diff < 0 then return "just now" end
    if diff < 60 then return diff .. "s ago" end
    if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
    if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
    return math.floor(diff / 86400) .. "d ago"
end

-- Header classification tables for probe display
local security_headers = {
    ["strict-transport-security"] = true, ["content-security-policy"] = true,
    ["x-content-type-options"] = true, ["x-frame-options"] = true,
    ["x-xss-protection"] = true, ["referrer-policy"] = true,
    ["permissions-policy"] = true, ["cross-origin-opener-policy"] = true,
    ["cross-origin-resource-policy"] = true,
}
local cache_headers = {
    ["cache-control"] = true, ["etag"] = true, ["last-modified"] = true,
    ["expires"] = true, ["age"] = true, ["vary"] = true,
}
local identity_headers = {
    ["server"] = true, ["x-powered-by"] = true, ["via"] = true,
}

--- Classify a header name into a category (security/cache/identity/nil)
function M.classify_header(name)
    local lower = name:lower()
    if security_headers[lower] then return "security" end
    if cache_headers[lower] then return "cache" end
    if identity_headers[lower] then return "identity" end
    return nil
end

-- Upgrade type constants
M.UPGRADE_SSE = "sse"
M.UPGRADE_WS  = "websocket"

return M
