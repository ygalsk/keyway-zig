-- redis_util.lua — Redis connect-and-execute wrapper + shared utilities
local redis_client = require("keyway.redis")

local M = {}

--- Execute a callback with a Redis connection, auto-keepalive.
--- Returns the callback result on success, or nil + error string on failure.
function M.with_redis(callback)
    local client, connect_err = redis_client.connect()
    if not client then return nil, connect_err end
    local call_ok, result = pcall(callback, client)
    redis_client.keepalive(client)
    if not call_ok then return nil, result end
    return result
end

-- Server-side EVAL script: fetch all user keys from Redis via SCAN (non-blocking).
-- Excludes internal prefixes (hook:, probe:, fn:, short:, rl:, paste:).
local redis_keys_script = [[
    local cursor = "0"
    local keys = {}
    local exclude = {["hook:"]=1,["probe:"]=1,["fn:"]=1,["short:"]=1,["rl:"]=1,["paste:"]=1}
    repeat
        local res = redis.call("SCAN", cursor, "COUNT", 100)
        cursor = res[1]
        for _, k in ipairs(res[2]) do
            local dominated = false
            for prefix in pairs(exclude) do
                if k:sub(1, #prefix) == prefix then dominated = true; break end
            end
            if not dominated then keys[#keys+1] = k end
        end
    until cursor == "0"
    table.sort(keys)
    return keys
]]

--- Fetch all user-visible keys from Redis (excludes internal prefixes).
--- Returns sorted key table or nil + error string.
function M.redis_keys()
    return M.with_redis(function(client)
        return client:eval(redis_keys_script, 0)
    end)
end

return M
