#!/usr/bin/env bash
# heap22's crossings (design B, rows 1-4b, 7-9, 13, 14, 16, 21), driven:
# bench/heap_crossings.iyi built with partitions and the verifier's
# poison-on-free, plain and optimised, every check passing; then one
# broken copy of the runtime or std per mechanism, each removing exactly
# that mechanism, and each caught by the check of its row.
#
#   bash bench/heap_crossings.sh
#
# Needs `make` first, and a runtime with S1's partitions (`IyiHeap.
# collect_local`, poison under `-Dheap_verify`). `FLAGS` replaces the build
# flags (default `-Dheap_partitions -Dheap_verify`); `FLAGS=` runs the
# flag-off control alone, every check passing and no copy built.
# `RELEASE_COPIES=1` builds each copy `--release` as well (Linux: the
# gate's ~60 s become ~210-260 s; every copy caught, 3 runs each on
# Linux, tmac and tssh at h22/fu-scrub). Exits non-zero if any step fails.
#
# A copy is caught when its program exits non-zero: a `FAIL: <row>` line,
# the verifier's report at a collection (`-Dheap_verify`, exit 86), or
# the crash a poisoned word makes (a signal, or Windows' access
# violation). A hang is ended at 120 s and counts as caught too, and is
# named so. Neither the poison nor the verifier is deterministic - a word
# a register or a frame still holds keeps an unpublished graph alive
# through the collection, and a marked chunk is neither freed nor
# reported (`Mutex.new capture publish` and `Box pin` passed on Linux,
# `Mutex capture publish` on tmac and tssh) - so the checks of rows 1,
# 1c, 1d, 2b, 3, 4, 4b, 9, 13, 14 and 21 also ask, where the graph
# crossed and before any collection, whether it is published or the
# shared heap's, or not its maker's (`IyiHeap.local?`, `owner_of`). Row
# 2's answer is freed whole at its unit's death, which marks nothing.
# Mechanisms none of these can show - the reference is still rooted on a
# stack, a second crossing publishes it again, or the answer's detach
# covers it - are listed at the end as the verifier's (S4,
# `-Dheap_verify`'s scan): no copy is built for them here.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
FLAGS="${FLAGS--Dheap_partitions -Dheap_verify}"
RELEASE_COPIES="${RELEASE_COPIES:-0}"

WINDOWS=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    WINDOWS=1
    ;;
  *) PSEP=':' ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0

run_case() { # label name build-flags
  local label="$1" name="$2" flags="$3"
  # shellcheck disable=SC2086
  if ! "$IYI" build $FLAGS $flags -o "$WORK/$name" "$REPO/bench/heap_crossings.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  timeout 300 "$WORK/$name" >"$WORK/$name.out" 2>&1
  local code=$?
  sed 's/^/  /' "$WORK/$name.out" | grep -v "panics here on purpose" | grep -v "^  *from \|^  *at \|^  *[0-9a-fx]* in "
  if [ "$code" -ne 0 ]; then
    echo "$label: exit $code"
    status=1
  fi
}

echo "== the crossings, plain ($FLAGS)"
run_case "plain" plain ""
echo "== the crossings, optimised ($FLAGS)"
run_case "release" release "--release"

case "$FLAGS" in
  *heap_partitions*) ;;
  *)
    echo
    [ "$status" -eq 0 ] && echo "heap_crossings: the flag-off control holds."
    exit "$status"
    ;;
esac

echo
echo "== each crossing's mechanism removed, caught by its check"
# label dir check-name awk-script tree file [compiler-env [release]]
# The optional seventh, `NAME=value`, is set for the build: a mechanism
# the compiler emits (S3) is removed by `IYI_SPAWN_BROKEN`, not a patch.
# The eighth, `release`, builds the copy `--release`.
prove_caught() {
  local label="$1" dir="$2" check="$3" script="$4" tree="$5" file="$6" compiler_env="${7:-IYI_SPAWN_BROKEN=}" opt=""
  [ "${8:-}" = release ] && opt="--release"
  # Both trees, whichever one the copy changes: the compiler takes a file
  # for std's only where its directory's parent holds `iyi/prelude.iyi`
  # (`ShareReach#std_at?`), and a std copy without the prelude beside it
  # was a program's module there - head 2 ran the Mutex rows' spawns
  # pinned in the shared heap, and the three copies "still passed".
  mkdir -p "$WORK/$dir"
  cp -R "$REPO/src/iyi" "$REPO/src/std" "$WORK/$dir/"
  if ! awk "$script" "$REPO/src/$tree/$file" > "$WORK/$dir/$tree/$file"; then
    echo "  $label: what the copy changes is not in $tree/$file any more"
    status=1
    return
  fi
  # shellcheck disable=SC2086
  if ! env "$compiler_env" IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build $FLAGS $opt \
       -o "$WORK/$dir/program" "$REPO/bench/heap_crossings.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched tree did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout 120 "$WORK/$dir/program" "$check" >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the check '$check' still passed, so it does not test this"
    status=1
    return
  fi
  local how
  if [ "$code" -eq 124 ]; then
    how="a hang, ended at 120 s"
  elif grep -q "^FAIL: " "$WORK/$dir/out"; then
    how="$(grep -m1 "^FAIL: " "$WORK/$dir/out" | sed 's/^FAIL: //')"
  elif [ "$code" -eq 86 ] && grep -q "^iyi: heap_verify: " "$WORK/$dir/out"; then
    how="the verifier: $(grep -m1 "^iyi: heap_verify: " "$WORK/$dir/out" | sed 's/^iyi: heap_verify: //')"
  else
    how="a crash (exit $code)"
  fi
  printf '  %s: %s: %s\n' "$label" "$check" "$how"
}

