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
# without the release the resident set stays, without the hold a unit
# allocates under a held mark without holding, without the directory's
# bounds its pages go resident, and without widening the directory bounds
# for a large mapping, an object placed beyond them fails the heap-pointer
# check, and a taken run's
# objects left `LOCAL` instead of published, or a helper that lets its
# sweep claim go before its walk ends, are caught by `-Dheap_verify`
# (exit 86).
#
# Each copy's verdict is one whole line. The checks below are state-decided
# except for c4's clock-decided mutant catch; none is RSS-decided.
# State-decided: c1 (a drained run taken again), c2 (a parked run put back on
# a drain list), c5 (the cooled path's release calls, counted in the copy),
# c6 (a unit holds under the held mark), c8 (the bounds' answer, asked
# directly), c9 (a placed object's heap-pointer check), c3 and c7 (the
# verifier's report). The resident set and the arena growth are information.
# RSS-decided, not forced: none.
# Mutant catch clock-decided: c4 ("an idle worker wakes for the warm pool"). The
# mutant is caught when the pool is still warm IDLE_MS after the last round
# (`-Dwarm_force`). The warm-pool cap sits behind the pending-idle branch in
# `idle_wait_ms`, so no state record isolates it without a clock. The healthy
# build's reading of the same pool is information only and never fails.
# Probe 44819618628: two jobs on each shape, ten whole-gate passes per job.
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
  if ! env -u IYI_OPTS ${path:+IYI_PATH="$path"} "$IYI" build $flags -o "$WORK/$name" "${PROGRAM:-$REPO/bench/heap_drain.iyi}" >"$WORK/$name.build.log" 2>&1; then
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
  if [ "$code" -eq 76 ]; then
    echo "  $label: setup failed (exit 76: a watchdog or setup, not a catch)"
    sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$code" -ne "$want" ]; then
    echo "  $label: missed (exit $code, wanted $want)"
    sed -n '1,6p' "$dir/run.out" | sed 's/^/    /'
    status=1
    return
  fi
  if [ -n "${EXPECT:-}" ] && ! { [ "$(grep -c '^FAIL: ' "$dir/run.out")" -eq 1 ] && grep -qxE "$EXPECT" "$dir/run.out"; }; then
    echo "  $label: missed: the verdict is not the one sentence (wanted $EXPECT)"
    sed -n '1,6p' "$dir/run.out" | sed 's/^/    /'
    status=1
    return
  fi
  if [ -n "${EXPECT_FIXED:-}" ] && ! { [ "$(grep -c '^FAIL: ' "$dir/run.out")" -eq 1 ] && grep -Fxq -- "$EXPECT_FIXED" "$dir/run.out"; }; then
    echo "  $label: missed: the fixed verdict was not present"
    sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 86 ] && ! { [ -n "${EXPECT_ERR:-}" ] && grep -Fxq -- "$EXPECT_ERR" "$dir/run.err"; }; then
    echo "  $label: missed: the intended verifier report was not present"
    sed -n '1,6p' "$dir/run.err" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 86 ]; then
    echo "  $label: caught, $EXPECT_ERR"
  else
    echo "  $label: caught, $(grep -m1 '^FAIL: ' "$dir/run.out")"
  fi
}

