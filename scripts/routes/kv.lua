-- routes/kv.lua — Key-value store routes
local form         = require("keyway.form")
local redis_client = require("keyway.redis")
local resp         = require("keyway.response")
local redis_util   = require("keyway.redis_util")

return {
    ["/kv"] = {
        GET = function(ctx)
            local keys, err = redis_util.redis_keys()
            resp.html_response(ctx, "kv", {
                keys = keys,
                error_msg = err,
            })
        end,

        POST = function(ctx)
            local fields = form.parse(ctx.body)
            local action = fields.action or ""
            local key    = fields.key or ""
            local value  = fields.value or ""

            local result
            local err_msg

            if key == "" then
                err_msg = "Key cannot be empty"
            else
                local client, connect_err = redis_client.connect()
                if not client then
                    err_msg = connect_err
                else
                    local call_ok, res = pcall(function()
                        if action == "set" then
                            client:set(key, value)
                            return { action = "set", key = key, display_value = value }
                        elseif action == "get" then
                            local val = client:get(key)
                            return { action = "get", key = key, value = val }
                        elseif action == "del" then
                            local count = client:del(key)
                            return { action = "del", key = key, count = count }
                        else
                            return nil
                        end
                    end)
                    redis_client.keepalive(client)

                    if call_ok then
                        result = res
                    else
                        err_msg = "Redis error: " .. tostring(res)
                    end
                end
            end

            -- Always refresh key list
            local keys, keys_err = redis_util.redis_keys()
            if not keys and not err_msg then
                err_msg = keys_err
            end

            resp.html_response(ctx, "kv", {
                keys = keys,
                result = result,
                error_msg = err_msg,
                success_msg = (result and not err_msg) and "Operation completed",
            })
        end,
    },
}
