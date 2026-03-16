-- probe.lua — HTTP probe logic using keyway.http_client
local response = require("keyway.response")
local cjson = require("cjson")
local http = require("keyway.http_client")

local M = {}

-- Header classification
local SECURITY_HEADERS = {
    ["strict-transport-security"] = true, ["content-security-policy"] = true,
    ["x-content-type-options"] = true, ["x-frame-options"] = true,
    ["x-xss-protection"] = true, ["referrer-policy"] = true,
    ["permissions-policy"] = true,
}
local CACHE_HEADERS = {
    ["cache-control"] = true, ["etag"] = true, ["last-modified"] = true,
    ["expires"] = true, ["age"] = true, ["vary"] = true,
}

function M.classify_header(name)
    local lower = name:lower()
    if SECURITY_HEADERS[lower] then return "security" end
    if CACHE_HEADERS[lower] then return "cache" end
    return "general"
end

-- Execute probe and return structured result (or nil, error_string)
function M.execute(url)
    local result, err = http.probe(url)
    if not result then
        return nil, err
    end
    -- Add header classification and reshape to dashboard format
    local classified_headers = {}
    for _, h in ipairs(result.headers) do
        classified_headers[#classified_headers + 1] = {
            name = h[1], value = h[2],
            category = M.classify_header(h[1]),
        }
    end
    local timing_us = result.timing_ms * 1000
    return {
        url          = url,
        status       = result.status,
        headers      = classified_headers,
        timing_ms    = result.timing_ms,
        timing_us    = timing_us,
        body_preview = (result.body or ""):sub(1, 500),
    }
end

function M.probe(ctx)
    local ok, body = pcall(cjson.decode, ctx.body)
    if not ok or not body.url then
        response.json_response(ctx, 400, { error = "JSON body with 'url' field required" })
        return
    end
    local result, err = M.execute(body.url)
    if not result then
        response.json_response(ctx, 200, { error = err })
        return
    end
    response.json_response(ctx, 200, {
        status       = result.status,
        headers      = result.headers,
        timing_ms    = result.timing_ms,
        body_preview = result.body_preview,
    })
end

return M
