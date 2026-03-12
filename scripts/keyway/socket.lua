-- keyway.socket — LuaSocket-compatible wrapper over cosocket primitives
-- Now uses the I/O ring internally for all operations.
-- Connection pooling is deep by design — setkeepalive() with zero args just works.
--
-- Methods live on a shared metatable — tcp() only creates one small state table.

local socket = {}

-- Helper: push one op to ring, submit, return single result
local function ring_one(op, ...)
    __keyway_ring_push(op, ...)
    local n = __keyway_ring_submit()
    if n == 0 then return nil, "ring submit returned 0" end
    local result, buf, err = __keyway_ring_result(0)
    return result, buf, err
end

-- Shared method table (created once at require time, not per-request)
local tcp_mt = {}
tcp_mt.__index = tcp_mt

function tcp_mt:connect(host, port, opts)
    self.pool_name = (opts and opts.pool) or (host .. ":" .. tostring(port))
    self.read_buf = ""
    self._host = host

    -- Try pool first (synchronous path via old API for pool hit)
    local fd, reuse = __keyway_pool_connect(self.pool_name, host, port)
    if not fd then
        return nil, reuse or "connection failed"
    end

    self.fd = fd
    self.reuse_count = reuse or 0
    return 1
end

function tcp_mt:send(data)
    if not self.fd then return nil, "not connected" end
    local result, _, err = ring_one("send", self.fd, data)
    if result < 0 then return nil, err or "send failed" end
    return result
end

function tcp_mt:receive(pattern)
    if not self.fd then return nil, "not connected" end

    pattern = pattern or "*l"

    if pattern == "*l" then
        local parts = { self.read_buf }
        local total = #self.read_buf
        local pos = self.read_buf:find("\n")
        while not pos do
            local result, buf, err = ring_one("recv", self.fd, 4096)
            if result < 0 then return nil, err or "recv failed" end
            if not buf or #buf == 0 then return nil, "closed" end
            parts[#parts + 1] = buf
            total = total + #buf
            -- Check for newline in the new chunk
            local buf_so_far = table.concat(parts)
            pos = buf_so_far:find("\n")
            if pos then
                parts = { buf_so_far }
            end
        end
        local buf = type(parts[1]) == "string" and #parts == 1 and parts[1] or table.concat(parts)
        local line = buf:sub(1, pos - 1)
        self.read_buf = buf:sub(pos + 1)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        return line

    elseif pattern == "*a" then
        -- Reads one chunk only (not full stream) — caller must loop for complete reads
        if #self.read_buf > 0 then
            local data = self.read_buf
            self.read_buf = ""
            return data
        end
        local result, buf, err = ring_one("recv", self.fd, 4096)
        if result < 0 then return nil, err or "recv failed" end
        return buf

    elseif type(pattern) == "number" then
        -- Collect chunks in a table, concat once (O(n) total vs O(n²) repeated ..)
        local parts = { self.read_buf }
        local total = #self.read_buf
        while total < pattern do
            local result, buf, err = ring_one("recv", self.fd, 4096)
            if result < 0 then return nil, err or "recv failed" end
            if not buf or #buf == 0 then return nil, "closed" end
            parts[#parts + 1] = buf
            total = total + #buf
        end
        local buf = table.concat(parts)
        local data = buf:sub(1, pattern)
        self.read_buf = buf:sub(pattern + 1)
        return data
    end

    return nil, "invalid receive pattern"
end

function tcp_mt:sslhandshake(reused_session, server_name)
    if not self.fd then return nil, "not connected" end
    local sni = server_name or self._host
    -- TLS handshake is multi-round-trip, keep using old single-shot API
    local ok, err = __keyway_io_sslhandshake(self.fd, sni)
    if not ok then return nil, err end
    return 1
end

function tcp_mt:close()
    if not self.fd then return nil, "not connected" end
    local result, _, err = ring_one("close", self.fd)
    self.fd = nil
    if result < 0 then return nil, err or "close failed" end
    return 1
end

function tcp_mt:setkeepalive(timeout_ms, pool_size)
    if not self.fd then return nil, "not connected" end
    if not self.pool_name then return nil, "no pool name" end

    -- setkeepalive is synchronous, but still goes through ring for consistency
    local ok, err = __keyway_pool_setkeepalive(
        self.fd,
        self.pool_name,
        timeout_ms or 0,
        pool_size or 0,
        self.reuse_count
    )

    self.fd = nil
    self.read_buf = ""
    return ok, err
end

function tcp_mt:getreusedtimes()
    return self.reuse_count
end

-- No-op stub: timeouts are managed at the Zig io_uring level
function tcp_mt:settimeout(ms)
    self._timeout = ms
end

--- Create a new TCP socket object.
-- Only allocates one small table; methods are on a shared metatable.
function socket.tcp()
    return setmetatable({
        fd = nil,
        reuse_count = 0,
        read_buf = "",
        pool_name = nil,
    }, tcp_mt)
end

return socket
