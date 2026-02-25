-- keyway.ngx_shim — Minimal ngx global so pgmoon uses cosocket mode.
--
-- pgmoon checks: if ngx and ngx.get_phase() ~= "init" → use ngx.socket.tcp()
-- pgmoon/util.lua checks: if ngx → use ngx.encode_base64/decode_base64
--
-- In nginx cosocket mode, pgmoon calls sock:send({table, of, strings})
-- which OpenResty handles natively. Keyway's __keyway_io_send only takes
-- a single string, so we wrap each socket's send to table.concat table args.

local keyway_socket = require("keyway.socket")

-- Flatten nested tables of strings (matches pgmoon.util.flatten behavior)
local function flatten_send(t)
    if type(t) == "string" then return t end
    if type(t) == "table" then
        local buf = {}
        for i = 1, #t do
            local v = t[i]
            if type(v) == "table" then
                buf[#buf + 1] = flatten_send(v)
            else
                buf[#buf + 1] = tostring(v)
            end
        end
        return table.concat(buf)
    end
    return tostring(t)
end

ngx = {
    socket = {
        tcp = function()
            local sock = keyway_socket.tcp()
            -- Wrap send to flatten table args before forwarding
            local raw_send = sock.send
            sock.send = function(self, data)
                if type(data) == "table" then
                    data = flatten_send(data)
                end
                return raw_send(self, data)
            end
            return sock
        end,
    },

    get_phase = function()
        return "content"
    end,

    -- base64 stubs — only needed for SCRAM-SHA-256 auth (trust auth skips these)
    encode_base64 = function(s)
        error("ngx.encode_base64 stub called — use trust auth in pg_hba.conf")
    end,
    decode_base64 = function(s)
        error("ngx.decode_base64 stub called — use trust auth in pg_hba.conf")
    end,
}
