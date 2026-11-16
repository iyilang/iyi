#!/usr/bin/env bash
# heap22's plumbing, driven: bench/heap_partition.iyi built plain and
# optimised, run bare and on a pool of four with 400,000 rounds a task, and
# then proven to fail in each direction that matters - a switch that does
# not install the fiber's partition, a bracket that does not put back what
# it found, a unit whose fiber list keeps its dead or never lists its
# living, and a freed record left on the caches list the pause strips;
# with partitions (`-Dheap_partitions` in IYI_OPTS), a dead unit's fiber
# still naming its partition, caught by the exercise and, with its check
# left out, by `-Dheap_verify` at the unit's death; and the arena
# directory's bounds read first under the runtime lock, which hangs or,
# with `-Dheap_verify`, stops by name if they are a once again.
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

# The arena directory's bounds read first under the runtime lock
# (`IyiHeap.dir_widen`, partitions only). A class variable whose
# initialiser is anything but a literal is a once, and a read compiled
# before that initialiser in the program's order goes through the once:
# under the lock, on a thread with no scheduler state yet, the once
# allocates to find its fiber and waits on the lock its own thread holds,
# for ever (darwin's first allocation in `IyiStackGuard.install`, heap22
# fu DirFix). The copy puts such a read in front on every system: an
# initialiser in `IyiScheduler`, ahead of the heap's in the program, that
# allocates - its first allocation maps an arena and widens the bounds
# under the lock - and asks `arena_of`, which reads them. Built as it is
# the program runs; with `@@dir_low` back on `DIR_SLOTS` it hangs (a
# timeout is the catch), and with `-Dheap_verify` `__iyi_once` stops by
# name, entered under the lock (exit 86).
BOUNDS_EARLY='{ print } /^  @@lot_locks : Pointer\(UInt64\) = Pointer\(UInt64\)\.new\(0_u64\)$/ { print "  @@bounds_early : UInt64 = IyiHeap.arena_of(Pointer(UInt64).malloc(1_u64).address)"; found = 1 } END { if (!found) exit 3 }'
BOUNDS_LAZY='{ if (sub(/^  @@dir_low : UInt64 = 0xFFFF_FFFF_FFFF_FFFF_u64$/, "  @@dir_low : UInt64 = DIR_SLOTS")) found = 1; print } END { if (!found) exit 3 }'

bounds_case() { # label dir expect(pass|hang|named) lazy(0|1) build-flags...
  local label="$1" dir="$2" expect="$3" lazy="$4"
  shift 4
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$BOUNDS_EARLY" "$REPO/src/iyi/concurrency.iyi" > "$WORK/$dir/iyi/concurrency.iyi" ||
     { [ "$lazy" = 1 ] && ! awk "$BOUNDS_LAZY" "$REPO/src/iyi/heap_partition.iyi" > "$WORK/$dir/iyi/heap_partition.iyi"; }; then
    echo "  $label: what the copy changes is not in the runtime any more"
    status=1
    return
  fi
  # shellcheck disable=SC2068
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build $@ \
       -o "$WORK/$dir/program" "$REPO/bench/heap_partition.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the copy did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout -k 5 60 "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local code=$?
  case "$expect:$code" in
    pass:0) echo "  $label: runs" ;;
    hang:124 | hang:137) echo "  $label: hangs, ended at 60 s (exit $code)" ;;
    named:86)
      if grep -q "^iyi: heap_verify: a once-initialised class variable or constant was first read under the runtime lock" "$WORK/$dir/out"; then
        echo "  $label: exits 86, the once named under the lock"
      else
        echo "  $label: exit 86 at another check"; sed -n '1,4p' "$WORK/$dir/out"; status=1
      fi ;;
    *)
      echo "  $label: expected $expect, exit $code"
      sed -n '1,6p' "$WORK/$dir/out"
      status=1 ;;
  esac
}

case " ${IYI_OPTS:-} " in
  *" -Dheap_partitions "*)
    # A compiler with S3's head 2 makes `IyiWaiter` born shared in codegen
    # (`IYI_BORN_SHARED`), which the bracket NOWAITER takes out only
    # repeats: the copy turns that off too (`IYI_SPAWN_BROKEN=new-shared`,
    # a value an older compiler ignores), or it passes (Rule2f, Linux,
    # 7ae0f9b18).
    IYI_SPAWN_BROKEN=new-shared prove_fails "the spare waiter in the partition" nowaiter "dead:" "$NOWAITER" concurrency.iyi
    prove_fails "a reaped fiber keeps its group" nogroup "dead:" "$NOGROUP" concurrency.iyi
    prove_fails "a reaped fiber keeps its block" noproc "dead:" "$NOPROC" concurrency.iyi

    echo
    echo "== the directory's bounds read first under the runtime lock"
    bounds_case "bounds read first under the lock" bounds pass 0
    bounds_case "bounds read first under the lock, -Dheap_verify" vbounds pass 0 -Dheap_verify
    bounds_case "the bounds a once again" lazybounds hang 1
    bounds_case "the bounds a once again, -Dheap_verify" vlazybounds named 1 -Dheap_verify

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
    IYI_SPAWN_BROKEN=new-shared prove_verified "the spare waiter in the partition" vnowaiter "$NOWAITER" concurrency.iyi
    prove_verified "a reaped fiber keeps its group" vnogroup "$NOGROUP" concurrency.iyi
    prove_verified "a reaped fiber keeps its block" vnoproc "$NOPROC" concurrency.iyi
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "heap_partition: the exercise holds, and fails when any of it is broken."
fi
exit "$status"
