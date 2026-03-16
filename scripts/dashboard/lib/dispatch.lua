-- dispatch.lua — Script dispatch middleware + event condition evaluator
local scripts_store = require("scripts.dashboard.lib.scripts_store")
local response = require("keyway.response")

local M = {}

local _handlers = {}     -- "METHOD /path" -> {fn, id, enabled, name, metrics}
local _middleware = {}    -- ordered: [{pattern, fn, id, enabled, priority, name, metrics}]
local _conditions = {}   -- event-driven: [{id, check_fn, activate_script_id}]
local _loaded = false
local _seeded = false

-- Seed Redis with defaults on first load (if key doesn't exist)
local function seed_if_needed()
    if _seeded then return end
    _seeded = true
    pcall(scripts_store.seed_from_defaults)
end

-- Reload all scripts from persistence, recompile
function M.reload()
    _handlers = {}
    _middleware = {}
    _conditions = {}

    local scripts = scripts_store.load()
    for _, s in ipairs(scripts) do
        if s.enabled then
            local fn, err = scripts_store.compile(s.code)
            if fn then
                if s.type == "handler" then
                    -- Handler: pattern is "METHOD /path" or just "/path" (all methods)
                    local method, path = s.pattern:match("^(%u+)%s+(.+)$")
                    if not method then
                        -- Default to GET if no method specified
                        method = "GET"
                        path = s.pattern
                    end
                    local key = method .. " " .. path
                    _handlers[key] = {
                        fn = fn, id = s.id, enabled = true,
                        name = s.name, metrics = s.metrics,
                    }
                else
                    -- Middleware: pattern is Lua pattern for path matching
                    _middleware[#_middleware + 1] = {
                        pattern = s.pattern, fn = fn, id = s.id,
                        enabled = true, priority = s.priority or 0,
                        name = s.name, metrics = s.metrics,
                    }
                end

                -- Parse trigger conditions
                if s.trigger_condition and s.trigger_condition ~= "" then
                    local cond_fn, cond_err = loadstring("return function(m) return " .. s.trigger_condition .. " end")
                    if cond_fn then
                        local ok, check = pcall(cond_fn)
                        if ok and type(check) == "function" then
                            _conditions[#_conditions + 1] = {
                                id = s.id,
                                check_fn = check,
                                activate_script_id = s.id,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Sort middleware by priority (higher first)
    table.sort(_middleware, function(a, b) return a.priority > b.priority end)
    _loaded = true
end

-- Last matched scripts — populated during dispatch, read by access_log_middleware
M._last_matched = {}
-- Last error from dispatch — populated on pcall failure, read by access_log_middleware
M._last_error = nil

-- Error handler for xpcall — captures traceback
local function _err_handler(e)
    return debug.traceback(tostring(e), 2)
end

-- Global middleware — registered once at startup, runs on every request
function M.dispatch(ctx, next)
    if not _loaded then
        seed_if_needed()
        M.reload()
    end
    M._last_matched = {}

    -- 1. Check script route handlers (exact match)
    local key = (ctx.method or "GET") .. " " .. (ctx.path or "/")
    local h = _handlers[key]
    if h and h.enabled then
        M._last_matched[#M._last_matched + 1] = { id = h.id, name = h.name }
        h.metrics.calls = h.metrics.calls + 1
        local t0 = response.now_us()
        local ok, err = xpcall(h.fn, _err_handler, ctx)
        local elapsed = response.now_us() - t0
        h.metrics.avg_latency_us = math.floor((h.metrics.avg_latency_us * (h.metrics.calls - 1) + elapsed) / h.metrics.calls)
        if not ok then
            h.metrics.errors = h.metrics.errors + 1
            M._last_error = err
        end
        return
    end

    -- 2. Run matching middleware scripts (priority-ordered)
    local idx = 1
    local function run_next()
        while idx <= #_middleware do
            local mw = _middleware[idx]
            idx = idx + 1
            if mw.enabled and ctx.path and ctx.path:match(mw.pattern) then
                M._last_matched[#M._last_matched + 1] = { id = mw.id, name = mw.name }
                mw.metrics.calls = mw.metrics.calls + 1
                local t0 = response.now_us()
                local called_next = false
                local ok, err = xpcall(mw.fn, _err_handler, ctx, function()
                    called_next = true
                end)
                local elapsed = response.now_us() - t0
                mw.metrics.avg_latency_us = math.floor((mw.metrics.avg_latency_us * (mw.metrics.calls - 1) + elapsed) / mw.metrics.calls)
                if not ok then
                    mw.metrics.errors = mw.metrics.errors + 1
                    M._last_error = err
                end
                if not called_next then return end
            end
        end
        next()
    end
    run_next()
end

-- Evaluate event conditions (called periodically or on metric update)
function M.evaluate_conditions(current_metrics)
    for _, cond in ipairs(_conditions) do
        local ok, should_activate = pcall(cond.check_fn, current_metrics)
        if ok then
            if should_activate then
                M.enable_script(cond.activate_script_id)
            end
        end
    end
end

-- Enable/disable a specific script by ID
function M.enable_script(id)
    local s = scripts_store.toggle(id)
    if s and s.enabled then M.reload() end
end

function M.disable_script(id)
    local s = scripts_store.get(id)
    if s and s.enabled then
        scripts_store.toggle(id)
        M.reload()
    end
end

-- Get runtime metrics for a script
function M.get_metrics(id)
    for _, h in pairs(_handlers) do
        if h.id == id then return h.metrics end
    end
    for _, mw in ipairs(_middleware) do
        if mw.id == id then return mw.metrics end
    end
    return nil
end

-- List all registered routes (compiled handlers + middleware)
function M.list_routes()
    if not _loaded then
        seed_if_needed()
        M.reload()
    end
    local routes = {}
    -- Handlers
    for key, h in pairs(_handlers) do
        local method, path = key:match("^(%u+)%s+(.+)$")
        if method and path then
            routes[#routes + 1] = {
                method = method,
                pattern = path,
                handler = h.name or "anonymous",
                middleware = {},
                hits = h.metrics and h.metrics.calls or 0,
                errors = h.metrics and h.metrics.errors or 0,
                avg_latency_us = h.metrics and h.metrics.avg_latency_us or 0,
            }
        end
    end
    -- Middleware as pseudo-routes
    for _, mw in ipairs(_middleware) do
        routes[#routes + 1] = {
            method = "MW",
            pattern = mw.pattern,
            handler = mw.name or "anonymous",
            middleware = {},
            hits = mw.metrics and mw.metrics.calls or 0,
            errors = mw.metrics and mw.metrics.errors or 0,
            avg_latency_us = mw.metrics and mw.metrics.avg_latency_us or 0,
        }
    end
    return routes
end

return M
