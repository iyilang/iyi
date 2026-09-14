#!/usr/bin/env bash
# Drives bench/thread_exercise.iyi: kernel threads under the collector —
# GC_DESIGN.md Stage 4, the stop-the-world, built (src/iyi/thread.iyi).
#
#     bash bench/thread_exercise.sh
#
# Six steps, and the last two are failure proofs, because a gate that cannot
# fail is not a gate:
#
#   1. The program holds every property, plain and --release, with eight
#      threads: each allocates from its own cache while collections run
#      from whichever thread crosses the budget; each holds a live list in
#      nothing but its own frames through those collections and finds it
#      intact, by checksum and by the sweep's own free flag; each runs
#      fibers of its own, one parked holding an object's only reference;
#      collections stopped threads; and the program finishes, which is the
#      proof no stop deadlocked on the runtime lock or on a thread inside
#      the allocator.
#   2. The binary keeps the floor. On Linux the runtime's five C-template
#      names and nothing else: a thread by raw `clone`, a stop by `tgkill`
#      and `rt_sigaction`, a park by `futex`, all syscalls. On darwin the
#      exact list: the runtime's names plus what a thread costs there,
#      the thread floor's list, spelled out.
#   3. The numbers, printed from the release run: allocations per thread,
#      collections, stops, and the wall time per allocation per thread at
#      1, 4 and 8 threads. Reported rather than budgeted.
#   4. The same, twice the cores' worth of threads, release — past the core count —
#      because a thread stopped while it has no CPU is the case the
#      floor's table said costs the timeslice, and the properties must hold
#      there too.
#   5. Failure proof: the thread-root walk removed from a copy of the
#      prelude, and a thread's list — reachable from its stopped frames
#      alone — is swept out from under it; the program exits 1 naming the
#      node on a free list.
#   6. Failure proof: a block that captures a value whose type is not
#      `Share` (SPEC.md III.4.4) does not compile, and the error names the
#      variable, its type and the field that made it mutable.
#
# Linux x86_64 and aarch64, darwin aarch64.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"

cd "$WORK" || exit 1

step() { echo "== $1"; }

case "$(uname -s)" in
  Linux | Darwin) ;;
  *)
    echo "thread exercise: measured on Linux and darwin; nothing to measure here"
    exit 0
    ;;
esac

# ── 1. The program, twice ─────────────────────────────────────────────────
step "threads under the collector, plain build"
if ! "$IYI" build "$REPO/bench/thread_exercise.iyi" -o threads > build.log 2>&1; then
  cat build.log; exit 1
fi
if ! timeout 300 ./threads 8 > answers.txt 2>&1; then
  cat answers.txt; exit 1
fi
grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }

step "threads under the collector, release build"
if ! "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o threads-release > build-release.log 2>&1; then
  cat build-release.log; exit 1
fi
if ! timeout 300 ./threads-release 8 > answers-release.txt 2>&1; then
  cat answers-release.txt; exit 1
fi
grep -q 'every property held' answers-release.txt || { cat answers-release.txt; exit 1; }

# ── 2. The floor ──────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux)
    step "dependency floor: threads and their stop add no symbol"
    for bin in threads threads-release; do
      added="$(nm -u "$bin" |
        sed -e 's/^ *[wU] *//' -e 's/@.*$//' |
        grep -v -E '^(_ITM_deregisterTMCloneTable|_ITM_registerTMCloneTable|__cxa_finalize|__gmon_start__|__libc_start_main)$' |
        grep -cv '^\s*$')"
      if [ "$added" -ne 0 ]; then
        echo "$bin put $added undefined symbols on the link line:"
        nm -u "$bin"
        exit 1
      fi
    done
    echo "  five template names and nothing else, plain and release"
    ;;
  Darwin)
    # The runtime's list (bench/dependency_floor.sh), the concurrency
    # exercise's `mprotect` (a fiber stack's guard page), and the thread
    # floor's thread list: pthread_create, pthread_join, pthread_kill and
    # sigaction for the thread and the stop, pipe/read/write for the park,
    # __tlv_bootstrap for the thread-locals. Nothing else.
    step "dependency floor: what threads cost darwin, by name"
    runtime='___error __dyld_get_image_header __dyld_get_image_vmaddr_slide __tlv_bootstrap _clock_gettime_nsec_np _exit _kevent _kqueue _madvise _mmap _mprotect _munmap _pthread_create _pthread_get_stackaddr_np _pthread_self _sigaction _sigaltstack _sysctlbyname _write'
    thread='_pipe _pthread_create _pthread_join _pthread_kill _read'
    for bin in threads threads-release; do
      allowed="$(printf '%s\n' $runtime $thread | sort -u)"
      found="$(nm -u "$bin" | sed -e 's/^ *//' | awk '{ print $NF }' | sort -u)"
      extra="$(comm -13 <(echo "$allowed") <(echo "$found"))"
      if [ -n "$extra" ]; then
        echo "$bin asks libSystem for more than the list:"
        echo "$extra" | sed 's/^/  /'
        exit 1
      fi
      libs="$(otool -L "$bin" | sed -n '2,$p' | awk '{ print $1 }' | grep -v -E '^/usr/lib/libSystem' | grep -cv '^$')"
      if [ "$libs" -ne 0 ]; then
        echo "$bin links something beyond libSystem:"; otool -L "$bin"; exit 1
      fi
    done
    echo "  the runtime's names and the thread floor's, and nothing else"
    ;;
