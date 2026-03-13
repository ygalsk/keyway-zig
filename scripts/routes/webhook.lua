-- routes/webhook.lua — Discord webhook sender
local form    = require("keyway.form")
local webhook = require("keyway.webhook")
local resp    = require("keyway.response")

return {
    ["/webhook"] = {
        GET = function(ctx)
            resp.html_response(ctx, "webhook", {
                webhook_url = os.getenv("DISCORD_WEBHOOK_URL"),
            })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local message = fields.message or ""
            message = resp.trim(message)

            local discord_url = os.getenv("DISCORD_WEBHOOK_URL")
            if not discord_url or discord_url == "" then
                resp.html_response(ctx, "webhook", {
                    error_msg = "DISCORD_WEBHOOK_URL environment variable is not set",
                })
                return
            end

            if message == "" then
                resp.html_response(ctx, "webhook", {
                    webhook_url = discord_url,
                    error_msg = "Message cannot be empty",
                })
                return
            end

            local result, send_err = webhook.discord(discord_url, message)

            if not result then
                resp.html_response(ctx, "webhook", {
                    webhook_url = discord_url,
                    error_msg = send_err,
                })
                return
            end

            result.status_class = resp.status_class(result.status)

            resp.html_response(ctx, "webhook", {
                webhook_url = discord_url,
                result = result,
                success_msg = "Message sent to Discord",
            })
        end,
    },
}
