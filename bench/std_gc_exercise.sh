#!/usr/bin/env bash
# Exercises `std/gc`: the program's window onto iyi's own collector.
#
#     bash bench/std_gc_exercise.sh
#
# Proves:
#   * bench/std_gc_exercise.iyi passes plain and --release: raw words, heap
#     pointers, stats that move with the collector, disable/enable.
#   * A build with -Dgc_none is refused at compile time with the module's
#     sentence, not with an undefined name from the missing collector.
#   * A negative size is refused by name at every allocating verb.
#   * Negative proofs: copies of the module that report a constant
#     collection count, that leave the trigger on under `disable`, and that
#     answer false for every heap pointer each fail at the named check.
#
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/gc exercise, plain build"
build_and_run "std_gc" exercise-gc "$REPO/bench/std_gc_exercise.iyi"

echo
echo "== every gc check reported"
for check in "raw words" "heap pointers" "stats move with the collector" "disable holds the trigger" "ALL CHECKS PASSED"; do
  if ! grep -q "$check" "$WORK/exercise-gc.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  raw words, heap pointers, stats and disable/enable all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_gc --release" exercise-gc-release "$REPO/bench/std_gc_exercise.iyi" --release >/dev/null
if grep -q "ALL CHECKS PASSED" "$WORK/exercise-gc-release.out" 2>/dev/null; then
  echo "  every check holds under --release"
else
  echo "  release: missing pass sentinel"
  status=1
fi

# ---------------------------------------------------------------------------
# The compile-time refusal under -Dgc_none
# ---------------------------------------------------------------------------

echo
echo "== a -Dgc_none build is refused with a sentence"
if "$IYI" build -Dgc_none -o "$WORK/gc-none" "$REPO/bench/std_gc_exercise.iyi" >"$WORK/gc-none.log" 2>&1; then
  echo "  the module BUILT under -Dgc_none (it should have refused)"
  status=1
elif grep -q "^Error: std/gc speaks for iyi's own collector, and -Dgc_none builds without one" "$WORK/gc-none.log"; then
  echo "  refused at compile time: $(grep -m1 '^Error: std/gc speaks' "$WORK/gc-none.log" | sed 's/^Error: //')"
else
  echo "  the build failed, but not with the module's sentence:"
  tail -5 "$WORK/gc-none.log" | sed 's/^/    /'
  status=1
fi

# ---------------------------------------------------------------------------
# What the allocating verbs refuse
# ---------------------------------------------------------------------------

echo
echo "== a negative size is refused by name"
gc_panics_with() { # gc_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/gc\nusing std/gc::{GC}\n\nputs (%s).address\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
gc_panics_with "malloc of -1" malloc_neg "negative size: -1" 'GC.malloc(-1)'
gc_panics_with "malloc_atomic of -8" atomic_neg "negative size: -8" 'GC.malloc_atomic(-8)'
gc_panics_with "realloc to -64" realloc_neg "negative size: -64" 'GC.realloc(GC.malloc(8), -64)'

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== proving the checks can fail when the module is broken"
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/gc.iyi" > "$WORK/$dir/std/gc.iyi"
  if cmp -s "$REPO/src/std/gc.iyi" "$WORK/$dir/std/gc.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_gc_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check ('$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

prove_fails "collections reported as a constant" const_collections "churn crossed the trigger" \
  's/IyiMark.bytes_kept, IyiMark.collections)/IyiMark.bytes_kept, 0_u64)/'
prove_fails "disable leaves the trigger on" disable_noop "no collection ran while disabled" \
  's/IyiMark.auto = false/IyiMark.auto = true/'
prove_fails "is_heap_ptr answers false for every pointer" never_heap "a chunk's start is a heap pointer" \
  's/IyiRoots.base_of(pointer.address) != 0_u64/IyiRoots.base_of(pointer.address) == 18446744073709551615_u64/'
prove_fails "free does nothing" free_noop "a freed chunk is not" \
  's/    IyiHeap.free(pointer)/    pointer/'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/gc exercise holds"
else
  echo "the std/gc exercise did not hold"
fi
exit $status
