#!/usr/bin/env bash
# Exercises `std/cookie`.
#
#     bash bench/std_cookie_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/end_process.sh"

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
refuses "a path with an attribute after it" path_semi 'Cookie: sid has a byte a cookie path cannot hold: "/; Domain=evil.example"' \
  'Cookie.new("sid", "abc", path: "/; Domain=evil.example").to_set_cookie'
refuses "a domain with an attribute after it" domain_semi 'Cookie: a has a domain that is not a host name: "example.com; Secure"' \
  'Cookie.new("a", "1", domain: "example.com; Secure").to_set_cookie'
refuses "a SameSite with an attribute after it" same_semi 'Cookie: a has a SameSite that is not Strict, Lax or None: "None; Domain=evil.example"' \
  'Cookie.new("a", "1", same_site: "None; Domain=evil.example").to_set_cookie'

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
    end_process "$serve_pid"
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
    end_process "$serve_pid"
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
prove_broken "a cookie sent to any host under its domain's name" "a jar keeps three of seven" \
  'return false unless host.ends_with?("." + domain)' ''
prove_broken "a cookie path matched inside a name" "a path matches at a slash" \
  'cookie.ends_with?("/") || request.to_unsafe[cookie.bytesize] == 47_u8' 'true'
prove_broken "a Secure cookie sent over http" "a Secure cookie not over http" \
  'next if cookie.secure && !secure' ''
prove_broken "a Secure cookie taken from an http answer" "a jar keeps three of seven" \
  'return if cookie.secure && !secure' ''
prove_broken "a Secure cookie kept from https:// as well" "a Secure cookie from https:// goes back over https://" \
  'next if cookie.secure && !secure' 'next if cookie.secure'
prove_broken "a one-label Domain kept" "a jar keeps three of seven" \
  'return unless domain.includes?(".") && CookieJar.domain_match?(host, domain)' 'return unless CookieJar.domain_match?(host, domain)'
prove_broken "Expires read before Max-Age" "Max-Age wins over Expires" \
  "    if age = max_age
      expires" "    if (age = max_age) && expires.nil?
      expires"
prove_broken "a lapsed cookie kept" "a jar keeps three of seven" \
  '    return if stored.expired?(now)
' ''
prove_broken "paths sent in the order they were set" "the longer path first" \
  'long_a == long_b ? (a[1] < b[1] ? -1 : (a[1] > b[1] ? 1 : 0)) : (long_a > long_b ? -1 : 1)' '(a[1] < b[1] ? -1 : (a[1] > b[1] ? 1 : 0))'
prove_broken "a quoted value written as it is" "cookie value cannot hold" \
  'unless c == 0x21_u8 ||' 'unless true ||'
prove_broken "a Secure cookie overwritten by an http answer" "an http answer does not overwrite a Secure cookie" \
  '    return if !secure && secure_kept?(cookie.name, scope, path, now)
' ''
prove_broken "a Secure cookie shadowed from a domain above its host" "nor set one for a domain its host is under" \
  '(CookieJar.domain_match?(scope, held) || CookieJar.domain_match?(held, scope))' 'CookieJar.domain_match?(scope, held)'
prove_broken "a Secure cookie shadowed from a host under its domain" "nor set one from a host under its domain" \
  '(CookieJar.domain_match?(scope, held) || CookieJar.domain_match?(held, scope))' 'CookieJar.domain_match?(held, scope)'
prove_broken "a Secure cookie shadowed from a longer path" "nor set one of a longer path to go beside it" \
  'CookieJar.path_match?(path, other.path || "/")' 'path == (other.path || "/")'
prove_broken "a lapsed Secure cookie guarding its name" "a Secure cookie that has lapsed guards nothing" \
  'other.secure && other.name == name && !other.expired?(now) &&' 'other.secure && other.name == name &&'
prove_broken "an http answer kept from every name beside a Secure cookie" "an http answer still sets a cookie of another name" \
  'other.secure && other.name == name &&' 'other.secure &&'
prove_broken "an https answer kept from a Secure cookie too" "an https answer still replaces a Secure cookie" \
  'return if !secure && secure_kept?' 'return if secure_kept?'
prove_broken "a __Secure- cookie taken without Secure" "a __Secure- cookie needs Secure" \
  '      return unless cookie.secure
' ''
prove_broken "a __Host- cookie taken without Secure" "a __Host- cookie needs Secure" \
  'if host_only || CookieJar.prefixed?(cookie.name, "__secure-")' 'if CookieJar.prefixed?(cookie.name, "__secure-")'
prove_broken "a __Host- cookie taken with a Domain" "a __Host- cookie has no Domain" \
  'return if host_only && !(cookie.domain.nil? && cookie.path == "/")' 'return if host_only && !(cookie.path == "/")'
prove_broken "a __Host- cookie taken with another Path" "a __Host- cookie has Path=/" \
  'return if host_only && !(cookie.domain.nil? && cookie.path == "/")' 'return if host_only && !cookie.domain.nil?'
prove_broken "a __Host- cookie taken with no Path written" "and has it written out" \
  'return if host_only && !(cookie.domain.nil? && cookie.path == "/")' 'return if host_only && !(cookie.domain.nil? && (cookie.path || "/") == "/")'
prove_broken "a prefix read in its usual case alone" "a prefix is read in any case" \
  'c = c | 32_u8 if c >= 65_u8 && c <= 90_u8' 'c = c | 32_u8 if c == 72_u8 || c == 83_u8'
prove_broken "a prefix found anywhere in a name" "a name that holds a prefix further in" \
  'host_only = CookieJar.prefixed?(cookie.name, "__host-")' 'host_only = cookie.name.downcase.includes?("__host-")'
prove_broken "a path written with a semicolon in it" "a path with a semicolon refused" \
  'if c < 0x20_u8 || c == 0x3B_u8 || c >= 0x7F_u8' 'if c < 0x20_u8 || c >= 0x7F_u8'
prove_broken "a path written with a control byte in it" "a path with a control byte refused" \
  'if c < 0x20_u8 || c == 0x3B_u8 || c >= 0x7F_u8' 'if c == 0x3B_u8 || c >= 0x7F_u8'
prove_broken "a path written with a delete byte in it" "a path with a delete byte refused" \
  'if c < 0x20_u8 || c == 0x3B_u8 || c >= 0x7F_u8' 'if c < 0x20_u8 || c == 0x3B_u8 || c >= 0x80_u8'
prove_broken "a path written with a byte outside ASCII in it" "a path outside ASCII refused" \
  'if c < 0x20_u8 || c == 0x3B_u8 || c >= 0x7F_u8' 'if c < 0x20_u8 || c == 0x3B_u8 || c == 0x7F_u8'
prove_broken "a domain written as it is" "a domain with a semicolon refused" \
  'unless DnsName.valid?(host)' 'unless true'
prove_broken "a domain's leading dot refused" "a domain's one leading dot written" \
  'unless DnsName.valid?(host)' 'unless DnsName.valid?(domain)'
prove_broken "a SameSite written as it is" "a SameSite with a semicolon refused" \
  'unless HTTP.same_name?(same, "Strict") ||' 'unless true ||'
prove_broken "a SameSite read in one case alone" "a SameSite in any case written" \
  'HTTP.same_name?(same, "Lax")' 'same == "Lax"'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/cookie exercise holds"
else
  echo "the std/cookie exercise did not hold"
fi
exit $status
