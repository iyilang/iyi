#!/usr/bin/env bash
# Exercises `std/http`.
#
#     bash bench/std_http_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

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
for phrase in "== request" "== response" "== over a socket" "== the server, from a raw socket"; do
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
  'HTTP.get("https://127.0.0.1/").or_panic.status'
refuses "a Content-Length that is not a number" length_text "HTTP: Content-Length is not a number" \
  'HTTP.parse_response("HTTP/1.1 200 OK\r\nContent-Length: many\r\n\r\nabc").body'
refuses "a chunked body cut inside a chunk" chunk_cut "HTTP: chunked body ends inside a chunk" \
  'HTTP.parse_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\nabc").body'
refuses "a status that is not a number" status_text "HTTP: not a status line" \
  'HTTP.parse_response("HTTP/1.1 OK\r\n\r\n").status'

echo
echo "== Python's http.client against the server"
if "$IYI" build -o "$WORK/server" "$REPO/bench/std_http_server.iyi" >"$WORK/server.build.log" 2>&1; then
  "$WORK/server" > "$WORK/server.out" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do
    port=$(head -1 "$WORK/server.out" 2>/dev/null)
    [ -n "$port" ] && break
    sleep 0.1
  done
  if [ -z "$port" ]; then
    echo "  the server printed no port"
    status=1
  elif [ -z "$PY" ]; then
    echo "  skipped: no working python3, so its http.client was not run against the server"
    kill "$server_pid" 2>/dev/null
  elif PORT="$port" "$PY" - <<'PY'
import http.client, os, sys
port = int(os.environ["PORT"])
c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
bad = 0
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what); bad += 1
# three requests on one keep-alive connection
c.request("POST", "/echo?k=v", body=b"payload", headers={"Content-Type": "text/plain"})
r = c.getresponse(); body = r.read()
check(r.status == 200 and body == b"payload", f"echo: {r.status} {body!r}")
check(r.getheader("X-Method") == "POST" and r.getheader("X-Query") == "k=v" and r.getheader("Content-Type") == "text/plain", "echo headers")
c.request("GET", "/missing"); r = c.getresponse(); body = r.read()
check(r.status == 404 and body == b"no /missing\n", f"404: {r.status} {body!r}")
c.request("GET", "/big"); r = c.getresponse(); body = r.read()
check(r.status == 200 and len(body) == 1000000 and body == b"x" * 1000000, f"a megabyte: {len(body)}")
# chunked request body, http.client style
c.request("PUT", "/echo", body=iter([b"ab", b"cd", b"e"]), encode_chunked=True)
r = c.getresponse(); body = r.read()
check(r.status == 200 and body == b"abcde" and r.getheader("X-Method") == "PUT", f"chunked: {r.status} {body!r}")
c.request("GET", "/stop"); r = c.getresponse(); body = r.read()
check(r.status == 200 and body == b"stopping", "stop")
c.close()
print("  four requests on one connection, a chunked one, a megabyte, and stop")
sys.exit(1 if bad else 0)
PY
  then
    wait "$server_pid"
    grep -q "^stopped$" "$WORK/server.out" || { echo "  the server did not return from serve"; status=1; }
  else
    echo "  Python's client and the server disagree"
    kill "$server_pid" 2>/dev/null
    status=1
  fi
else
  echo "  the server did not build"
  tail -5 "$WORK/server.build.log"
  status=1
fi

echo
echo "== the server under load"
if command -v wrk >/dev/null 2>&1; then
  "$IYI" build --release -o "$WORK/server-release" "$REPO/bench/std_http_server.iyi" >"$WORK/server-release.build.log" 2>&1
  "$WORK/server-release" > "$WORK/load.out" 2>&1 &
  load_pid=$!
  for _ in $(seq 1 50); do
    lport=$(head -1 "$WORK/load.out" 2>/dev/null)
    [ -n "$lport" ] && break
    sleep 0.1
  done
  wrk -t2 -c50 -d3s "http://127.0.0.1:$lport/echo" > "$WORK/wrk.out" 2>&1
  reqs=$(grep -o '^Requests/sec: *[0-9.]*' "$WORK/wrk.out" | grep -o '[0-9.]*$')
  # `wrk` counts a connection the stop closes under it as a read error;
  # a connect or timeout error is the server's.
  errs=$(grep -o 'Socket errors: .*' "$WORK/wrk.out" | grep -oE 'connect [1-9][0-9]*|timeout [1-9][0-9]*' || true)
  non2xx=$(grep -o 'Non-2xx or 3xx responses: [0-9]*' "$WORK/wrk.out" | grep -o '[0-9]*$' || echo 0)
  total=$(grep -o '^ *[0-9]* requests in' "$WORK/wrk.out" | grep -o '[0-9]*' | head -1)
  curl -s "http://127.0.0.1:$lport/stop" >/dev/null 2>&1 || { [ -n "$PY" ] && "$PY" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$lport/stop').read()"; }
  wait "$load_pid"
  if [ -z "$reqs" ] || [ "${non2xx:-0}" -ne 0 ] || [ -n "$errs" ]; then
    echo "  wrk -c50 -d3s: $reqs req/s, ${total:-0} requests, non-2xx ${non2xx:-0} $errs"
    echo "  the server dropped or refused requests under load"
    status=1
  else
    echo "  wrk -c50 -d3s: $reqs req/s, $total requests, every one answered 200"
  fi
else
  echo "  wrk is not installed; skipped"
fi

echo
echo "== proving the checks can fail when the module is broken"
mutate() { # mutate <label> <old> <new>
  local label="$1" old="$2" new="$3"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" "$PY" - <<PY
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
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 120 "$IYI" run "$REPO/bench/std_http_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a status parsed as zero" '{code, reason}' '{0, reason}'
mutate "header names compared by case" 'ca = ca + 32_u8 if ca >= 65_u8 && ca <= 90_u8' 'ca = ca'
mutate "a chunked body left as it came" 'body = decode_chunked(body) if' 'body = body if'
mutate "a server that forgets keep-alive" 'return if parsed.close' 'return if true'
mutate "a server that answers every request 200" 'Response.new(400, reason' 'Response.new(200, reason'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/http exercise holds"
else
  echo "the std/http exercise did not hold"
fi
exit $status
