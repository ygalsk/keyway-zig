-- routes/static.lua — Static assets and home page
local resp = require("keyway.response")

-- Load static CSS once at startup (each worker independently)
local css_file = assert(io.open("scripts/static/style.css", "r"))
local css_content = css_file:read("*a")
css_file:close()

return {
    ["/style.css"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/css; charset=utf-8"
            ctx.headers["Cache-Control"] = "public, max-age=86400"
            ctx.body = css_content
        end,
    },

    ["/"] = {
        GET = function(ctx)
            resp.html_response(ctx, "home", {})
        end,
    },
}
