-- routes/probe.lua — HTTP probe / site inspector
local form        = require("keyway.form")
local http_client = require("keyway.http_client")
local resp        = require("keyway.response")
local redis_util  = require("keyway.redis_util")

return {
    ["/probe"] = {
        GET = function(ctx)
            local vars = {}
            -- Support prefill from DNS "Probe this" links
            if ctx.query and ctx.query.prefill then
                vars.url = ctx.query.prefill
            end
            resp.html_response(ctx, "probe", vars)
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local url    = fields.url or ""

            if url == "" then
                resp.html_response(ctx, "probe", { error_msg = "URL is required" })
                return
            end

            local result, probe_err = http_client.probe(url)

            if not result then
                resp.html_response(ctx, "probe", { url = url, error_msg = probe_err })
                return
            end

            result.status_class = resp.status_class(result.status)

            -- Classify headers
            if result.headers then
                for _, h in ipairs(result.headers) do
                    h.category = resp.classify_header(h[1])
                end
            end

            -- Probe history via Redis
            local probe_history = redis_util.with_redis(function(client)
                client:lpush("probe:history", url)
                client:ltrim("probe:history", 0, 4)
                return client:lrange("probe:history", 0, 4) or {}
            end) or {}

            resp.html_response(ctx, "probe", {
                url = url,
                result = result,
                probe_history = probe_history,
            })
        end,
    },
}
