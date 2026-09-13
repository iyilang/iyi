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
#   4. Failure proof: a finished fiber's stack not handed back, and the
#      two hundred connections take two hundred mappings.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
cd "$WORK" || exit 1

step() { echo "== $1"; }

case "$(uname -s)" in
  Linux | Darwin) ;;
  *) echo "server load: the poller is Linux's and darwin's; nothing to drive here"; exit 0 ;;
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

step "failure proof: the poller's buffer as a number is a buffer nobody keeps"
sed -e 's/^  property events : Pointer(UInt8)$/  property events : UInt64/' \
    -e 's/^    @events = Pointer(UInt8)\.new(0_u64)$/    @events = 0_u64/' \
    -e 's/^    return buffer\.address if buffer\.address != 0_u64$/    return buffer if buffer != 0_u64/' \
    -e 's/^    buffer = Pointer(UInt8)\.malloc((EVENTS \* IYI_POLL_EVENT_BYTES)\.to_u64)$/    buffer = Pointer(UInt8).malloc((EVENTS * IYI_POLL_EVENT_BYTES).to_u64).address/' \
    -e 's/^    buffer\.address$/    buffer/' \
    "$REPO/src/iyi/concurrency.iyi" > patched/iyi/concurrency.iyi
cmp -s patched/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && {
  echo "the sed found nothing to change"; exit 1; }
# The one arm here whose defect arrives by timing rather than by counting:
# the freed chunk has to be handed to a canary *and* the kernel has to write
# events into it before the run ends. Two hundred connections is enough on
# every machine that wrote this file and was not enough once on a loaded CI
# runner, where the hidden buffer was freed (the exercise refuses a run that
# collected nothing) and simply never reused. Measured on a machine held at
# sixteen times its cores: at two hundred rounds four of twenty-four runs
# survived the collector, at a thousand none of twenty-four, at two thousand
# none of twelve. A run that dies does it in the first collections, so the
# longer arm still costs about a second and a half. The claim is unchanged;
# the trials are more.
mkdir -p load
# The formatter aligns `ROUNDS` with the constant under it, so the pattern
# takes the run of spaces that alignment leaves; the `cmp` below is what
# proves the line was actually found.
sed -E 's/^ROUNDS[[:space:]]+= 200$/ROUNDS = 2000/' "$REPO/bench/server_load.iyi" > load/server_load.iyi
cmp -s load/server_load.iyi "$REPO/bench/server_load.iyi" && {
  echo "the rounds line moved; this proof is running at the plain size"; exit 1; }
if ! IYI_PATH="$WORK/patched:$REPO/src" "$IYI" build "$WORK/load/server_load.iyi" -o hidden > build-hidden.log 2>&1; then
  cat build-hidden.log; exit 1
fi
timeout 300 ./hidden > hidden.txt 2>&1
code=$?
if [ "$code" -eq 0 ] || grep -q 'every property held' hidden.txt; then
  echo "a buffer the collector cannot see survived the run, so the run proves nothing:"
  grep -E '^(collections|answers|stacks|canary) ' hidden.txt | sed 's/^/  /'
  tail -2 hidden.txt; exit 1
fi
printf '  exits %s\n' "$code"

step "failure proof: a stack nobody hands back is a stack per connection"
cp "$REPO"/src/iyi/*.iyi patched/iyi/
sed -e 's/^    fiber\.release_stack$/    # the stack is not handed back/' \
    "$REPO/src/iyi/concurrency.iyi" > patched/iyi/concurrency.iyi
cmp -s patched/iyi/concurrency.iyi "$REPO/src/iyi/concurrency.iyi" && {
  echo "the sed found nothing to change"; exit 1; }
if ! IYI_PATH="$WORK/patched:$REPO/src" "$IYI" build "$REPO/bench/server_load.iyi" -o noreuse > build-noreuse.log 2>&1; then
  cat build-noreuse.log; exit 1
fi
timeout 300 ./noreuse > noreuse.txt 2>&1
code=$?
if [ "$code" -ne 1 ] || ! grep -q 'the stacks were not reused' noreuse.txt; then
  echo "the stack-reuse check did not fire (exit $code):"; tail -3 noreuse.txt; exit 1
fi
printf '  exits 1 at "%s"\n' "$(grep -m1 'the stacks were not reused' noreuse.txt | sed 's/^iyi: panic: FAIL: //')"

echo "workdir $WORK"
echo "server load: every step held"
exit 0
