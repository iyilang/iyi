#!/usr/bin/env bash
# Exercises `std/weak_ref`: `WeakRef(T)` over the collector's weak cells.
#
#     bash bench/std_weak_ref_exercise.sh
#
# Proves the exercise holds plain and --release - held targets answered,
# targets nothing holds cleared, the memory reused without a cleared
# reference coming back, dead references forgotten, literals never cleared,
# and threads reading while marks run beside them seeing nothing but nil or
# the object itself; that the other collectors keep the contract (libgc
# clears through a disappearing link, -Dgc_none never collects and never
# clears, wasm32's compiles); that `WeakRef` of a value type is refused when
# it is compiled; and that each part of the collector's side is needed: a
# broken prelude is caught at the check that names what it broke.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The patches are written in python, and windows answers `python3` with a
# store stub that prints and exits rather than running it, so the
# interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

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
# fail <reason>: every failure says what it was where it happens, and the
# verdict names each again. A failure the last lines left unnamed misled
# a reader of CI job 124704511844: the plain build's assertion was 30
# lines up, and the verdict under the proof section read as the proof's.
reasons=()
fail() {
  echo "  FAIL: $1"
  reasons+=("$1")
  status=1
}
# The first assertion or panic a run printed, to name its failure by.
why() {
  local line
  line="$(grep -m1 -E "ASSERTION FAILED|panic" "$1" 2>/dev/null | tr -d '\r' | sed 's/^ *//; s/^iyi: panic: //')"
  echo "${line:-no assertion or panic printed}"
}
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
EXERCISE="$REPO/bench/std_weak_ref_exercise.iyi"

build_and_run() { # build_and_run <label> <name> [flags...]
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
    tail -12 "$WORK/$name.build.log"
    fail "$label: build failed"
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    fail "$label: exited $exit_code at \"$(why "$WORK/$name.out")\""
    return 1
  fi
  if ! grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    fail "$label: missing pass sentinel"
    return 1
  fi
}

echo "== the std/weak_ref exercise, plain build"
build_and_run "plain" weak-plain

echo
echo "== every section reported"
phrases=("== a reference that is held" "== a reference whose target is gone" "== the memory reused" \
  "== the table forgets dead references" "== what nothing frees")
# The thread section is where the program has threads (the exercise says
# which targets), and every runner this gate trusts is one of them.
phrases+=("== threads reading while collections run")
missing=0
for phrase in "${phrases[@]}"; do
  if ! grep -q "$phrase" "$WORK/weak-plain.out" 2>/dev/null; then
    fail "missing section: $phrase"
    missing=1
  fi
