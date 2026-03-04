-- handlers.lua — Route registration for Keyway
-- Loaded independently by each worker thread at startup.

-- Module imports (top of file, before any route registration)
local styles        = require("keyway.styles")
local template      = require("keyway.template")
local form          = require("keyway.form")
local redis_client  = require("keyway.redis")
local http_client   = require("keyway.http_client")

-- Load templates once at startup (each worker independently)
template.load("layout")
template.load("home")
template.load("kv")
template.load("probe")

-- Helper: render a full page through the layout
local function render_page(page_name, vars)
    vars = vars or {}
    vars.worker_id = keyway.worker_id
    vars.page = page_name
    vars.content = template.render(page_name, vars)
    return template.render("layout", vars)
end

-- Helper: fetch all keys from Redis, returns sorted table or nil + error
local function redis_keys()
    local client, err = redis_client.connect()
    if not client then
        return nil, err
    end

    local ok, keys = pcall(function() return client:keys("*") end)
    redis_client.keepalive(client)

    if not ok then
        return nil, tostring(keys)
    end

    -- keys may be nil or empty table
    if keys and #keys > 0 then
        table.sort(keys)
    end
    return keys or {}
end

-- Route table
keyway.routes = {
    ["/style.css"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/css; charset=utf-8"
            ctx.headers["Cache-Control"] = "public, max-age=86400"
            ctx.body = styles.css
        end,
    },

    ["/"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("home", {})
        end,
    },

    ["/echo"] = {
        POST = function(ctx)
            local fields = form.parse(ctx.body or "")
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("home", {
                echo_fields = fields,
                success_msg = "Form parsed successfully",
            })
        end,
    },

    ["/kv"] = {
        GET = function(ctx)
            local keys, err = redis_keys()
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("kv", {
                keys = keys,
                error_msg = err,
            })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body or "")
            local action = fields.action or ""
            local key    = fields.key or ""
            local value  = fields.value or ""

            local result = nil
            local err_msg = nil

            if key == "" then
                err_msg = "Key cannot be empty"
            else
                local client, conn_err = redis_client.connect()
                if not client then
                    err_msg = conn_err
                else
                    local ok, res = pcall(function()
                        if action == "set" then
                            client:set(key, value)
                            return { action = "set", key = key, display_value = value }
                        elseif action == "get" then
                            local val = client:get(key)
                            return { action = "get", key = key, value = val }
                        elseif action == "del" then
                            local count = client:del(key)
                            return { action = "del", key = key, count = count }
                        else
                            return nil
                        end
                    end)
                    redis_client.keepalive(client)

                    if ok then
                        result = res
                    else
                        err_msg = "Redis error: " .. tostring(res)
                    end
                end
            end

            -- Always refresh key list
            local keys, keys_err = redis_keys()
            if not keys and not err_msg then
                err_msg = keys_err
            end

            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("kv", {
                keys = keys,
                result = result,
                error_msg = err_msg,
                success_msg = (result and not err_msg) and "Operation completed" or nil,
            })
        end,
    },

    ["/probe"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("probe", {})
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body or "")
            local url    = fields.url or ""

            if url == "" then
                ctx.status = 200
                ctx.headers["Content-Type"] = "text/html; charset=utf-8"
                ctx.body = render_page("probe", { error_msg = "URL is required" })
                return
            end

            local result, err = http_client.probe(url)

            if not result then
                ctx.status = 200
                ctx.headers["Content-Type"] = "text/html; charset=utf-8"
                ctx.body = render_page("probe", { url = url, error_msg = err })
                return
            end

            -- Determine status class for badge coloring
            local s = result.status
            result.status_class = (s >= 200 and s < 300) and "2xx"
                               or (s >= 300 and s < 400) and "3xx"
                               or "4xx5xx"

            ctx.status = 200
            ctx.headers["Content-Type"] = "text/html; charset=utf-8"
            ctx.body = render_page("probe", { url = url, result = result })
        end,
    },
}
