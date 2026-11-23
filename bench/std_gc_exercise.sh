#!/usr/bin/env bash
# Exercises `std/gc`: the program's window onto iyi's own collector.
#
#     bash bench/std_gc_exercise.sh
#
# Proves:
#   * bench/std_gc_exercise.iyi passes plain and --release: raw words, heap
#     pointers, stats that move with the collector, disable/enable.
#   * A build with -Dgc_none is refused at compile time with the module's
#     sentence, not with an undefined name from the missing collector.
#   * A negative size is refused by name at every allocating verb.
#   * `stats` and `is_heap_ptr` wait for the runtime lock: held by another
#     thread, each answers only after the holder lets go, on the real module.
#   * Negative proofs, each run once: copies of the module that report a
#     constant collection count, that leave the trigger on under `disable`,
#     that answer false for every heap pointer, or that free nothing each fail
#     at their named check. Copies of the runtime whose walks of `stats` and
#     `is_heap_ptr` hold at a large chunk while a second thread frees it die of
#     the memory fault on the walk's next read, after the walk's marker; the
#     same walks with the lock kept let the free wait, then pass.
#
# Exits non-zero if any check fails.
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

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/gc exercise, plain build"
build_and_run "std_gc" exercise-gc "$REPO/bench/std_gc_exercise.iyi"

echo
echo "== every gc check reported"
for check in "raw words" "heap pointers" "stats move with the collector" "disable holds the trigger" "a string built in a reused chunk ends in a NUL" "stats and is_heap_ptr wait for the runtime lock" "stats beside threads that allocate" "is_heap_ptr beside threads whose large chunks come and go" "ALL CHECKS PASSED"; do
  if ! grep -q "$check" "$WORK/exercise-gc.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  raw words, heap pointers, stats and disable/enable all reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_gc --release" exercise-gc-release "$REPO/bench/std_gc_exercise.iyi" --release >/dev/null
if grep -q "ALL CHECKS PASSED" "$WORK/exercise-gc-release.out" 2>/dev/null; then
  echo "  every check holds under --release"
else
  echo "  release: missing pass sentinel"
  status=1
fi

# ---------------------------------------------------------------------------
# The compile-time refusal under -Dgc_none
# ---------------------------------------------------------------------------

echo
echo "== a -Dgc_none build is refused with a sentence"
if "$IYI" build -Dgc_none -o "$WORK/gc-none" "$REPO/bench/std_gc_exercise.iyi" >"$WORK/gc-none.log" 2>&1; then
  echo "  the module BUILT under -Dgc_none (it should have refused)"
  status=1
elif grep -q "^Error: std/gc speaks for iyi's own collector, and -Dgc_none builds without one" "$WORK/gc-none.log"; then
  echo "  refused at compile time: $(grep -m1 '^Error: std/gc speaks' "$WORK/gc-none.log" | sed 's/^Error: //')"
else
  echo "  the build failed, but not with the module's sentence:"
  tail -5 "$WORK/gc-none.log" | sed 's/^/    /'
  status=1
fi

echo
echo "== a bare import is told how to reach the module's GC"
# `import std/gc` keeps the module's names qualified (SPEC.md R-2b), so a
# bare `GC` is the prelude's own. `GC.collect` was told "iyi's prelude has
# no `collect` on GC:Module: it is small by rule" and pointed at
# `iyi build --crystal`, with the module's `GC` one import away.
printf 'import std/gc\nGC.collect\nputs 1\n' > "$WORK/bare-import.iyi"
if "$IYI" check "$WORK/bare-import.iyi" >"$WORK/bare-import.log" 2>&1; then
  echo "  the bare import type-checked (it should have been told to import GC)"
  status=1
elif grep -qF 'Import it by name, `import std/gc::{GC}`' "$WORK/bare-import.log"; then
  echo '  told: "Import it by name, `import std/gc::{GC}`"'
else
  echo "  refused, but without the import:"
  tail -5 "$WORK/bare-import.log" | sed 's/^/    /'
  status=1
fi

# ---------------------------------------------------------------------------
# What the allocating verbs refuse
# ---------------------------------------------------------------------------

