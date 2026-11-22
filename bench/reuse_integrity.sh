#!/usr/bin/env bash
# A chunk the collector hands out is nobody else's while its object lives,
# and it is new: a field its constructor never set reads nil. Runs
# bench/reuse_integrity.iyi plain and optimised, three times each, and holds
# every sound run to the exact sentences it prints. Then proves each check
# catches its defect on the proof's one run, with the defect forced rather
# than left to timing: a release that zeroes a listed chunk's slot word at a
# released boundary (observed directly, read before and after the release),
# and a release that leaves a designated cold page's bytes where they were
# (the unset field is read on that page).
#
#   bash bench/reuse_integrity.sh
#
# Needs `make` first. Exits non-zero if any step fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
PSEP=":"
# A native compiler cannot read this shell's path mapping, and a patched
# prelude it cannot find is a proof that quietly stops proving.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=";"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0
DONE="reuse integrity: 60 rounds, every key spells its value, the startup constant intact"
FRESH='^reuse integrity: 6000000 fresh objects on [0-9]+ released pages taken up again, every unset field nil$'

# Every run of every sound build: the two sentences, once each.
run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/reuse_integrity.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  local again
  for again in 1 2 3; do
    "$WORK/$name" >"$WORK/$name.out" 2>&1
    local exit_code=$?
    if [ "$exit_code" -ne 0 ] || ! grep -Fxq "$DONE" "$WORK/$name.out" ||
       ! grep -Eq "$FRESH" "$WORK/$name.out"; then
      echo "  FAIL: $label, run $again, exited $exit_code:"
      sed 's/^/    /' "$WORK/$name.out" | tail -3
      status=1
      return
    fi
  done
  echo "  ok   $label, three runs:"
  sed 's/^reuse integrity: /         /' "$WORK/$name.out"
}

# Copies the runtime into $WORK/$1 and edits its prelude with each awk
# program in turn. Every step that can fail is checked: a copy or move that
# fails, or an awk program whose anchors are missing or ambiguous (it exits
# 3), prints the copy and the step, and sets the status, so no proof runs
# against an unedited or half-edited copy.
fail_step() {
  echo "  $1: $2 failed; the copy was not built"
  status=1
}

make_copy() {
  local name="$1" program
  shift
  local dir="$WORK/$name"
  if ! mkdir -p "$dir/iyi"; then
    fail_step "$name" "creating the copy directory"
    return 1
  fi
  if ! cp -R "$REPO/src/iyi/." "$dir/iyi/"; then
    fail_step "$name" "copying src/iyi"
    return 1
  fi
  if ! cp "$REPO/src/iyi/prelude.iyi" "$dir/prelude.in"; then
    fail_step "$name" "copying the prelude"
    return 1
  fi
  for program in "$@"; do
    if ! awk "$program" "$dir/prelude.in" >"$dir/prelude.out"; then
      fail_step "$name" "an awk edit of the prelude (its anchor is missing or not unique)"
      return 1
    fi
    if ! mv "$dir/prelude.out" "$dir/prelude.in"; then
      fail_step "$name" "moving an edited prelude into place"
      return 1
    fi
  done
  if ! mv "$dir/prelude.in" "$dir/iyi/prelude.iyi"; then
    fail_step "$name" "moving the prelude into the copy"
    return 1
  fi
}

# Builds the program of a copy made by make_copy. Flags follow the copy's name.
build_copy() {
  local name="$1"
  shift
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src" "$IYI" build --release "$@" \
       -o "$WORK/$name/program" "$REPO/bench/reuse_integrity.iyi" \
       >"$WORK/$name/build.log" 2>&1; then
    echo "  $name: the patched prelude did not build"
    sed -n '1,12p' "$WORK/$name/build.log"
    status=1
    return 1
  fi
}

# Shows what a copy's run printed that the proof cares about: the program's
# own sentences and its panic line, then the tail.
show_run() {
  local name="$1"
  grep -E '^iyi: panic|reuse integrity' "$WORK/$name/out" | sed 's/^/    /' | head -6
  sed 's/^/    | /' "$WORK/$name/out" | tail -3
}

