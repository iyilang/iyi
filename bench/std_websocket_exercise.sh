#!/usr/bin/env bash
# Exercises `std/websocket`.
#
#     bash bench/std_websocket_exercise.sh
#
# The exercise runs plain and --release; then what a program is refused,
# as the panics it ends with; then the module against peers it did not
# write - a WebSocket client and server written here in Python over raw
# sockets, from RFC 6455 rather than from the module, the same two again
# speaking RFC 7692's permessage-deflate over Python's zlib (raw DEFLATE,
# `wbits=-15`), with the window carried over and not, and Node's
# `WebSocket` client (undici's, which offers permessage-deflate) where
# Node is installed - in the clear, then the same peers under TLS
# (`wss://`, a P-256 certificate) with a copy that hands the bare socket
# over refused; then the exercise built from artifacts and typechecked
# for the other platforms, the docs and the format; then the proofs that
# the exercise fails when the module is broken.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/darwin_frames.sh"
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

# The peers and the patches are python, and a machine can answer
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_websocket_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  timeout -k 5 300 "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  # The refusals the exercise provokes on purpose print their panics as
  # they are caught; the section that checks them says which they were.
  grep -v -E '^iyi: panic: (WebSocket|Inflater): ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/websocket exercise, plain build"
build_and_run "plain" ws-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/ws-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every websocket section reported"
for phrase in "== handshake" "== frames a server reads" "== frames a server writes" \
              "== frames a client writes" "== what a server refuses" "== what a client refuses" \
              "== what a client's handshake refuses" "== permessage-deflate: the handshake" \
              "== permessage-deflate: RFC 7692's examples" "== permessage-deflate: what is refused" "== close handshake" \
              "== what a program is refused" "== client and server over std/http" "== through a proxy"; do
  if ! grep -q "$phrase" "$WORK/ws-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" ws-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/ws-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a program is refused"
# Each is a panic with its sentence, before anything is written: the
# program did something wrong, not the peer.
refuses() { # refuses <label> <name> <phrase> <statement>
  local label="$1" name="$2" phrase="$3" statement="$4"
  printf 'module main\n\nimport std/websocket::{WebSocket}\nimport std/socket::{IyiSocket}\n\nl = IyiSocket.listen("127.0.0.1", 0)\nc = IyiSocket.connect("127.0.0.1", l.local_port).or_panic\nws = WebSocket.new(l.accept.or_panic, "", false)\n%s\nputs "ACCEPTED"\n' \
    "$statement" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  timeout 60 "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ] || grep -q ACCEPTED "$WORK/$name.out"; then
    echo "  $label: it went on instead of refusing"
    status=1
    return
  fi
  if ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -oF "$phrase" "$WORK/$name.out")"
}
refuses "text that is not UTF-8" text_bytes "WebSocket: send's text is not UTF-8; send_binary sends bytes" \
  'ws.send(String.new(1) { |p| p[0] = 255_u8 })'
refuses "a ping past 125 bytes" ping_long "WebSocket: a ping carries at most 125 bytes, not 200" \
  'ws.ping(String.new(200) { |p| 200.times { |i| p[i] = 97_u8 } })'
refuses "close 1006" close_1006 "WebSocket: close code 1006 is not one an endpoint sends: 1000-1003, 1007-1014 or 3000-4999" \
  'ws.close(1006)'
refuses "close 5000" close_5000 "WebSocket: close code 5000 is not one an endpoint sends" \
  'ws.close(5000)'
refuses "a close reason past 123 bytes" reason_long "WebSocket: a close reason is at most 123 bytes, not 124" \
  'ws.close(1000, String.new(124) { |p| 124.times { |i| p[i] = 97_u8 } })'
refuses "a caller's Upgrade" own_upgrade "WebSocket: Upgrade is the handshake's own header" \
  'WebSocket.connect("ws://127.0.0.1:#{l.local_port}/", {"Upgrade" => "h2c"})'
refuses "a negative limit" limit_negative "WebSocket: max_message is a count of bytes, not -1" \
  'WebSocket.new(c, "", true, nil, -1)'
if grep -nE '^\s*(lib|fun) |File\.|Dir\.|ENV' "$REPO/src/std/websocket.iyi"; then
  echo "  the module reaches outside itself"
  status=1
else
  echo "  no file, environment or C binding in the module"
fi

# The first line a program printed, which is its port, once it has printed
# it; a program that exits ends the wait at once. Sixty seconds, as
# std_http_exercise.sh waits, for a Defender that holds a new exe's first
# launch.
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
echo "== a Python client against the server"
# The Python peers are RFC 6455 written out by hand over a socket: the
# standard library has no WebSocket, and the gate must not need the
# network to install one.
"$WORK/ws-plain" serve > "$WORK/serve.out" 2>&1 &
serve_pid=$!
port=$(await_port "$WORK/serve.out" "$serve_pid")
if [ -z "$port" ]; then
  echo "  the server printed no port"
  sed -n '1,5p' "$WORK/serve.out" | sed 's/^/    /'
  status=1
elif [ -z "$PY" ]; then
  echo "  skipped: no working python3, so no Python client was run against the server"
elif ! cat >"$WORK/ws-client.py" <<'PY'
import base64, hashlib, os, socket, ssl, struct, sys
port = int(os.environ["PORT"])
# Under TLS (wss://) when TLS_ROOTS names the root to trust: the socket
# wrapped, the name checked as localhost.
roots = os.environ.get("TLS_ROOTS")
host = os.environ.get("HOST", "127.0.0.1")
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
bad = 0
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what); bad += 1

