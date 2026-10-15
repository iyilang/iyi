#!/usr/bin/env bash
# Exercises `std/sse`.
#
#     bash bench/std_sse_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The patches, the reference parser and the peers below are python, and
# windows answers `python3` with a store stub that prints and exits rather
# than running it, so the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping, so the
# scratch directory is named the way it reads it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_sse_exercise.iyi" \
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

echo "== the std/sse exercise, plain build"
build_and_run "plain" sse-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/sse-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" sse-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/sse-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a stream refuses before it is written"
refuses() { # refuses <label> <name> <phrase> <statement>
  local label="$1" name="$2" phrase="$3" statement="$4"
  printf 'module main\n\nimport std/sse::{SSE, EventWriter}\nimport std/http::{BodyWriter}\nimport std/socket::{IyiSocket}\n\nw = EventWriter.new(BodyWriter.new(IyiSocket.listen("127.0.0.1", 0), true))\n%s\nputs "answered"\n' \
    "$statement" > "$WORK/$name.iyi"
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
  elif ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
  else
    printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -oF "$phrase" "$WORK/$name.out")"
  fi
}
refuses "an event type with a line break" event_break 'SSE: an event type cannot hold a line break: "a\nb"' \
  'w.send("x", event: "a\nb")'
refuses "an id with a CR" id_cr 'SSE: an id cannot hold a line break or a NUL: "1\r"' \
  'w.send("x", id: "1\r")'
refuses "an id with a NUL" id_nul 'SSE: an id cannot hold a line break or a NUL' \
  'w.send("x", id: "1" + String.new(1) { |p| p[0] = 0_u8 })'
refuses "a negative retry" retry_negative 'SSE: a retry is 0 or more milliseconds, not -5' \
  'w.send("x", retry: -5)'
refuses "data that is not UTF-8" data_bytes 'SSE: the data is not UTF-8' \
  'w.send("a" + String.new(1) { |p| p[0] = 0xFF_u8 })'
refuses "a comment that is not UTF-8" comment_bytes 'SSE: a comment is not UTF-8' \
  'w.comment(String.new(1) { |p| p[0] = 0xC0_u8 })'
refuses "a stream's own Content-Type" stream_type "SSE: Content-Type is the stream's own, text/event-stream" \
  'SSE.stream({"content-type" => "text/plain"}) { |events| nil }'
refuses "a client's own Last-Event-ID" open_header "SSE: Last-Event-ID is the stream's own header; the last event ID is last_event_id:" \
  'SSE.open("http://127.0.0.1:9/", {"Last-Event-ID" => "3"}) { |e| true }'
refuses "a last_event_id with a line break" open_id 'SSE: an id cannot hold a line break or a NUL: "a\nb"' \
  'SSE.open("http://127.0.0.1:9/", last_event_id: "a\nb") { |e| true }'
refuses "fewer than no reconnections" open_reconnects 'SSE: reconnects is 0 or more, not -1' \
  'SSE.open("http://127.0.0.1:9/", reconnects: -1) { |e| true }'

# The interpretation of §9.2.6 transcribed in Python, written apart from
# the module: the stream decoded whole (Python's UTF-8 decoder with
# "replace" substitutes maximal subparts, as the Encoding Standard's does),
# one BOM dropped, cut into lines by a regular expression, the last piece
# - after the last line end - discarded.
cat > "$WORK/sse_reference.py" <<'PY'
import re

MAX_RETRY = 2147483647

def parse(raw):
    text = raw.decode("utf-8", "replace")
    if text.startswith("\ufeff"):
        text = text[1:]
    lines = re.split(r"\r\n|\r|\n", text)[:-1]
    events, data, kind, id_buffer, last, retry = [], "", "", "", "", None
    for line in lines:
        if line == "":
            last = id_buffer
            if data == "":
                kind = ""
                continue
            if data.endswith("\n"):
                data = data[:-1]
            events.append((kind or "message", data, last))
            data, kind = "", ""
            continue
        if line.startswith(":"):
            continue
        if ":" in line:
            field, _, value = line.partition(":")
            if value.startswith(" "):
                value = value[1:]
        else:
            field, value = line, ""
        if field == "event":
            kind = value
        elif field == "data":
            data += value + "\n"
        elif field == "id":
            if "\0" not in value:
                id_buffer = value
        elif field == "retry":
            if value and all(c in "0123456789" for c in value):
                retry = min(int(value), MAX_RETRY)
    return events, last, retry

