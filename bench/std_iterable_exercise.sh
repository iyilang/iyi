#!/usr/bin/env bash
# Exercises `std/iterable`.
#
#     bash bench/std_iterable_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken iterable is
# caught, that empty, single-element, and multi-element sources hold across
# all defaults, that short-circuiting and full-consumption combinators
# behave correctly, and what `each_step` refuses: a non-positive step size
# and a negative offset.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_iterable_exercise.iyi" \
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

echo "== the std/iterable exercise, plain build"
build_and_run "plain" iterable-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/iterable-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every iterable section reported"
for phrase in "== empty source" "== one-element source" "== multi-element source" "== combinator proofs: short-circuit and full consumption"; do
  if ! grep -q "$phrase" "$WORK/iterable-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" iterable-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/iterable-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/iterable.iyi").read_text()
old = 'def cycle(n : Int32)\n    each.cycle(n)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/iterable.iyi").write_text(src.replace(old, 'def cycle(n : Int32)\n    each.cycle(n + 1)', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_iterable_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken iterable is caught"
fi

echo
echo "== what each_step refuses"
refuses() { # refuses <label> <name> <phrase> <statement>
  local label="$1" name="$2" phrase="$3" stmt="$4"
  cat <<IYI > "$WORK/$name.iyi"
module main

import std/iterator
using std/iterator::{Iterator, ArrayIterator}

import std/iterable
using std/iterable::{Iterable}

pub struct Seq(T)
  @data : Array(T)

  def initialize(@data : Array(T))
  end
end

impl Iterable for Seq(T) forall T
  type Iter = ArrayIterator(T)

  def each : ArrayIterator(T)
    Iterator.of(@data)
  end
end

s = Seq(Int32).new([1, 2, 3])
$stmt
IYI
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
refuses "a non-positive step (zero)" step_zero "step size must be positive" "s.each_step(0)"
refuses "a non-positive step (negative)" step_neg "step size must be positive" "s.each_step(-1)"
refuses "a negative offset" offset_neg "negative count: -1" "s.each_step(1, offset: -1)"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/iterable exercise holds"
else
  echo "the std/iterable exercise did not hold"
fi
exit $status
