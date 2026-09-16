#!/usr/bin/env bash
# Exercises `std/env`.
#
#     bash bench/std_env_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken module is
# caught, and what ENV refuses: accessing an absent key with `[]` or
# fetching an absent key without a default, each a panic with a descriptive
# sentence.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
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
export IYI_PATH="$REPO/src:$REPO/samples/iyi"
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
for phrase in "== set and get" "== absent key and defaults" "== delete and presence" "== iteration and hash"; do
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
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/env.iyi").read_text()
old = 'self[key]? != nil'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/env.iyi").write_text(src.replace(old, 'false', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_env_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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

echo
if [ "$status" -eq 0 ]; then
  echo "the std/env exercise holds"
else
  echo "the std/env exercise did not hold"
fi
exit $status
