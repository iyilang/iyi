#!/usr/bin/env bash
# heap22 S6 (LeakHunt): the partitions' runs given back, driven.
# bench/heap_drain.iyi built with partitions, plain and optimised, with its
# verifier, and under chaos with a local collection at every park: the sound
# builds, which must finish with no verifier report. Then the sound modes: the
# partitions held under long global marks (mark), the helpers' sweep claims
# (claim), the arena directory's bounds (dir), a unit's first allocation taking
# a drained run (adopt), and the flag-off control.
#
# Then one broken copy per mechanism, with a control run separately on the
# same path. A catch needs the named exit and whole verdict line. Fixed lines
# use grep -Fx; the c6 and c9 lines with numeric values use whole-line regexes.
# Exit 76 is setup, never a catch. The c7 count control expects its own 76
# watchdog sentence and must not be confused with the mutant's exit 86.
#
#   c1  a partition takes drained runs (exit 1)
#         FAIL: drain: no parked run was taken again from a drained list
#       Unchanged take, site counted (exit 0):
#         drain: 35712 kept strings intact
#   c2  the global sweep's relist, deleted (exit 1). Keyed park: the run the
#       program parks is read after the sweep: is it on its class's drain list?
#         FAIL: drain: the global sweep left the run the program parked on no drain list
#       Hook only, the relist kept and recorded (exit 0):
#         drain: the global sweep put the run the program parked back on its class's drain list
#   c3  a taken run's published mark lost (exit 86): the verifier's report at
#       the taker's own local collection, the first check that sees them.
#         a slot names a LOCAL chunk its local mark left unmarked, about to be freed
#       The same mutant with the verifier's local check silenced (exit 1): the
#       taker's own check reads the published mark.
#         FAIL: adopt: the published string is LOCAL after the taker's local collection
#       Hook only (exit 0):
#         adopt: a unit's first allocation took a run its dead predecessor published, and the local collection left the published string intact
#   c4  the pool-turn cap of a worker's idle wait, deleted (exit 1). Keyed warm:
#       a pooled run is held warm with no partition pending, and the wait the
#       worker gets is read: the selected idle deadline, not a clock.
#         FAIL: idle_wait_ms left a worker's wait unbounded with a pooled run held warm and no partition pending
#       Hook only (exit 0):
#         idle: idle_wait_ms cut a worker's unbounded wait to the pool's turn with a pooled run held warm and no partition pending
#   c5  a cooled run's page releases, deleted (exit 1). Keyed cool: the staged
#       run's first page holds a sentinel, read after the cooler returns (the
#       staged-page sentinel).
#         FAIL: idle: the run the program put on a release list reached the cold list with its page unreleased: the release call did not run
#       Hook only, the release recorded (exit 0):
#         idle: the run the program put on a release list reached the cold list with its page reading zero
#   c6  a unit allocates under an open mark without holding (exit 1).
#         FAIL: mark: a unit allocated N bytes under a held mark and never held
#       Hook only, the hold in place (exit 0):
#         mark: a unit held under an open mark: N holds, its partition past its ceiling while the mark was open
#   c7  the staged walk claim let go after its walk, under the class's lock, before
#       its check (exit 86). The release line names the staged slice, and the
#       verifier's report must name the same arena:
#         claim: the staged slice at 0x... let its walk claim go before its check
#         a sweep slice ended without its walk claim: another walker, or a local sweep past `quiet_class`, could walk the slice with it
#       Hook only, the staged slice checked and the round closed (exit 0):
#         claim: every walk claim held to its walk's end
#       The release kept under the class's lock, the staged check skipped (exit 0):
#       the lock and the reservation hold until the slice's tail has run,
#       so nothing can observe the release and no slice reports:
#         claim: every walk claim held to its walk's end
#       Completion not recorded (exit 76, its own watchdog sentence):
#         FAIL: claim: the staged slice did not complete within the watchdog
#   c8  the boundary predicate answers every slot below DIR_SLOTS as inside
#       (exit 1), asked directly for slot 0.
#         FAIL: dir: a slot outside every arena's bounds is answered as inside
#       Unchanged predicate, site counted (exit 0):
#         dir: the boundary predicate answers outside for a slot below every arena
#   c9  a large mapping does not widen the bounds (exit 1): its object fails the
#       heap-pointer check at its first sentence.
#         FAIL: dir: large object 0 at 0x... is no heap pointer the moment it is made
#       Placed hint only (exit 0):
#         dir: N of the 8 large objects landed outside the slots before them, each a heap pointer
#
# Residency, RSS, arena growth, carved and cold bytes and the pool's warm state
# are printed as information only. No verdict reads them, so none fails a run,
# and an unavailable reading prints as unavailable.
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
  echo "== the drained runs taken again, round after round (-Dheap_partitions)"
  whole "plain" plain "-Dheap_partitions"
  whole "optimised" release "-Dheap_partitions --release"
  whole "verifier" verify "-Dheap_partitions -Dheap_verify" 8 24 4
  echo "== the partitions held under long marks (mark mode)"
  again "optimised" release release-mark mark
  again "verifier" verify verify-mark mark 1000000 4 2
  echo "== the helpers' sweep claims checked at each walk's end (claim mode)"
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

