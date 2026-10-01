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
for phrase in "== request" "== response" "== messages at the edges" "== over a socket" "== the server, from a raw socket" "== a burst of connections"; do
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
  printf 'module main\n\nimport std/http::{HTTP}\n\n\nputs (%s).to_s\n' \
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
refuses "a caller's Transfer-Encoding" header_te "a request's body goes with its length" \
  'HTTP.format_request("POST", "/", "127.0.0.1", "abc", {"Transfer-Encoding" => "chunked"})'
refuses "https" scheme_tls "HTTP: TLS is not in 0.x" \
  'HTTP.get("https://127.0.0.1/").or_panic.status'
refuses "a Content-Length that is not a number" length_text "HTTP: Content-Length is not a number" \
  'HTTP.parse_response("HTTP/1.1 200 OK\r\nContent-Length: many\r\n\r\nabc").body'
refuses "a Content-Length past Int32's" length_large "HTTP: Content-Length \"3000000000\" is past the 2147483647 bytes a string holds" \
  'HTTP.parse_response("HTTP/1.1 200 OK\r\nContent-Length: 3000000000\r\n\r\nabc").body'
refuses "a chunked body cut inside a chunk" chunk_cut "HTTP: chunked body ends inside a chunk" \
  'HTTP.parse_response("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\nabc").body'
refuses "a status that is not a number" status_text "HTTP: not a status line" \
  'HTTP.parse_response("HTTP/1.1 OK\r\n\r\n").status'

# The first line a server printed, which is its port, once it has printed
# it. The wait is for the process to start running: on Windows, Defender
# checks an exe it has not seen before the exe's first launch runs, and its
# cloud check holds a file 10 s by default and up to 60 s by policy.
# Measured here, with four builds at a time, a program that only prints
# took up to 9.8 s on its first launch and under 0.3 s on its second, and
# this server printed its port 12.8 s after it was launched, after the
# fifty rounds of `sleep 0.1` this step used to wait had run out; the gate
# then said "the server printed no port" about a server that was fine. A
# server that exits ends the wait at once, so one that dies still fails
# without waiting out the minute.
await_port() { # await_port <output file> <pid>
  local out="$1" pid="$2" line="" start=$SECONDS
  while [ $((SECONDS - start)) -lt 60 ]; do
    line=$(head -1 "$out" 2>/dev/null)
    [ -n "$line" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  [ -n "$line" ] || line=$(head -1 "$out" 2>/dev/null)
  printf '%s' "$line"
}

echo
echo "== Python's http.client against the server"
if "$IYI" build -o "$WORK/server" "$REPO/bench/std_http_server.iyi" >"$WORK/server.build.log" 2>&1; then
  "$WORK/server" > "$WORK/server.out" 2>&1 &
  server_pid=$!
  port=$(await_port "$WORK/server.out" "$server_pid")
  if [ -z "$port" ]; then
    echo "  the server printed no port"
    sed -n '1,5p' "$WORK/server.out" | sed 's/^/    /'
    kill "$server_pid" 2>/dev/null
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
  lport=$(await_port "$WORK/load.out" "$load_pid")
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
mutations=0
mutate() { # mutate <label> <old> <new> [module, http.iyi by default]
  # A binary of its own each: on Windows the last one's file can still be
  # held a moment after it ended, and the next link over it failed with
  # LNK1104 - three of thirty mutations here, whichever came after.
  mutations=$((mutations + 1))
  local label="$1" old="$2" new="$3" module="${4:-http.iyi}"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/$module").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/$module").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 300 "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_http_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif timeout -k 5 120 "$WORK/mut-$mutations.bin" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: caught"
  fi
}
mutate "a status parsed as zero" '{code, reason}' '{0, reason}'
mutate "header names compared by case" 'ca = ca + 32_u8 if ca >= 65_u8 && ca <= 90_u8' 'ca = ca + 0_u8 if ca >= 65_u8 && ca <= 90_u8'
mutate "a chunked body left as it came" 'body = decode_chunked(body) if' 'body = body + "" if'
mutate "a server that forgets keep-alive" 'wrote.is_a?(Int32) && !close' 'wrote.is_a?(Int32) && false'
mutate "Connection read as one value" 'HTTP.has_token?(conn, "close")' 'HTTP.same_name?(HTTP.trim(conn), "close")'
mutate "a server that answers every request 200" 'Response.new(400, reason' 'Response.new(200, reason'
mutate "a server that parses the body so far after every read" 'wanted = parsed.wanted' 'wanted = 0'
mutate "a server that parses a chunked body again after every read" 'if head = parsed.chunked' 'if head = nil.as(Request?)'
mutate "a client that copies its answer so far per read" 'answer << chunk' 'answer << answer.to_s[0, 0] + chunk'
mutate "a server that never says 100 Continue" 'if parsed.expects && !continued' 'if false'
mutate "a server whose tasks share the accept loop's variable" '          spawn_handler(g, client, handler, listener, idle)' '          accepted = client
          g.spawn do
            handle(accepted, handler)
            0
          end'
