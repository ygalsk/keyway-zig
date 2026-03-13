-- routes/db.lua — PostgreSQL CRUD via pgmoon + cosocket (Neon hosted Postgres)
local form      = require("keyway.form")
local pg_client = require("keyway.postgres")
local resp      = require("keyway.response")

-- Postgres config
local pg_config = {
    host     = os.getenv("PGHOST") or "localhost",
    port     = os.getenv("PGPORT") or "5432",
    user     = os.getenv("PGUSER") or "postgres",
    password = os.getenv("PGPASSWORD") or "",
    database = os.getenv("PGDATABASE") or "neondb",
}

local CREATE_TABLE = [[
    CREATE TABLE IF NOT EXISTS notes (
        id SERIAL PRIMARY KEY,
        author VARCHAR(100) NOT NULL DEFAULT 'anonymous',
        content TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
]]

local table_created = false

local function db_connect()
    return pg_client.connect(pg_config)
end

-- Ensure the notes table exists (runs once per worker)
local function ensure_table(pg)
    if table_created then return true end
    local create_ok, create_err = pg:query(CREATE_TABLE)
    if not create_ok then return nil, create_err end
    table_created = true
    return true
end

local function db_page(ctx, pg, vars)
    -- Fetch notes + server time in a single round-trip
    local notes_res, query_err = pg:query(
        "SELECT id, author, content, created_at, now() AS server_time FROM notes ORDER BY created_at DESC"
    )
    local reuse = pg.sock and pg.sock:getreusedtimes() or 0
    if not notes_res then
        vars.error_msg = "Query error: " .. (query_err or "unknown")
    elseif notes_res[1] then
        vars.server_time = notes_res[1].server_time
        for _, note in ipairs(notes_res) do
            note.relative_time = resp.relative_time(note.created_at)
        end
        vars.notes = notes_res
    else
        -- No notes yet -- fetch server_time separately
        local time_res = pg:query("SELECT now() AS t")
        vars.server_time = time_res and time_res[1] and time_res[1].t
        vars.notes = notes_res
    end
    pg_client.keepalive(pg)
    vars.reuse_count = reuse

    resp.html_response(ctx, "db", vars)
end

return {
    ["/db"] = {
        GET = function(ctx)
            local pg, connect_err = db_connect()
            if not pg then
                resp.error_response(ctx, "db", 502, "Postgres error: " .. (connect_err or "unknown"))
                return
            end

            local schema_ok, schema_err = ensure_table(pg)
            if not schema_ok then
                pg_client.keepalive(pg)
                resp.error_response(ctx, "db", 502, "Schema error: " .. (schema_err or "unknown"))
                return
            end

            db_page(ctx, pg, {})
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local action = fields.action or ""

            local pg, connect_err = db_connect()
            if not pg then
                resp.error_response(ctx, "db", 502, "Postgres error: " .. (connect_err or "unknown"))
                return
            end

            local schema_ok, schema_err = ensure_table(pg)
            if not schema_ok then
                pg_client.keepalive(pg)
                resp.error_response(ctx, "db", 502, "Schema error: " .. (schema_err or "unknown"))
                return
            end

            local vars = {}

            if action == "add" then
                local author  = fields.author or ""
                local content = fields.content or ""
                author = resp.trim(author)
                content = resp.trim(content)

                if content == "" then
                    vars.error_msg = "Note content cannot be empty"
                else
                    if author == "" then author = "anonymous" end
                    local query = "INSERT INTO notes (author, content) VALUES ("
                        .. pg:escape_literal(author) .. ", "
                        .. pg:escape_literal(content) .. ") RETURNING id"
                    local insert_res, query_err = pg:query(query)
                    if insert_res then
                        local new_id = insert_res[1] and insert_res[1].id or nil
                        resp.broadcast_event("db", {
                            type = "add",
                            note = {
                                id = new_id,
                                author = author,
                                content = content,
                                relative_time = "just now",
                            },
                        })
                        vars.result_msg = "Note added by " .. author
                    else
                        vars.error_msg = "Insert error: " .. (query_err or "unknown")
                    end
                end
            elseif action == "delete" then
                local id = fields.id or ""
                if id:match("^%d+$") then
                    local delete_res, query_err = pg:query("DELETE FROM notes WHERE id = " .. id)
                    if delete_res then
                        resp.broadcast_event("db", {
                            type = "delete",
                            id = tonumber(id),
                        })
                        vars.result_msg = "Note #" .. id .. " deleted"
                    else
                        vars.error_msg = "Delete error: " .. (query_err or "unknown")
                    end
                else
                    vars.error_msg = "Invalid note ID"
                end
            else
                vars.error_msg = "Unknown action"
            end

            db_page(ctx, pg, vars)
        end,
    },

    ["/db/events"] = {
        GET = function(ctx)
            ctx.upgrade = resp.UPGRADE_SSE
            ctx.sse_room = "db"
        end,
    },
}