done
# Its own verdict, not the gate's so far: a failure above left this
# section silent when every section was there.
[ "$missing" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" weak-release --release

echo
echo "== the other collectors"
# The contract under each: libgc clears through a disappearing link;
# -Dgc_none never collects, so nothing is cleared and nothing breaks.
cat >"$WORK/collectors.iyi" <<'IYI'
module main

import std/weak_ref::{WeakRef}

{% if flag?(:gc_boehm) %}
  lib LibCollect
    fun gcollect = GC_gcollect
  end

  def collect_now : Nil
    LibCollect.gcollect
  end
{% else %}
  def collect_now : Nil
  end
{% end %}

class Thing
  getter id : Int32

  def initialize(@id : Int32)
  end
end

def make(held : Array(Thing), refs : Array(WeakRef(Thing))) : Nil
  i = 0
  while i < 1000
    thing = Thing.new(i)
    held << thing if i.even?
    refs << WeakRef.new(thing)
    i = i + 1
  end
end

held = [] of Thing
refs = [] of WeakRef(Thing)
make(held, refs)
collect_now
collect_now
kept = 0
cleared = 0
i = 0
while i < 1000
  value = refs[i].value
  if i.even?
    kept = kept + 1 if !value.nil? && value.object_id == held[i // 2].object_id && value.id == i
  elsif value.nil?
    cleared = cleared + 1
  end
  i = i + 1
end
puts "held #{kept} cleared #{cleared}"
IYI
if ! "$IYI" build -Dgc_none -o "$WORK/none" "$WORK/collectors.iyi" >"$WORK/none.build.log" 2>&1; then
  tail -8 "$WORK/none.build.log"
  fail "-Dgc_none: build failed"
elif [ "$("$WORK/none")" != "held 500 cleared 0" ]; then
  fail "-Dgc_none: '$("$WORK/none")', where every target is kept and none cleared"
else
  echo "  -Dgc_none: 500 held targets answered, nothing cleared, as nothing is collected"
fi
if ! "$IYI" build -Dgc_boehm -o "$WORK/boehm" "$WORK/collectors.iyi" >"$WORK/boehm.build.log" 2>&1; then
  if grep -qi "cannot find -lgc\|library 'gc' not found\|lgc.*not found\|gc.lib\|bdw-gc" "$WORK/boehm.build.log"; then
    echo "  -Dgc_boehm: no libgc to link on this machine"
  else
    tail -8 "$WORK/boehm.build.log"
    fail "-Dgc_boehm: build failed"
  fi
else
  boehm="$("$WORK/boehm")"
  held_count="${boehm#held }"
  held_count="${held_count%% *}"
  cleared_count="${boehm##* }"
  if [ "$held_count" != "500" ] || [ "${cleared_count:-0}" -lt 490 ]; then
    fail "-Dgc_boehm: '$boehm', where 500 are held and the rest cleared"
  else
    echo "  -Dgc_boehm: 500 held targets answered, $cleared_count of 500 cleared through libgc's links"
  fi
  # Windows: the gc.dll the program imports is put beside it, so it starts
  # with only the system's directory on PATH. It was not: the prelude never
  # named the DLL, the program found it only on PATH, where a Crystal
  # installation put it, and without one exited 0xC0000135 (Windows 11, 12
  # logical processors, the user's machine). A copy of the prelude that does
  # not name it is refused the same way.
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      system_path="$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32"
      alone="$(PATH="$system_path" "$WORK/boehm" 2>&1)"
      if [ ! -f "$WORK/gc.dll" ]; then
        fail "-Dgc_boehm: no gc.dll beside the program, which imports it"
      elif [ "${alone#held 500 cleared }" = "$alone" ]; then
        fail "-Dgc_boehm: with only $system_path on PATH the program answered '$(echo "$alone" | head -1)'"
      else
        echo "  -Dgc_boehm: gc.dll put beside the program, which starts with only $system_path on PATH"
      fi
      mkdir -p "$WORK/nodll/iyi" "$WORK/nodll/out"
      cp -R "$REPO/src/iyi/." "$WORK/nodll/iyi/"
      if ! awk '/^    @\[Link\(dll: "gc.dll"\)\]$/ { found = 1; next } { print } END { if (!found) exit 3 }' \
           "$REPO/src/iyi/prelude.iyi" > "$WORK/nodll/iyi/prelude.iyi"; then
        fail "-Dgc_boehm: the prelude no longer names gc.dll where this proof takes it out"
      elif ! IYI_PATH="$WORK/nodll${PSEP}$REPO/src" "$IYI" build -Dgc_boehm -o "$WORK/nodll/out/boehm" "$WORK/collectors.iyi" > "$WORK/nodll.build.log" 2>&1; then
        tail -8 "$WORK/nodll.build.log"
        fail "-Dgc_boehm: the copy that does not name gc.dll did not build"
      elif [ -f "$WORK/nodll/out/gc.dll" ] || PATH="$system_path" "$WORK/nodll/out/boehm" > /dev/null 2>&1; then
        fail "-Dgc_boehm: a prelude that does not name gc.dll still left the program able to start alone"
      else
        echo "  -Dgc_boehm: a prelude that does not name gc.dll leaves none beside the program, which does not start alone"
      fi ;;
  esac
fi
# Windows' LLVM carries x86 and AArch64 only (bench/verbs_exercise.sh holds
# that refusal); Linux's and darwin's carry WebAssembly, so there a failed
# compile is a failure.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) wasm_backend=0 ;;
  *) wasm_backend=1 ;;
esac
if [ "$wasm_backend" -eq 0 ]; then
  echo "  wasm32: not built here, this compiler's LLVM has no WebAssembly back end"
elif ! "$IYI" build --no-codegen --target wasm32-wasi -o "$WORK/wasm" "$WORK/collectors.iyi" >"$WORK/wasm.build.log" 2>&1; then
  tail -8 "$WORK/wasm.build.log"
  fail "wasm32: the program does not compile"
else
  echo "  wasm32: compiles against its own collector's cells"
fi

echo
echo "== what it refuses"
printf 'module main\n\nimport std/weak_ref::{WeakRef}\n\nputs WeakRef.new(1).value\n' >"$WORK/value.iyi"
if "$IYI" build --no-codegen -o "$WORK/value" "$WORK/value.iyi" >"$WORK/value.log" 2>&1; then
  fail "WeakRef(Int32): compiled, where a value type has no lifetime to watch"
elif ! grep -q "WeakRef(Int32): a weak reference watches an object's lifetime" "$WORK/value.log"; then
  sed -n '1,8p' "$WORK/value.log" | sed 's/^/    /'
  fail "WeakRef(Int32): refused, but not by name"
else
  echo "  WeakRef(Int32): $(grep -m1 -o "a weak reference watches.*" "$WORK/value.log")"
fi

echo
echo "== proving the checks fail when the collector's side is broken"
# patch <dir> <old> <new>: a copy of the prelude's directory with one site
# of prelude.iyi changed, which must be there exactly once. The directory
# whole, because the prelude requires the files beside it.
patch() {
  mkdir -p "$WORK/$1"
  cp -R "$REPO/src/iyi" "$WORK/$1/iyi"
  SRC="$REPO/src/iyi/prelude.iyi" DST="$WORK/$1/iyi/prelude.iyi" OLD="$2" NEW="$3" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text(encoding="utf-8")
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path(os.environ["DST"]).write_text(src.replace(old, os.environ["NEW"], 1), encoding="utf-8")
PY
}

# breaks <label> <name> <old> <new> <check>: the exercise stops at the
# assertion that names <check>.
breaks() {
  local label="$1" name="$2" old="$3" new="$4" check="$5"
  if ! patch "$name" "$old" "$new"; then
    fail "$label: the patch did not apply"
    return
  fi
  if ! IYI_PATH="$WORK/$name${PSEP}$IYI_PATH" "$IYI" build -o "$WORK/$name.bin" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
    tail -5 "$WORK/$name.build.log" | sed 's/^/    /'
    fail "$label: the broken copy did not build"
    return
  fi
  "$WORK/$name.bin" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  if grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    fail "$label: the exercise PASSED on a broken collector"
  elif ! grep -qF -- "ASSERTION FAILED: $check" "$WORK/$name.out"; then
    fail "$label: exited $exit_code at \"$(why "$WORK/$name.out")\", not at \"$check\""
  else
    echo "  $label: caught at \"$check\""
  fi
}

if [ -z "$PY" ]; then
  echo "  no python on this machine, so the broken-collector proofs are unmeasured"
else
  # A cell left set answers its target's memory once the sweep has had
  # it: the free list's link is written over the object, so every one of
  # them reads as broken - the read a weak reference exists to prevent.
  breaks "a cell never zeroed, answering freed memory" never_zeroed \
    '          Pointer(UInt64).new(cell).value = 0_u64 if target != 0_u64 && !live?(target)' \
    '          nil' \
    'a target still answered is intact'
  breaks "the end of the mark never asked, answering freed memory" never_asked \
    '        IyiWeak.clear
        # Every free list dropped first' \
    '        # Every free list dropped first' \
    'a target still answered is intact'
  breaks "a cell the collector scans" scanned \
    '      cell = __iyi_malloc_atomic64(8_u64).as(Pointer(UInt64))
      cell.value = address
      register(cell.address)' \
    '      cell = __iyi_malloc64(8_u64).as(Pointer(UInt64))
      cell.value = address
      register(cell.address)' \
    'a target nothing holds is cleared by the next collection'
  breaks "a dead reference kept in the table" kept_dead \
    '        if live?(cell)
          target = Pointer(UInt64).new(cell).value' \
    '        if true
          target = Pointer(UInt64).new(cell).value' \
    'a collection forgets the references nothing holds'
  breaks "an address the heap did not hand out taken for garbage" literal \
    '        base = IyiRoots.base_of(address)
        return true if base == 0_u64' \
    '        base = IyiRoots.base_of(address)
        return false if base == 0_u64' \
    'a literal is never cleared'
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/weak_ref exercise holds"
else
  echo "the std/weak_ref exercise did not hold:"
  printf '  %s\n' "${reasons[@]}"
fi
exit $status
