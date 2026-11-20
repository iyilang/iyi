#!/usr/bin/env bash
# heap22 S6 (LeakHunt): the partitions' runs given back, driven.
# bench/heap_drain.iyi built with partitions, plain and optimised: its
# partition arenas flat round after round (drained runs taken again) and
# its pooled runs' pages back after an idle wait; its mark mode, the
# partitions held under long global marks; its claim mode, the sweep
# helpers' rounds swept beside a sleeping program; its directory mode,
# the arena directory left unread for words outside every arena's slot;
# with the verifier and under chaos with a local collection at every
# park, no report; the flag-off control; then one broken copy per
# mechanism: without the take of drained runs or the global sweep's
# listing the arenas grow, without the idle wake the pool stays warm,
# without the release the resident set stays, without the hold the
# arenas grow under the marks, without the directory's bounds its pages
# go resident, and with bounds a large mapping does not widen a large
# object is no heap pointer (the program fails), and a taken run's
# objects left `LOCAL` instead of published, or a helper that lets its
# sweep claim go before its walk ends, are caught by `-Dheap_verify`
# (exit 86).
#
#   bash bench/heap_drain.sh           # every part
#   bash bench/heap_drain.sh sound     # plain, optimised, verifier, chaos
#   bash bench/heap_drain.sh off       # the flag-off control
#   bash bench/heap_drain.sh copies    # the broken copies
#
# Needs `make` first. `IYI` names the compiler, `SEEDS` the chaos seeds
# (default "1 2"), `KEEP=DIR` keeps every build and run. Exits non-zero
# when a sound build fails or a copy is missed.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="${KEEP:-$(mktemp -d)}"
mkdir -p "$WORK"
PART="${1:-all}"
SEEDS="${SEEDS:-1 2}"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT

status=0

# build NAME FLAGS [PATH]: the program built with FLAGS (against PATH's
# runtime when given); false when it does not build. Each build names
# its flags, `IYI_OPTS` left out: under a gate's `-Dheap_partitions` the
# flag-off control was built with the flag.
build() {
  local name="$1" flags="$2" path="${3:-}"
  # shellcheck disable=SC2086
  if ! env -u IYI_OPTS ${path:+IYI_PATH="$path"} "$IYI" build $flags -o "$WORK/$name" "$REPO/bench/heap_drain.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $name: build failed"
    sed -n '1,12p' "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return 1
  fi
}

# whole LABEL NAME FLAGS [ARGS...]: built and run; exit 0, no report.
whole() {
  local label="$1" name="$2" flags="$3"
  shift 3
  build "$name" "$flags" || return
  timeout 600 "$WORK/$name" "$@" >"$WORK/$name.out" 2>"$WORK/$name.err"
  local code=$?
  if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/$name.err"; then
    echo "  $label: exit $code"
    sed -n '1,12p' "$WORK/$name.out" "$WORK/$name.err" | sed 's/^/    /'
    status=1
    return
  fi
  echo "  $label: $(head -1 "$WORK/$name.out")"
}

# again LABEL NAME OUT [ARGS...]: NAME, built by `whole`, run again with
# ARGS into OUT; exit 0, no report.
again() {
  local label="$1" name="$2" out="$3"
  shift 3
  [ -x "$WORK/$name" ] || return
  timeout 600 "$WORK/$name" "$@" >"$WORK/$out.out" 2>"$WORK/$out.err"
  local code=$?
  if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/$out.err"; then
    echo "  $label: exit $code"
    sed -n '1,12p' "$WORK/$out.out" "$WORK/$out.err" | sed 's/^/    /'
    status=1
    return
  fi
  echo "  $label: $(head -1 "$WORK/$out.out")"
}