# The placement hint for the directory mode's copies, which `hinted` applies
# to two files. heap_partition.iyi gets the copy's own hint code after
# `dir_outside?`; prelude.iyi's `take_large` maps the program's large objects
# (armed by `-Dplaced_force`) at the first slot above the directory's high
# bound. Linux uses MAP_FIXED_NOREPLACE, darwin an mmap hint, and Windows
# VirtualAlloc with an address. Occupied slots are skipped, up to 64; failure
# to place an object fails the copy by name.
PASS='{ print }'
PLACE_TAKE='/^      def self\.take_large\(size : UInt64, bits : UInt64\)/ { armed = 1; declarations++ } armed && /base = __iyi_mmap\(mapped\)\.address/ { sites++; sub(/base = __iyi_mmap\(mapped\)\.address/, "base = placed_pick(size, mapped)") } armed && /^      end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'
PLACE_AFTER='/^  def self\.dir_outside\?\(slot : UInt64\) : Bool/ { armed = 1; declarations++ } { print } armed && /^  end$/ { armed = 0; sites++; while ((getline line < ins) > 0) print line } END { if (declarations != 1 || sites != 1) exit 3 }'
C9_DELETE='/^      def self\.count_large\(base : UInt64, mapped : UInt64, on : Bool\)/ { armed = 1; declarations++ } armed && /dir_widen\(/ { sites++; next } armed && /^      end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'

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
    __iyi_exit(76)
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
  if [ -n "${NEG_REFUSE_PLACEMENT:-}" ]; then
    awk '{ if ($0 ~ /return hint if placed_try\(hint, mapped\) == hint/) { sub(/return hint if placed_try\(hint, mapped\) == hint/, "return hint if false"); n++ } print } END { if (n != 1) exit 3 }' "$dir/iyi/heap_partition.iyi" >"$dir/heap.neg" || { echo "  $label: the placement refusal control is not in the form the copy patches"; status=1; return; }
    mv "$dir/heap.neg" "$dir/iyi/heap_partition.iyi"
  fi
  build "$name-bin" "-Dheap_partitions --release -Dplaced_force" "$dir${PSEP}$REPO/src" || return
  timeout 600 "$WORK/$name-bin" dir >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$code" -eq 76 ]; then
    echo "  $label: setup failed (exit 76: the placement or a watchdog, not a catch)"
    sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 1 ]; then
    if [ "$code" -eq 1 ] && grep -qxE 'FAIL: dir: large object 0 at 0x[0-9a-f]+ is no heap pointer the moment it is made' "$dir/run.out"; then
      echo "  $label: caught, $(grep -m1 '^FAIL: ' "$dir/run.out")"
      return
    fi
  elif [ "$code" -eq 0 ] && grep -qxE 'dir: [1-9][0-9]* of the 8 large objects landed outside the slots before them, each a heap pointer' "$dir/run.out"; then
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
PLACE_MARK_METHODS='/^      def self\.helper_main\(seen : UInt64\) : Nil/ { declarations++; while ((getline line < ins) > 0) print line; print "" } { print } END { if (declarations != 1) exit 3 }'
PLACE_MARK_HOLD='/^      def self\.helper_main\(seen : UInt64\) : Nil/ { armed = 1; declarations++ } armed && /seen = finish_concurrent/ { sites++; sub(/seen = finish_concurrent/, "IyiMark.forced_wait\n              seen = finish_concurrent") } armed && /^      end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'
PLACE_MARK_SLICE='/^  def self\.partition_slice\(record : UInt64, slice : UInt64\) : Nil/ { armed = 1; declarations++ } armed && /if LibIyiGCTable\.__iyi_marking != 0_u8/ { sites++; print; print "      IyiMark.forced_record_slice(record)"; next } armed && /^  end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'
C6_DELETE='/^  def self\.partition_slice\(record : UInt64, slice : UInt64\) : Nil/ { armed = 1; declarations++ } armed && /hold_partition\(record, debt\)/ { sites++; next } armed && /^  end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'

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
      @@forced_target : UInt64 = 0_u64
      @@forced_slice : UInt64 = 0_u64

      def self.forced_target(record : UInt64) : Nil
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_target).address).value.set(record)
      end

      def self.forced_record_slice(record : UInt64) : Nil
        target = Pointer(Atomic(UInt64)).new(pointerof(@@forced_target).address).value.get
        if target != 0_u64 && target == record && forced_open? && Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.get != 0_u64
          Pointer(Atomic(UInt64)).new(pointerof(@@forced_slice).address).value.set(1_u64)
        end
      end

      def self.forced_slice? : Bool
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_slice).address).value.get != 0_u64
      end

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
        started = IyiMark.now_ns
        while Pointer(Atomic(UInt64)).new(pointerof(@@forced_hold).address).value.get != 0_u64
          if IyiMark.now_ns &- started >= 120000000000_u64
            message = "FAIL: mark: closer timed out waiting for release\n"
            __iyi_write(1, message.to_unsafe.as(Void*), message.bytesize.to_u64)
            __iyi_exit(76)
          end
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
  if ! awk "$PLACE_MARK_SLICE" "$REPO/src/iyi/heap_partition.iyi" >"$dir/heap.1" || ! awk "$patch" "$dir/heap.1" >"$dir/iyi/heap_partition.iyi"; then
    echo "  $label: heap_partition.iyi is not in the form the copy patches"
    status=1
    return
  fi
  local program="$REPO/bench/heap_drain.iyi"
  if [ -n "${NEG_STALL_UNIT:-}" ]; then
    awk '{ if ($0 ~ /IyiMark\.forced_target\(IyiHeap\.current_record\)/) { print "          while true"; print "            sleep(1)"; print "          end"; n++ } print } END { if (n != 1) exit 3 }' "$REPO/bench/heap_drain.iyi" >"$dir/program.iyi" || { echo "  $label: the stalled-unit control is not in the form the program has"; status=1; return; }
    program="$dir/program.iyi"
  fi
  PROGRAM="$program" build "$name-bin" "-Dheap_partitions --release -Dmark_force" "$dir${PSEP}$REPO/src" || return
  timeout 600 "$WORK/$name-bin" mark >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$code" -eq 76 ]; then
    echo "  $label: setup failed (exit 76: a watchdog or setup, not a catch)"
    sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 1 ]; then
    if [ "$code" -eq 1 ] && [ "$(grep -c '^FAIL: ' "$dir/run.out")" -eq 1 ] && grep -qxE 'FAIL: mark: a unit allocated [0-9]+ bytes under a held mark and never held' "$dir/run.out"; then
      echo "  $label: caught, $(grep -xE 'FAIL: mark: a unit allocated [0-9]+ bytes under a held mark and never held' "$dir/run.out")"
      return
    fi
  elif [ "$code" -eq 0 ] && grep -qxE 'mark: a unit held under an open mark: [1-9][0-9]* holds, its partition past its ceiling while the mark was open' "$dir/run.out"; then
    echo "  $label: $(grep -m1 '^mark: a unit held' "$dir/run.out")"
    return
  fi
  echo "  $label: missed (exit $code, wanted $want)"
  sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
  status=1
}

