#!/usr/bin/env bash
# Exercises `std/router`.
#
#     bash bench/std_router_exercise.sh
#
# Where a Go toolchain of 1.22 or later runs (`go` on the path, or `GO=`
# naming one), the exercise's routing tables are handed to Go's own
# `http.ServeMux` and its answers compared line for line.
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

# Go's mux is the reference, and the first that has these patterns is
# 1.22. A version manager's shim that has no version chosen answers
# `go version` with an error, so each candidate is run, not looked for.
GO_BIN=""
for candidate in "${GO:-}" go /usr/local/go/bin/go "$HOME"/.local/share/mise/installs/go/*/bin/go; do
  [ -n "$candidate" ] || continue
  minor=$("$candidate" version 2>/dev/null | sed -n 's/^go version go1\.\([0-9]*\).*/\1/p')
  if [ -n "$minor" ] && [ "$minor" -ge 22 ]; then
    GO_BIN="$candidate"
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_router_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  # The refusals the exercise provokes on purpose print their panic as it
  # happens; the exercise checks each sentence itself.
  grep -v '^iyi: panic: Router: ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/router exercise, plain build"
build_and_run "plain" router-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/router-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" router-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/router-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a router refuses before it serves"
refuses() { # refuses <label> <name> <phrase> <statements>
  local label="$1" name="$2" phrase="$3" statements="$4"
  printf 'module main\n\nimport std/router::{Router}\nimport std/http::{Request, Response}\n\nrouter = Router.new\n%s\nputs "registered"\n' \
    "$statements" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it registered instead of refusing"
    status=1
  elif ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
  else
    printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -oF "$phrase" "$WORK/$name.out")"
  fi
}
refuses "a conflict Go documents" conflict_doc \
  'Router: "/index.html" conflicts with "GET /": it matches more methods but a more specific path, and both match GET "/index.html"' \
  'router.handle("GET /") { |_, _| Response.new(200) }
router.handle("/index.html") { |_, _| Response.new(200) }'
refuses "two paths neither more specific" conflict_paths \
  'Router: "/{y}/b" conflicts with "/a/{x}": both match "/a/b", and neither is more specific than the other' \
  'router.handle("/a/{x}") { |_, _| Response.new(200) }
router.handle("/{y}/b") { |_, _| Response.new(200) }'
refuses "the same pattern twice" conflict_same \
  'Router: "GET /users/{name}" conflicts with "GET /users/{id}": both match the same requests' \
  'router.handle("GET /users/{id}") { |_, _| Response.new(200) }
router.handle("GET /users/{name}") { |_, _| Response.new(200) }'
refuses "a { alone" open_brace \
  'Router: "/{" is not a pattern: a wildcard is a whole segment, {name}, and "{" is not one' \
  'router.handle("/{") { |_, _| Response.new(200) }'
refuses "a wildcard name twice" duplicate_name \
  'Router: "/{id}/x/{id}" is not a pattern: two wildcards are named "id"' \
  'router.handle("/{id}/x/{id}") { |_, _| Response.new(200) }'
refuses "a rest wildcard before the end" rest_not_last \
  'Router: "/files/{path...}/raw" is not a pattern: {path...} is not at the end' \
  'router.handle("/files/{path...}/raw") { |_, _| Response.new(200) }'
refuses "a pattern after the first request" after_serving \
  'Router: "/late" is registered after the router answered a request; patterns are registered before it serves' \
  'router.handle("/") { |_, _| Response.new(200) }
router.call(Request.new("GET", "/", nil, {"Host" => "x"}, ""))
router.handle("/late") { |_, _| Response.new(200) }'

echo
echo "== Go's own ServeMux answers the same tables"
if [ -z "$GO_BIN" ]; then
  echo "  skipped: no Go toolchain of 1.22 or later"
else
  mkdir -p "$WORK/mux"
  cat > "$WORK/mux/main.go" <<'GO'
// Reads the exercise's tables - T a table, P a pattern, R a request, C two
// patterns registered in turn, V one pattern - and prints Go's answers in
// the exercise's own words. The 1.22 patterns asked for whatever the
// toolchain's default for a file outside a module would be.
//go:debug httpmuxgo121=0
package main

