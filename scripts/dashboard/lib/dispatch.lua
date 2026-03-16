-- dispatch.lua — Script dispatch middleware
local scripts_store = require("scripts.dashboard.lib.scripts_store")
local response = require("keyway.response")

local M = {}

local _handlers = {}     -- "METHOD /path" -> {fn, id, enabled, name}
local _middleware = {}    -- ordered: [{pattern, fn, id, enabled, priority, name}]
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

    local scripts = scripts_store.load()
    for _, s in ipairs(scripts) do
        if s.enabled then
            local fn, err = scripts_store.compile(s.code)
            if fn then
                if s.type == "handler" then
                    local method, path = s.pattern:match("^(%u+)%s+(.+)$")
                    if not method then
                        method = "GET"
                        path = s.pattern
                    end
                    local key = method .. " " .. path
                    _handlers[key] = {
                        fn = fn, id = s.id, enabled = true, name = s.name,
                    }
                else
                    _middleware[#_middleware + 1] = {
                        pattern = s.pattern, fn = fn, id = s.id,
                        enabled = true, priority = s.priority or 0, name = s.name,
                    }
                end
            end
        end
    end

    -- Sort middleware by priority (higher first), stable tiebreaker by id
    table.sort(_middleware, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return (a.id or "") < (b.id or "")
    end)
    _loaded = true
end

-- Last matched scripts — populated during dispatch, read by access_log_middleware
M._last_matched = {}

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
        h.fn(ctx)
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
                local called_next = false
                mw.fn(ctx, function()
                    called_next = true
                end)
                if not called_next then return end
            end
        end
        next()
    end
    run_next()
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
                hits = 0,
                errors = 0,
                avg_latency_us = 0,
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
            hits = 0,
            errors = 0,
            avg_latency_us = 0,
        }
    end
    return routes
end

return M
