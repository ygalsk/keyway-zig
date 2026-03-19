-- keyway.db_socket — Shared socket helpers for database client wrappers
-- Provides table-send flattening and SNI-preserving connect for cosockets.

local socket = require("keyway.socket")
local dns    = require("keyway.dns")

local M = {}

M.resolve_host = dns.resolve_host

--- Create a cosocket with table-send flattening and SNI-preserving connect.
-- @param flatten_fn  function(data) -> string  converts table data to string before send
-- @return sock
function M.tcp(flatten_fn)
    local sock = socket.tcp()

    local orig_send = sock.send
    sock.send = function(self, data)
        if type(data) == "table" then
            data = flatten_fn(data)
        end
        return orig_send(self, data)
    end

    -- Preserve SNI hostname across connect (DNS resolves to IP, TLS needs hostname)
    local orig_connect = sock.connect
    sock.connect = function(self, host, port, opts)
        local sni = self._sni_host
        local ok, err = orig_connect(self, host, port, opts)
        if sni then self._host = sni end
        return ok, err
    end

    return sock
end

return M
