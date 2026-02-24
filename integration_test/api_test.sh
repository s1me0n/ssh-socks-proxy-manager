#!/bin/bash
# Integration tests for SSH Proxy Manager API
# Runs against the app on an Android emulator via adb port-forward
set -euo pipefail

API="http://127.0.0.1:7070"
PASS=0
FAIL=0
ERRORS=""

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1: $2"; FAIL=$((FAIL+1)); ERRORS="$ERRORS\n  - $1: $2"; }

assert_json() {
  local name="$1" url="$2" method="${3:-GET}" body="${4:-}"
  local resp
  if [ "$method" = "POST" ] && [ -n "$body" ]; then
    resp=$(curl -sf -X POST -H "Content-Type: application/json" -d "$body" "$url" 2>&1) || { fail "$name" "HTTP error"; return 1; }
  elif [ "$method" = "POST" ]; then
    resp=$(curl -sf -X POST "$url" 2>&1) || { fail "$name" "HTTP error"; return 1; }
  else
    resp=$(curl -sf "$url" 2>&1) || { fail "$name" "HTTP error"; return 1; }
  fi
  echo "$resp"
}

echo "🧪 SSH Proxy Manager API Integration Tests"
echo "============================================"
echo ""

# --- Test 1: GET /ping ---
echo "📍 Test: GET /ping"
resp=$(assert_json "ping" "$API/ping") && {
  echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['pong']==True" 2>/dev/null \
    && pass "ping returns pong=true" \
    || fail "ping" "unexpected response: $resp"
} || true

# --- Test 2: GET /help (bug v19 - must not hang) ---
echo "📍 Test: GET /help (timeout 5s)"
resp=$(timeout 5 curl -sf "$API/help" 2>&1) && {
  echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'endpoints' in d" 2>/dev/null \
    && pass "/help returns JSON with endpoints (no hang)" \
    || fail "/help" "missing endpoints key"
} || fail "/help" "timed out or HTTP error (v19 bug?)"

# --- Test 3: GET /servers (initially empty) ---
echo "📍 Test: GET /servers (initial)"
resp=$(assert_json "servers-initial" "$API/servers") && {
  echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d['servers'], list)" 2>/dev/null \
    && pass "/servers returns list" \
    || fail "/servers initial" "unexpected format"
} || true

# --- Test 4: POST /servers/add ---
echo "📍 Test: POST /servers/add"
add_resp=$(assert_json "servers-add" "$API/servers/add" POST '{"name":"TestSrv","host":"192.168.1.99","username":"testuser","password":"testpass","sshPort":22,"socksPort":1080}') && {
  SERVER_ID=$(echo "$add_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['success']==True; print(d['id'])" 2>/dev/null) \
    && pass "server added, id=$SERVER_ID" \
    || fail "/servers/add" "success!=true: $add_resp"
} || true

# --- Test 5: GET /servers contains added server (v19 bug - persistence) ---
echo "📍 Test: GET /servers (after add)"
if [ -n "${SERVER_ID:-}" ]; then
  resp=$(assert_json "servers-after-add" "$API/servers") && {
    echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ids=[s['id'] for s in d['servers']]
assert '$SERVER_ID' in ids, f'Server $SERVER_ID not in {ids}'
" 2>/dev/null \
      && pass "added server persisted in /servers list" \
      || fail "/servers persistence" "server not found in list"
  } || true
else
  fail "/servers persistence" "no SERVER_ID from add step"
fi

# --- Test 6: GET /status ---
echo "📍 Test: GET /status"
resp=$(assert_json "status" "$API/status") && {
  echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='running'" 2>/dev/null \
    && pass "/status returns running" \
    || fail "/status" "unexpected: $resp"
} || true

# --- Test 7: GET /tunnels (should be empty, no real SSH) ---
echo "📍 Test: GET /tunnels"
resp=$(assert_json "tunnels" "$API/tunnels") && {
  echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d['tunnels'], list)" 2>/dev/null \
    && pass "/tunnels returns list" \
    || fail "/tunnels" "unexpected format"
} || true

