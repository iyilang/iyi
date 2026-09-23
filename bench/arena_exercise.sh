#!/usr/bin/env bash
# Exercises the Stage 2 size-class arena allocator, and the default allocator
# beside it, so the same program proves both.
#
#     bash bench/arena_exercise.sh
#
# GC_DESIGN.md's Stage 2 names the verification: "allocate and free objects of
# various sizes; verify no corruption; inspect arena structure; measure
# allocation speed". `bench/arena_exercise.iyi` is that program and this runs
# it twice, plain and with `-Dgc_iyi`, because an allocator that is opt-in has
# two paths to keep working and only one of them is new.
#
# Four things happen here that the program cannot do for itself. It is run
# without the flag, which is the only way to know the default path still
# works. Its exit code is read rather than its output, because a check that
# fails raises and a panic exits non-zero. `bench/arena_large_probe.iyi` is
# run separately and its death is the assertion: freeing a large object
# releases the mapping, and the proof of a released mapping is that reading
# it faults. And the `-Dgc_iyi` binary's undefined symbols are audited the
# way `bench/dependency_floor.sh` audits a default build's, because a new
# allocator is exactly the kind of change that arrives with a new library.
#
# Needs `make` for bin/iyi, plus `nm`, and `otool` on darwin or `readelf` on
# Linux. Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrapper in bin is a posix shell script, so a caller that already has a
# compiler of its own names it through the environment.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

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

trap 'rm -rf "$WORK"' EXIT

status=0

# A floor measured with a reader that is not installed is not measured at
# all: `nm -u` in a shell with no `nm` prints nothing, and an empty symbol
# list reads as a floor that held. The readers are resolved once here, and
# the arm that needs them says what it could not measure instead.
NM=""
command -v nm >/dev/null 2>&1 && NM=nm
LIBS_READER=""
for candidate in otool readelf; do
  if command -v "$candidate" >/dev/null 2>&1; then
    LIBS_READER="$candidate"
    break
  fi
done
unmeasured=0

# The same readers `bench/dependency_floor.sh` uses, for the same reason: what
# a binary itself leaves undefined and what it itself asks to have loaded.
symbols() {
  "$NM" -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

libraries() {
  if [ "$LIBS_READER" = otool ]; then
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
  # $1 label, $2 output name, $3 source, rest: flags
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

echo "== the exercise, -Dgc_none (the opted-out bump pointer)"
build_and_run "gc_none" exercise-default "$REPO/bench/arena_exercise.iyi" -Dgc_none

echo
echo "== the exercise, the default (the collector's arena)"
build_and_run "default" exercise-gc "$REPO/bench/arena_exercise.iyi"

# The same two, --release: the speed a shipped program sees, which is the
# number that moved when the fast path grew a thread-local read (one call
# in a plain build, one `%fs:` load in a release one).
echo
echo "== the same two, --release"
build_and_run "gc_none, release" exercise-default-release "$REPO/bench/arena_exercise.iyi" -Dgc_none --release
build_and_run "default, release" exercise-gc-release "$REPO/bench/arena_exercise.iyi" --release

# Every check in the program prints a line, and the arena-only ones print
# nothing without the flag. Naming them here is what stops a build that
# silently compiled the whole arena section out from reading as a pass.
echo
echo "== every arena check reported"
# The huge-page check reads /proc, so it reports on Linux only.
for check in "size classes:" "addressability:" "clearing:" "reuse:" "traversal:" "large:" $( [ "$(uname -s)" = Linux ] && echo "huge:" ); do
  if ! grep -q "$check" "$WORK/exercise-gc.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  size classes, addressability, clearing, reuse, traversal, large$( [ "$(uname -s)" = Linux ] && echo " and huge" ) all reported"

echo
echo "== a freed large object's mapping is gone"
if ! "$IYI" build -o "$WORK/large-probe" "$REPO/bench/arena_large_probe.iyi" >"$WORK/large-probe.build.log" 2>&1; then
  echo "  probe build failed"
  tail -12 "$WORK/large-probe.build.log"
  status=1
else
  # Run through a child shell whose stderr is dropped: the fault is the
  # expected result here, and the "Segmentation fault" line a shell prints
  # for a killed job would read as this script's own failure.
  bash -c '"$0" >"$1" 2>&1' "$WORK/large-probe" "$WORK/large-probe.out" 2>/dev/null
  probe_exit=$?
  # 128 + SIGSEGV(11), or 128 + SIGBUS(10) where a platform reports an
  # unmapped read that way. Either is the read faulting, which is the claim.
  # Windows has no signal to die of: the runtime's vectored handler names
  # the access violation itself and exits 1, and that sentence is the same
  # claim in the runtime's words.
  if [ "$probe_exit" = 1 ] && grep -q "died of a memory fault" "$WORK/large-probe.out"; then
    probe_exit=fault
  fi
  case "$probe_exit" in
    139 | 138 | fault)
      echo "  the read faulted (exit $probe_exit): the mapping was released"
      ;;
    0)
      echo "  the probe READ the freed mapping and lived, so nothing was released:"
      sed 's/^/    /' "$WORK/large-probe.out"
      status=1
      ;;
    *)
      echo "  the probe exited $probe_exit, which is neither a fault nor a clean read"
      sed 's/^/    /' "$WORK/large-probe.out"
      status=1
      ;;
  esac
