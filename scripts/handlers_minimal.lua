-- Minimal test - just two simple routes
keystone.add_route("GET", "/users", function(req, resp)
    resp:set_status(200)
    resp:set_body("users")
end)

keystone.add_route("GET", "/ping", function(req, resp)
    resp:set_status(200)
    resp:set_body("pong")
end)

print("[Lua] Minimal handlers registered successfully")
