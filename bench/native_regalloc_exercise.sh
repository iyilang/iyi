#!/usr/bin/env bash
# The register allocation gate (SPEC 2.2 step 4, SPEC 3.5; slice C3c). Every fixture under bench/fixtures/native_cg/
# and bench/fixtures/native_regalloc/ is compiled by the native backend twice, once per allocator (IYI_NATIVE_REGALLOC
# pin and linear), linked with cc on this machine, and run. Each run's stdout and exit status must equal those of the
# equivalent .iyi program built by the hosted compiler. Also checked: the linear allocator gives the same object bytes on
# every run, it uses no more spill slots than the reference on each fixture (both counts are printed), the driver links
# only libSystem, and mutations of the allocator are each caught.
#
#   bench/native_regalloc_exercise.sh
#
# Jobs: native-darwin runs every step. The native-linux job does not run this gate; the encoder gate covers that target.
set -u
cd "$(dirname "$0")/.." || exit 1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-regalloc.XXXXXX")
RESTORE=()
restore_all() {
  local entry file backup
  for entry in "${RESTORE[@]+"${RESTORE[@]}"}"; do
    file=${entry%%|*}
    backup=${entry#*|}
    cp "$backup" "$file"
  done
  rm -rf "$WORK"
}
trap restore_all EXIT INT TERM

failed=0
fail() { echo "FAIL: $*"; failed=1; }
. bench/lib/native_signature.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$WORK/signature-failure"

export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}

FIX_CG=bench/fixtures/native_cg
FIX_RA=bench/fixtures/native_regalloc
DRV="$WORK/native_cg"

build_driver() { ./bin/iyi build -o "$1" src/compiler/tools/native_cg.iyi >"$WORK/build.$(basename "$1").log" 2>&1; }

# ---- 1. the driver -----------------------------------------------------------------------------
echo "== 1. build the driver with the hosted compiler"
if ! build_driver "$DRV"; then
  cat "$WORK/build.native_cg.log"
  fail "the driver does not build"
  echo "== SOME REGISTER ALLOCATION CHECKS FAILED"
  exit 1
fi

# ---- 2. the linkage floor ----------------------------------------------------------------------
echo "== 2. the driver links only libSystem"
if [ "$(uname -s)" = "Darwin" ]; then
  libs=$(otool -L "$DRV" | sed -n '2,$p' | sed 's/^[[:space:]]*//; s/ (.*//')
  bad=$(printf '%s\n' "$libs" | grep -v '^/usr/lib/libSystem.B.dylib$' | grep -v '^$' || true)
  if [ -n "$bad" ]; then
    echo "$bad"
    fail "the driver links a library other than libSystem"
  else
    echo "links: $(printf '%s' "$libs" | tr '\n' ' ')"
  fi
else
  echo "not Darwin: the linkage floor is checked on the darwin job"
fi

# ---- 3. every fixture runs as the hosted compiler's program does, under both allocators -----------
# Expected output of each fixture comes from the hosted compiler's build of its twin.
echo "== 3. every fixture runs as the hosted compiler's program does, under pin and linear"
# Compiles one fixture with the given driver and allocator, links it, and runs it. Leaves the stdout and
# status in $WORK/<prefix>.out and $WORK/<prefix>.status. Returns non-zero when the native backend refuses it.
native_run() {
  local drv=$1 alloc=$2 ir=$3 prefix=$4
  IYI_NATIVE_REGALLOC=$alloc "$drv" obj "$ir" "$prefix.o" >"$prefix.obj.log" 2>&1 || return 1
  cc "$prefix.o" bench/fixtures/native_cg/rt_stub.c -o "$prefix.bin" >"$prefix.link.log" 2>&1 || return 2
  native_signature_ok "$prefix.bin" || return 3
  # A mis-allocated program may loop forever, so the run is bounded: its alarm ends it with status 142.
  perl -e 'alarm 20; exec @ARGV' "$prefix.bin" >"$prefix.out" 2>/dev/null
  echo $? >"$prefix.status"
  return 0
}

