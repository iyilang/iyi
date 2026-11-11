#!/usr/bin/env bash
# heap22's plumbing, driven: bench/heap_partition.iyi built plain and
# optimised, run bare and on a pool of four with 400,000 rounds a task, and
# then proven to fail in each direction that matters - a switch that does
# not install the fiber's partition, a bracket that does not put back what
# it found, a unit whose fiber list keeps its dead or never lists its
# living, and a freed record left on the caches list the pause strips;
# with partitions (`-Dheap_partitions` in IYI_OPTS), a dead unit's fiber
# still naming its partition, caught by the exercise and, with its check
# left out, by `-Dheap_verify` at the unit's death.
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

# What a dead unit's fibers keep (`dead:`, partitions only). The waiter
# `park_on` keeps as the fiber's spare made in the unit's partition; a
# reaped fiber that keeps naming its group, or its block's context, both
# its unit's. Each is caught twice: by the exercise's own check, and with
# the check left out (`dead quiet`) by `-Dheap_verify`'s scan at the
# unit's death, which finds the shared fiber naming a chunk about to be
# freed (exit 86).
NOWAITER='{ if (sub(/waiter = IyiCross\.shared \{ IyiWaiter\.new\(fiber, nonce, word\.address\) \}/, "waiter = IyiWaiter.new(fiber, nonce, word.address)")) found = 1; print } END { if (!found) exit 3 }'
NOGROUP='/^        fiber\.group = nil$/ { found = 1; next } { print } END { if (!found) exit 3 }'
NOPROC='/^        fiber\.proc = nil$/ { found = 1; next } { print } END { if (!found) exit 3 }'

prove_verified() { # label dir awk-script file
  local label="$1" dir="$2" script="$3" file="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  # shellcheck disable=SC2086
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -Dheap_verify \
       -o "$WORK/$dir/program" "$REPO/bench/heap_partition.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout 120 "$WORK/$dir/program" dead quiet >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -ne 86 ] || ! grep -q "at its unit's death" "$WORK/$dir/out"; then
    echo "  $label: -Dheap_verify did not report it at the unit's death (exit $code)"
    sed -n '1,8p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: -Dheap_verify exits 86 at "%s", holder %s\n' "$label" \
    "$(grep -m1 "at its unit's death" "$WORK/$dir/out" | sed 's/^ *//')" \
    "$(grep -m1 'holder 0x' "$WORK/$dir/out" | sed 's/^ *holder 0x[0-9a-f]* //')"
}

case " ${IYI_OPTS:-} " in
  *" -Dheap_partitions "*)
    prove_fails "the spare waiter in the partition" nowaiter "dead:" "$NOWAITER" concurrency.iyi
    prove_fails "a reaped fiber keeps its group" nogroup "dead:" "$NOGROUP" concurrency.iyi
    prove_fails "a reaped fiber keeps its block" noproc "dead:" "$NOPROC" concurrency.iyi

    echo
    echo "== the same, with -Dheap_verify and the exercise's own check left out"
    if ! "$IYI" build -Dheap_verify -o "$WORK/verify" "$REPO/bench/heap_partition.iyi" >"$WORK/verify.build.log" 2>&1; then
      echo "verify: build failed"
      sed -n '1,12p' "$WORK/verify.build.log"
      status=1
    else
      timeout 120 "$WORK/verify" dead quiet >"$WORK/verify.out" 2>&1
      code=$?
      sed 's/^/  /' "$WORK/verify.out"
      if [ "$code" -ne 0 ]; then
        echo "verify, dead quiet: exit $code"
        status=1
      fi
    fi
    prove_verified "the spare waiter in the partition" vnowaiter "$NOWAITER" concurrency.iyi
    prove_verified "a reaped fiber keeps its group" vnogroup "$NOGROUP" concurrency.iyi
    prove_verified "a reaped fiber keeps its block" vnoproc "$NOPROC" concurrency.iyi
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "heap_partition: the exercise holds, and fails when any of it is broken."
fi
exit "$status"
