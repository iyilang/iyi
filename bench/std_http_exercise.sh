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
for phrase in "== request" "== response" "== messages at the edges" "== over a socket" "== the server, from a raw socket" "== a burst of connections" "== bodies as streams" "== content codings" "== redirects" "== forms" "== upgrades"; do
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
echo "== what the module reaches"
# What std/socket reaches and nothing of its own: cookies (the clock) and
# files are std/cookie's and std/fileserver's, and a multipart boundary is
# the parts' own hash, not the system's randomness. These are the modules
# it may import, and none but std/socket reaches anything.
imports=$(grep -oE '^import std/[a-z_]+' "$REPO/src/std/http.iyi" | sed 's/^import //' | sort | tr '\n' ' ')
if [ "$imports" = "std/compress std/digest std/mime std/socket std/uri " ]; then
  echo "  std/socket, and std/compress, std/digest, std/mime and std/uri, which reach nothing"
else
  echo "  std/http imports $imports"
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
import http.client, os, sys, gzip, zlib
from email.mime.multipart import MIMEMultipart
from email.mime.base import MIMEBase
from email.mime.text import MIMEText
import email.policy
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
# gzip, which Python's own gzip undoes: whole, and a stream a piece at a time
c.request("GET", "/text", headers={"Accept-Encoding": "gzip"}); r = c.getresponse(); body = r.read()
check(r.getheader("Content-Encoding") == "gzip" and gzip.decompress(body) == b"all work and no play makes jack a dull boy\n" * 2500, f"gzip: {r.getheader('Content-Encoding')} {len(body)} bytes")
c.request("GET", "/stream", headers={"Accept-Encoding": "gzip"}); r = c.getresponse(); body = r.read()
d = zlib.decompressobj(31)
plain = d.decompress(body) + d.flush()
check(r.getheader("Content-Encoding") == "gzip" and d.eof and plain == b"".join((("piece %d " % i) * 100 + "\n").encode() for i in range(10)), f"a gzip stream: {len(plain)} bytes, eof {d.eof}")
# multipart as Python's email package writes it
m = MIMEMultipart("form-data", boundary="py-boundary-1")
f = MIMEText("hello", "plain"); del f["Content-Type"]; del f["MIME-Version"]; del f["Content-Transfer-Encoding"]
f.add_header("Content-Disposition", "form-data", name="greeting"); m.attach(f)
u = MIMEBase("application", "json"); u.set_payload('{"k": [1, 2]}'); del u["MIME-Version"]
u.add_header("Content-Disposition", "form-data", name="doc", filename="d.json"); m.attach(u)
whole = m.as_bytes(policy=email.policy.HTTP)
body = whole[whole.index(b"\r\n\r\n") + 4:]
c.request("POST", "/parts", body=body, headers={"Content-Type": m["Content-Type"]}); r = c.getresponse(); got = r.read()
check(got == b'greeting|-|-|hello;doc|d.json|application/json|{"k": [1, 2]};', f"multipart from Python: {got!r}")
c.request("GET", "/stop"); r = c.getresponse(); body = r.read()
check(r.status == 200 and body == b"stopping", "stop")
c.close()
print("  requests on one connection, a chunked one, a megabyte, gzip whole and streamed, multipart, and stop")
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
echo "== the client against a server that resets the connection after a whole answer"
# Read to the close, `HTTP.get` answered `SocketError` ("the connection was
# reset by the peer") for a whole 200 that the server reset 300 ms after
# it, where Python's http.client answers the 200: an answer is read as far
# as its framing says, and what the connection does after it is not read.
if [ -z "$PY" ]; then
  echo "  skipped: no working python3 to reset the connection with"
else
  cat > "$WORK/reset_client.iyi" <<'IYI'
module main

import std/http::{HTTP, Response, HTTPError}
import std/socket::{SocketError}

case got = HTTP.get("http://127.0.0.1:#{Program.args[0]}/x")
in Response
  puts "#{got.status} #{got.body}"
