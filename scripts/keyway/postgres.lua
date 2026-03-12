-- keyway.postgres — PostgreSQL client wrapper using cosocket + pgmoon
-- Bridges pgmoon (luarocks) with keyway.socket for non-blocking I/O.
-- Usage:
--   local pg_client = require("keyway.postgres")
--   local pg, err = pg_client.connect({ host = "...", user = "...", ... })
--   if pg then
--       local res = pg:query("SELECT 1 AS n")
--       pg_client.keepalive(pg)
--   end

local socket  = require("keyway.socket")
local dns     = require("keyway.dns")
require("keyway.pgcrypto")  -- install openssl.* shims before pgmoon loads
local flatten = require("pgmoon.util").flatten

local resolve_host = dns.resolve_host

-- Patch pgmoon.socket.new to return our cosocket (with table-send support)
-- instead of calling ngx.socket.tcp(). Must happen before require("pgmoon").
local pgmoon_socket = require("pgmoon.socket")
pgmoon_socket.new = function(sock_type)
    local sock = socket.tcp()

    -- pgmoon sends nested tables to sock:send(); our cosocket expects a string.
    local orig_send = sock.send
    sock.send = function(self, data)
        if type(data) == "table" then
            data = flatten(data)
        end
        return orig_send(self, data)
    end

    -- pgmoon calls sock:connect(ip, port, opts) which sets _host = ip.
    -- We need _host to stay as the original hostname for TLS SNI/verification.
    -- Preserve any pre-set _sni_host across the connect call.
    local orig_connect = sock.connect
    sock.connect = function(self, host, port, opts)
        local sni = self._sni_host
        local ok, err = orig_connect(self, host, port, opts)
        if sni then self._host = sni end
        return ok, err
    end

    return sock, "nginx"
end

local pgmoon = require("pgmoon")

-- pgmoon prefers SCRAM-SHA-256-PLUS when advertised, but that requires
-- extracting the TLS peer certificate (resty.openssl.ssl) for channel binding.
-- We don't have that — force plain SCRAM-SHA-256 by stripping -PLUS from the
-- server's auth message before pgmoon's mechanism selection logic runs.
-- Methods live on __base (MoonScript OOP), not on the class table directly.
local pg_base = pgmoon.Postgres.__base or pgmoon.Postgres
local orig_scram = pg_base.scram_sha_256_auth
pg_base.scram_sha_256_auth = function(self, msg)
    -- Replace the PLUS mechanism name (null-separated in wire protocol)
    msg = msg:gsub("SCRAM%-SHA%-256%-PLUS%z", "")
    return orig_scram(self, msg)
end

local M = {}

--- Connect to PostgreSQL using cosocket, returning a pgmoon client.
-- @param config  table with host, port, user, password, database, ssl fields
-- @return pg, err  pgmoon Postgres object or nil + error string
function M.connect(config)
    local host = config.host
    local port = config.port or "5432"

    -- Resolve DNS hostname to IP (cosocket connect needs a numeric address)
    local ip, dns_err = resolve_host(host)
    if not ip then
        return nil, dns_err
    end

    local pg = pgmoon.new({
        host = ip,
        port = port,
        user = config.user,
        password = config.password,
        database = config.database,
        ssl = config.ssl ~= false,  -- default true (Neon requires SSL)
        socket_type = "nginx",
        application_name = config.application_name or "keyway",
        -- Pool key uses hostname so connections to same logical DB are reused
        pool_name = host .. ":" .. port .. ":" .. (config.database or "") .. ":" .. (config.user or ""),
    })

    -- Store original hostname so TLS SNI uses the real hostname, not the IP.
    -- Our patched connect() restores _host from _sni_host after connecting.
    pg.sock._sni_host = host

    local ok, err = pg:connect()
    if not ok then
        return nil, "Postgres connection failed: " .. (err or "unknown")
    end

    return pg
end

--- Return the connection to the cosocket pool for reuse.
-- Call this instead of pg:disconnect() to enable connection pooling.
-- @param pg  pgmoon Postgres object returned by M.connect()
function M.keepalive(pg)
    if pg.sock then
        pg:keepalive()
    end
end

--- Close the connection without pooling.
-- @param pg  pgmoon Postgres object returned by M.connect()
function M.close(pg)
    if pg.sock then
        pg:disconnect()
    end
end

return M
