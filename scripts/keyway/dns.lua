-- keyway.dns — DNS A-record lookup via UDP cosocket
-- Sends a raw DNS query to 8.8.8.8:53 and parses the A record response.

local M = {}

local RESOLVER     = "8.8.8.8"
local RESOLVER_PORT = 53
local TIMEOUT_MS   = 3000
local QUERY_ID     = 0x1234

-- Encode a domain as a DNS query packet for A records.
-- Returns a binary string in DNS wire format.
local function build_query(domain)
    -- Header: ID, Flags (RD=1), QDCOUNT=1, all others 0
    local header = string.char(
        math.floor(QUERY_ID / 256), QUERY_ID % 256,  -- ID from constant
        0x01, 0x00,  -- Flags: recursion desired
        0x00, 0x01,  -- QDCOUNT = 1
        0x00, 0x00,  -- ANCOUNT = 0
        0x00, 0x00,  -- NSCOUNT = 0
        0x00, 0x00   -- ARCOUNT = 0
    )

    -- Encode domain as length-prefixed labels: "example.com" → \x07example\x03com\x00
    local parts = {}
    for part in domain:gmatch("[^%.]+") do
        parts[#parts + 1] = string.char(#part) .. part
    end
    parts[#parts + 1] = string.char(0)
    local labels = table.concat(parts)

    -- Question: QTYPE=1 (A), QCLASS=1 (IN)
    local question = labels .. string.char(0x00, 0x01, 0x00, 0x01)

    return header .. question
end

-- Skip a DNS name at position `pos` in `data`.
-- Returns the position after the name.
local function skip_name(data, pos)
    while pos <= #data do
        local len = string.byte(data, pos)
        pos = pos + 1
        if len == 0 then
            return pos
        elseif len >= 0xC0 then
            -- Compression pointer — consume one more byte
            return pos + 1
        else
            pos = pos + len
        end
    end
    return pos
end

-- Parse a DNS response and extract A record IP strings.
-- Returns array of IP strings, or nil + error string.
local function parse_response(data)
    if #data < 12 then return nil, "response too short" end

    -- Verify ID
    local resp_id = string.byte(data, 1) * 256 + string.byte(data, 2)
    if resp_id ~= QUERY_ID then return nil, "response ID mismatch" end

    -- Check RCODE (lower 4 bits of byte 4)
    local rcode = string.byte(data, 4) % 16
    if rcode ~= 0 then
        local msgs = { [1]="format error", [2]="server failure", [3]="name not found", [5]="refused" }
        return nil, msgs[rcode] or ("DNS error " .. rcode)
    end

    local qdcount = string.byte(data, 5) * 256 + string.byte(data, 6)
    local ancount = string.byte(data, 7) * 256 + string.byte(data, 8)

    -- Skip header (12 bytes) + question section
    local pos = 13
    for _ = 1, qdcount do
        pos = skip_name(data, pos)
        pos = pos + 4  -- QTYPE + QCLASS
    end

    -- Parse answer records, collect A records
    local records = {}
    for _ = 1, ancount do
        if pos > #data then break end
        pos = skip_name(data, pos)

        if pos + 10 > #data then break end
        local rtype = string.byte(data, pos) * 256 + string.byte(data, pos + 1)
        local rdlen = string.byte(data, pos + 8) * 256 + string.byte(data, pos + 9)
        pos = pos + 10

        if rtype == 1 and rdlen == 4 and pos + 3 <= #data then
            records[#records + 1] = string.byte(data, pos)     .. "."
                                 .. string.byte(data, pos + 1) .. "."
                                 .. string.byte(data, pos + 2) .. "."
                                 .. string.byte(data, pos + 3)
        end
        pos = pos + rdlen
    end

    return records
end

--- Perform a DNS A-record lookup for `domain`.
-- Returns: records (array of IP strings), or nil, error_msg
function M.lookup(domain)
    if not domain or domain == "" then
        return nil, "domain is required"
    end
    -- Reject bare IP addresses
    if domain:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil, "enter a domain name, not an IP address"
    end

    local query = build_query(domain)

    -- Open UDP socket (connected to resolver, with timeout)
    local fd, err = __keyway_io_udp_connect(RESOLVER, RESOLVER_PORT, TIMEOUT_MS)
    if not fd then
        return nil, "connect failed: " .. (err or "unknown")
    end

    -- Send DNS query
    local _, serr = __keyway_io_send(fd, query)
    if not _ then
        __keyway_io_close(fd)
        return nil, "send failed: " .. (serr or "unknown")
    end

    -- Receive response (512 bytes = standard DNS UDP maximum)
    local resp, rerr = __keyway_io_recv(fd, 512)
    __keyway_io_close(fd)

    if not resp then
        return nil, "DNS query timed out"
    end

    local records, perr = parse_response(resp)
    if not records then
        return nil, perr or "failed to parse DNS response"
    end
    if #records == 0 then
        return nil, "no A records found for " .. domain
    end

    return records
end

return M