# copy LABEL DIR WANT AWK [FLAGS [ARGS...]]: patch COPY_FILE (default
# heap_partition.iyi) and, when named, EXTRA_FILE using EXTRA_AWK. Build and
# run once. A catch needs its expected exit and whole verdict line, and with
# NAMED_STAGED its verifier report must name the arena that the staged slice's
# release line named. A control needs its expected output and no verifier
# report. Exit 76 is setup, except for the explicit watchdog control, which
# checks its own setup sentence.
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
  if [ -n "${EXTRA_FILE:-}" ] && ! awk "$EXTRA_AWK" "$REPO/src/iyi/$EXTRA_FILE" >"$dir/iyi/$EXTRA_FILE"; then
    echo "  $label: what the copy changes is not in $EXTRA_FILE any more"
    status=1
    return
  fi
  build "$name-bin" "$flags" "$dir${PSEP}$REPO/src" || return
  local only=""
  [ "$want" = 86 ] && only=1
  timeout 600 env ${only:+HEAP22_PRINT_ONLY=1} "$WORK/$name-bin" "$@" >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$want" = 76 ] && [ "$code" -eq 76 ] && [ -n "${EXPECT_SETUP:-}" ] &&
    [ "$(grep -c '^FAIL: ' "$dir/run.out")" -eq 1 ] &&
    grep -Fxq -- "$EXPECT_SETUP" "$dir/run.out"; then
    echo "  $label: expected setup watchdog (exit 76), $EXPECT_SETUP"
    return
  fi
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
  if [ "$want" = 86 ] && [ -n "${NAMED_STAGED:-}" ]; then
    local named reported
    named="$(sed -n 's/^  claim: the staged slice at \(0x[0-9a-f]\{16\}\) let its walk claim go before its check$/\1/p' "$dir/run.err")"
    reported="$(sed -n 's/^    arena \(0x[0-9a-f]\{16\}\), claim .*$/\1/p' "$dir/run.err")"
    if [ "$(printf '%s\n' "$named" | grep -c .)" -ne 1 ] || [ "$named" != "$reported" ]; then
      echo "  $label: missed: the catch does not name the staged slice (staged ${named:-none}, reported ${reported:-none})"
      sed -n '1,8p' "$dir/run.err" | sed 's/^/    /'
      status=1
      return
    fi
  fi
  if [ "$want" = 0 ]; then
    if grep -q '^iyi: heap_verify' "$dir/run.err" || { [ -n "${EXPECT_OUT:-}" ] && ! grep -Fxq -- "$EXPECT_OUT" "$dir/run.out"; }; then
      echo "  $label: missed: the verifier reported, or the expected line is absent"
      sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
      status=1
      return
    fi
    echo "  $label: no verifier report, and the expected line is present"
    return
  fi
  if [ "$want" = 86 ]; then
    echo "  $label: caught, $EXPECT_ERR${NAMED_STAGED:+, naming the staged slice $named}"
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
PLACE_TAKE='/^      (@\[Effect\([^)]*\)\]; )?def self\.take_large\(size : UInt64, bits : UInt64\)/ { armed = 1; declarations++ } armed && /base = __iyi_mmap\(mapped\)\.address/ { sites++; sub(/base = __iyi_mmap\(mapped\)\.address/, "base = placed_pick(size, mapped)") } armed && /^      end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'
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
PLACE_MARK_METHODS='/^      (@\[Effect\([^)]*\)\]; )?def self\.helper_main\(seen : UInt64\) : Nil/ { declarations++; while ((getline line < ins) > 0) print line; print "" } { print } END { if (declarations != 1) exit 3 }'
PLACE_MARK_HOLD='/^      (@\[Effect\([^)]*\)\]; )?def self\.helper_main\(seen : UInt64\) : Nil/ { armed = 1; declarations++ } armed && /seen = finish_concurrent/ { sites++; sub(/seen = finish_concurrent/, "IyiMark.forced_wait\n              seen = finish_concurrent") } armed && /^      end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'
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

# The keyed witnesses (c2, c4 and c5). KEYED_ACCESS inserts the
# copy-only methods once, before `cool_pools`; each site awk adds one witness
# call or deletes one mechanism. Every anchor must match exactly once, or the
# awk exits 3 and the copy is "not in the form the copy patches", a setup failure.
KEYED_ACCESS='/^  def self\.cool_pools\(limit : Int32\) : Nil$/ { declarations++; while ((getline line < ins) > 0) print line; print "" } { print } END { if (declarations != 1) exit 3 }'
# The keyed copies serialize cooling on a copy-only word. The test holds it
# while staging and exercising a run, so an idle worker cannot take that run.
COOL_GATE='/^  def self\.cool_pools\(limit : Int32\) : Nil$/ { declarations++; print "  def self.cool_pools(limit : Int32) : Nil"; print "    cool_gate_lock"; print "    cool_pools_body(limit)"; print "    cool_gate_unlock"; print "  end"; print ""; print "  def self.cool_pools_body(limit : Int32) : Nil"; next } { print } END { if (declarations != 1) exit 3 }'
# c2: the relist of the run the program parked. The control keeps the relist and
# records it; the mutant deletes the relist and keeps the record and counter.
PARK_WITNESS='/^  def self\.sweep_partition_slice\(arena : UInt64, span : UInt64\) : UInt64$/ { armed = 1; declarations++ } { print } armed && /^          IyiHeap\.list_drained\(index, arena, cursor, n\)$/ { sites++; print "          IyiHeap.park_witness(arena, granule, cursor, index)" } armed && /^          IyiHeap\.note_drained$/ { counters++ } armed && /^  end$/ { armed = 0 } END { if (declarations != 1 || sites != 1 || counters != 1) exit 3 }'
PARK_BROKEN='/^  def self\.sweep_partition_slice\(arena : UInt64, span : UInt64\) : UInt64$/ { armed = 1; declarations++ } armed && /^          IyiHeap\.list_drained\(index, arena, cursor, n\)$/ { sites++; print "          IyiHeap.park_witness(arena, granule, cursor, index)"; next } armed && /^          IyiHeap\.note_drained$/ { counters++ } armed && /^  end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1 || counters != 1) exit 3 }'
# c4: the warm-pool branch of idle_wait_ms, the cap a worker's wait gets.
WARM_BROKEN='/^  def self\.idle_wait_ms\(timeout : Int64\) : Int64$/ { armed = 1; declarations++ } armed && /^    elsif pool_warm\?$/ { sites++; sub(/pool_warm\?/, "false") } armed && /^  end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'
# c5: the cooled run's release. Both copies record eligibility and the cold
# push; only the mutant deletes the three release calls.
COOL_SITE='/^  def self\.cool_pools_body\(limit : Int32\) : Nil$/ { armed = 1; declarations++ } armed && /^      __iyi_release_pages\(low, high - low\) if high > low$/ { sites++; print "      cool_eligible(run, low, high) if high > low" } armed && /^  end$/ { armed = 0 } { print } END { if (declarations != 1 || sites != 1) exit 3 }'
COOL_WITNESS='/^  def self\.cool_pools_body\(limit : Int32\) : Nil$/ { armed = 1; declarations++ } { print } armed && /^      write64\(line \+ PC_COLD, run\)$/ { sites++; print "      cool_witness(run)" } armed && /^  end$/ { armed = 0 } END { if (declarations != 1 || sites != 1) exit 3 }'
COOL_BROKEN='/^  def self\.cool_pools_body\(limit : Int32\) : Nil$/ { armed = 1; declarations++ } armed && /^      __iyi_release_pages\(low, high - low\) if high > low$/ { whole++; next } armed && /^      __iyi_release_pages\(edge, PAGE\) if edge < low && pooled_page\?\(arena, edge\)$/ { first++; next } armed && /^      __iyi_release_pages\(high, PAGE\) if high < span_high && high >= low && pooled_page\?\(arena, high\)$/ { last++; next } armed && /^      write64\(line \+ PC_COLD, run\)$/ { sites++; print; print "      cool_witness(run)"; next } armed && /^  end$/ { armed = 0 } { print } END { if (declarations != 1 || whole != 1 || first != 1 || last != 1 || sites != 1) exit 3 }'