mutate "a length past Int32's read as no number" 'return 2147483648_i64 if n > 2147483647_i64' 'return nil if n > 2147483647_i64'
mutate "a socket read that takes all it may read from the heap" 'if count < first || max_bytes == first' 'if false' socket.iyi
mutate "a malformed chunked body that raises in the server" 'return "not a chunk size: #{size_text.inspect}" unless size' 'raise "HTTP: not a chunk size: #{size_text.inspect}" unless size'
mutate "a chunk's end added past Int32's" 'return nil if size > n - i - 2' 'return nil if i + size + 2 > n'
mutate "a decoded chunk's end added past Int32's" 'raise "HTTP: chunked body ends inside a chunk" if size > n - i' 'raise "HTTP: chunked body ends inside a chunk" if i + size > n'
mutate "control characters let into a field value" 'return "header #{name} contains a control character" if control?(value)' ''
mutate "control characters let into a request target" 'target.bytesize == 0 || HTTP.control?(target)' 'target.bytesize == 0'
mutate "a control character written into a request" 'raise "HTTP: header #{name} contains a control character" if control?(value)' ''
mutate "a control character written into an answer" 'raise "HTTP: header #{name} contains a control character" if HTTP.control?(value)' ''
mutate "a status written outside 100 to 999" 'unless response.status >= 100 && response.status <= 999' 'unless true'
mutate "a reason written with a line break in it" '    raise "HTTP: the reason contains a line break" if HTTP.has_break?(response.reason)
    raise "HTTP: the reason contains a control character" if HTTP.control?(response.reason)
' ''
mutate "control characters let into a reason" 'raise "HTTP: not a status line: #{line}" if control?(reason)' ''
mutate "repeated fields told apart by case" 'key = name.downcase' 'key = name'
mutate "two lengths that differ read as the first" 'return nil unless trim(part) == first' 'return nil if false'
mutate "chunks beside a length that keep the connection" 'close = true if stub.header("Content-Length") || version == "HTTP/1.0"' 'close = true if false'
mutate "a signed or low status read as one" 'code_text.bytesize == 3 && digits?(code_text) && code >= 100' 'code_text.bytesize == 3'
mutate "any version under HTTP/" 'sp1 && sp1 == 8 && digits?(line[5, 1]) && line.to_unsafe[6] == 46_u8 && digits?(line[7, 1])' 'sp1'
mutate "an interim answer taken for the answer" 'break unless status >= 100 && status < 200 && status != 101 && start < text.bytesize' 'break'
mutate "a 204 written with a body and a length" 'bodiless = (response.status >= 100 && response.status < 200) || response.status == 204 || response.status == 304' 'bodiless = false'
mutate "an absolute-form target handed on whole" 'if authority = HTTP.absolute_form(target)' 'if authority = nil.as(Int32?)'
mutate "a caller's length written beside a body it does not measure" 'unless head || response.status == 304' 'unless true'
mutate "a caller's chunked framing written beside a length" 'raise "HTTP: #{name} is not written; the body goes with its length" if HTTP.same_name?(name, "Transfer-Encoding")' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/http exercise holds"
else
  echo "the std/http exercise did not hold"
fi
exit $status