def transcript(raw):
    events, last, retry = parse(raw)
    out = [f"E {k.encode().hex()} {d.encode().hex()} {i.encode().hex()}" for k, d, i in events]
    out.append(f"L {last.encode().hex()} R {'-' if retry is None else retry}")
    return out
PY

echo
echo "== the parser against a Python transcription of §9.2.6, over a generated corpus"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
elif ! WORK="$WORK" "$PY" - <<'PY'
import os, random, sys
sys.path.insert(0, os.environ["WORK"])
from sse_reference import transcript
rng = random.Random(20261014)
names = ["data", "data", "data", "event", "id", "id", "retry", "Data", "dat", "data ", "", "\ufeffdata", "x"]
values = ["", "a", " ", "  b", "x:y", "é", "ü € 😀", "12", "007", "1a", "-1", "99999999999999999999", "\0", "a\0b", "\ufeff", ":", " :", "\x01"]
raw_bits = [b"\xff", b"\xed\xa0\x80", b"\xe2\x82", b"\xf0\x9f", b"\xc0\xaf", b"\xf4\x90\x80\x80", b"\xef\xbb\xbf", b"\x80\x80"]
ends = [b"\n", b"\r", b"\r\n"]
def generated():
    out = bytearray()
    r = rng.random()
    if r < 0.15:
        out += b"\xef\xbb\xbf"
    if r < 0.05:
        out += b"\xef\xbb\xbf"
    for _ in range(rng.randint(0, 14)):
        k = rng.random()
        if k < 0.22:
            line = b""
        elif k < 0.3:
            line = b":" + rng.choice(values).encode()
        else:
            sep = rng.choice([b":", b": ", b":  ", b"", b"::"])
            line = rng.choice(names).encode() + (sep + rng.choice(values).encode() if sep else b"")
            if rng.random() < 0.15:
                line += rng.choice(raw_bits)
        out += line + rng.choice(ends)
    if rng.random() < 0.3:
        out += rng.choice([b"data: tail", b"data: tail\r", b"id: 9\n", b"\r"])
    return bytes(out)
cases = [
    b"data: This is the first message.\n\ndata: This is the second message, it\ndata: has two lines.\n\ndata: This is the third message.",
    b"event: add\ndata: 73857293\n\nevent: remove\ndata: 2153\n\nevent: add\ndata: 113411\n\n",
    b"data: YHOO\ndata: +2\ndata: 10\n\n",
    b": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n",
    b"data\n\ndata\ndata\n\ndata:",
    b"data:test\n\ndata: test\n\n",
    b"\xef\xbb\xbf\xef\xbb\xbfdata: a\n\ndata: b\n\n",
]
cases += [generated() for _ in range(800)]
with open(os.path.join(os.environ["WORK"], "corpus.hex"), "w") as f:
    for c in cases:
        f.write(c.hex() + "\n")
with open(os.path.join(os.environ["WORK"], "corpus.want"), "w") as f:
    for c in cases:
        f.write("\n".join(transcript(c)) + "\n")
PY
then
  echo "  the corpus was not written"
  status=1
elif ! "$WORK/sse-plain" corpus "$WORK/corpus.hex" > "$WORK/corpus.got" 2>&1; then
  echo "  the parser did not read the corpus"
  tail -3 "$WORK/corpus.got"
  status=1
elif WORK="$WORK" "$PY" - <<'PY'
import os, sys
work = os.environ["WORK"]
want = open(os.path.join(work, "corpus.want")).read().splitlines()
got = open(os.path.join(work, "corpus.got")).read().splitlines()
cases = sum(1 for line in want if line.startswith("L "))
events = sum(1 for line in want if line.startswith("E "))
if want != got:
    for n, (w, g) in enumerate(zip(want, got)):
        if w != g:
            print(f"  FAIL at line {n + 1}: python {w!r}, iyi {g!r}")
            break
    else:
        print(f"  FAIL: python {len(want)} lines, iyi {len(got)}")
    sys.exit(1)
print(f"  {cases} streams, the standard's six among them, {events} events: the same events, IDs and retries, fed in pieces of 1 to 7 bytes")
PY
then
  :
else
  status=1
fi

