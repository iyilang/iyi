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
#     answer false for every heap pointer each fail at the named check; one
#     whose `stats` walks without the runtime lock, and one whose
#     `is_heap_ptr` does, each die of a memory fault.
#
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

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

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

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
for check in "raw words" "heap pointers" "stats move with the collector" "disable holds the trigger" "a string built in a reused chunk ends in a NUL" "stats beside threads that allocate" "is_heap_ptr beside threads whose large chunks come and go" "ALL CHECKS PASSED"; do
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

echo
echo "== a bare import is told how to reach the module's GC"
# `import std/gc` keeps the module's names qualified (SPEC.md R-2b), so a
# bare `GC` is the prelude's own. `GC.collect` was told "iyi's prelude has
# no `collect` on GC:Module: it is small by rule" and pointed at
# `iyi build --crystal`, with the module's `GC` one import away.
printf 'import std/gc\nGC.collect\nputs 1\n' > "$WORK/bare-import.iyi"
if "$IYI" check "$WORK/bare-import.iyi" >"$WORK/bare-import.log" 2>&1; then
  echo "  the bare import type-checked (it should have been told to import GC)"
  status=1
elif grep -qF 'Import it by name, `import std/gc::{GC}`' "$WORK/bare-import.log"; then
  echo '  told: "Import it by name, `import std/gc::{GC}`"'
else
  echo "  refused, but without the import:"
  tail -5 "$WORK/bare-import.log" | sed 's/^/    /'
  status=1
fi

# ---------------------------------------------------------------------------
# What the allocating verbs refuse
# ---------------------------------------------------------------------------

echo
echo "== a negative size is refused by name"
gc_panics_with() { # gc_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/gc::{GC}\n\nputs (%s).address\n' "$expression" > "$WORK/$name.iyi"
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
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script> [runs]
  local label="$1" dir="$2" phrase="$3" script="$4" runs="${5:-1}"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/gc.iyi" > "$WORK/$dir/std/gc.iyi"
  if cmp -s "$REPO/src/std/gc.iyi" "$WORK/$dir/std/gc.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_gc_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  # A race is run until it is caught, up to *runs* times.
  local run=1 exit_code=0
  while [ "$run" -le "$runs" ]; do
    "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
    exit_code=$?
    [ "$exit_code" -ne 0 ] && break
    run=$((run + 1))
  done
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed in $runs run(s), so it does not test this"
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
  's/^    base != 0_u64$/    base == 18446744073709551615_u64/'
prove_fails "free does nothing" free_noop "a freed chunk is not" \
  's/    IyiHeap.free(pointer)/    pointer/'
# Three threads allocate beside two seconds of `stats`: walked without the
# lock, the walk died of a memory fault in 20 runs of 20 on Windows, where a
# released arena is unmapped as the scavenge ends. `is_heap_ptr` beside
# three threads whose large chunks come and go died the same way in 10 runs
# of 10. A Linux runner's walk without the lock passed: the race is the
# platform's to arrange, so the proofs run where they were measured.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # Races: 20 in 20 and 10 in 10 where measured, and one Windows runner
    # once ran the second clean, so each runs up to five times.
    prove_fails "stats walks without the lock" stats_unlocked "memory fault" \
      '/def self.stats/,/^  end/{/^    IyiHeap\.lock$/d; /^    IyiHeap\.unlock$/d}' 5
    prove_fails "is_heap_ptr walks without the lock" is_heap_unlocked "memory fault" \
      '/def self.is_heap_ptr/,/^  end/{/^    IyiHeap\.lock$/d; /^    IyiHeap\.unlock$/d}' 5
    ;;
  *)
    echo "  stats and is_heap_ptr walking without the lock: not proven here, the races were measured on Windows"
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "the std/gc exercise holds"
else
  echo "the std/gc exercise did not hold"
fi
exit $status
