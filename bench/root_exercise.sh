#!/usr/bin/env bash
# Exercises Stage 3 root discovery, and proves the exercise can fail.
#
#     bash bench/root_exercise.sh
#
# GC_DESIGN.md's Stage 3 names the verification: "write a test that allocates
# objects and embeds pointers in global memory, stack, and registers; verify
# that manual root discovery finds them". `bench/root_exercise.iyi` is that
# program and this runs it.
#
# Five things happen here that the program cannot do for itself.
#
# It is built without `-Dgc_iyi`, which is the only way to know that a prelude
# carrying a root scanner still compiles for a program that does not want one.
#
# Every check's line is named below, because a build that silently compiled the
# whole section out would otherwise print nothing and exit 0, which reads
# exactly like a pass.
#
# The `-Dgc_iyi` binary's undefined symbols and libraries are audited the way
# `bench/dependency_floor.sh` audits a default build's, because root discovery
# asks the platform new questions and a new question can arrive as a new
# library.
#
# The Linux paths are cross-compiled and their objects audited. Root discovery
# is the first part of this collector whose code differs by platform in more
# than a syscall number: Linux reads `/proc/self/maps` and three linker
# symbols (`__data_start`, `_end`, and `__ehdr_start` for the thread-local
# block a kernel thread lays out, which every program's trigger can start),
# darwin asks libSystem and walks a Mach header. A workstation runs one of
# them. Compiling the other, for both its architectures, is what says the
# inline assembly assembles and the symbols are the expected ones, and it
# is stated as that rather than as a run.
#
# And the two mechanisms most likely to pass for the wrong reason are removed
# from a COPY of the prelude, which is then built against and must fail. A
# check that cannot fail is not a check. The copy is why nothing in the tree is
# touched to do it.
#
# Needs `make` for bin/iyi, plus `nm`, and `otool` on darwin or `readelf` on
# Linux. Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

# The same readers `bench/dependency_floor.sh` uses, for the same reason: what
# a binary itself leaves undefined and what it itself asks to have loaded.
symbols() {
  nm -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

libraries() {
  if command -v otool >/dev/null 2>&1; then
    otool -L "$1" 2>/dev/null | sed -n '2,$p' | awk '{ print $1 }' | sed 's|.*/||' | sort -u
  else
    readelf -d "$1" 2>/dev/null |
      sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
      sed 's|.*/||' | sort -u
  fi
}

# Reports every element of $2 not matched by a prefix in $1.
unexpected() {
  local allowed="$1" found="$2" item keep ok
  for item in $found; do
    keep=no
    for ok in $allowed; do
      case "$item" in "$ok"*) keep=yes ;; esac
    done
    [ "$keep" = no ] && printf '%s\n' "$item"
  done
  return 0
}

build_and_run() {
  # $1 label, $2 output name, rest: flags
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/root_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
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
build_and_run "default" roots-gc

echo
echo "== every check reported"
for check in "stack bounds:" "global range:" "stack root:" "register root:" \
             "global root:" "interior pointer:" "not a pointer:" "arena tail:" \
             "freed chunk:" "freed large:" "many roots:" "maps parser:" \
             "all root checks passed"; do
  if ! grep -q "$check" "$WORK/roots-gc.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  bounds, stack, register, global, interior, rejection, tail, freed, many and the maps parser all reported"

echo
echo "== the same program, opted out with -Dgc_none"
# There is nothing to exercise without the collector's allocator and the
# program says so. What the arm proves is that a prelude carrying the root
# finder still builds and runs cleanly when the allocator it serves is
# deselected.
build_and_run "gc_none" roots-default -Dgc_none
if ! grep -q "root discovery needs the collector" "$WORK/roots-default.out" 2>/dev/null; then
  echo "  MISSING: the line saying the flag is what turns this on"
  status=1
fi

echo
echo "== the same program with optimisation on"
# A register-residency check is a check about the register allocator, so the
# build that changes register allocation is the one worth running twice. The
# register check names its own premises and fails when one is gone, so this
# run is not a formality: it is the one that would catch the ordering that
# lets the optimiser reuse the register before the scan reaches it.
build_and_run "release" roots-release --release
if ! grep -q "all root checks passed" "$WORK/roots-release.out" 2>/dev/null; then
  echo "  MISSING: the optimised build did not reach the end"
  status=1
fi

echo
echo "== what root discovery asks the machine for"
# Linux adds two undefined symbols and no library: `__data_start` and `_end`
# bound the static data, and both come from the link that is already happening,
# `_end` from the linker itself and `__data_start` from the C runtime object
# every link template adds. Reading `/proc/self/maps` costs nothing at all,
# because `openat`, `read` and `close` are raw syscalls there.
#
# darwin adds four, all libSystem's, which is the standing `write`, `mmap` and
# `munmap` already have on that platform: `pthread_self` and
# `pthread_get_stackaddr_np` for the stack base, and
# `_dyld_get_image_header` with `_dyld_get_image_vmaddr_slide` for the segment
# ranges. Apple documents libSystem as the interface and raw syscalls as not a
# stable ABI, so there is no rawer answer to reach for. The rest of the darwin
# list is every darwin program's — the poller, its clock and errno, which the
# panic path carries — plus one this program's own: `mprotect`, the guard
# page of the fiber it spawns. `bzero` was here for a day: the compiler
# zeroes every `Pointer.malloc` with an `llvm.memset`, the aarch64 back end
# lowers one it will not inline (the 1.5 MiB object below) to a `bzero`
# call, and the prelude now defines `bzero` the way it defines `memset`, so
# the call resolves to the program's own. The stale names (`malloc`,
# `memset`, `realloc`, the file calls) are gone from the list, because an
# entry nothing uses is a check without teeth.
case "$(uname -s)" in
  Linux)
    allowed_symbols="ITM_deregisterTMCloneTable ITM_registerTMCloneTable _cxa_finalize _gmon_start__ _libc_start_main __data_start _end"
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  *)
    allowed_symbols="__error _tlv_bootstrap backtrace backtrace_symbols_fd madvise pipe pthread_create pthread_kill sigaction sigaltstack sysctlbyname read _dyld_get_image_header _dyld_get_image_vmaddr_slide clock_gettime_nsec_np exit kevent kqueue mmap mprotect munmap pthread_get_stackaddr_np pthread_self write"
    ;;
