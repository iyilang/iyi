#!/usr/bin/env bash
# GC_DESIGN.md Stage 5, driven. Runs the mark exercise, checks it reached the
# end rather than merely exiting 0, audits what marking asks the machine for,
# and proves the exercise fails when the mark phase is broken.
#
#   bash bench/mark_exercise.sh
#
# Needs `make` first, because it runs ./bin/iyi. Exits non-zero if any step
# fails, which is what CI keys on.
#
# The last section is the one that matters. An exercise that prints reassurance
# is worth nothing until you have watched it catch the defect it exists for, so
# two mechanisms are removed from a copy of the prelude, built against through
# IYI_PATH, and each resulting program must fail at the check that names what
# was removed. Nothing in the tree is modified.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` on it is silently ignored, so the patched
# copy is never read and the proof that a check can fail quietly stops
# proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# Marking needs the collector's allocator, which is the default on
# linux-x86_64, linux-aarch64 and darwin; where a build deselects it the
# exercise itself refuses every section, and a gate that then reports those
# sections as MISSING claims more than it measured.
case "$(uname -s)" in
  Linux | Darwin) ;;
  *) echo "mark exercise: marking needs the collector's allocator, which this platform's build deselects; nothing to measure here"; exit 0 ;;
esac

status=0

undefined_symbols() {
  nm -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

linked_libraries() {
  if command -v otool >/dev/null 2>&1; then
    otool -L "$1" 2>/dev/null | sed -n '2,$p' | awk '{ print $1 }' | sed 's|.*/||' | sort -u
  else
    readelf -d "$1" 2>/dev/null |
      sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
      sed 's|.*/||' | sort -u
  fi
}

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/mark_exercise.iyi" \
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

echo "== the exercise, the default allocator"
run_case "the exercise" mark
# Exit 0 is not the check: a program that compiled the whole section out also
# exits 0. Reaching the last line is the check.
if ! grep -q "all mark checks passed" "$WORK/mark.out" 2>/dev/null; then
  echo "  MISSING: the run did not reach the end"
  status=1
fi

echo
echo "== every check reported"
for phrase in chain garbage idempotent unmark cycles "interior root" depth; do
  grep -q "$phrase" "$WORK/mark.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  chain, garbage, idempotence, unmark, cycles, interior root and depth all reported"

echo
echo "== the same program with optimisation on"
# Marking reads words the optimiser is free to move between registers and the
# stack, so the release build is a different test rather than the same one
# faster.
run_case "release" mark-release --release
if ! grep -q "all mark checks passed" "$WORK/mark-release.out" 2>/dev/null; then
  echo "  MISSING: the optimised build did not reach the end"
  status=1
fi

echo
echo "== the same program, opted out with -Dgc_none"
run_case "gc_none" mark-none -Dgc_none

echo
echo "== what marking asks the machine for"
if [ -f "$WORK/mark" ]; then
  syms="$(undefined_symbols "$WORK/mark" | tr '\n' ' ')"
  libs="$(linked_libraries "$WORK/mark" | tr '\n' ' ')"
  echo "  symbols   ${syms:-(none)}"
  echo "  libraries ${libs:-(none)}"
  # The mark phase's own additions over Stage 3 should be nothing: the queue is
  # mmap and munmap, both already bound for the arenas. The five loader-glue
  # names are every dynamically linked binary's baseline on Linux, the same
  # list `bench/arena_exercise.sh` allows: they come from crt/cc linkage, not
  # from marking. On darwin every program also carries the poller, its clock
  # and errno (`kqueue`, `kevent`, `clock_gettime_nsec_np`, `__error`),
  # because the panic path runs through the scheduler; they are libSystem's
  # and bench/dependency_floor.sh's, not marking's.
  extra="$(undefined_symbols "$WORK/mark" | grep -vxF -e clock_gettime -e exit -e mmap -e munmap -e write \
    -e pthread_self -e pthread_get_stackaddr_np -e _dyld_get_image_header -e _dyld_get_image_vmaddr_slide \
    -e kqueue -e kevent -e clock_gettime_nsec_np -e __error -e _tlv_bootstrap -e pthread_kill -e pthread_create -e sysctlbyname -e pipe -e sigaction -e sigaltstack -e madvise \
    -e backtrace -e backtrace_symbols_fd \
    -e open -e openat -e close -e read -e unlink -e chmod \
    -e ITM_deregisterTMCloneTable -e ITM_registerTMCloneTable -e _cxa_finalize -e _gmon_start__ -e _libc_start_main || true)"
  if [ -n "$extra" ]; then
    echo "  marking asks the machine for something new:"
    echo "$extra" | sed 's/^/    /'
    echo "  Each is a dependency being taken on (SPEC.md III.9)."
    status=1
  else
    echo "  nothing beyond what root discovery and the arenas already asked for"
  fi
fi

echo
echo "== the checks fail when the mark phase is broken"
# Each removes one mechanism from a copy of the prelude and builds against it
# through IYI_PATH. The program must fail, and fail at the check that names the
# removed mechanism, because a check that passes either way measures nothing.
prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  awk "$script" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/mark_exercise.iyi" \
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
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# Never blacken. The queue drains and every object stays gray, which is the
# shape of a mark phase that loses track of what it has already scanned.
prove_fails "no black shading" noblack "should be black" \
  '{ if ($0 ~ /IyiHeap\.write8\(IyiHeap\.mark_byte\(arena, base\), BLACK\)/) next; print }'

# Stop following pointers. Roots are marked and nothing they reach is, which is
# the defect that frees a live object.
prove_fails "no pointer follow" nofollow "should be black" \
  '{ if ($0 ~ /shade_word\(w, IyiHeap\.read64\(cursor\)\)/) { sub(/shade_word\(w, IyiHeap\.read64\(cursor\)\)/, "shade_word(w, 0_u64)") } print }'

# Precision off: every lookup misses, so the marker word-scans typed objects
# and follows the addresses their integer fields hold — the retention the
# typed-fields check exists to refuse.
prove_fails "no layout lookup" nolayout "typed fields:" \
  '{ sub(/entry = layout_entry\(w, type_id\)/, "entry = 0_u64"); print }'

echo
if [ "$status" -eq 0 ]; then
  echo "Marking: the live set comes out black, unreachable objects stay white,"
  echo "cycles terminate, and the exercise fails when the phase is broken."
else
  echo "Marking: something above failed."
fi
exit "$status"
