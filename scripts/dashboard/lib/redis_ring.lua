-- keyway.redis_ring — Native Redis client using batched I/O ring
-- Demonstrates the fan-out win: 2 yields for a full GET instead of 6.
-- No external dependencies (no redis-lua LuaRock needed).
--
-- Usage:
--   local redis = require("keyway.redis_ring")
--   local val = redis.get("mykey")
--   local ok = redis.set("mykey", "myvalue")

local ring = require("keyway.ring")

local M = {}

-- Default connection settings
M.host = "127.0.0.1"
M.port = 6379
M.pool_name = "redis"
M.pool_timeout_ms = 30000
M.pool_size = 10

-- Parse a simple Redis RESP reply (bulk string, simple string, integer, error)
local function parse_redis_reply(buf)
    if not buf or #buf == 0 then return nil, "empty reply" end

    local prefix = buf:sub(1, 1)
    local line_end = buf:find("\r\n")
    if not line_end then return nil, "incomplete reply" end

    if prefix == "+" then
        -- Simple string
        return buf:sub(2, line_end - 1)
    elseif prefix == "-" then
        -- Error
        return nil, buf:sub(2, line_end - 1)
    elseif prefix == ":" then
        -- Integer
        return tonumber(buf:sub(2, line_end - 1))
    elseif prefix == "$" then
        -- Bulk string
        local len = tonumber(buf:sub(2, line_end - 1))
        if len == -1 then return nil end -- null bulk string
        local data_start = line_end + 2
        return buf:sub(data_start, data_start + len - 1)
    elseif prefix == "*" then
        -- Array (simplified: return raw for now)
        return buf
    end

    return nil, "unknown reply type: " .. prefix
end

--- Build a RESP command string from arguments
local function build_cmd(...)
    local args = {...}
    local parts = {"*" .. #args .. "\r\n"}
    for _, arg in ipairs(args) do
        local s = tostring(arg)
        parts[#parts + 1] = "$" .. #s .. "\r\n" .. s .. "\r\n"
    end
    return table.concat(parts)
end

--- Execute a Redis command. 2 yields: connect + (send+recv batched).
function M.command(...)
    local r = ring.new()

    -- Yield 1: connect (pool hit is sync, miss is async)
    r:pool_connect(M.pool_name, M.host, M.port)
    local conns = r:submit()

    if not conns[1] or not conns[1].fd then
        return nil, conns[1] and conns[1].err or "connect failed"
    end
    local fd = conns[1].fd

    -- Yield 2: send + recv batched in one submission
    local cmd = build_cmd(...)
    r:send(fd, cmd)
    r:recv(fd, 4096)
    local results = r:submit()

    -- Return connection to pool (synchronous, no yield needed)
    __keyway_pool_setkeepalive(fd, M.pool_name, M.pool_timeout_ms, M.pool_size, 0)

    -- Parse the recv result (index 2 = recv)
    if not results[2] or not results[2].buf then
        return nil, results[2] and results[2].err or "recv failed"
    end

    return parse_redis_reply(results[2].buf)
end

--- GET key
function M.get(key)
    return M.command("GET", key)
end

--- SET key value [EX seconds]
function M.set(key, value, ex)
    if ex then
        return M.command("SET", key, value, "EX", ex)
    end
    return M.command("SET", key, value)
end

--- DEL key
function M.del(key)
    return M.command("DEL", key)
end

--- INCR key
function M.incr(key)
    return M.command("INCR", key)
end

--- PING
function M.ping()
    return M.command("PING")
end

return M