count=0
for ir in "$FIX_CG"/*.ir "$FIX_RA"/*.ir; do
  base=$(basename "$ir" .ir)
  dir=$(dirname "$ir")
  iy="$dir/$base.iyi"
  if [ ! -f "$iy" ]; then
    fail "$base.ir has no equivalent $base.iyi"
    continue
  fi
  if ! ./bin/iyi build -o "$WORK/$base.hosted" "$iy" >"$WORK/$base.hosted.log" 2>&1; then
    grep -v 'ld: warning' "$WORK/$base.hosted.log" | sed -n '1,5p'
    fail "$base: the hosted compiler does not build $base.iyi"
    continue
  fi
  "$WORK/$base.hosted" >"$WORK/expect.$base.out" 2>/dev/null
  echo $? >"$WORK/expect.$base.status"
  ok=1
  for alloc in pin linear; do
    if ! native_run "$DRV" "$alloc" "$ir" "$WORK/$base.$alloc"; then
      cat "$WORK/$base.$alloc.obj.log" 2>/dev/null
      fail "$base: the native backend refused the fixture under $alloc"
      ok=0
      continue
    fi
    if cmp -s "$WORK/$base.$alloc.out" "$WORK/expect.$base.out" && cmp -s "$WORK/$base.$alloc.status" "$WORK/expect.$base.status"; then
      :
    else
      echo "--- $alloc $base"; cat "$WORK/$base.$alloc.out"; echo "--- hosted $base"; cat "$WORK/expect.$base.out"
      fail "$base: the $alloc program differs from the hosted compiler's"
      ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    echo "$base: pin and linear equal the hosted compiler (status $(tr -d '\n' <"$WORK/expect.$base.status"))"
    count=$((count + 1))
  fi
done
[ "$count" -gt 0 ] || fail "no fixture ran"
echo "ran $count fixtures under both allocators"

# ---- 4. determinism: the linear object is the same on every run --------------------------------
echo "== 4. the linear allocator is deterministic"
for ir in "$FIX_RA"/*.ir; do
  base=$(basename "$ir" .ir)
  IYI_NATIVE_REGALLOC=linear "$DRV" obj "$ir" "$WORK/det1.$base.o" >/dev/null 2>&1
  IYI_NATIVE_REGALLOC=linear "$DRV" obj "$ir" "$WORK/det2.$base.o" >/dev/null 2>&1
  if ! cmp -s "$WORK/det1.$base.o" "$WORK/det2.$base.o"; then
    fail "$base: two linear compilations differ"
  fi
done
echo "two linear compilations of each register fixture are byte-identical"

# ---- 5. spill slots: the reference and the linear allocator, each fixture, both counts printed ---
echo "== 5. spill slots per fixture: the linear allocator uses no more than the reference"
slot_report=$(python3 - "$DRV" "$FIX_RA" <<'PY'
import os, re, subprocess, sys

drv, fixdir = sys.argv[1], sys.argv[2]
bad = []
strictly_fewer = 0
for name in sorted(os.listdir(fixdir)):
    if not name.endswith(".ir"):
        continue
    path = os.path.join(fixdir, name)
    funcs = re.findall(r"^define [^@]*@([A-Za-z0-9_]+)\(", open(path).read(), re.M)
    totals = {}
    for alloc in ["pin", "linear"]:
        total = 0
        for fn in funcs:
            env = dict(os.environ, IYI_NATIVE_REGALLOC=alloc)
            out = subprocess.run([drv, "mir", path, fn], env=env, capture_output=True, text=True)
            m = re.search(r"slots=(\d+)", out.stdout)
            total += int(m.group(1)) if m else 0
        totals[alloc] = total
    base = name[:-3]
    pin, lin = totals["pin"], totals["linear"]
    if lin < pin:
        strictly_fewer += 1
        verdict = "fewer"
    elif lin == pin:
        verdict = "NOT FEWER (equal; reason: the reference already spills nothing here)" if pin == 0 else "NOT FEWER (equal; reason: no interval fits a register it could not already reach)"
    else:
        verdict = "MORE"
        bad.append(base)
    print(f"{base}: spill slots reference={pin} linear={lin} ({verdict})")
print(f"strictly fewer on {strictly_fewer} fixtures")
if bad:
    print("MORE SPILLS: " + " ".join(bad))
    sys.exit(1)
PY
)
slot_status=$?
echo "$slot_report"
[ "$slot_status" -eq 0 ] || fail "the linear allocator spills more than the reference on a fixture"

# ---- 6. mutation proofs ------------------------------------------------------------------------
# Applies one or more textual mutations to `file`, builds the driver from the mutated source, and runs the check. A
# check returns non-zero when it detects the mutant (the output differs from the hosted compiler's, or the native
# backend refuses the fixture). The text of each mutation must occur exactly once, and the mutation must change it.
# The original file is restored afterwards, whatever happens.
mutate() {
  # mutate FILE OUT OLD NEW [OLD NEW ...]: writes the mutant to OUT, exits 2 if any text is not found exactly once.
  python3 - "$@" <<'PY'
import sys
path, out = sys.argv[1], sys.argv[2]
pairs = sys.argv[3:]
text = open(path).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    hits = text.count(old)
    if hits != 1:
        print(f"the text must occur exactly once (found {hits}): {old[:70]!r}")
        sys.exit(2)
    if old == new:
        print("PATCH CHANGED NOTHING")
        sys.exit(3)
    text = text.replace(old, new, 1)
open(out, "w").write(text)
PY
}

prove_mutation() {
  # prove_mutation NAME FILE CHECK OLD NEW [OLD NEW ...]
  local name=$1 file=$2 check=$3
  shift 3
  local backup="$WORK/backup.$RANDOM"
  cp "$file" "$backup"
  RESTORE+=("$file|$backup")
  if ! mutate "$file" "$WORK/mutated.src" "$@"; then
    fail "mutation $name: the mutation could not be applied"
    return
  fi
  cp "$WORK/mutated.src" "$file"
  local mut="$WORK/mutant.$RANDOM"
  if ! build_driver "$mut"; then
    cp "$backup" "$file"
    fail "mutation $name: the mutant does not build, so it proves nothing"
    return
  fi
  if "$check" "$mut" >/dev/null 2>&1; then
    cp "$backup" "$file"
    fail "mutation $name: NOT caught"
  else
    cp "$backup" "$file"
    echo "caught: $name"
  fi
}

# Check: every fixture under the linear allocator still equals the hosted compiler's program.
check_linear_outputs() {
  local drv=$1 ir base prefix
  for ir in "$FIX_CG"/*.ir "$FIX_RA"/*.ir; do
    base=$(basename "$ir" .ir)
    prefix="$WORK/mut.$base"
    native_run "$drv" linear "$ir" "$prefix" || return 1
    cmp -s "$prefix.out" "$WORK/expect.$base.out" || return 1
    cmp -s "$prefix.status" "$WORK/expect.$base.status" || return 1
  done
  return 0
}

# Check: the collector fixture under the linear allocator still equals the hosted compiler's program.
check_pointer_output() {
  local drv=$1 prefix="$WORK/mut.pointer_fp_call"
  native_run "$drv" linear "$FIX_RA/pointer_fp_call.ir" "$prefix" || return 1
  cmp -s "$prefix.out" "$WORK/expect.pointer_fp_call.out" || return 1
  cmp -s "$prefix.status" "$WORK/expect.pointer_fp_call.status" || return 1
  return 0
}

# Check: the pointer-flag fixture under the linear allocator still equals the hosted compiler's program.
check_pointer_flag_output() {
  local drv=$1 prefix="$WORK/mut.pointer_flag_fp"
  native_run "$drv" linear "$FIX_RA/pointer_flag_fp.ir" "$prefix" || return 1
  cmp -s "$prefix.out" "$WORK/expect.pointer_flag_fp.out" || return 1
  cmp -s "$prefix.status" "$WORK/expect.pointer_flag_fp.status" || return 1
  return 0
}

echo "== 6. mutations are each caught"
prove_mutation "linear: a register is given to an interval that overlaps an active one" \
  src/compiler/native/regalloc_linear.iyi check_linear_outputs \
  '      return reg unless held?(reg) || reserved?(reg, @starts[iv], @ends[iv])' \
  '      return reg unless reserved?(reg, @starts[iv], @ends[iv])'
prove_mutation "rewrite: a spilled operand is read without its reload" \
  src/compiler/native/regalloc_linear.iyi check_linear_outputs \
  '        reloads << slot_access(fn.isa, true, reg, fn.vreg_slot[v], fp)' \
  '        # the reload is dropped'
prove_mutation "linear: a value that crosses a call may take a caller-saved register" \
  src/compiler/native/regalloc_linear.iyi check_linear_outputs \
  '      return @callee_pool' \
  '      return @caller_pool + @callee_pool'
prove_mutation "collector: a floating-point value across a call may take an fp register, and the assertion is off" \
  src/compiler/native/regalloc_linear.iyi check_pointer_output \
  '        return [] of Int32' \
  '        return @fpr_pool' \
  '        if fp && @crossing[v] && @pointer[v]' \
  '        if false && fp && @crossing[v] && @pointer[v]'
prove_mutation "collector: a floating-point value across a call may take an fp register; the assertion catches it" \
  src/compiler/native/regalloc_linear.iyi check_pointer_output \
  '        return [] of Int32' \
  '        return @fpr_pool'
prove_mutation "collector: a flagged value may take a floating-point register across a call; the assertion catches it" \
  src/compiler/native/regalloc_linear.iyi check_pointer_flag_output \
  '      if @crossing[iv]
        return [] of Int32' \
  '      if @crossing[iv] && !@pointer[iv]
        return [] of Int32'
prove_mutation "linear: a value live into a block that starts with a call is not counted as crossing it" \
  src/compiler/native/regalloc_linear.iyi check_linear_outputs \
  '        cross = @call_prefix[@ends[v]] - @call_prefix[@starts[v]] > 0' \
  '        cross = @call_prefix[@ends[v]] - @call_prefix[@starts[v] + 1] > 0'
echo "a mutation that changes nothing is refused by the proof helper:"
[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
if mutate src/compiler/native/regalloc_linear.iyi "$WORK/noop.src" \
  'def member?(list : Array(Int32), x : Int32) : Bool' 'def member?(list : Array(Int32), x : Int32) : Bool' >/dev/null 2>&1; then
  fail "the proof helper accepted a mutation that changes nothing"
else
  echo "refused: the same text on both sides"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo "== ALL REGISTER ALLOCATION CHECKS PASSED"
  exit 0
fi
echo "== SOME REGISTER ALLOCATION CHECKS FAILED"
exit 1