esac

# ── 3. The numbers ────────────────────────────────────────────────────────
cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
step "the numbers, release build ($cores cores here)"
grep -E '^(threads|speed):' answers-release.txt | sed 's/^/  /'

# ── 4. Past the core count ────────────────────────────────────────────────
# Twice the cores, at least nine and at most 32: past the core count on
# any runner, and within a runner's patience - 32 threads on the darwin
# runner's three cores are a stop of 33 for every one of the three that
# can run, and the step outlived its five minutes there.
over=$((cores * 2))
[ "$over" -lt 9 ] && over=9
[ "$over" -gt 32 ] && over=32
step "the same, $over threads, release (past the $cores cores here)"
if ! timeout 300 ./threads-release "$over" > answers-32.txt 2>&1; then
  cat answers-32.txt; exit 1
fi
grep -q 'every property held' answers-32.txt || { cat answers-32.txt; exit 1; }
grep -E '^threads:' answers-32.txt | sed 's/^/  /'

# ── 5. Failure proof: a stopped thread's frames are roots ─────────────────
# The walk over stopped threads removed from the root set, in a copy of
# the prelude built against through IYI_PATH; nothing in the tree is
# touched. Every collection another thread triggers then frees this
# thread's list, and the check names the node on a free list.
step "failure proof: without the thread-root walk a live list is swept"
mkdir -p patched/iyi
cp "$REPO"/src/iyi/*.iyi patched/iyi/
awk '{ sub(/each_thread_root\(visit\)/, "each_global_root(visit)"); print }' \
  "$REPO/src/iyi/prelude.iyi" > patched/iyi/prelude.iyi
cmp -s patched/iyi/prelude.iyi "$REPO/src/iyi/prelude.iyi" && { echo "the awk found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/patched:$REPO/src" "$IYI" build --release "$REPO/bench/thread_exercise.iyi" -o unrooted > build-unrooted.log 2>&1; then
  cat build-unrooted.log; exit 1
fi
timeout 120 ./unrooted 8 > unrooted.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q "on a free list" unrooted.txt; then
  echo "the live-list check did not fire (exit $code):"; tail -5 unrooted.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'on a free list' unrooted.txt)"

# ── 6. Share: what a thread's block may capture is decided at compile time ─
# SPEC.md III.4.4's marker, gating III.4.11's block: a value whose type has
# a mutable field — here an `Array`, whose size is assigned by its own
# methods — cannot be captured by a block another thread runs, and the
# compiler names the variable, the type and the field that failed. The
# exercise itself captures integers and passes; this program must not
# compile.
step "failure proof: a block capturing a mutable value does not compile"
cat > unshared.iyi <<'IYI'
items = [1, 2, 3]
t = IyiThread.start do
  items.size
  nil
end
t.join
IYI
if "$IYI" build unshared.iyi -o unshared > build-unshared.log 2>&1; then
  echo "a block capturing an Array compiled:"; cat build-unshared.log; exit 1
fi
if ! grep -q "captures \`items : Array(Int32)\`, which is not Share" build-unshared.log; then
  echo "the refusal did not name the capture:"; cat build-unshared.log; exit 1
fi
printf '  refused: %s\n' "$(grep -m1 'is not Share' build-unshared.log | sed 's/^Error: //')"

echo "workdir $WORK"
echo "thread exercise: every step held"
exit 0