echo
echo "== Python and curl reading the server's streams"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
else
  "$WORK/sse-plain" serve > "$WORK/serve.out" 2>&1 &
  serve_pid=$!
  port=""
  for _ in $(seq 1 300); do
    port=$(head -1 "$WORK/serve.out" 2>/dev/null)
    [ -n "$port" ] && break
    kill -0 "$serve_pid" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$port" ]; then
    echo "  the server printed no port"
    status=1
    kill "$serve_pid" 2>/dev/null
  else
    if command -v curl >/dev/null 2>&1; then
      curl -sN --max-time 10 "http://127.0.0.1:$port/events" > "$WORK/curl.events" 2>/dev/null
      curl -sN --max-time 10 -H 'Last-Event-ID: 9' "http://127.0.0.1:$port/resume" > "$WORK/curl.resume" 2>/dev/null
    fi
    if PORT="$port" WORK="$WORK" "$PY" - <<'PY'
import os, sys, time, http.client, shutil
sys.path.insert(0, os.environ["WORK"])
from sse_reference import parse
port = int(os.environ["PORT"])
work = os.environ["WORK"]
feed = (": hello\n" "data: first\n\n" "event: update\nid: 7\ndata: two\ndata: lines\n\n"
        "data: crlf\ndata: and\ndata: cr\n\n" "id: \ndata:\n\n" "data:   spaced\n\n"
        "retry: 1500\ndata: ü € 😀\n\n" ": multi\n: line\n" "event: \ndata: last\ndata:\n\n").encode()
bad = 0
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what); bad += 1
def get(path, headers={}):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("GET", path, headers=headers)
    r = c.getresponse()
    return c, r
c, r = get("/events")
body = r.read()
check(r.status == 200 and r.getheader("Content-Type") == "text/event-stream" and r.getheader("Cache-Control") == "no-cache", f"headers: {r.status} {r.getheaders()}")
check(r.getheader("Transfer-Encoding") == "chunked", "chunked")
check(body == feed, f"the bytes: {body!r}")
events, last, retry = parse(body)
check(events == [("message", "first", ""), ("update", "two\nlines", "7"), ("message", "crlf\nand\ncr", "7"), ("message", "", ""),
                 ("message", "  spaced", ""), ("message", "ü € 😀", ""), ("message", "last\n", "")] and retry == 1500, f"events: {events} {retry}")
c.close()
c, r = get("/resume", {"Last-Event-ID": "5"})
events, last, retry = parse(r.read())
check([(d, i) for _, d, i in events] == [("after 5", "6"), ("after 5", "7"), ("after 5", "8")], f"resume: {events}")
c.close()
# Three ticks read as they are written - the stream would run ten
# seconds - then the connection closed under the server's loop.
c, r = get("/ticks")
started = time.monotonic()
lines, blanks = [], 0
while blanks < 3:
    line = r.readline()
    if not line:
        break
    lines.append(line)
    blanks += line == b"\n"
check(blanks == 3 and time.monotonic() - started < 3, f"three ticks as they came: {lines}")
c.close()
r.close()
state = "running"
for _ in range(300):
    c2, r2 = get("/ticks-status")
    state = r2.read().decode()
    c2.close()
    if state != "running":
        break
    time.sleep(0.02)
check(state.startswith("ended true ") and int(state.split()[2]) < 2000, f"the server's loop ended when Python went: {state}")
curl_note = "curl not installed"
if shutil.which("curl"):
    got = open(os.path.join(work, "curl.events"), "rb").read()
    check(got == feed, f"curl -N /events: {got!r}")
    resumed = parse(open(os.path.join(work, "curl.resume"), "rb").read())[0]
    check([i for _, _, i in resumed] == ["10", "11", "12"], f"curl /resume: {resumed}")
    curl_note = "curl -N reads the same bytes and resumes at 9"
get("/stop")[1].read()
print(f"  the stream byte for byte, its headers, chunked; seven events by the transcription; three ticks live, then {state.split()[2]} writes before the server saw Python gone; {curl_note}" if not bad else "  Python disagrees")
sys.exit(1 if bad else 0)
PY
    then
      wait "$serve_pid"
    else
      kill "$serve_pid" 2>/dev/null
      status=1
    fi
  fi
fi

