-- handlers.lua — Route registration for Keyway
-- Loaded independently by each worker thread at startup.

-- Module imports (top of file, before any route registration)
local template      = require("keyway.template")
local form          = require("keyway.form")
local redis_client  = require("keyway.redis")
local http_client   = require("keyway.http_client")
local hooks         = require("keyway.hooks")
local dns           = require("keyway.dns")

-- Load static CSS once at startup (each worker independently)
local css_file = assert(io.open("scripts/static/style.css", "r"))
local css_content = css_file:read("*a")
css_file:close()

-- Load templates once at startup (each worker independently)
template.load("layout")
template.load("home")
template.load("kv")
template.load("probe")
template.load("hooks")
template.load("hook_detail")
template.load("dns")

-- Helper: render a full page through the layout
local function render_page(page_name, vars)
    vars = vars or {}
    vars.worker_id = keyway.worker_id
    vars.page = page_name
    vars.content = template.render(page_name, vars)
    return template.render("layout", vars)
end

-- Helper: set ctx for an HTML page response
local function html_response(ctx, page, vars)
    ctx.status = 200
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = render_page(page, vars)
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
            ctx.body = css_content
        end,
    },

    ["/"] = {
        GET = function(ctx)
            html_response(ctx, "home", {})
        end,
    },

    ["/kv"] = {
        GET = function(ctx)
            local keys, err = redis_keys()
            html_response(ctx, "kv", {
                keys = keys,
                error_msg = err,
            })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local action = fields.action or ""
            local key    = fields.key or ""
            local value  = fields.value or ""

            local result
            local err_msg

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

            html_response(ctx, "kv", {
                keys = keys,
                result = result,
                error_msg = err_msg,
                success_msg = (result and not err_msg) and "Operation completed",
            })
        end,
    },

    ["/probe"] = {
        GET = function(ctx)
            html_response(ctx, "probe", {})
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local url    = fields.url or ""

            if url == "" then
                html_response(ctx, "probe", { error_msg = "URL is required" })
                return
            end

            local result, err = http_client.probe(url)

            if not result then
                html_response(ctx, "probe", { url = url, error_msg = err })
                return
            end

            -- Determine status class for badge coloring
            local s = result.status
            result.status_class = (s >= 200 and s < 300) and "2xx"
                               or (s >= 300 and s < 400) and "3xx"
                               or "4xx5xx"

            html_response(ctx, "probe", { url = url, result = result })
        end,
    },

    -- Webhook catch endpoint — accepts any HTTP method, stores request in Redis
    ["/h/{id}"] = (function()
        local function capture(ctx)
            local id   = ctx.params.id or ""
            local data = {
                method    = ctx.method or "",
                path      = ctx.path or "",
                headers   = ctx.request_headers,
                body      = ctx.body or "",
                timestamp = os.time(),
            }
            local client = redis_client.connect()
            if client then
                hooks.capture(client, id, data)
                redis_client.keepalive(client)
            end
            ctx.status = 200
            ctx.headers["Content-Type"] = "text/plain; charset=utf-8"
            ctx.body = "OK"
        end
        return {
            GET    = capture,
            POST   = capture,
            PUT    = capture,
            DELETE = capture,
            PATCH  = capture,
            HEAD   = capture,
        }
    end)(),

    ["/hooks"] = {
        GET = function(ctx)
            html_response(ctx, "hooks", {})
        end,

        POST = function(ctx)
            local id = hooks.generate_id()
            local client, err = redis_client.connect()
            local created = false
            if client then
                hooks.create(client, id)
                redis_client.keepalive(client)
                created = true
            end
            html_response(ctx, "hooks", {
                new_id    = created and id,
                error_msg = not created and ("Redis error: " .. (err or "unknown")),
            })
        end,
    },

    ["/hooks/{id}"] = {
        GET = function(ctx)
            local id = ctx.params.id or ""
            local client, err = redis_client.connect()
            if not client then
                html_response(ctx, "hook_detail", {
                    hook_id   = id,
                    requests  = {},
                    error_msg = "Redis error: " .. (err or "unknown"),
                })
                return
            end
            local exists   = hooks.exists(client, id)
            local requests = hooks.list_requests(client, id)
            redis_client.keepalive(client)

            for _, r in ipairs(requests) do
                r.timestamp_str = os.date("!%Y-%m-%dT%H:%M:%SZ", r.timestamp)
            end

            html_response(ctx, "hook_detail", {
                hook_id   = id,
                requests  = requests,
                error_msg = not exists and "Webhook not found",
            })
        end,
    },

    ["/dns"] = {
        GET = function(ctx)
            html_response(ctx, "dns", {})
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local domain = fields.domain or ""
            domain = domain:match("^%s*(.-)%s*$")

            if domain == "" then
                html_response(ctx, "dns", { error_msg = "Domain is required" })
                return
            end

            local records, err = dns.lookup(domain)

            if records then
                html_response(ctx, "dns", { domain = domain, records = records })
            else
                html_response(ctx, "dns", { domain = domain, error_msg = err })
            end
        end,
    },
}
