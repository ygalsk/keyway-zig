-- keyway.ring — Batched I/O ring buffer for cosocket operations
-- Push multiple I/O ops, submit once, get all results back in one yield.
--
-- Usage:
--   local ring = require("keyway.ring")
--   local r = ring.new()
--   r:connect("127.0.0.1", 6379)
--   r:connect("127.0.0.1", 5432)
--   local results = r:submit()  -- one yield, two connects
--   -- results[1].fd, results[2].fd

local ring = {}
local ring_mt = { __index = ring }

function ring.new()
    return setmetatable({}, ring_mt)
end

function ring:connect(host, port)
    __keyway_ring_push("connect", host, port)
end

function ring:send(fd, data)
    __keyway_ring_push("send", fd, data)
end

function ring:recv(fd, max_len)
    __keyway_ring_push("recv", fd, max_len or 4096)
end

function ring:close(fd)
    __keyway_ring_push("close", fd)
end

function ring:pool_connect(pool_name, host, port)
    __keyway_ring_push("pool_connect", pool_name, host, port)
end

function ring:setkeepalive(fd, pool_name, timeout_ms, pool_size, reuse_count)
    __keyway_ring_push("setkeepalive", fd, pool_name, timeout_ms or 0, pool_size or 0, reuse_count or 0)
end

function ring:tls_handshake(fd, sni_host)
    __keyway_ring_push("tls_handshake", fd, sni_host)
end

function ring:udp_connect(host, port, timeout_ms)
    __keyway_ring_push("udp_connect", host, port, timeout_ms or 0)
end

--- Submit all queued operations, yield once, return array of results.
-- Each result: { result = int, buf = string|nil, err = string|nil, fd = int|nil }
function ring:submit()
    local n = __keyway_ring_submit()
    local results = {}
    for i = 0, n - 1 do
        local result, buf, err = __keyway_ring_result(i)
        results[i + 1] = {
            result = result,
            buf = buf,
            err = err,
            fd = (result > 0) and result or nil,
        }
    end
    return results
end

return ring
