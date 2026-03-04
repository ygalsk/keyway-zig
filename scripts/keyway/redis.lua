-- keyway.redis — Redis client wrapper using cosocket
-- Bridges redis-lua (luarocks) with keyway.socket for non-blocking I/O.
-- Usage:
--   local redis_client = require("keyway.redis")
--   local client, err = redis_client.connect()
--   if client then
--       client:set("key", "value")
--       local val = client:get("key")
--       redis_client.keepalive(client)
--   end

local socket = require("keyway.socket")
local redis  = require("redis")

local M = {}

local REDIS_HOST = "127.0.0.1"
local REDIS_PORT = 6379

--- Connect to Redis using cosocket, returning a redis-lua client.
-- The cosocket is pre-connected and passed to redis-lua via the socket parameter,
-- bypassing its internal require('socket') call entirely.
-- @return client, err  redis-lua client object or nil + error string
function M.connect()
    local sock = socket.tcp()
    local ok, err = sock:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        return nil, "Redis connection failed: " .. (err or "unknown error")
    end

    -- redis-lua calls setoption('tcp-nodelay', true) and shutdown() on quit —
    -- our cosocket doesn't support these, so add no-op stubs.
    sock.setoption = function() return true end
    sock.shutdown  = function(self) return self:close() end

    -- Pass pre-connected cosocket directly to redis-lua (skips LuaSocket require)
    local client = redis.connect({ socket = sock })

    -- Stash socket ref so keepalive can return it to pool
    client._keyway_sock = sock

    return client
end

--- Return the connection to the cosocket pool for reuse.
-- Call this instead of client:quit() to enable connection pooling.
-- @param client  redis-lua client returned by M.connect()
function M.keepalive(client)
    if client._keyway_sock then
        client._keyway_sock:setkeepalive(0, 0)
        client._keyway_sock = nil
    end
end

--- Close the connection without pooling.
-- @param client  redis-lua client returned by M.connect()
function M.close(client)
    if client._keyway_sock then
        client._keyway_sock:close()
        client._keyway_sock = nil
    end
end

return M
