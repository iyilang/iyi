#!/usr/bin/env bash
# Native LLVM round-trip gate (SPEC 3.3, slice B2). It builds iyi-ir, round-trips every fixture that
# passes today, drops the unwind edges of the oracle's handler module and compares what is left, and proves the gate can
# fail with six mutations: dropping nsw in the translator, writing hidden as the default visibility, removing an intrinsic
# from the importer's accepted set, dropping the align on an intrinsic operand, importing either name of the program's
# entry with the C convention, and a patch that changes nothing.
# Run through bench/selfhost_gates.sh. The linked LLVM's major version is read through
# `iyi-ir version`. A fixture annotated `; needs-llvm: N` is reported as skipped, never as passed, when the linked major
# is below N. The COVERAGE.md comparison is reported as skipped when that file was written by a different LLVM major.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
[ -n "$PY" ] || { echo "FAIL: a working Python interpreter is required" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: perl is required for mutation proofs" >&2; exit 1; }
. "$REPO/bench/lib/mutation.sh" || exit 1

IYI="$REPO/bin/iyi"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-llvm.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE=$(native_path "$REPO") || exit 1
WORK_NATIVE=$(native_path "$WORK") || exit 1
export IYI_PATH="$REPO_NATIVE/src"
TOOL="$WORK/iyi-ir$EXE"
FX=bench/fixtures/llvm_roundtrip
SRC=src/compiler/tools/ir.iyi
failed=0

step() {
  echo "== $1. $2"
}

stop_gate() {
  echo "== NATIVE LLVM ROUNDTRIP GATE STOPPED: $1"
  exit 1
}

rebuild_tool() {
  if ! rm -f "$TOOL"; then
    echo "cannot remove the previous iyi-ir executable"
    return 1
  fi
  if "$IYI" build -o "$WORK_NATIVE/iyi-ir$EXE" "$REPO_NATIVE/$SRC" > "$WORK/iyi-ir-build.log" 2>&1; then
    if [ -f "$TOOL" ]; then
      return 0
    fi
    echo "iyi-ir build returned success without an executable"
  else
    echo "iyi-ir build failed"
  fi
  cat "$WORK/iyi-ir-build.log"
  return 1
}

# Only an expected behavioral diagnostic can catch a round-trip mutant.
# A build failure or unrelated runtime error makes the proof fail.
check_roundtrip_mutant() {
  local fixture="$1" rc=0 first
  if ! rebuild_tool; then
    echo "INVALID MUTANT: iyi-ir did not build"
    return 0
  fi
  "$TOOL" roundtrip "$fixture" > "$WORK/mutant.out" 2>&1 || rc=$?
  first=$(head -n 1 "$WORK/mutant.out")
  if [ "$rc" -eq 1 ]; then
    case "$first" in
      differs*|refused*|"locations differ"*) return 1 ;;
    esac
  elif [ "$rc" -eq 0 ] && [ "$(cat "$WORK/mutant.out")" = "identical" ]; then
    return 0
  fi
  echo "INVALID MUTANT: roundtrip exited $rc with an unexpected result"
  cat "$WORK/mutant.out"
  return 0
}

check_drop_unwind_mutant() {
  local rc=0 cmp_rc=0
  if ! rebuild_tool; then
    echo "INVALID MUTANT: iyi-ir did not build"
    return 0
  fi
  "$TOOL" drop-unwind "$UNW/entry.ll" > "$WORK/mutant.out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    cmp -s "$WORK/mutant.out" "$UNW/entry.expected" || cmp_rc=$?
    if [ "$cmp_rc" -eq 1 ]; then
      return 1
    elif [ "$cmp_rc" -eq 0 ]; then
      return 0
    fi
  fi
  echo "INVALID MUTANT: drop-unwind exited $rc or comparison failed (cmp $cmp_rc)"
  cat "$WORK/mutant.out"
  return 0
}

step 1 "build iyi-ir"
if rebuild_tool; then
  echo "iyi-ir built: $TOOL"
else
  stop_gate "iyi-ir did not build; the log is above"
fi
llvm_version=$("$TOOL" version 2>&1)
llvm_major=${llvm_version%%.*}
case "$llvm_major" in
  ''|*[!0-9]*) echo "cannot read the linked LLVM version: $llvm_version"; failed=1; llvm_major=0 ;;
  *) echo "linked LLVM: $llvm_version" ;;
esac

