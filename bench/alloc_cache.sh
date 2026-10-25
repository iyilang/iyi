#!/usr/bin/env bash
# Drives bench/alloc_cache.iyi: a pool's workers allocating from caches of
# their own, refilled under their size class's lock (GC_DESIGN.md, "Whose
# state is whose").
#
#     bash bench/alloc_cache.sh
#
# The exercise plain and --release, each reaching its last line, and then
# broken copies of the runtime, each caught by a named check or by the
# program dying before it can pass:
#
#   * a collection that leaves the caches' lists alone - a list kept
#     across the epoch's turn holds chunks the sweep links again;
#   * a class's lock that excludes nobody - two workers pop one batch;
#   * a walk claim that excludes nobody - two workers sweep one slice and
#     each takes its batch;
#   * a thread that ends without retiring its cache.
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/alloc_cache.iyi" \
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
  if ! grep -q "alloc cache: every property held" "$WORK/$name.out"; then
    echo "  MISSING: $label did not reach the end"
    status=1
    return 1
  fi
  for phrase in intact reused distinct flushed retired; do
    grep -q "^$phrase: " "$WORK/$name.out" || {
      echo "  MISSING: $label reported nothing for $phrase"
      status=1
    }
  done
  return 0
}

echo "== the exercise"
run_case "the exercise" plain

echo
echo "== the same program with optimisation on"
run_case "release" release --release

echo
echo "== the checks fail when the caches or the centre are broken"
# $1 label, $2 directory, $3 the checks that may name it (an ERE), $4 the
# prelude file the awk program rewrites, $5 the awk program, which exits 3
# when the line it breaks is not there - a proof whose break no longer
# lands proves nothing.
prove_fails() {
  local label="$1" dir="$2" phrase="$3" file="$4" script="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"; then
    echo "  $label: the line this proof breaks is not in $file any more"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build --release \
       -o "$WORK/$dir/program" "$REPO/bench/alloc_cache.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"
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
  if grep -qE "^FAIL: ($phrase):" "$WORK/$dir/out"; then
    printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
      "$(grep -m1 -E "^FAIL: ($phrase):" "$WORK/$dir/out" | sed 's/^FAIL: //')"
    return
  fi
  # A chunk handed out twice can break what the program needs to say so -
  # the runtime's own buffers come from the same heap - and the process
  # dies before any check reports. That is the break caught, not missed,
  # when the process died on a signal, or of the memory fault Windows'
  # handler names, and never reached the line that says it passed.
  if [ "$exit_code" -ge 128 ] && ! grep -q "every property held" "$WORK/$dir/out"; then
    printf '  %s: dies on signal %s before it can report, and never passes\n' \
      "$label" "$(( exit_code - 128 ))"
    return
  fi
  if grep -q "died of a memory fault" "$WORK/$dir/out" && ! grep -q "every property held" "$WORK/$dir/out"; then
    printf '  %s: dies of a memory fault before it can report, and never passes\n' "$label"
    return
  fi
  echo "  $label: failed, but not at the expected check"
  tail -6 "$WORK/$dir/out" | sed 's/^/    /'
  status=1
}

# The pause empties the centre and leaves every cache's list as it was.
prove_fails "caches not flushed at a collection" unflushed "intact|distinct|flushed" prelude.iyi \
  '{ if ($0 ~ /^            table\[index\] = 0_u64$/ && prev ~ /^          while index < CLASSES$/) { print "            # removed"; found = 1; prev = $0; next } prev = $0; print } END { if (!found) exit 3 }'

# A class's lock taken by everyone at once.
prove_fails "a class's lock that excludes nobody" openlock "intact|distinct" prelude.iyi \
  '{ if ($0 ~ /^        until word\.value\.get == 0_u64 && word\.value\.compare_and_set\(0_u64, 1_u64\)\[1\]$/) { print "        until true"; found = 1; next } print } END { if (!found) exit 3 }'

# A slice another walker is inside of taken again: two walkers on one
# slice, each linking its dead chunks, each worker making the batch its own.
prove_fails "two workers on one slice" shared "intact|distinct" prelude.iyi \
  '{ if ($0 ~ /^            if IyiHeap\.read64\(arena \+ IyiHeap::OFF_SWEEPING\) == epoch$/ && !found) { print "            if false"; found = 1; next } print } END { if (!found) exit 3 }'

# The `reused` check has no broken copy here, and that is a measured gap,
# not an oversight. Two were tried and passed it: a worker's own slice
# dropped (the helpers' batches and the warm and cold runs a dropped batch
# leaves hand the chunks back another way), and a sweep that hands nothing
# back at all - the frontier the check sums is over the arenas still
# mapped, and the scavenge hands the all-dead arenas back, so the sum fell.
# A check on mappings made rather than bytes carved is the next one to try.

# A thread that ends with its cache still on the list.
prove_fails "an ended thread's cache kept" unretired "retired" thread.iyi \
  '{ if ($0 ~ /^      IyiHeap\.retire_cache$/) { print "      # removed"; found = 1; next } print } END { if (!found) exit 3 }'

echo
if [ "$status" -eq 0 ]; then
  echo "alloc cache gate: passed"
else
  echo "alloc cache gate: FAILED"
fi
exit "$status"
