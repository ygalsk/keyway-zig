-- scripts_store.lua — Script CRUD, Redis persistence, loadstring sandbox
local cjson = require("cjson")
local response = require("keyway.response")
local redis = require("scripts.dashboard.lib.redis_ring")

local M = {}

local REDIS_KEY = "kw:scripts"

-- Sandbox environment for user scripts
local function make_sandbox()
    return {
        string = string, table = table, math = math,
        tonumber = tonumber, tostring = tostring,
        pairs = pairs, ipairs = ipairs, type = type,
        pcall = pcall, xpcall = xpcall, error = error,
        select = select, unpack = unpack,
        cjson = cjson,
        -- Keyway modules
        socket = require("keyway.socket"),
        dns = require("keyway.dns"),
        response = response,
    }
end

-- Generate 16-char hex ID using math.random (seeded at load time)
math.randomseed(response.now_us())

local function generate_id()
    return string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

-- Load scripts from Redis
function M.load()
    local data, err = redis.get(REDIS_KEY)
    if not data then return {} end
    local ok, scripts = pcall(cjson.decode, data)
    if not ok or type(scripts) ~= "table" then return {} end
    return scripts
end

-- Save scripts to Redis
function M.save(scripts)
    return redis.set(REDIS_KEY, cjson.encode(scripts))
end

-- Default seed scripts (no file I/O — inline data)
local SEED_SCRIPTS = {
    {
        id = "0b4a1c5b02221552", name = "Request Logger", type = "middleware",
        pattern = ".", priority = 0, enabled = false,
        code = "local response = require(\"keyway.response\")\n\nreturn function(ctx, next)\n  local t0 = response.now_us()\n  next()\n  local elapsed = math.floor(response.now_us() - t0)\n  ctx.headers[\"X-Request-Time-Us\"] = tostring(elapsed)\nend",
        metrics = { calls = 0, errors = 0, avg_latency_us = 0 },
    },
}

-- Seed Redis with defaults if key doesn't exist (yields via redis ring)
function M.seed_from_defaults()
    local existing = redis.get(REDIS_KEY)
    if not existing then
        redis.set(REDIS_KEY, cjson.encode(SEED_SCRIPTS))
    end
end

-- Compile script code in sandbox, returns function or nil+error
function M.compile(code)
    local fn, err = loadstring(code)
    if not fn then return nil, "syntax error: " .. (err or "unknown") end
    local sandbox = make_sandbox()
    setfenv(fn, sandbox)
    local ok, result = pcall(fn)
    if not ok then return nil, "runtime error: " .. tostring(result) end
    if type(result) ~= "function" then
        return nil, "script must return a function, got " .. type(result)
    end
    -- Wrap returned function in sandbox
    setfenv(result, sandbox)
    return result
end

-- CRUD operations

function M.create(params)
    local scripts = M.load()
    local id = generate_id()
    local now = tostring(math.floor(response.now_us() / 1000000))
    local script = {
        id = id,
        name = params.name or "Untitled",
        type = params.type or "middleware",
        pattern = params.pattern or ".",
        priority = params.priority or 0,
        enabled = false,
        code = params.code or "return function(ctx, next) next() end",
        trigger_condition = params.trigger_condition,
        metrics = { calls = 0, errors = 0, avg_latency_us = 0 },
        created_at = now,
        updated_at = now,
    }
    scripts[#scripts + 1] = script
    M.save(scripts)
    return script
end

function M.get(id)
    local scripts = M.load()
    for _, s in ipairs(scripts) do
        if s.id == id then return s end
    end
    return nil
end

function M.update(id, params)
    local scripts = M.load()
    for i, s in ipairs(scripts) do
        if s.id == id then
            if params.name then s.name = params.name end
            if params.type then s.type = params.type end
            if params.pattern then s.pattern = params.pattern end
            if params.priority ~= nil then s.priority = params.priority end
            if params.code then s.code = params.code end
            if params.trigger_condition ~= nil then s.trigger_condition = params.trigger_condition end
            s.updated_at = tostring(math.floor(response.now_us() / 1000000))
            scripts[i] = s
            M.save(scripts)
            return s
        end
    end
    return nil
end

function M.delete(id)
    local scripts = M.load()
    for i, s in ipairs(scripts) do
        if s.id == id then
            table.remove(scripts, i)
            M.save(scripts)
            return true
        end
    end
    return false
end

function M.toggle(id)
    local scripts = M.load()
    for i, s in ipairs(scripts) do
        if s.id == id then
            s.enabled = not s.enabled
            s.updated_at = tostring(math.floor(response.now_us() / 1000000))
            scripts[i] = s
            M.save(scripts)
            return s
        end
    end
    return nil
end

function M.list()
    return M.load()
end

return M
