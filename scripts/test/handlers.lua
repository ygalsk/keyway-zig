-- Minimal test fixture for zig build test
-- Provides a single route to validate script loading and route registration.

keyway.routes = {
    ["/"] = {
        GET = function(ctx)
            ctx.status = 200
            ctx.body = "ok"
        end,
    },
}
