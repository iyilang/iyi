#!/usr/bin/env bash
# Exercises Stage 3 root discovery, and proves the exercise can fail.
#
#     bash bench/root_exercise.sh
#
# GC_DESIGN.md's Stage 3 names the verification: "write a test that allocates
# objects and embeds pointers in global memory, stack, and registers; verify
# that manual root discovery finds them". `bench/root_exercise.iyi` is that
# program and this runs it.
#
# Five things happen here that the program cannot do for itself.
#
# It is built without `-Dgc_iyi`, which is the only way to know that a prelude
# carrying a root scanner still compiles for a program that does not want one.
#
# Every check's line is named below, because a build that silently compiled the
# whole section out would otherwise print nothing and exit 0, which reads
# exactly like a pass.
#
# The `-Dgc_iyi` binary's undefined symbols and libraries are audited the way
# `bench/dependency_floor.sh` audits a default build's, because root discovery
# asks the platform new questions and a new question can arrive as a new
# library.
#
# The Linux paths are cross-compiled and their objects audited. Root discovery
# is the first part of this collector whose code differs by platform in more
# than a syscall number: Linux reads `/proc/self/maps` and three linker
# symbols (`__data_start`, `_end`, and `__ehdr_start` for the thread-local
# block a kernel thread lays out, which every program's trigger can start),
# darwin asks libSystem and walks a Mach header. A workstation runs one of
# them. Compiling the other, for both its architectures, is what says the
# inline assembly assembles and the symbols are the expected ones, and it
# is stated as that rather than as a run.
#
# And the two mechanisms most likely to pass for the wrong reason are removed
# from a COPY of the prelude, which is then built against and must fail. A
# check that cannot fail is not a check. The copy is why nothing in the tree is
# touched to do it.
#
# Needs `make` for bin/iyi, plus `nm` (or LLVM's `llvm-nm`), and `otool` on
# darwin, `readelf` on Linux or the MSVC toolchain's `dumpbin` on Windows.
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/floor_base.sh"

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

# A floor measured with a reader that is not installed is not measured at
# all: `nm -u` in a shell with no `nm` prints nothing, and an empty symbol
# list reads as a floor that held. The readers are resolved once here, and
# the arm that needs them says what it could not measure instead.
NM=""
command -v nm >/dev/null 2>&1 && NM=nm
# Windows has no `nm`; LLVM's reads the ELF objects the cross-compile
# arm below writes, and the runners carry it where LLVM installs itself.
if [ -z "$NM" ]; then
  for candidate in llvm-nm "/c/Program Files/LLVM/bin/llvm-nm.exe"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      NM="$candidate"
      break
    fi
  done
fi
LIBS_READER=""
for candidate in otool readelf; do
  if command -v "$candidate" >/dev/null 2>&1; then
    LIBS_READER="$candidate"
    break
  fi
done
unmeasured=0

# The same readers `bench/dependency_floor.sh` uses, for the same reason: what
# a binary itself leaves undefined and what it itself asks to have loaded.
symbols() {
  "$NM" -u "$1" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' -e 's/@.*$//' |
    awk '{ print $NF }' |
    sed -e 's/^_//' |
    grep -v '^$' |
    sort -u
}

libraries() {
  if [ "$LIBS_READER" = otool ]; then
    otool -L "$1" 2>/dev/null | sed -n '2,$p' | awk '{ print $1 }' | sed 's|.*/||' | sort -u
  else
    readelf -d "$1" 2>/dev/null |
      sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
      sed 's|.*/||' | sort -u
  fi
}

# Reports every element of $2 not matched by a prefix in $1.
unexpected() {
  local allowed="$1" found="$2" item keep ok
  for item in $found; do
    keep=no
    for ok in $allowed; do
      case "$item" in "$ok"*) keep=yes ;; esac
    done
    [ "$keep" = no ] && printf '%s\n' "$item"
  done
  return 0
}

