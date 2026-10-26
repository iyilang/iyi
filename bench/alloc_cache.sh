#!/usr/bin/env bash
# Drives bench/alloc_cache.iyi: a pool's workers allocating from caches of
# their own, refilled under their size class's lock (GC_DESIGN.md, "A
# pool's workers and the centre: a lock per size class").
#
#     bash bench/alloc_cache.sh
#
# The exercise plain and --release, each reaching its last line, and then
# broken copies of the runtime, each caught by a named check or by the
# program dying before it can pass:
#
#   * a sweep that hands nothing back - every slice's batch dropped, the
#     helpers', the pause's and the allocating thread's own;
#   * a worker that throws away the batch of the slice it swept;
#   * a collection that leaves the caches' lists alone - a list kept
#     across the epoch's turn holds chunks the sweep links again;
#   * a class's lock that excludes nobody - two workers pop one batch;
#   * a walk claim that excludes nobody - two workers sweep one slice and
#     each takes its batch;
#   * a thread that ends without retiring its cache.
#
# The first two are caught at `reused` by name and nowhere else: they
# lose memory, not data, and a run that died of something else would not
# be the reuse check failing.
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a
# search path of `/tmp/tmp.X` and `/d/a/...` finds no prelude, and the
# gate's first run on Windows built none of its broken copies. The list's
# separator is `;` there, where a drive letter owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
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
  # Bounded: a run takes seconds, and a hang should cost two minutes of
  # a runner rather than its job.
  timeout -k 5 120 "$WORK/$name" >"$WORK/$name.out" 2>&1
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
# lands proves nothing - and $6, `named`, when only those checks catch it
# and a death on a signal does not.
prove_fails() {
  local label="$1" dir="$2" phrase="$3" file="$4" script="$5" named="${6:-}"
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
  timeout -k 5 120 "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
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
  if [ -n "$named" ]; then
    echo "  $label: failed, but not at the check that names it"
    tail -6 "$WORK/$dir/out" | sed 's/^/    /'
    status=1
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
  # A lock that excludes nobody can leave two threads each waiting on
  # what the other broke: on darwin that copy hung, where Linux and
  # Windows died of it. Stopped at the bound, it never passed either.
  if [ "$exit_code" -eq 124 ] && ! grep -q "every property held" "$WORK/$dir/out"; then
    printf '  %s: hangs past 120 s before it can report, and never passes\n' "$label"
    return
  fi
  echo "  $label: failed, but not at the expected check"
  tail -6 "$WORK/$dir/out" | sed 's/^/    /'
  status=1
}

# The slice's walk ends answering no batch: the dead chunks are freed and
# go on no list, and the second wave of `reused` carves all of itself.
prove_fails "a sweep that hands nothing back" nothing "reused" prelude.iyi \
  '/^      def self\.sweep_slice\(/ { inside = 1 } /^      def self\./ && !/sweep_slice/ { inside = 0 } { if (inside && $0 ~ /^        batch_head$/) { print "        0_u64"; found = 1; next } print } END { if (!found) exit 3 }' named

# The allocating thread sweeps its slice and keeps nothing of it: with no
# helper running, nobody else's batch hands the chunks back instead.
prove_fails "a worker that throws its swept batch away" dropped "reused" prelude.iyi \
  '{ if ($0 ~ /^        IyiHeap\.adopt_batch\(table, index, batch\) if batch != 0$/) { print "        # removed"; found = 1; next } print } END { if (!found) exit 3 }' named

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
