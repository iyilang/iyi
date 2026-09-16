#!/usr/bin/env bash
# Exercises `std/steppable`.
#
#     bash bench/std_steppable_exercise.sh
#
# Proves the exercise holds plain and --release, that all sections report,
# and proves the checks can fail when the module is broken:
# a broken step calculation, an ignored exclusive boundary, an unchecked
# step direction, and a broken block-iterator trait default.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"
export PATH="/opt/homebrew/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_steppable_exercise.iyi" \
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

echo "== the std/steppable exercise, plain build"
build_and_run "plain" steppable-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/steppable-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every steppable section reported"
for phrase in \
  "== forward stepping and step of one" \
  "== step not dividing span evenly" \
  "== backward stepping with negative step" \
  "== single-element spans and boundaries" \
  "== zero step and direction mismatches" \
  "== open-ended stepping without limit" \
  "== block iteration from trait default" \
  "== iterator sum and std/iterator integration"; do
  if ! grep -q "$phrase" "$WORK/steppable-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" steppable-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/steppable-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"

prove_fails() {
  local label="$1" dir="$2" old_pat="$3" new_pat="$4"
  mkdir -p "$WORK/$dir/std"
  python3 - <<PY
from pathlib import Path
import sys
src = Path("$REPO/src/std/steppable.iyi").read_text()
old = """$old_pat"""
if old not in src:
    sys.stderr.write(f"patch site missing for {sys.argv}\n")
    sys.exit(2)
Path("$WORK/$dir/std/steppable.iyi").write_text(src.replace(old, """$new_pat""", 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if IYI_PATH="$WORK/$dir:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_steppable_exercise.iyi" >"$WORK/$dir.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label: caught broken implementation"
  fi
}

prove_fails "step arithmetic" mut1 "next_val = @current + @step" "next_val = @current + @step + @step"
prove_fails "exclusive boundary check" mut2 "if cmp > 0 || (cmp == 0 && @exclusive)" "if cmp > 0"
prove_fails "step direction validation" mut3 "if sign != step_sign" "if false"
prove_fails "trait block iteration default" mut4 "yield item" "nil"

echo
if [ "$status" -eq 0 ]; then
  echo "std/steppable: all checks passed plain and release, failure modes proven"
else
  echo "std/steppable: exercise failed"
fi
exit $status