# One line deleted after a marker: `del MARKER LINE` as an awk program.
del() {
  printf '/%s/ { armed = 1 } armed && /%s/ { armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' "$1" "$2"
}
# One line rewritten after a marker: `sub MARKER FROM TO`.
subst() {
  printf '/%s/ { armed = 1 } armed && sub(/%s/, "%s") { armed = 0; found = 1 } { print } END { if (!found) exit 3 }' "$1" "$2" "$3"
}
# Each copy built plain, then `--release` under `RELEASE_COPIES=1`: what a
# check keeps live across a collection is the optimiser's to keep or drop.
# Defaulted here too: bench/heap_verify.sh sources this function without
# the line above, under `set -u`.
caught_both() { # label dir check-name awk-script tree file [compiler-env]
  prove_caught "$@"
  [ "${RELEASE_COPIES:-0}" = 1 ] || return 0
  prove_caught "$1, built \`--release\`" "$2-rel" "$3" "$4" "$5" "$6" "${7:-IYI_SPAWN_BROKEN=}" release
}

# Row 1: the spawn's captures not published.
caught_both "spawn publish" r1 spawn \
  "$(del 'private def on_pool\(pinned' '^      IyiCross\.publish\(block\)$')" iyi concurrency.iyi
# Row 1c: the thread's captures not published.
caught_both "thread publish" r1c thread \
  "$(del 'def self\.start\(proc : Proc' '^      IyiCross\.publish\(proc\)$')" iyi thread.iyi
# Row 1d: spawn(in:)'s captures not published.
caught_both "spawn(in:) publish" r1d in \
  "$(del 'def spawn\(\*, in owner : Unit\(S\), &block' '^    IyiCross\.publish\(block\)$')" iyi concurrency.iyi
# Row 2: the answer left a store into the box, no merge.
caught_both "answer merge" r2 answer \
  "$(subst 'def finish\(value : T\)' 'IyiHeap\.answer\(@box, value\)' '@box << value')" iyi concurrency.iyi
# Row 2b: a Unit task's answer not published.
caught_both "Unit answer publish" r2b unit_answer \
  "$(del 'private def unit_work' '^      IyiCross\.publish\(answer\)$')" iyi concurrency.iyi
# Row 3: a send's value not published.
caught_both "send publish" r3 channel \
  "$(del 'def send\(value : T\)' '^    IyiCross\.publish\(value\)$')" iyi concurrency.iyi
caught_both "select send publish" r3s select \
  "$(del 'def send_select_action' '^    IyiCross\.publish\(value\)$')" iyi concurrency.iyi
# Row 3: the ring grown in the sender's partition.
caught_both "ring growth shared" r3g ring \
  "$(subst 'private def push_item' 'IyiCross\.shared \{ Pointer\(T\)\.malloc\(\(@slots \* 2\)\.to_u64\) \}' 'Pointer(T).malloc((@slots * 2).to_u64)')" iyi concurrency.iyi
# Row 4: a Unit's value made in its maker's partition.
caught_both "Unit.new routing" r4 unit_new \
  "$(subst 'def self\.new\(\*, pinned' 'IyiHeap\.within\(unit\.heap\) \{ block\.call \}' 'block.call')" std unit.iyi
# Row 4b: a lock block's captures not published; a lock block allocating
# in the holder's partition; Mutex.new's captures not published.
caught_both "Mutex capture publish" r4b mutex_capture \
  "$(del 'def lock\(&block' '^    IyiCross\.publish\(block\)$')" std mutex.iyi
caught_both "Mutex shared bracket" r4bs mutex_bracket \
  "$(subst 'def lock\(&block' 'IyiCross\.shared \{ block\.call\(@value\) \}' 'block.call(@value)')" std mutex.iyi
