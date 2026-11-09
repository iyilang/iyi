#!/usr/bin/env bash
# Integration test: verifies fixture isolation against ambient environment pollution.
#
#     bash bench/fixture_isolation_test.sh
#
# Runs bench/std_websocket_exercise.sh and bench/std_http_exercise.sh from outside
# their launch boundaries with intentionally poisoned ambient proxy, WebSocket, and
# TLS variables, verifying that the fixture sanitizers enforce loopback isolation and
# that the exercises produce their complete normal transcripts without redirecting traffic.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "== fixture isolation: std_websocket_exercise under poisoned ambient environment"
ws_out="$(WS_URL="ws://127.0.0.1.poisoned.invalid:9999/chat" \
         NODE_EXTRA_CA_CERTS="/nonexistent/poisoned/ca.pem" \
         TLS_ROOTS="/nonexistent/poisoned/roots.pem" \
         TLS_CERT="/nonexistent/poisoned/cert.pem" \
         TLS_KEY="/nonexistent/poisoned/key.pem" \
         HOST="poisoned.external.invalid" \
         bash "$REPO/bench/std_websocket_exercise.sh" 2>&1)"

if ! grep -q "the std/websocket exercise holds" <<< "$ws_out"; then
  echo "FAIL: std_websocket_exercise did not hold under ambient environment pollution:" >&2
  printf '%s\n' "$ws_out" | tail -30 >&2
  exit 1
fi
if ! grep -q "the handshake, echoes, fragments around a ping" <<< "$ws_out"; then
  echo "FAIL: plain Python client transcript missing under ambient environment pollution" >&2
  exit 1
fi
echo "  std_websocket_exercise completed with normal transcript under ambient pollution"

echo
echo "== fixture isolation: std_http_exercise under poisoned ambient proxy environment"
http_out="$(http_proxy="http://127.0.0.1.poisoned.invalid:9999" \
           https_proxy="http://127.0.0.1.poisoned.invalid:9999" \
           all_proxy="socks5://127.0.0.1.poisoned.invalid:9999" \
           HTTP_PROXY="http://127.0.0.1.poisoned.invalid:9999" \
           HTTPS_PROXY="http://127.0.0.1.poisoned.invalid:9999" \
           ALL_PROXY="socks5://127.0.0.1.poisoned.invalid:9999" \
           bash "$REPO/bench/std_http_exercise.sh" 2>&1)"

if ! grep -q "the std/http exercise holds" <<< "$http_out"; then
  echo "FAIL: std_http_exercise did not hold under ambient proxy pollution:" >&2
  printf '%s\n' "$http_out" | tail -30 >&2
  exit 1
fi
echo "  std_http_exercise completed with normal transcript under ambient proxy pollution"

echo
echo "ALL FIXTURE ISOLATION CHECKS PASSED"
