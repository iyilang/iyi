#!/usr/bin/env bash
# Exercises the self-hosting LLVM bindings, wrappers, IR construction,
# pass manager optimization, and native object emission.
#
#   bash bench/selfhost_llvm_exercise.sh
#
# Verifies plain and release builds, links and runs the emitted object through
# the hosted iyi toolchain, and proves five wrapper mutations are caught.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd -P)
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
[ -n "$PY" ] || { echo "FAIL: a working Python interpreter is required" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "FAIL: perl is required for mutation proofs" >&2; exit 1; }
. "$REPO/bench/lib/mutation.sh" || exit 1

IYI="$REPO/bin/iyi"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/selfhost-llvm.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE=$(native_path "$REPO") || exit 1
WORK_NATIVE=$(native_path "$WORK") || exit 1
export IYI_PATH="$REPO_NATIVE/src"

status=0
mkdir -p "$WORK/plain_out" "$WORK/release_out" "$WORK/mut_out" "$WORK/final_out" || exit 1

echo "== 1. Building and running selfhost LLVM exercise (plain mode)"
if ! "$IYI" build -o "$WORK_NATIVE/exercise-plain$EXE" \
  "$REPO_NATIVE/bench/selfhost_llvm_exercise.iyi" > "$WORK/plain-build.log" 2>&1; then
  echo "FAILED: the plain exercise did not build"
  cat "$WORK/plain-build.log"
  exit 1
fi
# The exercise's own output names the check that failed: print it before stopping, or the gate's log ends at the
# heading above and says nothing.
if ! "$WORK/exercise-plain$EXE" "$WORK_NATIVE/plain_out" > "$WORK/plain.out" 2>&1; then
  cat "$WORK/plain.out"
  echo "FAILED: the plain exercise exited non-zero"
  exit 1
fi
cat "$WORK/plain.out"

echo
echo "== Checking reported verification sections in plain mode"
for phrase in \
  "== 1. Target initialization & identification" \
  "== 2. Context & Type system" \
  "== 3. Constants & Values" \
  "== 4. Module construction, globals & functions" \
  "== 5. Verification" \
  "== 6. Optimization passes (PassBuilder)" \
  "== 7. Object, Assembly, Bitcode emission" \
  "ALL SELFHOST LLVM CHECKS PASSED SUCCESSFULLY!"; do
  if ! grep -qF "$phrase" "$WORK/plain.out"; then
    echo "FAILED: missing '$phrase'"
    exit 1
  fi
done

echo
echo "== 2. Building and running selfhost LLVM exercise (--release mode)"
if ! "$IYI" build --release -o "$WORK_NATIVE/exercise-release$EXE" \
  "$REPO_NATIVE/bench/selfhost_llvm_exercise.iyi" > "$WORK/release-build.log" 2>&1; then
  echo "FAILED: the release exercise did not build"
  cat "$WORK/release-build.log"
  exit 1
fi
if ! "$WORK/exercise-release$EXE" "$WORK_NATIVE/release_out" > "$WORK/release.out" 2>&1; then
  cat "$WORK/release.out"
  echo "FAILED: the release exercise exited non-zero"
  exit 1
fi
cat "$WORK/release.out"

if ! grep -qF "ALL SELFHOST LLVM CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "FAILED: release mode did not pass checks"
  exit 1
fi

echo
echo "== 3. Verifying native object emission, linking, and execution"
if [ ! -f "$WORK/plain_out/selfhost_llvm_test.o" ]; then
  echo "FAILED: object file not found at $WORK/plain_out/selfhost_llvm_test.o"
  exit 1
fi

# Say what kind of object it is. The CI container has no `file`, and the gate
# died there with 127 on a line that only describes: the link and the run below
# are what check the object, so this prints the magic bytes where `file` is absent.
if command -v file >/dev/null 2>&1; then
  file "$WORK/plain_out/selfhost_llvm_test.o"
else
  echo "object magic: $(od -An -tx1 -N4 "$WORK/plain_out/selfhost_llvm_test.o" | tr -d ' \n')"
fi

# Link the emitted object through the same hosted toolchain on every host.
cat <<'IYI_RUNNER' > "$WORK/link_driver.iyi"
@[Unsafe("calls the emitted object's C ABI functions, whose signatures the compiler cannot check")]
lib LibEmitted
  fun add_numbers(a : Int32, b : Int32) : Int32
  fun factorial(n : Int32) : Int32
end

sum = LibEmitted.add_numbers(40, 2)
raise "FAIL: add_numbers(40, 2) = #{sum}, expected 42" unless sum == 42
puts "add_numbers(40, 2) = #{sum} [OK]"

