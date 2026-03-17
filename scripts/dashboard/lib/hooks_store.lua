-- hooks_store.lua — Webhook capture (Redis-persisted metadata + in-memory captures + SSE broadcast)
local cjson = require("cjson")
local response = require("keyway.response")
local redis = require("scripts.dashboard.lib.redis_ring")
local ffi = require("ffi")

local M = {}

local REDIS_KEY = "kw:hooks"
local MAX_CAPTURES = 50
local CAPTURE_PREFIX = "kw:hook_captures:"

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

-- Load all hooks metadata from Redis
local function load_hooks()
    local data, err = redis.get(REDIS_KEY)
    if not data then return {} end
    local ok, hooks = pcall(cjson.decode, data)
    if not ok or type(hooks) ~= "table" then return {} end
    return hooks
end

-- Save all hooks metadata to Redis
local function save_hooks(hooks)
    return redis.set(REDIS_KEY, cjson.encode(hooks))
end

function M.create()
    local hooks = load_hooks()
    local id = generate_id()
    local hook = {
        id = id,
        name = "",
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    hooks[#hooks + 1] = hook
    save_hooks(hooks)
    return hook
end

function M.exists(id)
    local hooks = load_hooks()
    for _, h in ipairs(hooks) do
        if h.id == id then return true end
    end
    return false
end

function M.capture(id, request_data)
    request_data.ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local encoded = cjson.encode(request_data)
    redis.lpush(CAPTURE_PREFIX .. id, encoded)
    redis.ltrim(CAPTURE_PREFIX .. id, 0, MAX_CAPTURES - 1)
    -- Broadcast capture event via SSE
    pcall(response.broadcast_html, "hook:" .. id, "capture", encoded)
    return true
end

local function load_captures(id)
    local raw = redis.lrange(CAPTURE_PREFIX .. id, 0, MAX_CAPTURES - 1)
    if not raw or type(raw) ~= "table" then return {} end
    local result = {}
    for _, item in ipairs(raw) do
        local ok, decoded = pcall(cjson.decode, item)
        if ok then result[#result + 1] = decoded end
    end
    return result
end

function M.get(id)
    local hooks = load_hooks()
    for _, h in ipairs(hooks) do
        if h.id == id then
            h.requests = load_captures(id)
            return h
        end
    end
    return nil
end

function M.list()
    local hooks = load_hooks()
    local result = {}
    for _, h in ipairs(hooks) do
        local caps = load_captures(h.id)
        result[#result + 1] = {
            id = h.id,
            name = h.name or "",
            created_at = h.created_at,
            capture_count = #caps,
        }
    end
    return result
end

function M.get_requests(id)
    return load_captures(id)
end

function M.delete(id)
    local hooks = load_hooks()
    for i, h in ipairs(hooks) do
        if h.id == id then
            table.remove(hooks, i)
            save_hooks(hooks)
            redis.del(CAPTURE_PREFIX .. id)
            return true
        end
    end
    return false
end

return M
