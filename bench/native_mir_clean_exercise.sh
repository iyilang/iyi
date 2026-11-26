#!/usr/bin/env bash
# Native MIR cleanup: deterministic objects, execution parity, structure and mutations.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
. bench/lib/host.sh || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "a functional Python interpreter is required" >&2
  exit 1
fi
if [ "$HOST_OS" = darwin ]; then
  export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"$PATH"
  export LIBRARY_PATH=${LIBRARY_PATH:-/opt/homebrew/opt/bdw-gc/lib}
fi
export IYI_PATH="$(native_path "$REPO/src")"
unset IYI_NATIVE_REGALLOC
WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-mir-clean.XXXXXX") || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
failed=0
fail() { echo "FAIL: $*"; failed=1; }
. bench/lib/native_signature.sh
. bench/lib/mutation.sh
export NATIVE_SIGNATURE_FAILURE_FILE="$WORK/signature-failure"

FIX_CG=bench/fixtures/native_cg
FIX_RA=bench/fixtures/native_regalloc
FIX_CLEAN=bench/fixtures/native_mir_clean
DRV="$WORK/native_cg$EXE"
build_driver() {
  ./bin/iyi build -o "$(native_path "$1")" "$(native_path src/compiler/tools/native_cg.iyi)" \
    >"$WORK/build.$(basename "$1").log" 2>&1
}

echo "== 1. build the native codegen driver"
if ! build_driver "$DRV"; then
  cat "$WORK/build.$(basename "$DRV").log"
  echo "SOME NATIVE MIR CLEAN CHECKS FAILED"
  exit 1
fi

echo "== 1b. exercise the MIR pass contracts"
cat >"$WORK/mir_contract.iyi" <<'IYI'
module mir_contract

import compiler/native/mir::{MFunction, MBlock, MInst, MOp, Operand, OperandKind, RegClass, AsmBody}
import compiler/native/mir_clean::{fold_result_copies, elide_fallthrough}
import compiler/native/aarch64/regs::{cond_ne, cond_eq}
import std/env::{ENV}

def ins(op : MOp) : MInst
  MInst.new(op.value.to_i32)
end

def vr(n : Int32) : Operand
  Operand.new(OperandKind::Virtual, n)
end

def require_contract(ok : Bool, message : String) : Nil
  raise "MIR contract: #{message}" unless ok
end

def copy_case(kind : Int32, enabled : Bool) : Nil
  fn = MFunction.new("copy")
  first = MBlock.new(0, "first")
  fn.blocks << first
  src = fn.new_vreg(RegClass::Gpr)
  dst = fn.new_vreg(kind == 6 ? RegClass::Fpr : RegClass::Gpr)
  extra = fn.new_vreg(RegClass::Gpr)
  fn.mark_pointer(src)
  producer = ins(kind == 5 ? MOp::InlineAsm : MOp::MovImm)
  producer.asm = AsmBody.new("", 1, 0, Hash(String, Int32).new, true) if kind == 5
  producer.defs << vr(extra) if kind == 10
  producer.defs << vr(src)
  producer.uses << vr(dst) if kind == 9
  first.insts << producer unless kind == 11
  if kind == 1
    duplicate = ins(MOp::MovImm)
    duplicate.defs << vr(src)
    first.insts << duplicate
  end
  if kind == 2 || kind == 4
    read = ins(MOp::Cmp)
    read.uses << vr(kind == 2 ? src : dst)
    first.insts << read
  end
  if kind == 3
    duplicate = ins(MOp::MovImm)
    duplicate.defs << vr(dst)
    first.insts << duplicate
  end
  target = first
  if kind == 7
    target = MBlock.new(1, "second")
    fn.blocks << target
  end
  copy = ins(MOp::Mov)
  copy.defs << vr(dst)
  if kind == 8
    copy.uses << Operand.new(OperandKind::Physical, 0)
  else
    copy.uses << vr(src)
  end
  target.insts << copy
  if kind == 12
    assembly = ins(MOp::InlineAsm)
    assembly.asm = AsmBody.new("", 0, 1, Hash(String, Int32).new, true)
    assembly.uses << vr(src)
    target.insts << assembly
  end
  if kind == 13
    chain = ins(MOp::Mov)
    chain.defs << vr(extra)
    chain.uses << vr(dst)
    target.insts << chain
  end
  expected = enabled && (kind == 0 || kind == 9 || kind == 10 || kind == 13)
  expected_count = expected ? (kind == 13 ? 2 : 1) : 0
  removed = fold_result_copies(fn)
  require_contract(removed == expected_count, "copy case #{kind} removed #{removed}")
  if expected
    slot = kind == 10 ? 1 : 0
    result = kind == 13 ? extra : dst
    require_contract(producer.defs[slot].reg == result, "copy case #{kind} did not rename its definition")
    require_contract(fn.vreg_pointer[dst], "copy case #{kind} lost the pointer flag")
    require_contract(fn.vreg_pointer[extra], "copy chain lost the pointer flag") if kind == 13
  else
    require_contract(!fn.vreg_pointer[dst], "copy case #{kind} changed the pointer flag")
  end