caught_both "Mutex.new capture publish" r4bn mutex_new \
  "$(del 'def self\.new\(&block : -> U\) : Mutex' '^    IyiCross\.publish\(block\)$')" std mutex.iyi
# The runtime's own links out of a bracket (S6): a drained cleanup's link
# - a Mutex's release node over the unit's cleanup, through a panic and a
# cancelled task's stop - and a joined group's `outer`, each left naming
# the unit's own chunk. Caught by `-Dheap_verify` (the death check, the
# check at the unit's collection), exit 86.
caught_both "defer drain unlink (panic)" rdd defer_drain \
  "$(del 'def self\.drain_defers\(fiber' '^        node\.next_node = nil$')" iyi concurrency.iyi
caught_both "defer drain unlink (stop)" rds defer_stop \
  "$(del 'def self\.drain_defers\(fiber' '^        node\.next_node = nil$')" iyi concurrency.iyi
caught_both "group outer unlink" rgo group_outer \
  "$(del 'def join\(early : Bool' '^      @outer = nil$')" iyi concurrency.iyi
# Row 9: Box, GC.malloc and ReferenceStorage pin nothing.
caught_both "Box pin" r9b box \
  "$(del 'def self\.box\(object : T\)' '^    IyiCross\.pin$')" std box.iyi
caught_both "GC.malloc pin" r9m malloc \
  "$(del 'def self\.malloc\(size : Int\)' '^    IyiCross\.pin$')" std gc.iyi
caught_both "ReferenceStorage pin" r9r storage \
  "$(del 'def self\.unsafe_construct' '^    IyiCross\.pin$')" std reference_storage.iyi
# Row 13: ENV's table made in the setter's partition. Not on Windows:
# there `ENV[]=` writes to the platform (`SetEnvironmentVariableW`) and
# iyi keeps no table of its own, so there is no bracket to remove.
if [ "$WINDOWS" -eq 1 ]; then
  echo "  ENV shared: skipped on Windows, ENV is written to the platform and iyi keeps no table to make shared"
else
  caught_both "ENV shared" r13 env \
    "$(subst 'def self\.\[\]=\(key : String' 'IyiCross\.shared do' 'begin')" std env.iyi
fi
# Row 14: a crossing task's glue made in the spawner's partition, and the
# new unit's object.
caught_both "pooled glue shared" r14 glue \
  "$(subst 'private def pooled\(unit : IyiUnit' 'task = IyiCross\.shared do' 'task = begin')" iyi concurrency.iyi
# The new unit's object: born in the shared heap by codegen
# (`__iyi_new_shared`, S3), which the compiler's `new-shared` copy turns off.
caught_both "IyiUnit shared" r14u glue '{ print }' iyi concurrency.iyi IYI_SPAWN_BROKEN=new-shared
# Row 16: TlsIdentity lends its chain.
caught_both "TlsIdentity chain copy" r16 tls \
  "$(subst 'def chain : Array\(Array\(UInt8\)\)' '@chain\.map\(&\.dup\)' '@chain')" std tls.iyi
# Row 21: a List's elements not published.
caught_both "List publish" r21 list \
  "$(del 'def initialize\(items : Array\(T\)\)' 'IyiCross\.publish\(item\)')" std list.iyi
# The scheduler's list of closes posted to another thread, made in the
# closer's partition. Not on Windows, which posts no list.
if [ "$WINDOWS" -eq 1 ]; then
  echo "  closed list shared: skipped on Windows, a close there ends the posted operation and no list is made"
else
  caught_both "closed list shared" r22 closed \
    "$(subst 'def self\.wake_closed\(fd : Int32\)' 'IyiCross\.shared do' 'begin')" iyi concurrency.iyi
fi

echo
echo "== the verifier's (S4): mechanisms whose loss no poison shows here"
echo "  send nodes and receive waiters in the shared heap: each is rooted by its parked fiber's stack while linked"
echo "  a channel's first ring in the shared heap: the channel is published with it at its first crossing"
echo "  a same-unit task's fiber in the shared heap: its group's child list roots it"
echo "  Mutex.new's bracket, List's copy in the shared heap: the carrying crossing publishes them"
echo "  SharedProc.of's publish: the crossing that carries the SharedProc publishes its closure again"
echo "  a WeakRef's cell in the shared heap; Windows' process-wait words: rooted by the waiting frame"
echo "  on_main's glue in the shared heap: a MAIN-placed Unit is made pinned, so nothing there is local"
echo "  a panic's message published: the Panicked answer detaches the partition, never collected locally, the shared heap's at death"

echo
if [ "$status" -eq 0 ]; then
  echo "heap_crossings: every crossing holds, and each fails when its mechanism is removed."
fi
exit "$status"