def encode(op, payload, fin=True, mask=True):
    n = len(payload)
    b0 = (0x80 if fin else 0) | op
    m = 0x80 if mask else 0
    if n < 126: head = struct.pack("!BB", b0, m | n)
    elif n < 65536: head = struct.pack("!BBH", b0, m | 126, n)
    else: head = struct.pack("!BBQ", b0, m | 127, n)
    if not mask:
        return head + payload
    key = os.urandom(4)
    stream = (key * (n // 4 + 1))[:n]
    masked = (int.from_bytes(payload, "big") ^ int.from_bytes(stream, "big")).to_bytes(n, "big") if n else b""
    return head + key + masked

class Peer:
    def __init__(self, extra=b"", version=b"13", protocols=b"superchat, chat"):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        if roots:
            self.s = ssl.create_default_context(cafile=roots).wrap_socket(self.s, server_hostname=host)
        self.key = base64.b64encode(os.urandom(16))
        req = (b"GET /chat HTTP/1.1\r\nHost: " + host.encode() + b":" + str(port).encode() +
               b"\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: " + self.key +
               b"\r\nSec-WebSocket-Version: " + version + b"\r\n")
        if protocols:
            req += b"Sec-WebSocket-Protocol: " + protocols + b"\r\n"
        self.s.sendall(req + b"\r\n" + extra)
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                break
            self.buf += chunk
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        self.status = lines[0]
        self.headers = {}
        for line in lines[1:]:
            k, _, v = line.partition(b":")
            self.headers[k.strip().lower()] = v.strip()
    def accepted(self):
        want = base64.b64encode(hashlib.sha1(self.key + GUID).digest())
        return self.status == b"HTTP/1.1 101 Switching Protocols" and self.headers.get(b"sec-websocket-accept") == want
    def send(self, op, payload, fin=True, mask=True):
        self.s.sendall(encode(op, payload, fin, mask))
    def read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError(f"{n} bytes wanted, {len(self.buf)} came")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out
    def frame(self):
        b0, b1 = self.read(2)
        n = b1 & 127
        if n == 126: n = struct.unpack("!H", self.read(2))[0]
        elif n == 127: n = struct.unpack("!Q", self.read(8))[0]
        if b1 & 0x80:
            raise ValueError("a server's frame is masked")
        return b0, b1, self.read(n)
    def ended(self):
        if self.buf:
            return False
        try:
            return self.s.recv(1) == b""
        except (ConnectionResetError, ssl.SSLEOFError):
            return True

p = Peer()
check(p.accepted(), f"the handshake: {p.status!r} {p.headers!r}")
check(p.headers.get(b"sec-websocket-protocol") == b"chat", "the server's first protocol among the client's")
p.send(1, b"hello")
check(p.frame() == (0x81, 5, b"hello"), "an echoed text")
p.send(1, b"fr", fin=False); p.send(9, b"p"); p.send(0, b"ag")
check(p.frame() == (0x8a, 1, b"p"), "a pong between fragments")
check(p.frame() == (0x81, 4, b"frag"), "the fragments echoed whole")
big = os.urandom(200000)
p.send(2, big)
b0, b1, data = p.frame()
check(b0 == 0x82 and b1 == 127 and data == big, "200000 bytes, a 64-bit length")
p.send(2, b"x" * 300)
check(p.frame() == (0x82, 126, b"x" * 300), "300 bytes, a 16-bit length")
text = "é ✓ 😀".encode()
p.send(1, text[:1], fin=False); p.send(0, text[1:5], fin=False); p.send(0, text[5:])
check(p.frame() == (0x81, len(text), text), "characters split between fragments")
p.send(8, struct.pack("!H", 1000) + b"bye")
b0, b1, data = p.frame()
check(b0 == 0x88 and data[:2] == struct.pack("!H", 1000), f"the close echoed: {data!r}")
check(p.ended(), "the server ends the connection after the close handshake")

p = Peer(extra=encode(1, b"with the handshake"))
check(p.accepted() and p.frame() == (0x81, 18, b"with the handshake"), "a frame in the handshake's write")
p.send(8, b"")
check(p.frame() == (0x88, 0, b"") and p.ended(), "an empty close echoed empty")

rsv1 = encode(1, b"x")
for wire, code, what in [(encode(1, b"\xc0\x80"), 1007, "an overlong NUL"),
                         (encode(1, b"\xed\xa0\x80"), 1007, "a surrogate"),
                         (encode(1, b"bare", mask=False), 1002, "an unmasked frame"),
                         (bytes([rsv1[0] | 0x40]) + rsv1[1:], 1002, "RSV1"),
                         (encode(9, b"x" * 126), 1002, "a long ping"),
                         (encode(0, b"x"), 1002, "a continuation alone"),
                         (encode(8, struct.pack("!H", 1005)), 1002, "close 1005"),
                         (struct.pack("!BBQ", 0x82, 0xFF, 1 << 40) + os.urandom(4), 1009, "2^40 declared bytes")]:
    p = Peer()
    p.s.sendall(wire)
    b0, b1, data = p.frame()
    check(b0 == 0x88 and data[:2] == struct.pack("!H", code), f"{what}: {data!r}")
    check(p.ended(), f"{what}: the connection ends")

p = Peer(version=b"8", protocols=None)
check(p.status.startswith(b"HTTP/1.1 426 ") and p.headers.get(b"sec-websocket-version") == b"13", f"version 8: {p.status!r}")
print("  the handshake, echoes, fragments around a ping, 64 and 16-bit lengths, the close; 1007, 1002 and 1009 faults; 426")
sys.exit(1 if bad else 0)
PY
then
  echo "  the Python client could not be written"
  status=1
elif ! PORT="$port" timeout 120 "$PY" "$WORK/ws-client.py"; then
  echo "  Python's client and the server disagree"
  status=1
fi

echo
echo "== Node's WebSocket client against the server"
# undici offers `permessage-deflate; client_max_window_bits`, takes the
# server's compressed messages and sends its own uncompressed: what it
# reads here is the server's compressor, the window carried over.
if [ -z "$port" ]; then
  echo "  skipped: no server"
elif ! command -v node >/dev/null 2>&1 || [ "$(node -e 'process.stdout.write(typeof WebSocket)' 2>/dev/null)" != "function" ]; then
  echo "  skipped: no node with a WebSocket client (Node 22 and later have one)"
elif ! cat >"$WORK/ws-node.js" <<'JS'
const port = process.env.PORT;
// wss://localhost under TLS, its root given by NODE_EXTRA_CA_CERTS.
const ws = new WebSocket(process.env.WS_URL || `ws://127.0.0.1:${port}/chat`, ["superchat", "chat"]);
ws.binaryType = "arraybuffer";
const sent = new Uint8Array(100000).map((_, i) => (i * 7 + 3) & 255);
const got = [];
let bad = 0;
const check = (cond, what) => { if (!cond) { console.log("  FAIL:", what); bad++; } };
const again = Array.from({ length: 50 }, (_, i) => `again and again, message ${i} of 50`);
const long = "a megabyte of words, compressed by the server; ".repeat(22310);
ws.onopen = () => { ws.send("hello from node"); ws.send(sent); ws.send("ünïcödé ✓"); again.forEach((t) => ws.send(t)); ws.send(long); };
ws.onmessage = (e) => { got.push(e.data); if (got.length === 54) ws.close(4321, "node done"); };
ws.onerror = (e) => { console.log("  error:", e.message); };
ws.onclose = (e) => {
  check(ws.protocol === "chat", `protocol ${ws.protocol}`);
  check(ws.extensions === "permessage-deflate", `extensions ${JSON.stringify(ws.extensions)}`);
  check(got[0] === "hello from node", "the text echoed");
  const back = got[1] instanceof ArrayBuffer ? new Uint8Array(got[1]) : null;
  check(back && back.length === sent.length && back.every((b, i) => b === sent[i]), "100000 bytes echoed");
  check(got[2] === "ünïcödé ✓", "UTF-8 echoed");
  check(again.every((t, i) => got[3 + i] === t), "50 texts echoed in order, compressed in one window");
  check(got[53] === long, `${long.length} bytes of text echoed`);
  check(e.code === 4321 && e.wasClean, `the close: ${e.code} clean=${e.wasClean}`);
  if (!bad) console.log("  permessage-deflate agreed; a protocol, a text, 100000 bytes, UTF-8, 50 texts and a megabyte echoed compressed; a clean close 4321");
  process.exit(bad ? 1 : 0);
};
setTimeout(() => { console.log("  timed out"); process.exit(1); }, 30000);
JS
then
  echo "  the Node client could not be written"
  status=1
elif ! PORT="$port" timeout 60 node "$WORK/ws-node.js"; then
  echo "  Node's client and the server disagree"
  status=1
fi

echo
echo "== a Python RFC 7692 client against the server"
# permessage-deflate over zlib's raw DEFLATE, from RFC 7692 rather than
# from the module: offers accepted and declined, messages compressed both
# ways with the window carried over and with none, a window of 2^9 held
# to, and what the server refuses.
cat >"$WORK/ws-deflate-client.py" <<'PY'
import base64, hashlib, os, random, socket, ssl, struct, sys, time, zlib
port = int(os.environ["PORT"])
# Under TLS (wss://) when TLS_ROOTS names the root to trust.
roots = os.environ.get("TLS_ROOTS")
host = os.environ.get("HOST", "127.0.0.1")
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TAIL = b"\x00\x00\xff\xff"
bad = 0
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what, flush=True); bad += 1

def encode(op, payload, fin=True, rsv=0):
    n = len(payload)
    b0 = (0x80 if fin else 0) | rsv | op
    if n < 126: head = struct.pack("!BB", b0, 0x80 | n)
    elif n < 65536: head = struct.pack("!BBH", b0, 0x80 | 126, n)
    else: head = struct.pack("!BBQ", b0, 0x80 | 127, n)
    key = os.urandom(4)
    stream = (key * (n // 4 + 1))[:n]
    masked = (int.from_bytes(payload, "big") ^ int.from_bytes(stream, "big")).to_bytes(n, "big") if n else b""
    return head + key + masked

# zlib's sync flush, its last four bytes left off (§7.2.1).
def deflate(c, data):
    out = c.compress(data) + c.flush(zlib.Z_SYNC_FLUSH)
    assert out.endswith(TAIL), out[-8:]
    return out[:-4]

def compressor(wbits=15):
    return zlib.compressobj(6, zlib.DEFLATED, -wbits)

class Peer:
    def __init__(self, offer):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=20)
        if roots:
            self.s = ssl.create_default_context(cafile=roots).wrap_socket(self.s, server_hostname=host)
        key = base64.b64encode(os.urandom(16))
        req = (b"GET /chat HTTP/1.1\r\nHost: " + host.encode() + b"\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               b"Sec-WebSocket-Key: " + key + b"\r\nSec-WebSocket-Version: 13\r\n")
        if offer is not None:
            req += b"Sec-WebSocket-Extensions: " + offer.encode() + b"\r\n"
        self.s.sendall(req + b"\r\n")
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                break
            self.buf += chunk
        head, _, self.buf = self.buf.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        self.status = lines[0]
        self.headers = {}
        for line in lines[1:]:
            k, _, v = line.partition(b":")
            self.headers[k.strip().lower()] = v.strip().decode()
        self.accepted = self.status == b"HTTP/1.1 101 Switching Protocols" and \
            self.headers.get(b"sec-websocket-accept") == base64.b64encode(hashlib.sha1(key + GUID).digest()).decode()
        self.extension = self.headers.get(b"sec-websocket-extensions")
    def send(self, op, payload, fin=True, rsv=0):
        self.s.sendall(encode(op, payload, fin, rsv))
    def read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise EOFError(f"{n} bytes wanted, {len(self.buf)} came")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out
    def frame(self):
        b0, b1 = self.read(2)
        n = b1 & 127
        if n == 126: n = struct.unpack("!H", self.read(2))[0]
        elif n == 127: n = struct.unpack("!Q", self.read(8))[0]
        return b0, self.read(n)
    def close(self):
        self.send(8, struct.pack("!H", 1000))
        b0, data = self.frame()
        check(b0 == 0x88 and data[:2] == struct.pack("!H", 1000), f"the close echoed: {b0:#x} {data!r}")
        self.s.close()
    def ended(self):
        try:
            return not self.buf and self.s.recv(1) == b""
        except (ConnectionResetError, ssl.SSLEOFError):
            return True
    def fault(self, wire, code, what):
        self.s.sendall(wire)
        b0, data = self.frame()
        check(b0 == 0x88 and data[:2] == struct.pack("!H", code), f"{what}: {b0:#x} {data!r}")
        check(self.ended(), f"{what}: the connection ends")

rng = random.Random(7692)
noise = lambda n: bytes(rng.getrandbits(8) for _ in range(n))

# The window carried over both ways: one compressor and one decompressor
# for the connection, at each end.
p = Peer("permessage-deflate; client_max_window_bits")
check(p.accepted and p.extension == "permessage-deflate", f"a browser's offer accepted: {p.status!r} {p.extension!r}")
out, back = compressor(), zlib.decompressobj(wbits=-15)
sizes = []
messages = [(1, "Hello".encode()), (1, "Hello".encode()), (2, bytes((i * 7 + 3) & 255 for i in range(100000))),
            (1, "é ✓ 😀 and more text, and more text".encode()), (1, b""), (2, noise(70000))]
for op, data in messages:
    p.send(op, deflate(out, data), rsv=0x40)
    b0, payload = p.frame()
    check(b0 == 0xc0 | op, f"the echo is compressed: {b0:#x}")
    check(back.decompress(payload + TAIL) == data, f"{len(data)} bytes inflate to what was sent")
    sizes.append(len(payload))
check(sizes[1] < sizes[0], f"the server's second Hello refers back into its first: {sizes[:2]}")
check(sizes[4] == 1, f"the empty message is one byte: {sizes[4]}")
# An uncompressed message between compressed ones, and a compressed
# message in three fragments, RSV1 on the first alone.
p.send(1, b"as it is")
b0, payload = p.frame()
check(b0 == 0xc1 and back.decompress(payload + TAIL) == b"as it is", "an uncompressed message, echoed compressed")
text = ("fragmented and compressed " * 200).encode()
z = deflate(out, text)
third = len(z) // 3
p.send(1, z[:third], fin=False, rsv=0x40); p.send(9, b"ping"); p.send(0, z[third:2 * third], fin=False); p.send(0, z[2 * third:])
check(p.frame() == (0x8a, b"ping"), "the pong between fragments, not compressed")
b0, payload = p.frame()
check(b0 == 0xc1 and back.decompress(payload + TAIL) == text, "a compressed message in three fragments")
# zlib's way to §7.2.3.4: a final block, then the empty stored block's
# header byte.
c = zlib.compressobj(6, zlib.DEFLATED, -15)
final = c.compress(b"Hello") + c.flush(zlib.Z_FINISH) + b"\x00"
p.send(1, final, rsv=0x40)
b0, payload = p.frame()
check(b0 == 0xc1 and back.decompress(payload + TAIL) == b"Hello", "a message ending in a final block")
p.close()

# No window carried over either way: a fresh compressor for each message
# here, and each echo inflated with a fresh decompressor, which fails on
# a reference into a message before.
p = Peer("permessage-deflate; server_no_context_takeover; client_no_context_takeover")
check(p.extension == "permessage-deflate; server_no_context_takeover; client_no_context_takeover", f"no context takeover agreed: {p.extension!r}")
echoes = []
for data in [b"Hello", b"Hello", noise(3000) * 3, b"Hello"]:
    p.send(1 if data == b"Hello" else 2, deflate(compressor(), data), rsv=0x40)
    b0, payload = p.frame()
    try:
        got = zlib.decompressobj(wbits=-15).decompress(payload + TAIL)
    except zlib.error as e:
        got = repr(e).encode()
    check(got == data, f"an echo inflated from nothing: {got[:60]!r}")
    echoes.append(payload)
check(echoes[0] == echoes[1] == echoes[3] == bytes.fromhex("f248cdc9c90700"), f"each Hello is §7.2.3.1's bytes: {[e.hex() for e in echoes]}")
p.close()

# server_max_window_bits: a random block, then the same block again as a
# second message, is a match 2000 back, past a window of 2^9; inflated
# with zlib's 2^9 window, a reference that far back is refused.
p = Peer("permessage-deflate; server_max_window_bits=9; client_max_window_bits")
check(p.extension == "permessage-deflate; server_max_window_bits=9", f"a window of 2^9 agreed: {p.extension!r}")
out, back = compressor(), zlib.decompressobj(wbits=-9)
block = noise(2000)
for k in range(2):
    p.send(2, deflate(out, block), rsv=0x40)
    b0, payload = p.frame()
    try:
        got = back.decompress(payload + TAIL)
    except zlib.error as e:
        got = repr(e).encode()
    check(got == block, f"message {k + 1} inflates in a window of 2^9: {got[:60]!r}")
    check(len(payload) > 1900, f"and does not refer 2000 back: {len(payload)} bytes")
p.close()
# The same block at the default window: the second is a reference back.
p = Peer("permessage-deflate")
out, back = compressor(), zlib.decompressobj(wbits=-15)
lengths = []
for k in range(2):
    p.send(2, deflate(out, block), rsv=0x40)
    b0, payload = p.frame()
    check(back.decompress(payload + TAIL) == block, "the block at a window of 2^15")
    lengths.append(len(payload))
check(lengths[1] < 100, f"the second refers back 2000: {lengths}")
p.close()

# Offers declined, and the one after them taken.
p = Peer("permessage-deflate; server_max_window_bits=16, permessage-deflate; foo, permessage-deflate; client_no_context_takeover")
check(p.extension == "permessage-deflate; client_no_context_takeover", f"two offers declined, the third taken: {p.extension!r}")
p.close()
p = Peer("permessage-deflate; server_max_window_bits=08")
check(p.accepted and p.extension is None, f"a window of 08 is declined: {p.extension!r}")
p.fault(encode(1, deflate(compressor(), b"Hello"), rsv=0x40), 1002, "RSV1 where nothing was agreed")

# What the server refuses once it is agreed.
for wire, code, what in [(encode(9, b"x", rsv=0x40), 1002, "RSV1 on a ping"),
                         (encode(1, b"\xf2\x48", fin=False, rsv=0x40) + encode(0, b"\xcd\xc9\xc9\x07\x00", rsv=0x40), 1002, "RSV1 on a continuation"),
                         (encode(2, b"\xff", rsv=0x40), 1007, "bytes that are not DEFLATE"),
                         (encode(1, deflate(compressor(), b"\xc0\x80"), rsv=0x40), 1007, "text that inflates to an overlong NUL")]:
    p = Peer("permessage-deflate")
    p.fault(wire, code, what)
# A deflate bomb: 256 MiB of zeros, past the server's 16 MiB as it
# inflates.
c = compressor()
bomb = b"".join(c.compress(bytes(1 << 20)) for _ in range(256)) + c.flush(zlib.Z_SYNC_FLUSH)
bomb = bomb[:-4]
p = Peer("permessage-deflate")
start = time.monotonic()
p.fault(encode(2, bomb, rsv=0x40), 1009, f"a deflate bomb of {len(bomb)} bytes")
took = time.monotonic() - start
check(took < 10, f"the bomb refused in {took:.2f} s")
if not bad:
    print(f"  offers accepted and declined; messages both ways with the window carried over and not, at windows of 2^15 and 2^9;"
          f" fragments, a final block, RSV1 refused where it does not go, 256 MiB of zeros in {len(bomb)} bytes refused 1009", flush=True)
sys.exit(1 if bad else 0)
PY
if [ -z "$port" ]; then
  echo "  skipped: no server"
elif [ -z "$PY" ]; then
  echo "  skipped: no working python3"
elif ! PORT="$port" timeout 120 "$PY" "$WORK/ws-deflate-client.py"; then
  echo "  Python's RFC 7692 client and the server disagree"
  status=1
fi

# The server stops at the text "stop": its close is 1001, and `serve`
# returns.
cat >"$WORK/ws-stop.py" <<'PY'
import base64, os, socket, ssl, struct
s = socket.create_connection(("127.0.0.1", int(os.environ["PORT"])), timeout=10)
if os.environ.get("TLS_ROOTS"):
    s = ssl.create_default_context(cafile=os.environ["TLS_ROOTS"]).wrap_socket(s, server_hostname="localhost")
s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + base64.b64encode(os.urandom(16)) + b"\r\n\r\n")
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
buf = buf.partition(b"\r\n\r\n")[2]
s.sendall(bytes([0x81, 0x84, 0, 0, 0, 0]) + b"stop")
while len(buf) < 4:
    buf += s.recv(4096)
assert buf[0] == 0x88 and buf[2:4] == struct.pack("!H", 1001), buf
s.sendall(bytes([0x88, 0x82, 0, 0, 0, 0]) + struct.pack("!H", 1001))
s.close()
PY
if [ -n "$port" ] && [ -n "$PY" ]; then
  PORT="$port" timeout 60 "$PY" "$WORK/ws-stop.py" || { echo "  the server did not stop"; status=1; }
fi
if [ -n "$port" ]; then
  waited=0
  while kill -0 "$serve_pid" 2>/dev/null && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! kill -0 "$serve_pid" 2>/dev/null && grep -q "^stopped$" "$WORK/serve.out"; then
    echo "  the server stopped at \"stop\" with a close 1001"
  else
    echo "  the server did not return from serve"
    status=1
  fi
fi
kill "$serve_pid" 2>/dev/null

echo
echo "== the client against a Python server"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3 to serve the client"
else
  cat >"$WORK/ws-server.py" <<'PY'
import base64, hashlib, os, socket, ssl, struct, sys
# Under TLS when TLS_CERT and TLS_KEY name its chain and key; the client
# then names it localhost.
host = os.environ.get("HOST", "127.0.0.1")
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
bad = 0
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what, flush=True); bad += 1
def encode(op, payload, fin=True):
    n = len(payload)
    b0 = (0x80 if fin else 0) | op
    if n < 126: head = struct.pack("!BB", b0, n)
    elif n < 65536: head = struct.pack("!BBH", b0, 126, n)
    else: head = struct.pack("!BBQ", b0, 127, n)
    return head + payload
ls = socket.socket()
ls.bind(("127.0.0.1", 0))
ls.listen(1)
port = ls.getsockname()[1]
print(port, flush=True)
c, _ = ls.accept()
if os.environ.get("TLS_CERT"):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.environ["TLS_CERT"], os.environ["TLS_KEY"])
    c = context.wrap_socket(c, server_side=True)