# --- Test 8: POST /connect/{id} (expect failure - no real SSH, but should not crash) ---
if [ -n "${SERVER_ID:-}" ]; then
  echo "📍 Test: POST /connect/$SERVER_ID (no real SSH - expect graceful error)"
  resp=$(curl -sf -X POST "$API/connect/$SERVER_ID" 2>&1) && {
    # If it returns success=false with error, that's fine (no SSH server)
    pass "/connect gracefully handled (no crash)"
  } || {
    # 500 is acceptable - SSH connection failed
    resp=$(curl -s -X POST "$API/connect/$SERVER_ID" 2>&1)
    echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'error' in d" 2>/dev/null \
      && pass "/connect returned error (expected - no SSH server)" \
      || fail "/connect" "unexpected response"
  }
fi

# --- Test 9: POST /disconnect/{id} (should work even if not connected) ---
if [ -n "${SERVER_ID:-}" ]; then
  echo "📍 Test: POST /disconnect/$SERVER_ID"
  resp=$(assert_json "disconnect" "$API/disconnect/$SERVER_ID" POST) && {
    echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['success']==True" 2>/dev/null \
      && pass "/disconnect returns success" \
      || fail "/disconnect" "unexpected: $resp"
  } || true
fi

# --- Test 10: DELETE /servers/{id} ---
if [ -n "${SERVER_ID:-}" ]; then
  echo "📍 Test: DELETE /servers/$SERVER_ID"
  resp=$(curl -sf -X DELETE "$API/servers/$SERVER_ID" 2>&1) && {
    echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['success']==True" 2>/dev/null \
      && pass "server deleted" \
      || fail "delete server" "unexpected: $resp"
  } || fail "delete server" "HTTP error"
fi

# --- Test 10b: PUT /servers/{id} (update) ---
echo "📍 Test: PUT /servers/{id} (add then update)"
add2_resp=$(assert_json "servers-add2" "$API/servers/add" POST '{"name":"UpdateTest","host":"10.0.0.1","username":"user2","password":"pass2","socksPort":2080}') && {
  UPD_ID=$(echo "$add2_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])" 2>/dev/null)
  if [ -n "${UPD_ID:-}" ]; then
    upd_resp=$(curl -sf -X PUT -H "Content-Type: application/json" -d '{"name":"UpdatedName","socksPort":3080}' "$API/servers/$UPD_ID" 2>&1) && {
      echo "$upd_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['success']==True" 2>/dev/null \
        && pass "PUT /servers/{id} update works" \
        || fail "PUT update" "unexpected: $upd_resp"
    } || fail "PUT update" "HTTP error"
    # Verify updated
    srv_resp=$(curl -sf "$API/servers" 2>&1)
    echo "$srv_resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
s=[x for x in d['servers'] if x['id']=='$UPD_ID'][0]
assert s['name']=='UpdatedName', f'name={s[\"name\"]}'
assert s['socksPort']==3080, f'port={s[\"socksPort\"]}'
" 2>/dev/null \
      && pass "PUT update persisted correctly" \
      || fail "PUT update verify" "values not updated"
    # Cleanup
    curl -sf -X DELETE "$API/servers/$UPD_ID" >/dev/null 2>&1 || true
  else
    fail "PUT update" "no ID from add"
  fi
} || true

# --- Test 11: GET /stats/{id} ---
echo "📍 Test: GET /stats/{id}"
resp=$(assert_json "stats" "$API/stats/nonexistent?period=1h") && {
  echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'totalUptime' in d and 'dataPoints' in d" 2>/dev/null \
    && pass "/stats returns expected fields" \
    || fail "/stats" "missing fields: $resp"
} || true

# --- Test 12: GET /profiles ---
echo "📍 Test: GET /profiles"
resp=$(assert_json "profiles" "$API/profiles") && {
  echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d['profiles'], list)" 2>/dev/null \
    && pass "/profiles returns list" \
    || fail "/profiles" "unexpected format"
} || true

# --- Summary ---
echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  echo -e "Failures:$ERRORS"
  exit 1
fi
echo "🎉 All tests passed!"
