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
local http_self = require("scripts.dashboard.lib.http_self")

-- ─── Per-Worker Counters ──────────────────────────────────────────────
local counters = {
    ws_connections = 0,
    ws_messages    = 0,
    http_probes    = 0,
    dns_lookups    = 0,
    self_requests  = 0,
    stream_tests   = 0,
}

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

-- ─── Access Log Middleware ────────────────────────────────────────────
-- Broadcasts JSON event per request via SSE.

local _request_count = 0

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

    -- Periodic event condition evaluation
    _request_count = _request_count + 1
    if _request_count % 100 == 0 then
        pcall(dispatch.evaluate_conditions, {
            total_requests = _request_count,
            error_rate = (counters.http_probes > 0) and 0 or 0,
        })
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

-- ─── Static Mount ────────────────────────────────────────────────────

keyway.static = {
    ["/__keyway/dashboard"] = { root = "scripts/dashboard/public", index = "index.html" },
}

-- ─── Routes ──────────────────────────────────────────────────────────

keyway.routes = {
    middleware = { access_log_middleware, dispatch.dispatch },

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
                    ws:send(cjson.encode({ error = "invalid json" }))
                    return
                end
                local cmd = msg.cmd
                if cmd == "ping" then
                    ws:send(cjson.encode({ cmd = "pong", ts = math.floor(response.now_us()), worker_id = keyway.worker_id }))
                elseif cmd == "info" then
                    ws:send(cjson.encode({
                        cmd = "info",
                        worker_id = keyway.worker_id,
                        ts = math.floor(response.now_us()),
                        counters = counters,
                    }))
                elseif cmd == "scripts" then
                    local all = scripts_store.list()
                    for _, s in ipairs(all) do
                        local rt = dispatch.get_metrics(s.id)
                        if rt then s.metrics = rt end
                    end
                    ws:send(cjson.encode({ cmd = "scripts", scripts = all }))
                elseif cmd == "hooks" then
                    local all = hooks_store.list()
                    ws:send(cjson.encode({ cmd = "hooks", hooks = all }))
                elseif cmd == "trigger" then
                    local id = msg.id
                    if not id then
                        ws:send(cjson.encode({ cmd = "trigger", error = "id required" }))
                    else
                        local script = scripts_store.get(id)
                        if not script then
                            ws:send(cjson.encode({ cmd = "trigger", error = "not found" }))
                        else
                            local fn, compile_err = scripts_store.compile(script.code)
                            if not fn then
                                ws:send(cjson.encode({ cmd = "trigger", error = compile_err }))
                            else
                                local mock_ctx = {
                                    method = "GET", path = script.pattern, body = "",
                                    status = 200, headers = {}, request_headers = {}, params = {},
                                }
                                local t0 = response.now_us()
                                local run_ok, run_err
                                if script.type == "middleware" then
                                    run_ok, run_err = pcall(fn, mock_ctx, function() end)
                                else
                                    run_ok, run_err = pcall(fn, mock_ctx)
                                end
                                local elapsed = math.floor(response.now_us() - t0)
                                ws:send(cjson.encode({
                                    cmd = "trigger", id = id,
                                    success = run_ok,
                                    error = run_ok and nil or tostring(run_err),
                                    result = { status = mock_ctx.status, body = mock_ctx.body, headers = mock_ctx.headers },
                                    timing_us = elapsed,
                                }))
                            end
                        end
                    end
                elseif cmd == "send_hook" then
                    local id = msg.id
                    local body = msg.body or ""
                    if not id then
                        ws:send(cjson.encode({ cmd = "send_hook", error = "id required" }))
                    elseif not hooks_store.exists(id) then
                        ws:send(cjson.encode({ cmd = "send_hook", error = "hook not found" }))
                    else
                        hooks_store.capture(id, {
                            method = "WS", path = "/h/" .. id,
                            headers = {}, body = body,
                        })
                        ws:send(cjson.encode({ cmd = "send_hook", ok = true, id = id }))
                    end
                else
                    ws:send(cjson.encode({ error = "unknown command: " .. tostring(cmd) }))
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

            local status, _, body = http_self.request(host_hdr, port, "GET", "/health")
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
            local status_code, _, resp_body = http_self.request(host_hdr, port, "GET", path)
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

    -- ─── Scripts API ─────────────────────────────────────────────

    ["/__keyway/api/scripts"] = {
        GET = function(ctx)
            local scripts = scripts_store.list()
            -- Merge runtime metrics
            for _, s in ipairs(scripts) do
                local rt = dispatch.get_metrics(s.id)
                if rt then s.metrics = rt end
            end
            response.json_response(ctx, 200, { scripts = scripts })
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
            local rt = dispatch.get_metrics(script.id)
            if rt then script.metrics = rt end
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
            local run_ok, run_err
            if script.type == "middleware" then
                run_ok, run_err = pcall(fn, mock_ctx, function() next_called = true end)
            else
                run_ok, run_err = pcall(fn, mock_ctx)
            end
            local elapsed = math.floor(response.now_us() - t0)
            response.json_response(ctx, 200, {
                success = run_ok,
                error = run_ok and nil or tostring(run_err),
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

    ["/__keyway/api/scripts/{id}/metrics"] = {
        GET = function(ctx)
            local metrics = dispatch.get_metrics(ctx.params.id)
            if not metrics then
                response.json_not_found(ctx)
                return
            end
            response.json_response(ctx, 200, { metrics = metrics })
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
                hook = { id = hook.id, created_at = hook.created_at, request_count = #hook.requests },
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
    response.json_response(ctx, 200, { captured = true })
end