echo
echo "== a negative size is refused by name"
gc_panics_with() { # gc_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  # Each verb answers a raw pointer, so the program is marked as one that
  # handles raw memory (SPEC.md III.13); unmarked, all three were refused
  # before they ran (darwin's std shard in CI run 42472342266).
  printf '@[Unsafe("GC.malloc and GC.realloc answer raw pointers, and the program prints the address of the one it is given")]\nmodule main\n\nimport std/gc::{GC}\n\nputs (%s).address\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
gc_panics_with "malloc of -1" malloc_neg "negative size: -1" 'GC.malloc(-1)'
gc_panics_with "malloc_atomic of -8" atomic_neg "negative size: -8" 'GC.malloc_atomic(-8)'
gc_panics_with "realloc to -64" realloc_neg "negative size: -64" 'GC.realloc(GC.malloc(8), -64)'

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== proving the checks can fail when the module is broken"
# Each copy changes one file and is built against through IYI_PATH; nothing
# in the tree is touched. An awk whose anchor has gone exits 3, and the gate
# fails on it. Every proof runs once, and its one ending must be the named
# one: a failure at its check, or the fault named below. Any other ending
# fails the gate and prints the tail of the run.

prove_fails() { # prove_fails <label> <dir> <ERE for the sentence> <sed script>
  local label="$1" dir="$2" sentence="$3" script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/gc.iyi" > "$WORK/$dir/std/gc.iyi"
  if cmp -s "$REPO/src/std/gc.iyi" "$WORK/$dir/std/gc.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_gc_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 1 ] || ! grep -qE "^iyi: panic: ${sentence}\$" "$WORK/$dir/out"; then
    echo "  $label: exited $exit_code, not 1 at its check ('$sentence'):"
    tail -3 "$WORK/$dir/out" | sed 's/^/    /'
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" "$(grep -m1 -E "^iyi: panic: ${sentence}\$" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

prove_fails "collections reported as a constant" const_collections \
  'ASSERTION FAILED: churn crossed the trigger: collections 0 -> 0' \
  's/IyiMark.bytes_kept, IyiMark.collections)/IyiMark.bytes_kept, 0_u64)/'
prove_fails "disable leaves the trigger on" disable_noop \
  'ASSERTION FAILED: no collection ran while disabled \([0-9]+ -> [0-9]+\)' \
  's/IyiMark.auto = false/IyiMark.auto = true/'
prove_fails "is_heap_ptr answers false for every pointer" never_heap \
  "ASSERTION FAILED: a chunk's start is a heap pointer" \
  's/^    base != 0_u64$/    base == 18446744073709551615_u64/'
prove_fails "free does nothing" free_noop \
  'ASSERTION FAILED: a freed chunk is not' \
  's/    IyiHeap.free(pointer)/    pointer/'

# The walks a free can land in. Walked without the runtime lock, `stats` and
# `is_heap_ptr` died of a memory fault on Windows, where a chunk the walk had
# reached was unmapped under it (20 runs of 20 and 10 of 10 there). A race is not
# a proof, so each copy makes that interleaving happen on its one run. The program
# arms one large chunk and starts a second thread, the freer, which frees it. The
# walk holds at the armed chunk until the freer has acknowledged the hold:
#   * the bug copy has no lock in the walk, so the free finishes (its unmap
#     publishes it) while the walk is still held; the walk then reads the freed
#     header and faults;
#   * the control copy keeps the lock, so the free reaches the runtime lock's
#     contended path while the walk is held (the lock records it, for the armed
#     chunk's freeing thread only); the walk then reads the header and passes.
# The walk prints a marker just before that read, so a fault from anywhere else
# in the child does not count. Every hold has a 20 s limit, with its own sentence.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    death_a="iyi: the program died of a memory fault. Outside a module marked \`@[Unsafe]\`, an iyi program cannot reach memory it does not own: this program's own are bench/std_gc_exercise, std/gc, and that is the place to look. Otherwise it is a bug in iyi's own runtime or std, and ours to fix: https://github.com/iyilang/iyi/issues"
    death_b="iyi: the program died of a memory fault. Outside a module marked \`@[Unsafe]\`, an iyi program cannot reach memory it does not own: this program's own are bench/std_gc_exercise, and that is the place to look. Otherwise it is a bug in iyi's own runtime or std, and ours to fix: https://github.com/iyilang/iyi/issues"
    ;;
  *)
    death_a="iyi: the program died of a memory fault. Outside a module marked \`@[Unsafe]\`, an iyi program cannot reach memory it does not own: this program's own are bench/std_gc_exercise, std/gc, and that is the place to look; on a target without iyi's runtime it can also be the stack running out. If neither, it is a bug in iyi's own runtime or std, and ours to fix: https://github.com/iyilang/iyi/issues"
    death_b="iyi: the program died of a memory fault. Outside a module marked \`@[Unsafe]\`, an iyi program cannot reach memory it does not own: this program's own are bench/std_gc_exercise, and that is the place to look; on a target without iyi's runtime it can also be the stack running out. If neither, it is a bug in iyi's own runtime or std, and ours to fix: https://github.com/iyilang/iyi/issues"
    ;;
esac

# In the copy of the runtime's prelude: the armed chunk, the words the walk and the
# freeing thread hand each other, and the hooks on the walk and on the free. Every
# wait is on a word with its own limit and sentence. Each watchdog writes the
# sentence and exits 76 by the path IyiRoots.fatal takes, without blocking on the runtime lock: Linux uses exit_group,
# macOS uses libSystem exit, and Windows makes bounded try_lock attempts before
# TerminateProcess. A walk holding the lock cannot wait for itself on this path.
prelude_awk='
$0 == "      def self.first_arena : UInt64" {
  print "      # Copy only, for a failure proof. The walk of the large list holds at the armed"
  print "      # victim until the freeing thread has acknowledged the hold. Then the unmap of the"
  print "      # victim publishes forced_done, or, in the control copy, the runtime lock found"
  print "      # contended while the freeing thread frees the victim publishes forced_waiting."
  print "      # Each word is written by one thread and read atomically by another."
  print "      @[UnsafeReach(\"proof word written by one thread and read atomically by another\")]"
  print "      @@forced_victim : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"proof word written by one thread and read atomically by another\")]"
  print "      @@forced_started : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"proof word written by one thread and read atomically by another\")]"
  print "      @@forced_held : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"proof word written by one thread and read atomically by another\")]"
  print "      @@forced_acked : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"proof word written by one thread and read atomically by another\")]"
  print "      @@forced_done : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"proof word written by one thread and read atomically by another\")]"
  print "      @@forced_freeing : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"proof word written by one thread and read atomically by another\")]"
  print "      @@forced_waiting : UInt64 = 0_u64"
  print "      @[UnsafeReach(\"proof word written by the walking thread and read atomically by the proof\")]"
  print "      @@forced_walks : UInt64 = 0_u64"
  print ""
  print "      def self.forced_arm(victim : UInt64) : Nil"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_victim).address).value.set(victim)"
  print "      end"
  print ""
  print "      def self.forced_victim : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_victim).address).value.get"
  print "      end"
  print ""
  print "      def self.forced_walked : UInt64"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_walks).address).value.get"
  print "      end"
  print ""
  print "      def self.forced_waited? : Bool"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_waiting).address).value.get == 1_u64"
  print "      end"
  print ""
  print "      def self.forced_started_set : Nil"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_started).address).value.set(1_u64)"
  print "      end"
  print ""
  print "      def self.forced_wait_started : Nil"
  print "        forced_wait(Pointer(Atomic(UInt64)).new(pointerof(@@forced_started).address), \"FAIL: the freeing thread did not start\\n\")"
  print "      end"
  print ""
  print "      def self.forced_acked_set : Nil"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_acked).address).value.set(1_u64)"
  print "      end"
  print ""
  print "      def self.forced_wait_held : Nil"
  print "        forced_wait(Pointer(Atomic(UInt64)).new(pointerof(@@forced_held).address), \"FAIL: the walk did not reach the armed chunk\\n\")"
  print "      end"
  print ""
  print "      # A wait on a word, ended after 20 s with the sentence (which ends in a newline) and status 76."
  print "      def self.forced_wait(word : Pointer(Atomic(UInt64)), sentence : String) : Nil"
  print "        started = __iyi_monotonic_ns"
  print "        while word.value.get == 0_u64"
  print "          if __iyi_monotonic_ns - started > 20_000_000_000_i64"
  print "            __iyi_write(2, sentence.to_unsafe.as(Void*), sentence.bytesize.to_u64)"
  print "            __iyi_exit(76)"
  print "          end"
  print "          IyiThread.spin_pause"
  print "        end"
  print "      end"
  print ""
  print "      # Written straight to standard output, just before the next header read of the walk."
  print "      def self.forced_marker : Nil"
  print "        text = \"forced walk: the next header read follows\\n\""
  print "        __iyi_write(1, text.to_unsafe.as(Void*), text.bytesize.to_u64)"
  print "      end"
  print ""
  print "      def self.forced_note_walk : Nil"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_walks).address).value.add(1_u64)"
  print "        Pointer(Atomic(UInt64)).new(pointerof(@@forced_held).address).value.set(1_u64)"
  print "        forced_wait(Pointer(Atomic(UInt64)).new(pointerof(@@forced_acked).address), \"FAIL: the freeing thread did not acknowledge the hold\\n\")"
  if (mode == "bug") {
    print "        forced_wait(Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address), \"FAIL: the free did not finish while the walk was held\\n\")"
  } else {
    print "        forced_wait(Pointer(Atomic(UInt64)).new(pointerof(@@forced_waiting).address), \"FAIL: the free did not wait for the runtime lock while the walk was held\\n\")"
  }
  print "        forced_marker"
  print "      end"
  print ""
  print "      # Called by the free of the armed chunk, once the unmap of the chunk has finished."
  print "      def self.forced_note_unmap(base : UInt64) : Nil"
  print "        if base + LARGE_USER == forced_victim"
  print "          Pointer(Atomic(UInt64)).new(pointerof(@@forced_done).address).value.set(1_u64)"
  print "        end"
  print "      end"
  print ""
  print "      def self.forced_begin_free(address : UInt64) : Nil"
  print "        if address == forced_victim"
  print "          Pointer(Atomic(UInt64)).new(pointerof(@@forced_freeing).address).value.set(1_u64)"
  print "        end"
  print "      end"
  print ""
  print "      def self.forced_end_free(address : UInt64) : Nil"
  print "        if address == forced_victim"
  print "          Pointer(Atomic(UInt64)).new(pointerof(@@forced_freeing).address).value.set(0_u64)"
  print "        end"
  print "      end"
  print ""
  print "      # Called on the contended path of the runtime lock. It records the freeing thread of"
  print "      # the armed chunk only: the other threads never set the freeing word."
  print "      def self.forced_note_contended : Nil"
  print "        if Pointer(Atomic(UInt64)).new(pointerof(@@forced_freeing).address).value.get == 1_u64"
  print "          Pointer(Atomic(UInt64)).new(pointerof(@@forced_waiting).address).value.set(1_u64)"
  print "        end"
  print "      end"
  print ""
  print
  setter = 1
  next
}
index($0, "      def self.free(pointer : Void*) : Nil") == 1 { infree = 1 }
infree && $0 == "          lock" {
  print "          IyiHeap.forced_begin_free(pointer.address)"
  print
  beginfree++
  next
}
infree && $0 == "          unlock" {
  print
  print "          IyiHeap.forced_end_free(pointer.address)"
  endfree++
  next
}
infree && $0 == "      end" { infree = 0 }
$0 == "        __iyi_munmap(base, read64(base + 8))" {
  print
  print "        IyiHeap.forced_note_unmap(base)"
  unmap++
  next
}
index($0, "    until ((seen = word.value.get) & 1_u64) == 0_u64") == 1 {
  print
  print "      IyiHeap.forced_note_contended"
  lockhook++
  next
}
index($0, "      def self.containing_large(pointer : Void*) : UInt64") == 1 { inside = 1 }
inside && hook != "none" && $0 == "        while node != 0" {
  print
  print "          if node + LARGE_USER == IyiHeap.forced_victim"
  print "            IyiHeap.forced_note_walk"
  print "          end"
  inside = 0
  hooked++
  next
}
{ print }
END { if (!setter || beginfree != 1 || endfree != 1 || unmap != 1 || lockhook != 1 || (hook != "none" && hooked != 1)) exit 3 }
'

