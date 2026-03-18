-- keyway.lua — Admin dashboard + file management control plane
-- Lua files on disk control the runtime. The dashboard is a file editor.

local response = require("keyway.response")
local cjson = require("cjson")
local dns = require("keyway.dns")
local http = require("keyway.http")

-- ─── Middleware Registry ──────────────────────────────────────────────

keyway.middleware = keyway.middleware or {}
keyway.middleware._registry = {}

function keyway.middleware.register(name, fn)
    keyway.middleware._registry[name] = fn
end

function keyway.middleware.resolve(name_or_fn)
    if type(name_or_fn) == "function" then return name_or_fn end
    local fn = keyway.middleware._registry[name_or_fn]
    if fn then return fn end
    error("middleware not found: " .. tostring(name_or_fn))
end

function keyway.middleware.list()
    local result = {}
    for name in pairs(keyway.middleware._registry) do
        result[#result + 1] = name
    end
    table.sort(result)
    return result
end

-- ─── Helpers ──────────────────────────────────────────────────────────

local function format_latency(us)
    if not us or us == 0 then return "-" end
    if us < 1000 then return us .. "us" end
    if us < 1000000 then return string.format("%.1fms", us / 1000) end
    return string.format("%.2fs", us / 1000000)
end

-- Resolve a middleware function's name by scanning known scopes.
-- debug.getinfo(fn, "n") doesn't work for function values in LuaJIT,
-- so we scan the global table and the script's upvalue locals.
local _mw_name_cache = setmetatable({}, { __mode = "k" })
local function mw_name(mw, index, prefix)
    local cached = _mw_name_cache[mw]
    if cached then return cached end

    -- Try middleware registry first (reverse lookup fn→name)
    if keyway.middleware and keyway.middleware._registry then
        for name, fn in pairs(keyway.middleware._registry) do
            if fn == mw then
                _mw_name_cache[mw] = name
                return name
            end
        end
    end

    -- Try debug.getinfo first (works for C functions and some named funcs)
    local info = debug.getinfo(mw, "nS")
    if info and info.name and info.name ~= "" then
        _mw_name_cache[mw] = info.name
        return info.name
    end

    -- Scan globals
    for k, v in pairs(_G) do
        if v == mw and type(k) == "string" then
            _mw_name_cache[mw] = k
            return k
        end
    end

    -- Scan upvalues of the calling function (2 levels up)
    for level = 2, 5 do
        local caller = debug.getinfo(level, "f")
        if not caller or not caller.func then break end
        local i = 1
        while true do
            local uname, uval = debug.getupvalue(caller.func, i)
            if not uname then break end
            if uval == mw and uname ~= "" and not uname:match("^%(") then
                _mw_name_cache[mw] = uname
                return uname
            end
            i = i + 1
        end
    end

    -- Fallback: source:line
    if info and info.short_src and info.linedefined then
        local fallback = info.short_src:match("([^/]+)$") .. ":" .. info.linedefined
        _mw_name_cache[mw] = fallback
        return fallback
    end

    return (prefix or "mw_") .. index
end

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

local function url_decode(s)
    return s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
end

-- ─── Localhost Guard ─────────────────────────────────────────────────

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

-- ─── Test Middleware ──────────────────────────────────────────────────

local function mw_before(ctx, next)
    ctx.headers["X-MW-Before"] = "applied"
    next()
end

local function mw_after(ctx, next)
    next()
    ctx.headers["X-MW-After"] = "applied"
end

-- Register built-in middleware
keyway.middleware.register("localhost_guard", localhost_guard)
keyway.middleware.register("mw_before", mw_before)
keyway.middleware.register("mw_after", mw_after)

local function ws_reply(ws, tbl)
    ws:send(cjson.encode(tbl))
end

local function ws_error(ws, cmd, msg)
    ws_reply(ws, { cmd = cmd, error = msg })
end

-- ─── WebSocket Command Dispatch ──────────────────────────────────

local ws_commands = {}

ws_commands.ping = function(ws, _)
    ws_reply(ws, { cmd = "pong", ts = math.floor(response.now_us()), worker_id = keyway.worker_id })
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

-- ─── Static Mount ────────────────────────────────────────────────────

keyway.static = {
    ["/__keyway/dashboard"] = { root = "scripts/dashboard/public", index = "index.html" },
}

-- ─── Reverse Proxy Mounts ────────────────────────────────────────────

keyway.proxy = {
    ["/__keyway/grafana"] = { host = "127.0.0.1", port = 3000, redirect = "/__keyway/dashboard/grafana.html", strip_prefix = false },
}

-- ─── Routes ──────────────────────────────────────────────────────────

keyway.routes = {
    middleware = { localhost_guard },

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
            ctx.upgrade = "websocket"
            ctx.on_message = function(ws)
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
            ctx.on_close = function() end
        end,
    },

    -- ─── Dashboard API Endpoints ─────────────────────────────────

    -- HTTP Probe
    ["/__keyway/api/probe"] = {
        POST = function(ctx)
            local ok, body = pcall(cjson.decode, ctx.body)
            if not ok or not body.url then
                response.json_response(ctx, 400, { error = "JSON body with 'url' field required" })
                return
            end
            local result, err = http.probe(body.url)
            if not result then
                response.json_response(ctx, 200, { error = err })
                return
            end
            local timing_us = (result.timing_ms or 0) * 1000
            pcall(response.broadcast_event, "keyway:access", {
                method = "PROBE",
                path = body.url,
                status = result.status,
                latency_us = timing_us,
                latency = format_latency(timing_us),
                worker_id = keyway.worker_id ~= nil and tostring(keyway.worker_id) or "-",
                content_type = "",
                header_count = #result.headers,
            })
            response.json_response(ctx, 200, {
                status       = result.status,
                headers      = result.headers,
                timing_ms    = result.timing_ms,
                body_preview = (result.body or ""):sub(1, 500),
            })
        end,
    },

    -- DNS Lookup
    ["/__keyway/api/dns"] = {
        POST = function(ctx)
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

    -- Stream Test
    ["/__keyway/api/stream"] = {
        GET = function(ctx)
            ctx.upgrade = "stream"
            ctx.status = 200
            for i = 1, 5 do
                ctx.body = string.format("chunk %d of 5 — worker %d — %dus\n",
                    i, keyway.worker_id, math.floor(response.now_us()))
                coroutine.yield()
            end
        end,
    },

    -- Route listing (with middleware chain info)
    ["/__keyway/api/routes"] = {
        GET = function(ctx)
            local global_mw = {}
            if keyway.routes.middleware then
                for i, mw in ipairs(keyway.routes.middleware) do
                    global_mw[#global_mw + 1] = { name = mw_name(mw, i, "global_mw_"), index = i }
                end
            end
            local routes = {}
            each_static_route(function(pattern, _, mw_names, http_methods)
                for _, method in ipairs(http_methods) do
                    routes[#routes + 1] = {
                        method = method,
                        pattern = pattern,
                        handler = "keyway.lua",
                        middleware = mw_names,
                    }
                end
            end)
            response.json_response(ctx, 200, {
                routes = routes,
                global_middleware = global_mw,
                available_middleware = keyway.middleware.list(),
            })
        end,
    },

    -- Effective config
    ["/__keyway/api/config/effective"] = {
        GET = function(ctx)
            local effective = {
                global_middleware = {},
                routes = {},
            }
            if keyway.routes.middleware then
                for i, mw in ipairs(keyway.routes.middleware) do
                    effective.global_middleware[#effective.global_middleware + 1] = mw_name(mw, i, "global_mw_")
                end
            end
            each_static_route(function(pattern, _, mw_names, http_methods)
                effective.routes[#effective.routes + 1] = {
                    pattern = pattern,
                    methods = http_methods,
                    middleware = mw_names,
                }
            end, "route_mw_")
            table.sort(effective.routes, function(a, b) return a.pattern < b.pattern end)
            response.json_response(ctx, 200, effective)
        end,
    },

    -- ─── Middleware Management API ────────────────────────────────

    -- List all registered middleware with source info
    ["/__keyway/api/middleware"] = {
        GET = function(ctx)
            local result = {}
            for name, fn in pairs(keyway.middleware._registry) do
                local info = debug.getinfo(fn, "S")
                result[#result + 1] = {
                    name = name,
                    source = info and info.short_src or "unknown",
                    line = info and info.linedefined or 0,
                }
            end
            table.sort(result, function(a, b) return a.name < b.name end)
            response.json_response(ctx, 200, { middleware = result })
        end,
    },

    -- Update middleware for a specific route pattern
    ["/__keyway/api/routes/{pattern}/middleware"] = {
        PUT = function(ctx)
            local ok, body = pcall(cjson.decode, ctx.body)
            if not ok or type(body.middleware) ~= "table" then
                response.json_response(ctx, 400, { error = "JSON body with 'middleware' array required" })
                return
            end

            local pattern = "/" .. url_decode(ctx.params.pattern)

            -- Validate all middleware names exist in registry
            for _, name in ipairs(body.middleware) do
                if not keyway.middleware._registry[name] then
                    response.json_response(ctx, 400, { error = "unknown middleware: " .. tostring(name) })
                    return
                end
            end

            -- Find the route in keyway.routes
            local route_entry = keyway.routes[pattern]
            if not route_entry or type(route_entry) ~= "table" then
                response.json_response(ctx, 404, { error = "route not found: " .. pattern })
                return
            end

            -- Resolve string names to functions and update in-memory route
            local resolved = {}
            for _, name in ipairs(body.middleware) do
                resolved[#resolved + 1] = keyway.middleware.resolve(name)
            end
            route_entry.middleware = resolved

            -- Clear mw_name cache so names re-resolve on next API call
            _mw_name_cache = setmetatable({}, { __mode = "k" })

            -- Best-effort Redis persistence (inside coroutine, so yields work)
            pcall(function()
                local redis = require("keyway.redis_ring")
                -- Build full overrides map from current route state
                local overrides = {}
                each_static_route(function(p, methods, _, _)
                    if methods.middleware and #methods.middleware > 0 then
                        local names = {}
                        for j, mw in ipairs(methods.middleware) do
                            names[#names + 1] = mw_name(mw, j, "mw_")
                        end
                        overrides[p] = names
                    end
                end)
                if keyway.routes.middleware then
                    local global_names = {}
                    for j, mw in ipairs(keyway.routes.middleware) do
                        global_names[#global_names + 1] = mw_name(mw, j, "global_mw_")
                    end
                    overrides["__global"] = global_names
                end
                redis.set("keyway:mw:overrides", cjson.encode(overrides))
            end)

            response.json_response(ctx, 200, { ok = true, pattern = pattern })
        end,
    },

    -- Update global middleware order
    ["/__keyway/api/middleware/global"] = {
        PUT = function(ctx)
            local ok, body = pcall(cjson.decode, ctx.body)
            if not ok or type(body.middleware) ~= "table" then
                response.json_response(ctx, 400, { error = "JSON body with 'middleware' array required" })
                return
            end

            -- Validate all middleware names exist in registry
            for _, name in ipairs(body.middleware) do
                if not keyway.middleware._registry[name] then
                    response.json_response(ctx, 400, { error = "unknown middleware: " .. tostring(name) })
                    return
                end
            end

            -- Resolve string names to functions and update global middleware
            local resolved = {}
            for _, name in ipairs(body.middleware) do
                resolved[#resolved + 1] = keyway.middleware.resolve(name)
            end
            keyway.routes.middleware = resolved

            -- Clear mw_name cache
            _mw_name_cache = setmetatable({}, { __mode = "k" })

            response.json_response(ctx, 200, { ok = true })
        end,
    },

    -- Sync: load overrides from Redis and apply to in-memory routes
    ["/__keyway/api/middleware/sync"] = {
        POST = function(ctx)
            local ok_redis, redis = pcall(require, "keyway.redis_ring")
            if not ok_redis then
                response.json_response(ctx, 200, { synced = false, reason = "redis not available" })
                return
            end

            local data, err = redis.get("keyway:mw:overrides")
            if not data then
                response.json_response(ctx, 200, { synced = false, reason = err or "no overrides saved" })
                return
            end

            local ok_json, overrides = pcall(cjson.decode, data)
            if not ok_json then
                response.json_response(ctx, 200, { synced = false, reason = "invalid json in redis" })
                return
            end

            local applied = 0

            -- Apply global middleware
            if overrides["__global"] then
                local resolved = {}
                local all_ok = true
                for _, name in ipairs(overrides["__global"]) do
                    local fn = keyway.middleware._registry[name]
                    if fn then
                        resolved[#resolved + 1] = fn
                    else
                        all_ok = false
                    end
                end
                if all_ok and #resolved > 0 then
                    keyway.routes.middleware = resolved
                    applied = applied + 1
                end
            end

            -- Apply per-route overrides
            for pattern, names in pairs(overrides) do
                if pattern ~= "__global" and keyway.routes[pattern] then
                    local resolved = {}
                    local all_ok = true
                    for _, name in ipairs(names) do
                        local fn = keyway.middleware._registry[name]
                        if fn then
                            resolved[#resolved + 1] = fn
                        else
                            all_ok = false
                        end
                    end
                    if all_ok then
                        keyway.routes[pattern].middleware = resolved
                        applied = applied + 1
                    end
                end
            end

            -- Clear mw_name cache
            _mw_name_cache = setmetatable({}, { __mode = "k" })

            response.json_response(ctx, 200, { synced = true, applied = applied })
        end,
    },

    -- ─── File Management API ────────────────────────────────────

    -- List all .lua files in the script directory
    ["/__keyway/api/files"] = {
        GET = function(ctx)
            local files = __keyway_file_list("scripts")
            response.json_response(ctx, 200, { files = files or {} })
        end,
    },

    -- Read a file
    ["/__keyway/api/files/{path}"] = {
        GET = function(ctx)
            local decoded = url_decode(ctx.params.path)
            local file_path = "scripts/" .. decoded
            local content, err = __keyway_file_read(file_path)
            if not content then
                response.json_response(ctx, 404, { error = err or "not found" })
                return
            end
            response.json_response(ctx, 200, { path = decoded, content = content })
        end,
        PUT = function(ctx)
            local ok, body = pcall(cjson.decode, ctx.body)
            if not ok or not body.content then
                response.json_response(ctx, 400, { error = "JSON body with 'content' field required" })
                return
            end
            local decoded = url_decode(ctx.params.path)
            local file_path = "scripts/" .. decoded
            local success, err = __keyway_file_write(file_path, body.content)
            if not success then
                response.json_response(ctx, 500, { error = err or "write failed" })
                return
            end
            response.json_response(ctx, 200, { path = decoded, ok = true })
        end,
        DELETE = function(ctx)
            local decoded = url_decode(ctx.params.path)
            local file_path = "scripts/" .. decoded
            local success, err = __keyway_file_delete(file_path)
            if not success then
                response.json_response(ctx, 404, { error = err or "not found" })
                return
            end
            response.json_response(ctx, 200, { ok = true })
        end,
    },

    -- Toggle file enabled/disabled (.lua <-> .lua.disabled)
    ["/__keyway/api/files/{path}/toggle"] = {
        POST = function(ctx)
            local decoded = url_decode(ctx.params.path)
            local file_path = "scripts/" .. decoded
            local new_path
            if decoded:match("%.lua%.disabled$") then
                new_path = "scripts/" .. decoded:gsub("%.disabled$", "")
            elseif decoded:match("%.lua$") then
                new_path = file_path .. ".disabled"
            else
                response.json_response(ctx, 400, { error = "not a .lua file" })
                return
            end
            local ok, err = __keyway_file_rename(file_path, new_path)
            if not ok then
                response.json_response(ctx, 500, { error = err or "rename failed" })
                return
            end
            -- Compute new relative path
            local new_rel = new_path:gsub("^scripts/", "")
            response.json_response(ctx, 200, { ok = true, path = new_rel })
        end,
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