if [ "$PART" = all ] || [ "$PART" = sound ]; then
  echo "== the arenas flat round after round (-Dheap_partitions)"
  whole "plain" plain "-Dheap_partitions"
  whole "optimised" release "-Dheap_partitions --release"
  whole "verifier" verify "-Dheap_partitions -Dheap_verify" 8 24 4
  echo "== the partitions held under long marks (mark mode)"
  again "optimised" release release-mark mark
  again "verifier" verify verify-mark mark 1000000 4 2
  echo "== the helpers' sweep rounds beside a sleeping program (claim mode)"
  again "verifier" verify verify-claim claim
  echo "== the arena directory left unread outside the arenas' slots (directory mode)"
  again "optimised" release release-dir dir
  again "verifier" verify verify-dir dir
  build stress "-Dheap_partitions -Dheap_verify -Diyi_chaos" && for seed in $SEEDS; do
    env IYI_CHAOS="$seed" IYI_HEAP_STRESS=1 timeout 600 "$WORK/stress" 6 8 4 >"$WORK/stress-$seed.out" 2>"$WORK/stress-$seed.err"
    code=$?
    if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/stress-$seed.err"; then
      echo "  chaos seed $seed, a collection at every park: exit $code"
      sed -n '1,12p' "$WORK/stress-$seed.out" "$WORK/stress-$seed.err" | sed 's/^/    /'
      status=1
    else
      echo "  chaos seed $seed, a collection at every park: $(head -1 "$WORK/stress-$seed.out")"
    fi
  done
fi

if [ "$PART" = all ] || [ "$PART" = off ]; then
  echo "== the flag-off control"
  whole "flag off" off ""
  again "flag off, mark mode" off off-mark mark
  again "flag off, claim mode" off off-claim claim
  again "flag off, directory mode" off off-dir dir
fi

# One line deleted after a marker: `del MARKER LINE` as an awk program.
del() {
  printf '/%s/ { armed = 1 } armed && /%s/ { armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' "$1" "$2"
}
# One line rewritten after a marker: `subst MARKER FROM TO`.
subst() {
  printf '/%s/ { armed = 1 } armed && sub(/%s/, "%s") { armed = 0; found = 1 } { print } END { if (!found) exit 3 }' "$1" "$2" "$3"
}

# copy LABEL DIR WANT AWK [FLAGS [ARGS...]]: src/iyi/heap_partition.iyi
# (or `COPY_FILE`, another file of src/iyi) patched by AWK, the program
# built against it (with FLAGS, default the optimised partitioned build)
# and run with ARGS: caught when it exits WANT - 1, the arenas' growth
# the program fails on, or 86, the verifier's report, the program's own
# checks printed and passed over.
copy() {
  local label="$1" name="$2" dir="$WORK/$2" want="$3" script="$4" flags="${5:--Dheap_partitions --release}"
  local file="${COPY_FILE:-heap_partition.iyi}"
  shift 4
  [ $# -gt 0 ] && shift
  mkdir -p "$dir"
  cp -R "$REPO/src/iyi" "$REPO/src/std" "$dir/"
  if ! awk "$script" "$REPO/src/iyi/$file" >"$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  build "$name-bin" "$flags" "$dir${PSEP}$REPO/src" || return
  local only=""
  [ "$want" = 86 ] && only=1
  timeout 600 env ${only:+HEAP22_PRINT_ONLY=1} "$WORK/$name-bin" "$@" >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$code" -ne "$want" ]; then
    echo "  $label: missed (exit $code, wanted $want)"
    sed -n '1,6p' "$dir/run.out" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 86 ]; then
    echo "  $label: caught, $(grep -m1 -A1 '^iyi: heap_verify: partition' "$dir/run.err" | tail -1 | sed 's/^ *//')"
  else
    echo "  $label: caught, $(grep -m1 '^FAIL: ' "$dir/run.out")"
  fi
}

