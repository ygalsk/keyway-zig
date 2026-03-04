-- Keyway Handlers
-- Uses organic HttpExchange API - ctx is a single Zig struct with declarative interface
if jit then
    jit.opt.start(
        "maxtrace=10000",      -- Allow more traces (default: 1000)
        "maxrecord=20000",     -- Allow longer traces (default: 4000)
        "maxirconst=10000",    -- More IR constants (default: 500)
        "maxmcode=4096",       -- Bigger machine code cache in KB (default: 512)
        "maxsnap=1000",        -- More snapshots (default: 500)
        "hotexit=10",          -- Lower hotness threshold (default: 56)
        "hotloop=40",          -- Lower loop hotness (default: 56)
        "tryside=4"            -- Trace side exits (default: 4)

    )
    collectgarbage("setpause", 100)
    collectgarbage("setstepmul", 500)
end

-- Module-level state (per-worker, no sharing)
local request_count = 0
local start_time = os.time()

-- ── Dependencies ─────────────────────────────────────────────────────────────
local cjson = require("cjson")
cjson.encode_sparse_array(true)

-- ── Static file loader ──────────────────────────────────────────────────────
local function read_file(path)
    local f = io.open(path, "r")
    if not f then error("missing: " .. path) end
    local content = f:read("*a")
    f:close()
    return content
end

local landing_page = read_file("scripts/static/landing.html")

-- ── Helper: escape a string for HTML output ─────────────────────────────────
local function html_escape(s)
    if not s then return "" end
    return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'):gsub("'", '&#39;'))
end

-- ── Helper: JSON response shorthand ─────────────────────────────────────────
local function json_response(ctx, status, tbl)
    ctx.status = status
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = cjson.encode(tbl)
end