build_and_run() {
  # $1 label, $2 output name, rest: flags
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/root_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
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

echo "== the exercise, the default allocator"
build_and_run "default" roots-gc

# Where the collector's allocator is not the default the program says so and
# exercises nothing. The arms below would then be reading an empty run, and a
# negative proof whose program has nothing to fail at reports the opposite of
# the truth, so they say what went unmeasured instead.
EXERCISED=yes
grep -q "root discovery needs the collector" "$WORK/roots-gc.out" 2>/dev/null &&
  EXERCISED=no

echo
echo "== every check reported"
if [ "$EXERCISED" = no ]; then
  echo "  the collector's allocator is not the default here, so there is nothing reported to check"
  unmeasured=$((unmeasured + 1))
else
  for check in "stack bounds:" "global range:" "stack root:" "register root:" \
               "global root:" "interior pointer:" "not a pointer:" "large walk:" "arena tail:" \
               "freed chunk:" "freed large:" "many roots:" "maps parser:" "dead helper:" \
               "all root checks passed"; do
    if ! grep -q "$check" "$WORK/roots-gc.out" 2>/dev/null; then
      echo "  MISSING: $check"
      status=1
    fi
  done
  [ "$status" -eq 0 ] && echo "  bounds, stack, register, global, interior, rejection, large walk, tail, freed, many, the maps parser and the dead helper all reported"
fi

echo
echo "== the same program, opted out with -Dgc_none"
# There is nothing to exercise without the collector's allocator and the
# program says so. What the arm proves is that a prelude carrying the root
# finder still builds and runs cleanly when the allocator it serves is
# deselected.
build_and_run "gc_none" roots-default -Dgc_none
if ! grep -q "root discovery needs the collector" "$WORK/roots-default.out" 2>/dev/null; then
  echo "  MISSING: the line saying the flag is what turns this on"
  status=1
fi

echo
echo "== the same program with optimisation on"
# A register-residency check is a check about the register allocator, so the
# build that changes register allocation is the one worth running twice. The
# register check names its own premises and fails when one is gone, so this
# run is not a formality: it is the one that would catch the ordering that
# lets the optimiser reuse the register before the scan reaches it. The
# dead-helper check is asserted only here (and only on Windows), where
# `IyiMark.collect`, always inlined, clears the dead stack from the
# program's frame and the collection's frames are all built under it.
build_and_run "release" roots-release --release
if [ "$EXERCISED" = no ]; then
  echo "  nothing was exercised here, so the optimised run is unmeasured too"
  unmeasured=$((unmeasured + 1))
elif ! grep -q "all root checks passed" "$WORK/roots-release.out" 2>/dev/null; then
  echo "  MISSING: the optimised build did not reach the end"
  status=1
fi

echo
echo "== a collection in a --release build that writes artifacts"
# The dead-stack clearing stored through a call that such a build does not
# inline, and the call's return address sat in the stretch it cleared:
# std_slice_exercise, built so, died of a memory fault at its first
# collection.
if ! "$IYI" build --release --emit-iyimod "$WORK/mods-rel" -o "$WORK/slice-rel" "$REPO/bench/std_slice_exercise.iyi" >"$WORK/slice-rel.build.log" 2>&1; then
  echo "  the --release --emit-iyimod build failed:"; sed -n '1,8p' "$WORK/slice-rel.build.log"; status=1
elif ! "$WORK/slice-rel" >"$WORK/slice-rel.out" 2>&1; then
  echo "  a --release --emit-iyimod build died: $(tail -1 "$WORK/slice-rel.out")"; status=1
else
  echo "  std_slice_exercise built --release --emit-iyimod collects and ends"
fi

echo
echo "== a helper the top level called once leaves nothing in its frame"
# An optimised build inlined `make` - one call site, which LLVM inlines
# whatever its size - into `__iyi_main`, whose frame lives as long as the
# program, and spilled the array to a slot of it nothing wrote again: the
# 4,000-array form of this kept 312 MB marked through three collections,
# where a debug build freed all of it. The compiler keeps a call the top
# level makes once out of line (codegen/call.cr, `keep_call_out_of_main`).
# Built with --release only, because only that build inlines.
cat > "$WORK/dropped.iyi" <<'IYI'
def make(count : Int32) : Int32
  a = [] of Array(Int64)
  count.times { a << Array(Int64).new(10000, 7_i64) }
  a.size
end

puts "made #{make(1000)} arrays of 80 KB"
3.times { IyiMark.collect }
puts "dropped: under 8 MB marked after three collections (#{IyiMark.bytes_marked < 8_388_608_u64})"
IYI
if [ "$EXERCISED" = no ]; then
  echo "  nothing was exercised here, so the inlined helper is unmeasured too"
  unmeasured=$((unmeasured + 1))
elif ! "$IYI" build --release -o "$WORK/dropped" "$WORK/dropped.iyi" >"$WORK/dropped.log" 2>&1; then
  echo "  build failed"
  sed -n '1,12p' "$WORK/dropped.log"
  status=1
elif "$WORK/dropped" >"$WORK/dropped.out" 2>&1 && grep -q "after three collections (true)" "$WORK/dropped.out"; then
  sed 's/^/  /' "$WORK/dropped.out"
else
  echo "  FAIL: the helper's arrays stayed marked"
  sed 's/^/    /' "$WORK/dropped.out" | tail -3
  status=1
fi

echo
echo "== what root discovery asks the machine for"
# Linux adds two undefined symbols and no library: `__data_start` and `_end`
# bound the static data, and both come from the link that is already happening,
# `_end` from the linker itself and `__data_start` from the C runtime object
# every link template adds. Reading `/proc/self/maps` costs nothing at all,
# because `openat`, `read` and `close` are raw syscalls there.
#
# darwin adds four, all libSystem's, which is the standing `write`, `mmap` and
# `munmap` already have on that platform: `pthread_self` and
# `pthread_get_stackaddr_np` for the stack base, and
# `_dyld_get_image_header` with `_dyld_get_image_vmaddr_slide` for the segment
# ranges. Apple documents libSystem as the interface and raw syscalls as not a
# stable ABI, so there is no rawer answer to reach for. The rest of the darwin
# list is every darwin program's — the poller, its clock and errno, which the
# panic path carries — plus one this program's own: `mprotect`, the guard
# page of the fiber it spawns. `bzero` was here for a day: the compiler
# zeroed every `Pointer.malloc` with an `llvm.memset` then, the aarch64 back
# end lowered one it would not inline (the 1.5 MiB object below) to a
# `bzero` call, and the prelude now defines `bzero` the way it defines
# `memset`, so a call resolves to the program's own. The stale names (`malloc`,
# `memset`, `realloc`, the file calls) are gone from the list, because an
# entry nothing uses is a check without teeth.
#
# darwin adds `close`, which is not root discovery's: the pool's growth
# brings it to every program there (`bench/thread_floor.sh` says by which
# chain), and macOS 26.6 (Apple M2 Pro, 10 cores, the user's machine)
# printed it here. This program's one task is `spawn(unit: :same)` (the fiber
# root step says why), so it starts no pool and Linux reads no
# `IYI_WORKERS`: no `environ`.
case "$(uname -s)" in
  Linux)
    allowed_symbols="$FLOOR_BASE_LINUX __data_start _end"
    if ! command -v readelf >/dev/null 2>&1; then
      echo "  readelf is required on Linux to read NEEDED entries" >&2
      exit 2
    fi
    ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    # A PE leaves nothing undefined; what it asks of the machine is the
    # DLLs it imports, read with the toolchain's own `dumpbin`, the floor
    # `bench/dependency_floor.sh` and `thread_exercise.sh` hold there.
    # Root discovery reads the stack bounds out of the TEB, the globals
    # out of the image's own section table (`GetModuleHandleA`), and
    # another thread's registers with `GetThreadContext`: kernel32's, all
    # of them, and nothing may join the C runtime.
    allowed_symbols=""
    windows_floor=yes
    ;;
  *)
    allowed_symbols="$FLOOR_BASE_DARWIN close"
    ;;