# The placement hint for the directory mode's copies, which `hinted` applies
# to two files. heap_partition.iyi gets the copy's own hint code after
# `dir_outside?`; prelude.iyi's `take_large` maps the program's large objects
# (armed by `-Dplaced_force`) at the first slot above the directory's high
# bound. The kernel is asked for that address once: MAP_FIXED_NOREPLACE on
# Linux, an mmap hint on darwin, VirtualAlloc with an address on Windows.
# A kernel that does not give it fails the copy by name; nothing is retried.
PASS='{ print }'
PLACE_TAKE='/def self\.take_large\(size : UInt64, bits : UInt64\)/ { armed = 1 } armed && sub(/base = __iyi_mmap\(mapped\)\.address/, "base = placed_pick(size, mapped)") { armed = 0; found = 1 } { print } END { if (!found) exit 3 }'
PLACE_AFTER='/def self\.dir_outside\?\(slot : UInt64\) : Bool/ { armed = 1 } { print } armed && /^  end$/ { armed = 0; found = 1; while ((getline line < ins) > 0) print line } END { if (!found) exit 3 }'

# hinted LABEL NAME WANT [PRELUDE_AWK]: a copy of src/iyi with the placement
# hint, built with `-Dplaced_force` and run once as `dir`. WANT 1 is a forced
# copy: it must exit 1 at the first large object's sentence. WANT 0 is the
# hint alone: it must pass with at least one object outside the bounds.
# PRELUDE_AWK, when given, patches prelude.iyi too (c9's widening).
hinted() {
  local label="$1" name="$2" want="$3" patch="${4:-$PASS}"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  cp -R "$REPO/src/iyi" "$REPO/src/std" "$dir/"
  cat >"$WORK/placed.iyi" <<'IYI'

  # copy only (bench/heap_drain.sh's `hinted`): a large object the copy places
  # sits at the first slot above the directory's high bound, where only a
  # widening of the bounds makes the mark see it.
  @@placed_size : UInt64 = 0_u64

  def self.placed_arm(size : UInt64) : Nil
    @@placed_size = size
  end

  def self.placed_pick(size : UInt64, mapped : UInt64) : UInt64
    return placed_map(mapped) if @@placed_size != 0_u64 && size == @@placed_size
    __iyi_mmap(mapped).address
  end

  # One mapping asked for at one address: the kernel gives it or it does not
  # (Linux: a range in use is EEXIST, never moved; darwin and Windows: another
  # address). Anything else it gave is given back, and 0 says it was refused.
  def self.placed_try(hint : UInt64, mapped : UInt64) : UInt64
    got = 0_u64
    {% if flag?(:win32) %}
      got = LibC.VirtualAlloc(Pointer(Void).new(hint), mapped, 0x3000_i32, 4_i32).address
    {% elsif flag?(:darwin) %}
      got = LibC.mmap(Pointer(Void).new(hint), mapped, 3, 0x1002, -1, 0_i64).address
      if got == 0xFFFFFFFFFFFFFFFF_u64
        got = 0_u64
      end
    {% else %}
      # MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE: a range in use is EEXIST, never moved
      result = __iyi_conc_syscall6(IYI_SYS_MMAP, hint.to_i64, mapped.to_i64, 3_i64, 0x100022_i64, -1_i64, 0_i64)
      got = result < 0_i64 ? 0_u64 : result.to_u64
    {% end %}
    if got != 0_u64 && got != hint
      __iyi_munmap(got, mapped)
      got = 0_u64
    end
    got
  end

  # The first slot above the directory's high bound that the kernel gives a
  # mapping of *mapped* bytes: a slot in use (the program's own mappings sit
  # between some arenas and above them) is refused and the next is asked for,
  # up to 64. Every slot asked for is above the bounds, so the object is
  # outside them whichever one it gets.
  def self.placed_map(mapped : UInt64) : UInt64
    k = 1_u64
    while k <= 64_u64
      slot = @@dir_high &+ k
      placed_fail("iyi: placed: the directory has no slot above its high bound\n") if slot >= DIR_SLOTS
      hint = slot.unsafe_shl(24_u64)
      return hint if placed_try(hint, mapped) == hint
      k = k + 1_u64
    end
    placed_fail("iyi: placed: none of the 64 slots above the directory's high bound was free\n")
  end

  def self.placed_fail(message : String) : NoReturn
    __iyi_write(2, message.to_unsafe.as(Void*), message.bytesize.to_u64)
    __iyi_exit(1)
  end
IYI
  if ! awk -v ins="$WORK/placed.iyi" "$PLACE_AFTER" "$REPO/src/iyi/heap_partition.iyi" >"$dir/iyi/heap_partition.iyi"; then
    echo "  $label: heap_partition.iyi's dir_outside? is not in the form the copy patches"
    status=1
    return
  fi
  if ! awk "$PLACE_TAKE" "$REPO/src/iyi/prelude.iyi" >"$dir/prelude.1" || ! awk "$patch" "$dir/prelude.1" >"$dir/iyi/prelude.iyi"; then
    echo "  $label: prelude.iyi is not in the form the copy patches"
    status=1
    return
  fi
  build "$name-bin" "-Dheap_partitions --release -Dplaced_force" "$dir${PSEP}$REPO/src" || return
  timeout 600 "$WORK/$name-bin" dir >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$want" = 1 ]; then
    if [ "$code" -eq 1 ] && grep -qxE 'FAIL: dir: large object 0 at 0x[0-9a-f]+ is no heap pointer the moment it is made' "$dir/run.out"; then
      echo "  $label: caught, $(grep -m1 '^FAIL: ' "$dir/run.out")"
      return
    fi
  elif [ "$code" -eq 0 ] && grep -qE '^dir: [1-9][0-9]* of the 8 large objects landed outside' "$dir/run.out"; then
    echo "  $label: $(grep -m1 'landed outside' "$dir/run.out")"
    return
  fi
  echo "  $label: missed (exit $code, wanted $want)"
  sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
  status=1
}