-- ── Helper: pretty-print JSON for playground display ────────────────────────
local function json_pretty(s)
    if not s or s == "" then return s end
    local ok, tbl = pcall(cjson.decode, s)
    if not ok then return s end
    -- Re-encode with manual indentation
    local function indent_json(val, depth)
        depth = depth or 0
        local pad = string.rep("  ", depth)
        local pad1 = string.rep("  ", depth + 1)
        local t = type(val)
        if t == "table" then
            -- Check if array (sequential integer keys)
            local is_array = (#val > 0)
            if is_array then
                local parts = {}
                for i = 1, #val do
                    parts[i] = pad1 .. indent_json(val[i], depth + 1)
                end
                return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
            else
                local parts = {}
                for k, v in pairs(val) do
                    parts[#parts + 1] = pad1 .. '"' .. tostring(k) .. '": ' .. indent_json(v, depth + 1)
                end
                if #parts == 0 then return "{}" end
                return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
            end
        elseif t == "string" then
            return cjson.encode(val)
        elseif t == "boolean" then
            return val and "true" or "false"
        elseif val == cjson.null then
            return "null"
        else
            return tostring(val)
        end
    end
    return indent_json(tbl, 0)
end

-- ── Helper: URL percent-decode ───────────────────────────────────────────────
local function url_decode(s)
    if not s then return "" end
    return s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

-- ── Helper: parse URL-encoded form body ─────────────────────────────────────
local function parse_form_body(body)
    local params = {}
    if not body or body == "" then return params end
    for pair in body:gmatch("[^&]+") do
        local key, val = pair:match("^([^=]+)=?(.*)")
        if key then
            params[url_decode(key)] = url_decode(val or "")
        end
    end
    return params
end

-- ── Cosocket helpers (loaded before route table) ────────────────────────────
require("keyway.ngx_shim")  -- must be before pgmoon (sets ngx global)
local pgmoon = require("pgmoon")

local PG_CONFIG = {
    host = "127.0.0.1", port = 5432,
    database = "keyway_demo", user = "dkremer",
}

local function pg_connect()
    local pg = pgmoon.new(PG_CONFIG)
    local ok, err = pg:connect()
    if not ok then return nil, err end
    return pg
end

-- ── Named handler functions ─────────────────────────────────────────────────
-- (referenced in route table AND playground dispatch)

local function handle_landing(ctx)
    ctx.status = 200
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = landing_page
end

local function handle_ping(ctx)
    ctx.status = 200
    ctx.body = "pong"
end

local function handle_health(ctx)
    json_response(ctx, 200, { status = "ok", engine = "keyway", runtime = "luajit" })
end

local function handle_users_get(ctx)
    local pg, err = pg_connect()
    if not pg then
        json_response(ctx, 503, { error = "db_unavailable", message = err or "unknown" })
        return
    end

    local res, query_err = pg:query("SELECT id, name, role FROM users ORDER BY id")
    pg:keepalive()

    if not res then
        json_response(ctx, 503, { error = "query_failed", message = query_err or "unknown" })
        return
    end

    local users = {}
    for i = 1, #res do
        local row = res[i]
        users[i] = { id = tonumber(row.id), name = row.name, role = row.role }
    end

    json_response(ctx, 200, users)
end

local function handle_users_post(ctx)
    local body = ctx.body or ""

    -- Parse JSON body with cjson
    local ok, data = pcall(cjson.decode, body)
    if not ok then data = {} end

    local name = data.name
    local role = data.role or "guest"

    if not name or name == "" then
        json_response(ctx, 400, { error = "bad_request", message = "name is required" })
        return
    end

    local pg, err = pg_connect()
    if not pg then
        json_response(ctx, 503, { error = "db_unavailable", message = err or "unknown" })
        return
    end

    local res, query_err = pg:query(
        "INSERT INTO users (name, role) VALUES ("
        .. pg:escape_literal(name) .. ", "
        .. pg:escape_literal(role)
        .. ") RETURNING id, name, role"
    )
    pg:keepalive()

    if not res or #res == 0 then
        json_response(ctx, 503, { error = "insert_failed", message = query_err or "unknown" })
        return
    end

    local row = res[1]
    ctx.status = 201
    ctx.headers["Location"] = "/users/" .. tostring(row.id)
    json_response(ctx, 201, { id = tonumber(row.id), name = row.name, role = row.role })
end

local function handle_user_by_id(ctx)
    local id = ctx.params.id
    local num_id = tonumber(id)
    if not num_id then
        json_response(ctx, 400, { error = "bad_request", message = "id must be a number" })
        return
    end

    local pg, err = pg_connect()
    if not pg then
        json_response(ctx, 503, { error = "db_unavailable", message = err or "unknown" })
        return
    end

    local res, query_err = pg:query(
        "SELECT id, name, role FROM users WHERE id = "
        .. pg:escape_literal(tostring(num_id))
    )
    pg:keepalive()

    if not res then
        json_response(ctx, 503, { error = "query_failed", message = query_err or "unknown" })
        return
    end

    if #res == 0 then
        json_response(ctx, 404, { error = "not_found", message = "user " .. tostring(num_id) .. " not found" })
        return
    end

    local row = res[1]
    json_response(ctx, 200, { id = tonumber(row.id), name = row.name, role = row.role })
end

local function handle_echo(ctx)
    ctx.status = 200
    ctx.body = ctx.params.message
end

local function handle_stats(ctx)
    local uptime = os.time() - start_time
    json_response(ctx, 200, {
        requests = request_count,
        uptime_seconds = uptime,
        worker = "per-core-isolated",
    })
end

local function handle_headers(ctx)
    local known = {
        "Host", "User-Agent", "Accept", "Content-Type",
        "Authorization", "X-Custom-Header", "X-Request-Id",
        "X-Forwarded-For", "Origin", "Referer"
    }
    local received = {}
    for _, name in ipairs(known) do
        local val = ctx.headers[name]
        if val then received[name] = val end
    end
    ctx.headers["X-Powered-By"] = "keyway/zig+luajit"
    ctx.headers["X-Worker"] = "per-core-isolated"
    json_response(ctx, 200, { received_headers = received })
end

local function handle_middleware_demo(ctx)
    local auth = ctx.headers["Authorization"]
    local authed = auth and auth == "Bearer keyway-demo-token"
    local auth_step = authed and "auth-ok" or "auth-pass"
    local trace = "timing > " .. auth_step .. " > handler"
    ctx.headers["X-Middleware-Trace"] = trace
    json_response(ctx, 200, {
        message = "Middleware demo complete",
        authenticated = authed,
        middleware_chain = trace,
    })
end

local function handle_inspect(ctx)
    local body = ctx.body or ""
    json_response(ctx, 200, {
        method = ctx.method,
        path = ctx.path,
        host = ctx.headers["Host"] or "",
        user_agent = ctx.headers["User-Agent"] or "",
        accept = ctx.headers["Accept"] or "",
        content_type = ctx.headers["Content-Type"] or "",
        body_length = #body,
        body_preview = body:sub(1, 200),
    })
end

local function handle_error(ctx)
    json_response(ctx, 500, {
        error = "intentional_error",
        message = "This is a deliberate 500 response for testing error handling in the playground.",
    })
end

-- ── Playground: Shared helpers ───────────────────────────────────────────────

local MOCK_BROWSER_HEADERS = {
    Host = "localhost:8080",
    ["User-Agent"] = "Keyway-Playground/1.0",
    Accept = "application/json, text/plain, */*",
}

local function mock_headers(extra)
    local h = { Host = "localhost:8080", ["User-Agent"] = "Keyway-Playground/1.0", Accept = "application/json" }
    if extra then for k, v in pairs(extra) do h[k] = v end end
    return h
end

local function reject_unauthorized(ctx)
    ctx.status = 401
    ctx.headers["Content-Type"] = "application/json"
    ctx.headers["X-Middleware-Trace"] = "timing > auth-rejected (short-circuit)"
    ctx.body = cjson.encode({
        error = "unauthorized",
        message = "Invalid bearer token. Expected: Bearer keyway-demo-token",
        middleware_chain = "timing > auth-rejected (short-circuit)",
    })
end

-- ── Playground: Internal dispatch ───────────────────────────────────────────

local function make_mock_ctx(method, path, opts)
    return {
        method = method,
        path = path,
        headers = (opts and opts.headers) or {},
        body = (opts and opts.body) or "",
        params = (opts and opts.params) or {},
        status = 200,
    }
end

local playground_actions = {
    ["get-ping"]     = { method = "GET",  path = "/ping",              handler = handle_ping },
    ["get-health"]   = { method = "GET",  path = "/health",            handler = handle_health },
    ["get-users"]    = { method = "GET",  path = "/users",             handler = handle_users_get },
    ["get-stats"]    = { method = "GET",  path = "/api/stats",         handler = handle_stats },
    ["get-user"]     = { method = "GET",  path = "/users/{id}",        handler = handle_user_by_id },
    ["get-echo"]     = { method = "GET",  path = "/echo/{message}",    handler = handle_echo },
    ["post-users"]   = { method = "POST", path = "/users",             handler = handle_users_post },
    ["get-404"]      = { method = "GET",  path = "/users/999999",      handler = handle_user_by_id },
    ["get-error"]    = { method = "GET",  path = "/api/error",         handler = handle_error },
    ["get-headers"]  = { method = "GET",  path = "/api/headers",       handler = handle_headers },
    ["get-mw-none"]  = { method = "GET",  path = "/api/middleware-demo", handler = handle_middleware_demo },
    ["get-mw-ok"]    = { method = "GET",  path = "/api/middleware-demo", handler = handle_middleware_demo },
    ["get-mw-bad"]   = { method = "GET",  path = "/api/middleware-demo", handler = handle_middleware_demo },
    ["get-inspect"]  = { method = "GET",  path = "/api/inspect",       handler = handle_inspect },
    ["post-inspect"] = { method = "POST", path = "/api/inspect",       handler = handle_inspect },
}

-- ── Playground: HTML renderer ───────────────────────────────────────────────

local function render_status_badge(status)
    local cls = "status-2xx"
    if status >= 500 then cls = "status-5xx"
    elseif status >= 400 then cls = "status-4xx" end
    return '<span class="status-badge ' .. cls .. '">' .. tostring(status) .. '</span>'
end

local function render_response_section(mock_ctx)
    if not mock_ctx then return "" end

    -- Pretty-format JSON body, plain text otherwise
    local body = mock_ctx.body or ""
    local pretty = json_pretty(body)
    local display_body = html_escape(pretty)

    -- Build response headers display
    local hdrs = ""
    if mock_ctx.headers then
        local hdr_parts = {}
        for k, v in pairs(mock_ctx.headers) do
            hdr_parts[#hdr_parts + 1] = '<div><span class="h-name">'
                .. html_escape(tostring(k)) .. '</span>: ' .. html_escape(tostring(v)) .. '</div>'
        end
        if #hdr_parts > 0 then
            hdrs = '<div class="response-headers">' .. table.concat(hdr_parts) .. '</div>'
        end
    end

    return '<div class="response-viewer">'
        .. '<div class="response-header">'
        .. render_status_badge(mock_ctx.status)
        .. '<span class="response-method">' .. html_escape(mock_ctx._method_label or "") .. '</span>'
        .. '</div>'
        .. hdrs
        .. '<div class="response-body"><pre>' .. display_body .. '</pre></div>'
        .. '</div>'
end

local function render_playground(active_tab, action_result)
    active_tab = active_tab or "get"

    local function tab_class(name)
        return name == active_tab and 'tab-btn active' or 'tab-btn'
    end
    local function panel_class(name)
        return name == active_tab and 'tab-panel active' or 'tab-panel'
    end
    local function tab_link(name, label)
        return '<a href="/playground?tab=' .. name .. '" class="' .. tab_class(name) .. '">' .. label .. '</a>'
    end

    -- Response section (only shown if an action was dispatched)
    local response_html = ""
    if action_result then
        response_html = render_response_section(action_result)
    end

    local parts = {}
    parts[#parts + 1] = [[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Keyway - API Playground</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --kiwi-green: #73B44C;
      --kiwi-green-dark: #5A9138;
      --kiwi-green-light: #9CCC65;
      --kiwi-lime: #BFD85F;
      --kiwi-lime-light: #D4E78E;
      --kiwi-brown: #5C4033;
      --kiwi-cream: #FAFADC;
      --kiwi-cream-dark: #F5F5DC;
      --kiwi-seed: #2C2C2C;
      --kiwi-seed-light: #4A4A4A;
      --kiwi-white: #FFFFFF;
      --kiwi-border: #E5E7EB;
    }

    body {
      background: var(--kiwi-white);
      color: var(--kiwi-seed);
      font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', sans-serif;
      line-height: 1.5;
      min-height: 100vh;
    }

    a { color: var(--kiwi-green-dark); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code, pre { font-family: 'JetBrains Mono', 'Fira Code', 'Consolas', monospace; }

    .container {
      max-width: 860px;
      margin: 0 auto;
      padding: 0 1.5rem;
    }

    header {
      padding: 1.5rem 0;
      border-bottom: 1px solid var(--kiwi-border);
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    header h1 {
      font-size: 1.25rem;
      font-weight: 700;
      color: var(--kiwi-seed);
    }

    header h1 span {
      color: var(--kiwi-seed-light);
      font-weight: 400;
    }

    header a {
      font-size: 0.9rem;
      color: var(--kiwi-seed-light);
    }

    .tabs {
      display: flex;
      flex-wrap: wrap;
      gap: 0.25rem;
      padding: 1.25rem 0 0.75rem;
      border-bottom: 1px solid var(--kiwi-border);
    }

    .tab-btn {
      display: inline-block;
      background: none;
      border: 1px solid transparent;
      border-radius: 0.375rem;
      padding: 0.4rem 0.75rem;
      font-size: 0.85rem;
      color: var(--kiwi-seed-light);
      font-family: inherit;
      transition: all 150ms ease;
    }
    .tab-btn:hover { color: var(--kiwi-seed); background: var(--kiwi-cream); text-decoration: none; }
    .tab-btn.active {
      color: var(--kiwi-green-dark);
      background: var(--kiwi-cream);
      border-color: var(--kiwi-border);
      font-weight: 500;
    }

    .tab-panel { display: none; padding: 1.25rem 0; }
    .tab-panel.active { display: block; }

    .btn-row { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 1rem; }

    .btn {
      display: inline-block;
      background: var(--kiwi-white);
      border: 1px solid var(--kiwi-border);
      border-radius: 0.375rem;
      padding: 0.4rem 0.85rem;
      font-size: 0.85rem;
      color: var(--kiwi-seed);
      font-family: 'JetBrains Mono', monospace;
      transition: all 150ms ease;
      cursor: pointer;
    }
    .btn:hover { border-color: var(--kiwi-green); color: var(--kiwi-green-dark); text-decoration: none; }

    .btn.primary {
      background: var(--kiwi-green);
      border-color: var(--kiwi-green);
      color: var(--kiwi-white);
    }
    .btn.primary:hover { background: var(--kiwi-green-dark); border-color: var(--kiwi-green-dark); text-decoration: none; }

    .input-row {
      display: flex;
      gap: 0.5rem;
      margin-bottom: 1rem;
      align-items: center;
    }

    .input-row label {
      color: var(--kiwi-seed-light);
      font-size: 0.85rem;
      font-family: 'JetBrains Mono', monospace;
      white-space: nowrap;
    }

    .input-row input, textarea.body-input {
      background: var(--kiwi-white);
      border: 1px solid var(--kiwi-border);
      border-radius: 0.375rem;
      padding: 0.4rem 0.75rem;
      font-size: 0.85rem;
      color: var(--kiwi-seed);
      font-family: 'JetBrains Mono', monospace;
    }
    .input-row input { flex: 1; }
    textarea.body-input {
      width: 100%;
      min-height: 60px;
      resize: vertical;
      margin-bottom: 0.75rem;
    }

    .response-viewer {
      background: var(--kiwi-cream);
      border: 1px solid var(--kiwi-border);
      border-radius: 0.5rem;
      overflow: hidden;
      margin-top: 0.75rem;
    }

    .response-header {
      display: flex;
      align-items: center;
      gap: 0.75rem;
      padding: 0.6rem 1rem;
      border-bottom: 1px solid var(--kiwi-border);
      font-size: 0.8rem;
      background: var(--kiwi-white);
    }

    .response-method {
      color: var(--kiwi-seed-light);
      font-family: 'JetBrains Mono', monospace;
      font-size: 0.75rem;
    }

    .status-badge {
      padding: 0.15rem 0.5rem;
      border-radius: 0.25rem;
      font-family: 'JetBrains Mono', monospace;
      font-weight: 700;
      font-size: 0.75rem;
    }
    .status-2xx { background: #dcfce7; color: #166534; }
    .status-4xx { background: #fef9c3; color: #854d0e; }
    .status-5xx { background: #fee2e2; color: #991b1b; }

    .response-headers {
      padding: 0.5rem 1rem;
      border-bottom: 1px solid var(--kiwi-border);
      font-size: 0.75rem;
      color: var(--kiwi-seed-light);
      font-family: 'JetBrains Mono', monospace;
      max-height: 100px;
      overflow-y: auto;
    }
    .response-headers div { padding: 0.1rem 0; }
    .response-headers .h-name { color: var(--kiwi-green-dark); }

    .response-body {
      padding: 1rem;
      font-size: 0.85rem;
      font-family: 'JetBrains Mono', monospace;
      overflow-x: auto;
      max-height: 400px;
      overflow-y: auto;
      color: var(--kiwi-seed);
    }

    .response-body pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
    }

    .note {
      color: var(--kiwi-seed-light);
      font-size: 0.85rem;
      margin-bottom: 1rem;
      line-height: 1.6;
    }

    footer {
      padding: 2rem 0;
      border-top: 1px solid var(--kiwi-border);
      text-align: center;
      font-size: 0.85rem;
      color: var(--kiwi-seed-light);
      margin-top: 2rem;
    }
    footer a { color: var(--kiwi-seed-light); }
    footer a:hover { color: var(--kiwi-green-dark); }

    @media (max-width: 600px) {
      .input-row { flex-direction: column; align-items: stretch; }
      .input-row label { margin-bottom: 0.25rem; }
    }
  </style>
</head>
<body>
  <div class="container">

    <header>
      <h1>Keyway <span>/ Playground</span></h1>
      <a href="/">&larr; Back to home</a>
    </header>

    <div class="tabs">]]

    -- Tab navigation
    parts[#parts + 1] = tab_link("get", "GET Requests")
    parts[#parts + 1] = tab_link("params", "Path Params")
    parts[#parts + 1] = tab_link("post", "POST &amp; Status")
    parts[#parts + 1] = tab_link("headers", "Headers")
    parts[#parts + 1] = tab_link("middleware", "Middleware")
    parts[#parts + 1] = tab_link("inspect", "Introspection")

    parts[#parts + 1] = '</div>'

    -- GET tab
    parts[#parts + 1] = '<div class="' .. panel_class("get") .. '" id="tab-get">'
    parts[#parts + 1] = '<div class="btn-row">'
    parts[#parts + 1] = '<a href="/playground?tab=get&action=get-ping" class="btn">GET /ping</a>'
    parts[#parts + 1] = '<a href="/playground?tab=get&action=get-health" class="btn">GET /health</a>'
    parts[#parts + 1] = '<a href="/playground?tab=get&action=get-users" class="btn">GET /users</a>'
    parts[#parts + 1] = '<a href="/playground?tab=get&action=get-stats" class="btn">GET /api/stats</a>'
    parts[#parts + 1] = '</div>'
    if active_tab == "get" then parts[#parts + 1] = response_html end
    parts[#parts + 1] = '</div>'

    -- Params tab
    parts[#parts + 1] = '<div class="' .. panel_class("params") .. '" id="tab-params">'
    -- User by ID form
    local param_id_val = action_result and action_result._input_id or "42"
    parts[#parts + 1] = '<form action="/playground" method="GET">'
    parts[#parts + 1] = '<input type="hidden" name="tab" value="params">'
    parts[#parts + 1] = '<input type="hidden" name="action" value="get-user">'
    parts[#parts + 1] = '<div class="input-row">'
    parts[#parts + 1] = '<label>GET /users/</label>'
    parts[#parts + 1] = '<input type="text" name="id" value="' .. html_escape(param_id_val) .. '" placeholder="id" style="max-width:100px">'
    parts[#parts + 1] = '<button type="submit" class="btn primary">Send</button>'
    parts[#parts + 1] = '</div></form>'
    -- Echo form
    local param_msg_val = action_result and action_result._input_msg or "hello-keyway"
    parts[#parts + 1] = '<form action="/playground" method="GET">'
    parts[#parts + 1] = '<input type="hidden" name="tab" value="params">'
    parts[#parts + 1] = '<input type="hidden" name="action" value="get-echo">'
    parts[#parts + 1] = '<div class="input-row">'
    parts[#parts + 1] = '<label>GET /echo/</label>'
    parts[#parts + 1] = '<input type="text" name="id" value="' .. html_escape(param_msg_val) .. '" placeholder="message">'
    parts[#parts + 1] = '<button type="submit" class="btn primary">Send</button>'
    parts[#parts + 1] = '</div></form>'
    if active_tab == "params" then parts[#parts + 1] = response_html end
    parts[#parts + 1] = '</div>'

    -- POST & Status tab
    parts[#parts + 1] = '<div class="' .. panel_class("post") .. '" id="tab-post">'
    local post_body_val = action_result and action_result._input_body or '{"name":"Charlie","role":"editor"}'
    parts[#parts + 1] = '<form action="/playground" method="POST">'
    parts[#parts + 1] = '<input type="hidden" name="tab" value="post">'
    parts[#parts + 1] = '<input type="hidden" name="action" value="post-users">'
    parts[#parts + 1] = '<textarea class="body-input" name="post_body">' .. html_escape(post_body_val) .. '</textarea>'
    parts[#parts + 1] = '<div class="btn-row">'
    parts[#parts + 1] = '<button type="submit" class="btn primary">POST /users</button>'
    parts[#parts + 1] = '</div></form>'
    parts[#parts + 1] = '<div class="btn-row">'
    parts[#parts + 1] = '<a href="/playground?tab=post&action=get-404" class="btn">404 Demo</a>'
    parts[#parts + 1] = '<a href="/playground?tab=post&action=get-error" class="btn">500 Demo</a>'
    parts[#parts + 1] = '</div>'
    if active_tab == "post" then parts[#parts + 1] = response_html end
    parts[#parts + 1] = '</div>'

    -- Headers tab
    parts[#parts + 1] = '<div class="' .. panel_class("headers") .. '" id="tab-headers">'
    parts[#parts + 1] = '<div class="btn-row">'
    parts[#parts + 1] = '<a href="/playground?tab=headers&action=get-headers" class="btn primary">Send to /api/headers</a>'
    parts[#parts + 1] = '</div>'
    if active_tab == "headers" then parts[#parts + 1] = response_html end
    parts[#parts + 1] = '</div>'

    -- Middleware tab
    parts[#parts + 1] = '<div class="' .. panel_class("middleware") .. '" id="tab-middleware">'
    parts[#parts + 1] = '<p class="note">The middleware chain checks for an Authorization header. Try with and without auth:</p>'
    parts[#parts + 1] = '<div class="btn-row">'
    parts[#parts + 1] = '<a href="/playground?tab=middleware&action=get-mw-none" class="btn">No Auth Header</a>'
    parts[#parts + 1] = '<a href="/playground?tab=middleware&action=get-mw-ok" class="btn primary">Correct Bearer</a>'
    parts[#parts + 1] = '<a href="/playground?tab=middleware&action=get-mw-bad" class="btn">Wrong Bearer</a>'
    parts[#parts + 1] = '</div>'
    if active_tab == "middleware" then parts[#parts + 1] = response_html end
    parts[#parts + 1] = '</div>'

    -- Inspect tab
    parts[#parts + 1] = '<div class="' .. panel_class("inspect") .. '" id="tab-inspect">'
    parts[#parts + 1] = '<div class="btn-row">'
    parts[#parts + 1] = '<a href="/playground?tab=inspect&action=get-inspect" class="btn primary">GET /api/inspect</a>'
    parts[#parts + 1] = '<a href="/playground?tab=inspect&action=post-inspect" class="btn">POST /api/inspect</a>'
    parts[#parts + 1] = '</div>'
    if active_tab == "inspect" then parts[#parts + 1] = response_html end
    parts[#parts + 1] = '</div>'

    -- Footer
    parts[#parts + 1] = [[
    <footer>
      <a href="/">Keyway</a> &middot; <a href="https://github.com/ygalsk/keyway-zig">GitHub</a>
    </footer>

  </div>
</body>
</html>]]

    return table.concat(parts)
end

-- ── Playground handler ──────────────────────────────────────────────────────

local function handle_playground(ctx)
    -- Read params from query (GET) or form body (POST)
    local active_tab, action, input_id, post_body

    if ctx.method == "POST" then
        -- POST form: parse URL-encoded body for tab, action, post_body
        local form = parse_form_body(ctx.body)
        active_tab = form.tab or "get"
        action = form.action
        post_body = form.post_body
    else
        -- GET: read from query params
        active_tab = ctx.query and ctx.query.tab or "get"
        action = ctx.query and ctx.query.action or nil
        input_id = ctx.query and ctx.query.id or nil
    end

    local action_result = nil

    if action and playground_actions[action] then
        local act = playground_actions[action]
        local opts = {}

        -- Set up params/body/headers for specific actions
        if action == "get-user" then
            opts.params = { id = input_id or "42" }
        elseif action == "get-echo" then
            opts.params = { message = input_id or "hello-keyway" }
        elseif action == "post-users" then
            opts.body = post_body or '{"name":"Charlie","role":"editor"}'
            opts.headers = mock_headers({ ["Content-Type"] = "application/json" })
        elseif action == "get-404" then
            opts.params = { id = "999999" }
        elseif action == "get-mw-ok" then
            opts.headers = mock_headers({ Authorization = "Bearer keyway-demo-token" })
        elseif action == "get-mw-bad" then
            opts.headers = mock_headers({ Authorization = "Bearer wrong-token" })
        elseif action == "post-inspect" then
            opts.body = "Hello from the playground!"
            opts.headers = mock_headers({ Accept = "*/*", ["Content-Type"] = "text/plain" })
        elseif action == "get-headers" then
            opts.headers = mock_headers({ ["X-Custom-Header"] = "keyway-demo",
                ["X-Request-Id"] = "pg-" .. tostring(os.time()) })
        elseif action == "get-inspect" then
            opts.headers = mock_headers({ ["Content-Type"] = "application/json" })
        end

        -- Apply default browser headers if none were set
        if not opts.headers then opts.headers = MOCK_BROWSER_HEADERS end

        local mock = make_mock_ctx(act.method, act.path, opts)

        -- Simulate middleware for get-mw-bad (auth middleware rejects before handler)
        if action == "get-mw-bad" then
            reject_unauthorized(mock)
        else
            act.handler(mock)
        end
        action_result = mock
        action_result._method_label = act.method .. " " .. act.path

        -- Preserve input values for re-rendering
        if action == "get-user" then
            action_result._input_id = input_id or "42"
        elseif action == "get-echo" then
            action_result._input_msg = input_id or "hello-keyway"
        elseif action == "post-users" then
            action_result._input_body = post_body or '{"name":"Charlie","role":"editor"}'
        end
    end

    ctx.status = 200
    ctx.headers["Content-Type"] = "text/html; charset=utf-8"
    ctx.body = render_playground(active_tab, action_result)
end

-- ── Declarative route table ─────────────────────────────────────────────────

keyway.routes = {
    -- Global middleware: count every request
    middleware = {
        function(ctx, next)
            request_count = request_count + 1
            next()
        end,
    },

    -- Landing page
    ["/"] = {
        GET = handle_landing,
    },

    -- Playground (server-rendered, accepts GET + POST)
    ["/playground"] = {
        GET = handle_playground,
        POST = handle_playground,
    },

    -- Health & status
    ["/ping"] = {
        GET = handle_ping,
    },
    ["/health"] = {
        GET = handle_health,
    },

    -- Users API (PostgreSQL via pgmoon)
    ["/users"] = {
        GET = handle_users_get,
        POST = handle_users_post,
        ["/{id}"] = {
            GET = handle_user_by_id,
        },
    },

    -- Echo
    ["/echo"] = {
        ["/{message}"] = {
            GET = handle_echo,
        },
    },

    -- API routes
    ["/api"] = {
        ["/stats"] = {
            GET = handle_stats,
        },
        ["/headers"] = {
            GET = handle_headers,
        },
        ["/middleware-demo"] = {
            middleware = {
                -- Timing middleware
                function(ctx, next)
                    local t0 = os.clock()
                    next()
                    local elapsed = string.format("%.3fms", (os.clock() - t0) * 1000)
                    local trace = ctx.headers["X-Middleware-Trace"] or "unknown"
                    ctx.headers["X-Middleware-Trace"] = trace .. " > timing:" .. elapsed
                end,
                -- Auth middleware
                function(ctx, next)
                    local auth = ctx.headers["Authorization"]
                    if auth and auth ~= "Bearer keyway-demo-token" then
                        reject_unauthorized(ctx)
                        return
                    end
                    next()
                end,
            },
            GET = handle_middleware_demo,
        },
        ["/inspect"] = {
            GET = handle_inspect,
            POST = handle_inspect,
        },
        ["/error"] = {
            GET = handle_error,
        },
    },
}
