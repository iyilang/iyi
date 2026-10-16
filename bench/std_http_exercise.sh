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
for phrase in "== request" "== response" "== messages at the edges" "== over a socket" "== the server, from a raw socket" "== a burst of connections" "== bodies as streams" "== content codings" "== redirects" "== forms" "== kept connections" "== timeouts" "== upgrades"; do
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
# and the byte slices it reads are iyi over the prelude, and std/x509 -
# the certificate a request carries - is std/tls's own already.
imports=$(grep -oE '^import std/[a-z_0-9]+' "$REPO/src/std/http.iyi" | sed 's/^import //' | sort | tr '\n' ' ')
if [ "$imports" = "std/compress std/digest std/hpack std/mime std/slice std/socket std/time std/tls std/uri std/x509 " ]; then
  echo "  std/socket, std/time and std/tls (std/x509 its own), and std/compress, std/digest, std/hpack, std/mime, std/slice and std/uri, which reach nothing"
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
echo "== https:// against Python's own TLS server"
# Python's ssl module is OpenSSL's TLS, held to 1.3 here, serving under a
# certificate for localhost from a root made for the run: gzip undone over
# TLS, a 303 followed on the same scheme, a kept connection used twice, a
# host the certificate does not name refused, and an upgrade over https://
# reaching the server, whose 404 it names.
# Then the same client against a copy of the module that sends https://
# in the clear, which must not answer the same.
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
PY
  cat > "$WORK/tls_client.iyi" <<'IYI'
module main

import std/http::{HTTP, HTTPClient, HTTPError}
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
client.close
other = HTTP.get("https://127.0.0.1:#{Program.args[0]}/landed")
puts "other #{other.is_a?(HTTPError) ? other.message : other.inspect}"
up = HTTP.upgrade(base + "/", "websocket")
puts "upgrade #{up.is_a?(HTTPError) ? up.message : up.inspect}"
HTTP.get(base + "/stop")
IYI
  serve_tls() {
    "$PY" - "$WORK/tls" > "$WORK/tls_server.out" 2>&1 <<'PY' &
import gzip, ssl, sys
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
        if self.path == "/gzip":
            self.answer(200, gzip.compress(text), [("Content-Encoding", "gzip")])
        elif self.path == "/landed":
            self.answer(200, self.command.encode())
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
s = HTTPServer(("127.0.0.1", 0), Handler)
s.socket = context.wrap_socket(s.socket, server_side=True)
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
    said=$(timeout 60 "$WORK/tls_client" "$tport" "$WORK/tls/root.pem" 2>&1)
    kill "$tls_pid" 2>/dev/null
    wait "$tls_pid" 2>/dev/null
    expected="gzip true true
hop 200 GET https://localhost:$tport/landed
kept 1 made, 1 reused
other HTTP: tls: the server's certificate is not trusted: x509: CN=localhost is not valid for 127.0.0.1: it names localhost (bad_certificate)
upgrade HTTP: the server answered 404 Not Found to an upgrade to websocket, not 101 Switching Protocols"
    if [ "$said" = "$expected" ]; then
      echo "  gzip over TLS 1.3, a 303 on https://, a kept connection used twice, a host the certificate does not name, an upgrade over https:// answered 404"
    else
      echo "  the client and Python's TLS server disagree:"
      printf '%s\n' "$said" | sed 's/^/    got:  /'
      printf '%s\n' "$expected" | sed 's/^/    want: /'
      status=1
    fi
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
      clear=$(timeout 60 "$WORK/tls_clear" "$tport" "$WORK/tls/root.pem" 2>&1)
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
import socket, struct, sys
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
    sock = run(sent, settings)
    for kind, flags, stream, payload in frames_of(sock):
        if kind == 7:
            return int.from_bytes(payload[4:8], "big")
    return None

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
    got="$(timeout -k 5 60 "$H2BIN" tls-get "$base" "$WORK/tls/root.pem" "$alpn" 2>&1 | tr '\n' '|')"
    want="echo 200 GET /echo x=1 $version host=localhost:$tport length=0 fnv=cbf29ce484222325 x=iyi|big 200 1000000 true|post 200 true|connections 1|"
    [ "$got" = "$want" ] || https_fail "the iyi client offering $alpn: $got"
  done
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
mutate "a server whose tasks share the accept loop's variable" '          spawn_handler(g, client, handler, listener, idle, stream_bodies, compress, timeout_ms, tls)' '          accepted = client
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
mutate "a client that never keeps a connection" 'conn = keeping.take(key) unless upgrade' ''
mutate "a client that keeps a connection the answer closed" 'keep = got.starts_with?("HTTP/1.1 ") && !reader.to_close? && status != 101 && (said.nil? || !has_token?(said, "close"))' 'keep = true'
mutate "a client that holds a connection for whatever was left unread" 'client && @keep && !@conn.ended? && @reader.drain(65536_i64)' 'client && @keep && !@conn.ended? && @reader.drain(9223372036854775807_i64)'
mutate "a GET not sent again when its kept connection was closed" 'retry = body.is_a?(String) && (head ||' 'retry = false && (head ||'
mutate "a POST sent again when its kept connection was closed" 'retry = body.is_a?(String) && (head || same_name?(method, "GET") || same_name?(method, "PUT") || same_name?(method, "DELETE") || same_name?(method, "OPTIONS") || same_name?(method, "TRACE"))' 'retry = body.is_a?(String)'
mutate "a head given as long as each read is short" '      conn.deadline_in(timeout_ms)
' ''
mutate "an upgraded connection held to the server's timeout" '      conn.unlimited
' ''
mutate "a client that waits for an answer as long as it takes" '        conn.gap = timeout_ms if timeout_ms > 0
        if speaks_h2' '        if speaks_h2'
mutate "a request that does not name its client" '    remote = client.remote_address' '    remote = nil.as(String?)'
mutate "a boundary that falls across reads missed" 'safe = @held.bytesize - (@delimiter.bytesize - 1)' 'safe = @held.bytesize'

# HTTP/2, each mechanism taken out of a copy that compiles: the iyi-to-iyi
# exercise stops at the check that names it, or the raw frames find the
# answer RFC 9113 asks for missing.
h2_patched() { # h2_patched <name> <old> <new>: a broken http2_exercise in $WORK/<name>.bin
  rm -rf "$WORK/$1"
  mkdir -p "$WORK/$1/std"
  OLD="$2" NEW="$3" "$PY" - "$REPO/src/std/http.iyi" "$WORK/$1/std/http.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique: " + old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, os.environ["NEW"], 1))
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
    timeout -k 5 300 "$PY" "$WORK/h2frames.py" "$H2PORT" >"$WORK/$name.out" 2>&1
    h2_stop
    H2BIN="$good"
    if grep -qF -- "FAIL: $case_name:" "$WORK/$name.out"; then
      echo "  $label: caught by the frames for \"$case_name\""
    else
      echo "  $label: the frames for \"$case_name\" did not fail on a broken server"
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
  elif https_checks "$WORK/$name.bin" "$WORK/tls/ed.pem" "$WORK/tls/ed.key" ed >"$WORK/$name.out" 2>&1; then
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
  '    secured.close
  end' '  end'
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
        return unless answered?' '        return unless answered?'
mtls_breaks "an HTTP/2 request without the client's certificate" mtls_h2 \
  '      req.peer_certificates = peer
      answered = h2.answer' '      answered = h2.answer'
mtls_breaks "an upgrade's handshake presenting no certificate" mtls_upgrade \
  '            offered.identity = tls_config.identity
' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/http exercise holds"
else
  echo "the std/http exercise did not hold"
fi
exit $status
