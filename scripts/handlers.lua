-- handlers.lua — Route registration for Keyway
-- Loaded independently by each worker thread at startup.
-- This file is the entry point: it loads templates, requires route modules,
-- and merges them into keyway.routes.

-- ================================================================
-- JIT optimizations
-- ================================================================
-- (LuaJIT defaults are good; this section reserved for future tuning)

-- ================================================================
-- Template loading (each worker independently)
-- ================================================================
local template = require("keyway.template")

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
template.load("short")
template.load("paste")
template.load("paste_detail")
template.load("ratelimit")
template.load("chat")
template.load("websocket")

-- ================================================================
-- Route modules
-- ================================================================
local route_modules = {
    require("routes.static"),
    require("routes.kv"),
    require("routes.probe"),
    require("routes.hooks"),
    require("routes.db"),
    require("routes.dns"),
    require("routes.scripts"),
    require("routes.short"),
    require("routes.paste"),
    require("routes.ratelimit"),
    require("routes.chat"),
    require("routes.webhook"),
    require("routes.tls_test"),
    require("routes.websocket"),
}

-- ================================================================
-- Merge all route modules into keyway.routes
-- ================================================================
keyway.routes = {}

for _, mod in ipairs(route_modules) do
    for path, handlers in pairs(mod) do
        keyway.routes[path] = handlers
    end
end