fi

# Huge pages, Linux: the check in the program reads the kernel's own
# books - resident pages, and the flags it holds for an arena's two halves
# - and each half of the rule is proven to fail by name in a copy of the
# prelude: the refusal removed, and the refusal stretched over the whole
# arena. Both are the kernel's flags, not its huge pages to give, so both
# fail wherever THP is not `never`.
if [ "$(uname -s)" = Linux ]; then
  thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
  prove_huge_fails() {
    local label="$1" dir="$2" phrase="$3" script="$4"
    mkdir -p "$WORK/$dir/iyi"
    cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
    awk "$script" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"
    if cmp -s "$WORK/$dir/iyi/prelude.iyi" "$REPO/src/iyi/prelude.iyi"; then
      echo "  $label: the awk found nothing to change"; status=1; return
    fi
    if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/arena_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
      echo "  $label: the patched prelude did not build"; sed -n '1,12p' "$WORK/$dir/build.log"; status=1; return
    fi
    "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      echo "  $label: the exercise still passed, so it does not test this"; status=1; return
    fi
    if ! grep -q "$phrase" "$WORK/$dir/out"; then
      echo "  $label: failed, but not at the expected check"; sed -n '$p' "$WORK/$dir/out"; status=1; return
    fi
    printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
  }
  echo
  echo "== huge pages: the rule fails by name when either half is removed"
  case "$thp" in
    *"[never]"*) echo "  THP is never here: neither half has anything to show" ;;
    *)
      prove_huge_fails "small arenas take huge pages" hugesmall "panic: huge:" \
        '{ if ($0 ~ /^          __iyi_madvise_nohuge\(base, HUGE_AT\)$/) { print "          # removed"; next } print }'
      prove_huge_fails "a large arena is refused them too" hugenever "panic: huge:" \
        '{ if ($0 ~ /^          __iyi_madvise_nohuge\(base, HUGE_AT\)$/) { print "          __iyi_madvise_nohuge(base, MAP)"; next } print }'
      ;;
  esac
fi

echo
echo "== the allocation floor, measured against the -Dgc_iyi binary"
# The default program floor is `bench/dependency_floor.sh`'s to state, and it
# measures a plain build. This measures the build that floor cannot see. The
# Linux list is unchanged from that script's, because the arena allocator
# issues mmap and munmap as raw syscalls there and asks libc for nothing. The
# darwin list is that script's, every name libSystem's (Apple documents
# libSystem as the interface and raw syscalls as not a stable ABI), minus the
# file calls no exercise makes, plus `clock_gettime`, which is the exercise
# program's own stopwatch rather than the allocator's and is not on any
# sample's line. The list is exact and every entry is used: `malloc`,
# `memset` and `realloc` were here from before the collector became the
# default and would have let a fallback to libSystem's allocator pass; the
# kqueue, clock and dyld names arrived with the concurrency runtime and the
# owned collector and were never recorded here, because this gate did not
# run on darwin until the darwin job took it.
case "$(uname -s)" in
  Linux)
    allowed_symbols="ITM_deregisterTMCloneTable ITM_registerTMCloneTable _cxa_finalize _gmon_start__ _libc_start_main"
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  *) allowed_symbols="__error _tlv_bootstrap backtrace backtrace_symbols_fd madvise pipe pthread_create pthread_kill sigaction sigaltstack sysctlbyname read _dyld_get_image_header _dyld_get_image_vmaddr_slide clock_gettime clock_gettime_nsec_np exit kevent kqueue mmap munmap pthread_get_stackaddr_np pthread_self write" ;;
esac
allowed_libs="libSystem libc.so ld-linux libgcc_s"

