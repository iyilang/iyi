#!/usr/bin/env bash
# Exercises `std/html`: escape and unescape.
#
#     bash bench/std_html_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_html_exercise.iyi" \
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

echo "== the std/html exercise, plain build"
build_and_run "plain" html-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/html-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every html section reported"
for phrase in "== escape" "== unescape"; do
  if ! grep -q "$phrase" "$WORK/html-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  escape and unescape reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" html-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/html-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when & is not escaped"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_amp/std"
  "$PY" - <<PY
src = open("$REPO/src/std/html.iyi").read()
old = 'bytes << 38_u8; bytes << 97_u8; bytes << 109_u8; bytes << 112_u8; bytes << 59_u8'
if old not in src:
    raise SystemExit("patch site missing")
open("$WORK/patched_amp/std/html.iyi", "w").write(src.replace(old, 'bytes << 38_u8', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_amp${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_html_exercise.iyi" >"$WORK/amp.out" 2>&1; then
    echo "  the exercise PASSED with & left raw"
    status=1
  else
    echo "  an escape that leaves & raw is caught"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/html exercise holds"
else
  echo "the std/html exercise did not hold"
fi
exit $status
