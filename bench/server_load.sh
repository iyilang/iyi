#!/usr/bin/env bash
# Drives bench/server_load.iyi: the shape every server has — a fiber per
# connection, both halves parked on the poller, a collection in the
# middle — and the two things that shape used to break.
#
#     bash bench/server_load.sh
#
# Four steps, and two of them are failure proofs, because a gate that
# cannot fail is not a gate:
#
#   1. The program holds, plain build: two hundred connections answered,
#      the collector runs while fibers are parked, nothing is damaged,
#      and the connections ran on a handful of stacks rather than two
#      hundred.
#   2. The same, release.
#   3. Failure proof: the poller's event buffer held as an address again
#      — a `UInt64` where the field is a pointer — and the collector,
#      precise over a typed object's fields, cannot see it. The kernel
#      writes epoll's answers into a chunk the allocator has handed to
#      somebody else and the program dies. This is `wrk -c 100` against
#      the sample web application, made small.
#      On Windows, the fiber's OVERLAPPED held the same way, and the
#      exercise's collection between a read and a write finds it freed.
#   4. Failure proof: a finished fiber's stack not handed back, and the
#      two hundred connections take two hundred mappings.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

cd "$WORK" || exit 1

step() { echo "== $1"; }

# Windows has a poller and sockets now — a completion port under the same
# `IyiScheduler`, and `std/socket`'s Winsock arm over it — so this drives
# there too. The line it used to print, that the poller is Linux's and
# darwin's, was true when it was written and stopped being true without
# anything here noticing.
case "$(uname -s)" in
  Linux | Darwin | MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *) echo "server load: this platform has no poller to drive; nothing to measure here"; exit 0 ;;
esac

step "a server's shape, plain build"
if ! "$IYI" build "$REPO/bench/server_load.iyi" -o server > build.log 2>&1; then
  cat build.log; exit 1
fi
if ! timeout 300 ./server > answers.txt 2>&1; then
  echo "the run failed:"; cat answers.txt; exit 1
fi
grep -q 'every property held' answers.txt || { cat answers.txt; exit 1; }
grep -E '^(collections|answers|stacks|canary) ' answers.txt | sed 's/^/  /'

step "a server's shape, release build"
if ! "$IYI" build --release "$REPO/bench/server_load.iyi" -o server-release > build-release.log 2>&1; then
  cat build-release.log; exit 1
fi
if ! timeout 300 ./server-release > answers-release.txt 2>&1; then
  echo "the release run failed:"; cat answers-release.txt; exit 1
fi
grep -q 'every property held' answers-release.txt || { cat answers-release.txt; exit 1; }