# The mark's closer held open, for the program's `mark_forced` (-Dmark_force):
# the copy's helper_main waits at its finish on a word (`IyiMark.forced_wait`)
# until the program releases it, so a mark stays open while one unit allocates.
# The methods go in before helper_main and the wait before its finish call.
PLACE_MARK_METHODS='/def self\.helper_main\(seen : UInt64\) : Nil/ { found = 1; while ((getline line < ins) > 0) print line; print "" } { print } END { if (!found) exit 3 }'
PLACE_MARK_HOLD='/seen = finish_concurrent/ { found = 1; sub(/seen = finish_concurrent/, "IyiMark.forced_wait\n              seen = finish_concurrent") } { print } END { if (!found) exit 3 }'

# marked LABEL NAME WANT [HEAP_PATCH]: the copy holds the mark's closer open
# (`PLACE_MARK_*`), HEAP_PATCH is applied to heap_partition.iyi, and the
# program is built with `-Dmark_force` and run once as `mark`. WANT 0 is the
# hold alone: a unit's allocation under the open mark holds, and the program
# says so. WANT 1 must exit 1 at the sentence for a unit that allocated under
# the held mark and never held.
marked() {
  local label="$1" name="$2" want="$3" patch="${4:-$PASS}"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  cp -R "$REPO/src/iyi" "$REPO/src/std" "$dir/"
  cat >"$WORK/forced.iyi" <<'IYI'
      # copy only (bench/heap_drain.sh's `marked`): the closer of a mark holds
      # it open here, on a word, until the program lets it go; `forced_open`
      # says the hold has begun.
      @@forced_hold : UInt64 = 0_u64
      @@forced_open : UInt64 = 0_u64

      def self.forced_arm : Nil
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_open).address).value.set(0_u64)
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.set(1_u64)
      end

      def self.forced_release : Nil
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.set(0_u64)
      end

      def self.forced_open? : Bool
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_open).address).value.get != 0_u64
      end

      # A closer that finishes before the program arms the hold is not held,
      # and does not open anything: the program's own marks, at its list, end so.
      def self.forced_wait : Nil
        return if Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.get == 0_u64
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_open).address).value.set(1_u64)
        while Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.get != 0_u64
          IyiThread.park_if_requested
          IyiThread.spin_pause
        end
      end
