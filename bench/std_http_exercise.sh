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
for phrase in "== request" "== response" "== messages at the edges" "== over a socket" "== the server, from a raw socket" "== a burst of connections" "== bodies as streams" "== content codings" "== redirects" "== forms" "== kept connections" "== timeouts" "== upgrades" "== proxies"; do
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
# What std/socket reaches, and std/tls for https:// - the operating
# system's trusted roots and its entropy - and nothing of its own: cookies
# (the clock) and files are std/cookie's and std/fileserver's, and a
# multipart boundary is the parts' own hash, not the system's randomness.
# A deadline reads the monotonic clock through std/time rather than the
# runtime's hook, and std/socket brings std/time already (a DNS query's ID
# is std/random's, which reads the clock), so it adds nothing to what the
# module reaches. These are the modules it may import, and none but
# std/socket, std/time and std/tls reaches anything: HTTP/2's std/hpack
# and the byte slices it reads are iyi over the prelude, as std/zstd is
# over std/digest's XXH64, and std/x509 - the certificate a request
# carries - is std/tls's own already, as std/unicode is std/uri's. No
# std/env: a proxy the environment names is std/http_proxy's to read.
imports=$(grep -oE '^import std/[a-z_0-9]+' "$REPO/src/std/http.iyi" | sed 's/^import //' | sort | tr '\n' ' ')
if [ "$imports" = "std/base64 std/compress std/digest std/hpack std/mime std/slice std/socket std/time std/tls std/unicode std/uri std/x509 std/zstd " ]; then
  echo "  std/socket, std/time and std/tls (std/x509 its own), and std/base64, std/compress, std/digest, std/hpack, std/mime, std/slice, std/unicode, std/uri and std/zstd, which reach nothing"
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
refuses "a scheme that is not HTTP's" scheme_ftp "HTTP: only http:// and https://" \
  'HTTP.get("ftp://127.0.0.1/").or_panic.status'
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
import http.client, os, shutil, subprocess, sys, gzip, zlib
try:
    from compression import zstd  # Python 3.14
except ImportError:
    zstd = None
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
# zstd, which Python's compression.zstd undoes: a whole body at gzip's
# weight or above, gzip where the client wants it more, and a stream
# gzip or as it is, never zstd
text = b"all work and no play makes jack a dull boy\n" * 2500
streamed = b"".join((("piece %d " % i) * 100 + "\n").encode() for i in range(10))
said = "zstd unchecked: no compression.zstd in this Python"
if zstd:
    c.request("GET", "/text", headers={"Accept-Encoding": "gzip, deflate, zstd"}); r = c.getresponse(); body = r.read()
    check(r.getheader("Content-Encoding") == "zstd" and r.getheader("Vary") == "Accept-Encoding" and zstd.decompress(body) == text, f"zstd: {r.getheader('Content-Encoding')} {len(body)} bytes")
    c.request("GET", "/text", headers={"Accept-Encoding": "zstd;q=0.5, gzip;q=0.8"}); r = c.getresponse(); body = r.read()
    check(r.getheader("Content-Encoding") == "gzip" and gzip.decompress(body) == text, f"gzip preferred: {r.getheader('Content-Encoding')}")
    c.request("GET", "/stream", headers={"Accept-Encoding": "zstd"}); r = c.getresponse(); body = r.read()
    check(r.getheader("Content-Encoding") is None and body == streamed, f"a stream to a client of zstd alone: {r.getheader('Content-Encoding')}")
    said = "zstd whole as Python's compression.zstd reads it"
# curl --compressed asks for every coding its build decodes; with zstd
# among them, the server's choice is zstd, and curl undoes it.
curl = shutil.which("curl")
if curl and "zstd" in subprocess.run([curl, "--version"], capture_output=True, text=True).stdout.split("Features:")[-1].lower().split():
    out = subprocess.run([curl, "-sS", "--compressed", "-D", "-", f"http://127.0.0.1:{port}/text"], capture_output=True)
    head, _, got = out.stdout.partition(b"\r\n\r\n")
    check(out.returncode == 0 and b"\r\ncontent-encoding: zstd" in head.lower() and got == text, f"curl --compressed: {head!r}, {len(got)} bytes")
    said += ", and by curl --compressed"
else:
    said += "; curl --compressed unchecked: its build lists no zstd"
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
print("  requests on one connection, a chunked one, a megabyte, gzip whole and streamed, multipart, and stop; " + said)
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
# and its compression.zstd (Python 3.14) - one frame, two, a window of
# 8 MiB taken and one of 16 MiB refused - undone by the client as it
# arrives; a redirect chain; a multipart body the client built, read back
# by Python's email parser; and a chunked upload from a stream, read by
# Python's server.
if [ -z "$PY" ]; then
  echo "  skipped: no working python3 to serve with"
else
  printf 'one line of the upload\n%.0s' $(seq 1 4000) > "$WORK/upload.txt"
  cat > "$WORK/py_client.iyi" <<'IYI'
module main

import std/http::{HTTP, HTTPError, MultipartBuilder}
import std/file::{File}

base = "http://127.0.0.1:#{Program.args[0]}"
paths = ["/gzip", "/deflate", "/raw-deflate"]
paths = paths + ["/zstd", "/zstd-frames", "/zstd-8mib"] if Program.args.size > 2
paths.each do |path|
  r = HTTP.get(base + path).or_panic
  puts "#{path} #{r.decoded?} #{r.body.bytesize} #{r.body == "python's own words " * 1000}"
end
if Program.args.size > 2
  wide = HTTP.get(base + "/zstd-16mib")
  puts "/zstd-16mib #{wide.is_a?(HTTPError) ? wide.message : "answered"}"
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
try:
    from compression import zstd
    from compression.zstd import ZstdCompressor, CompressionParameter
except ImportError:
    zstd = None

text = b"python's own words " * 1000

# A frame with no content size, asking for a window of 2^log bytes.
def windowed(log):
    c = ZstdCompressor(options={CompressionParameter.window_log: log})
    return c.compress(text) + c.flush()

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
        elif self.path == "/zstd" and zstd:
            self.answer(200, zstd.compress(text), [("Content-Encoding", "zstd")])
        elif self.path == "/zstd-frames" and zstd:
            self.answer(200, zstd.compress(text[:7000]) + zstd.compress(text[7000:]), [("Content-Encoding", "zstd")])
        elif self.path == "/zstd-8mib" and zstd:
            self.answer(200, windowed(23), [("Content-Encoding", "zstd")])
        elif self.path == "/zstd-16mib" and zstd:
            self.answer(200, windowed(24), [("Content-Encoding", "zstd")])
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
    zstd_args="" zstd_lines=""
    if "$PY" -c 'import compression.zstd' 2>/dev/null; then
      zstd_args="zstd"
      zstd_lines="
/zstd true 19000 true
/zstd-frames true 19000 true
/zstd-8mib true 19000 true
/zstd-16mib HTTP: the body's coding: zstd: the frame needs a window of 16777216 bytes, past the limit of 8388608"
    fi
    said=$(timeout 60 "$WORK/py_client" "$pport" "$WORK/upload.txt" $zstd_args 2>&1)
    wait "$py_pid" 2>/dev/null
    expected="/gzip true 19000 true
/deflate true 19000 true
/raw-deflate true 19000 true$zstd_lines
hop 200 GET accepts=gzip, deflate, zstd http://127.0.0.1:$pport/landed
parts name|None|text/plain|b'value';upload|notes.txt|text/plain|b'a\\r\\nb--c\\r\\n'
upload 92000 bytes in 2 chunks"
    if [ "$said" = "$expected" ]; then
      echo "  gzip, deflate both ways, ${zstd_args:+zstd one frame and two, its window refused past 8 MiB, }a 303 to a GET, multipart read by Python's email parser, a chunked upload"
    else
      echo "  the client and Python's server disagree:"
      printf '%s\n' "$said" | sed 's/^/    got:  /'
      printf '%s\n' "$expected" | sed 's/^/    want: /'
      status=1
    fi
  fi
fi

echo
echo "== https:// against Python's own TLS server"
# Python's ssl module is OpenSSL's TLS, held to 1.3 here, serving under a
# certificate for localhost from a root made for the run: gzip undone over
# TLS, a 303 followed on the same scheme, a kept connection used twice, a
# host the certificate does not name refused, and an upgrade over https://
# reaching the server, whose 404 it names.
# A kept connection is not handed to a request made after `HTTP.tls_config=`
# names roots that do not reach the server's (a root made beside the
# first): that request makes a connection of its own and is refused; a new
# configuration over the same roots makes a new connection too, which the
# next request under it reuses.
# A redirect from https:// to http:// at the same host and port - the
# server reads TLS or plain HTTP on one port, by the first byte - carries
# no Authorization, Proxy-Authorization or Cookie the caller wrote, and
# the jar's cookie set with `Secure` over https:// stays behind while the
# one set without goes on (Go's client and curl strip the same).
# Then the same client against a copy of the module that sends https://
# in the clear, which must not answer the same; and copies with the pool's
# configuration check, the scheme's part in the redirect's credential
# check, and the jar's `Secure` check taken out, each caught.
if [ -z "$PY" ] || ! "$PY" -c 'import ssl; from cryptography import x509' >/dev/null 2>&1; then
  echo "  skipped: no python3 with ssl and cryptography to serve TLS with"
else
  "$PY" - "$WORK/tls" <<'PY'
import datetime as dt, ipaddress, os, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
def name(cn): return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
ca_key = ec.generate_private_key(ec.SECP256R1())
ca = (x509.CertificateBuilder().subject_name(name("http gate root")).issuer_name(name("http gate root"))
      .public_key(ca_key.public_key()).serial_number(1).not_valid_before(now - dt.timedelta(days=1))
      .not_valid_after(now + dt.timedelta(days=2)).add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
      .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
      .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
      .sign(ca_key, hashes.SHA256()))
key = ec.generate_private_key(ec.SECP256R1())
leaf = (x509.CertificateBuilder().subject_name(name("localhost")).issuer_name(ca.subject)
        .public_key(key.public_key()).serial_number(2).not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=2))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256()))
open(f"{out}/root.pem", "wb").write(ca.public_bytes(serialization.Encoding.PEM))
open(f"{out}/leaf.pem", "wb").write(leaf.public_bytes(serialization.Encoding.PEM))
open(f"{out}/leaf.key", "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
# The same P-256 leaf with its root, for std/tls's server to send.
open(f"{out}/p256.pem", "wb").write(leaf.public_bytes(serialization.Encoding.PEM) + ca.public_bytes(serialization.Encoding.PEM))
# An Ed25519 leaf for the same name, the one std/tls's server signs with.
from cryptography.hazmat.primitives.asymmetric import ed25519
ed_key = ed25519.Ed25519PrivateKey.generate()
ed = (x509.CertificateBuilder().subject_name(name("localhost")).issuer_name(ca.subject)
      .public_key(ed_key.public_key()).serial_number(3).not_valid_before(now - dt.timedelta(days=1))
      .not_valid_after(now + dt.timedelta(days=2))
      .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
      # Python's ssl verifies strictly: a leaf names its issuer's key.
      .add_extension(x509.SubjectKeyIdentifier.from_public_key(ed_key.public_key()), critical=False)
      .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
      .sign(ca_key, hashes.SHA256()))
open(f"{out}/ed.pem", "wb").write(ed.public_bytes(serialization.Encoding.PEM) + ca.public_bytes(serialization.Encoding.PEM))
open(f"{out}/ed.key", "wb").write(ed_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
# Another root, which signs nothing the server sends.
other_key = ec.generate_private_key(ec.SECP256R1())
other = (x509.CertificateBuilder().subject_name(name("http gate other root")).issuer_name(name("http gate other root"))
         .public_key(other_key.public_key()).serial_number(4).not_valid_before(now - dt.timedelta(days=1))
         .not_valid_after(now + dt.timedelta(days=2)).add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
         .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
         .add_extension(x509.SubjectKeyIdentifier.from_public_key(other_key.public_key()), critical=False)
         .sign(other_key, hashes.SHA256()))
open(f"{out}/other.pem", "wb").write(other.public_bytes(serialization.Encoding.PEM))
PY
  cat > "$WORK/tls_client.iyi" <<'IYI'
module main

import std/http::{HTTP, HTTPClient, HTTPError}
import std/cookie::{CookieJar}
import std/tls::{TlsConfig}
import std/x509::{Certificate}
import std/file::{File}

config = TlsConfig.new
config.roots = Certificate.from_pem(File.read(Program.args[1])).or_panic
HTTP.tls_config = config
base = "https://localhost:#{Program.args[0]}"
r = HTTP.get(base + "/gzip").or_panic
puts "gzip #{r.decoded?} #{r.body == "python's own words " * 1000}"
hop = HTTP.post(base + "/hop", "dropped").or_panic
puts "hop #{hop.status} #{hop.body} #{hop.url}"
client = HTTPClient.new
2.times { client.get(base + "/landed").or_panic }
puts "kept #{client.connections_made} made, #{client.connections_reused} reused"
elsewhere = TlsConfig.new
elsewhere.roots = Certificate.from_pem(File.read(Program.args[2])).or_panic
HTTP.tls_config = elsewhere
moved = client.get(base + "/landed")
puts "other roots #{moved.is_a?(HTTPError) ? moved.message : "answered #{moved.inspect}"}"
again = TlsConfig.new
again.roots = config.roots
HTTP.tls_config = again
2.times { client.get(base + "/landed").or_panic }
puts "a new configuration, the same roots: #{client.connections_made} made, #{client.connections_reused} reused"
client.close
jar = CookieJar.new
down = HTTP.request("GET", base + "/down", {"Authorization" => "Bearer t", "Proxy-Authorization" => "Basic cDpx", "Cookie" => "c=1"}, jar: jar).or_panic
puts "downgrade #{down.url} #{down.body}"
other = HTTP.get("https://127.0.0.1:#{Program.args[0]}/landed")
puts "other #{other.is_a?(HTTPError) ? other.message : other.inspect}"
up = HTTP.upgrade(base + "/", "websocket")
puts "upgrade #{up.is_a?(HTTPError) ? up.message : up.inspect}"
HTTP.get(base + "/stop")
IYI
  serve_tls() {
    "$PY" - "$WORK/tls" > "$WORK/tls_server.out" 2>&1 <<'PY' &
import gzip, socket, ssl, sys
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
        secure = isinstance(self.connection, ssl.SSLSocket)
        if self.path == "/heard":
            # What the redirect's target was sent, and over what.
            said = lambda name: self.headers.get(name, "-")
            self.answer(200, f"{'tls' if secure else 'plain'} auth={said('Authorization')} proxy-auth={said('Proxy-Authorization')} cookie={said('Cookie')}".encode())
        elif not secure:
            self.answer(400, b"only /heard is served in the clear")
        elif self.path == "/gzip":
            self.answer(200, gzip.compress(text), [("Content-Encoding", "gzip")])
        elif self.path == "/landed":
            self.answer(200, self.command.encode())
        elif self.path == "/down":
            # To http:// at this host and port, with a Secure cookie and
            # one without.
            self.answer(302, b"", [("Location", f"http://localhost:{self.server.server_address[1]}/heard"),
                                   ("Set-Cookie", "s=1; Secure"), ("Set-Cookie", "p=1")])
        elif self.path == "/stop":
            self.answer(200, b"bye")
            self.server.done = True
        else:
            self.answer(404, b"no")
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.answer(303, b"", [("Location", "/landed")])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_3
context.load_cert_chain(f"{sys.argv[1]}/leaf.pem", f"{sys.argv[1]}/leaf.key")
class Server(HTTPServer):
    # TLS or HTTP in the clear on one port, told apart by the first byte:
    # 0x16 opens a TLS handshake record.
    def get_request(self):
        sock, addr = self.socket.accept()
        sock.settimeout(30)
        if sock.recv(1, socket.MSG_PEEK) == b"\x16":
            sock = context.wrap_socket(sock, server_side=True)
        return sock, addr
s = Server(("127.0.0.1", 0), Handler)
s.done = False
s.timeout = 30
print(s.server_address[1], flush=True)
while not s.done:
    s.handle_request()
PY
    tls_pid=$!
  }
  if ! "$IYI" build -o "$WORK/tls_client" "$WORK/tls_client.iyi" > "$WORK/tls_client.build" 2>&1; then
    echo "  the client did not build"
    sed -n '1,8p' "$WORK/tls_client.build"
    status=1
  else
    serve_tls
    tport=$(await_port "$WORK/tls_server.out" "$tls_pid")
    said=$(timeout 60 "$WORK/tls_client" "$tport" "$WORK/tls/root.pem" "$WORK/tls/other.pem" 2>&1)
    kill "$tls_pid" 2>/dev/null
    wait "$tls_pid" 2>/dev/null
    expected="gzip true true
hop 200 GET https://localhost:$tport/landed
kept 1 made, 1 reused
other roots HTTP: tls: the server's certificate is not trusted: x509: no certificate here issued CN=http gate root, the issuer of CN=localhost (bad_certificate)
a new configuration, the same roots: 3 made, 2 reused
downgrade http://localhost:$tport/heard plain auth=- proxy-auth=- cookie=p=1
other HTTP: tls: the server's certificate is not trusted: x509: CN=localhost is not valid for 127.0.0.1: it names localhost (bad_certificate)
upgrade HTTP: the server answered 404 Not Found to an upgrade to websocket, not 101 Switching Protocols"
    if [ "$said" = "$expected" ]; then
      echo "  gzip over TLS 1.3, a 303 on https://, a kept connection used twice, a host the certificate does not name, an upgrade over https:// answered 404"
      echo "  a kept connection not reused under other roots, nor under a new configuration of the same roots"
      echo "  https:// to http:// at the same host and port: no Authorization, Proxy-Authorization or Cookie of the caller's, the Secure cookie kept back"
    else
      echo "  the client and Python's TLS server disagree:"
      printf '%s\n' "$said" | sed 's/^/    got:  /'
      printf '%s\n' "$expected" | sed 's/^/    want: /'
      status=1
    fi
    # tls_breaks <label> <module> <old> <new> <line>: the client over a copy
    # of std/<module> with <old> replaced must answer the line starting
    # with <line> otherwise than the module does.
    tls_breaks() {
      local label="$1" module="$2" old="$3" new="$4" line="$5" broken want got
      rm -rf "$WORK/tlsbreak" && mkdir -p "$WORK/tlsbreak/std"
      if ! OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/$module" "$WORK/tlsbreak/std/$module" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
      then
        echo "  $label: the patch did not apply"
        status=1
        return
      fi
      if ! IYI_PATH="$WORK/tlsbreak${PSEP}$IYI_PATH" "$IYI" build -o "$WORK/tls_broken" "$WORK/tls_client.iyi" > "$WORK/tls_broken.build" 2>&1; then
        echo "  $label: the broken copy did not build"
        status=1
        return
      fi
      serve_tls
      tport=$(await_port "$WORK/tls_server.out" "$tls_pid")
      broken=$(timeout 60 "$WORK/tls_broken" "$tport" "$WORK/tls/root.pem" "$WORK/tls/other.pem" 2>&1)
      kill "$tls_pid" 2>/dev/null
      wait "$tls_pid" 2>/dev/null
      want="$(printf '%s\n' "$expected" | sed "s/$tport/PORT/g" | grep -m1 "^$line")"
      got="$(printf '%s\n' "$broken" | sed "s/$tport/PORT/g" | grep -m1 "^$line")"
      if [ -n "$got" ] && [ "$got" != "$want" ]; then
        echo "  $label: caught at \"$line\": $(printf '%s' "$got" | cut -c1-100)"
      else
        echo "  $label: not caught at \"$line\" (it answered \"$got\")"
        status=1
      fi
    }
    tls_breaks "a kept connection handed out under another configuration" http.iyi \
      '        if tls && !(under && under.same?(tls))' '        if false' "other roots"
    tls_breaks "a credential carried from https:// to http:// at one host and port" http.iyi \
      '    return false unless sa == sb' '    nil' "downgrade"
    tls_breaks "a Secure cookie sent over http://" cookie.iyi \
      '      next if cookie.secure && !secure' '      nil' "downgrade"
    # And the proof: https:// written in the clear does not answer so.
    mkdir -p "$WORK/clear/std"
    sed 's/^        if secure$/        if false/' "$REPO/src/std/http.iyi" > "$WORK/clear/std/http.iyi"
    if cmp -s "$REPO/src/std/http.iyi" "$WORK/clear/std/http.iyi"; then
      echo "  the patch that sends https:// in the clear changed nothing, so it proves nothing"
      status=1
    elif ! IYI_PATH="$WORK/clear${PSEP}$IYI_PATH" "$IYI" build -o "$WORK/tls_clear" "$WORK/tls_client.iyi" > "$WORK/tls_clear.build" 2>&1; then
      echo "  the client over the clear-text copy did not build"
      status=1
    else
      serve_tls
      tport=$(await_port "$WORK/tls_server.out" "$tls_pid")
      clear=$(timeout 60 "$WORK/tls_clear" "$tport" "$WORK/tls/root.pem" "$WORK/tls/other.pem" 2>&1)
      kill "$tls_pid" 2>/dev/null
      wait "$tls_pid" 2>/dev/null
      if [ "$clear" = "$expected" ]; then
        echo "  https:// sent in the clear answered the same, so the section does not test TLS"
        status=1
      else
        echo "  https:// sent in the clear is caught: $(printf '%s' "$clear" | head -1 | cut -c1-90)"
      fi
    fi
  fi
fi

echo
echo "== latency on loopback: Nagle off, and a flight in one write (bench/std_http_latency.iyi)"
# Nagle's algorithm holds a small write back while an earlier one is
# unacknowledged, and a peer's delayed ACK holds the acknowledgement 40 ms
# at least on Linux: std/socket now sets TCP_NODELAY on every connected
# and accepted TCP socket, and std/tls writes a flight of records in one
# write. Each line is the median of 50 GETs, built --release, under 15
# ms: with Nagle on, a GET whose answer the server streams on a kept
# connection - the head, then a chunk - took 41 ms here, and a TLS client
# whose ChangeCipherSpec and Finished went as two writes 47 ms with its
# socket's Nagle on, where each took 1 ms or less; 15 ms leaves a slow
# runner that much more and stays well under the least stall. Then
# OpenSSL's s_server as the server and curl as the client, each beside
# std/http, and on Linux, where strace is there to ask, what both ends
# write in one handshake: no ChangeCipherSpec written alone. Then copies
# of the modules with Nagle left on, the client's flight in two writes
# and the server's, each caught at the line that names it.
LATENCY_SELF="plain http://, std/http at both ends, a GET on a new connection
plain http://, a kept connection, an answer the server streams
https://, std/http at both ends, a GET on a new connection
https://, a kept connection, an answer the server streams
https://, Nagle on at the client, its handshake and a GET"
LATENCY_SSERVER="https:// to s_server, a GET on a new connection
https:// to s_server, Nagle on at the client, its handshake and a GET"
LATENCY_CURL="curl to std/http's https:// server, a GET on a new connection"
LATENCY_ALONE="no ChangeCipherSpec written alone, at either end, as strace saw the writes"
latency_openssl=yes
latency_curl=yes
latency_strace=no
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) latency_openssl=no; latency_curl=no ;;
  Linux) command -v strace >/dev/null 2>&1 && strace -f -qq -e trace=write -o /dev/null true >/dev/null 2>&1 && latency_strace=yes ;;