esac
allowed_libs="$FLOOR_LIBS_PROGRAM"

if [ "${windows_floor:-no}" = yes ]; then
  DUMPBIN="$(find_dumpbin || true)"
  if [ -z "$DUMPBIN" ]; then
    # The toolchain that linked these binaries carries it, so its absence
    # is a broken machine, not a platform without the reader.
    echo "  no dumpbin here, and a machine that built these binaries has the toolchain that carries it"
    status=1
  else
    for bin in roots-gc roots-release; do
      dlls="$(pe_dlls "$WORK/$bin.exe")"
      if [ -z "$dlls" ]; then
        echo "  dumpbin read no import table out of $bin"
        status=1
        continue
      fi
      extra="$(extra_dlls "$FLOOR_DLLS_RUNTIME" "$dlls")"
      if [ -n "$extra" ]; then
        echo "  $bin: root discovery links something new: $(echo $extra)"
        status=1
      else
        printf '  %-14s %s names from %s\n' "$bin" "$(pe_imports "$WORK/$bin.exe" | grep -c .)" "$(echo $dlls)"
      fi
    done
  fi
elif [ -z "$allowed_symbols" ]; then
  echo "  no floor is on record for this platform, so what root discovery asks for is unmeasured"
  unmeasured=$((unmeasured + 1))
elif [ -z "$NM" ] || [ -z "$LIBS_READER" ]; then
  echo "  no nm and no otool or readelf here, so what root discovery asks for is unmeasured"
  unmeasured=$((unmeasured + 1))
