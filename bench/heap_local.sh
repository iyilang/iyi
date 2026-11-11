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
# the parities a mark abandoned part way left, an idle takeover that
# reads no parked fiber's stack, an idle takeover of a unit
# whose `Unit` value is still being built, a dead unit's pooled run
# left carved for a stale word to pass the root test, a publication
# walk that takes a chunk straddling the carve frontier for uncarved,
# and an owner test and a weak sweep that do the same to a weak cell.
# The copies' verifier reports and goes on, so each copy must reach the
# program's own check. Last, the same
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
fi

# The copy's verifier (`-Dheap_verify`, bench/heap_verify.sh's to prove)
# reports and lets the run go on instead of ending it at exit 86, so the
# program's own check is the one each copy must reach: with S4's verifier
# merged, 7 of 9 copies ended at its report before their check
# (HHeapLead3.GMark, Linux and tmac). Whether it reported is said beside.
VERIFY_GOES_ON='/^  def self\.report_end : NoReturn$/ { print "  def self.report_end : Nil"; print "    say(\"iyi: heap_verify: going on (a broken copy of bench/heap_local.sh)\\n\")"; print "    @@reporting = 0_u64"; print "  end"; skip = 1; found = 1; next } skip && /^  end$/ { skip = 0; next } skip { next } { print } END { if (!found) exit 3 }'

prove_fails() { # label dir phrase awk-script file
  local label="$1" dir="$2" phrase="$3" script="$4" file="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
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
  local verifier="the verifier did not report"
  grep -q "^iyi: heap_verify: going on" "$WORK/$dir/out" && verifier="the verifier reported too"
  printf '  %s: exits %s at "%s" (%s)\n' "$label" "$code" "$(grep -m1 "^FAIL: $phrase" "$WORK/$dir/out" | sed 's/^FAIL: //')" "$verifier"
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
    '/^    sweep_weak\(record, id, parity\)$/ { found = found + 1; next } /^    stat_add\(pointerof\(@@local_freed\)\.address, freed\)$/ { print "    sweep_weak(record, id, parity)"; found = found + 1 } { print } END { if (found != 2) exit 3 }' \
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

  # A run of a dead unit to the pool with its `LOCAL` chunks left carved:
  # a stale word naming one passes the collector's root test, and a
  # global mark would keep what the dead chunk names.
  prove_fails "a pooled run's dead chunks left carved" nostale "stale:" \
    '/^          free_locals_in\(arena, run, n\)$/ { found = found + 1; next } /^            drain_run\(arena, run, n\)$/ { print "            free_locals_in(arena, run, n)"; found = found + 1 } { print } END { if (found != 2) exit 3 }' \
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
fi

# The nine targets, each to an object (`--cross-compile` links nothing),
# flag on and off. x86_64-darwin has no scheduler and wasm32-wasi no
# threads: there heap_partition.iyi is not loaded, and a prelude hook that
# called into it was "undefined method 'partition_slice'" on x86_64-darwin
# with the flag (9539ec448, Linux). arm-linux-gnueabihf has no prelude
# branch, so an iyi program is refused there by name, flag or no flag; the
# check is that the flag adds no other error.
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
      if "$IYI" build --cross-compile --target "$target" $flags \
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