mkdir -p patched/iyi
cp "$REPO"/src/iyi/*.iyi patched/iyi/

# This proof injects its defect into what the kernel writes into: the
# event buffer `epoll_wait` and `kevent` fill, and on Windows, whose poller
# is a completion port with no such buffer, the fiber's OVERLAPPED - held
# as a number, the way the event buffer was. Storing it that way passed
# every run until the exercise collected where only the field holds it,
# between a connection's read and its write; it asks there now. The size
# is matched, not written: the OVERLAPPED grew from 32 bytes to 40 with the
# worker its completion belongs to, and the sed found one line of two
# (job 121201606737). The check ends the run with `__iyi_exit` rather than
# a panic. After it the heap is corrupt, and a panic's cancelled siblings
# wait for packets that a freed OVERLAPPED's garbage owner word gets
# dropped: the run then hung after its panic line (job 123987176637;
# server_load.iyi says more).
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    step "failure proof: the fiber's OVERLAPPED as a number is an OVERLAPPED nobody keeps"
    sed -e 's/^  property wait_overlapped : Pointer(UInt8)$/  property wait_overlapped_word : UInt64\n\n  def wait_overlapped : Pointer(UInt8)\n    Pointer(UInt8).new(@wait_overlapped_word)\n  end/' \
        -e 's/^    @wait_overlapped = IyiCross\.shared { Pointer(UInt8)\.malloc(\([0-9]*\)_u64) }$/    @wait_overlapped_word = IyiCross.shared { Pointer(UInt8).malloc(\1_u64) }.address/' \
        "$REPO/src/iyi/concurrency.iyi" > patched/iyi/concurrency.iyi
    [ "$(diff "$REPO/src/iyi/concurrency.iyi" patched/iyi/concurrency.iyi | grep -c '^>')" -eq 6 ] || {
      echo "the sed did not find both lines it changes"; exit 1; }
    if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build "$REPO/bench/server_load.iyi" -o hidden > build-hidden.log 2>&1; then
      cat build-hidden.log; exit 1
    fi
    timeout -k 5 300 ./hidden > hidden.txt 2>&1
    code=$?
    if [ "$code" -ne 1 ] || ! grep -qF "FAIL: a collection between a connection's read and its write freed the OVERLAPPED the write hands the kernel" hidden.txt; then
      echo "an OVERLAPPED the collector cannot see survived the run, so the run proves nothing (exit $code):"
      tail -3 hidden.txt; exit 1
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 'freed the OVERLAPPED' hidden.txt | sed 's/^FAIL: //')"
    ;;
  *)
    step "failure proof: the poller's buffer as a number is a buffer nobody keeps"
    sed -e 's/^  property events : Pointer(UInt8)$/  property events : UInt64/' \
        -e 's/^    @events = Pointer(UInt8)\.new(0_u64)$/    @events = 0_u64/' \
        -e 's/^    return buffer\.address if buffer\.address != 0_u64$/    return buffer if buffer != 0_u64/' \
        -e 's/^    buffer = IyiCross\.shared { Pointer(UInt8)\.malloc((EVENTS \* IYI_POLL_EVENT_BYTES)\.to_u64) }$/    buffer = IyiCross.shared { Pointer(UInt8).malloc((EVENTS * IYI_POLL_EVENT_BYTES).to_u64) }.address/' \
        -e 's/^    buffer\.address$/    buffer/' \
        "$REPO/src/iyi/concurrency.iyi" > patched/iyi/concurrency.iyi
    # Every one of the five lines, counted: a sed that found four of them left
    # the buffer a pointer, and the copy failed to compile instead of failing
    # the run (heap22 put the malloc inside `IyiCross.shared { ... }`).
    [ "$(diff "$REPO/src/iyi/concurrency.iyi" patched/iyi/concurrency.iyi | grep -c '^>')" -eq 5 ] || {
      echo "the sed did not find all five lines it changes"; exit 1; }
    # One run, and the run decides. The copy's buffer is freed by the first
    # collection a connection makes after its read, so the copy dies on its
    # first connection with its own sentence. The check is a count of
    # collections, not a race, so there is no run count and no timing bound.
    if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build "$REPO/bench/server_load.iyi" -o hidden > build-hidden.log 2>&1; then
      cat build-hidden.log; exit 1
    fi
    timeout 300 ./hidden > hidden.txt 2>&1
    code=$?
    if [ "$code" -ne 1 ] || ! grep -qF "FAIL: a collection freed the poller's event buffer, which the kernel writes into" hidden.txt; then
      echo "a buffer the collector cannot see was not caught on its one run (exit $code):"
      tail -3 hidden.txt; exit 1
    fi
    printf '  exits 1 at "%s"\n' "$(grep -m1 'freed the poller' hidden.txt | sed 's/^FAIL: //')"
    ;;
esac

step "failure proof: a stack nobody hands back is a stack per connection"
cp "$REPO"/src/iyi/*.iyi patched/iyi/
sed -e 's/^    fiber\.release_stack$/    # the stack is not handed back/' \
    "$REPO/src/iyi/concurrency.iyi" > patched/iyi/concurrency.iyi
cmp -s patched/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && {
  echo "the sed found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build "$REPO/bench/server_load.iyi" -o noreuse > build-noreuse.log 2>&1; then
  cat build-noreuse.log; exit 1
fi
timeout 300 ./noreuse > noreuse.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -qF "FAIL: the stacks were not reused - 200 of them for 200 connections" noreuse.txt; then
  echo "the stack-reuse check did not fire (exit $code):"; tail -3 noreuse.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'the stacks were not reused' noreuse.txt | sed 's/^iyi: panic: FAIL: //')"
echo "workdir $WORK"
echo "server load: every step held"
exit 0