in SocketError
  puts "SocketError: #{got.message}"
in HTTPError
  puts "HTTPError: #{got.message}"
in Cancelled
  puts "Cancelled"
end
IYI
  if ! "$IYI" build -o "$WORK/reset_client" "$WORK/reset_client.iyi" > "$WORK/reset_client.build" 2>&1; then
    echo "  the client did not build"
    sed -n '1,8p' "$WORK/reset_client.build"
    status=1
  else
    "$PY" - > "$WORK/reset.server.out" 2>&1 <<'PY' &
import socket, struct, sys, time
ls = socket.socket()
ls.bind(("127.0.0.1", 0))
ls.listen(1)
print(ls.getsockname()[1], flush=True)
c, _ = ls.accept()
data = b""
while b"\r\n\r\n" not in data:
    data += c.recv(65536)
c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")
time.sleep(0.3)
# A close with no lingering is a reset, on every platform.
linger = struct.pack("HH", 1, 0) if sys.platform == "win32" else struct.pack("ii", 1, 0)
c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, linger)
c.close()
PY
    reset_pid=$!
    rport=$(await_port "$WORK/reset.server.out" "$reset_pid")
    said=$(timeout 30 "$WORK/reset_client" "$rport" 2>&1)
    wait "$reset_pid" 2>/dev/null
    if [ "$said" = "200 hi" ]; then
      echo "  a whole 200 that the server resets after is the 200"
    else
      echo "  the client answered: $said"
      status=1
    fi
  fi
fi

echo
echo "== the client against Python's server"
# What Python's zlib writes - gzip, deflate in zlib's envelope and bare -
# undone by the client as it arrives; a redirect chain; a multipart body
# the client built, read back by Python's email parser; and a chunked
# upload from a stream, read by Python's server.
if [ -z "$PY" ]; then
  echo "  skipped: no working python3 to serve with"
else
  printf 'one line of the upload\n%.0s' $(seq 1 4000) > "$WORK/upload.txt"
  cat > "$WORK/py_client.iyi" <<'IYI'
module main

import std/http::{HTTP, MultipartBuilder}
import std/file::{File}

base = "http://127.0.0.1:#{Program.args[0]}"
["/gzip", "/deflate", "/raw-deflate"].each do |path|
  r = HTTP.get(base + path).or_panic
  puts "#{path} #{r.decoded?} #{r.body.bytesize} #{r.body == "python's own words " * 1000}"
end
hop = HTTP.post(base + "/hop", "dropped").or_panic
puts "hop #{hop.status} #{hop.body} #{hop.url}"
built = MultipartBuilder.new
built.field("name", "value")
built.file("upload", "notes.txt", "a\r\nb--c\r\n")
parts = HTTP.post(base + "/parts", built.finish, {"Content-Type" => built.content_type}).or_panic
puts "parts #{parts.body}"
up = HTTP.put(base + "/upload", File.open(Program.args[1])).or_panic
puts "upload #{up.body}"
HTTP.get(base + "/stop")
IYI
  if ! "$IYI" build -o "$WORK/py_client" "$WORK/py_client.iyi" > "$WORK/py_client.build" 2>&1; then
    echo "  the client did not build"
    sed -n '1,8p' "$WORK/py_client.build"
    status=1
  else
    "$PY" - > "$WORK/py_server.out" 2>&1 <<'PY' &
import gzip, zlib, sys, email.parser, email.policy
from http.server import HTTPServer, BaseHTTPRequestHandler

