#!/usr/bin/env bash
# Exercises `std/env`.
#
#     bash bench/std_env_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken module is
# caught, and what ENV refuses: accessing an absent key with `[]` or
# fetching an absent key without a default, an empty key, a key containing
# '=', and a null byte in a key or value, each a panic with a descriptive
# sentence.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

ORIG_IYI_PATH="${IYI_PATH:-}"
cleanup() {
  rm -rf "$WORK"
  if [ -n "$ORIG_IYI_PATH" ]; then
    export IYI_PATH="$ORIG_IYI_PATH"
  else
    unset IYI_PATH
  fi
}
trap cleanup EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_env_exercise.iyi" \
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

echo "== the std/env exercise, plain build"
build_and_run "plain" env-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/env-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every env section reported"
for phrase in "== set and get" "== absent key and defaults" "== delete and presence" "== iteration and hash" "== nil assignment, empty value, positions, and Program.env"; do
  if ! grep -q "$phrase" "$WORK/env-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" env-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/env-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/env.iyi").read_text()
old = 'self[key]? != nil'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/env.iyi").write_text(src.replace(old, 'false', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_env_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken env is caught"
fi

echo
echo "== what env refuses"
refuses() { # refuses <label> <name> <phrase> <snippet>
  local label="$1" name="$2" phrase="$3" snippet="$4"
  cat <<IYI >"$WORK/$name.iyi"
module bench/refusal_$name
import std/env
using std/env::{ENV}

$snippet
IYI
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: the program did not build"
    status=1
    return
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: accepted input that should refuse"
    status=1
  elif ! grep -q "$phrase" "$WORK/$name.out" 2>/dev/null; then
    echo "  $label: failed without the expected phrase: $phrase"
    echo "  output was:"
    sed 's/^/    /' "$WORK/$name.out"
    status=1
  else
    echo "  $label: exits 1 at \"$phrase\""
  fi
}

refuses "absent key via []" absent_key "Missing ENV key: _IYI_ENV_EXERCISE_ABSENT_REFUSE" 'ENV["_IYI_ENV_EXERCISE_ABSENT_REFUSE"]'
refuses "fetch absent key without default" fetch_absent "Missing ENV key: _IYI_ENV_EXERCISE_FETCH_REFUSE" 'ENV.fetch("_IYI_ENV_EXERCISE_FETCH_REFUSE")'
refuses "empty ENV key" empty_key "ENV key is empty" 'ENV[""] = "x"'
refuses "ENV key containing =" eq_key "ENV key contains '='" 'ENV["_IYI_ENV_EXERCISE_EQ=X"] = "x"'
refuses "NUL in ENV key" nul_key "ENV key contains a null byte" 'nul = String.new(1) { |p| p[0] = 0_u8 }; ENV["K#{nul}V"] = "x"'
refuses "NUL in ENV value" nul_val "ENV value contains a null byte" 'nul = String.new(1) { |p| p[0] = 0_u8 }; ENV["_IYI_ENV_EXERCISE_NULVAL"] = "A#{nul}B"'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/env exercise holds"
else
  echo "the std/env exercise did not hold"
fi
exit $status
