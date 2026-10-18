#!/usr/bin/env bash
# Exercises `std/http_proxy`: HTTPProxy.from_env, the proxy variables read
# from the environment, against Python's urllib.request.
#
#     bash bench/std_http_proxy_exercise.sh
#
# The rules the values are read by - NO_PROXY's domains, addresses, ranges
# and ports, against Go's net/http - are std/http's `proxy_for`, held by
# bench/std_http_exercise.sh; this gate holds which variable is read.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_http_proxy_exercise.iyi" \
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

echo "== the std/http_proxy exercise, plain build"
build_and_run "plain" proxy-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/proxy-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every http_proxy section reported"
for phrase in "== which name wins" "== HTTP_PROXY under CGI (httpoxy)" "== NO_PROXY from the environment"; do
  if ! grep -q "$phrase" "$WORK/proxy-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" proxy-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/proxy-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what the module reaches"
# std/http's reach and the environment: std/env, and std/http, which
# reaches no environment of its own.
imports=$(grep -oE '^import std/[a-z_0-9]+' "$REPO/src/std/http_proxy.iyi" | sed 's/^import //' | sort | tr '\n' ' ')
if [ "$imports" = "std/env std/http " ] && ! grep -qE '^import std/env' "$REPO/src/std/http.iyi"; then
  echo "  std/env and std/http, and std/http does not import std/env"
else
  echo "  std/http_proxy imports $imports, or std/http imports std/env"
  status=1
fi

echo
echo "== every case against Python's urllib.request"
# Each case the exercise printed, its variables set alone in a clean
# environment for Python's `getproxies_environment` (the variable read)
# and `proxy_bypass_environment` (NO_PROXY, for the plain host names these
# cases use, where its rule and Go's agree), and what it answered for
# http://example.com/ and https://example.com/ compared. Python's
# environment on Windows folds every name to capitals, so there its
# reading is not the one this module takes, and the comparison is not run.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) windows=1 ;;
  *) windows=0 ;;
esac
if [ -z "$PY" ]; then
  echo "  skipped: no working python3"
elif [ "$windows" -eq 1 ]; then
  echo "  skipped on Windows: Python's environment folds names to capitals"
else
  cat > "$WORK/compare.py" <<'PY'
import os, sys, urllib.request
cases = differ = 0
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.startswith("case: "):
        continue
    pairs, said = line[len("case: "):].rstrip("\n").split(" -> ")
    os.environ.clear()
    for pair in pairs.split():
        name, _, value = pair.partition("=")
        os.environ[name] = value
    proxies = urllib.request.getproxies_environment()
    answers = []
    for scheme in ("http", "https"):
        chosen = proxies.get(scheme)
        if not chosen or urllib.request.proxy_bypass_environment("example.com", proxies):
            answers.append(f"{scheme}=direct")
        else:
            answers.append(f"{scheme}={chosen if '://' in chosen else 'http://' + chosen}")
    cases += 1
    if " ".join(answers) != said:
        differ += 1
        print(f"  FAIL: {pairs or '(none)'}: Python {' '.join(answers)}, iyi {said}")
if differ == 0:
    print(f"  {cases} cases: every one answered as Python {sys.version.split()[0]} answers it")
sys.exit(1 if differ or cases == 0 else 0)
PY
  if ! "$PY" "$WORK/compare.py" "$WORK/proxy-plain.out"; then
    status=1
  fi
fi

# Each rule undone in a copy: the exercise must fail at the check written
# for it - not at an earlier one, and not by failing to compile.
echo
echo "== proving the checks can fail when the module is broken"
mutations=0
broken() { # broken <label> <old> <new> <phrase>
  # A binary of its own each: on Windows the last one's file can still be
  # held a moment after it ended, and the next link over it failed with
  # LNK1104.
  mutations=$((mutations + 1))
  local label="$1" phrase="$4"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the broken-module proof is unmeasured"
    return
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$2" NEW="$3" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/http_proxy.iyi").read_text()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/http_proxy.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_http_proxy_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations.bin" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '1,4p' "$WORK/mut.out"
    status=1
  else
    echo "  $label: caught"
  fi
}
# Where a name has no case (Windows) the cases that set a name both ways
# cannot be set up, so the two breaks only they see go unasked there, and
# the CGI rule is the one that drops both names.
if [ "$windows" -eq 1 ]; then
  echo "  the name in capitals read first: unasked on Windows, where the names are one"
  echo "  a lower-case name set to nothing passed over: unasked on Windows, where the names are one"
  broken "HTTP_PROXY read under CGI" 'if cgi && HTTPProxy.folded?' 'if false' "ASSERTION FAILED: HTTP_PROXY is not read under CGI"
else
  broken "the name in capitals read first" 'if value = ENV[lower]?
      return value.empty? ? nil : value
    end
    return nil unless capitals
    value = ENV[lower.upcase]?' 'if value = ENV[lower.upcase]?
      return value.empty? ? nil : value
    end
    return nil unless capitals
    value = ENV[lower]?' "ASSERTION FAILED: the lower-case name wins"
  broken "a lower-case name set to nothing passed over" '      return value.empty? ? nil : value' '      return value unless value.empty?' "ASSERTION FAILED: a lower-case name set to nothing wins too"
  broken "HTTP_PROXY read under CGI" 'variable("http_proxy", !cgi)' 'variable("http_proxy", true)' "ASSERTION FAILED: HTTP_PROXY is not read under CGI"
fi
broken "HTTPS_PROXY dropped under CGI too" 'variable("https_proxy", true)' 'variable("https_proxy", !cgi)' "ASSERTION FAILED: HTTPS_PROXY still is under CGI"
broken "NO_PROXY not read" 'variable("no_proxy", true))' 'nil)' "ASSERTION FAILED: NO_PROXY names the host"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/http_proxy exercise holds"
else
  echo "the std/http_proxy exercise did not hold"
fi
exit $status
