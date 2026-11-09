#!/usr/bin/env bash
# Integration test: verifies fixture isolation against ambient environment pollution.
#
#     bash bench/fixture_isolation_test.sh
#
# Runs bench/std_websocket_exercise.sh and bench/std_http_exercise.sh from outside
# their launch boundaries with an owned loopback proxy trap and poisoned ambient variables,
# verifying that the fixture sanitizers enforce loopback targets and that the exercises
# produce their complete normal transcripts without redirecting traffic.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/iyi-fixture-isolation.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import socket, sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ]; then
  echo "python3 with socket support required for fixture_isolation_test.sh" >&2
  exit 1
fi

await_port() {
  local file="$1" pid="$2" waited=0
  while [ "$waited" -lt 600 ]; do
    if [ -s "$file" ]; then
      head -1 "$file" | tr -d '\r'
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# 1. Start an owned loopback proxy trap on an ephemeral port.
# If any client connection reaches this trap, it accepts and exits with 42 (failure).
cat >"$WORK/proxy_trap.py" <<'PY'
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(10)
print(s.getsockname()[1], flush=True)
s.settimeout(60)
try:
    conn, _ = s.accept()
    conn.close()
    sys.exit(42)  # connection was trapped
except (socket.timeout, TimeoutError):
    sys.exit(0)   # clean: no traffic reached the trap
PY

"$PY" "$WORK/proxy_trap.py" > "$WORK/proxy_trap.out" 2>&1 &
trap_pid=$!
trap_port=$(await_port "$WORK/proxy_trap.out" "$trap_pid")

if [ -z "$trap_port" ]; then
  echo "FAIL: owned loopback proxy trap failed to start" >&2
  exit 1
fi

echo "== fixture isolation: std_websocket_exercise under poisoned ambient environment"
# Poison ambient variables outside the script launch boundary, targeting the owned loopback trap
ws_out="$(WS_URL="ws://127.0.0.1:$trap_port/chat" \
         NODE_EXTRA_CA_CERTS="/nonexistent/poisoned/ca.pem" \
         TLS_ROOTS="/nonexistent/poisoned/roots.pem" \
         TLS_CERT="/nonexistent/poisoned/cert.pem" \
         TLS_KEY="/nonexistent/poisoned/key.pem" \
         HOST="poisoned.external.invalid" \
         bash "$REPO/bench/std_websocket_exercise.sh" 2>&1)"

if ! grep -q "the std/websocket exercise holds" <<< "$ws_out"; then
  echo "FAIL: std_websocket_exercise did not hold under ambient environment pollution:" >&2
  printf '%s\n' "$ws_out" | tail -30 >&2
  kill "$trap_pid" 2>/dev/null || true
  exit 1
fi
if ! grep -q "the handshake, echoes, fragments around a ping" <<< "$ws_out"; then
  echo "FAIL: plain Python client transcript missing under ambient environment pollution" >&2
  kill "$trap_pid" 2>/dev/null || true
  exit 1
fi
echo "  std_websocket_exercise completed with normal transcript under ambient pollution"

echo
echo "== fixture isolation: std_http_exercise under poisoned ambient proxy environment"
# Poison ambient proxy variables targeting the owned loopback proxy trap (not an external host)
http_out="$(http_proxy="http://127.0.0.1:$trap_port" \
           https_proxy="http://127.0.0.1:$trap_port" \
           all_proxy="http://127.0.0.1:$trap_port" \
           HTTP_PROXY="http://127.0.0.1:$trap_port" \
           HTTPS_PROXY="http://127.0.0.1:$trap_port" \
           ALL_PROXY="http://127.0.0.1:$trap_port" \
           bash "$REPO/bench/std_http_exercise.sh" 2>&1)"

if ! grep -q "the std/http exercise holds" <<< "$http_out"; then
  echo "FAIL: std_http_exercise did not hold under ambient proxy pollution:" >&2
  printf '%s\n' "$http_out" | tail -30 >&2
  kill "$trap_pid" 2>/dev/null || true
  exit 1
fi
echo "  std_http_exercise completed with normal transcript under ambient proxy pollution"

# Verify that the owned loopback proxy trap received ZERO connections
kill "$trap_pid" 2>/dev/null || true
wait "$trap_pid" 2>/dev/null || trap_status=$?
if [ "${trap_status:-0}" -eq 42 ]; then
  echo "FAIL: fixture execution sent traffic to the ambient proxy trap on 127.0.0.1:$trap_port" >&2
  exit 1
fi

echo
echo "ALL FIXTURE ISOLATION CHECKS PASSED"
