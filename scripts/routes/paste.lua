-- routes/paste.lua — Paste bin routes
local form         = require("keyway.form")
local redis_client = require("keyway.redis")
local hooks        = require("keyway.hooks")
local cjson        = require("cjson")
local resp         = require("keyway.response")
local redis_util   = require("keyway.redis_util")

local TTL_LABELS = { ["3600"] = "1 hour", ["86400"] = "24 hours", ["604800"] = "7 days", ["0"] = "never" }

-- Shared: fetch a paste by ID (used by /paste/{id} and /paste/{id}/raw)
local function paste_fetch(id)
    local client, connect_err = redis_client.connect()
    if not client then return nil, nil, "Redis unavailable" end

    local get_ok, raw = pcall(function() return client:get("paste:" .. id) end)
    if not get_ok or not raw then
        redis_client.keepalive(client)
        return nil, nil, "Paste not found or expired"
    end

    local incr_ok, view_count = pcall(function() return client:incr("paste:" .. id .. ":views") end)
    redis_client.keepalive(client)

    local decode_ok, data = pcall(cjson.decode, raw)
    if not decode_ok or not data then return nil, nil, "Corrupt paste data" end

    local views = (incr_ok and view_count) and tonumber(view_count) or 0
    return data, views, nil
end

local function fetch_pastes(client)
    local list_ok, ids = pcall(function() return client:lrange("paste:recent", 0, 19) end)
    if not list_ok or not ids or #ids == 0 then return {} end

    -- Batch fetch: 1 LRANGE + 2 MGETs = 3 round-trips (was 1 + 2N)
    local data_keys, view_keys = {}, {}
    for i, id in ipairs(ids) do
        data_keys[i] = "paste:" .. id
        view_keys[i] = "paste:" .. id .. ":views"
    end

    local mget_ok, raws = pcall(function() return client:mget(unpack(data_keys)) end)
    local views_ok, views = pcall(function() return client:mget(unpack(view_keys)) end)
    if not mget_ok or not raws then return {} end

    local pastes = {}
    for i, id in ipairs(ids) do
        if raws[i] then
            local decode_ok, data = pcall(cjson.decode, raws[i])
            if decode_ok and data then
                local preview = data.content or ""
                if #preview > 80 then preview = preview:sub(1, 80) .. "..." end
                pastes[#pastes + 1] = {
                    id = id,
                    title = data.title or "untitled",
                    views = (views_ok and views and views[i]) and tonumber(views[i]) or 0,
                    preview = preview,
                }
            end
        end
    end
    return pastes
end

return {
    ["/paste"] = {
        GET = function(ctx)
            local pastes = redis_util.with_redis(function(client) return fetch_pastes(client) end) or {}
            resp.html_response(ctx, "paste", { pastes = pastes })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local content = fields.content or ""
            local title = resp.trim(fields.title or "")
            local ttl = tonumber(fields.ttl) or 86400

            if content == "" then
                local pastes = redis_util.with_redis(function(client) return fetch_pastes(client) end) or {}
                resp.html_response(ctx, "paste", { pastes = pastes, error_msg = "Content cannot be empty" })
                return
            end

            local client, connect_err = redis_client.connect()
            if not client then
                resp.html_response(ctx, "paste", { error_msg = "Redis error: " .. (connect_err or "unknown") })
                return
            end

            local id = hooks.generate_id()
            if title == "" then title = "untitled" end

            local data = cjson.encode({
                content = content,
                title = title,
                created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            })

            local save_ok, save_err = pcall(function()
                if ttl > 0 then
                    client:setex("paste:" .. id, ttl, data)
                else
                    client:set("paste:" .. id, data)
                end
                client:set("paste:" .. id .. ":views", "0")
                if ttl > 0 then
                    client:expire("paste:" .. id .. ":views", ttl)
                end
                client:lpush("paste:recent", id)
                client:ltrim("paste:recent", 0, 49)
            end)

            local pastes = fetch_pastes(client)
            redis_client.keepalive(client)

            if save_ok then
                local host = resp.get_header(ctx, "host") or ""
                resp.html_response(ctx, "paste", {
                    pastes = pastes,
                    created = {
                        id = id,
                        url = "http://" .. host .. "/paste/" .. id,
                        raw_url = "/paste/" .. id .. "/raw",
                        ttl_label = TTL_LABELS[tostring(fields.ttl)] or nil,
                    },
                })
            else
                resp.html_response(ctx, "paste", { pastes = pastes, error_msg = "Redis error: " .. tostring(save_err) })
            end
        end,
    },

    ["/paste/{id}"] = {
        GET = function(ctx)
            local id = ctx.params.id or ""
            local data, views, fetch_err = paste_fetch(id)
            if not data then
                resp.error_response(ctx, "paste_detail", fetch_err == "Redis unavailable" and 502 or 404, fetch_err)
                return
            end
            resp.html_response(ctx, "paste_detail", {
                paste_id = id,
                paste_title = data.title or "untitled",
                paste_content = data.content or "",
                paste_views = views,
                paste_created = data.created,
            })
        end,
    },

    ["/paste/{id}/raw"] = {
        GET = function(ctx)
            local id = ctx.params.id or ""
            local data, _, fetch_err = paste_fetch(id)
            if not data then
                ctx.status = 404
                ctx.headers["Content-Type"] = "text/plain; charset=utf-8"
                ctx.body = fetch_err or "Not found"
                return
            end
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/plain; charset=utf-8"
            ctx.body = data.content or ""
        end,
    },
}
