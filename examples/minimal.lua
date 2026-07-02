-- Production-safe default entry surface.
local response = require("keyway.response")

keyway.routes = {
    ["/ping"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.body = "pong"
        end,
    },

    ["/hello/{name}"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.body = "hello " .. (ctx.params.name or "world")
        end,
    },

    ["/json"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, { message = "hello from keyway" })
        end,
    },
}