IYI
  if ! awk -v ins="$WORK/forced.iyi" "$PLACE_MARK_METHODS" "$REPO/src/iyi/prelude.iyi" >"$dir/prelude.1" \
    || ! awk "$PLACE_MARK_HOLD" "$dir/prelude.1" >"$dir/iyi/prelude.iyi"; then
    echo "  $label: prelude.iyi's helper_main is not in the form the copy patches"
    status=1
    return
  fi
  if ! awk "$patch" "$REPO/src/iyi/heap_partition.iyi" >"$dir/iyi/heap_partition.iyi"; then
    echo "  $label: heap_partition.iyi is not in the form the copy patches"
    status=1
    return
  fi
  build "$name-bin" "-Dheap_partitions --release -Dmark_force" "$dir${PSEP}$REPO/src" || return
  timeout 600 "$WORK/$name-bin" mark >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$want" = 1 ]; then
    if [ "$code" -eq 1 ] && grep -qxE 'FAIL: mark: a unit allocated [0-9]+ bytes under a held mark and never held' "$dir/run.out"; then
      echo "  $label: caught, $(grep -m1 '^FAIL: ' "$dir/run.out")"
      return
    fi
  elif [ "$code" -eq 0 ] && grep -qE '^mark: a unit held under an open mark' "$dir/run.out"; then
    echo "  $label: $(grep -m1 '^mark: a unit held' "$dir/run.out")"
    return
  fi
  echo "  $label: missed (exit $code, wanted $want)"
  sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
  status=1
}

if [ "$PART" = all ] || [ "$PART" = copies ]; then
  echo "== each mechanism removed"
  copy "a partition takes drained runs" c1 1 \
    "$(subst 'def self\.partition_take' 'drained = pop_listed\(index, PC_DRAIN\)' 'drained = 0_u64')"
  copy "the global sweep lists a parked run again" c2 1 \
    "$(del 'def self\.sweep_partition_slice' 'IyiHeap\.list_drained\(index, arena, cursor, n\)')"
  copy "a taken run's objects published" c3 86 \
    "$(subst 'def self\.adopt_drained' 'write8\(own, OWN_PUB\)' 'write8(own, 0_u64)')" "-Dheap_partitions -Dheap_verify" 8 24 4
  copy "an idle worker wakes for the warm pool" c4 1 \
    "$(subst 'def self\.idle_wait_ms' 'elsif pool_warm\?' 'elsif false')"
  copy "a cooled run's pages go back" c5 1 \
    '/def self\.cool_pools/ { armed = 1 } armed && /^  end$/ { armed = 0 } armed && /__iyi_release_pages\(/ { found = found + 1; next } { print } END { if (found != 3) exit 3 }'
  marked "a unit holds beneath an open mark" held 0
  marked "a partition holds under a mark" c6 1 "$(del 'def self\.partition_slice' 'hold_partition\(record, debt\)')"
  # A sweep helper that lets its walk claim go before its walk ends: a
  # partition's local sweep could pass `quiet_class` into an arena whose
  # frees are still landing on its return stack (`IyiMark.sweep_one_
  # helper`, prelude.iyi). The release put above the walk.
  COPY_FILE=prelude.iyi copy "a helper holds its claim to its walk's end" c7 86 \
    '/def self\.sweep_one_helper : Bool/ { armed = 1 } armed && /^          batch = sweep_slice\(arena, SWEEP_SPAN\)$/ { print "          IyiHeap.class_lock(index)"; print "          release_claim(arena, epoch)"; print "          IyiHeap.class_unlock(index)"; print; armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
    "-Dheap_partitions -Dheap_verify" claim
  # The arena directory's bounds (TmacRss, heap22 fu): every word below
  # the directory's end read in it again, its pages go resident; not
  # widened by a large mapping, an object of one outside the arenas'
  # slots is nobody's.
  copy "the directory unread outside the bounds" c8 1 \
    "$(subst 'def self\.dir_outside\?' 'slot < @@dir_low \|\| slot > @@dir_high' 'slot >= DIR_SLOTS')" \
    "-Dheap_partitions --release" dir
  hinted "a large mapping widens the bounds" c9 1 "$(del 'def self\.count_large' 'dir_widen\(')"
  hinted "a placed large object lands outside the bounds" placed 0
fi

exit $status