if [ -z "$NM" ] || [ -z "$LIBS_READER" ]; then
  echo "  no nm and no otool or readelf here, so the allocation floor is not measured"
  unmeasured=$((unmeasured + 1))
elif [ -x "$WORK/exercise-gc" ]; then
  gc_syms="$(symbols "$WORK/exercise-gc")"
  gc_libs="$(libraries "$WORK/exercise-gc")"
  printf '  symbols   %s\n' "$(echo $gc_syms)"
  printf '  libraries %s\n' "$(echo $gc_libs)"

  extra_syms="$(unexpected "$allowed_symbols" "$(echo $gc_syms)")"
  if [ -n "$extra_syms" ]; then
    echo "  the arena allocator asks the machine for something new:"
    echo "$extra_syms" | sed 's/^/    /'
    echo "  Each is a dependency being taken on. If that is the decision, record it"
    echo "  here and in the commit (SPEC.md III.9)."
    status=1
  fi

  extra_libs="$(unexpected "$allowed_libs" "$(echo $gc_libs)")"
  if [ -n "$extra_libs" ]; then
    echo "  the arena allocator links something new:"
    echo "$extra_libs" | sed 's/^/    /'
    status=1
  fi
  [ -z "$extra_syms$extra_libs" ] && echo "  nothing new: the arena allocator costs no symbol and no library"
else
  echo "  no -Dgc_iyi binary to audit"
  status=1
fi