# One run of a copy with its defect forced. It must end at exit 1, the
# status an uncaught raise gives, and print a line matching every regular
# expression given (each one whole line). Any other ending, a fault or a
# signal included, fails the gate.
prove_fails() {
  local name="$1"
  shift
  "$WORK/$name/program" >"$WORK/$name/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 1 ]; then
    echo "  FAIL: $name: its one run exited $exit_code, not 1 at the planted defect:"
    show_run "$name"
    status=1
    return
  fi
  local re
  for re in "$@"; do
    if ! grep -Eq "$re" "$WORK/$name/out"; then
      echo "  FAIL: $name: its one run exited 1 without a line matching $re:"
      show_run "$name"
      status=1
      return
    fi
  done
  echo "  caught on its one run: $(grep -m1 '^iyi: panic: ' "$WORK/$name/out" | sed 's/^iyi: panic: //' | cut -c1-400)"
}

# One run of a hook-only control: the copy's forced carve, without the
# defect, must pass that same single run with the sentences of a sound run,
# and print a line matching every extra regular expression given.
prove_passes() {
  local name="$1"
  shift
  "$WORK/$name/program" >"$WORK/$name/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 0 ] || ! grep -Fxq "$DONE" "$WORK/$name/out" ||
     ! grep -Eq "$FRESH" "$WORK/$name/out"; then
    echo "  FAIL: control $name exited $exit_code on its one run without the sound sentences:"
    show_run "$name"
    status=1
    return
  fi
  local re
  for re in "$@"; do
    if ! grep -Eq "$re" "$WORK/$name/out"; then
      echo "  FAIL: control $name passed without a line matching $re:"
      show_run "$name"
      status=1
      return
    fi
  done
  echo "  ok   control $name passed its one run"
}

# Every carve takes a released page: warm_pages hands out no warm room, so
# each idle run goes cold. The straddle check's observation (straddle_word,
# straddle_end) is compiled in as well, and the program reads its counts only
# under -Dstraddler_force. Each anchor must match exactly once.
WARM='
/^      IDLE_NS = 1000000000_u64$/ {
  n_idle++
  print
  print ""
  print "      # A failure proof copy only: how the straddle check counts what each release"
  print "      # zeroed, and every carve takes a released page. Atomic, so any thread may add."
  print "      @[UnsafeReach(\"counted by straddle_end from every thread that releases, then only read\")]"
  print "      @@straddle_met : UInt64 = 0_u64"
  print "      @@straddle_armed : UInt64 = 0_u64"
  print "      @@straddle_damaged : UInt64 = 0_u64"
  print ""
  print "      def self.straddle_word(straddler : UInt64, low : UInt64, cold_low : UInt64) : UInt64"
  print "        (straddler >= low && straddler + IyiHeap::OFF_INDEX + 8_u64 > cold_low) ? straddler + IyiHeap::OFF_INDEX : 0_u64"
  print "      end"
  print ""
  print "      def self.straddle_end(word : UInt64, before : UInt64) : Nil"
  print "        if word != 0_u64"
  print "          Pointer(Atomic(UInt64)).new(pointerof(@@straddle_met).address).value.add(1_u64)"
  print "          if before != 0_u64"
  print "            Pointer(Atomic(UInt64)).new(pointerof(@@straddle_armed).address).value.add(1_u64)"
  print "            if IyiHeap.read64(word) != before"
  print "              Pointer(Atomic(UInt64)).new(pointerof(@@straddle_damaged).address).value.add(1_u64)"
  print "            end"
  print "          end"
  print "        end"
  print "        nil"
  print "      end"
  print ""
  print "      def self.straddle_met : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@straddle_met).address).value.get"
  print "      end"
  print ""
  print "      def self.straddle_armed : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@straddle_armed).address).value.get"
  print "      end"
  print ""
  print "      def self.straddle_damaged : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@straddle_damaged).address).value.get"
  print "      end"
  next
}
/^      def self\.warm_pages\(chunk : UInt64, pages : UInt64\) : UInt64$/ {
  n_warm++
  print
  print "        return 0_u64"
  next
}
{ print }
END {
  if (n_idle != 1) { print "warm: the IDLE_NS anchor matched " n_idle " times, not once" > "/dev/stderr"; exit 3 }
  if (n_warm != 1) { print "warm: the warm_pages anchor matched " n_warm " times, not once" > "/dev/stderr"; exit 3 }
}
'