esac
LATENCY_OPENSSL=openssl
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if [ -x "$candidate" ]; then
    LATENCY_OPENSSL="$candidate"
    break
  fi
done
if [ -z "$PY" ] || ! command -v "$LATENCY_OPENSSL" >/dev/null 2>&1 || ! "$LATENCY_OPENSSL" version 2>/dev/null | grep -q '^OpenSSL '; then
  latency_openssl=no
fi
command -v curl >/dev/null 2>&1 || latency_curl=no
# latency_run <binary>: every line the binary and its peers answer.
latency_run() {
  local bin="$1" port pid
  timeout 120 "$bin" self "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" "$WORK/tls/root.pem" 50 2>&1
  if [ "$latency_openssl" = yes ]; then
    port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    "$LATENCY_OPENSSL" s_server -accept "127.0.0.1:$port" -www -tls1_3 -cert "$WORK/tls/leaf.pem" -key "$WORK/tls/leaf.key" \
      >"$WORK/latency-s_server.log" 2>&1 </dev/null &
    pid=$!
    for _ in $(seq 1 50); do
      "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
      sleep 0.1
    done
    timeout 120 "$bin" s_server "$port" "$WORK/tls/root.pem" 50 2>&1
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  if [ "$latency_curl" = yes ]; then
    rm -f "$WORK/latency.port"
    "$bin" serve "$WORK/latency.port" "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
      [ -s "$WORK/latency.port" ] && break
      sleep 0.1
    done
    port="$(cat "$WORK/latency.port" 2>/dev/null)"
    # A curl that could not speak to the server answers 000 in no time,
    # which is no latency: only 200s are counted, and all 50 must be.
    for _ in $(seq 1 51); do
      curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 10 --cacert "$WORK/tls/root.pem" "https://localhost:$port/"
    done | tail -50 | awk '$1 == "200" { print $2 }' | sort -n | awk -v label="$LATENCY_CURL" '{ t[NR] = $1 * 1000 } END {
      m = NR > 0 ? t[int(NR / 2) + 1] : 0
      if (NR != 50) printf "%s: %d of 50 answered 200\n", label, NR
      else if (m < 15) printf "%s: under 15 ms (median %.2f ms of %d)\n", label, m, NR
      else printf "%s: %.2f ms, past 15 ms (the median of %d)\n", label, m, NR }'
    curl -s -o /dev/null --max-time 10 --cacert "$WORK/tls/root.pem" "https://localhost:$port/quit"
    wait "$pid" 2>/dev/null
  fi
  if [ "$latency_strace" = yes ]; then
    strace -f -qq -e trace=sendto,write -o "$WORK/latency.trace" timeout 60 "$bin" once "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" "$WORK/tls/root.pem" >/dev/null 2>&1
    echo "$LATENCY_ALONE: $(grep -c '"\\24\\3\\3\\0\\1\\1", 6' "$WORK/latency.trace")"
  fi
}
# latency_held <output> <label>: whether the line for <label> is there and
# under the bound (or, for the strace line, counts none).
latency_held() {
  local line
  line="$(printf '%s\n' "$1" | grep -m1 -F "$2: ")"
  [ -n "$line" ] || return 1
  if [ "$2" = "$LATENCY_ALONE" ]; then
    [ "$line" = "$LATENCY_ALONE: 0" ]
  else
    printf '%s' "$line" | grep -q ': under 15 ms '
  fi
}
if [ ! -s "$WORK/tls/root.pem" ]; then
  echo "  skipped: the https:// section above made no certificates (no python3 with ssl and cryptography)"
elif ! "$IYI" build --release -o "$WORK/latency" "$REPO/bench/std_http_latency.iyi" >"$WORK/latency.build" 2>&1; then
  echo "  bench/std_http_latency.iyi did not build"
  sed -n '1,8p' "$WORK/latency.build"
  status=1
else
  latency_labels="$LATENCY_SELF"
  [ "$latency_openssl" = yes ] && latency_labels="$latency_labels
$LATENCY_SSERVER"
  [ "$latency_curl" = yes ] && latency_labels="$latency_labels
$LATENCY_CURL"
  [ "$latency_strace" = yes ] && latency_labels="$latency_labels
$LATENCY_ALONE"
  said="$(latency_run "$WORK/latency")"
  printf '%s\n' "$said" | sed 's/^/  /'
  while IFS= read -r label; do
    if ! latency_held "$said" "$label"; then
      echo "  FAIL $label"
      status=1
    fi
  done <<EOF
$latency_labels
EOF
  [ "$latency_openssl" = yes ] || echo "  no OpenSSL (LibreSSL is not it) with python3 here, or Windows, whose s_server this gate does not drive: s_server goes unasked"
  [ "$latency_curl" = yes ] || echo "  no curl here, or Windows, whose curl does not take this gate's root by --cacert: curl goes unasked"
  [ "$latency_strace" = yes ] || echo "  no strace that runs here (it is Linux's, and a container may forbid ptrace): the writes go uncounted, and so does the server's flight"
  # latency_breaks <label> <module> <old> <new> <line>: the program over a
  # copy of <module> with <old> made <new> must fail at <line>.
  latency_breaks() {
    local label="$1" module="$2" old="$3" new="$4" line="$5" got
    if ! printf '%s\n' "$latency_labels" | grep -qxF "$line"; then
      echo "  $label: skipped, as the check that names it is"
      return
    fi
    rm -rf "$WORK/latencybreak" && mkdir -p "$WORK/latencybreak/std"
    if ! OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/$module" "$WORK/latencybreak/std/$module" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
    then
      echo "  $label: the patch did not apply"
      status=1
      return
    fi
    if ! IYI_PATH="$WORK/latencybreak${PSEP}$IYI_PATH" "$IYI" build --release -o "$WORK/latency-broken" "$REPO/bench/std_http_latency.iyi" >"$WORK/latency-broken.build" 2>&1; then
      echo "  $label: the broken copy did not build"
      sed -n '1,6p' "$WORK/latency-broken.build" | sed 's/^/    /'
      status=1
      return
    fi
    got="$(latency_run "$WORK/latency-broken")"
    if latency_held "$got" "$line"; then
      echo "  $label: not caught at \"$line\""
      status=1
    else
      echo "  $label: caught: $(printf '%s\n' "$got" | grep -m1 -F "$line: " | cut -c1-120)"
    fi
  }
  latency_breaks "TCP sockets left with Nagle on" socket.iyi \
    '    __sys_set_nodelay(fd, true) unless family == AF_UNIX
  end' '    nil
  end' "plain http://, a kept connection, an answer the server streams"
  latency_breaks "the client's ChangeCipherSpec and Finished in two writes" tls.iyi \
    '    sent = send_protected(TlsRecords::HANDSHAKE, finished)
    return sent if sent
    sent = release' '    sent = release
    return sent if sent
    sent = send_protected(TlsRecords::HANDSHAKE, finished)' "https://, Nagle on at the client, its handshake and a GET"
  latency_breaks "the server's ServerHello and flight in separate writes" tls.iyi \
    '    # write.
    hold' '    # write.
    nil' "$LATENCY_ALONE"
fi

