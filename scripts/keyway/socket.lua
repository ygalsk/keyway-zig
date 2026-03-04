-- keyway.socket — LuaSocket-compatible wrapper over cosocket primitives
-- Provides tcp() objects with connect/send/receive/close/setkeepalive.
-- Connection pooling is deep by design — setkeepalive() with zero args just works.
--
-- Methods live on a shared metatable — tcp() only creates one small state table.

local socket = {}

-- Shared method table (created once at require time, not per-request)
local tcp_mt = {}
tcp_mt.__index = tcp_mt

function tcp_mt:connect(host, port, opts)
    self.pool_name = (opts and opts.pool) or (host .. ":" .. tostring(port))
    self.read_buf = ""

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
    return __keyway_io_send(self.fd, data)
end

function tcp_mt:receive(pattern)
    if not self.fd then return nil, "not connected" end

    pattern = pattern or "*l"

    if pattern == "*l" then
        local parts = { self.read_buf }
        local total = #self.read_buf
        local pos = self.read_buf:find("\n")
        while not pos do
            local chunk, err = __keyway_io_recv(self.fd, 4096)
            if not chunk then return nil, err or "recv failed" end
            if #chunk == 0 then return nil, "closed" end
            parts[#parts + 1] = chunk
            total = total + #chunk
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
        local chunk, err = __keyway_io_recv(self.fd, 4096)
        if not chunk then return nil, err or "recv failed" end
        return chunk

    elseif type(pattern) == "number" then
        -- Collect chunks in a table, concat once (O(n) total vs O(n²) repeated ..)
        local parts = { self.read_buf }
        local total = #self.read_buf
        while total < pattern do
            local chunk, err = __keyway_io_recv(self.fd, 4096)
            if not chunk then return nil, err or "recv failed" end
            if #chunk == 0 then return nil, "closed" end
            parts[#parts + 1] = chunk
            total = total + #chunk
        end
        local buf = table.concat(parts)
        local data = buf:sub(1, pattern)
        self.read_buf = buf:sub(pattern + 1)
        return data
    end

    return nil, "invalid receive pattern"
end

function tcp_mt:close()
    if not self.fd then return nil, "not connected" end
    local ok, err = __keyway_io_close(self.fd)
    self.fd = nil
    return ok, err
end

function tcp_mt:setkeepalive(timeout_ms, pool_size)
    if not self.fd then return nil, "not connected" end
    if not self.pool_name then return nil, "no pool name" end

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
