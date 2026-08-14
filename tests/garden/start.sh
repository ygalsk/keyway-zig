#!/bin/bash

set -euo pipefail

# 0xdafe == 56062, the port the garden's transducer images conventionally use
# for the echo backend. /tools is bind-mounted by the garden's compose entry.
python3 /tools/echo_server.py 127.0.0.1 "$((0xdafe))" &

# One worker: the garden compares parses, not throughput, and a single Lua
# state keeps the forwarded stream deterministic.
cd /app/keyway
exec ./zig-out/bin/keyway --script /app/keyway.lua --workers 1 --port 80