c.settimeout(20)
buf = b""
while b"\r\n\r\n" not in buf:
    buf += c.recv(65536)
head, _, buf = buf.partition(b"\r\n\r\n")
lines = head.split(b"\r\n")
fields = {}
for line in lines[1:]:
    k, _, v = line.partition(b":")
    fields[k.strip().lower()] = v.strip()
check(lines[0] == b"GET /chat?x=1 HTTP/1.1", f"the request line {lines[0]!r}")
check(fields.get(b"host") == f"{host}:{port}".encode(), "Host")
check(fields.get(b"upgrade", b"").lower() == b"websocket", "Upgrade")
check(b"upgrade" in [t.strip().lower() for t in fields.get(b"connection", b"").split(b",")], "Connection")
check(fields.get(b"sec-websocket-version") == b"13", "Sec-WebSocket-Version")
key = fields.get(b"sec-websocket-key", b"")
check(len(base64.b64decode(key, validate=True)) == 16, "a key of 16 bytes")
check(fields.get(b"sec-websocket-protocol") == b"chat, superchat", "the protocols offered in order")
check(fields.get(b"x-test") == b"1", "the caller's header")
accept = base64.b64encode(hashlib.sha1(key + GUID).digest())
big = bytes((i * 7 + 3) & 255 for i in range(70000))
# The first message rides in the same write as the 101: the client's
# leftover.
c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept +
          b"\r\nSec-WebSocket-Protocol: chat\r\n\r\n" + encode(1, b"hello"))