esac
allowed_libs="libSystem libc.so ld-linux libgcc_s"

if [ -x "$WORK/roots-gc" ]; then
  gc_syms="$(symbols "$WORK/roots-gc")"
  gc_libs="$(libraries "$WORK/roots-gc")"
  printf '  symbols   %s\n' "$(echo $gc_syms)"
  printf '  libraries %s\n' "$(echo $gc_libs)"

  extra_syms="$(unexpected "$allowed_symbols" "$(echo $gc_syms)")"
  if [ -n "$extra_syms" ]; then
    echo "  root discovery asks the machine for something new:"
    echo "$extra_syms" | sed 's/^/    /'
    echo "  Each is a dependency being taken on. If that is the decision, record it"
    echo "  here and in the commit (SPEC.md III.9)."
    status=1
  fi

  extra_libs="$(unexpected "$allowed_libs" "$(echo $gc_libs)")"
  if [ -n "$extra_libs" ]; then
    echo "  root discovery links something new:"
    echo "$extra_libs" | sed 's/^/    /'
    status=1
  fi
  [ -z "$extra_syms$extra_libs" ] && echo "  nothing beyond what is named above, and no new library"
else
  echo "  no -Dgc_iyi binary to audit"
  status=1
fi

echo
echo "== the other platform's code, compiled and audited"
# Not run. What this says is that the branch this machine does not take still
# compiles, that its inline assembly assembles for both architectures, and that
# it leaves exactly the two symbols named above.
case "$(uname -s)" in
  Linux) other_targets="x86_64-darwin aarch64-darwin" ; other_expect="" ;;
  *)     other_targets="x86_64-linux-gnu aarch64-linux-gnu" ; other_expect="__data_start __ehdr_start _end" ;;
esac
for target in $other_targets; do
  if ! "$IYI" build --cross-compile --target "$target" \
       -o "$WORK/roots-$target" "$REPO/bench/root_exercise.iyi" \
       >"$WORK/roots-$target.log" 2>&1; then
    echo "  $target: cross-compile failed"
    sed -n '1,12p' "$WORK/roots-$target.log"
    status=1
    continue
  fi
  found="$(nm -u "$WORK/roots-$target.o" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' | awk '{ print $NF }' | sort -u | tr '\n' ' ')"
  printf '  %-20s undefined: %s\n' "$target" "${found:-(none)}"
  if [ -n "$other_expect" ]; then
    for want in $other_expect; do
      case " $found " in
        *" $want "*) ;;
        *) echo "  $target: expected $want among its undefined symbols"; status=1 ;;
      esac
    done
    surplus="$(unexpected "$other_expect" "$found")"
    if [ -n "$surplus" ]; then
      echo "  $target: asks for more than the linker symbols:"
      echo "$surplus" | sed 's/^/    /'
      status=1
    fi
  fi
done

echo
echo "== the checks fail when the mechanism is removed"
# Two mechanisms, each removed from a copy of the prelude that is then built
# against through IYI_PATH. Nothing in the tree is modified. Each build must
# produce a program that fails, and fails at the check that names the removed
# mechanism, because a check that passes either way measures nothing.
prove_fails() {
  # $1 label, $2 directory name, $3 expected phrase, rest: the awk program
  local label="$1" dir="$2" phrase="$3"
  shift 3
  mkdir -p "$WORK/$dir/iyi"
  cp "$REPO"/src/iyi/*.iyi "$WORK/$dir/iyi/"
  awk "$1" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/root_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so the check proves nothing"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out" 2>/dev/null; then
    echo "  $label: failed, but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# The spill is what puts the callee-saved registers where the scan can see
# them. Both architectures' blocks go, so the copy is wrong everywhere rather
# than only here.
prove_fails "no register spill" nospill "register root:" '
  /asm\("stp x19|asm\("movq %rbx/ { skip = 1 }
  skip && /"volatile"\)/          { skip = 0; next }
  skip                            { next }
                                  { print }
'

# The global range narrowed at the point it is scanned rather than the point it
# is discovered, so the exercise gets past its own bounds check and fails at
# the root itself.
prove_fails "narrowed global range" narrow "global root:" '
  { sub(/scan_range\(data_low, data_high, visit\)/,
        "scan_range(data_low, data_low + 128_u64, visit)"); print }
'

# The fiber walk removed from the root set: the address held only on a
# suspended fiber's stack goes unfound, which is exactly the freed-live
# defect the walk exists to prevent.
prove_fails "no fiber walk" nofiber "fiber root:" '
  { sub(/each_fiber_root\(visit\)/, "each_global_root(visit)"); print }
'

echo
if [ "$status" -eq 0 ]; then
  echo "Roots: stack, registers and globals are all found, an interior pointer"
  echo "resolves to its base, and nothing that is not a live chunk is reported."
else
  echo "Roots: something above failed."
fi
exit $status
