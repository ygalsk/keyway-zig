-- keyway.lua — Admin dashboard + file management control plane
-- Lua files on disk control the runtime. The dashboard is a file editor.
-- Run from the repo root (as `zig build run` does): this example's static
-- and file-API paths are resolved relative to the current working directory,
-- not to this script's location.

local response = require("keyway.response")
local json = require("keyway.json")

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

-- Resolve a middleware function's name via the registry (reverse lookup);
-- anonymous middleware not in the registry falls back to "mw_<index>".
local function mw_name(mw, index)
    for name, fn in pairs(keyway.middleware._registry) do
        if fn == mw then return name end
    end
    return "mw_" .. index
end

local function each_static_route(cb)
    for pattern, methods in pairs(keyway.routes) do
        if type(methods) == "table" and pattern ~= "middleware" then
            local mw_names = {}
            if methods.middleware then
                for j, mw in ipairs(methods.middleware) do
                    mw_names[#mw_names + 1] = mw_name(mw, j)
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
        -- Allow localhost and Docker bridge networks (172.x.x.x)
        if addr ~= "127.0.0.1" and addr ~= "::1" and not addr:match("^172%.") then
            ctx.status = 403
            ctx.body = "Forbidden"
            return
        end
    end
    next()
end

-- Register built-in middleware
keyway.middleware.register("localhost_guard", localhost_guard)

local function ws_reply(ws, tbl)
    ws:send(json.encode(tbl))
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
    ["/__keyway/dashboard"] = { root = "dashboard/public", index = "index.html" },
}

-- ─── Reverse Proxy Mounts ────────────────────────────────────────────

keyway.proxy = {
    ["/__keyway/grafana"] = { host = "127.0.0.1", port = 3000, redirect = "/__keyway/dashboard/grafana.html", strip_prefix = false },
}

-- ─── Routes ──────────────────────────────────────────────────────────

keyway.routes = {
    middleware = { localhost_guard },

    -- Dashboard: WebSocket command interface
    ["/__keyway/ws"] = {
        GET = function(ctx)
            ctx.upgrade = "websocket"
            ctx.on_message = function(ws)
                local ok, msg = pcall(json.decode, ws.message)
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
                    global_mw[#global_mw + 1] = { name = mw_name(mw, i), index = i }
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
                    effective.global_middleware[#effective.global_middleware + 1] = mw_name(mw, i)
                end
            end
            each_static_route(function(pattern, _, mw_names, http_methods)
                effective.routes[#effective.routes + 1] = {
                    pattern = pattern,
                    methods = http_methods,
                    middleware = mw_names,
                }
            end)
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
            local ok, body = pcall(json.decode, ctx.body)
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

            response.json_response(ctx, 200, { ok = true, pattern = pattern })
        end,
    },

    -- Update global middleware order
    ["/__keyway/api/middleware/global"] = {
        PUT = function(ctx)
            local ok, body = pcall(json.decode, ctx.body)
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

            response.json_response(ctx, 200, { ok = true })
        end,
    },

    -- ─── File Management API ────────────────────────────────────

    -- List all .lua files in the script directory
    ["/__keyway/api/files"] = {
        GET = function(ctx)
            local files = __keyway_file_list("dashboard")
            response.json_response(ctx, 200, { files = files or {} })
        end,
    },

    -- Read a file
    ["/__keyway/api/files/{path}"] = {
        GET = function(ctx)
            local decoded = url_decode(ctx.params.path)
            local file_path = "dashboard/" .. decoded
            local content, err = __keyway_file_read(file_path)
            if not content then
                response.json_response(ctx, 404, { error = err or "not found" })
                return
            end
            response.json_response(ctx, 200, { path = decoded, content = content })
        end,
        PUT = function(ctx)
            local ok, body = pcall(json.decode, ctx.body)
            if not ok or not body.content then
                response.json_response(ctx, 400, { error = "JSON body with 'content' field required" })
                return
            end
            local decoded = url_decode(ctx.params.path)
            if decoded:match("%.lua$") then
                local fn, lerr = loadstring(body.content, "@" .. decoded)
                if not fn then
                    response.json_response(ctx, 422, { error = lerr })
                    return
                end
            end
            local file_path = "dashboard/" .. decoded
            local success, err = __keyway_file_write(file_path, body.content)
            if not success then
                response.json_response(ctx, 500, { error = err or "write failed" })
                return
            end
            response.json_response(ctx, 200, { path = decoded, ok = true })
        end,
        DELETE = function(ctx)
            local decoded = url_decode(ctx.params.path)
            local file_path = "dashboard/" .. decoded
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
            local file_path = "dashboard/" .. decoded
            local new_path
            if decoded:match("%.lua%.disabled$") then
                new_path = "dashboard/" .. decoded:gsub("%.disabled$", "")
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
            local new_rel = new_path:gsub("^dashboard/", "")
            response.json_response(ctx, 200, { ok = true, path = new_rel })
        end,
    },

}