echo
echo "== a server stopped while clients hold connections (bench/std_http_stop.iyi)"
# `serve` closes the connections it waits on when its listener closes. A
# kept-alive TLS client while the server stopped printed "iyi: panic:
# socket is closed" - the connection's own task then sent close_notify on
# the socket the stop had closed - and the program went on to exit 0, so
# only its output said so; a TLS upgrade's protocol that wrote its goodbye
# panicked the same way. Now a stopping server sends close_notify on each
# TLS connection waiting between requests before it closes the socket,
# and std/tls answers a socket closed under it as the connection's end
# (`closed?`, and a `TlsError` from a write) instead of reaching
# `IyiSocket#write`, whose refusal of a closed socket is a panic. Held
# here: std/http's clients keeping HTTP/1.1 and HTTP/2 over TLS, HTTP/1.1
# and h2c in the clear, and an upgrade each way whose block reads until
# the stop and asks `closed?` before it says goodbye, as std/websocket
# does - no panic printed, exit 0, both upgrades told "closed"; and
# Python's ssl, holding a kept-alive connection with
# `suppress_ragged_eofs=False` while the server stops, reading
# close_notify rather than an end without one (SSLEOFError, which it read
# before). Then copies of the modules without the write's check, with
# `closed?` blind to the socket, and with a stop that sends no
# close_notify, each caught at the line that names it.
STOP_EXPECTED="kept: TLS HTTP/1.1, TLS HTTP/2, clear HTTP/1.1, clear HTTP/2
upgraded: 101 and 101
the upgrades' last writes: closed, closed
stopped
exit 0
kept connection: HTTP/1.1 200 OK, then on the server's stop: close_notify
the TLS server: stopped, exit 0
panics printed: 0"
# stop_run <binary>: what the binary's `self` printed and how it exited,
# what Python read on its kept connection while the binary's `serve`
# stopped and how that ended, and the number of panics printed by either
# (their lines, and the "at" line a panic's place is printed on, apart).
stop_run() {
  local bin="$1" code pid
  timeout 120 "$bin" self "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" "$WORK/tls/root.pem" >"$WORK/stop-self.out" 2>&1
  code=$?
  grep -v -e 'panic' -e '^  at ' "$WORK/stop-self.out"
  echo "exit $code"
  rm -f "$WORK/stop.port"
  "$bin" serve "$WORK/stop.port" "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" >"$WORK/stop-serve.out" 2>&1 &
  pid=$!
  for _ in $(seq 1 600); do
    [ -s "$WORK/stop.port" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  timeout 60 "$PY" - "$(cat "$WORK/stop.port" 2>/dev/null)" "$WORK/tls/root.pem" <<'PY'
import socket, ssl, sys
port, root = int(sys.argv[1]), sys.argv[2]
context = ssl.create_default_context(cafile=root)
def connect():
    raw = socket.create_connection(("127.0.0.1", port), 10)
    return context.wrap_socket(raw, server_hostname="localhost", suppress_ragged_eofs=False)
def status(s, request):
    s.sendall(request)
    got = b""
    while b"\r\n\r\n" not in got or not got.endswith(b"ok"):
        piece = s.recv(4096)
        if not piece:
            break
        got += piece
    return got.split(b"\r\n", 1)[0].decode()
kept = connect()
first = status(kept, b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
status(connect(), b"GET /stop HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
try:
    end = kept.recv(4096)
    said = "close_notify" if end == b"" else f"{len(end)} bytes more"
except ssl.SSLEOFError:
    said = "an end without close_notify (SSLEOFError)"
except OSError as e:
    said = type(e).__name__
print(f"kept connection: {first}, then on the server's stop: {said}")
PY
  wait "$pid"
  code=$?
  echo "the TLS server: $(grep -v -e 'panic' -e '^  at ' "$WORK/stop-serve.out" | tr '\n' ' ' | sed 's/ $//'), exit $code"
  echo "panics printed: $(cat "$WORK/stop-self.out" "$WORK/stop-serve.out" | grep -c 'panic')"
}
if [ ! -s "$WORK/tls/root.pem" ]; then
  echo "  skipped: the https:// section above made no certificates (no python3 with ssl and cryptography)"
elif ! "$IYI" build -o "$WORK/stop" "$REPO/bench/std_http_stop.iyi" >"$WORK/stop.build" 2>&1; then
  echo "  bench/std_http_stop.iyi did not build"
  sed -n '1,8p' "$WORK/stop.build"
  status=1
else
  said="$(stop_run "$WORK/stop")"
  if [ "$said" = "$STOP_EXPECTED" ]; then
    printf '%s\n' "$said" | sed 's/^/  /'
  else
    echo "  a server stopped under its clients did not stop cleanly:"
    printf '%s\n' "$said" | sed 's/^/    got:  /'
    printf '%s\n' "$STOP_EXPECTED" | sed 's/^/    want: /'
    status=1
  fi
  # stop_breaks <label> <module> <old> <new> <line>: the program over a
  # copy of <module> with <old> made <new> must answer the line starting
  # with <line> otherwise than the modules do.
  stop_breaks() {
    local label="$1" module="$2" old="$3" new="$4" line="$5" want got
    rm -rf "$WORK/stopbreak" && mkdir -p "$WORK/stopbreak/std"
    if ! OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/$module" "$WORK/stopbreak/std/$module" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
    then
      echo "  $label: the patch did not apply"
      status=1
      return
    fi
    if ! IYI_PATH="$WORK/stopbreak${PSEP}$IYI_PATH" "$IYI" build -o "$WORK/stop-broken" "$REPO/bench/std_http_stop.iyi" >"$WORK/stop-broken.build" 2>&1; then
      echo "  $label: the broken copy did not build"
      sed -n '1,6p' "$WORK/stop-broken.build" | sed 's/^/    /'
      status=1
      return
    fi
    want="$(printf '%s\n' "$STOP_EXPECTED" | grep -m1 "^$line")"
    # Read whole first: a grep that stops at its line would close the pipe
    # under the rest of the run, Python's print among it.
    got="$(stop_run "$WORK/stop-broken")"
    got="$(printf '%s\n' "$got" | grep -m1 "^$line")"
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
      echo "  $label: caught at \"$line\": $got"
    else
      echo "  $label: not caught at \"$line\" (it answered \"$got\")"
      status=1
    fi
  }
  stop_breaks "a record written on a socket closed under the connection" tls.iyi \
    '    return TlsError.new("the socket under the connection is closed") if @socket.closed?
    sent = @socket.write' '    sent = @socket.write' "panics printed"
  stop_breaks "closed? blind to the socket under the connection" tls.iyi \
    '    @closed || @socket.closed?' '    @closed' "the upgrades' last writes"
  stop_breaks "a stop that sends no close_notify" http.iyi \
    '      stream.close
    end
    @socket.close' '      nil
    end
    @socket.close' "kept connection"
fi

echo
echo "== HTTP/2: the server and the client together (bench/http2_exercise.iyi)"
# h2c with prior knowledge both ways: every shape of body through the
# windows, gzip, cookies, a redirect, 200 requests on one connection, and
# what HTTP/2 refuses. Plain and --release.
H2BIN="$WORK/h2"
h2_built=0
if ! "$IYI" build -o "$H2BIN" "$REPO/bench/http2_exercise.iyi" >"$WORK/h2.build.log" 2>&1; then
  echo "  build failed"
  tail -12 "$WORK/h2.build.log"
  status=1
else
  h2_built=1
  timeout -k 5 120 "$H2BIN" >"$WORK/h2.out" 2>&1
  code=$?
  sed 's/^/  /' "$WORK/h2.out"
  if [ "$code" -ne 0 ] || ! grep -q "ALL CHECKS PASSED" "$WORK/h2.out"; then
    echo "  the HTTP/2 exercise did not hold (exit $code)"
    status=1
  fi
  if ! "$IYI" build --release -o "$WORK/h2-release" "$REPO/bench/http2_exercise.iyi" >"$WORK/h2r.build.log" 2>&1; then
    echo "  --release: build failed"
    tail -8 "$WORK/h2r.build.log"
    status=1
  elif ! timeout -k 5 120 "$WORK/h2-release" >"$WORK/h2r.out" 2>&1 || ! grep -q "ALL CHECKS PASSED" "$WORK/h2r.out"; then
    echo "  --release: the HTTP/2 exercise did not hold"
    tail -6 "$WORK/h2r.out"
    status=1
  else
    echo "  and the same with --release"
  fi
fi

# The exercise's server, for the peers below: up until a GET of /quit.
h2_serve() {
  rm -f "$WORK/h2.port"
  "$H2BIN" serve "$WORK/h2.port" >"$WORK/h2-serve.log" 2>&1 &
  H2PID=$!
  for _ in $(seq 1 100); do
    [ -s "$WORK/h2.port" ] && break
    sleep 0.1
  done
  H2PORT="$(cat "$WORK/h2.port" 2>/dev/null)"
}
h2_stop() {
  if [ -n "$PY" ]; then
    "$PY" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$H2PORT/quit').read()" >/dev/null 2>&1
  elif command -v curl >/dev/null 2>&1; then
    curl -s "http://127.0.0.1:$H2PORT/quit" >/dev/null 2>&1
  fi
  ( sleep 10; kill "$H2PID" 2>/dev/null ) &
  wait "$H2PID" 2>/dev/null
}

echo
echo "== HTTP/2: raw frames against the server (RFC 9113's errors)"
# Each case a connection of its own, its frames written by hand - the
# header blocks as HPACK literals without indexing - and the answer read
# as frames: the GOAWAY a connection error ends with and its code, or the
# RST_STREAM a stream error is, the connection then still answering PING.
if [ "$h2_built" -ne 1 ] || [ -z "$PY" ]; then
  echo "  skipped: no server built, or no python3 to write frames with"
else
  h2_serve
  cat >"$WORK/h2frames.py" <<'PY'
import socket, struct, sys, time
port = int(sys.argv[1])
PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
NAMES = {0: "NO_ERROR", 1: "PROTOCOL_ERROR", 3: "FLOW_CONTROL_ERROR", 5: "STREAM_CLOSED", 6: "FRAME_SIZE_ERROR",
         9: "COMPRESSION_ERROR", 11: "ENHANCE_YOUR_CALM", 7: "REFUSED_STREAM"}

def frame(kind, flags, stream, payload=b""):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload

def lit(name, value):
    def s(b):
        assert len(b) < 127
        return bytes([len(b)]) + b
    return b"\x00" + s(name.encode()) + s(value.encode())

def request(method="GET", path="/echo", extra=(), drop=()):
    fields = [(":method", method), (":scheme", "http"), (":path", path), (":authority", "127.0.0.1")]
    fields = [f for f in fields if f[0] not in drop] + list(extra)
    return b"".join(lit(k, v) for k, v in fields)

SETTINGS = frame(4, 0, 0)

def frames_of(sock):
    data = b""
    while True:
        while len(data) >= 9:
            n = int.from_bytes(data[:3], "big")
            if len(data) < 9 + n:
                break
            yield data[3], data[4], int.from_bytes(data[5:9], "big") & 0x7FFFFFFF, data[9:9 + n]
            data = data[9 + n:]
        try:
            more = sock.recv(65536)
        except (socket.timeout, ConnectionResetError):
            return
        if not more:
            return
        data += more

def run(sent, settings=True):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        sock.sendall(PREFACE + (SETTINGS if settings else b"") + sent)
    except OSError:
        pass  # the server answered and closed before it had read it all
    return sock

def goaway(sent, settings=True):
    return goaway_on(run(sent, settings))

def goaway_on(sock):
    for kind, flags, stream, payload in frames_of(sock):
        if kind == 7:
            return int.from_bytes(payload[4:8], "big")
    return None

# What a refused client still sends, in two pieces after pauses: a server
# that closed on the refusal resets the connection, and a send breaks -
# or the reset takes the refusal from the buffer before it is read.
def late(sock, rest):
    for piece in (rest[:len(rest) // 2], rest[len(rest) // 2:]):
        time.sleep(0.3)
        try:
            sock.sendall(piece)
        except OSError as e:
            return type(e).__name__
    return None

def goaway_late(sent, rest):
    sock = run(sent)
    broke = late(sock, rest)
    return broke or goaway_on(sock)

def status_late(sent, rest):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    sock.sendall(sent)
    broke = late(sock, rest)
    if broke:
        return broke
    data = b""
    try:
        while b"\r\n" not in data:
            more = sock.recv(65536)
            if not more:
                break
            data += more
    except OSError as e:
        return type(e).__name__
    return data.split(b"\r\n")[0].decode()

def reset_then_ping(sent):
    sock = run(sent)
    code = None
    for kind, flags, stream, payload in frames_of(sock):
        if kind == 3 and stream == 1 and code is None:
            code = int.from_bytes(payload, "big")
            try:
                sock.sendall(frame(6, 0, 0, b"pingpong"))
            except OSError:
                return code, False
        elif kind == 6 and flags & 1 and payload == b"pingpong":
            return code, True
        elif kind == 7:
            return code, False
    return code, False

failures = 0
def expect(name, got, want):
    global failures
    if got == want:
        print(f"  {name}: {NAMES.get(want, want)}")
    else:
        failures += 1
        print(f"  FAIL: {name}: {NAMES.get(got, got)} where {NAMES.get(want, want)} is the answer")

def stream_error(name, sent, want):
    global failures
    code, alive = reset_then_ping(sent)
    if code == want and alive:
        print(f"  {name}: RST_STREAM {NAMES.get(want, want)}, and the connection answers PING after")
    else:
        failures += 1
        print(f"  FAIL: {name}: RST_STREAM {NAMES.get(code, code)}, alive {alive}, where {NAMES.get(want, want)} and alive")

# The ordinary: SETTINGS acknowledged, PING answered, an unknown frame type
# passed over.
sock = run(frame(0xFA, 0, 0, b"ignored") + frame(6, 0, 0, b"12345678"))
acked = pinged = False
for kind, flags, stream, payload in frames_of(sock):
    acked = acked or (kind == 4 and flags & 1 == 1)
    if kind == 6 and flags & 1 and payload == b"12345678":
        pinged = True
        break
if acked and pinged:
    print("  SETTINGS acknowledged, an unknown frame type passed over, PING answered with its bytes")
else:
    failures += 1
    print(f"  FAIL: SETTINGS acknowledged {acked}, PING answered {pinged}")

expect("the first frame not SETTINGS", goaway(frame(6, 0, 0, b"12345678"), settings=False), 1)
expect("DATA on stream 0", goaway(frame(0, 0, 0, b"x")), 1)
expect("a frame past 16384 bytes", goaway(frame(0, 0, 1, b"x" * 16385)), 6)
big = frame(0, 0, 1, b"x" * 16385)
expect("a frame past 16384 bytes, its rest sent after the GOAWAY", goaway_late(big[:200], big[200:]), 6)
expect("a malformed head, a body sent after the answer",
       status_late(b"POST /echo HTTP/1.1\r\nHost: x\r\nno colon here\r\nContent-Length: 8000\r\n\r\n", b"y" * 8000),
       "HTTP/1.1 400 Bad Request")
expect("a head past 1 MiB, more sent after the answer",
       status_late(b"GET / HTTP/1.1\r\nX-Big: " + b"a" * 1048600, b"a" * 8000), "HTTP/1.1 431 Request Header Fields Too Large")
expect("a broken chunk, more sent after the answer",
       status_late(b"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", b"y" * 8000),
       "HTTP/1.1 400 Bad Request")
expect("SETTINGS of 5 bytes", goaway(frame(4, 0, 0, b"\x00\x04\x00\x00\x00")), 6)
expect("SETTINGS_INITIAL_WINDOW_SIZE past 2^31-1", goaway(frame(4, 0, 0, b"\x00\x04\x80\x00\x00\x00")), 3)
expect("SETTINGS_MAX_FRAME_SIZE under 16384", goaway(frame(4, 0, 0, b"\x00\x05\x00\x00\x00\x64")), 1)
expect("SETTINGS_ENABLE_PUSH of 2", goaway(frame(4, 0, 0, b"\x00\x02\x00\x00\x00\x02")), 1)
expect("PING of 7 bytes", goaway(frame(6, 0, 0, b"1234567")), 6)
expect("a WINDOW_UPDATE of 0 for the connection", goaway(frame(8, 0, 0, b"\x00\x00\x00\x00")), 1)
expect("the connection's window past 2^31-1", goaway(frame(8, 0, 0, b"\x7f\xff\xff\xff")), 3)
expect("a stream with an even number", goaway(frame(1, 5, 2, request())), 1)
expect("a header block broken off by another frame", goaway(frame(1, 1, 1, request()) + frame(6, 0, 0, b"12345678")), 1)
expect("CONTINUATION with no header block open", goaway(frame(9, 4, 1, request())), 1)
expect("a CONTINUATION flood", goaway(frame(1, 1, 1, request()) + b"".join(frame(9, 0, 1, b"\x00" * 16000) for _ in range(70))), 11)
expect("a header block that does not decode", goaway(frame(1, 5, 1, b"\x80")), 9)
expect("a PUSH_PROMISE from a client", goaway(frame(5, 4, 0, b"\x00\x00\x00\x02")), 1)
expect("RST_STREAM on a stream never opened", goaway(frame(3, 0, 5, b"\x00\x00\x00\x08")), 1)
expect("HEADERS on a closed stream", goaway(frame(1, 5, 1, request()) + frame(1, 5, 1, request())), 5)
stream_error("a field name in upper case", frame(1, 5, 1, request(extra=[("X-Up", "1")])), 1)
stream_error("no :method", frame(1, 5, 1, request(drop=[":method"])), 1)
stream_error("an empty :path", frame(1, 5, 1, request(path="")), 1)
stream_error("a connection-specific field", frame(1, 5, 1, request(extra=[("connection", "keep-alive")])), 1)
stream_error("te other than trailers", frame(1, 5, 1, request(extra=[("te", "gzip")])), 1)
stream_error("a value ending in white space", frame(1, 5, 1, request(extra=[("x-a", "b ")])), 1)
stream_error("an unknown pseudo-header", frame(1, 5, 1, request(extra=[(":protocol", "x")])), 1)
stream_error("a pseudo-header after a field", frame(1, 5, 1, lit("x-a", "1") + request()), 1)
stream_error("a body shorter than its content-length",
             frame(1, 4, 1, request("POST", extra=[("content-length", "10")])) + frame(0, 1, 1, b"12345"), 1)
stream_error("trailers without END_STREAM",
             frame(1, 4, 1, request("POST")) + frame(0, 0, 1, b"12345") + frame(1, 4, 1, lit("x-t", "1")), 1)
stream_error("a stream depending on itself", frame(2, 0, 1, b"\x00\x00\x00\x01\x10"), 1)
sys.exit(1 if failures else 0)
PY
  "$PY" "$WORK/h2frames.py" "$H2PORT" || status=1
  h2_stop
fi

echo
echo "== a close while the client still sends (RFC 9112 section 9.6)"
# http2_exercise's serve-close: `/ignore?n=1000000` answers a megabyte
# without reading the request's 8 MiB body, and closes - on its
# `Connection: close`, or past the 1 MiB a kept connection reads past
# (`Server::MAX_DRAIN`). A close with the body's bytes unread is a reset,
# which on Linux throws away what the server had yet to send and on
# Windows what the client had yet to read. Closed at once, 50 runs of
# each case on Linux: Python's http.client lost the answer in every run,
# plain and over TLS (its send was reset before it read); under
# `Connection: close`, a client reading as it sent lost the end of the
# answer in every run, and so did curl and the first of 200 pipelined
# requests; past MAX_DRAIN, every curl run ended in a reset (exit 55 or
# 56), and a client reading as it sent was cut short or reset in 45 runs
# plain and 4 over TLS. Lingering, the server shuts its sending half,
# reads past the rest, and closes once the client has.
# Each case RUNS times, plain and over std/tls: the whole answer read by
# Python - as it sends (one thread, select), after it sent all
# (http.client), with 200 requests pipelined behind one that says
# `Connection: close` - and by curl, with no reset anywhere, and the end
# of the stream (a FIN; over TLS a close_notify first, which Python is
# told to insist on) within half a second of the answer's last byte, not
# the second a server that never shuts its half lingers for.
cat >"$WORK/close.py" <<'PY'
import concurrent.futures, http.client, os, select, shutil, socket, ssl, subprocess, sys, time

# close.py PORT RUNS ROOT|- [CASE...]
port, runs = int(sys.argv[1]), int(sys.argv[2])
root = None if sys.argv[3] == "-" else sys.argv[3]
N, UP = 1000000, 8 * 1024 * 1024
want = bytes((i * 31 + 7) & 255 for i in range(N))
ctx = ssl.create_default_context(cafile=root) if root else None
host = "localhost" if root else "127.0.0.1"
here = os.path.dirname(os.path.abspath(__file__))


def connect():
    raw = socket.create_connection(("127.0.0.1", port), timeout=20)
    # An end with no close_notify raises SSLEOFError rather than reading
    # as an end.
    return ctx.wrap_socket(raw, server_hostname="localhost", suppress_ragged_eofs=False) if ctx else raw


def judged(data):
    head, sep, body = data.partition(b"\r\n\r\n")
    if not sep:
        return "no head in %d bytes" % len(data)
    lines = head.split(b"\r\n")
    if not lines[0].startswith(b"HTTP/1.1 200"):
        return "answered %r" % lines[0]
    length = [int(v) for k, _, v in (line.partition(b":") for line in lines[1:]) if k.strip().lower() == b"content-length"]
    if not length or len(body) < length[0]:
        return "%d bytes of the answer's %s" % (len(body), length[0] if length else "unknown length")
    return None if body[:length[0]] == want else "the answer's bytes differ"


# Reads to the end while *out* is sent, in one thread: an SSL object is
# not to be used from two at once. Whether the answer came whole, and how
# long after its last byte the end came.
def exchange(s, out, pause=None):
    out = memoryview(out)
    s.setblocking(False)
    data, at, broke, last, ended = b"", 0, None, None, None
    started = time.monotonic()
    while time.monotonic() < started + 20:
        if pause and at >= pause[0] and time.monotonic() < started + pause[1]:
            sending = False
        else:
            sending = at < len(out) and broke is None
        r, w, _ = select.select([s], [s] if sending else [], [], 0.05)
        if r or (ctx and s.pending()):
            try:
                more = s.recv(65536)
                if not more:
                    ended = time.monotonic()
                    break
                data += more
                last = time.monotonic()
            except (ssl.SSLWantReadError, ssl.SSLWantWriteError, BlockingIOError):
                pass
            except OSError as e:
                s.close()
                return "%s reading (%s)" % (type(e).__name__, judged(data) or "the answer whole")
        if w and sending:
            try:
                at += s.send(out[at:at + 65536])
            except (ssl.SSLWantReadError, ssl.SSLWantWriteError, BlockingIOError):
                pass
            except OSError as e:
                broke = type(e).__name__
    s.close()
    bad = judged(data)
    if bad:
        return bad + (", no end in 20 s" if ended is None else "")
    if broke:
        return "the answer whole, but the send was refused: " + broke
    if ended is None:
        return "the answer whole, and no end in 20 s"
    if last is not None and ended - last > 0.5:
        return "the end %.2f s after the answer" % (ended - last)
    return None


def as_sent(close):
    head = "POST /ignore?n=%d%s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\n\r\n" % (N, "&close=1" if close else "", host, UP)
    return exchange(connect(), head.encode() + b"u" * UP)


def pipelined():
    first = ("GET /ignore?n=%d&close=1 HTTP/1.1\r\nHost: %s\r\n\r\n" % (N, host)).encode()
    rest = ("GET /echo HTTP/1.1\r\nHost: %s\r\n\r\n" % host).encode() * 200
    # The rest held back 20 ms, so it arrives after the server has read
    # the first and is answering it.
    return exchange(connect(), first + rest, pause=(len(first), 0.02))


# The body handed over 256 KiB at a time, each piece's handing-over
# timed: a failure says how much of the body the server took, and when it
# stopped taking it - a server that stopped reading strands http.client
# in its send, which it finishes before it reads.
def sent_first(close):
    if ctx:
        c = http.client.HTTPSConnection("localhost", port, context=ctx, timeout=20)
    else:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    began = time.monotonic()
    sent = [0, began]
    piece = b"u" * 262144

    def body():
        while sent[0] < UP:
            yield piece
            sent[0] += len(piece)
            sent[1] = time.monotonic()

    try:
        c.request("POST", "/ignore?n=%d%s" % (N, "&close=1" if close else ""), body=body(), headers={"Content-Length": str(UP)})
        r = c.getresponse()
        got = r.read()
    except OSError as e:
        return "%s from http.client, %d of %d bytes sent, the last %.2f s in, %.2f s before the error" % (
            type(e).__name__, sent[0], UP, sent[1] - began, time.monotonic() - sent[1])
    finally:
        c.close()
    return None if r.status == 200 and got == want else "answered %d, %d bytes" % (r.status, len(got))


CURL = shutil.which("curl")
upload = os.path.join(here, "close-up.bin")


def by_curl(close):
    args = [CURL, "-sS", "--http1.1", "-H", "Expect:", "--data-binary", "@" + upload, "-o", "-"]
    url = "/ignore?n=%d%s" % (N, "&close=1" if close else "")
    if root:
        # Schannel (Windows' curl) asks a revocation list the gate's own
        # root has none of, and refuses the server for it.
        if "Schannel" in subprocess.run([CURL, "--version"], capture_output=True, text=True).stdout:
            args.append("--ssl-no-revoke")
        args += ["--cacert", root, "--resolve", "localhost:%d:127.0.0.1" % port, "https://localhost:%d%s" % (port, url)]
    else:
        args.append("http://127.0.0.1:%d%s" % (port, url))
    out = subprocess.run(args, capture_output=True, timeout=60)
    if out.returncode != 0 or out.stdout != want:
        return "curl exited %d with %d bytes: %s" % (out.returncode, len(out.stdout), out.stderr.decode(errors="replace").strip()[:80])
    return None


cases = {
    "Python reading as it sends, Connection: close": lambda: as_sent(True),
    "Python reading as it sends, a body past MAX_DRAIN": lambda: as_sent(False),
    "http.client, Connection: close": lambda: sent_first(True),
    "http.client, a body past MAX_DRAIN": lambda: sent_first(False),
    "200 requests pipelined behind Connection: close": pipelined,
}
if CURL:
    with open(upload, "wb") as f:
        f.write(b"u" * UP)
    cases["curl, Connection: close"] = lambda: by_curl(True)
    cases["curl, a body past MAX_DRAIN"] = lambda: by_curl(False)
# Only the cases named, when some are (a broken copy is held to the one
# that names it); each case on a thread of its own, its runs one after
# another: the cases share the server and nothing else.
named = sys.argv[4:]
chosen = [(name, case) for name, case in cases.items() if not named or name in named]


# The slowest run's time goes with the verdict, for a runner whose
# closes come near the bounds to show it.
def verdict(item):
    name, case = item
    first, lost, slowest = None, 0, 0.0
    for _ in range(runs):
        began = time.monotonic()
        got = case()
        slowest = max(slowest, time.monotonic() - began)
        if got:
            lost += 1
            first = first or got
    if lost:
        return False, "  FAIL: %s: %d of %d runs: %s" % (name, lost, runs, first)
    return True, "  %s: %d of %d whole, no reset, the end at once (the slowest %.2f s)" % (name, runs, runs, slowest)


with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(chosen))) as pool:
    verdicts = list(pool.map(verdict, chosen))
for _, line in verdicts:
    print(line)
if not CURL:
    print("  curl is not installed; its cases skipped")
sys.exit(0 if verdicts and all(held for held, _ in verdicts) else 1)
PY
# close_round <tag> <binary> <runs> <plain|tls> [case...]: the cases (or
# those named) against that binary's serve-close, its port file and log
# named by <tag> so that rounds run beside each other; fails when any
# case does.
close_round() {
  local tag="$1" bin="$2" runs="$3" over="$4" cpid cport code=0 root=-
  shift 4
  rm -f "$WORK/close-$tag.port"
  if [ "$over" = tls ]; then
    "$bin" serve-close "$WORK/close-$tag.port" "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" >"$WORK/close-$tag.log" 2>&1 &
    root="$WORK/tls/root.pem"
  else
    "$bin" serve-close "$WORK/close-$tag.port" >"$WORK/close-$tag.log" 2>&1 &
  fi
  cpid=$!
  for _ in $(seq 1 100); do
    [ -s "$WORK/close-$tag.port" ] && break
    sleep 0.1
  done
  cport="$(cat "$WORK/close-$tag.port" 2>/dev/null || echo 1)"
  timeout -k 5 600 "$PY" "$WORK/close.py" "$cport" "$runs" "$root" "$@" || code=1
  kill "$cpid" 2>/dev/null
  wait "$cpid" 2>/dev/null
  return "$code"
}
# Five runs a case by default, CLOSE_RUNS= for more: closed at once, the
# old server lost every run of every case but two in 50 (above), so five
# catch it many times over, and each broken copy below is caught in 3 of
# 3 runs of the case that names it.
CLOSE_RUNS="${CLOSE_RUNS:-5}"
# The --release build serves: a lingering close waits a second at most
# for what the client still sends, and the plain build's TLS
# drains 8 MiB in 0.21 s on Linux (x86-64), the release build's in 0.04
# s - a Windows runner's plain build nearer the second than a check that
# must hold every run should stand. The broken copies below are plain
# builds: each need only fail.
CLOSE_BIN="$WORK/h2-release"
[ -x "$CLOSE_BIN" ] || [ -x "$CLOSE_BIN.exe" ] || CLOSE_BIN="$H2BIN"
close_ready=0
if [ "$h2_built" -ne 1 ] || [ -z "$PY" ]; then
  echo "  skipped: no server built, or no python3 to be the client"
else
  close_ready=1
  # Plain and over TLS beside each other, each with its own server.
  { close_round plain "$CLOSE_BIN" "$CLOSE_RUNS" plain >"$WORK/close-plain.out" 2>&1; echo $? >"$WORK/close-plain.code"; } &
  round_pids=$!
  if [ -s "$WORK/tls/p256.pem" ]; then
    { close_round tls "$CLOSE_BIN" "$CLOSE_RUNS" tls >"$WORK/close-tls.out" 2>&1; echo $? >"$WORK/close-tls.code"; } &
    round_pids="$round_pids $!"
  fi
  wait $round_pids
  echo "  plain, $CLOSE_RUNS runs a case:"
  cat "$WORK/close-plain.out"
  [ "$(cat "$WORK/close-plain.code")" = 0 ] || status=1
  if [ -s "$WORK/tls/p256.pem" ]; then
    echo "  over std/tls (TLS 1.3, the P-256 leaf), $CLOSE_RUNS runs a case:"
    cat "$WORK/close-tls.out"
    [ "$(cat "$WORK/close-tls.code")" = 0 ] || status=1
  else
    echo "  over TLS: skipped, no certificates (no python3 with cryptography to make them)"
  fi
fi
# The client's close, against a Python server that answers one request on
# a kept connection and then waits for the client's end - over TLS its
# close_notify, which Python is told to insist on - holds its own end back
# 300 ms, and closes: close_notify first over TLS, and Python reads
# whether the client's socket took it or answered with a reset. A client
# that lingers waits for that end before its close returns; one that
# closes at once is gone, and is reset by what comes after.
cat >"$WORK/close_server.py" <<'PY'
import os, socket, ssl, sys, time

# close_server.py PORTFILE [CHAIN KEY]
listener = socket.create_server(("127.0.0.1", 0))
with open(sys.argv[1] + ".tmp", "w", newline="\n") as f:
    f.write(str(listener.getsockname()[1]))
os.replace(sys.argv[1] + ".tmp", sys.argv[1])
listener.settimeout(60)
raw, _ = listener.accept()
raw.settimeout(10)
s = raw
if len(sys.argv) > 3:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[2], sys.argv[3])
    s = ctx.wrap_socket(raw, server_side=True, suppress_ragged_eofs=False)
said = []
try:
    head = b""
    while b"\r\n\r\n" not in head:
        more = s.recv(65536)
        if not more:
            raise SystemExit("FAIL: the client went before its request")
        head += more
    s.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    if s.recv(1) != b"":
        raise SystemExit("FAIL: the client sent more after its request")
    said.append("the client's close_notify, then" if s is not raw else "the client's end, then")
    time.sleep(0.3)
    if s is not raw:
        raw = s.unwrap()
    else:
        raw.shutdown(socket.SHUT_WR)
    if raw.recv(1) != b"":
        raise SystemExit("FAIL: bytes after the client's end")
    time.sleep(0.2)
    err = raw.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
    said.append("this side's end 300 ms later taken with no reset" if err == 0 else "this side's end answered with a reset (%d)" % err)
except OSError as e:
    said.append("%s: %s" % (type(e).__name__, e))
raw.close()
print(" ".join(said))
PY
# client_close_round <binary> [tls]: the iyi client's close against the
# Python server above; prints what each end saw.
client_close_round() { # client_close_round <binary> [tls] [tag]
  local bin="$1" over="${2:-}" tag="${3:-cserve}" spid sport
  rm -f "$WORK/$tag.port"
  if [ -n "$over" ]; then
    "$PY" "$WORK/close_server.py" "$WORK/$tag.port" "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" >"$WORK/$tag.sout" 2>&1 &
  else
    "$PY" "$WORK/close_server.py" "$WORK/$tag.port" >"$WORK/$tag.sout" 2>&1 &
  fi
  spid=$!
  for _ in $(seq 1 100); do
    [ -s "$WORK/$tag.port" ] && break
    sleep 0.1
  done
  sport="$(cat "$WORK/$tag.port" 2>/dev/null || echo 1)"
  if [ -n "$over" ]; then
    timeout -k 5 60 "$bin" close-client "https://localhost:$sport" "$WORK/tls/root.pem" 2>&1
  else
    timeout -k 5 60 "$bin" close-client "http://127.0.0.1:$sport" 2>&1
  fi
  wait "$spid"
  cat "$WORK/$tag.sout"
}
# client_close_holds <output>: the client waited for the server's end, a
# second at most, and the server saw a clean close.
client_close_holds() {
  local ms
  ms="$(printf '%s\n' "$1" | sed -n 's/^200 ok closed in \([0-9]*\) ms$/\1/p')"
  [ -n "$ms" ] && [ "$ms" -ge 250 ] && [ "$ms" -lt 1000 ] &&
    printf '%s\n' "$1" | grep -q "taken with no reset"
}
if [ "$close_ready" -eq 1 ]; then
  for over in "" tls; do
    [ -n "$over" ] && [ ! -s "$WORK/tls/p256.pem" ] && continue
    got="$(client_close_round "$H2BIN" "$over")"
    if client_close_holds "$got"; then
      echo "  the client's close${over:+ over TLS}: $(printf '%s' "$got" | tr '\n' ';' | sed 's/;/; /g')"
    else
      echo "  FAIL: the client's close${over:+ over TLS}: $(printf '%s' "$got" | tr '\n' ';' | sed 's/;/; /g')"
      status=1
    fi
  done
fi

echo
echo "== HTTP/2: curl against the server"
if [ "$h2_built" -ne 1 ] || ! command -v curl >/dev/null 2>&1 || ! curl --version | grep -q 'HTTP2'; then
  echo "  skipped: no curl that speaks HTTP/2"
else
  h2_serve
  base="http://127.0.0.1:$H2PORT"
  ok=1
  got="$(curl -sS --http2-prior-knowledge -H 'X-Test: curl' "$base/echo?x=1")"
  [ "$got" = "GET /echo x=1 HTTP/2 host=127.0.0.1:$H2PORT length=0 fnv=cbf29ce484222325 x=curl" ] || { echo "  FAIL: GET answered '$got'"; ok=0; }
  if [ -n "$PY" ]; then
    "$PY" -c "import sys; sys.stdout.buffer.write(bytes((i * 31 + 7) & 255 for i in range(300000)))" >"$WORK/up.bin"
    got="$(curl -sS --http2-prior-knowledge -X PUT --data-binary @"$WORK/up.bin" "$base/echo")"
    want="PUT /echo  HTTP/2 host=127.0.0.1:$H2PORT length=300000 fnv=$("$PY" -c "
h = 0xcbf29ce484222325
for i in range(300000):
    h ^= (i * 31 + 7) & 255
    h = (h * 0x100000001b3) % 2**64
print(format(h, 'x'))") x="
    [ "$got" = "$want" ] || { echo "  FAIL: a 300 KB PUT answered '$got'"; ok=0; }
  fi
  curl -sS --http2-prior-knowledge -I "$base/big?n=12345" | tr -d '\r' >"$WORK/curl-head"
  grep -qx 'HTTP/2 200 ' "$WORK/curl-head" && grep -qx 'content-length: 12345' "$WORK/curl-head" || { echo "  FAIL: HEAD: $(cat "$WORK/curl-head" | tr '\n' ' ')"; ok=0; }
  got="$(curl -sS --http2-prior-knowledge --compressed "$base/text" | head -c 54)"
  [ "$got" = "hello, compressible world. hello, compressible world. " ] || { echo "  FAIL: gzip: '$got'"; ok=0; }
  got="$(curl -sS --http2-prior-knowledge -w '<%{num_connects}>' "$base/echo?a" "$base/echo?b" "$base/echo?c" | grep -o '<[0-9]*>' | tr -d '\n')"
  [ "$got" = "<1><0><0>" ] || { echo "  FAIL: three requests took connections '$got'"; ok=0; }
  [ "$ok" -eq 1 ] && echo "  GET, a 300 KB PUT, HEAD, gzip, and three requests over one connection, as curl (nghttp2) sends and reads them" || status=1
  h2_stop
fi

# Node's own HTTP/2 (nghttp2 under node:http2): the client against this
# server, and this client against its server - in the clear and under TLS
# with ALPN - with settings this end never sends itself: a 1000-byte window,
# a 256-byte HPACK table, padding on every frame, CONTINUATION, trailers and
# a 103 before the answer.
NODE=""
command -v node >/dev/null 2>&1 && node -e "require('http2')" >/dev/null 2>&1 && NODE=node

echo
echo "== HTTP/2: Node's client against the server"
if [ "$h2_built" -ne 1 ] || [ -z "$NODE" ]; then
  echo "  skipped: no node to be the client"
else
  cat >"$WORK/h2-client.js" <<'JS'
const http2 = require("http2"), zlib = require("zlib"), fs = require("fs");
// The port, and the root to trust when the server is std/tls's (https).
const [port, ca] = process.argv.slice(2);
const pattern = (n) => { const b = Buffer.alloc(n); for (let i = 0; i < n; i++) b[i] = (i * 31 + 7) & 255; return b; };
const fnv = (buf) => { let h = 0xcbf29ce484222325n; for (const x of buf) { h ^= BigInt(x); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; } return h.toString(16); };
const session = http2.connect(ca ? `https://localhost:${port}` : `http://127.0.0.1:${port}`,
  { settings: { initialWindowSize: 1000, headerTableSize: 256 }, ...(ca ? { ca: fs.readFileSync(ca) } : {}) });
session.on("error", (e) => { console.log("  FAIL: session error " + e.message); process.exit(1); });
const ask = (headers, body, cancelAfter) => new Promise((resolve, reject) => {
  const req = session.request(headers);
  const chunks = []; let head = null;
  req.on("response", (h) => { head = h; });
  req.on("data", (c) => { chunks.push(c); if (cancelAfter) req.close(http2.constants.NGHTTP2_CANCEL); });
  req.on("close", () => resolve({ head, data: Buffer.concat(chunks), code: req.rstCode }));
  req.on("error", (e) => { if (!cancelAfter) reject(e); });
  if (body) req.end(body); else req.end();
});
const fail = (what) => { console.log("  FAIL: " + what); process.exit(1); };
(async () => {
  const bigs = await Promise.all([...Array(100)].map(() => ask({ ":path": "/big?n=100000" })));
  bigs.forEach((r, i) => { if (!r.data.equals(pattern(100000))) fail(`concurrent GET ${i}: ${r.data.length} bytes`); });
  const ups = [...Array(20)].map((_, i) => pattern(250000 + i * 1000));
  const echoed = await Promise.all(ups.map((u) => ask({ ":method": "POST", ":path": "/echo" }, u)));
  echoed.forEach((r, i) => { if (!r.data.toString().includes(`length=${ups[i].length} fnv=${fnv(ups[i])}`)) fail(`upload ${i}: ${r.data}`); });
  const head = await ask({ ":method": "HEAD", ":path": "/big?n=777" });
  if (head.head[":status"] !== 200 || head.head["content-length"] !== "777" || head.data.length !== 0) fail("HEAD");
  const gz = await ask({ ":path": "/text", "accept-encoding": "gzip" });
  if (gz.head["content-encoding"] !== "gzip" || zlib.gunzipSync(gz.data).toString() !== "hello, compressible world. ".repeat(400)) fail("gzip");
  const cut = await ask({ ":path": "/big?n=5000000" }, null, true);
  const after = await ask({ ":path": "/echo?after=cancel" });
  if (!after.data.toString().startsWith("GET /echo after=cancel HTTP/2")) fail("a request after a cancelled one: " + after.data);
  const cookies = await ask({ ":path": "/cookie" });
  const set = cookies.head["set-cookie"];
  if (!Array.isArray(set) || set.join("|") !== "a=1|b=2; Path=/") fail("set-cookie " + JSON.stringify(set));
  const none = await ask({ ":path": "/missing" });
  if (none.head[":status"] !== 404) fail("404");
  console.log("  100 GETs at once and 20 uploads at once over one connection, under a 1000-byte window; HEAD, gzip, a stream cancelled mid-answer and the next request served, Set-Cookie twice, 404");
  session.close();
})().catch((e) => fail(e.message));
JS
  h2_serve
  timeout -k 5 120 "$NODE" "$WORK/h2-client.js" "$H2PORT" || status=1
  h2_stop
fi

echo
echo "== HTTP/2: the client against Node's server"
if [ "$h2_built" -ne 1 ] || [ -z "$NODE" ]; then
  echo "  skipped: no node to be the server"
else
  cat >"$WORK/h2-server.js" <<'JS'
const http2 = require("http2"), zlib = require("zlib"), fs = require("fs");
const [mode, portFile, logFile, cert, key] = process.argv.slice(2);
const pattern = (n) => { const b = Buffer.alloc(n); for (let i = 0; i < n; i++) b[i] = (i * 31 + 7) & 255; return b; };
const fnv = (buf) => { let h = 0xcbf29ce484222325n; for (const x of buf) { h ^= BigInt(x); h = (h * 0x100000001b3n) & 0xffffffffffffffffn; } return h.toString(16); };
const log = (line) => fs.appendFileSync(logFile, line + "\n");
// A header block past 16384 bytes goes as HEADERS and CONTINUATION; Node
// refuses to send one past maxSendHeaderBlockLength, 64 KiB unless raised.
const options = { settings: { initialWindowSize: 1000, headerTableSize: 256, maxConcurrentStreams: 5 },
                  maxSendHeaderBlockLength: 262144,
                  paddingStrategy: http2.constants.PADDING_STRATEGY_MAX };
const server = mode === "tls" ? http2.createSecureServer({ ...options, cert: fs.readFileSync(cert), key: fs.readFileSync(key) })
                              : http2.createServer(options);
const text = "hello, compressible world. ".repeat(400);
server.on("stream", (stream, headers) => {
  const path = headers[":path"];
  const send = (body, extra = {}, logged = body, big = 0, cookies = "") => {
    stream.respond({ ":status": 200, ...extra });
    stream.end(body);
    log(`${path} 200 ${logged.length} ${fnv(logged)} big=${big} cookies=${cookies}`);
  };
  if (path === "/echo?x=1") send(Buffer.from(`${headers[":method"]} ${path} x-test=${headers["x-test"]}`));
  else if (path === "/big?n=1000000") send(pattern(1000000));
  else if (path === "/trailers") {
    stream.respond({ ":status": 200 }, { waitForTrailers: true });
    stream.on("wantTrailers", () => stream.sendTrailers({ "x-trailer": "yes" }));
    stream.end("with trailers");
    log(`${path} 200 13 ${fnv(Buffer.from("with trailers"))} big=0 cookies=`);
  } else if (path === "/early") {
    stream.additionalHeaders({ ":status": 103, link: "</a.css>; rel=preload" });
    send(Buffer.from("after early hints"));
  } else if (path === "/headers") send(Buffer.from("big headers"), { "x-big": "a".repeat(70000) }, Buffer.from("big headers"), 70000);
  else if (path === "/padded?n=50000") send(pattern(50000));
  else if (path === "/gzip") send(zlib.gzipSync(text), { "content-encoding": "gzip" }, Buffer.from(text));
  else if (path === "/cookies") send(Buffer.from("cookies"), { "set-cookie": ["a=1", "b=2"] }, Buffer.from("cookies"), 0, "a=1|b=2");
  else if (path === "/upload") {
    const parts = [];
    stream.on("data", (c) => parts.push(c));
    stream.on("end", () => {
      const all = Buffer.concat(parts);
      const answer = `length=${all.length} fnv=${fnv(all)}`;
      stream.respond({ ":status": 200 });
      stream.end(answer);
      log(`/upload 200 ${answer}`);
    });
  } else { stream.respond({ ":status": 404 }); stream.end(); }
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
JS
  h2_fetch() { # h2_fetch <label> <mode> <scheme> [roots]
    local label="$1" mode="$2" scheme="$3" roots="${4:-}"
    rm -f "$WORK/node.port" "$WORK/node.log"
    "$NODE" "$WORK/h2-server.js" "$mode" "$WORK/node.port" "$WORK/node.log" "$WORK/tls/leaf.pem" "$WORK/tls/leaf.key" &
    local npid=$!
    for _ in $(seq 1 100); do
      [ -s "$WORK/node.port" ] && break
      sleep 0.1
    done
    local host=127.0.0.1
    [ "$scheme" = "https" ] && host=localhost
    timeout -k 5 120 "$H2BIN" fetch "$scheme://$host:$(cat "$WORK/node.port")" $roots >"$WORK/fetch.out" 2>&1
    kill "$npid" 2>/dev/null
    wait "$npid" 2>/dev/null
    if ! grep -qx "connections 1" "$WORK/fetch.out"; then
      echo "  $label: FAIL: $(grep -v '^/' "$WORK/fetch.out" | head -n 3 | tr '\n' ' ')"
      status=1
    elif ! diff <(grep '^/' "$WORK/fetch.out") "$WORK/node.log" >"$WORK/fetch.diff"; then
      echo "  $label: FAIL: what the client read is not what Node sent"
      sed 's/^/    /' "$WORK/fetch.diff" | head -n 12
      status=1
    else
      echo "  $label: $(grep -c '^/' "$WORK/fetch.out") answers read as Node sent them, over one connection - padded frames, CONTINUATION, trailers, a 103, gzip, two set-cookie, and a 3 MB upload through a 1000-byte window"
    fi
  }
  h2_fetch "h2c" h2c http
  if [ -s "$WORK/tls/root.pem" ] && [ -s "$WORK/tls/leaf.key" ]; then
    h2_fetch "TLS, ALPN h2" tls https "$WORK/tls/root.pem"
  else
    echo "  TLS: skipped: no certificate from the https:// section above"
  fi
fi

echo
echo "== HTTPS: the server over std/tls (Ed25519 and P-256 certificates, ALPN h2 and http/1.1)"
# `Server.serve(tls:)`: the exercise's server behind TlsServer, asked by
# the iyi client over h2 and over http/1.1, curl both ways, Node's client
# (100 GETs and 20 uploads at once under a 1000-byte window), Python
# reading an HTTP/1.0 answer to the end - which must close with
# close_notify - an upgrade answered 101, and a TLS 1.2 client refused
# with the next request still served; once with an Ed25519 certificate
# and once with a P-256 one.
# Python reading an HTTP/1.0 answer to the end, refusing an end that is
# not close_notify. A file of its own: macOS's bash 3.2 misreads a here
# document inside $( ) that holds a quote.
cat >"$WORK/eof-check.py" <<'PY'
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
# suppress_ragged_eofs=False: an end that is not close_notify raises
# SSLEOFError, where the default reads it as an ordinary end.
raw = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=20)
with ctx.wrap_socket(raw, server_hostname="localhost", suppress_ragged_eofs=False) as s:
    s.sendall(b"GET /echo?x=old HTTP/1.0\r\nHost: localhost\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
print(data.decode().split("\r\n")[0], data.decode().split("\r\n\r\n")[1].split(" host=")[0])
PY
# Whether curl is asked of a server with a <ed|p256> certificate: curl on
# LibreSSL (macOS's) or schannel (Windows') takes no Ed25519 certificate,
# and is refused it, rightly.
curl_asked() {
  command -v curl >/dev/null 2>&1 && curl --version | grep -q 'HTTP2' &&
    { [ "$1" = p256 ] || curl --version | head -1 | grep -q 'OpenSSL/'; }
}
# https_checks <binary> <chain> <key> <ed|p256>: every check against that
# binary's serve-tls; answers the number that failed.
https_checks() {
  local bin="$1" chain="$2" key="$3" kind="$4" failed=0 got want tport tpid
  rm -f "$WORK/h2tls.port"
  "$bin" serve-tls "$WORK/h2tls.port" "$chain" "$key" >"$WORK/h2tls.log" 2>&1 &
  tpid=$!
  for _ in $(seq 1 100); do
    [ -s "$WORK/h2tls.port" ] && break
    sleep 0.1
  done
  tport="$(cat "$WORK/h2tls.port" 2>/dev/null)"
  local base="https://localhost:$tport"
  https_fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
  for alpn in h2,http/1.1 http/1.1; do
    local version="HTTP/2"
    [ "$alpn" = http/1.1 ] && version="HTTP/1.1"
    got="$(timeout -k 5 "${HTTPS_GET_SECONDS:-60}" "$H2BIN" tls-get "$base" "$WORK/tls/root.pem" "$alpn" 2>&1 | tr '\n' '|')"
    want="echo 200 GET /echo x=1 $version host=localhost:$tport length=0 fnv=cbf29ce484222325 x=iyi|big 200 1000000 true|post 200 true|connections 1|"
    [ "$got" = "$want" ] || https_fail "the iyi client offering $alpn: $got"
  done
  # A broken copy is caught at its first failure, and the clients after
  # it only wait out their timeouts against a server that cannot answer
  # them: "the TLS handshake skipped" spent 684 s of the gate there.
  if [ -n "${HTTPS_FIRST_FAIL:-}" ] && [ "$failed" -gt 0 ]; then
    kill "$tpid" 2>/dev/null
    wait "$tpid" 2>/dev/null
    return $failed
  fi
  if curl_asked "$kind"; then
    local c=(curl -sS --cacert "$WORK/tls/root.pem" --resolve "localhost:$tport:127.0.0.1")
    got="$("${c[@]}" -H 'X-Test: curl' -w ' <%{http_version}>' "$base/echo?x=1" 2>&1)"
    [ "$got" = "GET /echo x=1 HTTP/2 host=localhost:$tport length=0 fnv=cbf29ce484222325 x=curl <2>" ] || https_fail "curl over h2: $got"
    got="$("${c[@]}" --http1.1 -w ' <%{http_version}>' "$base/echo?x=1" 2>&1)"
    [ "$got" = "GET /echo x=1 HTTP/1.1 host=localhost:$tport length=0 fnv=cbf29ce484222325 x= <1.1>" ] || https_fail "curl over http/1.1: $got"
    got="$("${c[@]}" -w '<%{num_connects}>' "$base/echo?a" "$base/echo?b" "$base/echo?c" 2>&1 | grep -o '<[0-9]*>' | tr -d '\n')"
    [ "$got" = "<1><0><0>" ] || https_fail "three requests took connections '$got'"
    got="$("${c[@]}" --compressed "$base/text" 2>&1 | head -c 54)"
    [ "$got" = "hello, compressible world. hello, compressible world. " ] || https_fail "gzip over TLS: '$got'"
    # curl asked for no upgrade, so after the 101 it waits for an answer
    # the block never sends: "Empty reply", and the code it saw.
    got="$("${c[@]}" --http1.1 -o /dev/null -w '%{http_code}' "$base/upgrade" 2>/dev/null)"
    [ "$got" = "101" ] || https_fail "an upgrade over TLS answered '$got'"
    if "${c[@]}" --tlsv1.2 --tls-max 1.2 -o /dev/null "$base/echo" 2>/dev/null; then
      https_fail "a TLS 1.2 client was served"
    fi
    got="$("${c[@]}" "$base/echo?after=refusal" 2>&1)"
    case "$got" in "GET /echo after=refusal HTTP/2 "*) ;; *) https_fail "a request after a refused handshake: $got" ;; esac
  fi
  if [ -n "$PY" ]; then
    got="$("$PY" "$WORK/eof-check.py" "$tport" "$WORK/tls/root.pem" 2>&1)"
    [ "$got" = "HTTP/1.1 200 OK GET /echo x=old HTTP/1.0" ] || https_fail "Python read to the end of an HTTP/1.0 answer: $got"
  fi
  if [ -n "$NODE" ] && [ -s "$WORK/h2-client.js" ]; then
    got="$(timeout -k 5 120 "$NODE" "$WORK/h2-client.js" "$tport" "$WORK/tls/root.pem" 2>&1)"
    case "$got" in *FAIL*|"") https_fail "Node's client: $got" ;; esac
  fi
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
  return $failed
}
# mtls_checks <binary>: its serve-tls asking for a client's certificate
# under the gate's root, and its own client presenting the localhost leaf
# over h2, over http/1.1 and through an upgrade - the handler must see
# that certificate - then presenting none, refused each way; and Python
# presenting the leaf. Answers the number that failed.
mtls_checks() {
  local bin="$1" failed=0 got want mport mpid
  rm -f "$WORK/mtls.port"
  "$bin" serve-tls "$WORK/mtls.port" "$WORK/tls/ed.pem" "$WORK/tls/ed.key" "$WORK/tls/root.pem" >"$WORK/mtls.log" 2>&1 &
  mpid=$!
  for _ in $(seq 1 100); do
    [ -s "$WORK/mtls.port" ] && break
    sleep 0.1
  done
  mport="$(cat "$WORK/mtls.port" 2>/dev/null)"
  local base="https://localhost:$mport"
  got="$(timeout -k 5 60 "$bin" whoami "$base" "$WORK/tls/root.pem" "$WORK/tls/leaf.pem" "$WORK/tls/leaf.key" 2>&1 | tr '\n' '|')"
  want="h2,http/1.1: 200 peer=CN=localhost HTTP/2|http/1.1: 200 peer=CN=localhost HTTP/1.1|upgrade: 101 CN=localhost|"
  [ "$got" = "$want" ] || { echo "  FAIL: a client certificate presented: $got"; failed=$((failed + 1)); }
  local refused="cannot read from localhost: tls: the server sent alert certificate_required (116)"
  got="$(timeout -k 5 60 "$bin" whoami "$base" "$WORK/tls/root.pem" 2>&1 | tr '\n' '|')"
  want="h2,http/1.1: $refused|http/1.1: $refused|upgrade: $refused|"
  [ "$got" = "$want" ] || { echo "  FAIL: no client certificate: $got"; failed=$((failed + 1)); }
  if [ -n "$PY" ]; then
    got="$("$PY" -c '
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
ctx.load_cert_chain(sys.argv[3], sys.argv[4])
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=20), server_hostname="localhost") as s:
    s.sendall(b"GET /whoami HTTP/1.0\r\nHost: localhost\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
print(data.decode().split("\r\n\r\n")[1])
' "$mport" "$WORK/tls/root.pem" "$WORK/tls/leaf.pem" "$WORK/tls/leaf.key" 2>&1)"
    [ "$got" = "peer=CN=localhost HTTP/1.0" ] || { echo "  FAIL: Python presenting a certificate: $got"; failed=$((failed + 1)); }
  fi
  kill "$mpid" 2>/dev/null
  wait "$mpid" 2>/dev/null
  return $failed
}
if [ "$h2_built" -ne 1 ] || [ ! -s "$WORK/tls/ed.key" ]; then
  echo "  skipped: no HTTP/2 exercise or no Ed25519 certificate from the https:// section above"
  https_ready=0
