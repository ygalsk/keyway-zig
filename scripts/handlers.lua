-- Keystone Gateway Handlers
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
print("[Lua] Registering /users route...")
-- List all users
keystone.add_route("GET", "/users", function(ctx)
    ctx.status = 200
    ctx.body = "pong"
end)

print("[Lua] Registering /ping route...")
keystone.add_route("GET", "/ping", function(ctx)
    ctx.status = 200
    ctx.body = "pong"
end)

-- Global table (persists across requests in the same thread)
local cache = {}
local count = 0
local user_cache = {}

print("[Lua] Registering /users/{id} route...")

keystone.add_route("GET", "/users/{id}", function(ctx)
    local user_id = ctx.params.id
    local role = (tonumber(user_id) or 0) % 2 == 0 and "admin" or "guest"

    -- Build JSON string without buffer for now
    local json = '{"id": ' .. user_id .. ', "role": "' .. role .. '", "status": "active"}'

    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"
    ctx.body = json
end)

-- Redis-backed route (using LuaRocks redis client)
print("[Lua] Registering /users-redis/{id} route...")

-- Create Redis client (reused across requests per worker)
local redis_client = require('redis')
local redis_conn = nil

keystone.add_route("GET", "/users-redis/{id}", function(ctx)
    local user_id = ctx.params.id

    -- Lazy connect to Redis (blocking, but connection pooling would be per-worker)
    if not redis_conn then
        redis_conn = redis.connect({
            host = '127.0.0.1',
            port = 6379,
        })
    end

    -- Blocking Redis GET (this is the bottleneck we'll measure)
    local user_data = redis_conn:get('user:' .. user_id)

    ctx.status = 200
    ctx.headers["Content-Type"] = "application/json"

    if user_data then
        ctx.body = user_data
    else
        -- Fallback if key doesn't exist
        ctx.body = '{"id": ' .. user_id .. ', "error": "not found"}'
    end
end)

-- Create a new user
keystone.add_route("POST", "/users", function(ctx)
    local body = ctx.body
    -- Could parse JSON here using Lua libraries
    ctx.status = 201
    ctx.body = "Lua Handler: User created successfully"
end)

-- Example handler showing method access
keystone.add_route("GET", "/debug", function(ctx)
    local method = ctx.method
    local path = ctx.path
    ctx.status = 200
    ctx.body = "Method: " .. method .. ", Path: " .. path
end)

print("[Lua] Handlers registered successfully")
