#!/usr/bin/env bash
# Exercises `std/http`.
#
#     bash bench/std_http_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_http_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/http exercise, plain build"
build_and_run "plain" http-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/http-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every http section reported"
for phrase in "== request" "== response" "== over a socket"; do
  if ! grep -q "$phrase" "$WORK/http-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" http-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/http-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a request refuses before it is written"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/http\n\nusing std/http::{HTTP}\n\nputs (%s).to_s\n' \
    "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 -o "$phrase.*" "$WORK/$name.out")"
}
refuses "a method with a space" method_space "HTTP: not a method" \
  'HTTP.format_request("GET /", "/", "127.0.0.1")'
refuses "a header value with a line break" header_break "HTTP: header X-A contains a line break" \
  'HTTP.format_request("GET", "/", "127.0.0.1", "", {"X-A" => "1\r\nX-B: 2"})'
refuses "a header the request writes itself" header_own "is the request.s own header" \
  'HTTP.format_request("GET", "/", "127.0.0.1", "", {"content-length" => "5"})'
refuses "https" scheme_tls "HTTP: TLS is not in 0.x" \
  'HTTP.get("https://127.0.0.1/").status'
refuses "a Content-Length that is not a number" length_text "HTTP: Content-Length is not a number" \
  'HTTP.parse_response("HTTP/1.1 200 OK\r\nContent-Length: many\r\n\r\nabc").body'
refuses "a chunked body cut inside a chunk" chunk_cut "HTTP: chunked body ends inside a chunk" \
  'HTTP.parse_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\nabc").body'
refuses "a status that is not a number" status_text "HTTP: not a status line" \
  'HTTP.parse_response("HTTP/1.1 OK\r\n\r\n").status'

echo
echo "== proving the checks can fail when the module is broken"
mutate() { # mutate <label> <old> <new>
  local label="$1" old="$2" new="$3"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" python3 - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/http.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/http.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_http_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a status parsed as zero" '{code, reason}' '{0, reason}'
mutate "header names compared by case" 'ca = ca + 32_u8 if ca >= 65_u8 && ca <= 90_u8' 'ca = ca'
mutate "a chunked body left as it came" 'body = decode_chunked(body) if' 'body = body if'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/http exercise holds"
else
  echo "the std/http exercise did not hold"
fi
exit $status