else
  https_ready=1
  for kind in ed p256; do
    chain="$WORK/tls/$kind.pem"
    key="$WORK/tls/$kind.key"
    [ "$kind" = p256 ] && key="$WORK/tls/leaf.key"
    if https_checks "$H2BIN" "$chain" "$key" "$kind"; then
      echo "  $kind: the iyi client over h2 and http/1.1, Python reading to close_notify, Node's 100 GETs and 20 uploads at once"
      if curl_asked "$kind"; then
        echo "  $kind: curl both ways, gzip, three requests on one connection, an upgrade answered 101, TLS 1.2 refused and the next request served"
      else
        echo "  $kind: curl not asked: no curl with HTTP/2, or one whose TLS takes no Ed25519 certificate"
      fi
    else
      status=1
    fi
  done
  if mtls_checks "$H2BIN"; then
    echo "  a client's certificate asked for: the handler sees it over h2, http/1.1 and an upgrade; none is refused; Python's presented"
  else
    status=1
  fi
fi

echo
echo "== HTTPS: the server's connection cap and request deadline"
# `Server.serve(tls:, max_connections: 2, timeout_ms: 3000,
# request_timeout_ms: 5000)` (http2_exercise's serve-guarded, the P-256
# leaf) against slow clients written here over Python's ssl. Two
# connections hold both places and a third is queued, not refused: its
# handshake goes unanswered until one of the two closes, and then it is
# served. A head sent a byte every half second is cut off at 3 s, as it was
# before; a body sent so - over HTTP/1.1, and over HTTP/2 a DATA frame of
# one byte at a time - at 5 s, where before each read's own 3 s limit was
# all it met and the body went on for as long as it dripped. Each close
# must come within 90% of its deadline and 1.5 s past it for the head (so
# a head held to the request's 5 s is caught), 2.5 s for a body, unanswered.
cat >"$WORK/guard.py" <<'PY'
import select, socket, ssl, struct, sys, threading, time