elif [ -x "$WORK/roots-gc" ]; then
  gc_syms="$(symbols "$WORK/roots-gc")"
  gc_libs="$(libraries "$WORK/roots-gc")"
  printf '  symbols   %s\n' "$(echo $gc_syms)"
  printf '  libraries %s\n' "$(echo $gc_libs)"

  extra_syms="$(unexpected "$allowed_symbols" "$(echo $gc_syms)")"
  if [ -n "$extra_syms" ]; then
    echo "  root discovery asks the machine for something new:"
    echo "$extra_syms" | sed 's/^/    /'
    echo "  Each is a dependency being taken on. If that is the decision, record it"
    echo "  here and in the commit (SPEC.md III.9)."
    status=1
  fi

  extra_libs="$(unexpected "$allowed_libs" "$(echo $gc_libs)")"
  if [ -n "$extra_libs" ]; then
    echo "  root discovery links something new:"
    echo "$extra_libs" | sed 's/^/    /'
    status=1
  fi
  [ -z "$extra_syms$extra_libs" ] && echo "  nothing beyond what is named above, and no new library"
else
  echo "  no -Dgc_iyi binary to audit"
  status=1
fi

echo
echo "== the other platform's code, compiled and audited"
# Not run. What this says is that the branch this machine does not take still
# compiles, that its inline assembly assembles for both architectures, and that
# it leaves exactly the two symbols named above.
case "$(uname -s)" in
  Linux) other_targets="x86_64-darwin aarch64-darwin" ; other_expect="" ;;
  *)     other_targets="x86_64-linux-gnu aarch64-linux-gnu" ; other_expect="__data_start __ehdr_start _end" ;;
esac
if [ -z "$NM" ]; then
  echo "  no nm here, so what these objects leave undefined is unmeasured; they still have to compile"
  unmeasured=$((unmeasured + 1))
fi
for target in $other_targets; do
  if ! "$IYI" build --cross-compile --target "$target" \
       -o "$WORK/roots-$target" "$REPO/bench/root_exercise.iyi" \
       >"$WORK/roots-$target.log" 2>&1; then
    echo "  $target: cross-compile failed"
    sed -n '1,12p' "$WORK/roots-$target.log"
    status=1
    continue
  fi
  # the object compiled, which is half of what this arm says; with no reader
  # the other half goes unsaid rather than reading as an empty symbol list.
  [ -z "$NM" ] && continue
  found="$("$NM" -u "$WORK/roots-$target.o" 2>/dev/null |
    sed -e 's/^ *//' -e 's/^U  *//' | awk '{ print $NF }' | sort -u | tr '\n' ' ')"
  printf '  %-20s undefined: %s\n' "$target" "${found:-(none)}"
  if [ -n "$other_expect" ]; then
    for want in $other_expect; do
      case " $found " in
        *" $want "*) ;;
        *) echo "  $target: expected $want among its undefined symbols"; status=1 ;;
      esac
    done
    surplus="$(unexpected "$other_expect" "$found")"
    if [ -n "$surplus" ]; then
      echo "  $target: asks for more than the linker symbols:"
      echo "$surplus" | sed 's/^/    /'
      status=1
    fi
  fi
done

