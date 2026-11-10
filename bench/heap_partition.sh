#!/usr/bin/env bash
# heap22's plumbing, driven: bench/heap_partition.iyi built plain and
# optimised, run bare and on a pool of four with 400,000 rounds a task, and
# then proven to fail in each direction that matters - a switch that does
# not install the fiber's partition, a bracket that does not put back what
# it found, a unit whose fiber list keeps its dead or never lists its
# living, and a freed record left on the caches list the pause strips.
#
#   bash bench/heap_partition.sh
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrapper in bin is a posix shell script, so a caller that already has a
# compiler of its own names it through the environment.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping, and the
# search path's separator is the platform's (bench/collect_trigger.sh).
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0

run_case() { # label name args-for-the-program... -- build flags...
  local label="$1" name="$2" flags="$3"
  shift 3
  # shellcheck disable=SC2086
  if ! "$IYI" build $flags -o "$WORK/$name" "$REPO/bench/heap_partition.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  # A hang is a failure too, ended at 300 s (exit 124).
  timeout 300 "$WORK/$name" "$@" >"$WORK/$name.out" 2>&1
  local code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$code" -ne 0 ]; then
    echo "$label: exit $code"
    status=1
  fi
}

echo "== the exercise, plain"
run_case "plain" plain ""
run_case "plain, 4 workers" plain4 "" 4 400000
echo "== the exercise, optimised"
run_case "release" release "--release"
run_case "release, 4 workers" release4 "--release" 4 400000

echo
echo "== the checks fail when the plumbing is broken"
prove_fails() { # label dir phrase awk-script file
  local label="$1" dir="$2" phrase="$3" script="$4" file="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/heap_partition.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout 120 "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "^FAIL: $phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 "^FAIL: $phrase" "$WORK/$dir/out" | sed 's/^FAIL: //')"
}

# The switch's install dropped: a fiber parked inside a record comes back
# on whatever the scheduler left installed, its thread's own cache.
prove_fails "the switch installs nothing" noinstall "switch:" \
  '/# The fiber.s partition installed as the last step/ { armed = 1 } armed && /install_alloc\(st, fiber\.alloc\)/ { armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
  concurrency.iyi

# `within` leaves its record installed after its block.
prove_fails "within puts nothing back" nowithin "bracket:" \
  '/def self\.within\(record : UInt64, &\)/ { inside = 1 } inside && /answer = yield/ { print; skip = 2; inside = 0; found = 1; next } skip > 0 { skip = skip - 1; next } { print } END { if (!found) exit 3 }' \
  concurrency.iyi

# `shared` leaves the thread's own cache installed after its block.
prove_fails "shared puts nothing back" noshared "bracket:" \
  '/def self\.shared\(&\)/ { inside = 1 } inside && /answer = yield/ { print; skip = 2; inside = 0; found = 1; next } skip > 0 { skip = skip - 1; next } { print } END { if (!found) exit 3 }' \
  concurrency.iyi

# A fiber that leaves the registry stays first on its unit's list.
prove_fails "the unit keeps its dead" nounlink "fibers:" \
  '{ if (sub(/elsif first\.is_a\?\(IyiFiber\) && first\.object_id == fiber\.object_id/, "elsif false")) found = 1; print } END { if (!found) exit 3 }' \
  concurrency.iyi

# A fiber that joins the registry never reaches its unit's list.
prove_fails "the unit lists nobody" nolink "fibers:" \
  '{ if (sub(/^      unit\.fibers = fiber$/, "      fiber.prev_in_unit = nil")) found = 1; print } END { if (!found) exit 3 }' \
  concurrency.iyi

# A freed record left on the caches list, its lists never handed back.
# With partitions in the runtime (`-Dheap_partitions` in IYI_OPTS)
# `partition_free` hands the record's runs to the shared heap and lets the
# record go in `partition_release` (heap_partition.iyi), which takes it off
# the list instead, so that copy leaves the record on the list there.
case " ${IYI_OPTS:-} " in
  *" -Dheap_partitions "*)
    prove_fails "a freed record stays listed" noretire "caches:" \
      '/def self\.partition_release\(record : UInt64\)/ { inside = 1 } inside && /^    if cursor == record$/ { print "    if false"; inside = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
      heap_partition.iyi ;;
  *)
    prove_fails "a freed record stays listed" noretire "caches:" \
      '/def self\.partition_free\(record : UInt64\)/ { inside = 1 } inside && /^        retire_lists\(record\)$/ { inside = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
      prelude.iyi ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "heap_partition: the exercise holds, and fails when any of it is broken."
fi
exit "$status"