# keyed LABEL NAME WANT WHICH LINE FLAGS [SITE...]: the copy of src/iyi with
# KEYED_ACCESS, then each SITE in order, applied to heap_partition.iyi, built
# with FLAGS and run as `keyed WHICH`. WANT 1 must exit 1 with exactly one FAIL
# line and LINE as a whole line; WANT 0 must exit 0 with LINE as a whole line
# and no FAIL line. Exit 76 is setup (a watchdog or a stage that never reached
# its run) and never a catch.
keyed() {
  local label="$1" name="$2" want="$3" which="$4" line="$5" flags="$6"
  shift 6
  local dir="$WORK/$name"
  mkdir -p "$dir"
  cp -R "$REPO/src/iyi" "$REPO/src/std" "$dir/"
  cat >"$WORK/keyed.iyi" <<'IYI'
  # copy only (bench/heap_drain.sh's `keyed`): the witnesses. Each records what
  # the runtime did to the one run the program staged; a copy that never reaches
  # that run leaves its record empty, and the program reports setup, not a catch.
  @[UnsafeReach("the staged run is stored and read atomically")]
  @@park_key : UInt64 = 0_u64
  @[UnsafeReach("the sweep records and the program reads atomically")]
  @@park_seen : UInt64 = 0_u64
  @[UnsafeReach("the staged run is stored and read atomically")]
  @@cool_key : UInt64 = 0_u64
  @[UnsafeReach("the staged page is stored and read atomically")]
  @@cool_page : UInt64 = 0_u64
  @[UnsafeReach("the cooler records and the program reads atomically")]
  @@cool_seen : UInt64 = 0_u64
  @[UnsafeReach("the release site records and the witness reads atomically")]
  @@cool_eligible : UInt64 = 0_u64
  COOL_SENTINEL = 0x5EEDC0015EEDC001_u64
  @[UnsafeReach("the copy-only cooling gate is acquired and released atomically")]
  @@cool_gate : UInt64 = 0_u64

  # Only the copy serializes cooling. A waiter has its own watchdog sentence;
  # neither its timing nor its count can decide a mutant verdict.
  def self.cool_gate_lock : Nil
    word = Pointer(Atomic(UInt64)).new(pointerof(@@cool_gate).address)
    started = IyiMark.now_ns
    until word.value.compare_and_set(0_u64, 1_u64)[1]
      if IyiMark.now_ns &- started >= 120000000000_u64
        message = "FAIL: keyed cooling: timed out waiting for the copy-only gate\n"
        __iyi_write(1, message.to_unsafe.as(Void*), message.bytesize.to_u64)
        __iyi_exit(76)
      end
      IyiThread.spin_pause
    end
  end

  def self.cool_gate_unlock : Nil
    Pointer(Atomic(UInt64)).new(pointerof(@@cool_gate).address).value.set(0_u64)
  end

  def self.park_stage : UInt64
    index = 0
    while index < CLASSES
      class_lock(index)
      run = take_pool_run(index)
      if run != 0_u64
        arena = run & (0_u64 &- MAP)
        granule = granule_of(arena, run)
        set_run_word(arena, granule, 0_u64, run_n(run_word(arena, granule)), RUN_PARKED)
        Pointer(Atomic(UInt64)).new(pointerof(@@park_key).address).value.set(run)
        class_unlock(index)
        return run
      end
      class_unlock(index)
      index = index + 1
    end
    0_u64
  end

  def self.park_witness(arena : UInt64, granule : UInt64, run : UInt64, index : Int32) : Nil
    return unless run == Pointer(Atomic(UInt64)).new(pointerof(@@park_key).address).value.get
    seen = Pointer(Atomic(UInt64)).new(pointerof(@@park_seen).address)
    return unless seen.value.get == 0_u64
    listed = read64(pline(index) + PC_DRAIN) == run ? 2_u64 : 0_u64
    seen.value.set(1_u64 | listed | run_state(run_word(arena, granule)).unsafe_shl(4_u64))
  end

  def self.park_seen : UInt64
    Pointer(Atomic(UInt64)).new(pointerof(@@park_seen).address).value.get
  end

  def self.warm_stage : Bool
    index = 0
    while index < CLASSES
      class_lock(index)
      line = pline(index)
      if (read64(line + PC_POOL) | read64(line + PC_OLD) | read64(line + PC_RELEASE)) != 0_u64
        class_unlock(index)
        return true
      end
      run = pop_listed(index, PC_COLD)
      if run != 0_u64
        arena = run & (0_u64 &- MAP)
        pool_run(index, arena, run, run_n(run_word(arena, granule_of(arena, run))))
        class_unlock(index)
        return true
      end
      class_unlock(index)
      index = index + 1
    end
    false
  end

  def self.warm_wait(requested : Int64) : Int64
    lock
    pending = IyiStat.atomic(IyiStat::IDLE_PENDING)
    was_pending = pending.value.get
    was_cursor = IyiStat.get(IyiStat::IDLE_CURSOR)
    pending.value.set(0_u64)
    IyiStat.set(IyiStat::IDLE_CURSOR, 0_u64)
    got = -2_i64
    index = 0
    while got == -2_i64 && index < CLASSES
      class_lock(index)
      line = pline(index)
      got = idle_wait_ms(requested) if (read64(line + PC_POOL) | read64(line + PC_OLD) | read64(line + PC_RELEASE)) != 0_u64
      class_unlock(index)
      index = index + 1
    end
    IyiStat.set(IyiStat::IDLE_CURSOR, was_cursor)
    pending.value.set(1_u64) if was_pending != 0_u64
    unlock
    got
  end

  def self.cool_arm : Nil
    IyiStat.set(IyiStat::COOL_PENDING, 1_u64)
  end

  def self.cool_stage : UInt64
    IyiStat.set(IyiStat::COOL_PENDING, 1_u64)
    index = 0
    while index < CLASSES
      class_lock(index)
      line = pline(index)
      chosen = 0_u64
      skipped = 0_u64
      while chosen == 0_u64
        run = take_pool_run(index)
        break if run == 0_u64
        arena = run & (0_u64 &- MAP)
        granule = granule_of(arena, run)
        n = run_n(run_word(arena, granule))
        low = (first_head(arena, run) + PAGE - 1_u64) & (0_u64 &- PAGE)
        high = first_head(arena, run + n.unsafe_shl(GRANULE_SHIFT)) & (0_u64 &- PAGE)
        if high > low
          write64(low, COOL_SENTINEL)
          set_run_word(arena, granule, read64(line + PC_RELEASE), n, RUN_POOL)
          write64(line + PC_RELEASE, run)
          Pointer(Atomic(UInt64)).new(pointerof(@@cool_page).address).value.set(low)
          Pointer(Atomic(UInt64)).new(pointerof(@@cool_key).address).value.set(run)
          chosen = run
        else
          set_run_word(arena, granule, skipped, n, RUN_POOL)
          skipped = run
        end
      end
      while skipped != 0_u64
        arena = skipped & (0_u64 &- MAP)
        granule = granule_of(arena, skipped)
        word = run_word(arena, granule)
        set_run_word(arena, granule, read64(line + PC_POOL), run_n(word), RUN_POOL)
        write64(line + PC_POOL, skipped)
        skipped = word & RUN_LINK
      end
      class_unlock(index)
      return chosen if chosen != 0_u64
      index = index + 1
    end
    0_u64
  end

  # Record the same keyed run at the whole-page release site in both copies.
  def self.cool_eligible(run : UInt64, low : UInt64, high : UInt64) : Nil
    key = Pointer(Atomic(UInt64)).new(pointerof(@@cool_key).address).value.get
    page = Pointer(Atomic(UInt64)).new(pointerof(@@cool_page).address).value.get
    if key != 0_u64 && run == key && low == page && high > low
      Pointer(Atomic(UInt64)).new(pointerof(@@cool_eligible).address).value.set(run)
    end
  end

  def self.cool_witness(run : UInt64) : Nil
    return unless run == Pointer(Atomic(UInt64)).new(pointerof(@@cool_key).address).value.get
    seen = Pointer(Atomic(UInt64)).new(pointerof(@@cool_seen).address)
    return unless seen.value.get == 0_u64
    arena = run & (0_u64 &- MAP)
    n = run_n(run_word(arena, granule_of(arena, run)))
    low = (first_head(arena, run) + PAGE - 1_u64) & (0_u64 &- PAGE)
    high = first_head(arena, run + n.unsafe_shl(GRANULE_SHIFT)) & (0_u64 &- PAGE)
    page = Pointer(Atomic(UInt64)).new(pointerof(@@cool_page).address).value.get
    eligible = Pointer(Atomic(UInt64)).new(pointerof(@@cool_eligible).address).value.get
    whole = high > low && low == page && eligible == run ? 2_u64 : 0_u64
    word = read64(page)
    read = word == 0_u64 ? 1_u64 : (word == COOL_SENTINEL ? 2_u64 : 3_u64)
    seen.value.set(1_u64 | whole | read.unsafe_shl(4_u64))
  end

  def self.cool_seen : UInt64
    Pointer(Atomic(UInt64)).new(pointerof(@@cool_seen).address).value.get
  end

IYI
  if ! awk -v ins="$WORK/keyed.iyi" "$KEYED_ACCESS" "$REPO/src/iyi/heap_partition.iyi" >"$dir/k.insert" \
    || ! awk "$COOL_GATE" "$dir/k.insert" >"$dir/k.0"; then
    echo "  $label: heap_partition.iyi's cool_pools is not in the form the copy patches"
    status=1
    return
  fi
  local src="$dir/k.0" i=0 script
  for script in "$@"; do
    i=$((i + 1))
    if ! awk "$script" "$src" >"$dir/k.$i"; then
      echo "  $label: site $i is not in the form the copy patches"
      status=1
      return
    fi
    src="$dir/k.$i"
  done
  cp "$src" "$dir/iyi/heap_partition.iyi"
  build "$name-bin" "$flags" "$dir${PSEP}$REPO/src" || return
  timeout 600 "$WORK/$name-bin" keyed "$which" >"$dir/run.out" 2>"$dir/run.err"
  local code=$?
  if [ "$code" -eq 76 ]; then
    echo "  $label: setup failed (exit 76: a stage that never reached its run, or a watchdog)"
    sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
    status=1
    return
  fi
  if [ "$want" = 1 ]; then
    if [ "$code" -eq 1 ] && [ "$(grep -c '^FAIL: ' "$dir/run.out")" -eq 1 ] && grep -Fxq -- "$line" "$dir/run.out"; then
      echo "  $label: caught, $line"
      return
    fi
  elif [ "$code" -eq 0 ] && [ "$(grep -c '^FAIL: ' "$dir/run.out")" -eq 0 ] && grep -Fxq -- "$line" "$dir/run.out"; then
    echo "  $label: $line"
    return
  fi
  echo "  $label: missed (exit $code, wanted $want)"
  sed -n '1,6p' "$dir/run.out" "$dir/run.err" | sed 's/^/    /'
  status=1
}
if [ "$PART" = all ] || [ "$PART" = copies ]; then
  echo "== each mechanism removed"
  # c1 (`partition_take`'s drained list): the mutant takes no drained run, so the
  # runtime's own count of drained takes stays 0 and the program fails by name
  # (exit 1). The hook-only control scans the same site without changing it:
  # a drained run is taken again and every kept string remains intact.
  TAKE_DRAINED='/^  def self\.partition_take\(table : Pointer\(UInt64\), index : Int32\) : UInt64$/ { in_take = 1; takes++ } in_take && /^      drained = pop_listed\(index, PC_DRAIN\)$/ { sites++; print "      drained = 0_u64"; next } in_take && /^  end$/ { in_take = 0 } { print } END { if (takes != 1 || sites != 1) exit 3 }'
  EXPECT_FIXED='FAIL: drain: no parked run was taken again from a drained list' copy "a partition takes drained runs" c1 1 "$TAKE_DRAINED"
  TAKE_SITE='/^  def self\.partition_take\(table : Pointer\(UInt64\), index : Int32\) : UInt64$/ { in_take = 1; takes++ } in_take && /^      drained = pop_listed\(index, PC_DRAIN\)$/ { sites++ } in_take && /^  end$/ { in_take = 0 } { print } END { if (takes != 1 || sites != 1) exit 3 }'
  EXPECT_OUT='drain: 35712 kept strings intact' copy "a partition takes drained runs (hook only)" c1ctl 0 "$TAKE_SITE"
  keyed "the global sweep's relist, deleted (c2)" c2 1 park "FAIL: drain: the global sweep left the run the program parked on no drain list" "-Dheap_partitions --release -Dkeyed_force" "$PARK_BROKEN"
  keyed "the relist, kept and recorded (hook only)" relisted 0 park "drain: the global sweep put the run the program parked back on its class's drain list" "-Dheap_partitions --release -Dkeyed_force" "$PARK_WITNESS"
  # c3 (adopt_drained's publishing write, `adopt` in heap_drain.iyi): the mutant
  # loses the published mark of that one write, so the taker's own local
  # collection is the first check that sees the chunk, and it names it (exit 86).
  # The hook-only control runs the same scan with the publishing write left as it is.
  ADOPT_LOSE='/^  def self\.adopt_drained\(/ { in_adopt = 1; adopts++ } in_adopt && /^          write8\(own, OWN_PUB\)$/ { sites++; print "          write8(own, 0_u64)"; next } in_adopt && /^  end$/ { in_adopt = 0 } { print } END { if (adopts != 1 || sites != 1) exit 3 }'
  EXPECT_ERR='  a slot names a LOCAL chunk its local mark left unmarked, about to be freed' copy "a taken run's published mark lost" c3 86 "$ADOPT_LOSE" "-Dheap_partitions -Dheap_verify" adopt
  ADOPT_SITE='/^  def self\.adopt_drained\(/ { in_adopt = 1; adopts++ } in_adopt && /^          write8\(own, OWN_PUB\)$/ { sites++ } in_adopt && /^  end$/ { in_adopt = 0 } { print } END { if (adopts != 1 || sites != 1) exit 3 }'
  EXPECT_OUT="adopt: a unit's first allocation took a run its dead predecessor published, and the local collection left the published string intact" \
    copy "a taken run's published mark kept (hook only)" c3ctl 0 "$ADOPT_SITE" "-Dheap_partitions -Dheap_verify" adopt
  # c3own (the taker's own byte, `adopt_taker`): the same loss with the verifier's
  # local check removed, so only the taker's own read of the mark can see it, and
  # that is a failure (exit 1). The hook-only control removes the check alone and
  # keeps the mark, so it must pass.
  CHECK_SILENCE='/^  def self\.local_collect_in\(/ { in_local = 1; locals++ } in_local && /^    [{]% if flag\?\(:heap_verify\) %[}] return false unless IyiHeapVerify\.check\(record, id, parity, running\) [{]% end %[}]$/ { silenced++; next } in_local && /^  end$/ { in_local = 0 } { print } END { if (locals != 1 || silenced != 1) exit 3 }'
  OWN_SILENT='/^  def self\.adopt_drained\(/ { in_adopt = 1; adopts++ } in_adopt && /^          write8\(own, OWN_PUB\)$/ { sites++; print "          write8(own, 0_u64)"; next } in_adopt && /^  end$/ { in_adopt = 0 } /^  def self\.local_collect_in\(/ { in_local = 1; locals++ } in_local && /^    [{]% if flag\?\(:heap_verify\) %[}] return false unless IyiHeapVerify\.check\(record, id, parity, running\) [{]% end %[}]$/ { silenced++; next } in_local && /^  end$/ { in_local = 0 } { print } END { if (adopts != 1 || sites != 1 || locals != 1 || silenced != 1) exit 3 }'
  EXPECT_FIXED="FAIL: adopt: the published string is LOCAL after the taker's local collection" copy "a taken run's published mark lost, the verifier's local check removed (c3own)" c3own 1 "$OWN_SILENT" "-Dheap_partitions -Dheap_verify" adopt
  EXPECT_OUT="adopt: a unit's first allocation took a run its dead predecessor published, and the local collection left the published string intact" \
    copy "a taken run's published mark kept, the verifier's local check removed (hook only)" c3ownctl 0 "$CHECK_SILENCE" "-Dheap_partitions -Dheap_verify" adopt
  keyed "an idle worker wakes for the warm pool (c4)" c4 1 warm "FAIL: idle_wait_ms left a worker's wait unbounded with a pooled run held warm and no partition pending" "-Dheap_partitions --release -Dkeyed_force" "$WARM_BROKEN"
  keyed "the warm-pool cap, kept (hook only)" warm 0 warm "idle: idle_wait_ms cut a worker's unbounded wait to the pool's turn with a pooled run held warm and no partition pending" "-Dheap_partitions --release -Dkeyed_force"
  keyed "a cooled run's pages go back (c5)" c5 1 cool "FAIL: idle: the run the program put on a release list reached the cold list with its page unreleased: the release call did not run" "-Dheap_partitions --release -Dkeyed_force" "$COOL_SITE" "$COOL_BROKEN"
  keyed "a cooled run's release is recorded (hook only)" cool 0 cool "idle: the run the program put on a release list reached the cold list with its page reading zero" "-Dheap_partitions --release -Dkeyed_force" "$COOL_SITE" "$COOL_WITNESS"
  marked "a unit holds beneath an open mark" held 0
  marked "a partition holds under a mark" c6 1 "$C6_DELETE"
  # c7, the walk claim (claim mode, `claim` in heap_drain.iyi). The first helper
  # slice's claim is the staged arena: `claim.iyi`'s hooks reserve it from every
  # other claim (`claim_class`, `partition_sweep_for`) until that slice's tail has run:
  # its release and arena_done, under the class lock. The mutant lets the staged claim
  # go after the walk, under that lock, and checks it before the lock is let go. The
  # readers of the claim word that could run in between all take that lock (`quiet`,
  # `free_unswept`, `idle_batches`, `next_slab`, `take_run`); `release_arena` cannot run
  # then, because a collection waits for the sweep round to close first.
  #   c7        the check fails (exit 86), and its report names the arena that the
  #             release line named: the staged slice.
  #   c7 hook   the same hooks without the release: the staged slice's tail runs and sets
  #             the done word (exit 0), and the verifier reports nothing.
  #   c7skip    the release kept under the class lock, the staged check skipped: the lock
  #             and the reservation hold until the slice's tail has run, so nothing can
  #             observe the release, and no slice reports (exit 0).
  #   c7 count  the same hooks with the staged slice's tail never setting the done word:
  #             the claim wait can end only at its completion watchdog (exit 76).
  cat >"$WORK/claim.iyi" <<'IYI'
      # copy only (bench/heap_drain.sh's c7): the first helper's claim is the staged
      # arena. Another claim of it, by a helper (`claim_class`) or by an allocating
      # thread (`partition_sweep_for`), is refused until that slice's tail has run: its
      # release and arena_done, under the class's lock. The mutant lets the staged claim
      # go after its walk, under that lock, and checks it before the lock is let go.
      @[UnsafeReach("the staged arena's address is set once, by the first helper's claim")]
      @@forced_staged : UInt64 = 0_u64
      @[UnsafeReach("nonzero while the staged arena is reserved, cleared at the staged slice's tail")]
      @@forced_held : UInt64 = 0_u64
      @[UnsafeReach("set once, by the staged slice at its tail, after its arena_done")]
      @@forced_done : UInt64 = 0_u64

      def self.forced_claim_taken(arena : UInt64) : Nil
        if Pointer(Atomic(UInt64)).new(pointerof(@@forced_staged).address).value.compare_and_set(0_u64, arena)[1]
          Pointer(Atomic(UInt64)).new(pointerof(@@forced_held).address).value.set(1_u64)
        end
      end

      def self.forced_reserved?(arena : UInt64) : Bool
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_held).address).value.get != 0_u64 && arena == Pointer(Atomic(UInt64)).new(pointerof(@@forced_staged).address).value.get
      end

      def self.forced_slice_checked(arena : UInt64) : Nil
        return unless arena == Pointer(Atomic(UInt64)).new(pointerof(@@forced_staged).address).value.get
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_held).address).value.set(0_u64)
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.set(1_u64)
      end

      # copy only (bench/heap_drain.sh's c7): the staged slice's release, named. The
      # line is written before the release, so the verifier's report on the same
      # claim, which the check after it makes, names the same arena.
      def self.forced_release_staged(arena : UInt64, epoch : UInt64) : Nil
        IyiHeapVerify.say("  claim: the staged slice at ")
        IyiHeapVerify.say_hex(arena)
        IyiHeapVerify.say(" let its walk claim go before its check\n")
        release_claim(arena, epoch)
      end

      def self.forced_staged_arena : UInt64
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_staged).address).value.get
      end

      def self.forced_staged_done? : Bool
        Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.get != 0_u64
      end