echo
echo "== the client against a Python server that drops it"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
elif WORK="$WORK" CLIENT="$WORK/sse-plain" "$PY" - <<'PY'
import os, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
seen = {"drop": [], "forever": [], "plain": [], "quiet": []}
forever_end = []
lock = threading.Lock()
def chunk(data):
    return b"%x\r\n" % len(data) + data + b"\r\n"
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def head(self, kind="text/event-stream", extra=()):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
    def cut(self):
        # The connection dropped inside a chunked body: no last chunk.
        self.wfile.flush()
        self.connection.shutdown(socket.SHUT_RDWR)
        self.close_connection = True
    def do_GET(self):
        name = self.path.strip("/")
        with lock:
            # perf_counter, not monotonic: Windows' monotonic moves in
            # steps of 15.6 ms, and a 50 ms wait read as 47.
            seen[name].append((time.perf_counter(), dict(self.headers)))
            n = len(seen[name]) - 1
        if name == "drop":
            if n == 3:
                self.send_response(204)
                self.end_headers()
                return
            self.head(extra=[("Transfer-Encoding", "chunked")])
            body = [b"retry: 50\n\nid: 1\ndata: one\n\nid: 2\ndata: two\n\nid: 3\ndata: thr",
                    b"data: three\n\nid: 4\0x\ndata: four\n\n",
                    b"id\ndata: five\n\n"][n]
            self.wfile.write(chunk(body))
            self.cut()
        elif name == "forever":
            self.head(extra=[("Transfer-Encoding", "chunked")])
            k = 0
            try:
                while k < 500:
                    self.wfile.write(chunk(b"data: %d\nid: %d\n\n" % (k, 42 + k)))
                    self.wfile.flush()
                    k += 1
                    time.sleep(0.02)
            except OSError:
                pass
            forever_end.append(k)
            self.close_connection = True
        elif name == "plain":
            self.head("text/plain", [("Content-Length", "9")])
            self.wfile.write(b"data: x\n\n")
        elif name == "quiet":
            self.head(extra=[("Content-Length", "0")])
class Quiet(ThreadingHTTPServer):
    # A connection this server cut is not an error worth a traceback.
    def handle_error(self, request, address):
        pass
server = Quiet(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"
run = subprocess.run([os.environ["CLIENT"], "client", base], capture_output=True, text=True, timeout=60)
out = run.stdout.splitlines()
bad = 0
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what); bad += 1
def ev(line):
    _, k, d, i = (line.split(" ") + ["", "", ""])[:4]
    return bytes.fromhex(k).decode(), bytes.fromhex(d).decode(), bytes.fromhex(i).decode()
events = [ev(l) for l in out if l.startswith("event ")]
check(run.returncode == 0, f"the client exited {run.returncode}: {run.stderr[-300:]}")
check(events == [("message", "one", "1"), ("message", "two", "2"), ("message", "three", "2"), ("message", "four", "2"), ("message", "five", "")], f"events: {events}")
check("drop: SSEError 204: SSE: the server answered 204, not 200" in out, f"drop: {out}")
drops = seen["drop"]
check(len(drops) == 4, f"{len(drops)} connections to /drop")
if len(drops) == 4:
    ids = [h.get("Last-Event-ID") for _, h in drops]
    check(ids == [None, "2", "2", None], f"Last-Event-ID {ids}")
    first = drops[0][1]
    check(first.get("Accept") == "text/event-stream" and first.get("Cache-Control") == "no-cache" and first.get("X-Probe") == "1", f"headers {first}")
    gaps = [round((drops[k][0] - drops[k - 1][0]) * 1000) for k in range(1, 4)]
    check(all(50 <= g < 2000 for g in gaps), f"delays {gaps} ms after retry: 50, against the caller's 5000")
check([l for l in out if l.startswith("forever ")] == ["forever 0 42", "forever 1 43", "forever 2 44"], f"forever: {out}")
check("forever: nil" in out, "false ends with nil")
check([h.get("Last-Event-ID") for _, h in seen["forever"]] == ["41"], f"last_event_id: {seen['forever']}")
for _ in range(100):
    if forever_end:
        break
    time.sleep(0.05)
