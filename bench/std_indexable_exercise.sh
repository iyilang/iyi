#!/usr/bin/env bash
# Exercises the Indexable trait and proves its checks can fail.
#
#   bash bench/std_indexable_exercise.sh
#
# Verifies:
#   1. Complete Indexable surface on prelude Array(T) and MinimalSeq(T).
#   2. MinimalSeq implements ONLY size and unsafe_fetch, receiving Indexable
#      defaults and satisfying Enumerable without defining def each.
#   3. Negative index resolution wraps from the end (e.g. a[-1]).
#   4. Out-of-bounds positive and negative indexing raises.
#   5. Empty collection handling for boundary methods.
#   6. Release build with optimizations.
#   7. Failure proofs using patched copies via IYI_PATH.
#
# Exits non-zero if any check fails.

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

status=0

# Ensure compiler and standard library paths are set. The compile cache is
# inherited rather than named here: every other driver in this directory
# inherits it, and naming one put the other language's environment variable
# into the tree where the identity floor could see it.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

echo "== the exercise, plain build"
if ! "$IYI" build -o "$WORK/exercise" "$REPO/bench/std_indexable_exercise.iyi" \
     >"$WORK/exercise.build.log" 2>&1; then
  echo "  build failed"
  sed -n '1,12p' "$WORK/exercise.build.log"
  exit 1
fi

"$WORK/exercise" >"$WORK/exercise.out" 2>&1
exit_code=$?
sed 's/^/  /' "$WORK/exercise.out"
if [ "$exit_code" -ne 0 ]; then
  echo "  exercise exited $exit_code"
  status=1
fi

if ! grep -q "all indexable checks passed" "$WORK/exercise.out" 2>/dev/null; then
  echo "  MISSING: exercise did not complete successfully"
  status=1
fi

echo
echo "== every section reported"
for section in "array surface: all passed" \
               "minimal sequence surface: all passed" \
               "empty collection handling: all passed" \
               "mutable surface: all passed"; do
  if ! grep -q "$section" "$WORK/exercise.out" 2>/dev/null; then
    echo "  MISSING: $section"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  array surface, minimal sequence, empty collection and mutable surface all reported"

echo
echo "== the same program with release optimisation"
if ! "$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/std_indexable_exercise.iyi" \
     >"$WORK/exercise-release.build.log" 2>&1; then
  echo "  optimised build failed"
  sed -n '1,12p' "$WORK/exercise-release.build.log"
  status=1
else
  "$WORK/exercise-release" >"$WORK/exercise-release.out" 2>&1
  rel_code=$?
  if [ "$rel_code" -ne 0 ]; then
    echo "  optimised exercise exited $rel_code"
    status=1
  elif ! grep -q "all indexable checks passed" "$WORK/exercise-release.out" 2>/dev/null; then
    echo "  MISSING: optimised run did not reach the end"
    status=1
  else
    echo "  optimised build passed all checks"
  fi
fi

echo
echo "== failure proofs: out-of-range and boundary raises"
# Run probe modes built into bench/std_indexable_exercise.iyi
run_probe() {
  local label="$1" mode="$2" expected_phrase="$3"
  "$WORK/exercise" "$mode" >"$WORK/probe-$mode.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: probe unexpectedly succeeded"
    status=1
    return 1
  fi
  if ! grep -q "$expected_phrase" "$WORK/probe-$mode.out" 2>/dev/null; then
    echo "  $label: failed with code $code, but missing expected phrase '$expected_phrase'"
    tail -n 4 "$WORK/probe-$mode.out" | sed 's/^/    /'
    status=1
    return 1
  fi
  printf '  %s: correctly raised panic matching "%s" (exit %s)\n' \
    "$label" "$expected_phrase" "$code"
  return 0
}

run_probe "positive index out of range" probe_positive_out_of_range "index 10 out of range for 5 elements"
run_probe "negative index out of range" probe_negative_out_of_range "index -10 out of range for 5 elements"
run_probe "trait index out of range" probe_trait_out_of_range "index 7 out of range for 5 elements"
run_probe "empty collection first" probe_empty_first "first of an empty collection"
run_probe "empty collection last" probe_empty_last "last of an empty collection"
run_probe "empty collection sample" probe_empty_sample "empty"
run_probe "update out of range" probe_update_out_of_range "index 5 out of range for 5 elements"
run_probe "swap out of range" probe_swap_out_of_range "index -6 out of range for 5 elements"
run_probe "fill negative count" probe_fill_negative_count "negative count: -1"
run_probe "fill past the end" probe_fill_past_end "index 6 out of range for 5 elements"
run_probe "insert out of range" probe_insert_out_of_range "index 2 out of range for 1 elements"
run_probe "delete_at out of range" probe_delete_at_out_of_range "index -2 out of range for 1 elements"

echo
echo "== failure proofs: checks fail when Indexable is broken"
# Proves that the exercise checks are load-bearing by running against
# a patched copy of src/std/indexable.iyi via IYI_PATH.
prove_fails() {
  local label="$1" dir="$2" expected_phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed "$sed_script" "$REPO/src/std/indexable.iyi" > "$WORK/$dir/std/indexable.iyi"

  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run \
       "$REPO/bench/std_indexable_exercise.iyi" >"$WORK/$dir.out" 2>&1; then
    local code=$?
    if grep -q "$expected_phrase" "$WORK/$dir.out" 2>/dev/null; then
      printf '  %s: caught expected failure matching "%s" (exit %s)\n' \
        "$label" "$expected_phrase" "$code"
    else
      echo "  $label: failed (exit $code) but did not match '$expected_phrase'"
      tail -n 4 "$WORK/$dir.out" | sed 's/^/    /'
      status=1
    fi
  else
    echo "  $label: exercise passed despite broken code: check does not test this"
    status=1
  fi
}

# 0. The pairs of each_cartesian with the inner loop dropped.
prove_fails "each_cartesian yields every pair" broken_cartesian "each_cartesian: every pair" \
  's/^      other.each { |b| yield a, b }$/      yield a, other[0]/'

# 1. Break negative index resolution: without wrap, a[-1] fails out of bounds
prove_fails "negative index resolution" broken_neg "assertion failed: fetch negative in bounds" \
  's/index = size + index if index < 0/# negative wrap removed/'

# 2. Break fetch default fallback: return 0 instead of default
prove_fails "fetch default fallback" broken_fetch "assertion failed: fetch out of bounds default" \
  's/default$/0/'

# 3. Break bsearch binary search: return nil unconditionally
prove_fails "bsearch binary search" broken_bsearch "assertion failed: bsearch found" \
  's/idx ? unsafe_fetch(idx) : nil/nil/'

# 4. Break values_at: skip last element
prove_fails "values_at lookup" broken_values "expected .10,50,30., got" \
  's/while i < indexes.size/while i < indexes.size - 1/'

# 5. Break rotate_in_place: the middle reversal skipped leaves the copy wrong
prove_fails "rotate_in_place reversal" broken_rotate "expected .3,2,10,101,4., got" \
  's/reverse_between(k, size - 1)/# middle reversal removed/'

# 6. Break delete_if: keep everything
prove_fails "delete_if compaction" broken_delete_if "expected .1,3,5,99., got" \
  's/unsafe_set_size(kept)/unsafe_set_size(size)/'

echo
if [ "$status" -eq 0 ]; then
  echo "Indexable: all surface methods verified, Enumerable satisfied,"
  echo "negative indices proven, and checks confirmed load-bearing."
else
  echo "Indexable: one or more checks failed."
fi

exit "$status"