echo
echo "== the checks fail when the mechanism is removed"
# Each mechanism below is removed from a copy of the prelude that is then built
# against through IYI_PATH. Nothing in the tree is modified. Each build must
# produce a program that fails, and fails at the check that names the removed
# mechanism, because a check that passes either way measures nothing.
prove_fails() {
  # $1 label, $2 directory name, $3 expected phrase, $4 the awk program
  # (which may exit non-zero to say it found nothing to change), rest: build flags
  local label="$1" dir="$2" phrase="$3" program="$4"
  shift 4
  if [ "$EXERCISED" = no ]; then
    echo "  $label: the exercise has nothing to run here, so this proof is unmeasured"
    unmeasured=$((unmeasured + 1))
    return
  fi
  mkdir -p "$WORK/$dir/iyi"
  cp "$REPO"/src/iyi/*.iyi "$WORK/$dir/iyi/"
  if ! awk "$program" "$REPO/src/iyi/prelude.iyi" > "$WORK/$dir/iyi/prelude.iyi"; then
    echo "  $label: the copy's awk found nothing in the prelude to take out"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build "$@" \
       -o "$WORK/$dir/program" "$REPO/bench/root_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so the check proves nothing"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out" 2>/dev/null; then
    echo "  $label: failed, but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# The spill is what puts the callee-saved registers where the scan can see
# them. Both architectures' blocks go, so the copy is wrong everywhere rather
# than only here.
prove_fails "no register spill" nospill "register root:" '
  /asm\("stp x19|asm\("movq %rbx/ { skip = 1 }
  skip && /"volatile"\)/          { skip = 0; next }
  skip                            { next }
                                  { print }
'

# The global range narrowed at the point it is scanned rather than the point it
# is discovered, so the exercise gets past its own bounds check and fails at
# the root itself.
prove_fails "narrowed global range" narrow "global root:" '
  { sub(/scan_range\(data_low, data_high, visit\)/,
        "scan_range(data_low, data_low + 128_u64, visit)"); print }
'

# The fiber walk removed from the root set: the address held only on a
# suspended fiber's stack goes unfound, which is exactly the freed-live
# defect the walk exists to prevent.
prove_fails "no fiber walk" nofiber "fiber root:" '
  { sub(/each_fiber_root\(visit\)/, "each_global_root(visit)"); print }
'

# The probe ignored, so the parser takes the line named `[stack]` whatever
# holds the arguments: the stack end valgrind's own stack gave, which a scan
# from the program's stack pointer ran past into unmapped memory.
prove_fails "the stack named, not held" named_stack "maps parser: the mapping holding" '
  { sub(/if probe != 0_u64$/, "if false"); print }
'

# The dead stack under a collection, not cleared at all, and cleared from
# the collection's own frame rather than its caller's - `IyiMark.collect`'s
# body out of line with the clear inside it, as it was when the stopper's
# two thread-locals (df97721d4) grew that frame from 64 to 160 bytes and
# laid its lowest word, which nothing writes, on a word still holding the
# helper's array (CI jobs 128176433783 and 128229123908). The program
# fills the kilobyte under its own frame with the helper's address first,
# so either copy keeps the 32 MB whatever word the frames' layout leaves
# unwritten: 20 runs of 20 each, built by LLVM 20.1.7 and by 23.1.1
# (Windows 11, 12 logical processors, the user's machine). The check is
# asserted in the optimised build on Windows only (bench/root_exercise.iyi
# says why), so the copies are run there.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    prove_fails "no dead-stack clear" dead_noclear "bytes the helper built were still marked" '
      /^        IyiRoots\.clear_dead_stack$/ { found = found + 1; next }
                                             { print }
      END                                    { if (found != 1) exit 3 }
    ' --release
    prove_fails "the dead stack cleared under the collection, not its caller" dead_inframe "bytes the helper built were still marked" '
      /^        IyiRoots\.clear_dead_stack$/    { found = found + 1; next }
                                                { print }
      /^      def self\.collect_cleared : Nil$/ { print "        IyiRoots.clear_dead_stack"; found = found + 1 }
      END                                       { if (found != 2) exit 3 }
    ' --release
    ;;
  *)
    echo "  the dead stack's two copies: the check is asserted in the optimised build on Windows only, so unmeasured on $(uname -s)"
    unmeasured=$((unmeasured + 1))
    ;;
esac

# The main stack's top, found after the program has spawned thousands of
# tasks: two mappings each, a stack and its guard, before the first
# collection asks where the main stack ends. Linux reads that out of
# `/proc/self/maps`, whose `[stack]` line is near the end, and read only the
# first 64 KB of it - so a program that spawned a few hundred tasks before
# its first collection died there with "no [stack] line" (now "no mapping
# ... holds the program's arguments": the line is found by the argv it
# holds).
#
# The tasks are `spawn(unit: :same)`, as a program on one worker spawns them. A
# plain spawn is parallel by default, and the pool it starts registers the
# main thread, whose line reads the stack's end then (thread.iyi), before
# the first task's stack is mapped: the one-buffer copy below found the
# stack with 3,000 tasks parked and 6,242 lines in the maps file, and
# proved nothing.
echo
echo "== the main stack is found past thousands of task stacks"
cat > "$WORK/tasks.iyi" <<'IYI'
IyiMark.auto = false
parked = Channel(Int32).new
seen = 0
group do |g|
  3000.times do
    g.spawn(unit: :same) do
      case parked.receive
      in Int32         then it
      in ChannelClosed then 0
      in Cancelled     then 0
      end
    end
  end
  g.spawn(unit: :same) do
    IyiMark.collect
    seen = 1
    parked.close
    0
  end
end
puts "tasks: 3000 parked, a collection after them, and it found the main stack (#{seen})"
IYI
many_tasks() { # many_tasks <label> [IYI_PATH]
  if ! IYI_PATH="${2:-$REPO/src}" "$IYI" build -o "$WORK/tasks-$1" "$WORK/tasks.iyi" > "$WORK/tasks-$1.log" 2>&1; then
    echo "  $1: build failed"; sed -n '1,12p' "$WORK/tasks-$1.log"; status=1; return 2
  fi
  "$WORK/tasks-$1" > "$WORK/tasks-$1.out" 2>&1
}
if many_tasks plain && grep -q "found the main stack (1)" "$WORK/tasks-plain.out"; then
  printf '  %s\n' "$(cat "$WORK/tasks-plain.out")"
else
  echo "  FAIL:"; sed 's/^/    /' "$WORK/tasks-plain.out" | tail -3; status=1
fi
case "$(uname -s)" in
  Linux)
    # The read stopped after its first buffer, as it did.
    mkdir -p "$WORK/onebuffer/iyi"
    cp "$REPO"/src/iyi/*.iyi "$WORK/onebuffer/iyi/"
    awk '{ if ($0 ~ /^            kept = filled - last$/) { print; print "            break if base == 0_u64"; next } print }' \
      "$REPO/src/iyi/prelude.iyi" > "$WORK/onebuffer/iyi/prelude.iyi"
    if cmp -s "$WORK/onebuffer/iyi/prelude.iyi" "$REPO/src/iyi/prelude.iyi"; then
      echo "  the proof's awk found nothing to change"; status=1
    else
      many_tasks onebuffer "$WORK/onebuffer${PSEP}$REPO/src"
      if grep -q "no mapping in /proc/self/maps holds" "$WORK/tasks-onebuffer.out"; then
        echo "  failure proof: a read of the first 64 KB alone dies at \"$(grep -m1 "no mapping in /proc/self/maps holds" "$WORK/tasks-onebuffer.out")\""
      else
        echo "  failure proof: the one-buffer read still found the stack, so this proves nothing"; status=1
      fi
    fi
    ;;
esac

# The stack the loader left under `main` - dyld's, or ld.so's and the C
# runtime's start - is zeroed before `__iyi_main`'s frame is laid over it
# (prelude.iyi, `main`). Every top-level local is in that frame, and a
# slot of it the program never writes was scanned with the loader's word
# in it: on macos-15 four such bytes and an `Int32` beside them made a word
# inside step 16e's 64 MB string in bench/concurrency_exercise.iyi, and
# the rendezvous check found 61 MiB kept in 25 runs of 40. A top-level
# array the program never writes is 32 KiB of that frame, over all of what
# the loader left (21,696 bytes deep on macos-15, 5,352 on Linux x86_64),
# and reads zero; the prelude without the clear leaves the loader's words
# in it. On Windows a frame of more than a page calls `__chkstk` from its
# prologue before its `sub rsp`, and that call's return address and saved
# register are the frame's top two words, the array's last two there (an
# address in `__iyi_main`'s prologue and one on the stack): the program's
# own, so the probe reads the 4,094 under them.
echo
echo "== the stack the loader left under main is zeroed"
cat > "$WORK/loader.iyi" <<'IYI'
@[Unsafe("the program reads an uninitialized top-level array through pointerof to see the words the loader left under main")]
@[NoInline]
def loader_words(words : Pointer(UInt64), count : Int32) : Int32
  found = 0
  index = 0
  while index < count
    found = found + 1 if words[index] != 0_u64
    index = index + 1
  end
  found
end

untouched = uninitialized UInt64[4096]
read = {% if flag?(:win32) %}4094{% else %}4096{% end %}
found = loader_words(pointerof(untouched).as(Pointer(UInt64)), read)
puts "loader words: #{found} of #{read} in a top-level array the program never wrote"
__iyi_exit(found == 0 ? 0 : 1)
IYI
loader_run() { # loader_run <label> <IYI_PATH> [build flags]
  local label="$1" path="$2"
  shift 2
  if ! IYI_PATH="$path" "$IYI" build "$@" -o "$WORK/loader-$label" "$WORK/loader.iyi" > "$WORK/loader-$label.log" 2>&1; then
    echo "  $label: build failed"; sed -n '1,12p' "$WORK/loader-$label.log"; status=1; return 2
  fi
  "$WORK/loader-$label" > "$WORK/loader-$label.out" 2>&1
}
for build in plain release; do
  flags=""
  [ "$build" = release ] && flags="--release"
  if loader_run "$build" "$REPO/src" $flags && grep -q '^loader words: 0 of ' "$WORK/loader-$build.out"; then
    printf '  %s: %s\n' "$build" "$(cat "$WORK/loader-$build.out")"
  else
    echo "  $build: FAIL:"; sed 's/^/    /' "$WORK/loader-$build.out" | tail -3; status=1
  fi
done
mkdir -p "$WORK/noclear/iyi"
cp "$REPO"/src/iyi/*.iyi "$WORK/noclear/iyi/"
if ! awk '/^    low = high - 65536_u64$/ { print "    low = high"; found = found + 1; next } { print } END { if (found != 1) exit 3 }' \
     "$REPO/src/iyi/prelude.iyi" > "$WORK/noclear/iyi/prelude.iyi"; then
  echo "  the proof's awk found no clear in main to take out"; status=1
else
  loader_run noclear "$WORK/noclear${PSEP}$REPO/src"
  if [ $? -eq 1 ] && grep -q '^loader words: [1-9]' "$WORK/loader-noclear.out"; then
    echo "  failure proof: without the clear, exits 1 at \"$(cat "$WORK/loader-noclear.out")\""
  else
    echo "  failure proof: without the clear the array still read zero, so this proves nothing"
    sed 's/^/    /' "$WORK/loader-noclear.out" | tail -3; status=1
  fi
fi

# The two retentions a conservative stack scan cannot avoid by itself, and
# the targeted fixes iyi has for each (GC_DESIGN.md, "Precise Stack Roots:
# Measured, and Not Taken"). In both, a 64 MB string nobody keeps any more
# is kept by a word that only looks like a pointer into it.
#
# * The loader's junk: a frame laid over the stack an earlier one left,
#   with a slot it never writes, holds that frame's word. Here the earlier
#   frame is the program's own (`play_loader`), so the word is an address
#   in the string every run; on macos-15 it was dyld's under `main`. The
#   fix is `__iyi_enter`'s: zero the stack under a frame before the frame
#   is laid over it, done here by the top level, 16 KiB under its own
#   stack pointer.
# * The clock: an integer the program does keep, live in a frame across
#   the collection, whose value falls inside the string (an integer at
#   0x49f9af3be did, on macos-15, in bench/concurrency_exercise.iyi). The
#   fix is that exercise's: a step that reads the clock runs in a `def` of
#   its own, so the number goes with that frame before anything collects.
#   Asserted in the optimised build: the debug build's frames keep a slot
#   of the `def`'s too, and kept the string in 5 runs of 5 on both
#   machines below.
#
# Each fix is asserted (the string is freed), and each case without its
# fix is the broken copy, which must keep the string: that is the scan
# being conservative, and it is the outcome precise stack maps would
# change, at which point the broken copy's assertion turns into the
# check. Measured 5 runs of 5 for each build on Linux x86_64 (12 vCPU,
# shared) and on macOS 26.6, Apple M2 Pro, 10 cores (the user's
# machine): 64,050,705 bytes kept without the fix every time, 50,696 to
# 50,712 with it. Elsewhere, where the stack clear's reach and a frame's
# layout were not measured (Windows' `__chkstk` and committed limit,
# aarch64 Linux under emulation), the step says so instead.
echo
echo "== a word that only looks like a pointer keeps 64 MB, and each fix takes it back"
cat > "$WORK/retention.iyi" <<'IYI'
@[Unsafe("the program keeps a 64 MB string's address from to_unsafe as an integer and reads uninitialized frames through pointerof, the stray words a conservative scan mistakes for pointers")]
import std/static_array
import std/gc::{GC}

# An address inside a 64 MB string nobody keeps, as an integer.
@[NoInline]
def dropped_string_word : UInt64
  s = "r" * 64000000
  s.to_unsafe.address &+ 32000000_u64
end

@[NoInline]
def kept_now : UInt64
  GC.collect
  GC.stats.bytes_kept_by_last_sweep
end

@[NoInline]
def nonzero(words : Pointer(UInt64), count : Int32) : Int32
  found = 0
  index = 0
  while index < count
    found = found + 1 if words[index] != 0_u64
    index = index + 1
  end
  found
end

@[NoInline]
def use_word(word : UInt64) : Int32
  word == 0_u64 ? 1 : 0
end

# The loader's part: a frame that leaves its words on the stack and returns.
@[NoInline]
def play_loader : Int32
  words = uninitialized UInt64[512]
  word = dropped_string_word
  index = 0
  while index < 512
    words[index] = word
    index = index + 1
  end
  nonzero(pointerof(words).as(Pointer(UInt64)), 512)
end

# The program's: a frame laid over them, with a slot it never writes, live
# across the collection.
@[NoInline]
def run_over_it : UInt64
  untouched = uninitialized UInt64[512]
  kept = kept_now
  left = nonzero(pointerof(untouched).as(Pointer(UInt64)), 512)
  puts "words left in the slot: #{left}"
  kept
end

@[NoInline]
def reading_in_a_def : Int32
  reading = dropped_string_word
  use_word(reading)
end

kept = 0_u64
{% if flag?(:case_clock) %}
  {% if flag?(:case_fixed) %}
    reading_in_a_def
    kept = kept_now
  {% else %}
    reading = dropped_string_word
    kept = kept_now
    use_word(reading)
  {% end %}
{% else %}
  play_loader
  {% if flag?(:case_fixed) %}
    high = uninitialized UInt64
    {% if flag?(:x86_64) %}
      asm("movq %rsp, $0" : "=r"(high) :: : "volatile")
    {% else %}
      asm("mov $0, sp" : "=r"(high) :: : "volatile")
    {% end %}
    low = high - 16384_u64
    while low < high
      Pointer(UInt64).new(low).value = 0_u64
      low = low + 8_u64
    end
  {% end %}
  kept = run_over_it
{% end %}
puts "kept: #{kept} bytes"
__iyi_exit(kept < 16777216_u64 ? 0 : 1)
IYI
retention_run() { # retention_run <label> [build flags]
  local label="$1"
  shift
  if ! "$IYI" build "$@" -o "$WORK/retention-$label" "$WORK/retention.iyi" > "$WORK/retention-$label.log" 2>&1; then
    echo "  $label: build failed"; sed -n '1,12p' "$WORK/retention-$label.log"; status=1; return 2
  fi
  "$WORK/retention-$label" > "$WORK/retention-$label.out" 2>&1
}
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64 | Darwin/arm64) RETENTION_MEASURED=yes ;;
  *) RETENTION_MEASURED=no ;;
esac
if [ "$EXERCISED" = no ]; then
  echo "  the collector's allocator is not the default here, so nothing is kept or freed to check"
  unmeasured=$((unmeasured + 1))
elif [ "$RETENTION_MEASURED" = no ]; then
  echo "  measured on Linux x86_64 and darwin arm64 only, so unmeasured on $(uname -s)/$(uname -m)"
  unmeasured=$((unmeasured + 1))
else
  for case_ in "loader plain" "loader release" "clock release"; do
    set -- $case_
    name="$1" flags=""
    [ "$2" = release ] && flags="--release"
    if retention_run "$name-$2-fixed" $flags "-Dcase_$name" -Dcase_fixed &&
       grep -q '^kept: ' "$WORK/retention-$name-$2-fixed.out"; then
      echo "  $name, $2, with the fix: $(grep '^kept: ' "$WORK/retention-$name-$2-fixed.out")"
    else
      echo "  $name, $2, with the fix: FAIL:"; sed 's/^/    /' "$WORK/retention-$name-$2-fixed.out" | tail -3; status=1
    fi
    retention_run "$name-$2-held" $flags "-Dcase_$name"
    if [ $? -eq 1 ] && grep -q '^kept: [0-9]\{8,\} bytes' "$WORK/retention-$name-$2-held.out"; then
      echo "  failure proof: without it the conservative scan exits 1 at \"$(grep '^kept: ' "$WORK/retention-$name-$2-held.out")\""
    else
      echo "  failure proof: without the fix the string was freed anyway, so this proves nothing"
      sed 's/^/    /' "$WORK/retention-$name-$2-held.out" | tail -3; status=1
    fi
  done
fi

echo
if [ "$status" -ne 0 ]; then
  echo "Roots: something above failed."
elif [ "$unmeasured" -eq 1 ]; then
  # A summary may not claim more than was measured: an arm with no reader,
  # no floor on record, or nothing to exercise is counted here rather than
  # folded into the pass.
  echo "Roots: what ran holds, with 1 check not measured here."
elif [ "$unmeasured" -gt 1 ]; then
  echo "Roots: what ran holds, with $unmeasured checks not measured here."
else
  echo "Roots: stack, registers and globals are all found, an interior pointer"
  echo "resolves to its base, and nothing that is not a live chunk is reported."
fi
exit $status
