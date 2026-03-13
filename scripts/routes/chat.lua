-- routes/chat.lua — Cassandra chat rooms
local form        = require("keyway.form")
local cass_client = require("keyway.cassandra")
local resp        = require("keyway.response")

-- Cassandra config (Astra: host=<db-id>-<region>.apps.astra.datastax.com, port=29042, username=token)
local cass_config = {
    host     = os.getenv("CASS_HOST") or "127.0.0.1",
    port     = tonumber(os.getenv("CASS_PORT") or "29042"),
    keyspace = os.getenv("CASS_KEYSPACE") or "keyway",
    username = os.getenv("CASS_USERNAME") or "token",
    password = os.getenv("CASS_PASSWORD"),
    ssl      = os.getenv("CASS_SSL") ~= "false",
}

local schema_created = false

local function ensure_schema(client)
    if schema_created then return true end
    local rooms_ok, rooms_err = client:execute([[
        CREATE TABLE IF NOT EXISTS rooms (
            name text PRIMARY KEY
        )
    ]])
    if not rooms_ok then return nil, rooms_err end
    local msgs_ok, msgs_err = client:execute([[
        CREATE TABLE IF NOT EXISTS messages (
            room text,
            ts timestamp,
            author text,
            body text,
            PRIMARY KEY (room, ts)
        ) WITH CLUSTERING ORDER BY (ts DESC)
    ]])
    if not msgs_ok then return nil, msgs_err end
    schema_created = true
    return true
end

return {
    ["/chat"] = {
        GET = function(ctx)
            local client, connect_err = cass_client.connect(cass_config)
            if not client then
                resp.error_response(ctx, "chat", 502, "Cassandra error: " .. (connect_err or "unknown"))
                return
            end

            local schema_ok, schema_err = ensure_schema(client)
            if not schema_ok then
                cass_client.keepalive(client)
                resp.error_response(ctx, "chat", 502, "Schema error: " .. (schema_err or "unknown"))
                return
            end

            local rows, query_err = client:execute("SELECT name FROM rooms")
            cass_client.keepalive(client)

            resp.html_response(ctx, "chat", {
                rooms = rows or {},
            })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local name = resp.trim(fields.name or "")

            if name == "" or not name:match("^[a-zA-Z0-9_%-]+$") then
                resp.html_response(ctx, "chat", { error_msg = "Room name is required (letters, numbers, dashes, underscores)" })
                return
            end

            local client, connect_err = cass_client.connect(cass_config)
            if not client then
                resp.error_response(ctx, "chat", 502, "Cassandra error: " .. (connect_err or "unknown"))
                return
            end

            local schema_ok, schema_err = ensure_schema(client)
            if not schema_ok then
                cass_client.keepalive(client)
                resp.error_response(ctx, "chat", 502, "Schema error: " .. (schema_err or "unknown"))
                return
            end

            client:execute("INSERT INTO rooms (name) VALUES (?)", { name })
            cass_client.keepalive(client)

            ctx.status = 303
            ctx.headers["Location"] = "/chat/" .. name
            ctx.body = ""
        end,
    },

    ["/chat/{room}"] = (function()
        local cassandra_mod = require("cassandra")

        return {
            GET = function(ctx)
                local room = ctx.params.room or ""

                local client, connect_err = cass_client.connect(cass_config)
                if not client then
                    resp.error_response(ctx, "chat", 502, "Cassandra error: " .. (connect_err or "unknown"))
                    return
                end

                local rows, query_err = client:execute(
                    "SELECT ts, author, body FROM messages WHERE room = ? ORDER BY ts DESC LIMIT 50",
                    { room }
                )
                cass_client.keepalive(client)

                resp.html_response(ctx, "chat", {
                    room = room,
                    messages = rows or {},
                })
            end,

            POST = function(ctx)
                local room = ctx.params.room or ""
                local fields = form.parse(ctx.body)
                local author = resp.trim(fields.author or "")
                local body = resp.trim(fields.body or "")

                if author == "" then author = "anonymous" end

                if body == "" then
                    resp.html_response(ctx, "chat", {
                        room = room,
                        messages = {},
                        error_msg = "Message body is required",
                    })
                    return
                end

                local client, connect_err = cass_client.connect(cass_config)
                if not client then
                    resp.error_response(ctx, "chat", 502, "Cassandra error: " .. (connect_err or "unknown"))
                    return
                end

                -- Use current time in milliseconds as CQL timestamp
                local now_ms = math.floor(os.time() * 1000)
                client:execute(
                    "INSERT INTO messages (room, ts, author, body) VALUES (?, ?, ?, ?)",
                    { room, cassandra_mod.timestamp(now_ms), author, body }
                )
                cass_client.keepalive(client)

                -- Broadcast to SSE subscribers
                resp.broadcast_event(room, {
                    author = author,
                    body = body,
                    ts = tostring(now_ms),
                })

                ctx.status = 303
                ctx.headers["Location"] = "/chat/" .. room
                ctx.body = ""
            end,
        }
    end)(),

    ["/chat/{room}/events"] = {
        GET = function(ctx)
            ctx.upgrade = resp.UPGRADE_SSE
            ctx.sse_room = ctx.params.room
        end,
    },
}
