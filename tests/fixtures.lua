-- Integration-test reference surface.
-- Compose the opt-in dashboard control plane, then add test-only fixtures.
dofile("dashboard/keyway.lua")

local response = require("keyway.response")

local function mw_before(ctx, next)
    ctx.headers["X-MW-Before"] = "applied"
    next()
end

local function mw_after(ctx, next)
    next()
    ctx.headers["X-MW-After"] = "applied"
end

keyway.middleware.register("mw_before", mw_before)
keyway.middleware.register("mw_after", mw_after)

-- Integration-test upstreams (see tests/integration/proxy.test.ts).
keyway.proxy["/__keyway/test-proxy"] = { host = "127.0.0.1", port = 38291, strip_prefix = true }
keyway.proxy["/__keyway/test-proxy-dead"] = { host = "127.0.0.1", port = 1, strip_prefix = true }
keyway.proxy["/__keyway/test-proxy-hung"] = { host = "127.0.0.1", port = 38292, strip_prefix = true }

keyway.routes["/test/hello"] = {
    GET = function(ctx)
        ctx.status = 200
        ctx.body = "hello world"
    end,
}

keyway.routes["/test/users/{id}"] = {
    GET = function(ctx)
        response.json_response(ctx, 200, { id = ctx.params.id })
    end,
}

keyway.routes["/test/search"] = {
    GET = function(ctx)
        response.json_response(ctx, 200, { q = ctx.query.q })
    end,
}

keyway.routes["/test/headers"] = {
    GET = function(ctx)
        local ua = response.get_header(ctx, "User-Agent") or "unknown"
        ctx.status = 200
        ctx.headers["X-Echo-UA"] = ua
        ctx.headers["X-Worker"] = tostring(keyway.worker_id)
        ctx.body = "headers ok"
    end,
}

keyway.routes["/test/echo"] = {
    POST = function(ctx)
        ctx.status = 200
        ctx.body = ctx.body
    end,
}

keyway.routes["/test/status/{code}"] = {
    GET = function(ctx)
        local code = tonumber(ctx.params.code) or 200
        ctx.status = code
        ctx.body = "status " .. tostring(code)
    end,
}

keyway.routes["/test/json"] = {
    GET = function(ctx)
        response.json_response(ctx, 200, { message = "hello", worker_id = keyway.worker_id })
    end,
}

keyway.routes["/test/sse"] = {
    GET = function(ctx)
        ctx.upgrade = "sse"
        ctx.sse_room = "test:events"
    end,
}

-- (#192) Sets on_message/on_close (like a WS handler would) but leaves
-- sse_room unset, so the SSE upgrade is rejected with 400 — exercises the
-- Lua-registry-ref cleanup on the SSE reject path.
keyway.routes["/test/sse-no-room"] = {
    GET = function(ctx)
        ctx.on_message = function() end
        ctx.on_close = function() end
        ctx.upgrade = "sse"
    end,
}

keyway.routes["/test/ws"] = {
    GET = function(ctx)
        ctx.upgrade = "websocket"
        ctx.on_message = function(ws)
            ws:send(ws.message)
        end
        ctx.on_close = function() end
    end,
}

keyway.routes["/test/stream"] = {
    GET = function(ctx)
        ctx.upgrade = "stream"
        ctx.status = 200
        ctx.body = "chunk1\n"
        coroutine.yield()
        ctx.body = "chunk2\n"
        coroutine.yield()
        ctx.body = "chunk3\n"
        coroutine.yield()
    end,
}

keyway.routes["/test/broadcast"] = {
    POST = function(ctx)
        local data = ctx.body
        pcall(response.broadcast_event, "test:events", { message = data })
        ctx.status = 200
        ctx.body = "ok"
    end,
}

-- (#176) Response header CRLF injection regression: a response header value
-- containing a literal CRLF + a fake header name must not split into a
-- second, real response header at serialize time (src/http/http.zig
-- Response.serialize). Set directly here rather than via a request header,
-- since fetch()/picohttpparser both refuse literal CRLF in a header value
-- before it would ever reach Lua as a single value.
keyway.routes["/test/header-injection"] = {
    GET = function(ctx)
        ctx.status = 200
        ctx.headers["X-Bad"] = "a\r\nX-Injected: evil"
        ctx.body = "ok"
    end,
}

keyway.routes["/test/mw"] = {
    middleware = { mw_before, mw_after },
    GET = function(ctx)
        ctx.status = 200
        ctx.body = "middleware ok"
    end,
}