# In the copy of std/gc: the stats walk's hook, before it reads each chunk's size.
gc_awk='
/^  def self.stats : Stats$/ { active = (kind == "stats") }
/^  def self.is_heap_ptr\(pointer : Void\*\) : Bool$/ { active = (kind == "is_heap") }
active && mode == "bug" && ($0 == "    IyiHeap.lock" || $0 == "    IyiHeap.unlock") { removed++; next }
kind == "stats" && $0 == "      mapped += IyiHeap.large_mapped(large)" {
  print "      if large + IyiHeap::LARGE_USER == IyiHeap.forced_victim"
  print "        IyiHeap.forced_note_walk"
  print "      end"
  hooked = 1
}
active && $0 == "  end" { active = 0 }
{ print }
END { if ((mode == "bug" && removed != 2) || (kind == "stats" && !hooked)) exit 3 }
'

# forced_copy <dir> <stats|is_heap> <bug|control>: the copy the forced program runs against.
forced_copy() {
  local dir="$1" kind="$2" mode="$3" hook=none
  mkdir -p "$WORK/$dir/iyi" "$WORK/$dir/std"
  cp "$REPO"/src/iyi/*.iyi "$WORK/$dir/iyi/"
  if [ "$kind" = is_heap ]; then hook="$mode"; fi
  if ! awk -v hook="$hook" -v mode="$mode" "$prelude_awk" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"; then
    echo "  $dir: an anchor is gone from the runtime's prelude, so the copy was not made"
    status=1
    return 1
  fi
  if ! awk -v mode="$mode" -v kind="$kind" "$gc_awk" "$REPO/src/std/gc.iyi" > "$WORK/$dir/std/gc.iyi"; then
    echo "  $dir: an anchor is gone from std/gc, so the copy was not made"
    status=1
    return 1
  fi
  return 0
}

# The marker is the child's own line, printed just before the walk's next read of
# the armed chunk's header. A fault counts only after it, so a fault that came from
# somewhere else in the child does not pass the proof.
forced_marker='forced walk: the next header read follows'

# forced_run <label> <dir> <stats|is_heap> <bug|control>: the forced program on the
# copy, once. A bug must print the marker and then die of the fault (exit 1, the
# fault's sentence below the marker). A control must print the marker and pass.
forced_run() {
  local label="$1" dir="$2" kind="$3" mode="$4" code marked died
  IYI_PATH="$WORK/$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" \
    "$IYI" run "-D${kind}_force" "$REPO/bench/std_gc_exercise.iyi" >"$WORK/$dir.out" 2>&1
  code=$?
  marked=$(grep -nxF -- "$forced_marker" "$WORK/$dir.out" | head -n 1 | cut -d: -f1)
  died=$(grep -nxF -e "$death_a" -e "$death_b" "$WORK/$dir.out" | head -n 1 | cut -d: -f1)
  if [ "$mode" = bug ]; then
    if [ "$code" -eq 1 ] && [ -n "$marked" ] && [ -n "$died" ] && [ "$marked" -lt "$died" ]; then
      echo "  $label: the marker, then the fault's sentence, exits 1"
    else
      echo "  $label: not the marker then the fault on its one run (exit $code, marker line '$marked', fault line '$died'):"
      grep -v 'ld: warning' "$WORK/$dir.out" | tail -20 | sed 's/^/    /'
      status=1
    fi
  elif [ "$code" -eq 0 ] && [ -n "$marked" ] && grep -qxF -- "the armed chunk was walked and read whole" "$WORK/$dir.out"; then
    echo "  $label: the marker, then the walk passes on its one run"
  else
    echo "  $label: did not pass on its one run (exit $code, marker line '$marked'):"
    grep -v 'ld: warning' "$WORK/$dir.out" | tail -20 | sed 's/^/    /'
    status=1
  fi
}

forced_copy stats_walk stats bug && forced_run "stats: a walk that reads a chunk another thread frees while the walk holds it" stats_walk stats bug
forced_copy stats_hold stats control && forced_run "stats: a walk that holds the lock while another thread waits for it" stats_hold stats control
forced_copy is_heap_walk is_heap bug && forced_run "is_heap_ptr: a walk that reads a chunk another thread frees while the walk holds it" is_heap_walk is_heap bug
forced_copy is_heap_hold is_heap control && forced_run "is_heap_ptr: a walk that holds the lock while another thread waits for it" is_heap_hold is_heap control

echo
if [ "$status" -eq 0 ]; then
  echo "the std/gc exercise holds"
else
  echo "the std/gc exercise did not hold"
fi
exit $status