c.sendall(encode(1, b"fr", fin=False) + encode(9, b"p1") + encode(0, b"ag"))
c.sendall(encode(2, big))
def read(n):
    global buf
    while len(buf) < n:
        chunk = c.recv(65536)
        if not chunk:
            raise EOFError(f"{n} bytes wanted, {len(buf)} came")
        buf += chunk
    out, buf = buf[:n], buf[n:]
    return out
keys = []
def frame():
    b0, b1 = read(2)
    n = b1 & 127
    if n == 126: n = struct.unpack("!H", read(2))[0]
    elif n == 127: n = struct.unpack("!Q", read(8))[0]
    check(b1 & 0x80, "a client's frame is masked")
    key = read(4)
    keys.append(key)
    data = read(n)
    stream = (key * (n // 4 + 1))[:n]
    data = (int.from_bytes(data, "big") ^ int.from_bytes(stream, "big")).to_bytes(n, "big") if n else b""
    return b0, data
check(frame() == (0x81, b"hello"), "the echo of the frame that came with the 101")
check(frame() == (0x8a, b"p1"), "the pong")
check(frame() == (0x81, b"frag"), "the fragments' echo")
check(frame() == (0x82, big), "70000 bytes echoed")
check(frame() == (0x81, "é and ✓".encode()), "UTF-8 from the client")
check(len(set(keys)) == len(keys), "a fresh mask for every frame")
c.sendall(encode(8, struct.pack("!H", 1000) + b"done"))
b0, data = frame()
check(b0 == 0x88 and data == struct.pack("!H", 1000), f"the client's echo of the close: {data!r}")
c.close()
if not bad:
    print("  the request, five masked frames each with its own key, a pong, the close echoed", flush=True)
sys.exit(1 if bad else 0)
PY
  timeout 120 "$PY" "$WORK/ws-server.py" > "$WORK/pyserver.out" 2>&1 &
  py_pid=$!
  pyport=$(await_port "$WORK/pyserver.out" "$py_pid")
  client_said=$(timeout 60 "$WORK/ws-plain" connect "$pyport" 2>&1)
  wait "$py_pid"
  py_status=$?
  sed -n '2,$p' "$WORK/pyserver.out"
  expected='protocol chat
text "hello"
text "frag"
binary 70000 bytes
end
closed 1000 done'
  if [ "$py_status" -ne 0 ]; then
    echo "  Python's server and the client disagree"
    status=1
  elif [ "$client_said" != "$expected" ]; then
    echo "  the client said:"
    printf '%s\n' "$client_said" | sed 's/^/    /'
    status=1
  else
    echo "  the client read the protocol, three messages and the close 1000 \"done\""
  fi
fi

echo
echo "== the client against a Python RFC 7692 server"
# The Python server above again, answering the client's offer three ways
# and compressing with zlib: the window carried over, none carried over
# (a fresh compressor for every message, and a fresh decompressor for
# each of the client's), and the client held to a window of 2^9.
if [ -z "$PY" ]; then
  echo "  skipped: no working python3 to serve the client"
else
  cat >"$WORK/ws-deflate-server.py" <<'PY'
import base64, hashlib, os, random, socket, ssl, struct, sys, zlib
# MODE: "takeover" answers permessage-deflate alone, "fresh" both
# no_context_takeovers, "window" client_max_window_bits=9.
mode = os.environ["MODE"]
answer = {"takeover": "permessage-deflate",
          "fresh": "permessage-deflate; server_no_context_takeover; client_no_context_takeover",
          "window": "permessage-deflate; client_max_window_bits=9"}[mode]
host = os.environ.get("HOST", "127.0.0.1")
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TAIL = b"\x00\x00\xff\xff"
bad = 0
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", mode + ":", what, flush=True); bad += 1
def encode(op, payload, fin=True, rsv=0):
    n = len(payload)
    b0 = (0x80 if fin else 0) | rsv | op
    if n < 126: head = struct.pack("!BB", b0, n)
    elif n < 65536: head = struct.pack("!BBH", b0, 126, n)
    else: head = struct.pack("!BBQ", b0, 127, n)
    return head + payload
out = zlib.compressobj(6, zlib.DEFLATED, -15)
def deflate(data):
    c = zlib.compressobj(6, zlib.DEFLATED, -15) if mode == "fresh" else out
    z = c.compress(data) + c.flush(zlib.Z_SYNC_FLUSH)
    return z[:-4]
back = zlib.decompressobj(wbits=-9 if mode == "window" else -15)
def inflate(payload):
    d = zlib.decompressobj(wbits=-15) if mode == "fresh" else back
    try:
        return d.decompress(payload + TAIL)
    except zlib.error as e:
        return repr(e).encode()
ls = socket.socket()
ls.bind(("127.0.0.1", 0))
ls.listen(1)
port = ls.getsockname()[1]
print(port, flush=True)
c, _ = ls.accept()
if os.environ.get("TLS_CERT"):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.environ["TLS_CERT"], os.environ["TLS_KEY"])
    c = context.wrap_socket(c, server_side=True)
c.settimeout(20)
buf = b""
while b"\r\n\r\n" not in buf:
    buf += c.recv(65536)
head, _, buf = buf.partition(b"\r\n\r\n")
fields = {}
for line in head.split(b"\r\n")[1:]:
    k, _, v = line.partition(b":")
    fields[k.strip().lower()] = v.strip()
check(fields.get(b"sec-websocket-extensions") == b"permessage-deflate; client_max_window_bits", f"the client's offer: {fields.get(b'sec-websocket-extensions')!r}")
key = fields.get(b"sec-websocket-key", b"")
accept = base64.b64encode(hashlib.sha1(key + GUID).digest())
# 35 copies of a random 2000-byte block: a compressor that reaches 2000
# back writes the copies in a few bytes each, and one held to 2^9 cannot.
rng = random.Random(9)
block = bytes(rng.getrandbits(8) for _ in range(2000))
big = block * 35
c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept +
          b"\r\nSec-WebSocket-Protocol: chat\r\nSec-WebSocket-Extensions: " + answer.encode() + b"\r\n\r\n" + encode(1, deflate(b"hello"), rsv=0x40))
