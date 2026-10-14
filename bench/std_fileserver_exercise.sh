#!/usr/bin/env bash
# Exercises `std/fileserver`.
#
#     bash bench/std_fileserver_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The patches and the client below are python, and windows answers
# `python3` with a store stub that prints and exits rather than running it,
# so the interpreter is measured here instead of assumed.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_fileserver_exercise.iyi" \
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

echo "== the std/fileserver exercise, plain build"
build_and_run "plain" files-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/files-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" files-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/files-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== Python's http.client against a directory served"
# A file of 300 KB, so a range in its middle and its last bytes cross the
# server's 64 KB pieces, and Python's own reading of each answer.
mkdir -p "$WORK/www/sub"
if [ -n "$PY" ]; then
  "$PY" -c "import sys; sys.stdout.buffer.write(bytes(range(256)) * 1200)" > "$WORK/www/blob.bin"
  printf '<p>sub</p>' > "$WORK/www/sub/index.html"
  printf 'body { color: red }' > "$WORK/www/style.css"
fi
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
else
  "$WORK/files-plain" serve "$WORK/www" > "$WORK/serve.out" 2>&1 &
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
  elif PORT="$port" ROOT="$WORK/www" "$PY" - <<'PY'
import os, sys, http.client, email.utils
root = os.environ["ROOT"]
blob = open(os.path.join(root, "blob.bin"), "rb").read()
c = http.client.HTTPConnection("127.0.0.1", int(os.environ["PORT"]), timeout=10)
bad = 0
def get(path, headers={}, method="GET"):
    c.request(method, path, headers=headers)
    r = c.getresponse()
    return r, r.read()
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what); bad += 1
r, body = get("/blob.bin")
check(r.status == 200 and body == blob and r.getheader("Content-Length") == str(len(blob)), f"whole: {r.status} {len(body)}")
check(r.getheader("Content-Type") == "application/octet-stream", r.getheader("Content-Type"))
mtime = os.stat(os.path.join(root, "blob.bin")).st_mtime
check(email.utils.parsedate_to_datetime(r.getheader("Last-Modified")).timestamp() == int(mtime), "Last-Modified is the file's")
tag = r.getheader("ETag")
for spec, lo, hi in [("bytes=100000-200000", 100000, 200000), ("bytes=-70000", len(blob) - 70000, len(blob) - 1), ("bytes=307000-", 307000, len(blob) - 1)]:
    r, body = get("/blob.bin", {"Range": spec})
    check(r.status == 206 and body == blob[lo:hi + 1] and r.getheader("Content-Range") == f"bytes {lo}-{hi}/{len(blob)}", f"{spec}: {r.status} {len(body)} {r.getheader('Content-Range')}")
r, body = get("/blob.bin", {"If-None-Match": tag})
check(r.status == 304 and body == b"", f"304: {r.status}")
r, body = get("/blob.bin", {"If-Modified-Since": email.utils.formatdate(mtime + 60, usegmt=True)})
check(r.status == 304, f"304 by date: {r.status}")
r, body = get("/blob.bin", {"If-Modified-Since": email.utils.formatdate(mtime - 60, usegmt=True)})
check(r.status == 200 and body == blob, f"modified since: {r.status}")
r, body = get("/blob.bin", method="HEAD")
check(r.status == 200 and body == b"" and r.getheader("Content-Length") == str(len(blob)), "HEAD")
r, body = get("/style.css")
check(body == b"body { color: red }" and r.getheader("Content-Type") == "text/css; charset=utf-8", r.getheader("Content-Type"))
r, body = get("/sub")
check(r.status == 301 and r.getheader("Location") == "/sub/", f"redirect: {r.status} {r.getheader('Location')}")
r, body = get("/sub/")
check(r.status == 200 and body == b"<p>sub</p>", f"index: {r.status} {body!r}")
r, body = get("/missing")
check(r.status == 404, f"missing: {r.status}")
get("/stop")
print("  a 300 KB file whole and in three ranges, 304 by tag and by date, HEAD, a type, a directory, 404" if not bad else "  Python disagrees")
sys.exit(1 if bad else 0)
PY
  then
    wait "$serve_pid"
  else
    kill "$serve_pid" 2>/dev/null
    status=1
  fi
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
src = Path("$REPO/src/std/fileserver.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/fileserver.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_fileserver_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a .. segment followed out of the root" "stays inside the root" \
  'return not_found if segment == ".."' ''
# A NUL reaches the file system's own refusal, a panic, and the block's
# connection ends with no answer.
prove_broken "a NUL let into a path" "the server closed mid-response" \
  'return not_found if decoded.includes?("\0") || decoded.includes?("\\")' ''
prove_broken "a range past the end served" "a range past the end is 416" \
  'return true if first >= size' ''
prove_broken "a suffix range read from the front" "bytes=-3" \
  'return {size - count, size - 1_i64}' 'return {0_i64, count - 1_i64}'
prove_broken "If-None-Match ignored" "If-None-Match, weakly compared" \
  'return Response.new(304, "", headers) if none.strip == "*" || FileServer.tag_listed?(none, tag)' ''
prove_broken "If-Modified-Since read before If-None-Match" "If-None-Match goes before If-Modified-Since" \
  '    elsif since = req.header("If-Modified-Since")' '    end
    if since = req.header("If-Modified-Since")'
prove_broken "a range served under another version's If-Range" "under another version" \
  'return named == tag || named == stamp' 'return true'
prove_broken "a directory served without its slash" "a directory without its slash is redirected" \
  '      unless decoded.ends_with?("/")' '      if false'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/fileserver exercise holds"
else
  echo "the std/fileserver exercise did not hold"
fi
exit $status