text = b"python's own words " * 1000
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def answer(self, status, body, headers=()):
        self.send_response(status)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        accepts = self.headers.get("Accept-Encoding", "")
        if self.path == "/gzip":
            self.answer(200, gzip.compress(text), [("Content-Encoding", "gzip")])
        elif self.path == "/deflate":
            self.answer(200, zlib.compress(text), [("Content-Encoding", "deflate")])
        elif self.path == "/raw-deflate":
            c = zlib.compressobj(9, zlib.DEFLATED, -15)
            self.answer(200, c.compress(text) + c.flush(), [("Content-Encoding", "deflate")])
        elif self.path == "/landed":
            self.answer(200, f"{self.command} accepts={accepts}".encode())
        elif self.path == "/stop":
            self.answer(200, b"bye")
            self.server.done = True
        else:
            self.answer(404, b"no")
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        if self.path == "/hop":
            self.answer(303, b"", [("Location", "/landed")])
        elif self.path == "/parts":
            msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
                b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
            said = ";".join(f"{p.get_param('name', header='content-disposition')}|{p.get_filename()}|{p.get_content_type()}|{p.get_payload(decode=True)!r}" for p in msg.iter_parts())
            self.answer(200, said.encode())
    def do_PUT(self):
        size = 0
        chunks = 0
        if self.headers.get("Transfer-Encoding") == "chunked":
            while True:
                n = int(self.rfile.readline().split(b";")[0], 16)
                if n == 0:
                    self.rfile.readline()
                    break
                size += len(self.rfile.read(n)); self.rfile.readline(); chunks += 1
        self.answer(200, f"{size} bytes in {chunks} chunks".encode())

s = HTTPServer(("127.0.0.1", 0), Handler)
s.done = False
print(s.server_address[1], flush=True)
while not s.done:
    s.handle_request()
PY
    py_pid=$!
    pport=$(await_port "$WORK/py_server.out" "$py_pid")
    said=$(timeout 60 "$WORK/py_client" "$pport" "$WORK/upload.txt" 2>&1)
    wait "$py_pid" 2>/dev/null
    expected="/gzip true 19000 true
/deflate true 19000 true
/raw-deflate true 19000 true
hop 200 GET accepts=gzip, deflate http://127.0.0.1:$pport/landed
parts name|None|text/plain|b'value';upload|notes.txt|text/plain|b'a\\r\\nb--c\\r\\n'
upload 92000 bytes in 2 chunks"
    if [ "$said" = "$expected" ]; then
      echo "  gzip, deflate both ways, a 303 to a GET, multipart read by Python's email parser, a chunked upload"
    else
      echo "  the client and Python's server disagree:"
      printf '%s\n' "$said" | sed 's/^/    got:  /'
      printf '%s\n' "$expected" | sed 's/^/    want: /'
      status=1
    fi
  fi
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
mutate "a chunked body left as it came" 'body = decode_chunked(body)' 'body = body + ""'
mutate "a server that forgets keep-alive" 'socket.write(format_response(response, head, closing)).is_a?(Int32) && !closing' 'socket.write(format_response(response, head, closing)).is_a?(Int32) && false'
mutate "a block's Connection: close dropped" 'closing = true if HTTP.has_token?(said, "close")' ''
mutate "Connection read as one value" 'HTTP.has_token?(conn, "close")' 'HTTP.same_name?(HTTP.trim(conn), "close")'
mutate "a server that answers every request 200" 'Response.new(error.status, error.reason' 'Response.new(200, error.reason'
mutate "a server that joins the body so far after every read" '      pieces << got
    end' '      pieces = [pieces.join + got]
    end'
mutate "a server that keeps a chunked body so far beside it, copied per piece" '      want = @left if want > @left
      want = max.to_i64 if want > max.to_i64
      piece = conn.take(want.to_i32)
      @left = @left - piece.bytesize.to_i64
      @total = @total + piece.bytesize.to_i64
      if @left == 0_i64' '      want = @left if want > @left
      want = max.to_i64 if want > max.to_i64
      piece = conn.take(want.to_i32)
      @text = @text + piece
      @left = @left - piece.bytesize.to_i64
      @total = @total + piece.bytesize.to_i64
      if @left == 0_i64'
mutate "a server that holds a body at its declared length, not at what has arrived" '      pieces << got
    end' '      Pointer(UInt8).malloc(@declared.to_u64) if pieces.size == 1
      pieces << got
    end'