z = deflate(b"frag")
c.sendall(encode(1, z[:2], fin=False, rsv=0x40) + encode(9, b"p1") + encode(0, z[2:]))
c.sendall(encode(2, deflate(big), rsv=0x40))
def read(n):
    global buf
    while len(buf) < n:
        chunk = c.recv(65536)
        if not chunk:
            raise EOFError(f"{n} bytes wanted, {len(buf)} came")
        buf += chunk
    out, buf = buf[:n], buf[n:]
    return out
def frame():
    b0, b1 = read(2)
    n = b1 & 127
    if n == 126: n = struct.unpack("!H", read(2))[0]
    elif n == 127: n = struct.unpack("!Q", read(8))[0]
    key = read(4)
    data = read(n)
    stream = (key * (n // 4 + 1))[:n]
    data = (int.from_bytes(data, "big") ^ int.from_bytes(stream, "big")).to_bytes(n, "big") if n else b""
    return b0, data
b0, data = frame()
check(b0 == 0xc1 and inflate(data) == b"hello", f"the echo of hello, compressed: {b0:#x}")
check(frame() == (0x8a, b"p1"), "the pong, not compressed")
b0, data = frame()
check(b0 == 0xc1 and inflate(data) == b"frag", "the fragments' echo")
b0, data = frame()
check(b0 == 0xc2 and inflate(data) == big, f"70000 bytes echoed: {b0:#x}")
if mode == "window":
    check(len(data) > 60000, f"held to 2^9, no match 2000 back: {len(data)} bytes")
else:
    check(len(data) < 10000, f"matches 2000 back: {len(data)} bytes")
b0, data = frame()
check(b0 == 0xc1 and inflate(data) == "é and ✓".encode(), "UTF-8 from the client")
c.sendall(encode(8, struct.pack("!H", 1000) + b"done"))
b0, data = frame()
check(b0 == 0x88 and data == struct.pack("!H", 1000), f"the client's echo of the close: {data!r}")
c.close()
if not bad:
    print(f"  {mode}: {answer!r} agreed; three compressed messages read, echoed compressed, inflated by zlib; the close", flush=True)
sys.exit(1 if bad else 0)
PY
  for mode in takeover fresh window; do
    MODE="$mode" timeout 120 "$PY" "$WORK/ws-deflate-server.py" > "$WORK/pydeflate-$mode.out" 2>&1 &
    py_pid=$!
    pyport=$(await_port "$WORK/pydeflate-$mode.out" "$py_pid")
    client_said=$(timeout 60 "$WORK/ws-plain" connect "$pyport" 2>&1)
    wait "$py_pid"
    py_status=$?
    sed -n '2,$p' "$WORK/pydeflate-$mode.out"
    if [ "$py_status" -ne 0 ]; then
      echo "  Python's RFC 7692 server ($mode) and the client disagree"
      status=1
    elif [ "$client_said" != "$expected" ]; then
      echo "  the client said, against the $mode server:"
      printf '%s\n' "$client_said" | sed 's/^/    /'
      status=1
    fi
  done
fi

echo
echo "== wss://: the same peers under TLS (a P-256 certificate)"
# std/http's server under std/tls's, which hands upgrade's block the TLS
# stream; std/p256 signs every handshake. Python's client and Node's
# against it, the stop, and the client against Python's server under
# ssl - each the program above, wrapped.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import ec' >/dev/null 2>&1; then
  echo "  skipped: no python cryptography to make a certificate with"
else
  mkdir -p "$WORK/wss"
  "$PY" - "$WORK/wss" <<'PY'
import datetime as dt, os, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
out = sys.argv[1]
now = dt.datetime.now(dt.timezone.utc)
def name(cn): return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
root_key, key = ec.generate_private_key(ec.SECP256R1()), ec.generate_private_key(ec.SECP256R1())
root = (x509.CertificateBuilder().subject_name(name("wss root")).issuer_name(name("wss root"))
        .public_key(root_key.public_key()).serial_number(1).not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=2))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()), critical=False)
        .sign(root_key, hashes.SHA256()))
