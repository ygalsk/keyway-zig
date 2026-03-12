-- handlers.lua — Route registration for Keyway
-- Loaded independently by each worker thread at startup.

-- Module imports (top of file, before any route registration)
local template      = require("keyway.template")
local form          = require("keyway.form")
local redis_client  = require("keyway.redis")
local http_client   = require("keyway.http_client")
local pg_client     = require("keyway.postgres")
local hooks         = require("keyway.hooks")
local webhook       = require("keyway.webhook")
local dns           = require("keyway.dns")
local socket        = require("keyway.socket")
local cjson         = require("cjson")

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
template.load("db")
template.load("webhook")
template.load("scripts")

-- Helper: render a full page through the layout
local function render_page(page_name, vars)
    vars = vars or {}
    vars.worker_id = keyway.worker_id
    vars.page = page_name
    vars.content = template.render(page_name, vars)
    return template.render("layout", vars)
end

-- Helper: set ctx for an error page response
local function error_response(ctx, page, status, msg)
    ctx.status = status
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = render_page(page, { error_msg = msg })
end

-- Helper: set ctx for an HTML page response
local function html_response(ctx, page, vars)
    ctx.status = 200
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = render_page(page, vars)
end

-- Helper: JSON API response
local function json_response(ctx, status, data)
    ctx.status = status
    ctx.headers["Content-Type"] = "application/json; charset=utf-8"
    ctx.body = cjson.encode(data)
end

-- Helper: trim leading/trailing whitespace
local function trim(s) return (s:match("^%s*(.-)%s*$")) end