check(forever_end and forever_end[0] < 500, f"the client closed its connection when it stopped: {forever_end}")
check('plain: SSEError 200: SSE: the answer is "text/plain", not text/event-stream' in out and len(seen["plain"]) == 1, f"plain: {out} {len(seen['plain'])}")
check("quiet: SSEError 200: SSE: the stream ended with no event, 3 times in a row" in out and len(seen["quiet"]) == 3, f"quiet: {out} {len(seen['quiet'])}")
server.shutdown()
if not bad:
    print(f"  five events over four connections cut mid-chunk, Last-Event-ID none, 2, 2, none, delays {gaps} ms; a 204, text/plain and three empty streams each end it as the standard has; false closes the connection")
sys.exit(1 if bad else 0)
PY
then
  :
else
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
prove_broken() { # prove_broken <label> <phrase> <old> <new>
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/sse.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/sse.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_sse_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "a leading BOM kept" "a leading BOM is dropped" \
  '        line = line[3, line.bytesize - 3]
' ''
prove_broken "a CR alone not a line end" "CR alone ends a line" \
  '      if c == 10_u8 || c == 13_u8
        line = text[start, i - start]' '      if c == 10_u8
        line = text[start, i - start]'
prove_broken "the LF of a CRLF split between pieces read as a blank line" "a CRLF split between pieces is one line end" \
  '      i = 1 if p[0] == 10_u8
' ''
prove_broken "every leading space stripped" "one space stripped" \
  'value = value[1, value.bytesize - 1] if value.bytesize > 0 && value.to_unsafe[0] == 32_u8' 'value = value.strip'
prove_broken "the data's last LF kept" "the introduction's three messages" \
  '    data = data[0, data.bytesize - 1] if data.ends_with?("\n")
' ''
prove_broken "an id with a NUL taken" "an id with a NUL is ignored" \
  '@id_buffer = value unless value.includes?("\0")' '@id_buffer = value'
prove_broken "the last event ID set at the id field" "the last event ID is set at the blank line" \
  '@id_buffer = value unless value.includes?("\0")' '@last_event_id = @id_buffer = value unless value.includes?("\0")'
prove_broken "an empty retry read as 0" "retry: digits alone" \
  '    return nil if text.bytesize == 0
    p = text.to_unsafe' '    p = text.to_unsafe'
prove_broken "the event type carried to the next event" "the type does not carry over" \
  '    event = Event.new(@type.bytesize == 0 ? "message" : @type, data, @last_event_id)
    @type = ""' '    event = Event.new(@type.bytesize == 0 ? "message" : @type, data, @last_event_id)'
prove_broken "a blank line without data dispatching" "the four blocks" \
  '    if @data.bytesize == 0
      @type = ""
      return nil
    end
' ''
prove_broken "ill-formed bytes passed through" "ill-formed bytes are U+FFFD" \
  'line = Unicode.clean(bytes)' 'line = bytes'
prove_broken "multi-line data written on one data: line" "the lines SSE.stream writes" \
  'EventWriter.lines(data).each do |line|' '[data].each do |line|'
prove_broken "a client gone not kept" "a client gone ends the stream's loop" \
  '    @fault = got
' ''
prove_broken "Last-Event-ID not sent" "last_event_id: goes out as Last-Event-ID" \
  'sent["Last-Event-ID"] = last if last.bytesize > 0 && !HTTP.control?(last)' ''
prove_broken "an id with a control character sent" "contains a control character" \
  'sent["Last-Event-ID"] = last if last.bytesize > 0 && !HTTP.control?(last)' 'sent["Last-Event-ID"] = last if last.bytesize > 0'
prove_broken "a reconnection's parser started with no ID" "a resumed stream keeps its place" \
  'parser = EventParser.new(last)' 'parser = EventParser.new'
prove_broken "the stream's retry ignored" "the stream's retry sets the delay" \
  '      if ms = parser.retry
        delay = ms
      end
' ''
prove_broken "the no-event count never started again" "a connection that brings an event starts the count again" \
  'misses = parser.dispatched > 0_i64 ? 0 : misses + 1' 'misses = misses + 1'
prove_broken "a status other than 200 read as a stream" "a 204 fails the connection" \
  'return SSEError.new("the server answered #{status}, not 200", status) unless status == 200' ''
prove_broken "any Content-Type read as a stream" "text/plain fails the connection" \
  'unless type && SSE.event_stream?(type)' 'if false'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/sse exercise holds"
else
  echo "the std/sse exercise did not hold"
fi
exit $status