end

def branch_cases(enabled : Bool) : Nil
  fn = MFunction.new("branches")
  first = MBlock.new(0, "first")
  second = MBlock.new(1, "second")
  third = MBlock.new(2, "third")
  fn.blocks << first
  fn.blocks << second
  fn.blocks << third
  forward = ins(MOp::B)
  forward.target = 1
  first.insts << forward
  back = ins(MOp::B)
  back.target = 0
  second.insts << back
  removed = elide_fallthrough(fn)
  require_contract(removed == (enabled ? 1 : 0), "fallthrough count")
  require_contract(first.insts.size == (enabled ? 0 : 1), "fallthrough branch")
  require_contract(second.insts.size == 1 && second.insts[0].target == 0, "backedge was removed")

  fn = MFunction.new("inversion")
  first = MBlock.new(0, "first")
  second = MBlock.new(1, "second")
  third = MBlock.new(2, "third")
  fn.blocks << first
  fn.blocks << second
  fn.blocks << third
  cond = ins(MOp::Bcond)
  cond.cond = cond_ne
  cond.target = 1
  first.insts << cond
  branch = ins(MOp::B)
  branch.target = 2
  first.insts << branch
  removed = elide_fallthrough(fn)
  require_contract(removed == (enabled ? 1 : 0), "inversion count")
  require_contract(first.insts.size == (enabled ? 1 : 2), "inversion branch count")
  require_contract(cond.target == (enabled ? 2 : 1), "inversion target")
  require_contract(cond.cond == (enabled ? cond_eq : cond_ne), "inversion condition")
end

enabled = ENV["IYI_NATIVE_MIR_CLEAN"]? != "0"
kind = 0
while kind <= 13
  copy_case(kind, enabled)
  kind = kind + 1
end
branch_cases(enabled)
puts "MIR contract checks passed"
IYI
CONTRACT="$WORK/mir_contract$EXE"
if ./bin/iyi build -o "$(native_path "$CONTRACT")" "$(native_path "$WORK/mir_contract.iyi")" >"$WORK/contract.build.log" 2>&1; then
  for setting in 1 0; do
    if ! IYI_NATIVE_MIR_CLEAN=$setting "$CONTRACT" >"$WORK/contract.$setting.log" 2>&1; then
      cat "$WORK/contract.$setting.log"
      fail "MIR contract checks failed with cleanup=$setting"
    fi
  done
  if ! (unset IYI_NATIVE_MIR_CLEAN; "$CONTRACT") >"$WORK/contract.default.log" 2>&1; then
    cat "$WORK/contract.default.log"
    fail "MIR contract checks failed with the default switch"
  fi
  if IYI_NATIVE_MIR_CLEAN=invalid "$CONTRACT" >"$WORK/contract.invalid.log" 2>&1; then
    fail "an invalid MIR cleanup switch was accepted"
  elif ! grep -Fq 'IYI_NATIVE_MIR_CLEAN is invalid' "$WORK/contract.invalid.log"; then
    cat "$WORK/contract.invalid.log"
    fail "the invalid switch did not produce the expected refusal"
  fi
