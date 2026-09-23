#!/usr/bin/env bash
# Exercises `std/option_parser`.
#
#     bash bench/std_option_parser_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_option_parser_exercise.iyi" \
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

echo "== the std/option_parser exercise, plain build"
build_and_run "plain" option_parser-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/option_parser-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every option_parser section reported"
for phrase in "== flags"; do
  if ! grep -q "$phrase" "$WORK/option_parser-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" option_parser-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/option_parser-release.out" 2>/dev/null; then
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
src = Path("$REPO/src/std/option_parser.iyi").read_text()
old = 'spec[1].call(args[i])'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/option_parser.iyi").write_text(src.replace(old, 'spec[1].call("")', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_option_parser_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken option_parser is caught"
  fi

  # The handler set and not called: the mistake panics anyway.
  mkdir -p "$WORK/unheard/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/option_parser.iyi").read_text()
old = '    raise sentence unless handler\n    handler.call(flag)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/unheard/std/option_parser.iyi").write_text(src.replace(old, '    raise sentence', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the unheard-handler patch did not apply"
    status=1
  elif IYI_PATH="$WORK/unheard${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_option_parser_exercise.iyi" >"$WORK/unheard.out" 2>&1; then
    echo "  the exercise PASSED with invalid_option never called"
    status=1
  elif grep -q "unknown flag: --nope" "$WORK/unheard.out"; then
    echo "  a handler that is never called is caught"
  else
    echo "  the unheard handler failed, but not at the first mistake"
    tail -3 "$WORK/unheard.out" | sed 's/^/    /'
    status=1
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/option_parser exercise holds"
else
  echo "the std/option_parser exercise did not hold"
fi
exit $status
