//! Embedded Lua stdlib sources — imported by lua_state.zig at compile time.
//! This file lives in scripts/keyway/ so @embedFile can resolve sibling .lua files.

pub const response = @embedFile("response.lua");
pub const json = @embedFile("json.lua");
