//! Embedded Lua stdlib sources — imported by lua_state.zig at compile time.
//! This file lives in scripts/keyway/ so @embedFile can resolve sibling .lua files.

pub const socket = @embedFile("socket.lua");
pub const ring = @embedFile("ring.lua");
pub const dns = @embedFile("dns.lua");
pub const form = @embedFile("form.lua");
pub const response = @embedFile("response.lua");
pub const http = @embedFile("http_client.lua");
pub const json = @embedFile("json.lua");
