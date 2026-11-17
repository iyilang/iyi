#!/usr/bin/env bash
# heap22 slice S1's local collections, driven: bench/heap_local.iyi built
# with partitions and the verifying build's poison-on-free, plain and
# optimised, and with partitions alone; then proven to fail at its own
# check in each direction that matters - a local mark that follows words
# into other partitions, a free that lists another heap's chunk, a global
# sweep that drops what it frees for a partition, a pointer answer left
# as a store into the box, a unit that grows a child unit's answer
# without being pinned, a partition that answer detached still
# collected locally, a death that frees a pinned unit's partition,
# a local mark blind to the unit's other fibers, a local sweep that
# leaves a weak cell naming the chunk it freed, a weak pass after the
# sweep, which a stop between two classes skips, a weak cell to a large
# object left off its partition's list, a local mark that trusts
# the parities a mark abandoned part way left, or a sweep stopped part
# way left, a run a sweep emptied pooled before its later classes, under
# a dead object naming its chunk, a death that keeps the runs its
# sweeps emptied, an idle takeover that reads no parked fiber's stack,
# an idle takeover of a unit whose `Unit` value is still being built, the
# same stacks unread by a collection of a unit parked dirty and owing
# nothing, a busy program whose parked unit is taken after two ticks, an
# idle takeover that holds its unit while a fiber of the unit woken
# meanwhile waits, an idle walk that drops a unit parked dirty whose token
# was held, a unit's death that takes its partition while a takeover
# holds it, with the takeover reading its unit again (a memory fault), or
# a takeover that drops the death left to it, a sweep that keeps its runs
# and drops the return stack
# or lists a free chunk again, a parked unit's spare runs left off the idle
# workers' test, a pooled run's blocks taken as never written, a dead unit's
# pooled run left carved for a stale word to pass the root test, a
# publication
# walk that takes a chunk straddling the carve frontier for uncarved,
# an owner test and a weak sweep that do the same to a weak cell, and a
# counter put back in the data segment at a value that names a `LOCAL`
# chunk the mark left unmarked, which only the verifier sees: the
# program's checks pass, and the verifier must name the data segment.
# Two copies of the cache page's layout must be refused by the runtime
# itself: the pause's take sum reading partition records (stopped at the
# first pause), and the take words moved onto a record's shared words
# (the build fails).
# The copies' verifier reports and goes on, so each other copy must
# reach the program's own check. bench/http_idle.iyi runs beside it, with
# the flag and without: an idle keep-alive connection's partition holds
# nothing of its last request, and a std/http copy whose HTTP/1.1 loop
# serves requests in its own frame and zeroes nothing must fail there.
# Last, the same
# program cross-compiled to an object for each of the nine targets the
# README names, with the flag and without it: a hook the prelude compiles
# on a target where heap_partition.iyi is not loaded fails there.
#
#   bash bench/heap_local.sh            # all three
#   bash bench/heap_local.sh cases      # the builds that must pass
#   bash bench/heap_local.sh broken     # the copies that must fail
#   bash bench/heap_local.sh cross      # the nine targets, flag on and off
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
PART="${1:-all}"

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