port, root = int(sys.argv[1]), sys.argv[2]
head_ms, request_ms = int(sys.argv[3]), int(sys.argv[4])
cases = sys.argv[5:] or ["cap", "head", "body", "h2"]
failed = 0


def connect(alpn, timeout=20):
    ctx = ssl.create_default_context(cafile=root)
    ctx.set_alpn_protocols([alpn])
    raw = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    return ctx.wrap_socket(raw, server_hostname="localhost")


def drip(s, first, unit, every=0.5, limit=30):
    """Sends *first*, then *unit* every *every* seconds, reading what comes:
    the seconds until the server closed (None if it had not in *limit*),
    and what it sent."""
    start = time.monotonic()
    got = b""
    s.sendall(first)
    # A record with no data in it - a TLS 1.3 NewSessionTicket, which the
    # server sends after the handshake - makes the socket readable while
    # recv has nothing to give: waited for unbounded, the drip stopped and
    # the server's pause between reads (3 s) closed it, not the deadline.
    s.settimeout(every)
    last = start
    while time.monotonic() - start < limit:
        wait = max(0.0, every - (time.monotonic() - last))
        if s.pending() or select.select([s], [], [], wait)[0]:
            try:
                chunk = s.recv(65536)
            except TimeoutError:
                chunk = None
            except (ssl.SSLError, OSError):
                return time.monotonic() - start, got
            if chunk is not None:
                if not chunk:
                    return time.monotonic() - start, got
                got += chunk
                continue
        try:
            s.sendall(unit)
        except (ssl.SSLError, OSError):
            return time.monotonic() - start, got
        last = time.monotonic()
    return None, got


def judge(name, closed, low_ms, high_ms, extra=None):
    global failed
    if closed is None:
        print(f"FAIL {name}: still open after 30 s")
        failed += 1
    elif not (low_ms <= closed * 1000 <= high_ms):
        print(f"FAIL {name}: closed after {closed:.1f} s, outside {low_ms / 1000:.1f}-{high_ms / 1000:.1f} s")
        failed += 1
    elif extra:
        print(f"FAIL {name}: {extra}")
        failed += 1
    else:
        print(f"ok {name}: closed after {closed:.1f} s")


def hpack(fields):
    # Literal header fields without indexing, new names (RFC 7541 6.2.2).
    out = b""
    for name, value in fields:
        out += b"\x00" + bytes([len(name)]) + name + bytes([len(value)]) + value
    return out


def frame(kind, flags, stream, payload):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload


