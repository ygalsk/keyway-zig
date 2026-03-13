-- routes/hooks.lua — Webhook catch + management routes
local form         = require("keyway.form")
local redis_client = require("keyway.redis")
local hooks        = require("keyway.hooks")
local resp         = require("keyway.response")
local redis_util   = require("keyway.redis_util")

return {
    -- Webhook catch endpoint -- accepts any HTTP method, stores request in Redis
    ["/h/{id}"] = (function()
        local function capture(ctx)
            local id   = ctx.params.id or ""
            local data = {
                method    = ctx.method or "",
                path      = ctx.path or "",
                headers   = ctx.request_headers,
                body      = ctx.body or "",
                timestamp = os.time(),
            }
            redis_util.with_redis(function(client) hooks.capture(client, id, data) end)
            data.timestamp_str = os.date("!%Y-%m-%dT%H:%M:%SZ", data.timestamp)
            resp.broadcast_event("hook:" .. id, data)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/plain; charset=utf-8"
            ctx.body = "OK"
        end
        return {
            GET    = capture,
            POST   = capture,
            PUT    = capture,
            DELETE = capture,
            PATCH  = capture,
            HEAD   = capture,
        }
    end)(),

    ["/hooks"] = {
        GET = function(ctx)
            resp.html_response(ctx, "hooks", {})
        end,

        POST = function(ctx)
            local id = hooks.generate_id()
            local _, create_err = redis_util.with_redis(function(client)
                hooks.create(client, id)
            end)
            if not create_err then
                ctx.status = 303
                ctx.headers["Location"] = "/hooks/" .. id
                ctx.body = ""
            else
                resp.html_response(ctx, "hooks", {
                    error_msg = "Redis error: " .. (create_err or "unknown"),
                })
            end
        end,
    },

    ["/hooks/{id}/test"] = {
        POST = function(ctx)
            local id = ctx.params.id or ""
            local fields = form.parse(ctx.body)
            local method = fields.method or "POST"
            local body = fields.body or ""

            local data = {
                method    = method,
                path      = "/h/" .. id,
                headers   = { { "X-Source", "Test Panel" }, { "Content-Type", "text/plain" } },
                body      = body,
                timestamp = os.time(),
            }

            redis_util.with_redis(function(client) hooks.capture(client, id, data) end)
            data.timestamp_str = os.date("!%Y-%m-%dT%H:%M:%SZ", data.timestamp)
            resp.broadcast_event("hook:" .. id, data)

            ctx.status = 303
            ctx.headers["Location"] = "/hooks/" .. id
            ctx.body = ""
        end,
    },

    ["/hooks/{id}/events"] = {
        GET = function(ctx)
            ctx.upgrade = resp.UPGRADE_SSE
            ctx.sse_room = "hook:" .. ctx.params.id
        end,
    },

    ["/hooks/{id}"] = {
        GET = function(ctx)
            local id = ctx.params.id or ""
            local client, connect_err = redis_client.connect()
            if not client then
                resp.html_response(ctx, "hook_detail", {
                    hook_id   = id,
                    requests  = {},
                    error_msg = "Redis error: " .. (connect_err or "unknown"),
                })
                return
            end
            local exists   = hooks.exists(client, id)
            local requests = hooks.list_requests(client, id)
            redis_client.keepalive(client)

            for _, r in ipairs(requests) do
                r.timestamp_str = os.date("!%Y-%m-%dT%H:%M:%SZ", r.timestamp)
            end

            resp.html_response(ctx, "hook_detail", {
                hook_id   = id,
                requests  = requests,
                error_msg = not exists and "Webhook not found",
            })
        end,
    },
}