else
  cat "$WORK/contract.build.log"
  fail "MIR contract fixture did not build"
fi

# A nonzero driver exit is a refusal (1); missing input or output is invalid (2).
emit_obj() {
  local drv=$1 clean=$2 ir=$3 obj=$4 log=$5 native_ir native_obj
  [ -f "$ir" ] && [ -x "$drv" ] || return 2
  native_ir=$(native_path "$ir") || return 2
  native_obj=$(native_path "$obj") || return 2
  rm -f "$obj" || return 2
  if IYI_NATIVE_MIR_CLEAN=$clean "$drv" obj "$native_ir" "$native_obj" >"$log" 2>&1; then
    :
  else
    case $? in
      126|127) echo "driver could not be executed" >>"$log"; return 2 ;;
      *) return 1 ;;
    esac
  fi
  if [ ! -s "$obj" ]; then
    echo "driver succeeded without producing a nonempty object: $obj" >>"$log"
    return 2
  fi
}

fixture_key() {
  printf '%s.%s\n' "$(basename "$(dirname "$1")")" "$(basename "$1" .ir)"
}

# Keep the Perl alarm while distinguishing a killed process from one that
# legitimately exits 142. Return 1 for an alarm and 2 for a launch/wait error.
bounded_run() {
  local exe=$1 prefix=$2 status
  rm -f "$prefix.timeout" "$prefix.exec-error" "$prefix.done" || return 2
  perl -e '
    my ($timeout, $error, $done, $exe) = @ARGV;
    my $pid = fork();
    defined($pid) or die "fork: $!";
    if ($pid == 0) {
      alarm 20;
      exec { $exe } $exe;
      open my $fh, ">", $error or die "exec and error marker failed: $!";
      print $fh "exec failed: $!\n";
      close $fh or die "error marker: $!";
      exit 127;
    }
    my $waited = waitpid($pid, 0);
    my $status = $?;
    $waited == $pid or die "waitpid: $!";
    if (($status & 127) == 14) {
      open my $fh, ">", $timeout or die "timeout marker: $!";
      close $fh or die "timeout marker: $!";
    }
    open my $fh, ">", $done or die "completion marker: $!";
    close $fh or die "completion marker: $!";
    exit (($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$prefix.timeout" "$prefix.exec-error" "$prefix.done" "$exe" </dev/null >"$prefix.out" 2>/dev/null
  status=$?
  echo "$status" >"$prefix.status" || return 2
  [ -e "$prefix.done" ] && [ ! -e "$prefix.exec-error" ] || return 2
  [ ! -e "$prefix.timeout" ] || return 1
  return 0
}

# Link and run an emitted object on macOS arm64. Link and signature errors
# have distinct statuses so they cannot be credited as mutation detections.
run_obj() {
  local obj=$1 prefix=$2 result
  [ -s "$obj" ] || return 2
  cc "$obj" bench/fixtures/native_cg/rt_stub.c -o "$prefix.bin" >"$prefix.link.log" 2>&1 || return 3
  native_signature_ok "$prefix.bin" || return 4
  bounded_run "$prefix.bin" "$prefix"
  result=$?
  case "$result" in
    0) return 0 ;;
    1) echo "native execution timed out: $prefix"; return 5 ;;
    *) echo "native execution could not start or be observed: $prefix"; return 6 ;;
  esac
}