# The straddler's adjustment (prelude L8042) is dropped, so the release at
# L8064 covers the straddler's slot word. close_run reads the word before the
# release into its own locals and checks it after: the observation is per
# call, so threads that sweep at once cannot read each other's word.
STRADDLE='
/^ +cold_low = cold_low \+ IyiHeap::PAGE if straddler >= low && / {
  n_bump++
  print "        watch_word = IyiMark.straddle_word(straddler, low, cold_low)"
  print "        watch_before = watch_word != 0_u64 ? IyiHeap.read64(watch_word) : 0_u64"
  next
}
/^ +IyiHeap\.release_run\(cold_low, page_high - cold_low\)$/ {
  n_release++
  print
  print "          IyiMark.straddle_end(watch_word, watch_before)"
  next
}
{ print }
END {
  if (n_bump != 1) { print "straddle: the adjustment anchor matched " n_bump " times, not once" > "/dev/stderr"; exit 3 }
  if (n_release != 1) { print "straddle: the release anchor matched " n_release " times, not once" > "/dev/stderr"; exit 3 }
}
'

# The same observation with the adjustment kept: the watched word stays
# intact, and the proof's control passes.
STRADDLE_CONTROL='
/^ +cold_low = cold_low \+ IyiHeap::PAGE if straddler >= low && / {
  n_bump++
  print "        watch_word = IyiMark.straddle_word(straddler, low, cold_low)"
  print "        watch_before = watch_word != 0_u64 ? IyiHeap.read64(watch_word) : 0_u64"
  print
  next
}
/^ +IyiHeap\.release_run\(cold_low, page_high - cold_low\)$/ {
  n_release++
  print
  print "          IyiMark.straddle_end(watch_word, watch_before)"
  next
}
{ print }
END {
  if (n_bump != 1) { print "straddle control: the adjustment anchor matched " n_bump " times, not once" > "/dev/stderr"; exit 3 }
  if (n_release != 1) { print "straddle control: the release anchor matched " n_release " times, not once" > "/dev/stderr"; exit 3 }
}
'

# The release as advice again, with a designated cold page. The four platform
# edits are the advice itself: `MADV_FREE` on Linux, `MEM_RESET` on Windows,
# and no release at all on darwin, each of which leaves a page's bytes in
# place. Each edit must match exactly once. The release of the first cold
# page after the program arms the copy is skipped, so that page keeps its
# bytes by construction, whatever the kernel would do with them.
ADVICE='
/^      fun __iyi_release_pages\(address : UInt64, length : UInt64\) : Nil$/ { inside = 1; n_arm++ }
inside && /^      end$/ { inside = 0 }
inside && $0 == "        __iyi_madvise(address, length, 4_i64)" { print "        __iyi_madvise(address, length, 8_i64)"; n_madv++; next }
inside && $0 == "        LibC.VirtualFree(Pointer(Void).new(address), length, 0x4000_i32)" { print "        LibC.VirtualAlloc(Pointer(Void).new(address), length, 0x80000_i32, 4_i32)"; n_reset++; next }
inside && $0 == "        LibC.VirtualAlloc(Pointer(Void).new(address), length, 0x1000_i32, 4_i32)" { n_commit++; next }
inside && $0 == "        return if LibC.mmap(Pointer(Void).new(address), length, 3, 0x1012, -1, 0_i64).address == address" { print "        return"; n_mmap++; next }
/^      def self\.release_run\(address : UInt64, length : UInt64\) : Nil$/ {
  n_keep++
  print "      # A failure proof copy only: the cold page the first release after the arm"
  print "      # skips, and the one the program checks an unset field on."
  print "      @[UnsafeReach(\"set once by advice_arm, then by the release that follows\")]"
  print "      @@advice_state : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"the chunk size the program armed the copy for, set once by advice_arm\")]"
  print "      @@advice_chunk : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"the cold page the release skipped, set once, then only read\")]"
  print "      @@advice_page : UInt64 = 0_u64"
  print ""
  print "      def self.advice_arm(chunk : UInt64) : Nil"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@advice_chunk).address).value.set(chunk)"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@advice_state).address).value.set(1_u64)"
  print "        nil"
  print "      end"
  print ""
  print "      def self.advice_kept : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@advice_page).address).value.get"
  print "      end"
  print ""
  print "      def self.advice_release(address : UInt64, length : UInt64) : Nil"
  print "        armed = Pointer(Atomic(UInt64)).new(pointerof(@@advice_state).address).value.get == 1_u64"
  print "        same_class = IyiHeap.arena_chunk(IyiHeap.arena_of(address)) == Pointer(Atomic(UInt64)).new(pointerof(@@advice_chunk).address).value.get"
  print "        if armed && same_class && length >= PAGE && IyiHeap.arena_live(IyiHeap.arena_of(address)) != 0_u64"
  print "          Pointer(Atomic(UInt64)).new(pointerof(@@advice_page).address).value.set(address)"
  print "          Pointer(Atomic(UInt64)).new(pointerof(@@advice_state).address).value.set(2_u64)"
  print "          offset = 0_u64"
  print "          while offset < PAGE"
  print "            IyiHeap.write64(address + offset, 0x0000123456780000_u64)"
  print "            offset = offset + 8_u64"
  print "          end"
  print "          __iyi_release_pages(address + PAGE, length - PAGE) if length > PAGE"
  print "        else"
  print "          __iyi_release_pages(address, length)"
  print "        end"
  print "      end"
  print ""
  print
  next
}
$0 == "        __iyi_release_pages(address, length)" { print "        advice_release(address, length)"; n_call++; next }
{ print }
END {
  if (n_arm != 3) { print "advice: the release arms matched " n_arm " times, not 3" > "/dev/stderr"; exit 3 }
  if (n_madv != 1) { print "advice: the Linux madvise edit matched " n_madv " times, not once" > "/dev/stderr"; exit 3 }
  if (n_reset != 1) { print "advice: the Windows decommit edit matched " n_reset " times, not once" > "/dev/stderr"; exit 3 }
  if (n_commit != 1) { print "advice: the Windows recommit edit matched " n_commit " times, not once" > "/dev/stderr"; exit 3 }
  if (n_mmap != 1) { print "advice: the darwin mmap edit matched " n_mmap " times, not once" > "/dev/stderr"; exit 3 }
  if (n_keep != 1) { print "advice: the release_run anchor matched " n_keep " times, not once" > "/dev/stderr"; exit 3 }
  if (n_call != 1) { print "advice: the release call matched " n_call " times, not once" > "/dev/stderr"; exit 3 }
}
'

