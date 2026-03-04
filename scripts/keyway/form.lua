-- keyway.form — URL-encoded (application/x-www-form-urlencoded) body parser
-- Decodes + as space, %XX as characters, splits on & and =.
-- Usage:
--   local form = require("keyway.form")
--   local data = form.parse(ctx.body)
--   -- data.name, data.email, etc.

local M = {}

--- Decode a URL-encoded string segment.
-- Replaces + with space, then decodes %XX hex escapes.
-- @param s  Raw URL-encoded string
-- @return   Decoded string
local function url_decode(s)
    return s:gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

--- Parse a URL-encoded form body into a table.
-- Splits the body on &, then splits each pair on the first = to get key/value.
-- Both key and value are URL-decoded. Keys without = get an empty string value.
-- Returns an empty table for nil or empty body.
-- @param body  Raw request body string (or nil)
-- @return      Table mapping string keys to string values
function M.parse(body)
    local result = {}
    if not body or body == "" then
        return result
    end

    for pair in (body .. "&"):gmatch("([^&]*)&") do
        if pair ~= "" then
            local eq = pair:find("=")
            local key, value
            if eq then
                key   = url_decode(pair:sub(1, eq - 1))
                value = url_decode(pair:sub(eq + 1))
            else
                key   = url_decode(pair)
                value = ""
            end
            if key ~= "" then
                result[key] = value
            end
        end
    end

    return result
end

return M