step 2 "every fixture round-trips identically, and the one the translator refuses is refused by name"
count=0
total=0
skipped=0
for name in arith control probe_switch probe_phi memory consts calls sizeof visibility wide_int overflow8_16 variadic flags_attrs memset_param_align int192 asm_unwind; do
  need=$(awk '/^; needs-llvm: /{ print $3; exit }' "$FX/$name.ll")
  if [ -n "$need" ] && [ "$llvm_major" -lt "$need" ]; then
    skipped=$((skipped + 1))
    echo "skipped: $name needs LLVM >= $need (linked LLVM $llvm_version)"
    continue
  fi
  total=$((total + 1))
  rc=0
  verdict=$("$TOOL" roundtrip "$FX/$name.ll" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && [ "$verdict" = "identical" ]; then
    count=$((count + 1))
    echo "identical: $name"
  else
    echo "NOT identical: $name: $(echo "$verdict" | head -1)"
    # The rest of what the tool said: on a runner the log is all there is to read the difference from.
    echo "$verdict" | sed -n '2,12p' | sed 's/^/    /'
    failed=1
  fi
done
rc=0
verdict=$("$TOOL" roundtrip "$FX/dso_local.ll" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && [[ "$verdict" == "refused by the translator: the linked LLVM's C API cannot set dso_local"* ]]; then
  echo "refused by name: dso_local"
else
  echo "NOT refused by name: dso_local (exit $rc): $(echo "$verdict" | head -1)"
  failed=1
fi
echo "identical fixtures: $count of $total run; skipped: $skipped"

step 2b "the oracle's handler module with its unwind edges dropped is the normal path, and the program's entry is Iyi"
UNW=bench/fixtures/ir/unwind
if "$TOOL" drop-unwind "$UNW/entry.ll" > "$WORK/iyi-ir-unwind.out" 2>&1 && cmp -s "$WORK/iyi-ir-unwind.out" "$UNW/entry.expected"; then
  echo "identical: drop-unwind entry"
else
  echo "NOT identical: drop-unwind entry"
  diff "$WORK/iyi-ir-unwind.out" "$UNW/entry.expected" | sed -n '1,12p' | sed 's/^/    /'
  failed=1
fi

step 3 "mutation: drop nsw in the translator"
prove_mutation "drop nsw in translate" \
  src/compiler/backend/llvm/translate.iyi \
  "LibLLVM.set_nsw(result, 1) if (flags & 2_i64) != 0" \
  "LibLLVM.set_nsw(result, 0) if (flags & 2_i64) != 0" \
  -- check_roundtrip_mutant "$FX/arith.ll" || failed=1

step 3b "mutation: write hidden as default in the translator"
prove_mutation "write hidden as default in translate" \
  src/compiler/backend/llvm/translate.iyi \
  "LibLLVM.set_visibility(fn, visibility_number(f.visibility))" \
  "LibLLVM.set_visibility(fn, 0)" \
  -- check_roundtrip_mutant "$FX/visibility.ll" || failed=1

step 4 "mutation: remove llvm.memcpy from the importer's accepted intrinsics"
prove_mutation "remove llvm.memcpy from the importer" \
  src/compiler/backend/llvm/import.iyi \
  "found = intrinsic_match(llvm_name, @ir.types)" \
  "found = llvm_name == \"llvm.memcpy.p0.p0.i64\" ? nil : intrinsic_match(llvm_name, @ir.types)" \
  -- check_roundtrip_mutant "$FX/calls.ll" || failed=1

step 4c "mutation: drop the align on an intrinsic operand in the translator"
prove_mutation "drop align on an intrinsic operand in translate" \
  src/compiler/backend/llvm/translate.iyi \
  "LibLLVM.add_callsite_attribute(call, index, create_attribute(a))" \
  "LibLLVM.add_callsite_attribute(call, index, create_attribute(a)) if a.name != \"align\"" \
  -- check_roundtrip_mutant "$FX/memset_param_align.ll" || failed=1

step 4d "mutation: the bare entry is imported with the C convention"
prove_mutation "import __crystal_main as C" \
  src/compiler/backend/llvm/import.iyi \
  "return CallConv::Iyi if name == \"__crystal_main\" || name == \"__iyi_main\"" \
  "return CallConv::Iyi if name == \"__iyi_main\"" \
  -- check_drop_unwind_mutant || failed=1

step 4e "mutation: the prelude's entry is imported with the C convention"
prove_mutation "import __iyi_main as C" \
  src/compiler/backend/llvm/import.iyi \
  "return CallConv::Iyi if name == \"__crystal_main\" || name == \"__iyi_main\"" \
  "return CallConv::Iyi if name == \"__crystal_main\"" \
  -- check_drop_unwind_mutant || failed=1

step 5 "mutation: a patch that changes nothing is refused"
noop_rc=0
noop_out=$(prove_mutation "no-op patch" \
  src/compiler/backend/llvm/translate.iyi \
  "LibLLVM.set_nsw(result, 1) if (flags & 2_i64) != 0" \
  "LibLLVM.set_nsw(result, 1) if (flags & 2_i64) != 0" \
  -- true 2>&1) || noop_rc=$?
case "$noop_rc:$noop_out" in
  3:*"PATCH CHANGED NOTHING"*) echo "$noop_out"; echo "refused: no-op patch" ;;
  *) echo "NOT refused: no-op patch"; echo "$noop_out"; failed=1 ;;
