-- routes/dns.lua — DNS lookup routes
local form = require("keyway.form")
local dns  = require("keyway.dns")
local resp = require("keyway.response")

return {
    ["/dns"] = {
        GET = function(ctx)
            resp.html_response(ctx, "dns", {})
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local domain = fields.domain or ""
            domain = resp.trim(domain)

            if domain == "" then
                resp.html_response(ctx, "dns", { error_msg = "Domain is required" })
                return
            end

            local t0 = resp.now_us()
            local records, lookup_err = dns.lookup(domain)
            local dns_time = math.floor(resp.now_us() - t0)

            if records then
                resp.html_response(ctx, "dns", {
                    domain = domain,
                    records = records,
                    dns_time_us = dns_time,
                })
            else
                resp.html_response(ctx, "dns", { domain = domain, error_msg = lookup_err })
            end
        end,
    },
}
