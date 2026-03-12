-- keyway.webhook — Outbound webhook module
-- Thin wrapper over http_client.post() for JSON payloads.

local http_client = require("keyway.http_client")
local cjson       = require("cjson")

local M = {}

-- POST a JSON-encoded payload to a URL.
-- Returns result table or nil + error string.
function M.send(url, payload)
    local body = cjson.encode(payload)
    local headers = {
        { "Content-Type", "application/json" },
    }
    return http_client.post(url, body, headers)
end

-- Send a message to a Discord webhook.
-- message can be a string (wrapped as {content: msg}) or a table (passed through for embeds).
-- Returns result table or nil + error string.
function M.discord(url, message)
    local payload
    if type(message) == "string" then
        payload = { content = message }
    elseif type(message) == "table" then
        payload = message
    else
        return nil, "message must be a string or table"
    end
    return M.send(url, payload)
end

return M