mutate "a server that copies the head so far at every read" '      @searched = @stop
      return HTTPError.new("#{what} headers past #{limit} bytes", 431) if available > limit' '      @searched = @stop
      String.new(available) do |copy|
        copy.copy_from(@data + @start.to_i64, available)
        nil
      end
      return HTTPError.new("#{what} headers past #{limit} bytes", 431) if available > limit'
mutate "a server that waits on a client partway through a request" 'conn = Conn.new(client, listener, idle)' 'conn = Conn.new(client, listener, nil)'
mutate "a server that moves the rest of the read to a buffer of its own per request" '  def consume(count : Int32) : Nil
    @start = @start + count' '  def consume(count : Int32) : Nil
    rest = Pointer(UInt8).malloc(@capacity.to_u64)
    rest.copy_from(@data + @start.to_i64, @stop - @start)
    @data = rest
    @stop = @stop - @start
    @searched = @searched - @start
    @start = 0
    @start = @start + count'
mutate "a client that reads a head for as long as it comes" 'conn.read_head(Server::MAX_HEAD, "response")' 'conn.read_head(2147483647, "response")'
mutate "a server that never says 100 Continue" '    if head.expects
      socket = conn.socket' '    if false
      socket = conn.socket'
mutate "a server whose tasks share the accept loop's variable" '          spawn_handler(g, client, handler, listener, idle, stream_bodies, compress)' '          accepted = client
          g.spawn do
            handle(accepted, handler)
            0
          end'
mutate "a coding this client cannot undo read as chunked" 'return "transfer coding #{coding.inspect} is not one this client decodes" unless same_name?(coding, "chunked")' 'next unless same_name?(coding, "chunked")'
mutate "a body chunked twice decoded as if once" 'return "Transfer-Encoding #{te.inspect} is chunked twice" if chunked > 1' ''
mutate "a length past Int32's read as no number" 'return 2147483648_i64 if n > 2147483647_i64' 'return nil if n > 2147483647_i64'
mutate "a malformed chunked body that raises in the server" 'return "not a chunk size: #{size_text.inspect}" unless size' 'raise "HTTP: not a chunk size: #{size_text.inspect}" unless size'
mutate "a chunk's end added past Int32's" 'return nil if size > n - i - 2' 'return nil if i + size + 2 > n'
mutate "a decoded chunk's end added past Int32's" 'raise "HTTP: chunked body ends inside a chunk" if size > n - i' 'raise "HTTP: chunked body ends inside a chunk" if i + size > n'
mutate "control characters let into a field value" 'return "header #{name} contains a control character" if control?(value)' ''
mutate "control characters let into a request target" 'target.bytesize == 0 || HTTP.control?(target)' 'target.bytesize == 0'
mutate "a folded answer read as fields of its own" 'lines = unfolded(lines) if unfold' ''
mutate "a folded request unfolded too" 'lines = unfolded(lines) if unfold' 'lines = unfolded(lines)'
mutate "a control character written into a request" 'raise "HTTP: header #{name} contains a control character" if control?(value)' ''
mutate "a control character written into an answer" 'raise "HTTP: header #{name} contains a control character" if HTTP.control?(value)' ''
mutate "a status written outside 100 to 999" 'unless response.status >= 100 && response.status <= 999' 'unless true'
mutate "a reason written with a line break in it" '    raise "HTTP: the reason contains a line break" if HTTP.has_break?(response.reason)
    raise "HTTP: the reason contains a control character" if HTTP.control?(response.reason)
