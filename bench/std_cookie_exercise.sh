#!/usr/bin/env bash
# Exercises `std/cookie`.
#
#     bash bench/std_cookie_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The patches and the peers below are python, and windows answers
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_cookie_exercise.iyi" \
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

echo "== the std/cookie exercise, plain build"
build_and_run "plain" cookie-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/cookie-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" cookie-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/cookie-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a cookie refuses before it is written"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/cookie::{Cookie}\n\nputs (%s).to_s\n' \
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
  elif ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
  else
    printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -oF "$phrase" "$WORK/$name.out")"
  fi
}
refuses "a value with a comma" value_comma 'Cookie: a has a byte a cookie value cannot hold: "1,2"' \
  'Cookie.new("a", "1,2").to_set_cookie'
refuses "a value with a quote inside" value_quote 'Cookie: a has a byte a cookie value cannot hold' \
  'Cookie.new("a", "x\"y").to_set_cookie'
refuses "a name with a semicolon" name_semi 'Cookie: not a cookie name: "a;b"' \
  'Cookie.new("a;b", "1").to_set_cookie'

echo
echo "== Python's http.cookies reads what to_set_cookie writes"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
elif ! "$WORK/cookie-plain" lines > "$WORK/lines.txt" 2>&1; then
  echo "  the lines did not print"
  status=1
elif LINES_FILE="$WORK/lines.txt" "$PY" - <<'PY'
import os, sys
from http.cookies import SimpleCookie
lines = open(os.environ["LINES_FILE"]).read().splitlines()
want = [
    ("session", "abc123", {"path": "/", "httponly": True}),
    ("theme", "dark", {"path": "/app", "max-age": "3600", "secure": True, "samesite": "Lax"}),
    ("lang", "en-US", {"domain": "example.com", "expires": "Wed, 21 Oct 2037 07:28:00 GMT"}),
]
bad = 0
for line, (name, value, attrs) in zip(lines, want):
    c = SimpleCookie()
    c.load(line)
    m = c.get(name)
    if m is None or m.value != value:
        print(f"  FAIL: {line!r} read as {c!r}"); bad += 1; continue
    for k, v in attrs.items():
        if m[k] != v:
            print(f"  FAIL: {line!r}: {k} is {m[k]!r}, not {v!r}"); bad += 1
if len(lines) != 3:
    print(f"  FAIL: {len(lines)} lines"); bad += 1
print("  three lines, every attribute read back" if not bad else "  Python read them otherwise")
sys.exit(1 if bad else 0)
PY
then
  :
else
  status=1
fi

echo
echo "== Python's cookie jar against a server that sets them"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
else
  "$WORK/cookie-plain" serve > "$WORK/serve.out" 2>&1 &
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
  elif PORT="$port" "$PY" - <<'PY'
import os, sys, urllib.request, http.cookiejar
base = f"http://127.0.0.1:{os.environ['PORT']}"
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
bad = 0
def get(path):
    return opener.open(base + path, timeout=10).read().decode()
def check(got, want, what):
    global bad
    if got != want:
        print(f"  FAIL: {what}: {got!r}, not {want!r}"); bad += 1
get("/login")
check(get("/whoami"), "s3cr3t dark -", "the session and the theme, not /deep's")
check(get("/deep/x"), "s3cr3t dark 1", "under /deep, its cookie too")
get("/logout")
check(get("/whoami"), "- dark -", "Max-Age=0 removes the session")
urllib.request.urlopen(base + "/stop", timeout=10).read()
print("  set, sent back by path, and removed by Max-Age=0" if not bad else "  Python's jar disagrees")
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
src = Path("$REPO/src/std/cookie.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/cookie.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_cookie_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a cookie sent to any host under its domain's name" "a jar keeps four of seven" \
  'return false unless host.ends_with?("." + domain)' ''
prove_broken "a cookie path matched inside a name" "a path matches at a slash" \
  'cookie.ends_with?("/") || request.to_unsafe[cookie.bytesize] == 47_u8' 'true'
prove_broken "a Secure cookie sent over http" "Secure not over http" \
  'next if cookie.secure' ''
prove_broken "a one-label Domain kept" "a jar keeps four of seven" \
  'return unless domain.includes?(".") && CookieJar.domain_match?(host, domain)' 'return unless CookieJar.domain_match?(host, domain)'
prove_broken "Expires read before Max-Age" "Max-Age wins over Expires" \
  "    if age = max_age
      expires" "    if (age = max_age) && expires.nil?
      expires"
prove_broken "a lapsed cookie kept" "a jar keeps four of seven" \
  '    return if stored.expired?(Time.utc)
' ''
prove_broken "paths sent in the order they were set" "the longer path first" \
  'long_a == long_b ? (a[1] < b[1] ? -1 : (a[1] > b[1] ? 1 : 0)) : (long_a > long_b ? -1 : 1)' '(a[1] < b[1] ? -1 : (a[1] > b[1] ? 1 : 0))'
prove_broken "a quoted value written as it is" "cookie value cannot hold" \
  'unless c == 0x21_u8 ||' 'unless true ||'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/cookie exercise holds"
else
  echo "the std/cookie exercise did not hold"
fi
exit $status