echo "== the exercise, the default allocator"
run_case "default" plain
run_case "release" optimised --release

# The straddler's damage, observed directly: the copy reads the slot word at
# the released boundary before and after the release, and the program names
# the verdict. The straddle line comes first, then the panic.
echo
echo "== the check fails when a release zeroes a listed chunk's slot word at a released boundary"
if make_copy straddle "$WARM" "$STRADDLE" && build_copy straddle -Dstraddler_force; then
  prove_fails straddle \
    '^reuse integrity: the straddle check met [1-9][0-9]* released boundaries, armed [1-9][0-9]* nonzero slots there, [1-9][0-9]* zeroed by a release$' \
    '^iyi: panic: reuse integrity: a release zeroed a listed chunk slot word at a released boundary, [1-9][0-9]* time\(s\)$'
fi
if make_copy straddle_control "$WARM" "$STRADDLE_CONTROL" && build_copy straddle_control -Dstraddler_force; then
  prove_passes straddle_control \
    '^reuse integrity: the straddle check met [1-9][0-9]* released boundaries, armed [1-9][0-9]* nonzero slots there, 0 zeroed by a release$'
fi

# The copy skips the release of a designated cold page. The carve's first
# chunk on that page retains the pattern and forces one stale object; later
# chunks are listed by the carve and cleared when popped. The control is
# the warm room alone, with the advice left out.
echo
echo "== the check fails when a released page keeps its bytes"
if make_copy warm_control "$WARM" && build_copy warm_control; then
  prove_passes warm_control
fi
if make_copy advice "$WARM" "$ADVICE" && build_copy advice -Dadvice_force; then
  prove_fails advice \
    '^iyi: panic: reuse integrity: [1-9][0-9]* of 6000000 fresh objects read a field their constructor never set as something other than nil, on [1-9][0-9]* released pages taken up again, [1-9][0-9]* of the stale objects on the cold page whose release the copy skipped$'
fi

echo
if [ "$status" -eq 0 ]; then
  echo "reuse integrity gate: every step held"
else
  echo "reuse integrity gate: FAILED"
fi
exit "$status"