run_case() { # label name build-flags program-args...
  local label="$1" name="$2" flags="$3"
  shift 3
  # shellcheck disable=SC2086
  if ! "$IYI" build $flags -o "$WORK/$name" "$REPO/bench/heap_local.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,16p' "$WORK/$name.build.log"
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

# bench/http_idle.iyi: an idle keep-alive connection's partition holds
# nothing of its last request once collected (std/http's `serve_h1`).
# Flags named, `IYI_OPTS` left out, so the no-flag row has no flag.
run_http_idle() { # label name build-flags
  local label="$1" name="$2" flags="$3"
  # shellcheck disable=SC2086
  if ! env -u IYI_OPTS "$IYI" build $flags -o "$WORK/$name" "$REPO/bench/http_idle.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,16p' "$WORK/$name.build.log"
    status=1
    return
  fi
  timeout 300 "$WORK/$name" >"$WORK/$name.out" 2>&1
  local code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$code" -ne 0 ]; then
    echo "$label: exit $code"
    status=1
  fi
}

if [ "$PART" = all ] || [ "$PART" = cases ]; then
  echo "== partitions and poison-on-free, plain"
  run_case "verify" verify "-Dheap_partitions -Dheap_verify"
  run_case "verify, 4 workers" verify4 "-Dheap_partitions -Dheap_verify" 4 120
  echo "== partitions and poison-on-free, optimised"
  run_case "verify release" verifyr "--release -Dheap_partitions -Dheap_verify"
  run_case "verify release, 8 workers" verifyr8 "--release -Dheap_partitions -Dheap_verify" 8 200
  echo "== partitions alone, optimised"
  run_case "release" release "--release -Dheap_partitions" 4 200
  echo "== without partitions"
  run_case "no flag" noflag ""
  echo "== an idle keep-alive connection (bench/http_idle.iyi), on and off"
  run_http_idle "http idle" httpidle "--release -Dheap_partitions"
  run_http_idle "http idle, plain" httpidleplain "-Dheap_partitions"
  run_http_idle "http idle, no flag" httpidleoff "--release"
fi

# The copy's verifier (`-Dheap_verify`, bench/heap_verify.sh's to prove)
# reports and lets the run go on instead of ending it at exit 86, so the
# program's own check is the one each copy must reach: with S4's verifier
# merged, 7 of 9 copies ended at its report before their check
# (HHeapLead3.GMark, Linux and tmac). Whether it reported is said beside.
VERIFY_GOES_ON='/^  def self\.report_end : NoReturn$/ { print "  def self.report_end : Nil"; print "    say(\"iyi: heap_verify: going on (a broken copy of bench/heap_local.sh)\\n\")"; print "    @@reporting = 0_u64"; print "  end"; skip = 1; found = 1; next } skip && /^  end$/ { skip = 0; next } skip { next } { print } END { if (!found) exit 3 }'

# A copy of src/iyi patched in *file* by *awk-script*, and in *file2* by
# *awk-script2* when given, that must fail at "FAIL: phrase", or with
# *phrase* `memory fault` die of one: a copy that brings back a fault
# before any check could name what it broke. Windows' handler says so;
# elsewhere the runtime's handler leaves a fault outside a fiber's guard
# page to the system, and the program dies of SIGSEGV or SIGBUS.
prove_fails() { # label dir phrase awk-script file [awk-script2 file2]
  local label="$1" dir="$2" phrase="$3" script="$4" file="$5" script2="${6:-}" file2="${7:-}"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  if [ -n "$file2" ] && ! awk "$script2" "$REPO/src/iyi/$file2" > "$WORK/$dir/iyi/$file2"; then
    echo "  $label: what the copy changes is not in $file2 any more"
    status=1
    return
  fi
  if ! awk "$VERIFY_GOES_ON" "$WORK/$dir/iyi/heap_verify.iyi" > "$WORK/$dir/heap_verify.iyi" ||
     ! mv "$WORK/$dir/heap_verify.iyi" "$WORK/$dir/iyi/heap_verify.iyi"; then
    echo "  $label: heap_verify.iyi's report_end is not where the copy looks for it"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -Dheap_partitions -Dheap_verify \
       -o "$WORK/$dir/program" "$REPO/bench/heap_local.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout 200 "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local code=$?
  # `verifier:`: a copy whose word holds nothing the program reads, so
  # the program passes and the verifier's report is the check.
  if [ "$phrase" = "verifier:" ]; then
    if [ "$code" -ne 0 ] || ! grep -q "^  holder: the data segment$" "$WORK/$dir/out"; then
      echo "  $label: the verifier named no data-segment holder (exit $code)"
      sed -n '$p' "$WORK/$dir/out"
      status=1
      return
    fi
    printf '  %s: the verifier named the data segment as the holder (exit %s, %s reports)\n' "$label" "$code" "$(grep -c '^  holder: the data segment$' "$WORK/$dir/out")"
    return
  fi
  if [ "$phrase" = "memory fault" ]; then
    if [ "$code" -ne 139 ] && [ "$code" -ne 138 ] && ! grep -q "died of a memory fault" "$WORK/$dir/out"; then
      echo "  $label: did not die of a memory fault (exit $code)"
      sed -n '$p' "$WORK/$dir/out"
      status=1
      return
    fi
    printf '  %s: dies of a memory fault (exit %s)\n' "$label" "$code"
    return
  fi
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  # Unanchored: the verifier's report runs on another thread, and its
  # "iyi: heap_verify: partition " can sit unfinished in front of the
  # program's FAIL line (Linux, nofrontier, v2 prep).
  if ! grep -q "FAIL: $phrase" "$WORK/$dir/out"; then
    echo "  $label: failed (exit $code), but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  local verifier="the verifier did not report"
  grep -q "iyi: heap_verify: going on" "$WORK/$dir/out" && verifier="the verifier reported too"
  printf '  %s: exits %s at "%s" (%s)\n' "$label" "$code" "$(grep -m1 "FAIL: $phrase" "$WORK/$dir/out" | sed 's/^.*FAIL: //')" "$verifier"
}

# A copy of prelude.iyi patched by *awk-script* that the runtime or the
# compiler must refuse with *message*: at its build (`build`) or when
# bench/heap_local.iyi runs (`run`), every run.
prove_layout_refused() { # label dir build|run message awk-script
  local label="$1" dir="$2" when="$3" message="$4" script="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"; then
    echo "  $label: what the copy changes is not in prelude.iyi any more"
    status=1
    return
  fi
  IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -Dheap_partitions \
    -o "$WORK/$dir/program" "$REPO/bench/heap_local.iyi" >"$WORK/$dir/build.log" 2>&1
  local code=$?
  if [ "$when" = build ]; then
    if [ "$code" -eq 0 ] || ! grep -q "$message" "$WORK/$dir/build.log"; then
      echo "  $label: the build was not refused for the layout (exit $code)"
      status=1
      return
    fi
    printf '  %s: the build is refused: "%s"\n' "$label" "$(grep -m1 -o "$message.*" "$WORK/$dir/build.log" | cut -c1-120)"
    return
  fi
  if [ "$code" -ne 0 ]; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout 200 "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  code=$?
  if [ "$code" -eq 0 ] || ! grep -q "$message" "$WORK/$dir/out"; then
    echo "  $label: not stopped at the layout check (exit $code)"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: stops with exit %s: "%s"\n' "$label" "$code" "$(grep -m1 "$message" "$WORK/$dir/out")"
}

# A copy of std/http.iyi patched by *awk-script*, ahead of the tree's on
# `IYI_PATH`, under bench/http_idle.iyi built with *build-flags*: it must
# fail at "FAIL: phrase".
prove_http_idle_fails() { # label dir build-flags awk-script
  local label="$1" dir="$2" flags="$3" script="$4" phrase="idle:"
  mkdir -p "$WORK/$dir/std"
  if ! awk "$script" "$REPO/src/std/http.iyi" > "$WORK/$dir/std/http.iyi"; then
    echo "  $label: what the copy changes is not in std/http.iyi any more"
    status=1
    return
  fi
  # shellcheck disable=SC2086
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" env -u IYI_OPTS "$IYI" build $flags \
       -o "$WORK/$dir/program" "$REPO/bench/http_idle.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched std/http did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout 300 "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "^FAIL: $phrase" "$WORK/$dir/out"; then
    echo "  $label: failed (exit $code), but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 "^FAIL: $phrase" "$WORK/$dir/out" | sed 's/^FAIL: //')"
}

if [ "$PART" = all ] || [ "$PART" = broken ]; then
  echo
  echo "== the checks fail when a mechanism is broken"

  # The local mark's owner filter gone: a word into another partition is
  # followed, and that partition's `OWN` byte written by a unit that does
  # not own it.
  prove_fails "a missed root filter" nofilter "filter:" \
    '/def self\.local_shade\(record : UInt64, id : UInt64, parity : UInt64, word : UInt64\)/ { inside = 1 } inside && /unsafe_shr\(GRANULE_SHIFT\) &\* 2_u64\) != id$/ { inside = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # `free` lists a chunk of the shared heap on a partition's list.
  prove_fails "an owner check missing in free" nofreeowner "free:" \
    '{ if (sub(/return id == 0 unless partition_arena\?\(arena\)/, "return true unless partition_arena?(arena)")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The global sweep frees a partition's dead and hands nothing back.
  prove_fails "a dropped return stack" noreturn "return:" \
    '/def self\.push_return\(record : UInt64, index : Int32, head : UInt64, tail : UInt64\)/ { print; print "    return"; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A pointer answer stored into the box and nothing more: the partition
  # is freed whole at the unit's death under the answer.
  prove_fails "a merge left as a box store" noanswer "answer:" \
    '/^      answered\(box\.object_id, / { found = 1; next } { print } END { if (!found) exit 3 }' \
    concurrency.iyi

  # A unit that reads a child unit's pointer answer left unpinned: what it
  # adds to the answered graph is `LOCAL` under the shared heap's holder,
  # and its own collection frees it.
  prove_fails "a unit joiner that grows an answer unpinned" noadopt "adopt:" \
    '/^      IyiHeap\.adopt_answer\(@box\.to_unsafe\.address, / { found = 1; next } { print } END { if (!found) exit 3 }' \
    concurrency.iyi

  # A partition detached by a pointer answer still collected locally: the
  # answer, held only by the task's shared box, is freed.
  prove_fails "a detached partition collected" nodetach "detach:" \
    '{ if ($0 ~ /^    return false if read64\(record &\+ REC_STATE\) & REC_DETACHED != 0$/) { found = 1; next } print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A pin that moves the unit's allocation to the shared heap and leaves
  # its partition the unit's: the death frees it whole.
  prove_fails "a death that frees a pinned partition" nopin "pin:" \
    '/def self\.pin_running : Nil/ { inside = 1 } inside && /^    unit\.heap = 0_u64$/ { found = found + 1; next } inside && /^    merge\(record, 0_u64\)$/ { found = found + 1; inside = 0; next } { print } END { if (found != 2) exit 3 }' \
    heap_partition.iyi

  # The unit's other fibers' stacks left out of the local roots.
  prove_fails "other fibers' stacks unscanned" nostacks "fibers:" \
    '{ if ($0 ~ /^          local_range\(record, id, parity, fiber\.saved_sp, fiber\.stack_top\)$/) { found = 1; next } print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The local sweep frees a weak target and leaves its cell naming the
  # freed chunk.
  prove_fails "a weak cell left on a freed target" noweak "weak:" \
    '/def self\.sweep_weak\(record : UInt64, id : UInt64, parity : UInt64\) : Nil/ { inside = 1 } inside && /^            write64\(cell, 0_u64\)$/ { inside = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The weak pass after the sweep, as it was: a sweep stopped between
  # two classes returns before it, and the cells to the chunks it freed
  # name them still. (With the stop not asked, it clears what the sweep
  # freed; an empty run the sweep pooled was taken by another worker's
  # unit before it looked, which no single run shows.)
  prove_fails "a weak pass after the local sweep" noweakfirst "weak:" \
    '/^    sweep_weak\(record, id, parity\)$/ { found = found + 1; next } /^    IyiStat\.add\(IyiStat::LOCAL_FREED, freed\)$/ { print "    sweep_weak(record, id, parity)"; found = found + 1 } { print } END { if (found != 2) exit 3 }' \
    heap_partition.iyi

  # A weak cell to a large object left off its partition's list, as it
  # was through d3b590476: the sweep that unmaps the object leaves the
  # cell naming the unmapped block.
  prove_fails "a weak cell to a large object unlisted" nolargeweak "weak:" \
    '/def self\.weak_registered\(cell : UInt64, target : UInt64\) : Nil/ { inside = 1 } inside && /^    if arena == 0$/ { print "    return if arena == 0"; skip = 1; inside = 0; found = 1; next } skip && /^    end$/ { skip = 0; next } skip { next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The mark bits an abandoned local mark left trusted by the next one:
  # a link only past the abandoned mark's reach holds is never opened,
  # and what it holds is freed.
  prove_fails "an abandoned mark's parities trusted" noclear "abandon:" \
    '{ if ($0 ~ /^    clear_local_marks\(record\) if read64\(record &\+ REC_MARKING\) != 0_u64$/) { found = 1; next } print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The marks trusted once the mark ends, as they were through
  # 3984c899a: a sweep stopped between two classes leaves a dead object
  # of a later class wearing the parity the next mark wears, which takes
  # it for reached and keeps it.
  prove_fails "a stopped sweep's parities trusted" nounswept "unswept:" \
    '/^    return false unless local_sweep\(record, id, parity, idle, keep\)$/ { print "    write64(record &+ REC_MARKING, 0_u64)"; print "    local_sweep(record, id, parity, idle, keep)"; getline; getline; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # An empty run to the pool as the sweep meets it, as through 3984c899a:
  # while the sweep has later classes to go, a dead object of one names
  # its chunk, and another unit that takes the run puts its own object
  # under that word - a whole sweep held between two classes, which
  # #145's app met at stress 0 (seeds 2 and 3 of 3, Linux), and a stopped one.
  prove_fails "an emptied run pooled before the sweep ends" poolearly "unswept:" \
    '/def self\.local_sweep\(/ { inside = 1 } inside && /^              set_run_word\(arena, granule_first, read64\(record &\+ REC_EMPTIED\), n, RUN_OWNED\)$/ { print "              pool_run(index, arena, run, n)"; print "              write64(record &+ REC_HELD, read64(record &+ REC_HELD) - n.unsafe_shl(GRANULE_SHIFT))"; getline; inside = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A death that leaves the runs its stopped sweep emptied on the record:
  # nobody's list holds them, and they stay the dead partition's. (Their
  # order at a death - the runs pooled only once every class's dead
  # chunks are free - has no copy: another unit would have to take one
  # and collect while the dying one is between two classes.)
  prove_fails "a death that keeps its emptied runs" deathleak "unswept:" \
    '/^      pool_emptied\(record, false\)$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # An idle worker's takeover that reads none of the parked unit's
  # stacks, as the unit's own collection reads all but the running one:
  # a list held only by a parked fiber's frame is freed under it. A
  # takeover comes in every run (`takeover:` fails when none does): under
  # `IYI_HEAP_STRESS`, where each unit collects itself before it parks,
  # the check hands the parked units their debt, so bench/heap_verify.sh's
  # table sees the takeover too.
  prove_fails "a takeover that reads no parked stack" notakeover "takeover:" \
    '{ if (sub(/if !\(running\.is_a\?\(IyiFiber\) && running\.object_id == fiber\.object_id\) && fiber\.state/, "if running.is_a?(IyiFiber) \\&\\& running.object_id != fiber.object_id \\&\\& fiber.state")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # An idle worker's takeover that takes a unit with no fiber and no
  # value slot: a `Unit` whose value is still being built on its caller's
  # fiber is collected with that stack unread.
  prove_fails "a takeover of a unit under construction" noconstruct "construct:" \
    '{ if (sub(/if \(unit\.fibers\.is_a\?\(IyiFiber\) \|\| unit\.value_slot != 0_u64\) && unit\.holder == 0_u64/, "if unit.holder == 0_u64")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # An idle worker's collection of a unit parked dirty and owing nothing
  # (heap22 S6's idle trigger) that reads none of its parked stacks: the
  # idle check alone (`HEAP22_ONLY=idle`), since the takeover check, which
  # runs first, meets the same collection. Under `IYI_HEAP_STRESS` the
  # check stamps the parked units dirty itself.
  HEAP22_ONLY=idle prove_fails "an idle collection that reads no parked stack" noidle "idle:" \
    '{ if (sub(/if !\(running\.is_a\?\(IyiFiber\) && running\.object_id == fiber\.object_id\) && fiber\.state/, "if running.is_a?(IyiFiber) \\&\\& running.object_id != fiber.object_id \\&\\& fiber.state")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The busy rule (`IyiHeap.idle_delay`) gone: every walk gives a parked
  # unit two ticks, so a busy program's unit waiting on its database is
  # taken mid-request again - slower, and no check of soundness would
  # see it. The busy check alone (`HEAP22_ONLY=busy`).
  HEAP22_ONLY=busy prove_fails "a busy program's parked unit taken after two ticks" nobusy "busy:" \
    '{ if (sub(/parks &- before >= IDLE_BUSY_PARKS &\* \(tick &- since\) \? IDLE_BUSY_TICKS : 2_u64/, "2_u64")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # An idle worker's takeover that ignores the wake of a fiber of the
  # unit it collects (`IyiHeap.give_way?` never true): the fiber waits
  # out the whole collection - no soundness check sees it, the giveway
  # check alone (`HEAP22_ONLY=giveway`) does.
  HEAP22_ONLY=giveway prove_fails "a takeover that keeps a woken fiber waiting" nogiveway "giveway:" \
    '{ if (sub(/return false unless Pointer\(Void\)\.new\(unit\)\.as\(IyiUnit\)\.waiting\?/, "return false if unit != 0_u64")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # An idle worker's takeover that keeps what a worker out looking holds
  # - the look's token, and on Windows the port's seat - while it
  # collects (`IyiHeap.collect_taken`): a push from outside the pool
  # meanwhile calls no worker to a fiber of the taken unit, which waits
  # out the collection unless another worker comes to look on its own.
  # The look check alone (`HEAP22_ONLY=look`), whose takeover the
  # runtime's switch makes enter holding the token and holds where it
  # must hold it no more; the giveway check, which has no switch, missed
  # this copy on a darwin CI runner. The seat's line sits in a win32
  # block, so elsewhere its removal changes nothing.
  HEAP22_ONLY=look prove_fails "a takeover that keeps the look's token" notoken "look:" \
    '{ if (sub(/IyiWorkers\.stop_spinning\(st, true\)/, "")) found = 1; if (sub(/IyiScheduler\.left_idle\(st\)/, "")) seat = 1; print } END { if (!found || !seat) exit 3 }' \
    heap_partition.iyi

  # An idle walk that drops a partition old enough but passed over while
  # its unit's token is held: once the token is let go no walk comes
  # again in a program with nothing else to park - no soundness check
  # sees it, the idlehold check alone (`HEAP22_ONLY=idlehold`) does.
  HEAP22_ONLY=idlehold prove_fails "an idle walk that drops a held unit" noidlehold "idlehold:" \
    '{ if (sub(/elsif idle_held\?\(record\)/, "elsif false")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # An idle clock's turn that trusts a time read before the clock: a look
  # whose time another worker's turn left behind wraps `now &- last`,
  # turns the clock again at once and backwards, and the next walk's busy
  # rule counts a moment's parks - a busy program called idle (heap_local's
  # `busy:` flake under load, heap22 fu). No soundness check sees it, the
  # clock check alone (`HEAP22_ONLY=clock`) does, its look held by the
  # runtime's switch until the race has happened.
  HEAP22_ONLY=clock prove_fails "a clock turned again with a time behind it" clockwrap "clock:" \
    '{ if (sub(/if now > last && now &- last >= IDLE_NS && /, "if now \\&- last >= IDLE_NS \\&\\& ")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A unit's death at its last fiber's unregister that takes the
  # partition off the unit while an idle worker's takeover holds the
  # record busy: the takeover, which collects the unit `take_unit` handed
  # it, collects a record that names no unit, and the death waits for it
  # (heap22 merge, MGateTssh). The takendeath check alone
  # (`HEAP22_ONLY=takendeath`), the takeover held there by the runtime's
  # switch until the unregister is done.
  HEAP22_ONLY=takendeath prove_fails "a death that ignores a takeover's hold" noholdreg "takendeath:" \
    '{ if (sub(/ && IyiHeap\.read64\(unit\.heap \+ IyiHeap::REC_STATE\) & IyiHeap::REC_BUSY == 0_u64/, "")) found = 1; print } END { if (!found) exit 3 }' \
    concurrency.iyi

  # The runtime before the fix: that death, and a takeover that reads its
  # unit from the record after the take, outside the runtime's lock - 0,
  # once the death took it - and dies reading it, as thread_exercise did
  # on tssh (1 run in 130). The re-read alone is no fault: while the
  # record is busy no death takes its unit.
  HEAP22_ONLY=takendeath prove_fails "a takeover that reads its unit again" rereadunit "memory fault" \
    '{ if (sub(/ && IyiHeap\.read64\(unit\.heap \+ IyiHeap::REC_STATE\) & IyiHeap::REC_BUSY == 0_u64/, "")) found = 1; print } END { if (!found) exit 3 }' \
    concurrency.iyi \
    '{ if (sub(/taken = Pointer\(Void\)\.new\(unit\)\.as\(IyiUnit\)/, "taken = Pointer(Void).new(read64(record + REC_UNIT)).as(IyiUnit)")) found = found + 1; if (sub(/@@taken_unit = unit$/, "@@taken_unit = read64(record + REC_UNIT)")) found = found + 1; print } END { if (found != 2) exit 3 }' \
    heap_partition.iyi

  # A takeover's end that leaves undone the death its unit's unregister
  # left to it: the partition outlives its unit for good.
  HEAP22_ONLY=takendeath prove_fails "a takeover that drops the death left to it" nodeferdeath "takendeath:" \
    '{ if (sub(/dead = !unit\.fibers\.is_a\?\(IyiFiber\) && unit\.value_slot == 0_u64 && unit\.heap == record/, "dead = false")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A sweep that keeps its runs and drops the return stack, as the whole
  # sweep does: what the global sweep handed back there is free and on no
  # list, lost to the partition, which takes new runs round after round.
  prove_fails "a kept sweep that drops the return stack" nokeptreturn "kept:" \
    '{ print } /^          list = table\[index\]$/ { print "          Pointer(Atomic(UInt64)).new(record &+ REC_RETURN &+ index.to_u64 &* 8_u64).value.set(0_u64)"; found = 1 } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A sweep that keeps its runs and links every free chunk again, as the
  # whole sweep does, ahead of the list that already holds them: a chunk
  # twice on the list, or the list a ring, and the allocator hands one
  # chunk to two objects. The kept check alone (`HEAP22_ONLY=kept`): the
  # parks of the checks before it hand a ring's chunks out, and the
  # program died of a memory fault there (CpuFix3, Linux and tmac).
  HEAP22_ONLY=kept prove_fails "a kept sweep that lists free chunks again" nokeptfree "kept:" \
    '/def self\.sweep_run_kept\(/ { inside = 1 } { print } inside && /^      bits = read8\(meta\)$/ { print "      if bits & CARVED_FLAG != 0 && bits & FREE_FLAG != 0"; print "        write64(head + OFF_LINK, list)"; print "        write64(head + OFF_INDEX, slot)"; print "        list = head"; print "      end"; inside = 0; found = 1 } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A unit whose kept sweep left runs with nothing live on them clean to
  # the idle workers: parked, it holds them for as long as it sits.
  prove_fails "spare runs left off the idle test" nospare "spare:" \
    '{ if (sub(/ \|\| read64\(record &\+ REC_SPARE\) != 0_u64/, "")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A pool run's chunks threaded as fresh - the kernel's zero past their
  # link words - as only a frontier run's are: a unit that takes a dead
  # unit's pooled block reads the dead unit's words in it.
  prove_fails "a pooled run taken as fresh" nofresh "fresh:" \
    '{ if (sub(/^    thread_run\(table, index, arena, run, n, frontier\)$/, "    thread_run(table, index, arena, run, n, true)")) found = 1; print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # A run of a dead unit to the pool with its `LOCAL` chunks left carved
  # (freed on a run handed to the shared heap alone): a stale word naming
  # one passes the collector's root test, and a global mark would keep
  # what the dead chunk names.
  prove_fails "a pooled run's dead chunks left carved" nostale "stale:" \
    '/^          free_locals_in\(arena, run, n\)$/ { found = found + 1; next } /^            set_run_word\(arena, granule_first, handed, n, RUN_OWNED\)$/ { print "            free_locals_in(arena, run, n)"; found = found + 1 } { print } END { if (found != 2) exit 3 }' \
    heap_partition.iyi

  # The publication walk's frontier test made of the word, not the
  # chunk's head: a headed object whose chunk straddles its run's end,
  # its address on the frontier, is taken for uncarved and stays local.
  prove_fails "a frontier test of the word" nofrontier "frontier:" \
    '/# The head against the frontier, not the word/ { print; getline; if (sub(/return 0_u64 if head >= read64\(arena &\+ OFF_HIGH\)$/, "return 0_u64 if word >= read64(arena \\&+ OFF_HIGH)")) found = 1 } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The owner test's frontier test made of the address: a weak cell to a
  # string whose chunk straddles its run's end is never registered with
  # the partition, and the local sweep that frees the string leaves it.
  prove_fails "an owner test of the word, for weak cells" noweakowner "frontier:" \
    '/def self\.owner_in_arena\(arena : UInt64, address : UInt64\) : UInt64/ { inside = 1 } inside && sub(/return 0_u64 if head >= read64\(arena &\+ OFF_HIGH\)$/, "return 0_u64 if address >= read64(arena \\&+ OFF_HIGH)") { found = 1; inside = 0 } { print } END { if (!found) exit 3 }' \
    heap_partition.iyi

  # The weak sweep's frontier test made of the target: the cell is
  # registered, and the sweep that frees its chunk drops it uncleared.
  prove_fails "a weak sweep's frontier test of the word" noweaksweep "frontier:" \
    '{ if (sub(/head_of\(arena, target\) < read64\(arena \+ OFF_HIGH\)/, "target < read64(arena + OFF_HIGH)")) found = found + 1; print } END { if (found != 1) exit 3 }' \
    heap_partition.iyi

  # A counter of the runtime's back in the data segment, at a value that
  # names a `LOCAL` chunk the local mark left unmarked - what `local_ns`
  # read on tmac at 4.77 s of local collections (0x11c3b1a6d, five bytes
  # into one; heap_local's "verify release, 8 workers" exited 86). The
  # counters live in `IyiStat`'s page now; this copy proves the scan of
  # the data segment still sees such a word, so the fix moved the words
  # and left the verifier's rule alone.
  prove_fails "a counter in the data segment naming a LOCAL chunk" countword "verifier:" \
    '/^  @@pause_ring : UInt64 = 0_u64$/ { print; print "  @@local_ns : UInt64 = 0_u64"; found = found + 1; next }
     /^  def self\.clear_local_marks\(record : UInt64\) : Nil$/ { print "  def self.unmarked_local(record : UInt64, id : UInt64, parity : UInt64) : UInt64"; print "    index = 0"; print "    while index < CLASSES"; print "      run = read64(record &+ (FILL + index).to_u64 * 8_u64)"; print "      while run != 0"; print "        arena = run & (0_u64 &- MAP)"; print "        word = run_word(arena, granule_of(arena, run))"; print "        stop = run + run_n(word).unsafe_shl(GRANULE_SHIFT)"; print "        head = first_head(arena, run)"; print "        while head < stop"; print "          return head if IyiHeapVerify.target_of(record, id, parity, false, head) != 0"; print "          head = head + read64(arena + OFF_CHUNK)"; print "        end"; print "        run = word & RUN_LINK"; print "      end"; print "      index = index + 1"; print "    end"; print "    0_u64"; print "  end"; print ""; found = found + 1 }
     /return false unless IyiHeapVerify\.check\(record, id, parity, running\)/ { print "    @@local_ns = unmarked_local(record, id, parity)"; found = found + 1 }
     { print } END { if (found != 3) exit 3 }' \
    heap_partition.iyi

  # A cache page's take words (`IyiHeap::TAKEN`, mt's warm room per
  # class) and a partition record's heap state share the record's bytes
  # from `REC_LEND` up. The pause's sum of the takes zeroed every record's
  # words there, and this program panicked in `pool_emptied` on
  # `REC_HELD` (the heap22 merge onto mt/next-two). Two copies: the sum
  # reading records again, which `taken_word` must stop at the first
  # pause; and the take words moved onto the words every cache page
  # shares with a record (`REC_ID` up), which the build must refuse.
  prove_layout_refused "the pause's take sum reading partition records" takenrecord run \
    "iyi: a partition record's heap words taken for a class's take" \
    '/^      def self\.taken_of\(index : Int32\) : UInt64$/ { inside = 1 }
     inside && /^            if read64\(page \+ REC_ID\) != 0$/ { skip = 4; found = 1 }
     skip > 0 { skip--; next }
     inside && /^      end$/ { inside = 0 }
     { print } END { if (!found) exit 3 }'
  prove_layout_refused "the take words over a record's shared words" takenonrec build \
    "must lie past REC_FREE's word" \
    '{ if (sub(/^      TAKEN = 176$/, "      TAKEN = 168")) found = 1; print } END { if (!found) exit 3 }'

  # std/http's HTTP/1.1 loop as the flag-off build has it: each request's
  # wait and work in the loop's own frame, and nothing zeroed before the
  # wait for the next, so the last request's objects stay in the parked
  # fiber's stack and its partition's idle collection keeps them. Both
  # halves go: the call alone frees most of it on Linux (the request; a
  # 1 KiB buffer stays, IdleFix3's diag). Built plain, where the loop's
  # locals keep their stack slots: since the master merge (with master's
  # std/tls, std/rsa and std/x509 swapped into heap22's tree, and only then) a
  # --release build of this copy on Linux left nothing of the request in
  # the parked frames, and passed in 3 runs of 3, while the plain build
  # fails with all 32 partitions holding their requests, and the fixed
  # loop passes both ways (the "http idle, plain" row above).
  prove_http_idle_fails "a parked connection that keeps its last request" httpkeeps "-Dheap_partitions" \
    '/^  \{% begin %\}/ { inside = 1 } inside { found = found + gsub(/flag\?\(:heap_partitions\)/, "false") } inside && /^  end\{% end %\}$/ { inside = 0 }
     /^# `Server\.serve_h1` under `-Dheap_partitions`/ { tail = 1 } tail { if (/IyiRoots\.clear_dead_stack if conn\.available == 0$/) found = found + 1; next }
     { print } END { if (found != 5) exit 3 }'
fi

# The nine targets, each to an object (`--cross-compile` links nothing),
# flag on and off. x86_64-darwin has no scheduler and wasm32-wasi no
# threads: there heap_partition.iyi is not loaded, and a prelude hook that
# called into it was "undefined method 'partition_slice'" on x86_64-darwin
# with the flag (9539ec448, Linux). arm-linux-gnueabihf has no prelude
# branch, so an iyi program is refused there by name, flag or no flag; the
# check is that the flag adds no other error. Each build names its flags,
# `IYI_OPTS` left out: under the on gate's `-Dheap_partitions` the "(no
# flag)" row was built with the flag, and x86_64-darwin's missing guard
# (095d32d63) failed both rows.
if [ "$PART" = all ] || [ "$PART" = cross ]; then
  echo
  echo "== the program cross-compiled for every target, flag on and off"
  for target in x86_64-linux-gnu x86_64-linux-musl aarch64-linux-gnu \
                arm-linux-gnueabihf x86_64-darwin aarch64-darwin \
                x86_64-w64-mingw32 x86_64-windows-msvc wasm32-wasi; do
    for flags in "" "-Dheap_partitions"; do
      out="$WORK/cross-$target${flags:+-on}"
      label="$(printf '%-22s %s' "$target" "${flags:-(no flag)}")"
      # shellcheck disable=SC2086
      if env -u IYI_OPTS "$IYI" build --cross-compile --target "$target" $flags \
           -o "$out" "$REPO/bench/heap_local.iyi" >"$out.log" 2>&1; then
        built=1
      else
        built=0
      fi
      # tssh's compiler links an LLVM with the x86 and aarch64 back ends
      # only, and says so for wasm32-wasi and arm-linux-gnueabihf with or
      # without the flag: the machine cannot build those targets, which
      # says nothing of the flag.
      backend=""
      if [ "$built" -eq 0 ] && [ "$(grep -c '^Error: ' "$out.log")" -eq 1 ]; then
        backend="$(sed -n "s/^Error: [^ ]* needs LLVM's \([A-Za-z0-9]*\) back end.*/\1/p" "$out.log")"
      fi
      if [ -n "$backend" ]; then
        echo "  $label: skipped, this compiler's LLVM has no $backend back end"
        continue
      fi
      if [ "$target" = arm-linux-gnueabihf ]; then
        if [ "$built" -eq 0 ] && [ "$(grep -c '^Error: ' "$out.log")" -eq 1 ] &&
           grep -q "^Error: iyi: this target is not one iyi's prelude has platform bindings for" "$out.log"; then
          echo "  $label: refused by name, and nothing else"
        else
          echo "  $label: not the prelude's one refusal"
          sed -n '1,12p' "$out.log"
          status=1
        fi
        continue
      fi
      if [ "$built" -eq 0 ]; then
        echo "  $label: cross-compile failed"
        sed -n '1,12p' "$out.log"
        status=1
        continue
      fi
      if [ ! -f "$out.o" ] && [ ! -f "$out.obj" ] && [ ! -f "$out.wasm" ]; then
        echo "  $label: no object was written"
        status=1
        continue
      fi
      echo "  $label: an object"
    done
  done
fi

echo
if [ "$status" -eq 0 ]; then
  echo "heap_local: units collect their own partitions, and the checks fail when any mechanism is broken."
fi
exit "$status"