esac

step 6 "the tree is restored: iyi-ir is rebuilt from the committed sources"
sources_committed=1
for source in \
  src/compiler/llvm.iyi \
  src/compiler/llvm/{builder,context,lib_llvm,llvm,memory_buffer,module,pass_manager,target,values}.iyi \
  src/compiler/backend/llvm/{emit,import,translate}.iyi \
  src/compiler/tools/ir.iyi; do
  git cat-file -e "HEAD:$source" 2>/dev/null || sources_committed=0
done
if [ "$sources_committed" -eq 1 ] &&
   git diff --quiet HEAD -- src/compiler/llvm.iyi src/compiler/llvm \
     src/compiler/backend/llvm src/compiler/tools/ir.iyi src/compiler/ir; then
  echo "sources match HEAD"
else
  echo "sources differ from HEAD after the mutations"
  failed=1
fi
rebuild_tool || stop_gate "iyi-ir did not rebuild from the restored sources"

step 7 "the coverage inventory of the fixtures and gap reproducers matches COVERAGE.md"
COV=$FX/COVERAGE.md
cov_tsv="$WORK/iyi-ir-coverage.tsv"
coverage_rc=0
if ls "$FX"/gaps/*.ll > /dev/null 2>&1; then
  "$TOOL" coverage "$FX"/*.ll "$FX"/gaps/*.ll > "$cov_tsv" 2>&1 || coverage_rc=$?
else
  "$TOOL" coverage "$FX"/*.ll > "$cov_tsv" 2>&1 || coverage_rc=$?
fi
if [ "$coverage_rc" -ne 0 ]; then
  echo "FAILED: iyi-ir coverage exited $coverage_rc"
  cat "$cov_tsv"
  failed=1
elif [ ! -r "$COV" ] && [ "${COVERAGE_WRITE:-0}" != "1" ]; then
  echo "FAILED: COVERAGE.md is missing or unreadable"
  failed=1
else
  {
    echo "# LLVM round-trip coverage: committed fixtures and gap reproducers"
    echo
    echo "Linked LLVM: $llvm_version"
    echo
    echo "Written by \`bench/native_llvm_roundtrip_exercise.sh\` from \`iyi-ir coverage\` over every fixture and gap reproducer. The gate fails when this file is stale; \`COVERAGE_WRITE=1\` rewrites it."
    echo
    echo '```'
    cat "$cov_tsv"
    echo '```'
  } > "$WORK/iyi-ir-COVERAGE.md"
  if [ "${COVERAGE_WRITE:-0}" = "1" ]; then
    if cp "$WORK/iyi-ir-COVERAGE.md" "$COV"; then
      echo "COVERAGE.md written"
    else
      echo "FAILED: could not write COVERAGE.md"
      failed=1
    fi
  else
    cov_written=$(awk '/^Linked LLVM: /{ print $3; exit }' "$COV")
    if [ "${cov_written%%.*}" != "$llvm_major" ]; then
      cov_major=${cov_written%%.*}
      echo "skipped: COVERAGE.md was written with LLVM ${cov_major:-unknown}, this is LLVM $llvm_major (not compared)"
      skipped=$((skipped + 1))
    elif cmp -s "$WORK/iyi-ir-COVERAGE.md" "$COV"; then
      echo "COVERAGE.md is current"
    else
      echo "COVERAGE.md is stale: rerun with COVERAGE_WRITE=1"
      failed=1
    fi
  fi
fi
echo "skipped checks: $skipped (reported, never counted as passed)"

if [ "$failed" -eq 0 ]; then
  echo "== ALL NATIVE LLVM ROUNDTRIP CHECKS PASSED"
  exit 0
fi
echo "== SOME NATIVE LLVM ROUNDTRIP CHECKS FAILED"
exit 1