' ''
mutate "control characters let into a reason" 'return HTTPError.new("not a status line: #{line}") if control?(reason)' ''
mutate "Host: a and Host: b on one request served as one" 'return HTTPError.new("Host on #{hosts} lines") if hosts > 1' ''
mutate "an HTTP/1.1 request with no Host served" 'hosts == 0 && version == "HTTP/1.1"' 'false'
mutate "a Host that is not a host served" 'unless HTTP.host?(value)' 'if false'
mutate "an absolute-form target's authority left for the Host line's" 'headers[host_name] = named' ''
mutate "repeated fields told apart by case" 'key = name.downcase' 'key = name'
mutate "two lengths that differ read as the first" 'return nil unless trim(part) == first' 'return nil if false'
mutate "chunks beside a length that keep the connection" 'close = true if stub.header("Content-Length") || version == "HTTP/1.0"' 'close = true if false'
mutate "a signed or low status read as one" 'code_text.bytesize == 3 && digits?(code_text) && code >= 100' 'code_text.bytesize == 3'
mutate "any version under HTTP/" 'sp1 && sp1 == 8 && digits?(line[5, 1]) && line.to_unsafe[6] == 46_u8 && digits?(line[7, 1])' 'sp1'
mutate "an interim answer taken for the answer" 'break unless status >= 100 && status < 200 && status != 101 && start < text.bytesize' 'break'
mutate "a 204 written with a body and a length" '    (status >= 100 && status < 200) || status == 204 || status == 304' '    false'
mutate "an empty line before a request read as one" 'while at + 1 < text.bytesize && p[at] == 13_u8' 'while false && p[at] == 13_u8'
mutate "a client that reads an answer with a length to the close" 'return BodyReader.new(conn, BodyReader::LENGTH, n, unlimited)' 'return BodyReader.new(conn, BodyReader::CLOSE, n, unlimited)'
mutate "a client that reads a chunked answer to the close" 'return BodyReader.new(conn, BodyReader::CHUNKED, 0_i64, unlimited)' 'return BodyReader.new(conn, BodyReader::CLOSE, 0_i64, unlimited)'
mutate "an absolute-form target handed on whole" 'if authority = HTTP.absolute_form(target)' 'if authority = nil.as(Int32?)'
mutate "a caller's length written beside a body it does not measure" 'unless head || response.status == 304' 'unless true'
mutate "a caller's chunked framing written beside a length" 'raise "HTTP: #{name} is not written; the body goes with its length" if HTTP.same_name?(name, "Transfer-Encoding")' ''
mutate "a line's search kept as a place in a buffer that moves" 'searched = at - @start' 'searched = at'
mutate "a connection handed over and left open past the listener's close" 'conn.held { takeover.call(socket, leftover) }' 'takeover.call(socket, leftover)'
mutate "a block's unread body read for as long as it comes" 'reader.drain(MAX_DRAIN.to_i64)' 'reader.drain(9223372036854775807_i64)'
mutate "a q of 0 taken for gzip" 'weight = zero_weight?(kv[2, kv.bytesize - 2]) ? 0.0 : 1.0' 'weight = 1.0'
mutate "a short body compressed" 'response.body.bytesize >= COMPRESS_FROM' 'response.body.bytesize >= 0'
mutate "an image compressed" 'return false unless type && MIME.compressible?(type)' 'return false unless type'
mutate "a gzip answer that does not vary" 'headers["Vary"] = "Accept-Encoding"' ''
mutate "a bare deflate stream read as zlib's" 'envelope = Envelope::Raw unless zlib' ''
mutate "a decoded body that keeps the coded body's fields" 'fields.reject_in_place { |key, _| same_name?(key, "Content-Encoding") || same_name?(key, "Content-Length") }' ''
mutate "a redirect that never changes the method" 'unless keeps || (status != 303 && !same_name?(verb, "POST")) || same_name?(verb, "HEAD")' 'unless true'
mutate "credentials carried to another host" 'sent = without(sent, ["Authorization", "Proxy-Authorization", "Cookie"]) unless same_authority?(current, target)' ''
mutate "a part that does not end at its boundary" '          @held = @held[@delimiter.bytesize, @held.bytesize - @delimiter.bytesize]
          @part_done = true' '          @held = @held[@delimiter.bytesize, @held.bytesize - @delimiter.bytesize]'
mutate "a boundary that falls across reads missed" 'safe = @held.bytesize - (@delimiter.bytesize - 1)' 'safe = @held.bytesize'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/http exercise holds"
else
  echo "the std/http exercise did not hold"
fi
exit $status
