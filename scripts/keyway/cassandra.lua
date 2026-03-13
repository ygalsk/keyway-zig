-- keyway.cassandra — Cassandra client wrapper using cosocket + lua-cassandra
-- Bridges lua-cassandra (luarocks) with keyway.socket for non-blocking I/O.
-- Usage:
--   local cass_client = require("keyway.cassandra")
--   local client, err = cass_client.connect({ host = "...", ... })
--   if client then
--       local rows = client:execute("SELECT * FROM table")
--       cass_client.keepalive(client)
--   end

local db_socket = require("keyway.db_socket")

local resolve_host = db_socket.resolve_host

-- Recursive flatten for lua-cassandra's nested table sends
local function cass_flatten(data)
    local buf = {}
    local function flatten(v)
        if type(v) == "string" then buf[#buf + 1] = v
        elseif type(v) == "number" then buf[#buf + 1] = tostring(v)
        elseif type(v) == "table" then
            for i = 1, #v do flatten(v[i]) end
        end
    end
    flatten(data)
    return table.concat(buf)
end

-- Patch cassandra.socket.tcp to return our cosocket instead of LuaSocket.
local cass_socket = require("cassandra.socket")

cass_socket.tcp = function()
    local sock = db_socket.tcp(cass_flatten)

    -- lua-cassandra calls sock:sslhandshake(false, nil, verify, params)
    -- Our cosocket expects (reused_session, server_name, no_verify_or_mode)
    -- Use "custom" mode when CASS_TLS_* env vars are set (mTLS with client certs),
    -- otherwise fall back to "insecure" (skip verification for private CAs)
    local tls_mode = os.getenv("CASS_TLS_CA") and "custom" or "insecure"
    local orig_sslhandshake = sock.sslhandshake
    sock.sslhandshake = function(self, reused_session, server_name, _verify, _params)
        return orig_sslhandshake(self, reused_session, nil, tls_mode)
    end

    return sock
end

local cassandra = require("cassandra")

local M = {}

--- Connect to Cassandra using cosocket, returning a lua-cassandra client.
-- @param config  table with host, port, keyspace, username, password, ssl fields
-- @return client, err  cassandra Host object or nil + error string
function M.connect(config)
    local host = config.host or "127.0.0.1"
    local port = config.port or 9042

    -- Resolve DNS hostname to IP (cosocket connect needs a numeric address)
    local ip, dns_err = resolve_host(host)
    if not ip then
        return nil, dns_err
    end

    local opts = {
        host = ip,
        port = port,
        keyspace = config.keyspace,
        ssl = config.ssl ~= false,
        protocol_version = config.protocol_version or 4,
    }

    -- Auth: Astra uses token-based auth (username="token", password=AstraCS:...)
    if config.username and config.password then
        opts.auth = cassandra.auth_providers.plain_text(
            config.username,
            config.password
        )
    end

    local client, err = cassandra.new(opts)
    if not client then
        return nil, "Cassandra client creation failed: " .. (err or "unknown")
    end

    -- Store original hostname so TLS SNI uses the real hostname, not the IP
    client.sock._sni_host = host

    local ok, conn_err = client:connect()
    if not ok then
        return nil, "Cassandra connection failed: " .. (conn_err or "unknown")
    end

    -- Astra Serverless requires LOCAL_QUORUM (rejects ONE, LOCAL_ONE, ANY)
    -- Wrap execute to inject consistency as default
    local orig_execute = client.execute
    client.execute = function(self, query, args, options)
        options = options or {}
        if not options.consistency then
            options.consistency = cassandra.consistencies.local_quorum
        end
        return orig_execute(self, query, args, options)
    end

    return client
end

--- Return the connection to the cosocket pool for reuse.
-- @param client  cassandra Host object returned by M.connect()
function M.keepalive(client)
    if client and client.sock then
        client:setkeepalive()
    end
end

--- Close the connection without pooling.
-- @param client  cassandra Host object returned by M.connect()
function M.close(client)
    if client and client.sock then
        client:close()
    end
end

return M