import (
	"bufio"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var wild = regexp.MustCompile(`\{([A-Za-z_][A-Za-z0-9_]*)(\.\.\.)?\}`)

// A handler that answers its pattern and its wildcards' values by name.
func handler(p string) http.HandlerFunc {
	names := []string{}
	for _, m := range wild.FindAllStringSubmatch(p, -1) {
		names = append(names, m[1])
	}
	sort.Strings(names)
	return func(w http.ResponseWriter, r *http.Request) {
		parts := []string{}
		for _, n := range names {
			parts = append(parts, n+"="+r.PathValue(n))
		}
		fmt.Fprint(w, p+"|"+strings.Join(parts, ","))
	}
}

func registers(f func()) (ok bool) {
	defer func() {
		if recover() != nil {
			ok = false
		}
	}()
	f()
	return true
}

func main() {
	in := bufio.NewScanner(os.Stdin)
	var mux *http.ServeMux
	table := ""
	for in.Scan() {
		kind, rest, _ := strings.Cut(in.Text(), " ")
		switch kind {
		case "T":
			table, mux = rest, http.NewServeMux()
		case "P":
			mux.Handle(rest, handler(rest))
		case "R":
			f := strings.SplitN(rest, " ", 3)
			// Read off the wire as Go's server reads it, which answers 400
			// to a target it cannot parse.
			got := "400"
			req, err := http.ReadRequest(bufio.NewReader(strings.NewReader(f[0] + " " + f[2] + " HTTP/1.1\r\nHost: " + f[1] + "\r\n\r\n")))
			if err == nil {
				rec := httptest.NewRecorder()
				mux.ServeHTTP(rec, req)
				switch rec.Code {
				case 200:
					got = rec.Body.String()
				case 301:
					got = "301 " + rec.Header().Get("Location")
				case 405:
					got = "405 " + rec.Header().Get("Allow")
				default:
					got = strconv.Itoa(rec.Code)
				}
			}
			fmt.Printf("A %s %s => %s\n", table, rest, got)
		case "C":
			newer, older, _ := strings.Cut(rest, "\t")
			m := http.NewServeMux()
			m.Handle(older, handler(older))
			got := "conflict"
			if registers(func() { m.Handle(newer, handler(newer)) }) {
				got = "ok"
			}
			fmt.Printf("A C %s => %s\n", rest, got)
		case "V":
			got := "invalid"
			if registers(func() { http.NewServeMux().Handle(rest, handler(rest)) }) {
				got = "ok"
			}
			fmt.Printf("A V %s => %s\n", rest, got)
		}
	}
}
GO
  if [ ! -x "$WORK/router-plain" ]; then
    echo "  the exercise did not build"
    status=1
  else
    "$WORK/router-plain" table > "$WORK/table.txt"
    grep -v '^A ' "$WORK/table.txt" > "$WORK/table.in"
    grep '^A ' "$WORK/table.txt" > "$WORK/table.ours"
    if ! (cd "$WORK/mux" && GOTOOLCHAIN=local GOFLAGS= "$GO_BIN" run main.go) < "$WORK/table.in" > "$WORK/table.go" 2> "$WORK/go.err"; then
      echo "  Go did not run:"
      sed -n '1,8p' "$WORK/go.err"
      status=1
    elif ! diff "$WORK/table.ours" "$WORK/table.go" > "$WORK/table.diff"; then
      echo "  Go answers differently (ours <, Go's >):"
      sed 's/^/    /' "$WORK/table.diff"
      status=1
    else
      printf '  %s (%s): %s requests, %s pairs registered in turn, %s patterns read - every answer the same\n' \
        "$("$GO_BIN" version | cut -d' ' -f3)" "$GO_BIN" \
        "$(grep -c '^R ' "$WORK/table.in")" "$(grep -c '^C ' "$WORK/table.in")" "$(grep -c '^V ' "$WORK/table.in")"
    fi
  fi
fi

echo
echo "== Python's http.client against a router served"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
else
  "$WORK/router-plain" serve > "$WORK/serve.out" 2>&1 &
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
import os, sys, http.client
c = http.client.HTTPConnection("127.0.0.1", int(os.environ["PORT"]), timeout=10)
bad = 0
def ask(method, path, body=None):
    c.request(method, path, body=body)
    r = c.getresponse()
    return r, r.read()
def check(cond, what):
    global bad
    if not cond:
        print("  FAIL:", what); bad += 1
r, body = ask("GET", "/users/J%C3%BCrgen")
check(r.status == 200 and body.decode() == "user Jürgen", f"a wildcard decoded: {r.status} {body!r}")
r, body = ask("HEAD", "/users/1")
check(r.status == 200 and body == b"" and r.getheader("Content-Length") == "6", f"HEAD of a GET pattern: {r.status} {r.getheader('Content-Length')} {body!r}")
r, body = ask("POST", "/users/1", b"x")
check(r.status == 201 and body == b"posted 1: x", f"POST: {r.status} {body!r}")
r, body = ask("DELETE", "/users/1")
check(r.status == 405 and r.getheader("Allow") == "GET, HEAD, POST", f"405: {r.status} {r.getheader('Allow')}")
r, body = ask("POST", "/")
check(r.status == 405 and r.getheader("Allow") == "GET, HEAD", f"405 for /: {r.status} {r.getheader('Allow')}")
r, body = ask("GET", "/static")
check(r.status == 301 and r.getheader("Location") == "/static/", f"301: {r.status} {r.getheader('Location')}")
r, body = ask("GET", "/static?x=1")
check(r.status == 301 and r.getheader("Location") == "/static/?x=1", f"301 with a query: {r.getheader('Location')}")
r, body = ask("HEAD", "/static")
check(r.status == 301 and r.getheader("Location") == "/static/" and body == b"", f"HEAD redirected: {r.status}")
r, body = ask("GET", "/static/a/b")
check(r.status == 200 and body == b"static /static/a/b", f"a subtree: {body!r}")
r, body = ask("GET", "/a/../users/2")
check(r.status == 301 and r.getheader("Location") == "/users/2", f"a path cleaned: {r.status} {r.getheader('Location')}")
r, body = ask("GET", "/")
check(r.status == 200 and body == b"home", f"/{{$}}: {body!r}")
r, body = ask("GET", "/missing")
check(r.status == 404, f"404: {r.status}")
r, body = ask("GET", "/%zz")
check(r.status == 400, f"400: {r.status}")
ask("GET", "/stop")
print("  a wildcard decoded, HEAD of a GET pattern, POST, two 405s with Allow, three 301s, a cleaned path, {$}, 404, 400" if not bad else "  Python disagrees")
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
src = Path("$REPO/src/std/router.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/router.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_router_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -F "ASSERTION FAILED" "$WORK/mut.out" | grep -qF "$2"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    grep -m1 -A2 "ASSERTION FAILED" "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "GET not taking HEAD" "routed HEAD any.example /static/app.js" \
  '@method.empty? || @method == method || (@method == "GET" && method == "HEAD")' '@method.empty? || @method == method'
prove_broken "the first match taken, not the most specific" "routed GET example.com /" \
  '(chosen < 0 || pattern.more_specific?(@patterns[chosen]))' '(chosen < 0)'
prove_broken "a host's pattern compared with the rest" "routed GET example.com /index.html" \
  'if pattern.host == host && pattern.matches_method?(method)' 'if (pattern.host == host || pattern.host.empty?) && pattern.matches_method?(method)'
prove_broken "an overlap taken as no conflict" "/index.html beside GET / conflicts" \
  'second == inverse ? OVERLAPS : second' 'second'
prove_broken "GET's requests not counted among HEAD's" "GET /a/b beside HEAD /a/{x} conflicts too" \
  'return MORE_GENERAL if @method == "GET" && other.method == "HEAD"' 'return DISJOINT if @method == "GET" && other.method == "HEAD"'
prove_broken "{x} matching the end {\$} matches" "/{x} beside /{\$}: relation" \
  'return (their_kind == ENDS ? DISJOINT : MORE_GENERAL) if kind == WILD' 'return MORE_GENERAL if kind == WILD'
prove_broken "{x} matching an empty segment" "no rest past the end, no empty segment" \
  '        return nil if piece.empty?
' ''
prove_broken "a subtree's root not redirected" "routed GET any.example /static" \
  'if (again = find(host, req.method, slashed)) && @patterns[again[0]].exact?(slashed)' 'if false'
prove_broken "an unclean path routed as it is" "routed GET any.example /a/../index.html" \
  '    return Router.redirect(path, req.query) unless path == raw
' ''
prove_broken "Allow without HEAD" "routed PATCH any.example /items/7" \
  'methods << "HEAD" if methods.includes?("GET") && !methods.includes?("HEAD")' ''
prove_broken "wildcard values left encoded" "a pattern's wildcards" \
  '      decoded = URI.decode?(segment)
      return nil unless decoded
      pieces << decoded' '      pieces << segment'
prove_broken "a wildcard name used twice" "the pattern \"/{id}/{id}\"" \
  'return refused(text, "two wildcards are named #{name.inspect}") if seen.includes?(name)' ''
prove_broken "a rest wildcard taken before the end" "the pattern \"/{x...}/a\"" \
  'return refused(text, "{#{name}...} is not at the end") if multi && stop != size' ''
prove_broken "a pattern after the first request taken" "a pattern after the first request is refused" \
  'raise "Router: #{pattern.inspect} is registered after the router answered a request; patterns are registered before it serves" if @answering' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/router exercise holds"
else
  echo "the std/router exercise did not hold"
fi
exit $status