for case in cases:
    if case == "cap":
        # Two connections hold both places; a third waits in the listen
        # queue - its handshake unanswered - until one of them closes.
        a, b = connect("http/1.1"), connect("http/1.1")
        seen = {}

        def third():
            try:
                c = connect("http/1.1", timeout=15)
                seen["at"] = time.monotonic()
                c.sendall(b"GET /echo?x=third HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                data = b""
                while True:
                    chunk = c.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                seen["answer"] = data.split(b"\r\n")[0].decode()
            except Exception as e:
                seen["error"] = repr(e)

        t = threading.Thread(target=third)
        t.start()
        time.sleep(1.0)
        closed_at = time.monotonic()
        a.close()
        t.join(20)
        b.close()
        if "error" in seen or "at" not in seen:
            print(f"FAIL cap: the third connection was not served: {seen.get('error', 'no answer in 20 s')}")
            failed += 1
        elif seen["at"] < closed_at:
            print(f"FAIL cap: the third connection was served {closed_at - seen['at']:.1f} s before a place was free")
            failed += 1
        elif seen.get("answer") != "HTTP/1.1 200 OK":
            print(f"FAIL cap: the third connection was answered {seen.get('answer')!r}")
            failed += 1
        else:
            print(f"ok cap: the third connection waited, then was served {seen['at'] - closed_at:.2f} s after a place was free: {seen['answer']}")
    elif case == "head":
        s = connect("http/1.1")
        closed, got = drip(s, b"GET /echo HTTP/1.1\r\nHost: localhost\r\nX-Drip: ", b"a")
        judge("a head a byte at a time", closed, head_ms * 0.9, head_ms + 1500, f"answered {got[:40]!r}" if got else None)
    elif case == "body":
        s = connect("http/1.1")
        closed, got = drip(s, b"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n", b"b")
        judge("a body a byte at a time", closed, request_ms * 0.9, request_ms + 2500, f"answered {got[:40]!r}" if got else None)
    elif case == "h2":
        s = connect("h2")
        if s.selected_alpn_protocol() != "h2":
            print(f"FAIL an HTTP/2 body a frame of a byte at a time: ALPN chose {s.selected_alpn_protocol()!r}")
            failed += 1
            continue
        head = hpack([(b":method", b"POST"), (b":scheme", b"https"), (b":path", b"/echo"),
                      (b":authority", b"localhost"), (b"content-length", b"100")])
        first = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + frame(4, 0, 0, b"") + frame(1, 4, 1, head)
        closed, got = drip(s, first, frame(0, 0, 1, b"c"))
        # Anything but SETTINGS, GOAWAY and WINDOW_UPDATE is an answer.
        kinds, at = set(), 0
        while at + 9 <= len(got):
            kinds.add(got[at + 3])
            at += 9 + int.from_bytes(got[at:at + 3], "big")
        judge("an HTTP/2 body a frame of a byte at a time", closed, request_ms * 0.9, request_ms + 2500,
              f"answered frames of types {sorted(kinds)}" if kinds - {4, 7, 8} else None)
sys.exit(1 if failed else 0)
PY
# guarded <binary> <output> [case...]: the slow clients against that
# binary's serve-guarded; answers whether every case held.
guarded() {
  local bin="$1" out="$2" gpid
  shift 2
  rm -f "$WORK/guarded.port"
  "$bin" serve-guarded "$WORK/guarded.port" "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" 2 3000 5000 >"$WORK/guarded.log" 2>&1 &
  gpid=$!
  for _ in $(seq 1 100); do
    [ -s "$WORK/guarded.port" ] && break
    sleep 0.1
  done
  timeout -k 5 180 "$PY" "$WORK/guard.py" "$(cat "$WORK/guarded.port" 2>/dev/null || echo 1)" "$WORK/tls/root.pem" 3000 5000 "$@" >"$out" 2>&1
  local code=$?
  kill "$gpid" 2>/dev/null
  wait "$gpid" 2>/dev/null
  return $code
}
guard_ready=0
if [ "$https_ready" -ne 1 ] || [ -z "$PY" ]; then
  echo "  skipped: no HTTPS server from the section above, or no python3 to be the slow clients"
else
  guard_ready=1
  guarded "$H2BIN" "$WORK/guarded.out"
  code=$?
  sed 's/^ok /  /; s/^FAIL /  FAIL: /' "$WORK/guarded.out"
  [ "$code" -eq 0 ] || status=1
fi

echo
echo "== through a proxy: a proxy written here in Python, curl beside the client"
# `proxy:` end to end: a forwarding proxy written by hand below - absolute
# form forwarded in origin form, CONNECT tunnelled byte for byte, Basic
# credentials required, and each request logged as it saw it - between
# the iyi client and an iyi server that answers both http:// and https://
# (std/tls, the P-256 leaf from the https:// section above, ALPN h2 and
# http/1.1), and a WebSocket at /ws on both. The server names the
# Proxy-Authorization it was sent, which must be none; the proxy's log
# must show the credential on every request and CONNECT that carried
# one - a WebSocket's CONNECT, ws:// and wss:// alike, among them - and a
# 407 for those that did not. curl
# through the same proxy must leave the same lines in its log and get the
# same answers. Then NO_PROXY, against Go's own net/http where a Go
# toolchain is installed.
cat > "$WORK/proxy.py" <<'PY'
import base64, socket, sys, threading
from urllib.parse import urlsplit
want = "Basic " + base64.b64encode(b"gate:s3cret").decode()
log = open(sys.argv[1], "a", buffering=1)

def read_head(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            return None, b""
        data += chunk
    head, rest = data.split(b"\r\n\r\n", 1)
    return head.decode("latin-1"), rest

def pipe(a, b):
    try:
        while True:
            chunk = a.recv(65536)
            if not chunk:
                break
            b.sendall(chunk)
    except OSError:
        pass
    try:
        b.shutdown(socket.SHUT_WR)
    except OSError:
        pass

def refuse(client, status):
    client.sendall(f"HTTP/1.1 {status}\r\nProxy-Authenticate: Basic realm=\"gate\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())

def handle(client):
    with client:
        head, rest = read_head(client)
        if head is None:
            return
        lines = head.split("\r\n")
        method, target, version = lines[0].split(" ")
        fields = [line.split(":", 1) for line in lines[1:]]
        fields = [(k, v.strip()) for k, v in fields]
        auth = [v for k, v in fields if k.lower() == "proxy-authorization"]
        host = [v for k, v in fields if k.lower() == "host"]
        verdict = "ok" if auth == [want] else ("missing" if not auth else "wrong")
        seen = f"{method} {target} host={','.join(host)} auth={verdict}"
        if verdict != "ok":
            log.write(seen + " 407\n")
            refuse(client, "407 Proxy Authentication Required")
            return
        if method == "CONNECT":
            name, port = target.rsplit(":", 1)
            upstream = socket.create_connection((name.strip("[]"), int(port)))
            log.write(seen + " tunnel\n")
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            if rest:
                upstream.sendall(rest)
            back = threading.Thread(target=pipe, args=(upstream, client))
            back.start()
            pipe(client, upstream)
            back.join()
            upstream.close()
            return
        url = urlsplit(target)
        if url.scheme != "http" or not url.hostname:
            log.write(seen + " 400 not absolute-form\n")
            refuse(client, "400 Bad Request")
            return
        length = int(next((v for k, v in fields if k.lower() == "content-length"), "0"))
        while len(rest) < length:
            rest += client.recv(65536)
        # Hop by hop (RFC 9110 §7.6.1): the credential and the connection
        # are the proxy's, not passed on.
        kept = [f"{k}: {v}" for k, v in fields if k.lower() not in ("proxy-authorization", "connection")]
        path = (url.path or "/") + ("?" + url.query if url.query else "")
        upstream = socket.create_connection((url.hostname, url.port or 80))
        upstream.sendall((f"{method} {path} {version}\r\n" + "".join(f + "\r\n" for f in kept) + "Connection: close\r\n\r\n").encode("latin-1") + rest)
        log.write(seen + " forwarded\n")
        pipe(upstream, client)
        upstream.close()

server = socket.create_server(("127.0.0.1", 0))
print(server.getsockname()[1], flush=True)
while True:
    peer, _ = server.accept()
    threading.Thread(target=handle, args=(peer,), daemon=True).start()
PY
cat > "$WORK/proxy_origin.iyi" <<'IYI'
module main

import std/http::{HTTP, Server, Response, Request}
import std/websocket::{WebSocket, Message}
import std/socket::{IyiSocket}
import std/tls::{TlsServerConfig}
import std/file::{File}

def told(req : Request) : Response
  return talked(req) if req.path == "/ws"
  Response.new(200, "#{req.method} #{req.path} #{req.query || "-"} #{req.version} host=#{req.header("Host")} proxy-auth=#{req.header("Proxy-Authorization") || "-"} length=#{req.body.bytesize}")
end

# A WebSocket that says what its handshake carried, echoes one message,
# and waits for the client's close.
def talked(req : Request) : Response
  WebSocket.upgrade(req) do |ws|
    ws.send("#{req.version} host=#{req.header("Host")} proxy-auth=#{req.header("Proxy-Authorization") || "-"}")
    got = ws.receive
    ws.send("echo " + got.data) if got.is_a?(Message)
    ws.receive
    nil
  end
end

config = TlsServerConfig.from_pem(File.read(Program.args[1]), File.read(Program.args[2])).or_panic
config.alpn = ["h2", "http/1.1"]
plain = IyiSocket.listen("127.0.0.1", 0)
secure = IyiSocket.listen("127.0.0.1", 0)
File.write(Program.args[0], "#{plain.local_port} #{secure.local_port}")
group do |g|
  g.spawn { Server.serve(plain) { |req| told(req) }; 0 }
  g.spawn { Server.serve(secure, tls: config) { |req| told(req) }; 0 }
  0
end
IYI
cat > "$WORK/proxy_client.iyi" <<'IYI'
module main

import std/http::{HTTP, HTTPClient, HTTPError, Response}
import std/websocket::{WebSocket, WebSocketError, Message}
import std/socket::{SocketError}
import std/tls::{TlsConfig}
import std/x509::{Certificate}
import std/file::{File}

def said(got : Response | HTTPError | SocketError | Cancelled) : String
  return "#{got.status} #{got.body}" if got.is_a?(Response)
  return got.message if got.is_a?(HTTPError) || got.is_a?(SocketError)
  "cancelled"
end

def heard(got : Message | Nil | Cancelled | SocketError | WebSocketError) : String
  got.is_a?(Message) ? got.data : got.inspect
end

# A WebSocket's first message, and the echo of one sent: or why there is
# no WebSocket.
def talked(got : WebSocket | Cancelled | SocketError | HTTPError | WebSocketError) : String
  return "cancelled" if got.is_a?(Cancelled)
  return got.message unless got.is_a?(WebSocket)
  first = heard(got.receive)
  got.send("hello").or_panic
  second = heard(got.receive)
  got.close
  first + " | " + second
end

args = Program.args
proxy = "http://gate:s3cret@127.0.0.1:#{args[0]}"
bare = "127.0.0.1:#{args[0]}"
plain = "http://127.0.0.1:#{args[1]}"
secure = "https://localhost:#{args[2]}"
config = TlsConfig.new
config.roots = Certificate.from_pem(File.read(args[3])).or_panic
config.alpn = args[4].split(',')
HTTP.tls_config = config
puts "http: " + said(HTTP.request("GET", plain + "/echo?x=1", proxy: proxy, timeout_ms: 20000))
puts "post: " + said(HTTP.request("POST", plain + "/echo", body: "hello", proxy: proxy, timeout_ms: 20000))
puts "https: " + said(HTTP.request("GET", secure + "/echo?x=2", proxy: proxy, timeout_ms: 20000))
puts "https, the caller's credential: " + said(HTTP.request("GET", secure + "/echo?x=3", {"Proxy-Authorization" => "Basic Z2F0ZTpzM2NyZXQ="}, proxy: bare, timeout_ms: 20000))
# The tunnel first, kept, then http:// through the same proxy: which must
# not be written into the tunnel, to the https:// server.
client = HTTPClient.new(proxy: proxy, timeout_ms: 20000)
puts "client https: " + said(client.get(secure + "/echo?k=2"))
puts "client https again: " + said(client.get(secure + "/echo?k=3"))
puts "client http: " + said(client.get(plain + "/echo?k=1"))
puts "client: #{client.connections_made} made, #{client.connections_reused} reused"
client.close
puts "https, no credential: " + said(HTTP.request("GET", secure + "/echo?x=4", proxy: bare, timeout_ms: 20000))
puts "http, no credential: " + said(HTTP.request("GET", plain + "/echo?x=5", proxy: bare, timeout_ms: 20000))
puts "https, a wrong credential: " + said(HTTP.request("GET", secure + "/echo?x=6", proxy: "http://gate:wrong@127.0.0.1:#{args[0]}", timeout_ms: 20000))
# WebSockets through the proxy: a CONNECT tunnel for ws:// as for wss://.
puts "ws: " + talked(WebSocket.connect("ws://127.0.0.1:#{args[1]}/ws", proxy: proxy))
puts "wss: " + talked(WebSocket.connect("wss://localhost:#{args[2]}/ws", proxy: proxy))
puts "ws, no credential: " + talked(WebSocket.connect("ws://127.0.0.1:#{args[1]}/ws", proxy: bare))
IYI
# proxy_up / proxy_down: the proxy and the origin started and stopped,
# their ports in PPORT, HPORT and SPORT, the proxy's log emptied.
proxy_up() {
  : > "$WORK/proxy.log"
  "$PY" "$WORK/proxy.py" "$WORK/proxy.log" > "$WORK/proxy.out" 2>&1 &
  proxy_pid=$!
  rm -f "$WORK/origin.ports"
  "$WORK/proxy_origin" "$WORK/origin.ports" "$WORK/tls/p256.pem" "$WORK/tls/leaf.key" > "$WORK/origin.out" 2>&1 &
  origin_pid=$!
  PPORT=$(await_port "$WORK/proxy.out" "$proxy_pid")
  for _ in $(seq 1 100); do
    [ -s "$WORK/origin.ports" ] && break
    sleep 0.1
  done
  read -r HPORT SPORT < "$WORK/origin.ports"
}
proxy_down() {
  kill "$proxy_pid" "$origin_pid" 2>/dev/null
  wait "$proxy_pid" "$origin_pid" 2>/dev/null
}
# What the client must print, and the proxy log, for ALPN's HTTP/<version>.
proxy_expected() {
  local v="$1" echo="host=127.0.0.1:$HPORT proxy-auth=-" tls="host=localhost:$SPORT proxy-auth=-"
  cat <<EOF
http: 200 GET /echo x=1 HTTP/1.1 $echo length=0
post: 200 POST /echo - HTTP/1.1 $echo length=5
https: 200 GET /echo x=2 $v $tls length=0
https, the caller's credential: 200 GET /echo x=3 $v $tls length=0
client https: 200 GET /echo k=2 $v $tls length=0
client https again: 200 GET /echo k=3 $v $tls length=0
client http: 200 GET /echo k=1 HTTP/1.1 $echo length=0
client: 2 made, 1 reused
https, no credential: HTTP: the proxy at 127.0.0.1:$PPORT answered 407 Proxy Authentication Required to CONNECT localhost:$SPORT
http, no credential: 407 
https, a wrong credential: HTTP: the proxy at 127.0.0.1:$PPORT answered 407 Proxy Authentication Required to CONNECT localhost:$SPORT
ws: HTTP/1.1 $echo | echo hello
wss: HTTP/1.1 $tls | echo hello
ws, no credential: HTTP: the proxy at 127.0.0.1:$PPORT answered 407 Proxy Authentication Required to CONNECT 127.0.0.1:$HPORT
--
GET http://127.0.0.1:$HPORT/echo?x=1 host=127.0.0.1:$HPORT auth=ok forwarded
POST http://127.0.0.1:$HPORT/echo host=127.0.0.1:$HPORT auth=ok forwarded
CONNECT localhost:$SPORT host=localhost:$SPORT auth=ok tunnel
CONNECT localhost:$SPORT host=localhost:$SPORT auth=ok tunnel
CONNECT localhost:$SPORT host=localhost:$SPORT auth=ok tunnel
GET http://127.0.0.1:$HPORT/echo?k=1 host=127.0.0.1:$HPORT auth=ok forwarded
CONNECT localhost:$SPORT host=localhost:$SPORT auth=missing 407
GET http://127.0.0.1:$HPORT/echo?x=5 host=127.0.0.1:$HPORT auth=missing 407
CONNECT localhost:$SPORT host=localhost:$SPORT auth=wrong 407
CONNECT 127.0.0.1:$HPORT host=127.0.0.1:$HPORT auth=ok tunnel
CONNECT localhost:$SPORT host=localhost:$SPORT auth=ok tunnel
CONNECT 127.0.0.1:$HPORT host=127.0.0.1:$HPORT auth=missing 407
EOF
}
# proxy_round <client binary> <alpn> <HTTP/version>: the client through a
# fresh proxy and origin; 0 when its output and the proxy's log are the
# expected ones, and otherwise the first line that differs, printed.
proxy_round() {
  local bin="$1" alpn="$2" v="$3" got want
  proxy_up
  # Without CRs: Python writes the proxy's log with CRLF on Windows.
  got="$(timeout -k 5 "${PROXY_ROUND_SECONDS:-120}" "$bin" "$PPORT" "$HPORT" "$SPORT" "$WORK/tls/root.pem" "$alpn" 2>&1; echo --; tr -d '\r' <"$WORK/proxy.log")"
  want="$(proxy_expected "$v")"
  proxy_down
  if [ "$got" = "$want" ]; then
    return 0
  fi
  diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | grep -m2 '^[<>]' | sed 's/^/    /'
  return 1
}
proxy_ready=0
if [ -z "$PY" ] || [ ! -s "$WORK/tls/p256.pem" ]; then
  echo "  skipped: no python3, or no certificate from the https:// section above"
elif ! "$IYI" build -o "$WORK/proxy_origin" "$WORK/proxy_origin.iyi" > "$WORK/proxy_origin.build" 2>&1 ||
     ! "$IYI" build -o "$WORK/proxy_client" "$WORK/proxy_client.iyi" > "$WORK/proxy_client.build" 2>&1; then
  echo "  the proxy's origin or client did not build"
  sed -n '1,8p' "$WORK/proxy_origin.build" "$WORK/proxy_client.build"
  status=1
else
  proxy_ready=1
  for round in "http/1.1 HTTP/1.1" "h2,http/1.1 HTTP/2"; do
    set -- $round
    if proxy_round "$WORK/proxy_client" "$1" "$2"; then
      echo "  ALPN $1: http:// forwarded and https:// tunnelled ($2 inside), a WebSocket tunnelled ws:// and wss://, the credential at the proxy and never at the server, a kept tunnel, 407 named"
    else
      echo "  ALPN $1: the client through the proxy did not answer as expected"
      status=1
    fi
  done
  if command -v curl >/dev/null 2>&1; then
    proxy_up
    # Schannel (Windows' curl) asks a revocation list the gate's own root
    # has none of, and refuses the server for it.
    norevoke=()
    curl --version 2>/dev/null | head -1 | grep -q 'Schannel' && norevoke=(--ssl-no-revoke)
    c=(curl -sS --noproxy '' -x "http://gate:s3cret@127.0.0.1:$PPORT" --cacert "$WORK/tls/root.pem" --http1.1 ${norevoke[@]+"${norevoke[@]}"})
    got="$("${c[@]}" "http://127.0.0.1:$HPORT/echo?x=1"; echo; "${c[@]}" "https://localhost:$SPORT/echo?x=2"; echo; curl -sS --noproxy '' -x "http://127.0.0.1:$PPORT" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HPORT/echo?x=5"; echo; tr -d '\r' <"$WORK/proxy.log")"
    proxy_down
    want="GET /echo x=1 HTTP/1.1 host=127.0.0.1:$HPORT proxy-auth=- length=0
GET /echo x=2 HTTP/1.1 host=localhost:$SPORT proxy-auth=- length=0
407
GET http://127.0.0.1:$HPORT/echo?x=1 host=127.0.0.1:$HPORT auth=ok forwarded
CONNECT localhost:$SPORT host=localhost:$SPORT auth=ok tunnel
GET http://127.0.0.1:$HPORT/echo?x=5 host=127.0.0.1:$HPORT auth=missing 407"
    if [ "$got" = "$want" ]; then
      echo "  curl through the same proxy: the same answers, and the same lines in its log as the iyi client's"
    else
      echo "  curl through the proxy disagrees:"
      diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/    /'
      status=1
    fi
  else
    echo "  curl is not installed; its cross-check skipped"
  fi
fi

# NO_PROXY against Go's net/http, which reads it with
# golang.org/x/net/http/httpproxy: one process per environment (Go reads
# its environment once), each URL's proxy printed beside `proxy_for`'s.
GO="${GO:-go}"
cat > "$WORK/proxy_table.iyi" <<'IYI'
module main

import std/http::{HTTP}

args = Program.args
args[3, args.size - 3].each do |url|
  puts "#{url} #{HTTP.proxy_for(url, args[0].empty? ? nil : args[0], args[1].empty? ? nil : args[1], args[2]) || "direct"}"
end
IYI
mkdir -p "$WORK/goproxy"
cat > "$WORK/goproxy/main.go" <<'GO'
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	for _, u := range os.Args[1:] {
		req, err := http.NewRequest("GET", u, nil)
		if err != nil {
			fmt.Println(u, "unparsed")
			continue
		}
		p, err := http.ProxyFromEnvironment(req)
		switch {
		case err != nil:
			fmt.Println(u, "error")
		case p == nil:
			fmt.Println(u, "direct")
		default:
			fmt.Println(u, p.String())
		}
	}
}
GO
# HTTP_PROXY|HTTPS_PROXY|NO_PROXY|URL ...
no_proxy_table='proxy|sproxy|foobar.com, .barbaz.net, *.wildcard.io, 192.168.1.1, 192.168.1.2:81, 192.168.1.3:80, 10.0.0.0/30, 2001:db8::52:0:1, [2001:db8::52:0:2]:443, [2001:db8::52:0:3]:80, 2002:db8:a::45/64|http://localhost http://LOCALHOST:8080 http://127.0.0.1 http://127.0.0.2 http://[::1] http://[::2] http://[::ffff:127.0.0.1] http://192.168.1.1 http://192.168.1.2 http://192.168.1.2:81 http://192.168.1.3 https://192.168.1.3 http://10.0.0.2 http://10.0.0.4 http://[2001:db8::52:0:1] http://[2001:db8::52:0:2] https://[2001:db8::52:0:2] http://[2001:db8::52:0:3] http://[2002:db8:a::123] http://[2002:db8:b::1] http://[fe80::424b:c8be:1643:a1b6] http://barbaz.net http://www.barbaz.net https://www.barbaz.net http://foobar.com http://www.foobar.com http://WWW.FooBar.com http://foofoobar.com http://baz.com http://localhost.net http://local.localhost http://barbarbaz.net http://wildcard.io http://nested.wildcard.io http://awildcard.io
proxy|https://sproxy:8443|example.com:8080, ::ffff:10.0.0.0/104, [::ffff:9.9.9.9], 172.16.0.0/12|http://example.com/ http://example.com:8080/ https://example.com:8080/ http://10.1.2.3/ http://[::ffff:10.1.2.3]/ http://9.9.9.9/ http://172.20.0.1/ https://172.32.0.1/ ftp://example.com/
cache.corp:3128||*|http://example.com/ https://example.com/ http://10.1.1.1/
http://u:p@cache.corp:3128||  .Example.COM ,, :80, [::1, ::1]:80|http://example.com/ http://a.example.com/ http://a.example.com.evil/
socks5://127.0.0.1:1080|||http://example.com/ https://example.com/
proxy||bücher.example, .xn--caf-dma.example|http://xn--bcher-kva.example/ http://bücher.example/ http://www.BÜCHER.example/ http://a.café.example/ http://café.example/'
if ! { command -v "$GO" >/dev/null 2>&1 && "$GO" version >/dev/null 2>&1; }; then
  echo "  NO_PROXY against Go: skipped, no Go toolchain (GO=$GO)"
elif ! (cd "$WORK/goproxy" && GO111MODULE=off GOFLAGS= "$GO" build -o "$WORK/goproxy/px" main.go) > "$WORK/goproxy.build" 2>&1 ||
     ! "$IYI" build -o "$WORK/proxy_table" "$WORK/proxy_table.iyi" > "$WORK/proxy_table.build" 2>&1; then
  echo "  NO_PROXY against Go: a program did not build"
  sed -n '1,8p' "$WORK/goproxy.build" "$WORK/proxy_table.build"
  status=1
else
  compared=0
  environments=0
  differed=0
  while IFS='|' read -r hp hsp np urls; do
    # shellcheck disable=SC2086
    go_said="$(env -i HTTP_PROXY="$hp" HTTPS_PROXY="$hsp" NO_PROXY="$np" "$WORK/goproxy/px" $urls)"
    # shellcheck disable=SC2086
    iyi_said="$("$WORK/proxy_table" "$hp" "$hsp" "$np" $urls)"
    compared=$((compared + $(printf '%s\n' "$go_said" | wc -l)))
    environments=$((environments + 1))
    if [ "$go_said" != "$iyi_said" ]; then
      differed=1
      echo "  NO_PROXY=$np: Go and proxy_for disagree:"
      diff <(printf '%s\n' "$go_said") <(printf '%s\n' "$iyi_said") | sed 's/^/    /'
    fi
  done <<< "$no_proxy_table"
  if [ "$differed" -eq 0 ]; then
    echo "  $compared URLs under $environments environments: proxy_for answers what Go's net/http does ($("$GO" version | cut -d' ' -f3))"
  else
    status=1
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
# The broken copies are built one after another and run beside each other,
# MUT_JOBS at a time: a run of the exercise is 21 seconds of mostly waiting
# on its own sockets and clocks, and ninety-seven of them one at a time
# took the gate past the 35 minutes `bench/std_siblings.sh` gives a
# sibling. Each answer goes to a file of its own and they are printed in
# order once all have ended.
MUT_JOBS="${MUT_JOBS:-4}"
mutation_pids=""
mkdir -p "$WORK/mutres"
mutation_said() { # mutation_said <n> <line>...: the n-th mutation's answer
  local n="$1"
  shift
  printf '%s\n' "$@" > "$WORK/mutres/$n"
}
mutate() { # mutate <label> <old> <new> [module, http.iyi by default]
  # A binary of its own each: on Windows the last one's file can still be
  # held a moment after it ended, and the next link over it failed with
  # LNK1104 - three of thirty mutations here, whichever came after.
  mutations=$((mutations + 1))
  local label="$1" old="$2" new="$3" module="${4:-http.iyi}" n="$mutations"
  if [ -z "$PY" ]; then
    mutation_said "$n" "  $label: skipped, no working python3 to make the broken copy with"
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
    mutation_said "$n" "  $label: the patch did not apply"
    touch "$WORK/mutres/failed"
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 300 "$IYI" build -o "$WORK/mut-$n.bin" "$REPO/bench/std_http_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    mutation_said "$n" "  $label: the broken copy did not compile" "$(sed -n '1,6p' "$WORK/mut.out")"
    touch "$WORK/mutres/failed"
  else
    (
      if timeout -k 5 120 "$WORK/mut-$n.bin" >"$WORK/mut-$n.out" 2>&1; then
        mutation_said "$n" "  $label: the exercise PASSED on a broken module"
        touch "$WORK/mutres/failed"
      else
        mutation_said "$n" "  $label: caught"
      fi
    ) &
    mutation_pids="$mutation_pids $!"
    # `wait -n` where the shell has it (bash 4.3); darwin's 3.2 polls.
    while [ "$(jobs -rp | wc -l)" -ge "$MUT_JOBS" ]; do
      wait -n 2>/dev/null || sleep 0.2
    done
  fi
}
mutations_report() { # every answer, in the order the mutations were made
  local pid n=1
  for pid in $mutation_pids; do
    wait "$pid"
  done
  while [ "$n" -le "$mutations" ]; do
    cat "$WORK/mutres/$n"
    n=$((n + 1))
  done
  [ -e "$WORK/mutres/failed" ] && status=1
  return 0
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
mutate "a server that waits on a client partway through a request" 'conn = Conn.new(client, listener, idle, stream)' 'conn = Conn.new(client, listener, nil, stream)'
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
      socket = conn.transport' '    if false
      socket = conn.transport'
mutate "a server whose tasks share the accept loop's variable" '          spawn_handler(g, client, handler, listener, idle, stream_bodies, compress, timeout_ms, tls, request_timeout_ms, slots)' '          accepted = client
          g.spawn do
            handle(accepted, handler)
            slots.take_now if slots
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
mutate "a q of 0 taken for gzip" 'return 0 if zero_weight?(text)' 'return 1000 if zero_weight?(text)'
mutate "a q read as 0 or 1" 'value = value + (p[i] - 48_u8).to_i32 * scale' 'value = 1000'
mutate "a short body compressed" 'response.body.bytesize >= COMPRESS_FROM' 'response.body.bytesize >= 0'
mutate "an image compressed" 'return nil unless type && MIME.compressible?(type)' 'return nil unless type'
mutate "a gzip answer that does not vary" 'headers["Vary"] = "Accept-Encoding"' ''
mutate "a bare deflate stream read as zlib's" 'envelope = Envelope::Raw unless zlib' ''
mutate "a decoded body that keeps the coded body's fields" 'fields.reject_in_place { |key, _| same_name?(key, "Content-Encoding") || same_name?(key, "Content-Length") }' ''
mutate "zstd not asked for" 'sent["Accept-Encoding"] = "gzip, deflate, zstd" if asked' 'sent["Accept-Encoding"] = "gzip, deflate" if asked'
mutate "a zstd answer left as it came" '    if name == "zstd"
      reader.decode_zstd(Zstd::WINDOW_LIMIT)' '    if name == "zstd"
      return false'
mutate "a zstd window past 8 MiB taken" 'reader.decode_zstd(Zstd::WINDOW_LIMIT)' 'reader.decode_zstd(536870912)'
mutate "zstd sent where the client prefers gzip" 'return "zstd" if zstd > 0 && zstd >= gzip' 'return "zstd" if zstd > 0'
mutate "a tie given to gzip" 'return "zstd" if zstd > 0 && zstd >= gzip' 'return "zstd" if zstd > 0 && zstd > gzip'
mutate "zstd sent to a client that refuses it" 'return "zstd" if zstd > 0 && zstd >= gzip' 'return "zstd" if zstd >= gzip'
mutate "a stream sent gzip to a client that takes zstd alone" 'if response.source.nil? && response.writer.nil?' 'if true'
mutate "HTTP/2 answers in gzip where zstd was chosen" 'response = Server.compressed(response, coding) if coding && response.body.bytesize >= Server::COMPRESS_FROM' 'response = Server.compressed(response, "gzip") if coding && response.body.bytesize >= Server::COMPRESS_FROM'
mutate "an upgrade sent past its proxy" 'exchange = exchange("GET", url, sent, "", nil, false, "Upgrade", nil, timeout_ms, route)' 'exchange = exchange("GET", url, sent, "", nil, false, "Upgrade", nil, timeout_ms, nil)'
mutate "an upgrade to http:// sent to a proxy in absolute form" 'tunneled = !route.nil? && (secure || !upgrade.nil?)' 'tunneled = !route.nil? && secure'
mutate "a redirect that never changes the method" 'unless keeps || (status != 303 && !same_name?(verb, "POST")) || same_name?(verb, "HEAD")' 'unless true'
mutate "credentials carried to another host" 'sent = without(sent, ["Authorization", "Proxy-Authorization", "Cookie"]) unless same_authority?(current, target)' ''
mutate "a part that does not end at its boundary" '          @held = @held[@delimiter.bytesize, @held.bytesize - @delimiter.bytesize]
          @part_done = true' '          @held = @held[@delimiter.bytesize, @held.bytesize - @delimiter.bytesize]'
mutate "a client that never keeps a connection" 'conn = keeping.take(key, secure ? under : nil) unless upgrade' ''
mutate "a client that keeps a connection the answer closed" 'keep = got.starts_with?("HTTP/1.1 ") && !reader.to_close? && status != 101 && (said.nil? || !has_token?(said, "close"))' 'keep = true'
mutate "a client that holds a connection for whatever was left unread" 'client && @keep && !@conn.ended? && @reader.drain(65536_i64)' 'client && @keep && !@conn.ended? && @reader.drain(9223372036854775807_i64)'
mutate "a GET not sent again when its kept connection was closed" 'retry = body.is_a?(String) && (head ||' 'retry = false && (head ||'
mutate "a POST sent again when its kept connection was closed" 'retry = body.is_a?(String) && (head || same_name?(method, "GET") || same_name?(method, "PUT") || same_name?(method, "DELETE") || same_name?(method, "OPTIONS") || same_name?(method, "TRACE"))' 'retry = body.is_a?(String)'
mutate "a head given as long as each read is short" '      conn.deadline_at(until_head(started, timeout_ms, whole))
      got = conn.read_head(' '      got = conn.read_head('
mutate "an upgraded connection held to the server's timeout" '      conn.unlimited
' ''
mutate "a client that waits for an answer as long as it takes" '        conn.gap = timeout_ms if timeout_ms > 0
        if speaks_h2' '        if speaks_h2'
mutate "a request that does not name its client" '    remote = client.remote_address' '    remote = nil.as(String?)'
mutate "a boundary that falls across reads missed" 'safe = @held.bytesize - (@delimiter.bytesize - 1)' 'safe = @held.bytesize'
mutate "an http:// request to a proxy in origin form" 'target = "http://" + host_line + path' 'target = path'
mutate "a proxy URL's credential not sent with an http:// request" '          sent["Proxy-Authorization"] = credential' '          nil'
mutate "kept proxy connections filed by origin, not by proxy" 'key = via.key
        target = ' 'target = '
mutate "a CONNECT without the caller's own credential" 'tunnel_credential = via.authorization || header_in(headers, "Proxy-Authorization")' 'tunnel_credential = via.authorization'
mutate "HTTP/2 with prior knowledge spoken to a proxy" '&& client.prior_knowledge && route.nil?' '&& client.prior_knowledge'
mutate "a CONNECT refused taken for a tunnel" 'unless status >= 200 && status < 300' 'if false'
mutate "bytes after a CONNECT's 200 handed to TLS" 'if conn.available > 0
        return HTTPError.new("the proxy at' 'if false
        return HTTPError.new("the proxy at'
mutate "an https:// proxy spoken in the clear" 'only http:// proxies") unless scheme == "http"' 'only http:// proxies") if false'
mutate "https:// taking HTTP_PROXY" 'chosen = if scheme == "https"
               https_proxy' 'chosen = if scheme == "https"
               http_proxy'
mutate "localhost sent through a proxy" 'return false if ascii == "localhost"' ''
mutate "a loopback address sent through a proxy" 'return false if ip && loopback?(ip)' ''
mutate "a NO_PROXY domain matching names that merely end in it" 'suffix = "." + ascii_name(phost)' 'suffix = ascii_name(phost)'
mutate "NO_PROXY's CIDR ranges passed over" 'return false if ip && in_range?(ip, net, dotted ? bits + 96 : bits)' 'nil'
mutate "an IPv6 range holding IPv4 addresses" '    return false unless mapped?(ip) == mapped?(cut)' ''
mutate "a NO_PROXY address's port passed over" 'return false if ip && ip == pip && (pport.bytesize == 0 || pport == port)' 'return false if ip && ip == pip'
mutate "a NO_PROXY domain's port passed over" 'return false if pport.bytesize == 0 || pport == port' 'return false'
mutations_report

# HTTP/2, each mechanism taken out of a copy that compiles: the iyi-to-iyi
# exercise stops at the check that names it, or the raw frames find the
# answer RFC 9113 asks for missing.
h2_patched() { # h2_patched <name> <old> <new> [module, http.iyi by default]: a broken http2_exercise in $WORK/<name>.bin
  local module="${4:-http.iyi}"
  rm -rf "$WORK/$1"
  mkdir -p "$WORK/$1/std"
  OLD="$2" NEW="$3" "$PY" - "$REPO/src/std/$module" "$WORK/$1/std/$module" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique: " + old)
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(src.replace(old, os.environ["NEW"], 1))
PY
  [ $? -eq 0 ] || return 1
  IYI_PATH="$WORK/$1${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 300 "$IYI" build -o "$WORK/$1.bin" "$REPO/bench/http2_exercise.iyi" >"$WORK/$1.log" 2>&1
}
h2_breaks() { # h2_breaks <label> <name> <old> <new> <check>
  local label="$1" name="$2" old="$3" new="$4" check="$5"
  if [ "$h2_built" -ne 1 ] || [ -z "$PY" ]; then
    echo "  $label: skipped, no HTTP/2 exercise or no python3"
  elif ! h2_patched "$name" "$old" "$new"; then
    echo "  $label: the broken copy did not build"
    sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /'
    status=1
  else
    timeout -k 5 120 "$WORK/$name.bin" >"$WORK/$name.out" 2>&1
    if grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
      echo "  $label: the HTTP/2 exercise PASSED on a broken module"
      status=1
    elif ! grep -qF -- "ASSERTION FAILED: $check" "$WORK/$name.out"; then
      echo "  $label: it failed, but not at '$check'"
      grep -m2 'panic\|FAILED' "$WORK/$name.out" | sed 's/^/    /'
      status=1
    else
      echo "  $label: caught at \"$check\""
    fi
  fi
}
# h2_node_breaks <label> <name> <old> <new>: Node's client, which holds a
# server to the 1000-byte windows it advertises, fails on the broken one.
h2_node_breaks() {
  local label="$1" name="$2" old="$3" new="$4"
  if [ "$h2_built" -ne 1 ] || [ -z "$PY" ] || [ -z "$NODE" ] || [ ! -s "$WORK/h2-client.js" ]; then
    echo "  $label: skipped, no HTTP/2 server, python3 or node"
  elif ! h2_patched "$name" "$old" "$new"; then
    echo "  $label: the broken copy did not build"
    sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /'
    status=1
  else
    local good="$H2BIN"
    H2BIN="$WORK/$name.bin"
    h2_serve
    timeout -k 5 120 "$NODE" "$WORK/h2-client.js" "$H2PORT" >"$WORK/$name.out" 2>&1
    local code=$?
    h2_stop
    H2BIN="$good"
    if [ "$code" -ne 0 ] && grep -q "FAIL\|FLOW_CONTROL" "$WORK/$name.out"; then
      echo "  $label: caught by Node's client: $(grep -m1 'FAIL' "$WORK/$name.out" | sed 's/^ *//')"
    else
      echo "  $label: Node's client did not fail on a broken server (exit $code)"
      status=1
    fi
  fi
}
h2_frames_breaks() { # h2_frames_breaks <label> <name> <old> <new> <case>
  local label="$1" name="$2" old="$3" new="$4" case_name="$5"
  if [ "$h2_built" -ne 1 ] || [ -z "$PY" ] || [ ! -s "$WORK/h2frames.py" ]; then
    echo "  $label: skipped, no HTTP/2 server, python3 or frames to send it"
  elif ! h2_patched "$name" "$old" "$new"; then
    echo "  $label: the broken copy did not build"
    sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /'
    status=1
  else
    local good="$H2BIN"
    H2BIN="$WORK/$name.bin"
    h2_serve
    local code=0
    timeout -k 5 300 "$PY" "$WORK/h2frames.py" "$H2PORT" >"$WORK/$name.out" 2>&1 || code=$?
    h2_stop
    H2BIN="$good"
    if grep -qF -- "FAIL: $case_name:" "$WORK/$name.out"; then
      echo "  $label: caught by the frames for \"$case_name\""
    else
      # A miss and a run that never reached the case read apart: once on
      # Windows (tls/resumption, job 118118781204) this missed where every
      # other run caught it, and nothing was left to say which. 124 is the
      # timeout's; the frames exit 1 for a failure, 0 for none.
      if [ "$code" -eq 0 ]; then
        echo "  $label: the frames for \"$case_name\" did not fail on a broken server"
      else
        echo "  $label: the frames stopped (exit $code) without a verdict on \"$case_name\""
      fi
      tail -4 "$WORK/$name.out" | sed 's/^/    /'
      status=1
    fi
  fi
}
h2_breaks "a stream's window never opened again" h2_stream_window \
  '          write_frame(WINDOW_UPDATE, 0, id, H2Connection.u32(piece.bytesize))' '          nil' \
  'a megabyte up through the windows'
h2_breaks "the connection's window never opened again" h2_conn_window \
  '      return false unless write_frame(WINDOW_UPDATE, 0, 0, H2Connection.u32(size.to_i32))' '      nil' \
  'a megabyte up through the windows'
h2_node_breaks "the peer's stream window passed over" h2_peer_window \
  '      room = s.send_window.to_i32 if s.send_window < room.to_i64' '      nil'
h2_breaks "the preface not recognised" h2_preface \
  '        return false if conn.peek(seen) != wanted.to_unsafe[seen]' '        return false' \
  'GET over HTTP/2'
h2_breaks "Set-Cookie lines joined into one field" h2_cookies \
  '        each_line.each { |line| fields << Std::Hpack::HeaderField.new(lower, H2Connection.trimmed(line)) }' \
  '        fields << Std::Hpack::HeaderField.new(lower, H2Connection.trimmed(value))' \
  'Set-Cookie on fields of their own'
h2_breaks "an upgrade reset as if cancelled" h2_upgrade \
  '      refuse(id, HTTP_1_1_REQUIRED)' '      refuse(id, CANCEL)' \
  'an upgrade is reset with HTTP_1_1_REQUIRED'
h2_breaks "a stream's reset taking its connection" h2_reset_closes \
  '        if h2.usable?
          # One stream' '        if false
          # One stream' \
  "a stream's reset leaves its connection"
h2_breaks "a gzip answer left coded" h2_gzip \
  '      decoded = undo_coding(reader, headers)
      if decoded.is_a?(HTTPError)
        h2.forget(id)' '      decoded = false
      if decoded.is_a?(HTTPError)
        h2.forget(id)' \
  'a gzip answer decoded as it is read'
h2_frames_breaks "a request's fields unchecked" h2_fields \
  '      return refuse(id, PROTOCOL_ERROR) if H2Connection.request_flaw(decoded)' '      nil' \
  'a field name in upper case'
h2_frames_breaks "a header block held whatever its size" h2_flood \
  '    return fail(ENHANCE_YOUR_CALM, "a header block past #{HEADER_LIST} bytes") if @block.size + piece.bytesize > HEADER_LIST' '    nil' \
  'a CONTINUATION flood'
h2_frames_breaks "the first frame taken whatever it is" h2_first \
  '    if !@settled && (type != SETTINGS || flags & ACK != 0)' '    if false' \
  'the first frame not SETTINGS'
h2_frames_breaks "a frame of any size read" h2_frame_size \
  '    return fail(FRAME_SIZE_ERROR, "a frame of #{length} bytes, past the #{FRAME} this end takes") if length > FRAME' '    nil' \
  'a frame past 16384 bytes'
h2_frames_breaks "a GOAWAY for a connection error closed on at once" linger_h2 \
  '    h2.goaway
    true
  end' '    h2.goaway
    false
  end' \
  'a frame past 16384 bytes, its rest sent after the GOAWAY'
h2_frames_breaks "a malformed head's 400 closed on at once" linger_head \
  '          refuse(conn.transport, parsed)
          return true' '          refuse(conn.transport, parsed)
          return false' \
  'a malformed head, a body sent after the answer'
h2_frames_breaks "a 431 closed on at once" linger_431 \
  '        refuse(conn.transport, got)
        return true' '        refuse(conn.transport, got)
        return false' \
  'a head past 1 MiB, more sent after the answer'
h2_frames_breaks "a broken body's 400 closed on at once" linger_body \
  '            refuse(conn.transport, body)
            return true' '            refuse(conn.transport, body)
            return false' \
  'a broken chunk, more sent after the answer'
# The lingering close broken, in std/http or under it in std/tls: the case
# that names the break, three runs, must fail - and the client's own close
# where that is named. The copies are built one after another (they share
# the compiler's cache) and run MUT_JOBS at a time, each against servers
# of its own; the answers are printed in order once all have ended.
close_n=0
close_pids=""
mkdir -p "$WORK/closeres"
close_judged() { # close_judged <n> <label> <name> <plain|tls|-> <case> <client|client-tls|->
  local n="$1" label="$2" name="$3" over="$4" case_name="$5" client="$6" got said=""
  if [ "$over" != - ]; then
    close_round "$name" "$WORK/$name.bin" 3 "$over" "$case_name" >"$WORK/$name.out" 2>&1
    if grep -qF -- "FAIL: $case_name:" "$WORK/$name.out"; then
      said="  $label: caught: $(grep -m1 -F -- "FAIL: $case_name:" "$WORK/$name.out" | sed 's/^ *FAIL: //' | cut -c1-150)"
    else
      printf '%s\n' "  $label: the close cases did not fail at \"$case_name\"" "$(tail -4 "$WORK/$name.out" | sed 's/^/    /')" >"$WORK/closeres/$n"
      touch "$WORK/closeres/failed"
      return
    fi
  fi
  if [ "$client" != - ]; then
    got="$(client_close_round "$WORK/$name.bin" "${client#client}" "$name-c")"
    if client_close_holds "$got"; then
      printf '%s\n' "  $label: the client's close held on a broken copy: $(printf '%s' "$got" | tr '\n' ' ')" >"$WORK/closeres/$n"
      touch "$WORK/closeres/failed"
      return
    fi
    said="${said:+$said
}  $label: caught at the client's close: $(printf '%s' "$got" | tr '\n' ' ' | cut -c1-140)"
  fi
  printf '%s\n' "$said" >"$WORK/closeres/$n"
}
close_breaks() { # close_breaks <label> <name> <module> <old> <new> <plain|tls|-> <case> [client|client-tls]
  local label="$1" name="$2" module="$3" old="$4" new="$5" over="$6" case_name="$7" client="${8:--}" pid running
  close_n=$((close_n + 1))
  if [ "$close_ready" -ne 1 ] || { case "$over$client" in *tls*) true ;; *) false ;; esac && [ ! -s "$WORK/tls/p256.pem" ]; }; then
    echo "  $label: skipped with the close cases" >"$WORK/closeres/$close_n"
    return
  elif ! h2_patched "$name" "$old" "$new" "$module"; then
    printf '%s\n' "  $label: the broken copy did not build" "$(sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /')" >"$WORK/closeres/$close_n"
    touch "$WORK/closeres/failed"
    return
  fi
  close_judged "$close_n" "$label" "$name" "$over" "$case_name" "$client" &
  close_pids="$close_pids $!"
  while :; do
    running=""
    for pid in $close_pids; do
      kill -0 "$pid" 2>/dev/null && running="$running $pid"
    done
    close_pids="$running"
    [ "$(echo $close_pids | wc -w)" -lt "$MUT_JOBS" ] && break
    sleep 0.2
  done
}
close_breaks_report() {
  local pid n=1
  for pid in $close_pids; do
    wait "$pid"
  done
  while [ "$n" -le "$close_n" ]; do
    cat "$WORK/closeres/$n"
    n=$((n + 1))
  done
  [ -e "$WORK/closeres/failed" ] && status=1
  return 0
}
close_breaks "the linger removed: a close at once" close_nolinger http.iyi \
  '    else
      linger
    end' '    else
      @socket.close
    end' plain 'http.client, Connection: close' client
close_breaks "close_write skipped: the sending half never shut" close_nohalf http.iyi \
  '    socket.close_write
' '' plain 'Python reading as it sends, Connection: close'
close_breaks "TLS: the drain removed" close_nodrain tls.iyi \
  '    drain unless @eof
' '' tls 'http.client, Connection: close'
close_breaks "TLS: close_write skipped by close, so no close_notify" close_notify tls.iyi \
  '    close_write
    drain unless @eof' '    drain unless @eof' tls 'Python reading as it sends, Connection: close'
close_breaks "TLS: the client closing at once" close_client_tls http.iyi \
  '    elsif stream = @stream
      stream.close
    else' '    elsif stream = @stream
      close_now
    else' - - client-tls
h2_frames_breaks "HEADERS on a closed stream passed over" h2_stale \
  '          mode = @reset_lately.includes?(id) ? IGNORED_BLOCK : STALE_BLOCK' '          mode = IGNORED_BLOCK' \
  'HEADERS on a closed stream'
# The HTTPS server broken, the checks above run against it with the good
# client: each must fail somewhere.
https_breaks() { # https_breaks <label> <name> <old> <new>
  local label="$1" name="$2" old="$3" new="$4"
  if [ "$https_ready" -ne 1 ] || [ -z "$PY" ]; then
    echo "  $label: skipped, no HTTPS server to break"
  elif ! h2_patched "$name" "$old" "$new"; then
    echo "  $label: the broken copy did not build"
    sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /'
    status=1
  elif HTTPS_FIRST_FAIL=1 HTTPS_GET_SECONDS=20 https_checks "$WORK/$name.bin" "$WORK/tls/ed.pem" "$WORK/tls/ed.key" ed >"$WORK/$name.out" 2>&1; then
    echo "  $label: the HTTPS checks passed on a broken server"
    status=1
  else
    echo "  $label: caught: $(grep -m1 'FAIL' "$WORK/$name.out" | sed 's/^ *FAIL: //' | cut -c1-120)"
  fi
}
https_breaks "an answer written past TLS" https_clear \
  '    socket = conn.transport
    head = HTTP.same_name?(req.method, "HEAD")' '    socket = conn.socket
    head = HTTP.same_name?(req.method, "HEAD")'
https_breaks "the TLS handshake skipped" https_plain \
  '    unless config = tls' '    unless config = nil.as(TlsServerConfig?)'
https_breaks "no close_notify at the end" https_notify \
  '      stream.close_write
      stream.abort' '      stream.abort'
# The cap and the request deadline broken, the slow clients run against
# the copy: each must fail at the case that names it.
guard_breaks() { # guard_breaks <label> <name> <old> <new> <case> <phrase>
  local label="$1" name="$2" old="$3" new="$4" case_name="$5" phrase="$6"
  if [ "${guard_ready:-0}" -ne 1 ]; then
    echo "  $label: skipped with the slow clients' section"
  elif ! h2_patched "$name" "$old" "$new"; then
    echo "  $label: the broken copy did not build"
    sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /'
    status=1
  elif guarded "$WORK/$name.bin" "$WORK/$name.out" "$case_name"; then
    echo "  $label: the slow clients were cut off by a broken server"
    status=1
  elif grep -qF "FAIL $phrase:" "$WORK/$name.out"; then
    echo "  $label: caught: $(grep -m1 'FAIL' "$WORK/$name.out" | sed 's/^FAIL //' | cut -c1-120)"
  else
    echo "  $label: failed, but not at \"$phrase\": $(sed -n '1p' "$WORK/$name.out")"
    status=1
  fi
}
guard_breaks "a request's body bounded per read alone" guard_body \
  '        conn.deadline_at(whole, "read a request") if whole > 0_i64
        reader = body_reader(conn, head)' '        reader = body_reader(conn, head)' \
  body "a body a byte at a time"
guard_breaks "an HTTP/2 body bounded per read alone" guard_h2 \
  '      conn.deadline_at(whole, "read a request") if whole > 0_i64
      unless stream_bodies' '      unless stream_bodies' \
  h2 "an HTTP/2 body a frame of a byte at a time"
guard_breaks "connections served without a cap" guard_cap \
  'slots = max_connections > 0 ? Channel(Int32).new(max_connections) : nil' 'slots = nil.as(Channel(Int32)?)' \
  cap "cap"
guard_breaks "a connection's place never given back" guard_leak \
  "      # The connection's place, given back however it ended.
      slots.take_now if slots
" "" \
  cap "cap"
guard_breaks "a head held to the whole request's deadline alone" guard_head \
  '    head = timeout_ms > 0 ? started + timeout_ms.to_i64 * 1000000_i64 : 0_i64' '    head = 0_i64' \
  head "a head a byte at a time"
# The client's certificate, lost on the way to the handler or the server:
# the mTLS checks must fail.
mtls_breaks() { # mtls_breaks <label> <name> <old> <new>
  local label="$1" name="$2" old="$3" new="$4"
  if [ "$https_ready" -ne 1 ] || [ -z "$PY" ]; then
    echo "  $label: skipped, no HTTPS server to break"
  elif ! h2_patched "$name" "$old" "$new"; then
    echo "  $label: the broken copy did not build"
    sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /'
    status=1
  elif mtls_checks "$WORK/$name.bin" >"$WORK/$name.out" 2>&1; then
    echo "  $label: the client-certificate checks passed on a broken copy"
    status=1
  else
    echo "  $label: caught: $(grep -m1 'FAIL' "$WORK/$name.out" | sed 's/^ *FAIL: //' | cut -c1-120)"
  fi
}
mtls_breaks "an HTTP/1.1 request without the client's certificate" mtls_h1 \
  '        req.peer_certificates = peer
        response = handler.call(req)' '        response = handler.call(req)'
mtls_breaks "an HTTP/2 request without the client's certificate" mtls_h2 \
  '      req.peer_certificates = peer
      response = handler.call(req)' '      response = handler.call(req)'
mtls_breaks "an upgrade's handshake presenting no certificate" mtls_upgrade \
  '            offered.identity = under.identity
' ''
# The client through a proxy, broken in a copy: the round against the
# Python proxy and the iyi server above must fail.
proxy_breaks() { # proxy_breaks <label> <name> <old> <new>
  local label="$1" name="$2" old="$3" new="$4"
  if [ "$proxy_ready" -ne 1 ]; then
    echo "  $label: skipped, no proxy round to break"
    return
  fi
  rm -rf "$WORK/$name"
  mkdir -p "$WORK/$name/std"
  OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/http.iyi" "$WORK/$name/std/http.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique: " + old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, os.environ["NEW"], 1))
PY
  if [ $? -ne 0 ] || ! IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" timeout 300 "$IYI" build -o "$WORK/$name.bin" "$WORK/proxy_client.iyi" >"$WORK/$name.log" 2>&1; then
    echo "  $label: the broken copy did not build"
    sed -n '1,6p' "$WORK/$name.log" | sed 's/^/    /'
    status=1
  # Twenty seconds for a broken copy, which fails where it fails: without
  # a tunnel the client waited out all 120 (123 s of the gate).
  elif PROXY_ROUND_SECONDS=20 proxy_round "$WORK/$name.bin" http/1.1 HTTP/1.1 >"$WORK/$name.out" 2>&1; then
    echo "  $label: the proxy round passed on a broken client"
    status=1
  else
    echo "  $label: caught: $(sed -n '1p' "$WORK/$name.out" | sed 's/^ *//' | cut -c1-120)"
  fi
}
proxy_breaks "the caller's Proxy-Authorization written inside the tunnel" proxy_inside \
  'tunnel_credential = via.authorization || header_in(headers, "Proxy-Authorization")
        sent = without(sent, ["Proxy-Authorization"])' \
  'tunnel_credential = via.authorization || header_in(headers, "Proxy-Authorization")'
proxy_breaks "a CONNECT without its credential" proxy_connect_bare \
  '      ask << "Proxy-Authorization: " << credential << "\r\n"' '      nil'
proxy_breaks "https:// through a proxy without a tunnel" proxy_no_tunnel \
  'if tunneled && (via = route)' 'if false && (via = route)'
proxy_breaks "a tunnel kept under the proxy alone" proxy_tunnel_key \
  'key = via.key + " " + key' 'key = via.key'
proxy_breaks "an upgrade sent past its proxy" proxy_upgrade_direct \
  'exchange = exchange("GET", url, sent, "", nil, false, "Upgrade", nil, timeout_ms, route)' \
  'exchange = exchange("GET", url, sent, "", nil, false, "Upgrade", nil, timeout_ms, nil)'
proxy_breaks "a ws:// handshake sent to the proxy in absolute form" proxy_upgrade_absolute \
  'tunneled = !route.nil? && (secure || !upgrade.nil?)' 'tunneled = !route.nil? && secure'

# The lingering close's copies, started above beside what came after.
close_breaks_report
echo
if [ "$status" -eq 0 ]; then
  echo "the std/http exercise holds"
else
  echo "the std/http exercise did not hold"
fi
exit $status