fact5 = LibEmitted.factorial(5)
raise "FAIL: factorial(5) = #{fact5}, expected 120" unless fact5 == 120
puts "factorial(5) = #{fact5} [OK]"
puts "EMITTED OBJECT EXECUTION VERIFIED SUCCESSFULLY!"
IYI_RUNNER

if ! "$IYI" build --link-flags "$WORK_NATIVE/plain_out/selfhost_llvm_test.o" \
  -o "$WORK_NATIVE/test_runner$EXE" "$WORK_NATIVE/link_driver.iyi" > "$WORK/driver-build.log" 2>&1; then
  echo "FAILED: the emitted object driver did not build"
  cat "$WORK/driver-build.log"
  exit 1
fi
if ! "$WORK/test_runner$EXE" > "$WORK/driver.out" 2>&1; then
  cat "$WORK/driver.out"
  echo "FAILED: the emitted object driver exited non-zero"
  exit 1
fi
cat "$WORK/driver.out"

if ! grep -qF "EMITTED OBJECT EXECUTION VERIFIED SUCCESSFULLY!" "$WORK/driver.out"; then
  echo "FAILED: emitted object execution failed"
  exit 1
fi

echo
echo "== 4. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# A build failure, missing executable, or unrelated runtime failure cannot
# prove the exercise caught a defect.
llvm_exercise_mutant() {
  if ! rm -f "$WORK/mut-exercise$EXE"; then
    echo "INVALID MUTANT: could not remove the previous LLVM exercise executable"
    return 0
  fi
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" \
    "$REPO_NATIVE/bench/selfhost_llvm_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "INVALID MUTANT: LLVM exercise did not build"
    cat "$WORK/mut-build.log"
    return 0
  fi
  if [ ! -f "$WORK/mut-exercise$EXE" ]; then
    echo "INVALID MUTANT: LLVM exercise executable is missing"
    cat "$WORK/mut-build.log"
    return 0
  fi
  if "$WORK/mut-exercise$EXE" "$WORK_NATIVE/mut_out" > "$WORK/mut-run.log" 2>&1; then
    if grep -qF "ALL SELFHOST LLVM CHECKS PASSED SUCCESSFULLY!" "$WORK/mut-run.log"; then
      return 0
    fi
  elif grep -qF "Assertion failed:" "$WORK/mut-run.log"; then
    return 1
  fi
  echo "INVALID MUTANT: LLVM exercise did not report an assertion failure or a clean pass"
  cat "$WORK/mut-run.log"
  return 0
}

prove_mutation "corrupting build_and in builder.iyi" \
  "$REPO/src/compiler/llvm/builder.iyi" \
  "LibLLVM.build_and" \
  "LibLLVM.build_or" \
  -- llvm_exercise_mutant || status=1

prove_mutation "corrupting int_width in values.iyi" \
  "$REPO/src/compiler/llvm/values.iyi" \
  "LibLLVM.get_int_type_width(@unwrap)" \
  "LibLLVM.get_int_type_width(@unwrap) + 1" \
  -- llvm_exercise_mutant || status=1

prove_mutation "corrupting Target.init_target in target.iyi" \
  "$REPO/src/compiler/llvm/target.iyi" \
  'case name.downcase' \
  'case name.upcase' \
  -- llvm_exercise_mutant || status=1

prove_mutation "corrupting verify_safely in module.iyi" \
  "$REPO/src/compiler/llvm/module.iyi" \
  "{false, err}" \
  '{true, ""}' \
  -- llvm_exercise_mutant || status=1

prove_mutation "corrupting build_xor in builder.iyi" \
  "$REPO/src/compiler/llvm/builder.iyi" \
  "LibLLVM.build_xor" \
  "LibLLVM.build_or" \
  -- llvm_exercise_mutant || status=1

echo
echo "== 5. Confirming clean state verification"
if ! "$IYI" build --release -o "$WORK_NATIVE/exercise-final$EXE" \
  "$REPO_NATIVE/bench/selfhost_llvm_exercise.iyi" > "$WORK/final-build.log" 2>&1; then
  echo "FAILED: the restored LLVM exercise did not build"
  cat "$WORK/final-build.log"
  status=1
elif ! "$WORK/exercise-final$EXE" "$WORK_NATIVE/final_out" > "$WORK/final.out" 2>&1; then
  echo "FAILED: the restored LLVM exercise exited non-zero"
  cat "$WORK/final.out"
  status=1
elif ! grep -qF "ALL SELFHOST LLVM CHECKS PASSED SUCCESSFULLY!" "$WORK/final.out"; then
  echo "FAILED: the restored LLVM exercise did not report success"
  cat "$WORK/final.out"
  status=1
else
  echo "  Clean state confirmed: all self-host LLVM checks pass!"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST LLVM BENCHMARK & MUTATION CHECKS PASSED!"
  exit 0
fi
echo "== SOME CHECKS FAILED!"
exit 1
