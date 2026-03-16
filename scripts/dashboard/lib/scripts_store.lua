-- scripts_store.lua — Script CRUD, Redis persistence, loadstring sandbox
local cjson = require("cjson")
local ffi = require("ffi")
local redis = require("scripts.dashboard.lib.redis_ring")

local M = {}

local REDIS_KEY = "kw:scripts"
local SCRIPTS_PATH = "scripts/dashboard/scripts.json"

-- Sandbox environment for user scripts
local function make_sandbox()
    return {
        string = string, table = table, math = math,
        tonumber = tonumber, tostring = tostring,
        pairs = pairs, ipairs = ipairs, type = type,
        pcall = pcall, xpcall = xpcall, error = error,
        select = select, unpack = unpack,
        os = { time = os.time, clock = os.clock },
        cjson = cjson,
        -- Keyway modules
        socket = require("keyway.socket"),
        dns = require("keyway.dns"),
        response = require("keyway.response"),
    }
end

-- Generate 16-char hex ID
pcall(ffi.cdef, [[int open(const char *path, int flags); long read(int fd, void *buf, long count); int close(int fd);]])

local function generate_id()
    local fd = ffi.C.open("/dev/urandom", 0)
    if fd < 0 then
        return string.format("%08x%08x", os.time(), math.random(0, 0x7fffffff))
    end
    local buf = ffi.new("uint8_t[8]")
    ffi.C.read(fd, buf, 8)
    ffi.C.close(fd)
    local hex = {}
    for i = 0, 7 do hex[#hex + 1] = string.format("%02x", buf[i]) end
    return table.concat(hex)
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

-- Seed Redis from scripts.json if key doesn't exist (file I/O, no yield)
function M.seed_from_file()
    local f = io.open(SCRIPTS_PATH, "r")
    if not f then return end
    local data = f:read("*a")
    f:close()
    local ok, scripts = pcall(cjson.decode, data)
    if not ok or type(scripts) ~= "table" then return end
    -- Write to Redis (this yields, so must be called from a coroutine)
    local existing = redis.get(REDIS_KEY)
    if not existing then
        redis.set(REDIS_KEY, cjson.encode(scripts))
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
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
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
            s.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
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
            s.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
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
