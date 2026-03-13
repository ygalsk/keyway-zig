-- routes/ratelimit.lua — Rate limiter demo
local redis_client = require("keyway.redis")
local resp         = require("keyway.response")

return {
    ["/ratelimit"] = {
        GET = function(ctx)
            resp.html_response(ctx, "ratelimit", {})
        end,
    },

    ["/ratelimit/api"] = (function()
        local SLIDING_WINDOW_SCRIPT = [[
            local key = KEYS[1]
            local now = tonumber(ARGV[1])
            local window = tonumber(ARGV[2])
            local limit = tonumber(ARGV[3])
            redis.call("ZREMRANGEBYSCORE", key, 0, now - window)
            local count = redis.call("ZCARD", key)
            if count < limit then
                redis.call("ZADD", key, now, now .. ":" .. math.random())
                redis.call("EXPIRE", key, math.ceil(window / 1000) + 1)
                return { 1, limit - count - 1 }
            end
            return { 0, 0 }
        ]]

        local WINDOW_MS = 60000  -- 60 seconds
        local LIMIT = 10

        local function rate_limit(ctx)
            -- Use client IP or fallback to "demo"
            local xff = resp.get_header(ctx, "x-forwarded-for")
            local identifier = xff and (xff:match("^[^,]+") or "demo") or "demo"

            local client, connect_err = redis_client.connect()
            if not client then
                resp.json_response(ctx, 503, { error = "Redis unavailable" })
                return
            end

            local now_ms = math.floor(os.time() * 1000)
            local rl_key = "rl:" .. identifier
            local eval_args = resp.build_eval_args(SLIDING_WINDOW_SCRIPT, { rl_key }, { tostring(now_ms), tostring(WINDOW_MS), tostring(LIMIT) })

            local eval_ok, result = pcall(function()
                return client:eval(unpack(eval_args))
            end)
            redis_client.keepalive(client)

            ctx.headers["X-RateLimit-Limit"] = tostring(LIMIT)
            ctx.headers["X-RateLimit-Window"] = "60s"

            if not eval_ok then
                resp.json_response(ctx, 500, { error = "Rate limit check failed" })
                return
            end

            local allowed = result[1] == 1
            local remaining = result[2] or 0

            ctx.headers["X-RateLimit-Remaining"] = tostring(remaining)

            resp.broadcast_event("ratelimit", {
                identifier = identifier,
                allowed = allowed,
                remaining = remaining,
                limit = LIMIT,
                status = allowed and 200 or 429,
            })

            if allowed then
                resp.json_response(ctx, 200, { message = "Request allowed", remaining = remaining })
            else
                ctx.headers["Retry-After"] = "60"
                resp.json_response(ctx, 429, { error = "Rate limit exceeded", remaining = 0 })
            end
        end

        return {
            GET = rate_limit,
        }
    end)(),

    ["/ratelimit/events"] = {
        GET = function(ctx)
            ctx.upgrade = resp.UPGRADE_SSE
            ctx.sse_room = "ratelimit"
        end,
    },
}
