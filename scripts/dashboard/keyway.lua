-- keyway.lua — Admin dashboard + programmable control plane
-- Exercises every primitive: SSE, WebSocket, streaming, static files,
-- middleware, route params, query params, JSON, script engine.

local response = require("keyway.response")
local cjson = require("cjson")
local dns = require("keyway.dns")
local socket = require("keyway.socket")

-- Dashboard libs
local probe = require("scripts.dashboard.lib.probe")
local scripts_store = require("scripts.dashboard.lib.scripts_store")
local dispatch = require("scripts.dashboard.lib.dispatch")
local hooks_store = require("scripts.dashboard.lib.hooks_store")

-- Local HTTP request helper (uses keyway.socket which is ring-based, yields properly)
local function self_request(host_hdr, port, method, path)
    local tcp = socket.tcp()
    tcp:settimeout(5000)
    local ok, err = tcp:connect("127.0.0.1", port)
    if not ok then return nil, "connect failed: " .. (err or "unknown") end
    tcp:send(string.format("%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", method, path, host_hdr))
    local status_line = tcp:receive("*l")
    if not status_line then tcp:close(); return nil, "no response" end
    local status_code = tonumber(status_line:match("^HTTP/%S+ (%d+)")) or 0
    local headers, content_length = {}, nil
    while true do
        local line = tcp:receive("*l")
        if not line or line == "" then break end
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name then
            headers[#headers + 1] = { name, value }
            if name:lower() == "content-length" then content_length = tonumber(value) end
        end
    end
    local body = ""
    if content_length and content_length > 0 then
        body = tcp:receive(content_length) or ""
    else
        -- No Content-Length: read until EOF (Connection: close)
        local chunks = {}
        while true do
            local chunk, chunk_err = tcp:receive(4096)
            if not chunk then break end
            chunks[#chunks + 1] = chunk
        end
        if #chunks > 0 then body = table.concat(chunks) end
    end
    tcp:close()
    return status_code, headers, body
end

-- ─── Per-Worker Counters ──────────────────────────────────────────────
local counters = {
    ws_connections = 0,
    ws_messages    = 0,
    http_probes    = 0,
    dns_lookups    = 0,
    self_requests  = 0,
    stream_tests   = 0,
}

-- ─── Per-Route Metrics (static routes from keyway.routes) ────────────
-- Key: "METHOD /pattern" → { hits, errors, total_latency_us }
local _route_metrics = {}

-- ─── Helpers ──────────────────────────────────────────────────────────

local function esc(s)
    if not s then return "" end
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function format_latency(us)
    if not us or us == 0 then return "-" end
    if us < 1000 then return us .. "us" end
    if us < 1000000 then return string.format("%.1fms", us / 1000) end
    return string.format("%.2fs", us / 1000000)
end

local function status_cls(s)
    if not s or s == 0 then return "s-0" end
    if s < 300 then return "s-2xx" end
    if s < 400 then return "s-3xx" end
    if s < 500 then return "s-4xx" end
    return "s-5xx"
end

-- Extract {param} from path: /__keyway/api/scripts/{id} style
local function extract_path_id(path, prefix)
    local id = path:match("^" .. prefix .. "/([^/]+)")
    return id
end

-- ─── Localhost Guard ─────────────────────────────────────────────────
-- Restricts /__keyway/ paths to localhost only.

local function localhost_guard(ctx, next)
    if ctx.path and ctx.path:match("^/__keyway/") then
        local addr = ctx.remote_addr or ""
        if addr ~= "127.0.0.1" and addr ~= "::1" then
            ctx.status = 403
            ctx.body = "Forbidden"
            return
        end
    end
    next()
end

-- ─── Access Log Middleware ────────────────────────────────────────────
-- Broadcasts JSON event per request via SSE.

local function access_log_middleware(ctx, next)
    local t0 = response.now_us()
    next()
    local latency_us = math.floor(response.now_us() - t0)
    local method = ctx.method or "GET"
    local status = ctx.status or 0
    local wid = keyway.worker_id

    -- Count request headers
    local header_count = 0
    if ctx.request_headers then
        for _ in ipairs(ctx.request_headers) do header_count = header_count + 1 end
    end

    -- Get response content-type
    local content_type = ctx.headers and ctx.headers["Content-Type"] or ""

    -- Collect matched scripts from dispatch
    local matched_scripts = nil
    if #dispatch._last_matched > 0 then
        matched_scripts = dispatch._last_matched
    end

    -- Check for hook capture (set by M_capture_hook)
    local hook_id = ctx._hook_id or nil

    pcall(response.broadcast_event, "keyway:access", {
        method = method,
        path = ctx.path or "--",
        status = status,
        latency_us = latency_us,
        latency = format_latency(latency_us),
        worker_id = wid ~= nil and tostring(wid) or "-",
        content_type = content_type,
        header_count = header_count,
        scripts = matched_scripts,
        hook_id = hook_id,
    })

    -- Track per-route metrics for static routes
    local path = ctx.path or ""
    -- Match against registered static route patterns
    for pattern, methods in pairs(keyway.routes) do
        if type(methods) == "table" and pattern ~= "middleware" and methods[method] then
            -- Check if path matches pattern (exact or param substitution)
            local pat_regex = "^" .. pattern:gsub("([%.%-%+%%%^%$%(%)%[%]%*%?])", "%%%1"):gsub("{[^}]+}", "[^/]+") .. "$"
            if path:match(pat_regex) then
                local key = method .. " " .. pattern
                local rm = _route_metrics[key]
                if not rm then
                    rm = { hits = 0, errors = 0, total_latency_us = 0 }
                    _route_metrics[key] = rm
                end
                rm.hits = rm.hits + 1
                if status >= 400 then rm.errors = rm.errors + 1 end
                rm.total_latency_us = rm.total_latency_us + latency_us
                break
            end
        end
    end

end

-- ─── Test Middleware ──────────────────────────────────────────────────

local function mw_before(ctx, next)
    ctx.headers["X-MW-Before"] = "applied"
    next()
end

local function mw_after(ctx, next)
    next()
    ctx.headers["X-MW-After"] = "applied"
end

-- ─── Initialize Script Engine ────────────────────────────────────────
-- Reload is lazy: dispatch.dispatch checks _loaded on first request.
-- No startup call needed (cosocket yields require a handler coroutine).

-- ─── Shared Helpers ──────────────────────────────────────────────

local function ws_reply(ws, tbl)
    ws:send(cjson.encode(tbl))
end

local function ws_error(ws, cmd, msg)
    ws_reply(ws, { cmd = cmd, error = msg })
end

local function mw_name(mw, index, prefix)
    local name = (prefix or "mw_") .. index
    local info = debug.getinfo(mw, "n")
    if info and info.name then name = info.name end
    return name
end


--- Iterate static routes in keyway.routes, calling cb(pattern, methods_table, mw_names, http_methods).
local function each_static_route(cb, mw_prefix)
    for pattern, methods in pairs(keyway.routes) do
        if type(methods) == "table" and pattern ~= "middleware" then
            local mw_names = {}
            if methods.middleware then
                for j, mw in ipairs(methods.middleware) do
                    mw_names[#mw_names + 1] = mw_name(mw, j, mw_prefix)
                end
            end
            local http_methods = {}
            for method, _ in pairs(methods) do
                if type(method) == "string" and method:match("^%u+$") then
                    http_methods[#http_methods + 1] = method
                end
            end
            cb(pattern, methods, mw_names, http_methods)
        end
    end
end

-- ─── WebSocket Command Dispatch ──────────────────────────────────

local ws_commands = {}

ws_commands.ping = function(ws, _)
    ws_reply(ws, { cmd = "pong", ts = math.floor(response.now_us()), worker_id = keyway.worker_id })
end

ws_commands.info = function(ws, _)
    ws_reply(ws, {
        cmd = "info",
        worker_id = keyway.worker_id,
        ts = math.floor(response.now_us()),
        counters = counters,
    })
end

ws_commands.scripts = function(ws, _)
    ws_reply(ws, { cmd = "scripts", scripts = scripts_store.list() })
end

ws_commands.hooks = function(ws, _)
    ws_reply(ws, { cmd = "hooks", hooks = hooks_store.list() })
end

ws_commands.trigger = function(ws, msg)
    local id = msg.id
    if not id then return ws_error(ws, "trigger", "id required") end
    local script = scripts_store.get(id)
    if not script then return ws_error(ws, "trigger", "not found") end
    local fn, compile_err = scripts_store.compile(script.code)
    if not fn then return ws_error(ws, "trigger", compile_err) end
    local mock_ctx = {
        method = "GET", path = script.pattern, body = "",
        status = 200, headers = {}, request_headers = {}, params = {},
    }
    local t0 = response.now_us()
    local function err_handler(e) return debug.traceback(tostring(e), 2) end
    local run_ok, run_err
    if script.type == "middleware" then
        run_ok, run_err = xpcall(fn, err_handler, mock_ctx, function() end)
    else
        run_ok, run_err = xpcall(fn, err_handler, mock_ctx)
    end
    local elapsed = math.floor(response.now_us() - t0)
    ws_reply(ws, {
        cmd = "trigger", id = id,
        success = run_ok,
        error = run_ok and nil or run_err,
        result = { status = mock_ctx.status, body = mock_ctx.body, headers = mock_ctx.headers },
        timing_us = elapsed,
    })
end

ws_commands.routes = function(ws, _)
    ws_reply(ws, { cmd = "routes", routes = dispatch.list_routes() })
end

ws_commands.lua = function(ws, msg)
    local code = msg.code
    if not code or code == "" then return ws_error(ws, "lua", "code required") end
    local fn, compile_err = loadstring("return " .. code)
    if not fn then
        fn, compile_err = loadstring(code)
    end
    if not fn then return ws_error(ws, "lua", compile_err) end
    local ok, result = pcall(fn)
    if ok then
        ws_reply(ws, { cmd = "lua", result = tostring(result) })
    else
        ws_error(ws, "lua", tostring(result))
    end
end

ws_commands.send_hook = function(ws, msg)
    local id = msg.id
    local body = msg.body or ""
    if not id then return ws_error(ws, "send_hook", "id required") end
    if not hooks_store.exists(id) then return ws_error(ws, "send_hook", "hook not found") end
    hooks_store.capture(id, {
        method = "WS", path = "/h/" .. id,
        headers = {}, body = body,
    })
    ws_reply(ws, { cmd = "send_hook", ok = true, id = id })
end

-- ─── Static Mount ────────────────────────────────────────────────────

keyway.static = {
    ["/__keyway/dashboard"] = { root = "scripts/dashboard/public", index = "index.html" },
}

-- ─── Routes ──────────────────────────────────────────────────────────

keyway.routes = {
    middleware = { localhost_guard, access_log_middleware, dispatch.dispatch },

    -- Dashboard: SSE event stream
    ["/__keyway/events"] = {
        GET = function(ctx)
            ctx.upgrade = "sse"
            ctx.sse_room = "keyway:access"
        end,
    },

    -- Dashboard: WebSocket command interface
    ["/__keyway/ws"] = {
        GET = function(ctx)
            counters.ws_connections = counters.ws_connections + 1
            ctx.upgrade = "websocket"
            ctx.on_message = function(ws)
                counters.ws_messages = counters.ws_messages + 1
                local ok, msg = pcall(cjson.decode, ws.message)
                if not ok then
                    ws_reply(ws, { error = "invalid json" })
                    return
                end
                local handler = ws_commands[msg.cmd]
                if handler then
                    handler(ws, msg)
                else
                    ws_reply(ws, { error = "unknown command: " .. tostring(msg.cmd) })
                end
            end
            ctx.on_close = function()
                counters.ws_connections = math.max(0, counters.ws_connections - 1)
            end
        end,
    },

    -- ─── Metrics (JSON) ──────────────────────────────────────────

    ["/__keyway/api/metrics"] = {
        GET = function(ctx)
            local host_hdr = response.get_header(ctx, "Host") or "localhost:8080"
            local port = tonumber(host_hdr:match(":(%d+)$")) or 8080

            local status, _, body = self_request(host_hdr, port, "GET", "/health")
            if not status then
                response.json_response(ctx, 200, { status = "error", error = "health check failed" })
                return
            end

            local ok, m = pcall(cjson.decode, body)
            if not ok then
                response.json_response(ctx, 200, { status = "error", error = "invalid health response" })
                return
            end

            response.json_response(ctx, 200, m)
        end,
    },

    -- ─── Dashboard API Endpoints ─────────────────────────────────

    -- HTTP Probe
    ["/__keyway/api/probe"] = {
        POST = function(ctx)
            counters.http_probes = counters.http_probes + 1
            local ok, body = pcall(cjson.decode, ctx.body)
            if not ok or not body.url then
                response.json_response(ctx, 400, { error = "JSON body with 'url' field required" })
                return
            end
            local result, err = probe.execute(body.url)
            if not result then
                response.json_response(ctx, 200, { error = err })
                return
            end
            -- Broadcast probe as pseudo-traffic entry
            pcall(response.broadcast_event, "keyway:access", {
                method = "PROBE",
                path = body.url,
                status = result.status,
                latency_us = result.timing_us,
                latency = format_latency(result.timing_us),
                worker_id = keyway.worker_id ~= nil and tostring(keyway.worker_id) or "-",
                content_type = "",
                header_count = #result.headers,
            })
            response.json_response(ctx, 200, {
                status       = result.status,
                headers      = result.headers,
                timing_ms    = result.timing_ms,
                body_preview = result.body_preview,
            })
        end,
    },

    -- DNS Lookup
    ["/__keyway/api/dns"] = {
        POST = function(ctx)
            counters.dns_lookups = counters.dns_lookups + 1
            local ok, body = pcall(cjson.decode, ctx.body)
            if not ok or not body.domain then
                response.json_response(ctx, 400, { error = "JSON body with 'domain' field required" })
                return
            end
            local t0 = response.now_us()
            local records, err = dns.lookup(body.domain)
            local timing = math.floor(response.now_us() - t0)
            if not records then
                response.json_response(ctx, 200, { error = err, timing_us = timing })
                return
            end
            response.json_response(ctx, 200, { records = records, timing_us = timing })
        end,
    },

    -- Self-Request
    ["/__keyway/api/self"] = {
        POST = function(ctx)
            counters.self_requests = counters.self_requests + 1
            local ok, body = pcall(cjson.decode, ctx.body)
            local path = (ok and body.path) or "/test/json"
            local host_hdr = response.get_header(ctx, "Host") or "localhost:8080"
            local port = tonumber(host_hdr:match(":(%d+)$")) or 8080

            local t0 = response.now_us()
            local status_code, _, resp_body = self_request(host_hdr, port, "GET", path)
            local timing = math.floor(response.now_us() - t0)
            if not status_code then
                response.json_response(ctx, 200, { error = resp_body or "request failed" })
                return
            end
            response.json_response(ctx, 200, {
                status = status_code,
                body = (resp_body or ""):sub(1, 500),
                timing_us = timing,
                path = path,
            })
        end,
    },

    -- Stream Test
    ["/__keyway/api/stream"] = {
        GET = function(ctx)
            counters.stream_tests = counters.stream_tests + 1
            ctx.upgrade = "stream"
            ctx.status = 200
            for i = 1, 5 do
                ctx.body = string.format("chunk %d of 5 — worker %d — %dus\n",
                    i, keyway.worker_id, math.floor(response.now_us()))
                coroutine.yield()
            end
        end,
    },

    -- Counters
    ["/__keyway/api/counters"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, counters)
        end,
    },

    -- Route listing (with middleware chain info)
    ["/__keyway/api/routes"] = {
        GET = function(ctx)
            local routes = dispatch.list_routes()
            each_static_route(function(pattern, _, mw_names, http_methods)
                for _, method in ipairs(http_methods) do
                    local key = method .. " " .. pattern
                    local rm = _route_metrics[key]
                    local hits = rm and rm.hits or 0
                    local errors = rm and rm.errors or 0
                    local avg = (rm and hits > 0) and math.floor(rm.total_latency_us / hits) or 0
                    routes[#routes + 1] = {
                        method = method,
                        pattern = pattern,
                        handler = "keyway.lua",
                        middleware = mw_names,
                        hits = hits,
                        errors = errors,
                        avg_latency_us = avg,
                    }
                end
            end)
            response.json_response(ctx, 200, { routes = routes })
        end,
    },

    -- Effective config — compiled route table with resolved middleware chains
    ["/__keyway/api/config/effective"] = {
        GET = function(ctx)
            local effective = {
                global_middleware = {},
                routes = {},
                scripts = {},
            }
            -- Global middleware from keyway.routes.middleware
            if keyway.routes.middleware then
                for i, mw in ipairs(keyway.routes.middleware) do
                    effective.global_middleware[#effective.global_middleware + 1] = mw_name(mw, i, "global_mw_")
                end
            end
            -- Static routes
            each_static_route(function(pattern, _, mw_names, http_methods)
                effective.routes[#effective.routes + 1] = {
                    pattern = pattern,
                    methods = http_methods,
                    middleware = mw_names,
                }
            end, "route_mw_")
            -- Script-defined routes
            local script_routes = dispatch.list_routes()
            for _, r in ipairs(script_routes) do
                effective.scripts[#effective.scripts + 1] = {
                    method = r.method,
                    pattern = r.pattern,
                    handler = r.handler,
                    hits = r.hits,
                    errors = r.errors,
                }
            end
            -- Sort routes by pattern
            table.sort(effective.routes, function(a, b) return a.pattern < b.pattern end)
            response.json_response(ctx, 200, effective)
        end,
    },

    -- ─── Scripts API ─────────────────────────────────────────────

    ["/__keyway/api/scripts"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, { scripts = scripts_store.list() })
        end,
        POST = function(ctx)
            local body, err = response.parse_json_body(ctx)
            if not body then return end
            local script = scripts_store.create(body)
            response.json_response(ctx, 201, { script = script })
        end,
    },

    ["/__keyway/api/scripts/{id}"] = {
        GET = function(ctx)
            local script = scripts_store.get(ctx.params.id)
            if not script then
                response.json_not_found(ctx)
                return
            end
            response.json_response(ctx, 200, { script = script })
        end,
        PUT = function(ctx)
            local body, err = response.parse_json_body(ctx)
            if not body then return end
            local script = scripts_store.update(ctx.params.id, body)
            if not script then
                response.json_not_found(ctx)
                return
            end
            -- Reload dispatch if script is enabled
            if script.enabled then dispatch.reload() end
            response.json_response(ctx, 200, { script = script })
        end,
        DELETE = function(ctx)
            local ok = scripts_store.delete(ctx.params.id)
            if not ok then
                response.json_not_found(ctx)
                return
            end
            dispatch.reload()
            response.json_response(ctx, 200, { ok = true })
        end,
    },

    ["/__keyway/api/scripts/{id}/toggle"] = {
        POST = function(ctx)
            local script = scripts_store.toggle(ctx.params.id)
            if not script then
                response.json_not_found(ctx)
                return
            end
            dispatch.reload()
            -- Broadcast reload signal to all workers
            pcall(response.broadcast_event, "keyway:scripts", { action = "reload" })
            response.json_response(ctx, 200, { script = script })
        end,
    },

    ["/__keyway/api/scripts/{id}/trigger"] = {
        POST = function(ctx)
            local script = scripts_store.get(ctx.params.id)
            if not script then
                response.json_not_found(ctx)
                return
            end
            if not script.enabled then
                scripts_store.toggle(ctx.params.id)
                dispatch.reload()
                pcall(response.broadcast_event, "keyway:scripts", { action = "reload" })
            end
            response.json_response(ctx, 200, { script = scripts_store.get(ctx.params.id), triggered = true })
        end,
    },

    ["/__keyway/api/scripts/{id}/test"] = {
        POST = function(ctx)
            local script = scripts_store.get(ctx.params.id)
            if not script then
                response.json_not_found(ctx)
                return
            end
            local fn, err = scripts_store.compile(script.code)
            if not fn then
                response.json_response(ctx, 200, { error = err })
                return
            end
            -- Build mock context from request body
            local ok, body = pcall(cjson.decode, ctx.body)
            local mock_ctx = {
                method = (ok and body.method) or "GET",
                path = (ok and body.path) or script.pattern,
                body = (ok and body.body) or "",
                status = 200,
                headers = {},
                request_headers = {},
                params = {},
            }
            local next_called = false
            local t0 = response.now_us()
            local function err_handler(e) return debug.traceback(tostring(e), 2) end
            local run_ok, run_err
            if script.type == "middleware" then
                run_ok, run_err = xpcall(fn, err_handler, mock_ctx, function() next_called = true end)
            else
                run_ok, run_err = xpcall(fn, err_handler, mock_ctx)
            end
            local elapsed = math.floor(response.now_us() - t0)
            response.json_response(ctx, 200, {
                success = run_ok,
                error = run_ok and nil or run_err,
                result = {
                    status = mock_ctx.status,
                    body = mock_ctx.body,
                    headers = mock_ctx.headers,
                    next_called = next_called,
                },
                timing_us = elapsed,
            })
        end,
    },

    -- ─── Hooks API ───────────────────────────────────────────────

    ["/__keyway/api/hooks"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, { hooks = hooks_store.list() })
        end,
        POST = function(ctx)
            local hook = hooks_store.create()
            response.json_response(ctx, 201, { hook = hook })
        end,
    },

    ["/__keyway/api/hooks/{id}"] = {
        GET = function(ctx)
            local hook = hooks_store.get(ctx.params.id)
            if not hook then
                response.json_not_found(ctx)
                return
            end
            response.json_response(ctx, 200, {
                hook = { id = hook.id, name = hook.name, created_at = hook.created_at, request_count = #hook.requests },
                requests = hook.requests,
            })
        end,
        DELETE = function(ctx)
            local ok = hooks_store.delete(ctx.params.id)
            if not ok then
                response.json_not_found(ctx)
                return
            end
            response.json_response(ctx, 200, { ok = true })
        end,
    },

    ["/__keyway/api/hooks/{id}/events"] = {
        GET = function(ctx)
            ctx.upgrade = "sse"
            ctx.sse_room = "hook:" .. ctx.params.id
        end,
    },

    -- Webhook catch endpoint — captures any request to /h/{id}
    ["/h/{id}"] = {
        GET = function(ctx) M_capture_hook(ctx) end,
        POST = function(ctx) M_capture_hook(ctx) end,
        PUT = function(ctx) M_capture_hook(ctx) end,
        DELETE = function(ctx) M_capture_hook(ctx) end,
    },

    -- ─── Integration Test Endpoints ──────────────────────────────

    ["/test/hello"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.body = "hello world"
        end,
    },

    ["/test/users/{id}"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, { id = ctx.params.id })
        end,
    },

    ["/test/search"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, { q = ctx.query.q })
        end,
    },

    ["/test/headers"] = {
        GET = function(ctx)
            local ua = response.get_header(ctx, "User-Agent") or "unknown"
            ctx.status = 200
            ctx.headers["X-Echo-UA"] = ua
            ctx.headers["X-Worker"] = tostring(keyway.worker_id)
            ctx.body = "headers ok"
        end,
    },

    ["/test/echo"] = {
        POST = function(ctx)
            ctx.status = 200
            ctx.body = ctx.body
        end,
    },

    ["/test/status/{code}"] = {
        GET = function(ctx)
            local code = tonumber(ctx.params.code) or 200
            ctx.status = code
            ctx.body = "status " .. tostring(code)
        end,
    },

    ["/test/json"] = {
        GET = function(ctx)
            response.json_response(ctx, 200, { message = "hello", worker_id = keyway.worker_id })
        end,
    },

    ["/test/sse"] = {
        GET = function(ctx)
            ctx.upgrade = "sse"
            ctx.sse_room = "test:events"
        end,
    },

    ["/test/ws"] = {
        GET = function(ctx)
            ctx.upgrade = "websocket"
            ctx.on_message = function(ws)
                ws:send(ws.message)
            end
            ctx.on_close = function() end
        end,
    },

    ["/test/stream"] = {
        GET = function(ctx)
            ctx.upgrade = "stream"
            ctx.status = 200
            ctx.body = "chunk1\n"
            coroutine.yield()
            ctx.body = "chunk2\n"
            coroutine.yield()
            ctx.body = "chunk3\n"
            coroutine.yield()
        end,
    },

    ["/test/broadcast"] = {
        POST = function(ctx)
            local data = ctx.body
            pcall(response.broadcast_event, "test:events", { message = data })
            ctx.status = 200
            ctx.body = "ok"
        end,
    },

    ["/test/mw"] = {
        middleware = { mw_before, mw_after },
        GET = function(ctx)
            ctx.status = 200
            ctx.body = "middleware ok"
        end,
    },
}

-- ─── Webhook Capture Helper ──────────────────────────────────────────

function M_capture_hook(ctx)
    local id = ctx.params.id
    if not hooks_store.exists(id) then
        response.json_response(ctx, 404, { error = "hook not found" })
        return
    end
    -- Tag for access_log_middleware to pick up
    ctx._hook_id = id
    local headers = {}
    if ctx.request_headers then
        for _, h in ipairs(ctx.request_headers) do
            headers[h[1]] = h[2]
        end
    end
    hooks_store.capture(id, {
        method = ctx.method or "GET",
        path = ctx.path or "",
        headers = headers,
        body = ctx.body or "",
    })
    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = '{"captured":true}'
end
