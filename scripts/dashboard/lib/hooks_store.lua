-- hooks_store.lua — Webhook capture (in-memory + SSE broadcast)
local cjson = require("cjson")
local response = require("keyway.response")
local ffi = require("ffi")

local M = {}

-- In-memory storage (per-worker)
local _hooks = {}       -- id -> { created_at, requests[] }
local MAX_CAPTURES = 50

-- Generate 8-char hex ID
pcall(ffi.cdef, [[int open(const char *path, int flags); long read(int fd, void *buf, long count); int close(int fd);]])

local function generate_id()
    local fd = ffi.C.open("/dev/urandom", 0)
    if fd < 0 then
        return string.format("%08x", os.time())
    end
    local buf = ffi.new("uint8_t[4]")
    ffi.C.read(fd, buf, 4)
    ffi.C.close(fd)
    local hex = {}
    for i = 0, 3 do hex[#hex + 1] = string.format("%02x", buf[i]) end
    return table.concat(hex)
end

function M.create()
    local id = generate_id()
    _hooks[id] = {
        id = id,
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        requests = {},
    }
    return _hooks[id]
end

function M.exists(id)
    return _hooks[id] ~= nil
end

function M.capture(id, request_data)
    local hook = _hooks[id]
    if not hook then return false end
    request_data.ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    table.insert(hook.requests, 1, request_data)
    if #hook.requests > MAX_CAPTURES then
        hook.requests[MAX_CAPTURES + 1] = nil
    end
    -- Broadcast capture event via SSE
    pcall(response.broadcast_html, "hook:" .. id, "capture", cjson.encode(request_data))
    return true
end

function M.get(id)
    return _hooks[id]
end

function M.list()
    local result = {}
    for id, h in pairs(_hooks) do
        result[#result + 1] = {
            id = id,
            created_at = h.created_at,
            request_count = #h.requests,
        }
    end
    return result
end

function M.get_requests(id)
    local hook = _hooks[id]
    if not hook then return nil end
    return hook.requests
end

function M.delete(id)
    if _hooks[id] then
        _hooks[id] = nil
        return true
    end
    return false
end

return M
