-- routes/websocket.lua — WebSocket echo demo + test page
local resp = require("keyway.response")

return {
    ["/ws"] = {
        GET = function(ctx)
            if (ctx.headers["Upgrade"] or ""):lower() ~= "websocket" then
                ctx.status = 400
                ctx.body = "Expected WebSocket upgrade"
                return
            end
            ctx.upgrade = resp.UPGRADE_WS
            ctx.on_message = function(ws)
                ws:send("echo: " .. ws.message)
            end
        end,
    },

    ["/websocket"] = {
        GET = function(ctx)
            resp.html_response(ctx, "websocket", {})
        end,
    },
}