leaf = (x509.CertificateBuilder().subject_name(name("localhost")).issuer_name(root.subject)
        .public_key(key.public_key()).serial_number(2).not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=2))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), critical=False)
        .sign(root_key, hashes.SHA256()))
pem = lambda c: c.public_bytes(serialization.Encoding.PEM)
open(os.path.join(out, "roots.pem"), "wb").write(pem(root))
open(os.path.join(out, "chain.pem"), "wb").write(pem(leaf) + pem(root))
open(os.path.join(out, "key.pem"), "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
PY
  "$WORK/ws-plain" serve "$WORK/wss/chain.pem" "$WORK/wss/key.pem" > "$WORK/wss-serve.out" 2>&1 &
  wss_pid=$!
  wport=$(await_port "$WORK/wss-serve.out" "$wss_pid")
  if [ -z "$wport" ]; then
    echo "  the server under TLS printed no port"
    sed -n '1,5p' "$WORK/wss-serve.out" | sed 's/^/    /'
    status=1
  else
    if [ ! -s "$WORK/ws-client.py" ]; then
      echo "  no Python client was written above, so none ran over wss://"
    elif ! PORT="$wport" TLS_ROOTS="$WORK/wss/roots.pem" HOST=localhost timeout 120 "$PY" "$WORK/ws-client.py"; then
      echo "  Python's client and the server disagree over wss://"
      status=1
    fi
    if [ -s "$WORK/ws-deflate-client.py" ] && ! PORT="$wport" TLS_ROOTS="$WORK/wss/roots.pem" HOST=localhost timeout 120 "$PY" "$WORK/ws-deflate-client.py"; then
      echo "  Python's RFC 7692 client and the server disagree over wss://"
      status=1
    fi
    if [ -s "$WORK/ws-node.js" ]; then
      if ! PORT="$wport" WS_URL="wss://localhost:$wport/chat" NODE_EXTRA_CA_CERTS="$WORK/wss/roots.pem" timeout 60 node "$WORK/ws-node.js"; then
        echo "  Node's client and the server disagree over wss://"
        status=1
      fi
    fi
    PORT="$wport" TLS_ROOTS="$WORK/wss/roots.pem" timeout 60 "$PY" "$WORK/ws-stop.py" || { echo "  the server under TLS did not stop"; status=1; }
    waited=0
    while kill -0 "$wss_pid" 2>/dev/null && [ "$waited" -lt 300 ]; do
      sleep 0.1
      waited=$((waited + 1))
    done
    if ! kill -0 "$wss_pid" 2>/dev/null && grep -q "^stopped$" "$WORK/wss-serve.out"; then
      echo "  the server under TLS stopped at \"stop\" with a close 1001"
    else
      echo "  the server under TLS did not return from serve"
      status=1
    fi
  fi
  kill "$wss_pid" 2>/dev/null
  if [ -s "$WORK/ws-server.py" ]; then
    TLS_CERT="$WORK/wss/chain.pem" TLS_KEY="$WORK/wss/key.pem" HOST=localhost timeout 120 "$PY" "$WORK/ws-server.py" > "$WORK/wss-pyserver.out" 2>&1 &
    py_pid=$!
    pyport=$(await_port "$WORK/wss-pyserver.out" "$py_pid")
    client_said=$(timeout 60 "$WORK/ws-plain" connect "$pyport" "$WORK/wss/roots.pem" 2>&1)
    wait "$py_pid"
    py_status=$?
    sed -n '2,$p' "$WORK/wss-pyserver.out"
    expected='protocol chat
text "hello"
text "frag"
binary 70000 bytes
end
closed 1000 done'
    if [ "$py_status" -ne 0 ]; then
      echo "  Python's server under ssl and the client disagree"
      status=1
    elif [ "$client_said" != "$expected" ]; then
      echo "  the client said, over wss://:"
      printf '%s\n' "$client_said" | sed 's/^/    /'
      status=1
    else
      echo "  the client read the protocol, three messages and the close 1000 \"done\" over wss://"
    fi
  fi
  if [ -s "$WORK/ws-deflate-server.py" ]; then
    MODE=takeover TLS_CERT="$WORK/wss/chain.pem" TLS_KEY="$WORK/wss/key.pem" HOST=localhost timeout 120 "$PY" "$WORK/ws-deflate-server.py" > "$WORK/wss-pydeflate.out" 2>&1 &
    py_pid=$!
    pyport=$(await_port "$WORK/wss-pydeflate.out" "$py_pid")
    client_said=$(timeout 60 "$WORK/ws-plain" connect "$pyport" "$WORK/wss/roots.pem" 2>&1)
    wait "$py_pid"
    py_status=$?
    sed -n '2,$p' "$WORK/wss-pydeflate.out"
    if [ "$py_status" -ne 0 ] || [ "$client_said" != "$expected" ]; then
      echo "  Python's RFC 7692 server under ssl and the client disagree:"
      printf '%s\n' "$client_said" | sed 's/^/    /'
      status=1
    fi
  fi
  # And on a copy of std/http whose upgrade under TLS hands the block the
  # bare socket: the WebSocket's frames then go out in the clear, and the
  # Python client, reading TLS, must fail.
  if [ -s "$WORK/ws-client.py" ]; then
    rm -rf "$WORK/bare"
    mkdir -p "$WORK/bare/std"
    if ! "$PY" - "$REPO/src/std/http.iyi" "$WORK/bare/std/http.iyi" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "      conn.held { takeover.call(socket, leftover) }"
if src.count(old) != 1:
    raise SystemExit("patch site missing or not one")
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, "      conn.held { takeover.call(conn.socket, leftover) }"))
PY
    then
      echo "  the bare-socket patch did not apply"
      status=1
    elif ! IYI_PATH="$WORK/bare${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/ws-bare" "$REPO/bench/std_websocket_exercise.iyi" >"$WORK/bare.log" 2>&1; then
      echo "  the bare-socket copy did not compile"
      sed -n '1,6p' "$WORK/bare.log" | sed 's/^/    /'
      status=1
    else
      "$WORK/ws-bare" serve "$WORK/wss/chain.pem" "$WORK/wss/key.pem" > "$WORK/bare-serve.out" 2>&1 &
      bare_pid=$!
      bport=$(await_port "$WORK/bare-serve.out" "$bare_pid")
      if PORT="$bport" TLS_ROOTS="$WORK/wss/roots.pem" HOST=localhost timeout 60 "$PY" "$WORK/ws-client.py" >"$WORK/bare-client.out" 2>&1; then
        echo "  the Python client PASSED against an upgrade that hands over the bare socket under TLS"
        status=1
      else
        echo "  an upgrade that hands over the bare socket under TLS is caught: $(grep -m1 -E 'FAIL|Error' "$WORK/bare-client.out" | sed 's/^ *//' | cut -c1-100)"
      fi
      kill "$bare_pid" 2>/dev/null
    fi
  fi
