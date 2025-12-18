-- Keystone Gateway Handlers
-- Uses zero-copy userdata API - req and resp are Zig structs, not Lua tables
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
end
-- List all users
keystone.add_route("GET", "/users", function(req, resp)
    resp:set_status(200)
    resp:set_body("Lua Handler: User list [Alice, Bob, Charlie]")
end)

-- Get specific user by ID
keystone.add_route("GET", "/users/{id}", function(req, resp)
    local user_id = req:get_param("id") or "unknown"
    resp:set_status(200)
    resp:set_body("Lua Handler: User details for ID: " .. user_id)
end)

-- Create a new user
keystone.add_route("POST", "/users", function(req, resp)
    local body = req:get_body()
    -- Could parse JSON here using Lua libraries
    resp:set_status(201)
    resp:set_body("Lua Handler: User created successfully")
end)

-- Example handler showing method access
keystone.add_route("GET", "/debug", function(req, resp)
    local method = req:get_method()
    local path = req:get_path()
    resp:set_status(200)
    resp:set_body("Method: " .. method .. ", Path: " .. path)
end)

print("[Lua] Handlers registered successfully")
