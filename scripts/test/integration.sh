#!/usr/bin/env bash
# integration.sh — Integration test harness for keyway
# Starts the server, runs curl assertions, reports pass/fail.
set -euo pipefail

BINARY="${BINARY:-zig-out/bin/keyway}"
SCRIPT="${SCRIPT:-scripts/dashboard/keyway.lua}"
PORT=$(shuf -i 10000-60000 -n 1)
BASE="http://127.0.0.1:${PORT}"
WORKERS=1
PID=""
PASS=0
FAIL=0
TOTAL=0

# ─── Helpers ──────────────────────────────────────────────────────────────

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -f "$TMP_HEADERS" "$TMP_BODY" "$TMP_SSE"
}
trap cleanup EXIT

TMP_HEADERS=$(mktemp)
TMP_BODY=$(mktemp)
TMP_SSE=$(mktemp)

has_jq() { command -v jq &>/dev/null; }
has_wscat() { command -v wscat &>/dev/null; }

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); printf "  \033[31mFAIL\033[0m %s: %s\n" "$1" "$2"; }
skip() { TOTAL=$((TOTAL + 1)); printf "  \033[33mSKIP\033[0m %s: %s\n" "$1" "$2"; }

# Fetch into TMP_BODY + TMP_HEADERS, return HTTP status code
fetch() {
    local method="${1:-GET}"
    shift
    local url="$1"
    shift
    curl -s -X "$method" -o "$TMP_BODY" -D "$TMP_HEADERS" "$@" "$url"
    grep -oP 'HTTP/\S+ \K\d+' "$TMP_HEADERS" | tail -1
}

assert_status() {
    local name="$1" method="$2" url="$3" expected="$4"
    shift 4
    local status
    status=$(fetch "$method" "${BASE}${url}" "$@")
    if [ "$status" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "expected status $expected, got $status"
    fi
}

assert_body_contains() {
    local name="$1" text="$2"
    if grep -qF "$text" "$TMP_BODY"; then
        pass "$name"
    else
        fail "$name" "body does not contain '$text'"
    fi
}

assert_header_exists() {
    local name="$1" header="$2"
    if grep -qi "^${header}:" "$TMP_HEADERS"; then
        pass "$name"
    else
        fail "$name" "header '$header' not found"
    fi
}

# ─── Build ────────────────────────────────────────────────────────────────

if [ ! -f "$BINARY" ]; then
    echo "Building keyway..."
    zig build 2>&1
fi

if [ ! -f "$BINARY" ]; then
    echo "ERROR: binary not found at $BINARY"
    exit 1
fi

# ─── Start Server ─────────────────────────────────────────────────────────

echo "Starting keyway on port $PORT..."
"$BINARY" --script "$SCRIPT" --workers "$WORKERS" --port "$PORT" &
PID=$!

# Wait for server to be ready (poll /health)
echo "Waiting for server..."
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w '' "${BASE}/health" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "ERROR: server exited prematurely"
        exit 1
    fi
    sleep 0.1
done

# Final check
if ! curl -sf "${BASE}/health" >/dev/null 2>&1; then
    echo "ERROR: server did not become ready"
    exit 1
fi

echo "Server ready (PID=$PID, port=$PORT)"
echo ""
echo "Running tests..."
echo ""

# ─── Test Cases ───────────────────────────────────────────────────────────

# 1. Hello world
assert_status "GET /test/hello → 200" GET "/test/hello" 200
assert_body_contains "hello body" "hello world"

# 2. Route params
assert_status "GET /test/users/42 → 200" GET "/test/users/42" 200
assert_body_contains "user id in body" "42"

# 3. Query params
assert_status "GET /test/search?q=foo → 200" GET "/test/search?q=foo" 200
assert_body_contains "query param in body" "foo"

# 4. Headers
assert_status "GET /test/headers → 200" GET "/test/headers" 200
assert_header_exists "X-Echo-UA header" "X-Echo-UA"
assert_header_exists "X-Worker header" "X-Worker"

# 5. Echo POST
assert_status "POST /test/echo → 200" POST "/test/echo" 200 -d "payload"
assert_body_contains "echo body" "payload"

# 6. Status codes
assert_status "GET /test/status/201 → 201" GET "/test/status/201" 201
assert_status "GET /test/status/404 → 404" GET "/test/status/404" 404

# 7. JSON response
assert_status "GET /test/json → 200" GET "/test/json" 200
if has_jq; then
    msg=$(jq -r '.message' < "$TMP_BODY" 2>/dev/null || echo "")
    if [ "$msg" = "hello" ]; then
        pass "json .message = hello"
    else
        fail "json .message = hello" "got '$msg'"
    fi
else
    skip "json .message = hello" "jq not available"
fi

# 8. Middleware headers
assert_status "GET /test/mw → 200" GET "/test/mw" 200
assert_header_exists "middleware X-MW-Before" "X-MW-Before"

# 9. Static dashboard
assert_status "GET /__keyway/dashboard → 200" GET "/__keyway/dashboard" 200
if grep -qi "text/html" "$TMP_HEADERS"; then
    pass "dashboard content-type is html"
else
    fail "dashboard content-type is html" "not text/html"
fi

# 10. Health endpoint
assert_status "GET /health → 200" GET "/health" 200
if has_jq; then
    st=$(jq -r '.status' < "$TMP_BODY" 2>/dev/null || echo "")
    if [ "$st" = "ok" ]; then
        pass "health .status = ok"
    else
        fail "health .status = ok" "got '$st'"
    fi
else
    skip "health .status = ok" "jq not available"
fi

# 11. Streaming (chunked transfer)
assert_status "GET /test/stream → 200" GET "/test/stream" 200
assert_body_contains "stream chunk1" "chunk1"
assert_body_contains "stream chunk2" "chunk2"
assert_body_contains "stream chunk3" "chunk3"

# 12. 404 for unknown route
assert_status "GET /nonexistent → 404" GET "/nonexistent" 404

# 13. SSE event stream (background curl, trigger, check)
# SSE test: use timeout to auto-kill curl, trigger multiple requests for reliability
timeout 3 curl -s -N "${BASE}/__keyway/events" > "$TMP_SSE" 2>/dev/null &
SSE_PID=$!
sleep 0.5
# Trigger several requests to increase chance of capture
for _ in 1 2 3; do
    curl -s "${BASE}/test/hello" >/dev/null 2>&1
    sleep 0.3
done
sleep 0.5
kill "$SSE_PID" 2>/dev/null || true
wait "$SSE_PID" 2>/dev/null || true
if grep -q "test" "$TMP_SSE" && grep -q "hello" "$TMP_SSE"; then
    pass "SSE receives access log events"
else
    fail "SSE receives access log events" "event not found in SSE stream"
fi

# 14. WebSocket echo
if has_wscat; then
    # Use --wait 2 to give the server time to echo back before wscat closes
    ws_result=$(echo "hello ws" | timeout 5 wscat -c "ws://127.0.0.1:${PORT}/test/ws" --wait 2 2>/dev/null || echo "")
    if echo "$ws_result" | grep -qF "hello ws"; then
        pass "WebSocket echo"
    else
        fail "WebSocket echo" "expected 'hello ws', got: $ws_result"
    fi
else
    skip "WebSocket echo" "wscat not available"
fi

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Total: %d  " "$TOTAL"
printf "\033[32mPass: %d\033[0m  " "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf "\033[31mFail: %d\033[0m" "$FAIL"
else
    printf "Fail: %d" "$FAIL"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAIL" -eq 0 ]