fi

echo
echo "== the exercise's artifacts and other platforms"
# Built from the modules' artifacts, the exercise must print what it
# printed from source, darwin's frames under a task's panic left out
# (bench/darwin_frames.sh); and it typechecks for the four other
# platforms std is held to.
mkdir -p "$WORK/r1/mods"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_websocket_exercise.iyi" \
      && "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_websocket_exercise.iyi") > "$WORK/r1/build.log" 2>&1 \
   && timeout -k 5 300 "$WORK/r1/from-source" > "$WORK/r1/source.out" 2>&1 \
   && timeout -k 5 300 "$WORK/r1/from-artifact" > "$WORK/r1/artifact.out" 2>&1 \
   && without_frames < "$WORK/r1/source.out" > "$WORK/r1/source.cmp" \
   && without_frames < "$WORK/r1/artifact.out" > "$WORK/r1/artifact.cmp" \
   && cmp -s "$WORK/r1/source.cmp" "$WORK/r1/artifact.cmp" \
   && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
  echo "  from source and from its artifacts alike, $(wc -l < "$WORK/r1/artifact.out" | tr -d ' ') lines"
else
  echo "  FAIL: the exercise does not run the same from its artifacts"
  grep -m3 -E 'Error|panic: ASSERTION' "$WORK/r1/build.log" "$WORK/r1/source.out" "$WORK/r1/artifact.out" 2>/dev/null | sed 's/^/    /'
  diff "$WORK/r1/source.cmp" "$WORK/r1/artifact.cmp" 2>/dev/null | sed -n '1,6p' | sed 's/^/    /'
  status=1
fi
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross-$target" "$REPO/bench/std_websocket_exercise.iyi" > "$WORK/cross-$target.log" 2>&1; then
    echo "  FAIL: $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross-$target.log" | cut -c1-140)"
    status=1
  fi
done
echo "  typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
if "$IYI" doc "$REPO/src/std/websocket.iyi" > "$WORK/doc.out" 2>&1 && grep -q "deflate : Bool = true" "$WORK/doc.out" && grep -q "PerMessageDeflate" "$WORK/doc.out"; then
  echo "  iyi doc reads the module, permessage-deflate and all"
else
  echo "  FAIL: iyi doc src/std/websocket.iyi"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/websocket.iyi" "$REPO/bench/std_websocket_exercise.iyi" > "$WORK/format.log" 2>&1; then
  echo "  the module and its exercise are formatted"
else
  echo "  not formatted: $(grep -m1 produced "$WORK/format.log")"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [<other phrase>]: the exercise
# must fail on a copy of the module with <old> replaced, at the check that
# names <phrase> - or <other phrase>, where the platform decides which of
# two checks a break meets first. The module is std/websocket, or the
# std module MUTATE names.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  local label="$1" phrase="$2" other="${5:-}"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $label proof is unmeasured"
    return
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/${MUTATE:-websocket.iyi}").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/${MUTATE:-websocket.iyi}").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $label patch did not apply"
    status=1
  # Built first, then run: a patch that does not compile would also fail,
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations" "$REPO/bench/std_websocket_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the $label copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif timeout -k 5 120 "$WORK/mut-$mutations" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $label"
    status=1
  elif grep -qF -- "$phrase" "$WORK/mut.out" || { [ -n "$other" ] && grep -qF -- "$other" "$WORK/mut.out"; }; then
    echo "  $label is caught"
  else
    echo "  $label failed, but not where it should have:"
    # The panic that ended it, not the run's last lines: on darwin those
    # are the frames printed after the message.
    grep -v '^iyi: panic: WebSocket: ' "$WORK/mut.out" | grep -m3 -E '^iyi: panic|ASSERTION' | sed 's/^/    /'
    status=1
  fi
}
prove_broken "a GUID with one digit wrong" "the accept value of §1.3's key" \
  'GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"' 'GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B12"'
prove_broken "a server that does not check the client's version" "version 8 is 426 naming 13" \
  'unless HTTP.trim(version) == "13"' 'if false'
prove_broken "a client that takes any accept value" "a wrong accept" \
  ' unless HTTP.trim(accepted) == accept(key)' ' if false'