-- Helper: split comma-separated string into table
local function split_csv(str)
    if not str or str == "" then return {} end
    local t = {}
    for v in str:gmatch("[^,]+") do
        t[#t + 1] = trim(v)
    end
    return t
end

-- Helper: monotonic clock in microseconds (cached timespec, matches http_client.lua pattern)
local ffi = require("ffi")
local _ts = ffi.new("struct timespec")
local function now_us()
    ffi.C.clock_gettime(1, _ts) -- CLOCK_MONOTONIC
    return tonumber(_ts.tv_sec) * 1000000 + tonumber(_ts.tv_nsec) / 1000
end

-- Helper: build EVAL args table from script, keys list, and argv list
local function build_eval_args(script, keys_list, argv_list)
    local args = { script, #keys_list }
    for _, k in ipairs(keys_list) do args[#args + 1] = k end
    for _, a in ipairs(argv_list) do args[#args + 1] = a end
    return args
end

-- Helper: HTTP status class for badge coloring
local function status_class(code)
    if code >= 200 and code < 300 then return "2xx"
    elseif code >= 300 and code < 400 then return "3xx"
    else return "4xx5xx"
    end
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

            result.status_class = status_class(result.status)

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

    -- Showcase: PostgreSQL CRUD via pgmoon + cosocket (Neon hosted Postgres)
    ["/db"] = (function()
        local pg_config = {
            host     = os.getenv("PGHOST") or "localhost",
            port     = os.getenv("PGPORT") or "5432",
            user     = os.getenv("PGUSER") or "postgres",
            password = os.getenv("PGPASSWORD") or "",
            database = os.getenv("PGDATABASE") or "neondb",
        }

        local CREATE_TABLE = [[
            CREATE TABLE IF NOT EXISTS notes (
                id SERIAL PRIMARY KEY,
                author VARCHAR(100) NOT NULL DEFAULT 'anonymous',
                content TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        ]]

        local table_created = false

        local function db_connect()
            return pg_client.connect(pg_config)
        end

        -- Ensure the notes table exists (runs once per worker)
        local function ensure_table(pg)
            if table_created then return true end
            local ok, err = pg:query(CREATE_TABLE)
            if not ok then return nil, err end
            table_created = true
            return true
        end

        local function db_page(ctx, pg, vars)
            -- Fetch notes + server time in a single round-trip
            local notes_res, q_err = pg:query(
                "SELECT id, author, content, created_at, now() AS server_time FROM notes ORDER BY created_at DESC"
            )
            local reuse = pg.sock and pg.sock:getreusedtimes() or 0
            -- Grab server_time before keepalive (empty table = no notes yet)
            if not notes_res then
                vars.error_msg = "Query error: " .. (q_err or "unknown")
            elseif notes_res[1] then
                vars.server_time = notes_res[1].server_time
                vars.notes = notes_res
            else
                -- No notes yet — fetch server_time separately
                local time_res = pg:query("SELECT now() AS t")
                vars.server_time = time_res and time_res[1] and time_res[1].t
                vars.notes = notes_res
            end
            pg_client.keepalive(pg)
            vars.reuse_count = reuse

            html_response(ctx, "db", vars)
        end

        return {
            GET = function(ctx)
                local pg, err = db_connect()
                if not pg then
                    error_response(ctx, "db", 502, "Postgres error: " .. (err or "unknown"))
                    return
                end

                local ok, create_err = ensure_table(pg)
                if not ok then
                    pg_client.keepalive(pg)
                    error_response(ctx, "db", 502, "Schema error: " .. (create_err or "unknown"))
                    return
                end

                db_page(ctx, pg, {})
            end,

            POST = function(ctx)
                local fields = form.parse(ctx.body)
                local action = fields.action or ""

                local pg, err = db_connect()
                if not pg then
                    error_response(ctx, "db", 502, "Postgres error: " .. (err or "unknown"))
                    return
                end

                local ok, create_err = ensure_table(pg)
                if not ok then
                    pg_client.keepalive(pg)
                    error_response(ctx, "db", 502, "Schema error: " .. (create_err or "unknown"))
                    return
                end

                local vars = {}

                if action == "add" then
                    local author  = fields.author or ""
                    local content = fields.content or ""
                    author = trim(author)
                    content = trim(content)

                    if content == "" then
                        vars.error_msg = "Note content cannot be empty"
                    else
                        if author == "" then author = "anonymous" end
                        local q = "INSERT INTO notes (author, content) VALUES ("
                            .. pg:escape_literal(author) .. ", "
                            .. pg:escape_literal(content) .. ")"
                        local ok, q_err = pg:query(q)
                        if ok then
                            vars.result_msg = "Note added by " .. author
                        else
                            vars.error_msg = "Insert error: " .. (q_err or "unknown")
                        end
                    end
                elseif action == "delete" then
                    local id = fields.id or ""
                    if id:match("^%d+$") then
                        local ok, q_err = pg:query("DELETE FROM notes WHERE id = " .. id)
                        if ok then
                            vars.result_msg = "Note #" .. id .. " deleted"
                        else
                            vars.error_msg = "Delete error: " .. (q_err or "unknown")
                        end
                    else
                        vars.error_msg = "Invalid note ID"
                    end
                else
                    vars.error_msg = "Unknown action"
                end

                db_page(ctx, pg, vars)
            end,
        }
    end)(),

    -- Showcase: raw cosocket TLS — connect, handshake, send, receive over HTTPS
    ["/tls-test"] = {
        GET = function(ctx)
            local host = ctx.query.host or "www.google.com"
            local timings = {}

            -- 1. DNS resolve
            local t0 = now_us()
            local ip, dns_err = dns.resolve_host(host)
            timings[#timings + 1] = string.format("DNS resolve:   %d us", now_us() - t0)
            if not ip then
                ctx.status = 502
                ctx.body = "DNS failed: " .. (dns_err or "unknown")
                return
            end

            -- 2. TCP connect
            local tcp = socket.tcp()
            t0 = now_us()
            local ok, err = tcp:connect(ip, 443)
            timings[#timings + 1] = string.format("TCP connect:   %d us", now_us() - t0)
            if not ok then
                ctx.status = 502
                ctx.body = "connect failed: " .. (err or "unknown")
                return
            end

            -- 3. TLS handshake with SNI
            t0 = now_us()
            local tls_ok, tls_err = tcp:sslhandshake(nil, host)
            timings[#timings + 1] = string.format("TLS handshake: %d us", now_us() - t0)
            if not tls_ok then
                tcp:close()
                ctx.status = 502
                ctx.body = "tls handshake failed: " .. (tls_err or "unknown")
                return
            end

            -- 4. Send HTTP request
            t0 = now_us()
            tcp:send("GET / HTTP/1.1\r\nHost: " .. host .. "\r\nConnection: close\r\n\r\n")
            timings[#timings + 1] = string.format("HTTP send:     %d us", now_us() - t0)

            -- 5. Read status line + headers
            t0 = now_us()
            local status_line = tcp:receive("*l")
            local headers = {}
            while true do
                local line = tcp:receive("*l")
                if not line or line == "" then break end
                headers[#headers + 1] = line
            end
            timings[#timings + 1] = string.format("HTTP recv:     %d us", now_us() - t0)

            tcp:close()

            ctx.status = 200
            ctx.headers["Content-Type"] = "text/plain; charset=utf-8"
            ctx.body = "=== Outbound TLS Cosocket Test ===\n\n"
                .. "Target: https://" .. host .. "/\n"
                .. "Status: " .. (status_line or "(nil)") .. "\n\n"
                .. "Timings:\n" .. table.concat(timings, "\n") .. "\n\n"
                .. "Response Headers:\n" .. table.concat(headers, "\n") .. "\n"
        end,
    },

    ["/webhook"] = {
        GET = function(ctx)
            html_response(ctx, "webhook", {
                webhook_url = os.getenv("DISCORD_WEBHOOK_URL"),
            })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local message = fields.message or ""
            message = trim(message)

            local discord_url = os.getenv("DISCORD_WEBHOOK_URL")
            if not discord_url or discord_url == "" then
                html_response(ctx, "webhook", {
                    error_msg = "DISCORD_WEBHOOK_URL environment variable is not set",
                })
                return
            end

            if message == "" then
                html_response(ctx, "webhook", {
                    webhook_url = discord_url,
                    error_msg = "Message cannot be empty",
                })
                return
            end

            local result, err = webhook.discord(discord_url, message)

            if not result then
                html_response(ctx, "webhook", {
                    webhook_url = discord_url,
                    error_msg = err,
                })
                return
            end

            result.status_class = status_class(result.status)

            html_response(ctx, "webhook", {
                webhook_url = discord_url,
                result = result,
                success_msg = "Message sent to Discord",
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
            domain = trim(domain)

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

    -- Script Console — live Redis Lua scripting + saved function registry
    ["/scripts"] = (function()
        -- Fetch all saved functions from Redis (fn:* keys)
        local function list_functions(client)
            local ok, keys = pcall(function() return client:keys("fn:*") end)
            if not ok or not keys or #keys == 0 then return {} end
            table.sort(keys)
            local ok2, values = pcall(function() return client:mget(unpack(keys)) end)
            if not ok2 or not values then return {} end
            local fns = {}
            for i, key in ipairs(keys) do
                local raw = values[i]
                if raw then
                    local ok3, data = pcall(cjson.decode, raw)
                    if ok3 then
                        data.name = key:sub(4) -- strip "fn:" prefix
                        fns[#fns + 1] = data
                    end
                end
            end
            return fns
        end

        return {
            GET = function(ctx)
                local client, err = redis_client.connect()
                local functions = {}
                if client then
                    functions = list_functions(client)
                    redis_client.keepalive(client)
                end
                html_response(ctx, "scripts", { functions = functions })
            end,

            POST = function(ctx)
                local fields = form.parse(ctx.body)
                local action = fields.action or ""

                local client, conn_err = redis_client.connect()
                if not client then
                    error_response(ctx, "scripts", 502, "Redis error: " .. (conn_err or "unknown"))
                    return
                end

                local vars = {}

                if action == "eval" then
                    local script = fields.script or ""
                    local keys_list = split_csv(fields.keys_input)
                    local argv_list = split_csv(fields.argv_input)

                    local t0 = now_us()
                    local eval_args = build_eval_args(script, keys_list, argv_list)

                    local ok, result = pcall(function()
                        return client:eval(unpack(eval_args))
                    end)
                    local elapsed = math.floor(now_us() - t0)

                    if ok then
                        -- Format result for display
                        local display
                        if type(result) == "table" then
                            display = cjson.encode(result)
                        else
                            display = tostring(result)
                        end
                        vars.eval_result = display
                        vars.eval_time_us = elapsed
                    else
                        vars.eval_error = tostring(result)
                    end

                    -- Preserve editor state
                    vars.script_body = script
                    vars.script_name = fields.name
                    vars.script_description = fields.description
                    vars.keys_input = fields.keys_input
                    vars.argv_input = fields.argv_input

                elseif action == "save" then
                    local name = trim(fields.name or "")
                    local script = fields.script or ""

                    if not name:match("^[%w_%-]+$") then
                        vars.error_msg = "Invalid name — use letters, numbers, hyphens, underscores only"
                    elseif script == "" then
                        vars.error_msg = "Script cannot be empty"
                    else
                        local now = os.time()
                        -- Check if it already exists (preserve created_at)
                        local existing_raw = client:get("fn:" .. name)
                        local created_at = now
                        if existing_raw then
                            local ok2, existing = pcall(cjson.decode, existing_raw)
                            if ok2 and existing.created_at then
                                created_at = existing.created_at
                            end
                        end

                        local data = cjson.encode({
                            script = script,
                            description = fields.description or "",
                            created_at = created_at,
                            updated_at = now,
                        })
                        local ok, err = pcall(function() client:set("fn:" .. name, data) end)
                        if ok then
                            vars.success_msg = "Saved as /fn/" .. name
                        else
                            vars.error_msg = "Save failed: " .. tostring(err)
                        end
                    end

                    -- Preserve editor state
                    vars.script_body = fields.script
                    vars.script_name = fields.name
                    vars.script_description = fields.description
                    vars.keys_input = fields.keys_input
                    vars.argv_input = fields.argv_input

                elseif action == "load" then
                    local name = fields.name or ""
                    local raw = client:get("fn:" .. name)
                    if raw then
                        local ok, data = pcall(cjson.decode, raw)
                        if ok then
                            vars.script_name = name
                            vars.script_body = data.script
                            vars.script_description = data.description or ""
                        end
                    end

                elseif action == "delete" then
                    local name = fields.name or ""
                    if name ~= "" then
                        pcall(function() client:del("fn:" .. name) end)
                        vars.success_msg = "Deleted " .. name
                    end
                end

                vars.functions = list_functions(client)
                redis_client.keepalive(client)
                html_response(ctx, "scripts", vars)
            end,
        }
    end)(),

    -- Dynamic function endpoints — execute saved Redis Lua scripts via HTTP
    ["/fn/{name}"] = (function()
        local function exec_fn(ctx)
            local name = ctx.params.name or ""

            local client, conn_err = redis_client.connect()
            if not client then
                json_response(ctx, 502, { error = "Redis error: " .. (conn_err or "unknown") })
                return
            end

            local raw = client:get("fn:" .. name)
            if not raw then
                redis_client.keepalive(client)
                json_response(ctx, 404, { error = "Function not found: " .. name })
                return
            end

            local ok, data = pcall(cjson.decode, raw)
            if not ok then
                redis_client.keepalive(client)
                json_response(ctx, 500, { error = "Corrupt function data" })
                return
            end

            -- Parse keys/argv from query params or form body
            local keys_str, argv_str
            if ctx.method == "POST" then
                local fields = form.parse(ctx.body)
                keys_str = fields.keys or ""
                argv_str = fields.argv or ""
            else
                keys_str = ctx.query.keys or ""
                argv_str = ctx.query.argv or ""
            end
            local keys_list = split_csv(keys_str)
            local argv_list = split_csv(argv_str)

            local eval_args = build_eval_args(data.script, keys_list, argv_list)

            local t0 = now_us()
            local eval_ok, result = pcall(function()
                return client:eval(unpack(eval_args))
            end)
            local elapsed = math.floor(now_us() - t0)
            redis_client.keepalive(client)

            if eval_ok then
                json_response(ctx, 200, { result = result, time_us = elapsed })
            else
                json_response(ctx, 500, { error = tostring(result), time_us = elapsed })
            end
        end

        return {
            GET  = exec_fn,
            POST = exec_fn,
        }
    end)(),
}
