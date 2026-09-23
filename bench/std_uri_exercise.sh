#!/usr/bin/env bash
# Exercises `std/uri`: RFC 3986 parse of scheme, host and path.
#
#     bash bench/std_uri_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_uri_exercise.iyi" \
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

echo "== the std/uri exercise, plain build"
build_and_run "plain" uri-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/uri-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every uri section reported"
for phrase in "== parse" "== refuse"; do
  if ! grep -q "$phrase" "$WORK/uri-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" uri-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/uri-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/uri.iyi").read_text()
old = '        uri.host = host\n      end'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/uri.iyi").write_text(src.replace(old, '        # uri.host = host\n      end', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_uri_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken uri is caught"
  fi

  # The form reading made strict again: the query panics at its first
  # malformed escape.
  mkdir -p "$WORK/strict/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/uri.iyi").read_text()
old = '              params.add(URI.decode_form_lenient(raw_k), URI.decode_form_lenient(raw_v))'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/strict/std/uri.iyi").write_text(src.replace(old, '              params.add(URI.decode_www_form(raw_k), URI.decode_www_form(raw_v))', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the strict-form patch did not apply"
    status=1
  elif IYI_PATH="$WORK/strict${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_uri_exercise.iyi" >"$WORK/strict.out" 2>&1; then
    echo "  the exercise PASSED with a form reading that panics"
    status=1
  elif grep -q "malformed percent escape" "$WORK/strict.out"; then
    echo "  a form reading that panics is caught"
  else
    echo "  the strict form failed, but not at its escape"
    tail -3 "$WORK/strict.out" | sed 's/^/    /'
    status=1
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/uri exercise holds"
else
  echo "the std/uri exercise did not hold"
fi
exit $status