prove_broken "a client that drops what came with the 101" "a frame that came with the 101" \
  'WebSocket.new(up.socket, up.leftover, true, agreed, max_message, terms)' 'WebSocket.new(up.socket, "", true, agreed, max_message, terms)'
prove_broken "a server that drops what came after the handshake" "a frame in the leftover" \
  '    @in_stop = leftover.bytesize' '    @in_stop = 0'
prove_broken "a client that does not mask" "a client's 1 bytes, unmasked by the reader" \
  '        WebSocket.mask(dst + head, n, key)' ''
prove_broken "a server that takes unmasked frames" "an unmasked client frame" \
  '      return fail(1002, "a client'"'"'s frame is not masked") unless masked' ''
prove_broken "a client that takes masked frames" "a masked server frame" \
  '      return fail(1002, "a server'"'"'s frame is masked") if masked' ''
prove_broken "reserved bits read past" "RSV1" \
  'if (b0 & 112) != 0' 'if (b0 & 0) != 0'
prove_broken "a control frame past 125 bytes" "a ping of 126 bytes" \
  '      return fail(1002, "a control frame claims more than 125 bytes") if short > 125' ''
prove_broken "a new message inside a fragmented one" "a text inside a text" \
  '      return fail(1002, "a new message before the last one'"'"'s final frame") if @parts_op != 0' ''
prove_broken "a 64-bit length with its high bit read as a length" "a 64-bit length with its high bit set" \
  '      return fail(1002, "a 64-bit length with its high bit set") if (p[2] & 128_u8) != 0_u8' ''
prove_broken "a UTF-8 check that starts again at each fragment" "é split between two fragments" \
  '@utf8 = WebSocket.utf8_scan(@parts + @parts_size, n, @utf8)' '@utf8 = WebSocket.utf8_scan(@parts + @parts_size, n, 0)'
prove_broken "overlong two-byte forms taken" "c0 80 as text" \
  'elsif b >= 0xC2 && b <= 0xDF' 'elsif b >= 0xC0 && b <= 0xDF'
prove_broken "surrogates taken" "ed a0 80 as text" \
  'high = 0x9F' 'high = 0xBF'
prove_broken "a limit only past Int32" "1001 declared bytes past 1000" \
  'if total > @max_message.to_u64' 'if total > 2147483647_u64'
prove_broken "a ping left unanswered" "7 bytes were expected and 0 came" \
  '      write_frame(OP_PONG, payload)! unless @sent_close' ''
prove_broken "close codes taken whatever they are" "close code 0" \
  'unless WebSocket.close_code?(code)
      reason' 'if false
      reason'
prove_broken "a close echoed without its code" "is echoed with its code" \
  'write_frame(OP_CLOSE, count >= 2 ? payload[0, 2] : "")' 'write_frame(OP_CLOSE, "")'
prove_broken "a close reason that need not be UTF-8" "a close reason that is not UTF-8" \
  '      return fail(1007, "a close reason that is not UTF-8") unless WebSocket.utf8_scan(reason.to_unsafe, reason.bytesize, 0) == 0' ''
# The runtime refuses a second task's write to a socket another task's
# write is parked on, so without the wait one of them panics - where the
# first write parks before the second comes. Where the socket's buffers
# take the second write while the first waits (darwin's), the second
# frame lands inside the first, which the 16 MiB check finds.
prove_broken "two tasks writing at once" "two fibers writing one fd" \
  '    while @writing
      sleep(1)!
    end
' '' "16 MiB written whole while another task sends"
prove_broken "a client that goes direct past its proxy" "the handshake through the proxy's tunnel" \
  'HTTP.upgrade(target, "websocket", sent, proxy: proxy)' 'HTTP.upgrade(target, "websocket", sent)'
prove_broken "a compressed message sent with its 00 00 ff ff" "§7.2.3.1's Hello frame, byte for byte" \
  '    size = size - 4' '    size = size - 0'
prove_broken "a compressed message sent without RSV1" "§7.2.3.1's Hello frame, byte for byte" \
  '(128 | (compressed ? 64 : 0) | opcode)' '(128 | opcode)'
prove_broken "the window carried over under server_no_context_takeover" "under server_no_context_takeover the second Hello is the first's bytes" \
  '    if deflater.nil? || fresh' '    if deflater.nil?'
prove_broken "a decoder that forgets the window between messages" "§7.2.3.2's shared window: Hello again in 5 bytes" \
  '    if inflater.nil? || fresh' '    if inflater.nil? || true'
prove_broken "RSV1 taken on a continuation" "RSV1 on a continuation" \
  '      return fail(1002, "RSV1 set on a continuation frame; it marks a compressed message on its first frame alone") if rsv1' ''
prove_broken "RSV1 taken on a control frame" "RSV1 on a ping" \
  '      return fail(1002, "RSV1 set on a control frame; permessage-deflate compresses messages alone") if rsv1' ''
prove_broken "a deflate bomb inflated whole" "a deflate bomb" \
  'inflater.inflate(tailed, @max_message)' 'inflater.inflate(tailed)'
prove_broken "control frames compressed" "a pong, never compressed" \
  'compressed = !@deflate.nil? && (opcode == OP_TEXT || opcode == OP_BINARY)' 'compressed = !@deflate.nil?' "a ping, never compressed"
prove_broken "compressed fragments checked as text" "§7.2.3.1's Hello in fragments of 3 and 4" \
  '    if kind == OP_TEXT && !compressed' '    if kind == OP_TEXT'
prove_broken "a compressor that ignores max_window_bits" "a window of 2^8 holds every match to 256 back" \
  'terms.level, @client ? terms.client_max_window_bits : terms.server_max_window_bits)' 'terms.level, 15)'
prove_broken "the deflate level ignored" "at level 0 the Hello is §7.2.3.3's stored block" \
  'Deflater.new(Envelope::Raw, terms.level,' 'Deflater.new(Envelope::Raw, 6,'
prove_broken "an offer's unknown parameter read past" "another extension and an offer it cannot keep passed over" \
  'return "#{param[0]} is not a parameter of permessage-deflate"' 'next' '"permessage-deflate; foo" is declined'
prove_broken "an offer's parameter taken twice" '"permessage-deflate; client_no_context_takeover; client_no_context_takeover" is declined' \
  'return "#{param[0]} is named twice" if seen.includes?(name)' 'seen.size'
prove_broken "an answer's client_max_window_bits taken without a value" 'an answer of "permessage-deflate; client_max_window_bits"' \
  'elsif answer || name == "server_max_window_bits"' 'elsif name == "server_max_window_bits"'
prove_broken "server_no_context_takeover accepted and not named back" "both no_context_takeovers named back" \
  'answer = answer + "; server_no_context_takeover" if terms.server_no_context_takeover' 'answer = answer + "" if terms.server_no_context_takeover'
MUTATE=compress.iyi prove_broken "a chain's head taken past a smaller window" "a window of 2^8 holds every match to 256 back" \
  's - old > @reach ? 0 : old' 's - old > WSIZE ? 0 : old'
MUTATE=compress.iyi prove_broken "a final block that ends the stream by pieces" "the window kept past a final block" \
  '@state = @pieces ? BLOCK : DONE' '@state = DONE'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/websocket exercise holds"
else
  echo "the std/websocket exercise did not hold"
fi
exit $status