echo
echo "== the samples, both allocators, same output"
# The exercise is written to be exercised; the samples are what people run.
# Building each one both ways and diffing is what says the arena allocator is
# a drop-in rather than a thing with its own programs. `calc` reads standard
# input and falls back to its built-in source on EOF, so it gets /dev/null.
mkdir -p "$WORK/samples" && cp -r "$REPO/samples/iyi/." "$WORK/samples/"
for source in "$REPO"/samples/iyi/*.iyi; do
  sample="$(basename "$source" .iyi)"
  (
    cd "$WORK/samples" || exit 1
    if ! "$IYI" build -o "$WORK/$sample-default" "$sample.iyi" >"$WORK/$sample.default.log" 2>&1; then
      echo "  $sample: default build failed"
      exit 1
    fi
    if ! "$IYI" build -Dgc_iyi -o "$WORK/$sample-gc" "$sample.iyi" >"$WORK/$sample.gc.log" 2>&1; then
      echo "  $sample: -Dgc_iyi build failed"
      tail -8 "$WORK/$sample.gc.log"
      exit 1
    fi
    "$WORK/$sample-default" </dev/null >"$WORK/$sample.default.out" 2>&1
    default_exit=$?
    "$WORK/$sample-gc" </dev/null >"$WORK/$sample.gc.out" 2>&1
    gc_exit=$?
    if [ "$default_exit" -ne "$gc_exit" ]; then
      echo "  $sample: exit $default_exit default, $gc_exit under -Dgc_iyi"
      exit 1
    fi
    if ! diff -q "$WORK/$sample.default.out" "$WORK/$sample.gc.out" >/dev/null; then
      echo "  $sample: OUTPUT DIFFERS"
      diff "$WORK/$sample.default.out" "$WORK/$sample.gc.out" | head -10
      exit 1
    fi
    echo "  $sample: identical output, exit $default_exit"
  ) || status=1
done

echo
echo "== speed, same program, same machine, plain build and --release"
bump_ns="$(grep -m1 '^ *speed:' "$WORK/exercise-default.out" 2>/dev/null | awk '{ print $2 }')"
arena_ns="$(grep -m1 '^ *speed:' "$WORK/exercise-gc.out" 2>/dev/null | awk '{ print $2 }')"
pair_ns="$(grep 'alloc+free' "$WORK/exercise-gc.out" 2>/dev/null | awk '{ print $2 }')"
bump_rel="$(grep -m1 '^ *speed:' "$WORK/exercise-default-release.out" 2>/dev/null | awk '{ print $2 }')"
arena_rel="$(grep -m1 '^ *speed:' "$WORK/exercise-gc-release.out" 2>/dev/null | awk '{ print $2 }')"
pair_rel="$(grep 'alloc+free' "$WORK/exercise-gc-release.out" 2>/dev/null | awk '{ print $2 }')"
printf '  bump pointer      %s ns per allocation, %s ns --release\n' "${bump_ns:-?}" "${bump_rel:-?}"
printf '  size-class arena  %s ns per allocation, %s ns --release\n' "${arena_ns:-?}" "${arena_rel:-?}"
printf '  size-class arena  %s ns per alloc+free pair, %s ns --release\n' "${pair_ns:-?}" "${pair_rel:-?}"
echo "  A size-class allocator is expected to cost more than a bump pointer on"
echo "  the fast path. The number is reported rather than hidden, and it is the"
echo "  price of a heap that can hand memory back."

# And asserted, in release, where a program ships - against the bump
# pointer measured in the same run, not against a number typed here. The
# allocation is a thread-local cache pop and a header store: it has read
# 13 ns to the bump pointer's 11 on a twenty-core Linux box and 41 to its
# 28 on darwin's shared three-core runner, so the platform's own floor
# moves by two and a fixed ceiling of 40 ns failed the second machine
# while passing every regression the first one has seen. What a
# regression does is multiply: a lock taken per allocation read 39 ns
# against an 11 ns bump pointer, a sweep walked per refill 80 against 17.
# So the gate is the ratio, and the ratio is what a regression crosses -
# not a target to tune to, and checked rather than eyeballed because
# nobody reads a printed number twice.
#
# Of the *minimum* of three runs each, which is the same answer this
# repository gives noise everywhere else (`bench/daemon_full_build.py`:
# "build time has a floor and noise only ever adds"). One sample per arm
# failed a darwin runner at 44 ns against a 13 ns bump - 3.4x - on a
# commit that touched neither allocator: a shared three-core box that
# happened to give the bump pointer its best run and the arena one of its
# worst. A regression multiplies every run, so it survives a minimum; a
# runner's weather does not.
ALLOCATION_RATIO=${ALLOCATION_RATIO:-25}
ALLOCATION_RUNS=${ALLOCATION_RUNS:-3}

min_ns() { # binary, awk-selectable line
  local binary="$1" pattern="$2" best="" value=""
  local run=1
  while [ "$run" -le "$ALLOCATION_RUNS" ]; do
    value="$("$binary" 2>/dev/null | grep -m1 "$pattern" | awk '{ print $2 }')"
    case "$value" in
      '' | *[!0-9]*) : ;;
      *) if [ -z "$best" ] || [ "$value" -lt "$best" ]; then best="$value"; fi ;;
    esac
    run=$((run + 1))
  done
  printf '%s' "$best"
}

if [ -x "$WORK/exercise-default-release" ] && [ -x "$WORK/exercise-gc-release" ]; then
  bump_rel="$(min_ns "$WORK/exercise-default-release" '^ *speed:')"
  arena_rel="$(min_ns "$WORK/exercise-gc-release" '^ *speed:')"
  pair_rel="$(min_ns "$WORK/exercise-gc-release" 'alloc+free')"
  printf '  best of %s: bump %s ns, arena %s ns, pair %s ns\n' \
    "$ALLOCATION_RUNS" "${bump_rel:-?}" "${arena_rel:-?}" "${pair_rel:-?}"
fi

ratio_holds() { # name arena bump
  [ -n "$2" ] && [ -n "$3" ] && [ "$3" -gt 0 ] || return 0
  if [ $(( $2 * 10 )) -gt $(( $3 * ALLOCATION_RATIO )) ]; then
    echo "  FAIL: $1 costs $2 ns in release against the bump pointer's $3, past $((ALLOCATION_RATIO / 10)).$((ALLOCATION_RATIO % 10))x"
    status=1
  fi
}
ratio_holds "an allocation" "$arena_rel" "$bump_rel"
ratio_holds "an alloc+free pair" "$pair_rel" "$bump_rel"

echo
if [ "$status" -ne 0 ]; then
  echo "the arena allocator did not hold"
elif [ "$unmeasured" -gt 0 ]; then
  # A summary may not claim more than was measured: an arm whose reader is
  # missing is counted here rather than folded into the pass.
  echo "the arena allocator holds, with $unmeasured check not measured here"
else
  echo "the arena allocator holds"
fi
exit $status
