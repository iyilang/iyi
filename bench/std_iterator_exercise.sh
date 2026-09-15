#!/usr/bin/env bash
# Lazy sequences, exercised and driven. Runs the iterator exercise plain and
# optimised, checks every section reported, and proves the checks can fail
# by patching copies of the iterator library via IYI_PATH.
#
#     bash bench/std_iterator_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# each capability: infinite sequence consumption, pipeline laziness, map,
# select, skip, zip, chain, and flat_map.
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

# Ensure foundation traits are present in IYI_PATH even if std/foundation
# has not yet been merged into current master branch.
EXTRA_PATH=""
if [ ! -f "$REPO/src/std/traits.iyi" ]; then
  mkdir -p "$WORK/foundation/std"
  git show origin/std/foundation:src/std/traits.iyi > "$WORK/foundation/std/traits.iyi" 2>/dev/null || true
  git show origin/std/foundation:src/std/enumerable.iyi > "$WORK/foundation/std/enumerable.iyi" 2>/dev/null || true
  EXTRA_PATH="$WORK/foundation:"
fi

BASE_IYI_PATH="${EXTRA_PATH}${REPO}/src"

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! IYI_PATH="$BASE_IYI_PATH" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_iterator_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
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

echo "== the iterator exercise, plain build"
run_case "plain" iterator-plain
if ! grep -q "all iterator checks passed" "$WORK/iterator-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every iterator section reported"
for phrase in \
  "iterator: infinite take" \
  "iterator: pipeline laziness" \
  "iterator: short-circuit any?" \
  "iterator: short-circuit find" \
  "iterator: map" \
  "iterator: compact_map" \
  "iterator: flat_map" \
  "iterator: select" \
  "iterator: reject" \
  "iterator: take and first(n)" \
  "iterator: take_while" \
  "iterator: skip" \
  "iterator: skip_while" \
  "iterator: each_slice" \
  "iterator: each_cons" \
  "iterator: step" \
  "iterator: zip" \
  "iterator: chain" \
  "iterator: with_index" \
  "iterator: cycle" \
  "iterator: terminals folding" \
  "iterator: terminals counting" \
  "iterator: terminals predicates" \
  "iterator: terminals searching" \
  "iterator: terminals traits" \
  "iterator: each" \
  "iterator: sources"; do
  grep -q "$phrase" "$WORK/iterator-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  all 27 iterator sections reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" iterator-release --release
if ! grep -q "all iterator checks passed" "$WORK/iterator-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when an iterator mechanism is broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  if [ -d "$WORK/foundation/std" ]; then
    cp -R "$WORK/foundation/std/." "$WORK/$dir/std/"
  fi
  sed -e "$sed_script" "$REPO/src/std/iterator.iyi" > "$WORK/$dir/std/iterator.iyi"
  if ! IYI_PATH="$WORK/$dir:$BASE_IYI_PATH" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_iterator_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched iterator library did not build"
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
    echo "  $label: failed, but not at expected check (expected '$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. Take pulls wrong element count (take(n) takes n + 1)
prove_fails "take limit broken" broken_take "assertion failed for infinite take" \
  's/@count < @n/@count < (@n + 1)/'

# 2. Pipeline mapping broken (map iterator returns nil prematurely)
prove_fails "map transform broken" broken_map "assertion failed for pipeline result" \
  's/def next : U?/def next : U?; return nil/g'

# 3. Select filtering broken (fails to loop over elements)
prove_fails "select predicate broken" broken_select "assertion failed for pipeline result" \
  's/while !(item = @iter\.next)\.nil?/item = @iter.next; if !item.nil?/'
# 4. Skip broken (fails to advance past requested count)
prove_fails "skip count broken" broken_skip "assertion failed for skip" \
  's/while @skipped < @n/while @skipped < 0/'

# 5. Zip broken (prematurely halts pairing)
prove_fails "zip pairing broken" broken_zip "assertion failed for zip" \
  's/item1 = @iter1\.next/item1 = nil/'

# 6. Chain broken (skips first iterator directly to second)
prove_fails "chain sequence broken" broken_chain "assertion failed for chain" \
  's/if !@first_done/if false/'

# 7. FlatMap broken (fails to yield sub-arrays)
prove_fails "flat_map flattening broken" broken_flat_map "assertion failed for flat_map" \
  's/@current_sub = @func\.call(item)/@current_sub = [] of U/'

# 8. Range iterator broken (yields the exclusive end)
prove_fails "range end broken" broken_range "assertion failed for range exclusive" \
  's/elsif !@range\.exclusive? \&\& val == @range\.end/elsif val == @range.end/'
echo
if [ "$status" -eq 0 ]; then
  echo "Iterator: all 27 sections pass plain and release, and each check is"
  echo "proven to fail when its mechanism is broken."
else
  echo "Iterator: something above failed."
fi
exit "$status"