echo "== 2. emit both modes and check deterministic objects"
fixture_count=0
for dir in "$FIX_CG" "$FIX_RA" "$FIX_CLEAN"; do
  dir_count=0
  for ir in "$dir"/*.ir; do
    [ -f "$ir" ] || continue
    dir_count=$((dir_count + 1))
    fixture_count=$((fixture_count + 1))
    key=$(fixture_key "$ir")
    for mode in on on2 off; do
      clean=1
      [ "$mode" != off ] || clean=0
      prefix="$WORK/$key.$mode"
      if ! emit_obj "$DRV" "$clean" "$ir" "$prefix.o" "$prefix.obj.log"; then
        cat "$prefix.obj.log" 2>/dev/null || true
        fail "$key: $mode did not emit a nonempty object"
      fi
    done
    if [ -s "$WORK/$key.on.o" ] && [ -s "$WORK/$key.on2.o" ]; then
      cmp -s "$WORK/$key.on.o" "$WORK/$key.on2.o" || fail "$key: enabled objects differ"
    else
      fail "$key: cannot compare enabled objects"
    fi
  done
  [ "$dir_count" -gt 0 ] || fail "no fixtures in $dir"
done
printf 'objects: %s fixtures, two enabled objects and one disabled object each\n' "$fixture_count"

echo "== 3. compare both modes with hosted twins"
if [ "$HOST_ID" = darwin-arm64 ]; then
  for tool in cc perl file; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "required runtime tool is missing: $tool"
      echo "SOME NATIVE MIR CLEAN CHECKS FAILED"
      exit 1
    fi
  done
  for dir in "$FIX_CG" "$FIX_RA" "$FIX_CLEAN"; do
    for ir in "$dir"/*.ir; do
      [ -f "$ir" ] || continue
      key=$(fixture_key "$ir")
      iy="${ir%.ir}.iyi"
      hosted="$WORK/$key.hosted$EXE"
      if [ ! -f "$iy" ]; then
        fail "$ir has no equivalent $iy"
        continue
      fi
      if ! ./bin/iyi build -o "$(native_path "$hosted")" "$(native_path "$iy")" >"$WORK/$key.hosted.log" 2>&1; then
        cat "$WORK/$key.hosted.log"
        fail "$key: the hosted twin does not build"
        continue
      fi
      if ! bounded_run "$hosted" "$WORK/expect.$key"; then
        fail "$key: hosted execution timed out or could not be observed"
        continue
      fi
      for mode in on off; do
        prefix="$WORK/$key.$mode"
        if ! run_obj "$prefix.o" "$prefix"; then
          cat "$prefix.link.log" 2>/dev/null || true
          fail "$key: $mode object could not be linked, signed, or run"
          continue
        fi
        if ! cmp -s "$prefix.out" "$WORK/expect.$key.out" ||
           ! cmp -s "$prefix.status" "$WORK/expect.$key.status"; then
          fail "$key: $mode differs from its hosted twin"
        fi
      done
    done
  done
else
  host_limited "Darwin objects cannot be linked or executed on $HOST_ID"
fi

# The same structural predicate runs on the pristine driver and on the branch mutant.
# Status 1 means an observed MIR defect; status 2 means the predicate could not run.
cat >"$WORK/check_mir.py" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

drv, mode, *dirs = sys.argv[1:]
errors = []
defects = []
functions = 0
backedges = 0
inversions = 0

def dump(path, name, enabled):
    env = dict(os.environ, IYI_NATIVE_MIR_CLEAN=str(enabled))
    try:
        result = subprocess.run([drv, "mir", str(path), name], env=env,
                                capture_output=True, text=True)
    except OSError as exc:
        errors.append(f"{path.name} {name}: cannot run driver: {exc}")
        return None
    if result.returncode:
        errors.append(f"{path.name} {name}: driver exited {result.returncode}: {result.stderr.strip()}")
        return None
    blocks = {}
    current = None
    for line in result.stdout.splitlines():
        match = re.match(r"^block (\d+) ", line)
        if match:
            current = int(match.group(1))
            if current in blocks:
                errors.append(f"{path.name} {name}: duplicate block {current}")
                return None
            blocks[current] = []
            continue
        match = re.match(r"^  ([A-Za-z0-9_]+)/\d+f?(?: |$)", line)
        if match:
            if current is None:
                errors.append(f"{path.name} {name}: instruction outside a block")
                return None
            target = re.search(r"\btarget=(\d+)", line)
            blocks[current].append((match.group(1), int(target.group(1)) if target else None))
    if not result.stdout.startswith("function " + name + "\n") or not blocks:
        errors.append(f"{path.name} {name}: malformed MIR dump")
        return None
    return blocks

for dirname in dirs:
    directory = Path(dirname)
    paths = sorted(directory.glob("*.ir"))
    if not paths:
        errors.append(f"no IR fixtures in {directory}")
    for path in paths:
        try:
            names = re.findall(r"^define [^@\n]*@([^\s(]+)\(", path.read_text(encoding="utf-8"), re.M)
        except OSError as exc:
            errors.append(f"cannot read {path}: {exc}")
            continue
        if not names:
            errors.append(f"{path.name}: no function definitions")
        custom = directory.name == "native_mir_clean"
        for name in names:
            before = dump(path, name, 0)
            after = dump(path, name, 1)
            if before is None or after is None:
                continue
            functions += 1
            if before.keys() != after.keys():
                defects.append(f"{path.name} {name}: block list changed")
                continue
            old_count = sum(map(len, before.values()))
            new_count = sum(map(len, after.values()))
            if new_count > old_count or (custom and new_count == old_count):
                defects.append(f"{path.name} {name}: instruction count {old_count} -> {new_count}")
            if not custom:
                continue
            for number, instructions in after.items():
                for op, target in instructions:
                    if op == "B" and target == number + 1:
                        defects.append(f"{path.name} {name}: block {number} branches to its successor")
            for number, instructions in before.items():
                if not instructions or instructions[-1][0] != "B":
                    continue
                target = instructions[-1][1]
                if target is None:
                    errors.append(f"{path.name} {name}: branch without a target")
                    continue
                if target < number:
                    backedges += 1
                if target == number + 1:
                    continue
                inverted = len(instructions) > 1 and instructions[-2] == ("Bcond", number + 1)
                if inverted:
                    inversions += 1
                expected = ("Bcond" if inverted else "B", target)
                current = after[number]
                if not current or current[-1] != expected:
                    defects.append(f"{path.name} {name}: block {number} lost non-fallthrough edge to {target}")
if not functions:
    errors.append("no functions could be checked")
if mode == "custom" and (not backedges or not inversions):
    errors.append("custom fixtures must exercise a backedge and an inverted conditional")
for problem in errors:
    print("INVALID: " + problem)
for problem in defects:
    print("decisive: " + problem)
print(f"MIR functions: {functions}; backedges: {backedges}; inversions: {inversions}")
if errors:
    sys.exit(2)
if defects:
    sys.exit(1)
PY

check_mir() {
  local drv=$1 mode=$2
  if [ "$mode" = all ]; then
    "$PY" "$(native_path "$WORK/check_mir.py")" "$(native_path "$drv")" all \
      "$(native_path "$FIX_CG")" "$(native_path "$FIX_RA")" "$(native_path "$FIX_CLEAN")"
  else
    "$PY" "$(native_path "$WORK/check_mir.py")" "$(native_path "$drv")" custom "$(native_path "$FIX_CLEAN")"
  fi
}

echo "== 4. compare MIR instruction counts and fallthrough edges"
check_mir "$DRV" all || fail "the per-function MIR comparison failed"
check_mir "$DRV" custom || fail "the custom MIR edge predicate failed"

# A fixture result is a detected regression only after object emission, linking and signing succeeded.
check_fixture_output() {
  local drv=$1 ir=$2 key prefix result ext
  [ -f "$ir" ] || return 2
  key=$(fixture_key "$ir")
  prefix="$WORK/mutation.$key"
  [ -f "$WORK/expect.$key.out" ] && [ -f "$WORK/expect.$key.status" ] || return 2
  emit_obj "$drv" 1 "$ir" "$prefix.o" "$prefix.obj.log"
  result=$?
  [ "$result" -eq 0 ] || { cat "$prefix.obj.log" 2>/dev/null || true; return 2; }
  run_obj "$prefix.o" "$prefix"
  result=$?
  if [ "$result" -eq 5 ]; then
    echo "decisive: $key timed out"
    return 1
  fi
  [ "$result" -eq 0 ] || { cat "$prefix.link.log" 2>/dev/null || true; return 2; }
  for ext in out status; do
    cmp -s "$prefix.$ext" "$WORK/expect.$key.$ext"
    result=$?
    if [ "$result" -eq 1 ]; then
      echo "decisive: $key $ext differs from its hosted twin"
      return 1
    fi
    [ "$result" -eq 0 ] || return 2
  done
  return 0
}

MUTATION_INVALID="$WORK/mutation.invalid"
mutation_invalid() {
  echo "INVALID: $*"
  touch "$MUTATION_INVALID"
  return 2
}

# Every mutant is rebuilt from the patched source. Invalid setup leaves a marker as well as exit 2,
# because the older helper on this stack counts every nonzero exit as a catch.
check_mutant() {
  local kind=$1 mutant="$WORK/mutant$EXE" result structure runtime ir
  if ! build_driver "$mutant"; then
    cat "$WORK/build.$(basename "$mutant").log"
    mutation_invalid "mutant driver did not build"
    return 2
  fi
  if [ "$kind" = branch ]; then
    check_mir "$mutant" custom
    structure=$?
    [ "$structure" -ne 2 ] || { mutation_invalid "structural predicate could not run"; return 2; }
    if [ "$HOST_ID" = darwin-arm64 ]; then
      check_fixture_output "$mutant" "$FIX_CLEAN/loop.ir"
      runtime=$?
      [ "$runtime" -ne 2 ] || { mutation_invalid "branch runtime predicate could not run"; return 2; }
      [ "$structure" -eq 1 ] && [ "$runtime" -eq 1 ] && return 1
      return 0
    fi
    return "$structure"
  fi
  if [ "$kind" = invert ]; then
    check_fixture_output "$mutant" "$FIX_CLEAN/diamond.ir"
    result=$?
    [ "$result" -ne 2 ] || { mutation_invalid "inversion runtime predicate could not run"; return 2; }
    return "$result"
  fi
  for ir in "$FIX_CLEAN"/*.ir; do
    [ -f "$ir" ] || continue
    check_fixture_output "$mutant" "$ir"
    result=$?
    [ "$result" -ne 2 ] || { mutation_invalid "copy runtime predicate could not run"; return 2; }
    [ "$result" -ne 1 ] || return 1
  done
  return 0
}

prove_clean_mutation() {
  local label=$1 file=$2 old=$3 new=$4 kind=$5
  rm -f "$MUTATION_INVALID"
  if ! prove_mutation "$label" "$file" "$old" "$new" -- check_mutant "$kind"; then
    fail "mutation was not caught: $label"
  fi
  [ ! -e "$MUTATION_INVALID" ] || fail "mutation check had invalid setup: $label"
}

echo "== 5. mutation proofs"
if [ "$HOST_ID" = darwin-arm64 ]; then
  for ir in "$FIX_CLEAN"/*.ir; do
    [ -f "$ir" ] || continue
    check_fixture_output "$DRV" "$ir" || fail "pristine runtime predicate failed for $ir"
  done
  prove_clean_mutation "copy: remove a result copy without renaming its producer" \
    src/compiler/native/mir_clean.iyi \
    '              producer.defs[def_slot[s]] = dst # fold-result-rename' \
    '              producer.defs[def_slot[s]] = producer.defs[def_slot[s]] # fold-result-rename' copy
  prove_clean_mutation "condition: leave an inverted branch condition unchanged" \
    src/compiler/native/target.iyi \
    '    inst.cond = cond_invert(inst.cond) # invert-branch' \
    '    inst.cond = inst.cond # invert-branch' invert
else
  host_limited "runtime mutation: remove a result copy without renaming its producer (macOS arm64)"
  host_limited "runtime mutation: leave an inverted condition unchanged (macOS arm64)"
fi
prove_clean_mutation "branch: drop an unconditional branch regardless of its target" \
  src/compiler/native/mir_clean.iyi \
  '        if tail.target == block.index + 1 # fallthrough-branch' \
  '        if true # fallthrough-branch' branch

[ ! -e "$NATIVE_SIGNATURE_FAILURE_FILE" ] || fail "a native executable failed signature verification"
echo
if [ "$failed" -eq 0 ]; then
  echo "ALL NATIVE MIR CLEAN CHECKS PASSED!"
  exit 0
fi
echo "SOME NATIVE MIR CLEAN CHECKS FAILED"
exit 1
