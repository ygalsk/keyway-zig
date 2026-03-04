-- keyway.hooks — Webhook storage and retrieval module
-- Handles ID generation, Redis storage, and request capture.

local ffi   = require("ffi")
local cjson = require("cjson")

-- FFI declarations for /dev/urandom access (called once at module load)
pcall(ffi.cdef, [[
    int open(const char *pathname, int flags);
    typedef long ssize_t;
    ssize_t read(int fd, void *buf, size_t count);
    int close(int fd);
]])

local O_RDONLY = 0

local M = {}

local urandom_fd = ffi.C.open("/dev/urandom", O_RDONLY)

--- Generate a 16-char lowercase hex ID from /dev/urandom.
-- @return string  e.g. "a3f9c1d2b4e5f607"
function M.generate_id()
    if urandom_fd < 0 then
        math.randomseed(os.time())
        return string.format("%08x%08x", os.time(), math.random(0, 0xffffffff))
    end
    local buf = ffi.new("unsigned char[8]")
    ffi.C.read(urandom_fd, buf, 8)
    local parts = {}
    for i = 0, 7 do
        parts[i + 1] = string.format("%02x", buf[i])
    end
    return table.concat(parts)
end

--- Mark a webhook as existing in Redis.
-- @param client  redis-lua client from keyway.redis
-- @param id      string hook ID
function M.create(client, id)
    client:set("hook:" .. id, "1")
end

--- Check if a webhook exists.
-- @param client  redis-lua client
-- @param id      string hook ID
-- @return bool
function M.exists(client, id)
    -- redis-lua returns boolean true/false for EXISTS, not 1/0
    local val = client:get("hook:" .. id)
    return val ~= nil and val ~= false
end

--- Capture an incoming request into the hook's Redis list.
-- Stores newest-first; keeps at most 50 entries per hook.
-- @param client  redis-lua client
-- @param id      string hook ID
-- @param data    table { method, path, headers, body, timestamp }
function M.capture(client, id, data)
    local key   = "hook:" .. id .. ":reqs"
    local entry = cjson.encode(data)
    client:lpush(key, entry)
    client:ltrim(key, 0, 49)
end

--- List captured requests for a hook, newest first.
-- @param client  redis-lua client
-- @param id      string hook ID
-- @return table  array of decoded request tables (may be empty)
function M.list_requests(client, id)
    local key = "hook:" .. id .. ":reqs"
    local raw = client:lrange(key, 0, 49)
    if not raw or #raw == 0 then return {} end
    local results = {}
    for _, entry in ipairs(raw) do
        local ok, decoded = pcall(cjson.decode, entry)
        if ok and decoded then
            results[#results + 1] = decoded
        end
    end
    return results
end

return M