IYI
  export CLAIM_INS="$WORK/claim.iyi"
  # The awk programs. Each rule counts its sites inside its scope: a method (`in_helper`,
  # `in_class`), or, inside sweep_one_helper, its partition arm (`in_arm`, from the
  # `{% if flag?(:heap_partitions) %}` line to the `{% else %}` line). Each program
  # requires exactly one site of each rule it uses (its END), so a missing or a
  # duplicate site in scope exits 3 and the copy is not built. A site outside a scope
  # is not counted, which the awk control below checks.
  CLAIM_METHODS='/^      (@\[Effect\([^)]*\)\]; )?def self\.helper_main\(seen : UInt64\) : Nil$/ { declarations++; methods = 0; while ((getline line < ENVIRON["CLAIM_INS"]) > 0) { print line; methods++ }; if (methods == 0) exit 3; print "" }'
  CLAIM_CLASS='/^      def self\.claim_class\(index : Int32, who : Int32\) : UInt64$/ { in_class = 1; classes++ } in_class && /^          if sweep_left\?\(arena, epoch\)$/ { reserved++; print "          if sweep_left?(arena, epoch) && !forced_reserved?(arena)"; next } in_class && /^      end$/ { in_class = 0 }'
  CLAIM_TAKEN='/^        def self\.sweep_one_helper : Bool$/ { in_helper = 1; helpers++ } in_helper && /^            pool_word\(POOL_SWEEPERS\)\.value\.add\(1_u64\) if arena > 2_u64$/ { taken++; print; print "            forced_claim_taken(arena) if arena > 2_u64"; next } in_helper && /^        end$/ { in_helper = 0 }'
  CLAIM_ARM='in_helper && /^          [{]% if flag\?\(:heap_partitions\) %[}]$/ { in_arm = 1; arms++ } in_helper && in_arm && /^          [{]% else %[}]$/ { in_arm = 0; closes++ }'
  CLAIM_STAGED='in_helper && in_arm && /^            [{]% if flag\?\(:heap_verify\) %[}] IyiHeapVerify\.check_claimed\(arena, epoch\) [{]% end %[}]$/ { staged++; print "            if forced_reserved?(arena)"; print "              IyiHeap.class_lock(index)"; print "              forced_release_staged(arena, epoch)"; print "              {% if flag?(:heap_verify) %} IyiHeapVerify.check_claimed(arena, epoch) {% end %}"; print "              IyiHeap.class_unlock(index)"; print "            end" }'
  CLAIM_STAGED_HELD='in_helper && in_arm && /^            [{]% if flag\?\(:heap_verify\) %[}] IyiHeapVerify\.check_claimed\(arena, epoch\) [{]% end %[}]$/ { staged++; print "            if forced_reserved?(arena)"; print "              IyiHeap.class_lock(index)"; print "              forced_release_staged(arena, epoch)"; print "            end" }'
  CLAIM_SKIP_CHECK='in_helper && in_arm && /^            [{]% if flag\?\(:heap_verify\) %[}] IyiHeapVerify\.check_claimed\(arena, epoch\) [{]% end %[}]$/ { skipped++; print "            {% if flag?(:heap_verify) %}"; print "            unless forced_reserved?(arena)"; print "              IyiHeapVerify.check_claimed(arena, epoch)"; print "            end"; print "            {% end %}"; next }'
  CLAIM_SKIP_LOCK='in_helper && in_arm && /^            IyiHeap\.class_lock\(index\)$/ { locked++; print "            unless forced_reserved?(arena)"; print "              IyiHeap.class_lock(index)"; print "            end"; next }'
  CLAIM_DONE='in_helper && in_arm && /^            arena_done\(arena, epoch\)$/ { cleared++; print; print "            forced_slice_checked(arena)"; next }'
  CLAIM_PARTITION='/^  def self\.partition_sweep_for\(record : UInt64, index : Int32\) : UInt64$/ { in_part = 1; parts++ } in_part && /^        if IyiHeap\.partition_arena\?\(arena\) && sweep_left\?\(arena, epoch\) && IyiHeap\.read64\(arena \+ IyiHeap::OFF_SWEEPING\) != epoch$/ { reserved_part++; print "        if IyiHeap.partition_arena?(arena) && sweep_left?(arena, epoch) && IyiHeap.read64(arena + IyiHeap::OFF_SWEEPING) != epoch && !IyiMark.forced_reserved?(arena)"; next } in_part && /^  end$/ { in_part = 0 }'
  PRELUDE_CONTROL="$CLAIM_METHODS $CLAIM_CLASS $CLAIM_TAKEN $CLAIM_ARM $CLAIM_DONE { print } END { if (declarations != 1 || classes != 1 || reserved != 1 || helpers != 1 || taken != 1 || arms != 1 || closes != 1 || cleared != 1) exit 3 }"
  PRELUDE_MUTANT="$CLAIM_METHODS $CLAIM_CLASS $CLAIM_TAKEN $CLAIM_ARM $CLAIM_STAGED $CLAIM_DONE { print } END { if (declarations != 1 || classes != 1 || reserved != 1 || helpers != 1 || taken != 1 || arms != 1 || closes != 1 || staged != 1 || cleared != 1) exit 3 }"
  PRELUDE_SKIP="$CLAIM_METHODS $CLAIM_CLASS $CLAIM_TAKEN $CLAIM_ARM $CLAIM_STAGED_HELD $CLAIM_SKIP_CHECK $CLAIM_SKIP_LOCK $CLAIM_DONE { print } END { if (declarations != 1 || classes != 1 || reserved != 1 || helpers != 1 || taken != 1 || arms != 1 || closes != 1 || staged != 1 || skipped != 1 || locked != 1 || cleared != 1) exit 3 }"
  PRELUDE_COUNTLESS="$CLAIM_METHODS $CLAIM_CLASS $CLAIM_TAKEN { print } END { if (declarations != 1 || classes != 1 || reserved != 1 || helpers != 1 || taken != 1) exit 3 }"
  PARTITION_RESERVE="$CLAIM_PARTITION { print } END { if (parts != 1 || reserved_part != 1) exit 3 }"
  # awk control, no copy built: the partition-arm rules count inside the arm. Each
  # program exits 0 on the source. A second arena_done or class_lock inside the arm
  # exits 3. A second arena_done in the else arm is outside the arm and is not counted.
  AWK_CONTROL="$WORK/awk-control"
  mkdir -p "$AWK_CONTROL"
  AWK_STATE='/^        def self\.sweep_one_helper : Bool$/ { h = 1 } h && /^          [{]% if flag\?\(:heap_partitions\) %[}]$/ { arm = 1 } h && arm && /^          [{]% else %[}]$/ { arm = 0; alt = 1 } /^        end$/ { h = 0; alt = 0 } { print }'
  awk "$AWK_STATE h && arm && !d && /^            arena_done\(arena, epoch\)$/ { print; d = 1 }" "$REPO/src/iyi/prelude.iyi" > "$AWK_CONTROL/arm-arena.iyi"
  awk "$AWK_STATE h && alt && !d && /^            arena_done\(arena, epoch\)$/ { print; d = 1 }" "$REPO/src/iyi/prelude.iyi" > "$AWK_CONTROL/else-arena.iyi"
  awk "$AWK_STATE h && arm && !d && /^            IyiHeap\.class_lock\(index\)$/ { print; d = 1 }" "$REPO/src/iyi/prelude.iyi" > "$AWK_CONTROL/arm-lock.iyi"
  awk_expect() {
    awk "$3" "$4" >/dev/null 2>&1
    local code=$?
    if [ "$code" -ne "$1" ]; then
      echo "  awk control: missed: $2 exited $code, wanted $1"
      status=1
    fi
  }
  ARENA_DONE_ONCE="$CLAIM_TAKEN $CLAIM_ARM $CLAIM_DONE { print } END { if (cleared != 1) exit 3 }"
  LOCK_ONCE="$CLAIM_TAKEN $CLAIM_ARM $CLAIM_SKIP_LOCK { print } END { if (locked != 1) exit 3 }"
  awk_expect 0 "the source's arm arena_done" "$ARENA_DONE_ONCE" "$REPO/src/iyi/prelude.iyi"
  awk_expect 3 "a second arena_done in the arm" "$ARENA_DONE_ONCE" "$AWK_CONTROL/arm-arena.iyi"
  awk_expect 0 "a second arena_done in the else arm" "$ARENA_DONE_ONCE" "$AWK_CONTROL/else-arena.iyi"
  awk_expect 0 "the source's arm class_lock" "$LOCK_ONCE" "$REPO/src/iyi/prelude.iyi"
  awk_expect 3 "a second class_lock in the arm" "$LOCK_ONCE" "$AWK_CONTROL/arm-lock.iyi"
  [ "$status" -eq 0 ] && echo "  awk control: a duplicate anchor in the partition arm exits 3, one in the else arm is not counted, the source passes"
  EXPECT_ERR='  a sweep slice ended without its walk claim: another walker, or a local sweep past `quiet_class`, could walk the slice with it' NAMED_STAGED=1 \
    COPY_FILE=prelude.iyi EXTRA_FILE=heap_partition.iyi EXTRA_AWK="$PARTITION_RESERVE" \
    copy "a helper holds its claim to its walk's end" c7 86 "$PRELUDE_MUTANT" "-Dheap_partitions -Dheap_verify -Dclaim_force" claim
  EXPECT_OUT="claim: every walk claim held to its walk's end" \
    COPY_FILE=prelude.iyi EXTRA_FILE=heap_partition.iyi EXTRA_AWK="$PARTITION_RESERVE" \
    copy "a helper's staged slice checked, not released (hook only)" c7ctl 0 "$PRELUDE_CONTROL" "-Dheap_partitions -Dheap_verify -Dclaim_force" claim
  EXPECT_OUT="claim: every walk claim held to its walk's end" \
    COPY_FILE=prelude.iyi EXTRA_FILE=heap_partition.iyi EXTRA_AWK="$PARTITION_RESERVE" \
    copy "the staged slice's check skipped, its release kept: nothing else reports (c7skip)" c7skip 0 "$PRELUDE_SKIP" "-Dheap_partitions -Dheap_verify -Dclaim_force" claim
  EXPECT_SETUP='FAIL: claim: the staged slice did not complete within the watchdog' \
    COPY_FILE=prelude.iyi EXTRA_FILE=heap_partition.iyi EXTRA_AWK="$PARTITION_RESERVE" \
    copy "a staged slice never counted complete (c7 count)" c7cnt 76 "$PRELUDE_COUNTLESS" "-Dheap_partitions -Dheap_verify -Dclaim_force" claim 1 8 120 5
  # c8, the arena directory's bounds (directory mode, `dir` in heap_drain.iyi).
  # The mutant answers every slot below DIR_SLOTS as inside, and the program asks
  # the predicate directly for slot 0, so the verdict is the predicate's answer.
  DIR_BOUND='/^  def self\.dir_outside\?\(slot : UInt64\) : Bool$/ { in_dir = 1; dirs++ } in_dir && /^    slot < @@dir_low \|\| slot > @@dir_high$/ { sites++; print "    slot >= DIR_SLOTS"; next } in_dir && /^  end$/ { in_dir = 0 } { print } END { if (dirs != 1 || sites != 1) exit 3 }'
  EXPECT_FIXED="FAIL: dir: a slot outside every arena's bounds is answered as inside" copy "the directory unread outside the bounds" c8 1 "$DIR_BOUND" "-Dheap_partitions --release" dir
  # The hook-only control runs the same scan with the predicate left unchanged.
  DIR_SITE='/^  def self\.dir_outside\?\(slot : UInt64\) : Bool$/ { in_dir = 1; dirs++ } in_dir && /^    slot < @@dir_low \|\| slot > @@dir_high$/ { sites++ } in_dir && /^  end$/ { in_dir = 0 } { print } END { if (dirs != 1 || sites != 1) exit 3 }'
  EXPECT_OUT="dir: the boundary predicate answers outside for a slot below every arena" \
    copy "the directory unread outside the bounds (hook only)" c8ctl 0 "$DIR_SITE" "-Dheap_partitions --release" dir
  hinted "a large mapping widens the bounds" c9 1 "$C9_DELETE"
  hinted "a placed large object lands outside the bounds" placed 0
fi

exit $status
