-- routes/short.lua — URL shortener routes
local form         = require("keyway.form")
local redis_client = require("keyway.redis")
local resp         = require("keyway.response")
local redis_util   = require("keyway.redis_util")

-- Convert number to base36 string
local b36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function to_base36(n)
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        local r = n % 36
        s = b36:sub(r + 1, r + 1) .. s
        n = math.floor(n / 36)
    end
    return s
end

local function fetch_links(client)
    local list_ok, codes = pcall(function() return client:lrange("short:recent", 0, 19) end)
    if not list_ok or not codes or #codes == 0 then return {} end

    -- Batch fetch: 1 LRANGE + 2 MGETs = 3 round-trips (was 1 + 2N)
    local url_keys, hit_keys = {}, {}
    for i, code in ipairs(codes) do
        url_keys[i] = "short:" .. code
        hit_keys[i] = "short:" .. code .. ":hits"
    end

    local urls_ok, urls = pcall(function() return client:mget(unpack(url_keys)) end)
    local hits_ok, hits = pcall(function() return client:mget(unpack(hit_keys)) end)
    if not urls_ok or not urls then return {} end

    local links = {}
    for i, code in ipairs(codes) do
        if urls[i] then
            links[#links + 1] = {
                code = code,
                url = urls[i],
                hits = (hits_ok and hits and hits[i]) and tonumber(hits[i]) or 0,
            }
        end
    end
    return links
end

return {
    ["/short"] = {
        GET = function(ctx)
            local links = redis_util.with_redis(function(client) return fetch_links(client) end) or {}
            resp.html_response(ctx, "short", { links = links })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local url = resp.trim(fields.url or "")

            if url == "" or (not url:match("^https?://")) then
                local links = redis_util.with_redis(function(client) return fetch_links(client) end) or {}
                resp.html_response(ctx, "short", { links = links, error_msg = "Please enter a valid URL starting with http:// or https://" })
                return
            end

            local client, connect_err = redis_client.connect()
            if not client then
                resp.html_response(ctx, "short", { error_msg = "Redis error: " .. (connect_err or "unknown") })
                return
            end

            local create_ok, code = pcall(function()
                local id = client:incr("short:next_id")
                local c = to_base36(id)
                client:set("short:" .. c, url)
                client:set("short:" .. c .. ":hits", "0")
                client:set("short:" .. c .. ":ts", tostring(os.time()))
                client:lpush("short:recent", c)
                client:ltrim("short:recent", 0, 49)
                return c
            end)

            local links = fetch_links(client)
            redis_client.keepalive(client)

            if create_ok then
                resp.broadcast_event("short", {
                    type = "created",
                    code = code,
                    url = url,
                    hits = 0,
                })
                local host = resp.get_header(ctx, "host") or ""
                local short_url = "http://" .. host .. "/s/" .. code
                resp.html_response(ctx, "short", {
                    links = links,
                    created = { code = code, target = url, short_url = short_url },
                })
            else
                resp.html_response(ctx, "short", { links = links, error_msg = "Redis error: " .. tostring(code) })
            end
        end,
    },

    ["/s/{code}"] = {
        GET = function(ctx)
            local code = ctx.params.code or ""
            local client, connect_err = redis_client.connect()
            if not client then
                ctx.status = 502
                ctx.body = "Redis unavailable"
                return
            end
            local get_ok, url = pcall(function() return client:get("short:" .. code) end)
            if get_ok and url then
                local incr_ok, hits = pcall(function() return client:incr("short:" .. code .. ":hits") end)
                redis_client.keepalive(client)
                resp.broadcast_event("short", {
                    type = "hit",
                    code = code,
                    hits = incr_ok and tonumber(hits) or 0,
                })
                ctx.status = 302
                ctx.headers["Location"] = url
                ctx.body = ""
            else
                redis_client.keepalive(client)
                ctx.status = 404
                ctx.headers["Content-Type"] = "text/plain"
                ctx.body = "Short URL not found"
            end
        end,
    },

    ["/short/events"] = {
        GET = function(ctx)
            ctx.upgrade = resp.UPGRADE_SSE
            ctx.sse_room = "short"
        end,
    },
}