# The cooled path's release call, counted (c5). COOL_ACCESS adds the copy-only
# counter and its reader before `cool_pools`, once. COOL_HOOK records each of
# its three release calls beside the call, under the same condition; COOL_BROKEN
# deletes the calls, and the record with them.
COOL_ACCESS='/^  def self\.cool_pools\(limit : Int32\) : Nil/ { declarations++; while ((getline line < ins) > 0) print line; print "" } { print } END { if (declarations != 1) exit 3 }'
COOL_BROKEN='/def self\.cool_pools/ { armed = 1 } armed && /^  end$/ { armed = 0 } armed && /__iyi_release_pages\(/ { found = found + 1; next } { print } END { if (found != 3) exit 3 }'
COOL_HOOK='/^  def self\.cool_pools/ { armed = 1; declarations++ } armed && /__iyi_release_pages\(/ { line = $0; print; cond = line; if (!sub(/^.* if /, "", cond)) exit 3; indent = line; sub(/[^ ].*$/, "", indent); print indent "IyiHeap.cool_record if " cond; sites++; next } armed && /^  end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 3) exit 3 }'

# The copy-only methods COOL_ACCESS inserts: the counter and its reader.
# `state LABEL NAME WANT FLAGS ACCESS SITE`: the copy of src/iyi with ACCESS,
# then SITE, applied to heap_partition.iyi, built with FLAGS and run once in
# drain mode. WANT 1 must exit 1 with the one sentence the program prints when
# the release never ran; WANT 0 (the hook alone) must exit 0 and print the count.
# Exit 76 is setup or a watchdog, never a catch.
state() {
  local label="$1" name="$2" want="$3" flags="$4" access="$5" site="$6"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  cp -R "$REPO/src/iyi" "$REPO/src/std" "$dir/"
  cat >"$WORK/cool.iyi" <<'IYI'
  # copy only (bench/heap_drain.sh's `state`): the count of the cooled path's
  # release calls, written beside each call.
  @@cool_released : UInt64 = 0_u64

  def self.cool_record : Nil
    Pointer(Atomic(UInt64)).new(pointerof(@@cool_released).address).value.add(1_u64)
  end

  def self.cool_released_count : UInt64
    Pointer(Atomic(UInt64)).new(pointerof(@@cool_released).address).value.get
  end

  def self.cool_arm : Nil
    IyiStat.set(IyiStat::COOL_PENDING, 1_u64)
  end

    IyiStat.set(IyiStat::COOL_PENDING, 1_u64)
  end

IYI
  if ! awk -v ins="$WORK/cool.iyi" "$access" "$REPO/src/iyi/heap_partition.iyi" >"$dir/a.1"; then
    echo "  $label: heap_partition.iyi's cool_pools is not in the form the copy patches"
    status=1
    return
  fi
  if ! awk "$site" "$dir/a.1" >"$dir/iyi/heap_partition.iyi"; then
    echo "  $label: cool_pools' release calls are not in the form the copy patches"
    status=1
    return
  fi
  build "$name-bin" "$flags" "$dir${PSEP}$REPO/src" || return
  timeout 600 "$WORK/$name-bin" >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$code" -eq 76 ]; then
    echo "  $label: setup failed (exit 76)"
    sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 1 ]; then
    if [ "$code" -eq 1 ] && [ "$(grep -c '^FAIL: ' "$dir/run.out")" -eq 1 ] && grep -qxE "FAIL: idle: no cooled run's pages were handed back to the OS: the release call did not run" "$dir/run.out"; then
      echo "  $label: caught, FAIL: idle: no cooled run's pages were handed back to the OS: the release call did not run"
      return
    fi
  elif [ "$code" -eq 0 ] && grep -qxE 'idle: [1-9][0-9]* cooled runs handed their pages back to the OS' "$dir/run.out"; then
    echo "  $label: $(grep -xE 'idle: [1-9][0-9]* cooled runs handed their pages back to the OS' "$dir/run.out")"
    return
  fi
  echo "  $label: missed (exit $code, wanted $want)"
  sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
  status=1
}
if [ "$PART" = all ] || [ "$PART" = copies ]; then
  echo "== each mechanism removed"
  EXPECT='^FAIL: drain: no parked run was taken again from a drained list$' copy "a partition takes drained runs" c1 1 \
    "$(subst 'def self\.partition_take' 'drained = pop_listed\(index, PC_DRAIN\)' 'drained = 0_u64')"
  keyed "the global sweep's relist, deleted (c2)" c2 1 park "FAIL: drain: the global sweep left the run the program parked on no drain list" "-Dheap_partitions --release -Dkeyed_force" "$PARK_BROKEN"
  keyed "the relist, kept and recorded (hook only)" relisted 0 park "drain: the global sweep put the run the program parked back on its class's drain list" "-Dheap_partitions --release -Dkeyed_force" "$PARK_WITNESS"
  EXPECT_ERR='  a slot names a LOCAL chunk its local mark left unmarked, about to be freed' copy "a taken run's objects published" c3 86 \
    "$(subst 'def self\.adopt_drained' 'write8\(own, OWN_PUB\)' 'write8(own, 0_u64)')" "-Dheap_partitions -Dheap_verify" 8 24 4
  keyed "an idle worker wakes for the warm pool (c4)" c4 1 warm "FAIL: idle_wait_ms left a worker's wait unbounded with a pooled run held warm and no partition pending" "-Dheap_partitions --release -Dkeyed_force" "$WARM_BROKEN"
  keyed "the warm-pool cap, kept (hook only)" warm 0 warm "idle: idle_wait_ms cut a worker's unbounded wait to the pool's turn with a pooled run held warm and no partition pending" "-Dheap_partitions --release -Dkeyed_force"
  keyed "a cooled run's pages go back (c5)" c5 1 cool "FAIL: idle: the run the program put on a release list reached the cold list with its page unreleased: the release call did not run" "-Dheap_partitions --release -Dkeyed_force" "$COOL_BROKEN"
  keyed "a cooled run's release is recorded (hook only)" cool 0 cool "idle: the run the program put on a release list reached the cold list with its page reading zero" "-Dheap_partitions --release -Dkeyed_force" "$COOL_WITNESS"
  marked "a unit holds beneath an open mark" held 0
  marked "a partition holds under a mark" c6 1 "$C6_DELETE"
  # A sweep helper that lets its walk claim go before its walk ends: a
  # partition's local sweep could pass `quiet_class` into an arena whose
  # frees are still landing on its return stack (`IyiMark.sweep_one_
  # helper`, prelude.iyi). The release put above the walk.
  EXPECT_ERR='  a sweep slice ended without its walk claim: another walker, or a local sweep past `quiet_class`, could walk the slice with it' COPY_FILE=prelude.iyi copy "a helper holds its claim to its walk's end" c7 86 \
    '/def self\.sweep_one_helper : Bool/ { armed = 1 } armed && /^          batch = sweep_slice\(arena, SWEEP_SPAN\)$/ { print "          IyiHeap.class_lock(index)"; print "          release_claim(arena, epoch)"; print "          IyiHeap.class_unlock(index)"; print; armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' \
    "-Dheap_partitions -Dheap_verify" claim
  # The arena directory's bounds (TmacRss, heap22 fu): every word below
  # the directory's end read in it again, its pages go resident; not
  # widened by a large mapping, an object of one outside the arenas'
  # slots is nobody's.
  EXPECT_FIXED="FAIL: dir: a slot outside every arena's bounds is answered as inside" copy "the directory unread outside the bounds" c8 1 \
    "$(subst 'def self\.dir_outside\?' 'slot < @@dir_low \|\| slot > @@dir_high' 'slot >= DIR_SLOTS')" \
    "-Dheap_partitions --release" dir
  hinted "a large mapping widens the bounds" c9 1 "$C9_DELETE"
  hinted "a placed large object lands outside the bounds" placed 0
fi

exit $status
