-- routes/scripts.lua — Script Console + saved Redis Lua functions
local form         = require("keyway.form")
local redis_client = require("keyway.redis")
local cjson        = require("cjson")
local resp         = require("keyway.response")
local redis_util   = require("keyway.redis_util")

-- Fetch all saved functions from Redis (fn:* keys)
local function list_functions(client)
    local keys = {}
    local scan_ok = pcall(function()
        local cursor = "0"
        repeat
            local res = client:scan(cursor, "match", "fn:*", "count", 100)
            cursor = res[1]
            for _, k in ipairs(res[2]) do keys[#keys + 1] = k end
        until cursor == "0"
    end)
    if not scan_ok or #keys == 0 then return {} end
    table.sort(keys)
    local mget_ok, values = pcall(function() return client:mget(unpack(keys)) end)
    if not mget_ok or not values then return {} end
    local fns = {}
    for i, key in ipairs(keys) do
        local raw = values[i]
        if raw then
            local decode_ok, data = pcall(cjson.decode, raw)
            if decode_ok and data then
                data.name = key:sub(4) -- strip "fn:" prefix
                fns[#fns + 1] = data
            end
        end
    end
    return fns
end

return {
    ["/scripts"] = {
        GET = function(ctx)
            local functions = redis_util.with_redis(function(client) return list_functions(client) end) or {}
            resp.html_response(ctx, "scripts", { functions = functions })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local action = fields.action or ""

            local client, connect_err = redis_client.connect()
            if not client then
                resp.error_response(ctx, "scripts", 502, "Redis error: " .. (connect_err or "unknown"))
                return
            end

            local vars = {}

            if action == "eval" then
                local script = fields.script or ""
                local keys_list = resp.split_csv(fields.keys_input)
                local argv_list = resp.split_csv(fields.argv_input)

                local t0 = resp.now_us()
                local eval_args = resp.build_eval_args(script, keys_list, argv_list)

                local eval_ok, result = pcall(function()
                    return client:eval(unpack(eval_args))
                end)
                local elapsed = math.floor(resp.now_us() - t0)

                if eval_ok then
                    local display
                    if type(result) == "table" then
                        display = cjson.encode(result)
                    else
                        display = tostring(result)
                    end
                    vars.eval_result = display
                    vars.eval_time_us = elapsed
                else
                    vars.eval_error = tostring(result)
                end

            elseif action == "save" then
                local name = resp.trim(fields.name or "")
                local script = fields.script or ""

                if not name:match("^[%w_%-]+$") then
                    vars.error_msg = "Invalid name -- use letters, numbers, hyphens, underscores only"
                elseif script == "" then
                    vars.error_msg = "Script cannot be empty"
                else
                    local now = os.time()
                    -- Check if it already exists (preserve created_at)
                    local existing_raw = client:get("fn:" .. name)
                    local created_at = now
                    if existing_raw then
                        local decode_ok, existing = pcall(cjson.decode, existing_raw)
                        if decode_ok and existing and existing.created_at then
                            created_at = existing.created_at
                        end
                    end

                    local data = cjson.encode({
                        script = script,
                        description = fields.description or "",
                        created_at = created_at,
                        updated_at = now,
                    })
                    local save_ok, save_err = pcall(function() client:set("fn:" .. name, data) end)
                    if save_ok then
                        vars.success_msg = "Saved as /fn/" .. name
                    else
                        vars.error_msg = "Save failed: " .. tostring(save_err)
                    end
                end

            elseif action == "load" then
                local name = fields.name or ""
                local raw = client:get("fn:" .. name)
                if raw then
                    local decode_ok, data = pcall(cjson.decode, raw)
                    if decode_ok and data then
                        vars.script_name = name
                        vars.script_body = data.script
                        vars.script_description = data.description or ""
                    end
                end

            elseif action == "delete" then
                local name = fields.name or ""
                if name ~= "" then
                    pcall(function() client:del("fn:" .. name) end)
                    vars.success_msg = "Deleted " .. name
                end
            end

            -- Preserve editor state for eval/save (load/delete set their own)
            if action == "eval" or action == "save" then
                vars.script_body = vars.script_body or fields.script
                vars.script_name = vars.script_name or fields.name
                vars.script_description = vars.script_description or fields.description
                vars.keys_input = vars.keys_input or fields.keys_input
                vars.argv_input = vars.argv_input or fields.argv_input
            end

            vars.functions = list_functions(client)
            redis_client.keepalive(client)
            resp.html_response(ctx, "scripts", vars)
        end,
    },

    -- Dynamic function endpoints -- execute saved Redis Lua scripts via HTTP
    ["/fn/{name}"] = (function()
        local function exec_fn(ctx)
            local name = ctx.params.name or ""

            local client, connect_err = redis_client.connect()
            if not client then
                resp.json_response(ctx, 502, { error = "Redis error: " .. (connect_err or "unknown") })
                return
            end

            local raw = client:get("fn:" .. name)
            if not raw then
                redis_client.keepalive(client)
                resp.json_response(ctx, 404, { error = "Function not found: " .. name })
                return
            end

            local decode_ok, data = pcall(cjson.decode, raw)
            if not decode_ok or not data then
                redis_client.keepalive(client)
                resp.json_response(ctx, 500, { error = "Corrupt function data" })
                return
            end

            -- Parse keys/argv from query params or form body
            local keys_str, argv_str
            if ctx.method == "POST" then
                local post_fields = form.parse(ctx.body)
                keys_str = post_fields.keys or ""
                argv_str = post_fields.argv or ""
            else
                keys_str = ctx.query.keys or ""
                argv_str = ctx.query.argv or ""
            end
            local keys_list = resp.split_csv(keys_str)
            local argv_list = resp.split_csv(argv_str)

            local eval_args = resp.build_eval_args(data.script, keys_list, argv_list)

            local t0 = resp.now_us()
            local eval_ok, result = pcall(function()
                return client:eval(unpack(eval_args))
            end)
            local elapsed = math.floor(resp.now_us() - t0)
            redis_client.keepalive(client)

            if eval_ok then
                resp.json_response(ctx, 200, { result = result, time_us = elapsed })
            else
                resp.json_response(ctx, 500, { error = tostring(result), time_us = elapsed })
            end
        end

        return {
            GET  = exec_fn,
            POST = exec_fn,
        }
    end)(),
}
