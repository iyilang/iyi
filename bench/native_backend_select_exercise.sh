#!/bin/bash
# Backend selection (SPEC 2.1, slice B3). The native-only tool names the backend each target builds with, refuses LLVM by
# name, and writes its verified IR as text that the same tool rebuilds into the executable the hosted compiler builds.
#
# 1. --print-backend prints llvm for each of the five targets while NATIVE_TARGETS is empty.
# 2. --backend llvm is refused with the message a compiler without the LLVM backend gives: exit 1, nothing written.
# 3. --emit ir writes the program's IR; the tool rebuilds that IR and its exit equals the hosted build's.
# 4. Mutation: a triple added to NATIVE_TARGETS changes that target's print from llvm to native, and the gate goes red.
# 5. IR whose module targets another platform is refused by its target, on every host: exit 1, nothing written. The
#    native linker refuses its x86_64 object as well, so a tool without the target check still refuses, by another
#    message; this check holds the refusal to the target's name.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
TOOL_SRC="$REPO/src/compiler/tools/compile_native.iyi"
BACKEND_SRC="$REPO/src/compiler/backend/backend.iyi"
FIXTURE="$REPO/bench/fixtures/backend_select_exit.iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/native_signature.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-backend-select.XXXXXX")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
status=0
TARGETS="aarch64-apple-darwin x86_64-linux-gnu aarch64-linux-gnu x86_64-pc-windows-msvc wasm32-wasi"

echo "== 1. build the native tool from its source with ./bin/iyi"
if ! "$IYI" build -o "$WORK_NATIVE/tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/tool.build.log" 2>&1; then
  echo "FAIL: ./bin/iyi could not build $TOOL_SRC"
  cat "$WORK/tool.build.log"
  exit 1
fi
echo "   built the native tool"

echo "== 2. --print-backend for the five targets: llvm while NATIVE_TARGETS is empty"
for t in $TARGETS; do
  got=$("$WORK/tool$EXE" "$REPO_NATIVE/bench/fixtures/backend_select_exit.iyi" -o "$WORK_NATIVE/print_out" --print-backend --target "$t" 2>/dev/null)
  if [ "$got" = "llvm" ]; then
    echo "   $t: llvm"
  else
    echo "FAIL: $t printed '$got', not llvm"
    status=1
  fi
done

echo "== 3. --backend llvm is refused by name: exit 1, the message verbatim, no output"
for t in $TARGETS; do
  rm -f "$WORK/llvm_out"
  "$WORK/tool$EXE" "$REPO_NATIVE/bench/fixtures/backend_select_exit.iyi" -o "$WORK_NATIVE/llvm_out" --backend llvm --target "$t" >"$WORK/llvm.out" 2>"$WORK/llvm.err"
  rc=$?
  want="iyi: this compiler has no LLVM backend; $t has no native backend yet"
  got=$(cat "$WORK/llvm.err")
  if [ "$rc" = 1 ] && [ "$got" = "$want" ] && [ ! -e "$WORK/llvm_out" ]; then
    echo "   $t: refused with exit 1, the message verbatim, nothing written"
  else
    echo "FAIL: $t: exit $rc, stderr '$got', output exists: $([ -e "$WORK/llvm_out" ] && echo yes || echo no)"
    status=1
  fi
done

echo "== 4. --emit ir: the IR parses and verifies, and the tool rebuilds it to the hosted build's exit"
if ! "$IYI" build -o "$WORK_NATIVE/hosted$EXE" "$REPO_NATIVE/bench/fixtures/backend_select_exit.iyi" >"$WORK/hosted.log" 2>&1; then
  echo "FAIL: the hosted compiler could not build $FIXTURE"
  cat "$WORK/hosted.log"
  exit 1
fi
"$WORK/hosted$EXE" >/dev/null 2>&1
hosted_rc=$?
if "$WORK/tool$EXE" "$REPO_NATIVE/bench/fixtures/backend_select_exit.iyi" -o "$WORK_NATIVE/prog.ir" --emit ir >"$WORK/emit.log" 2>&1 && [ -s "$WORK/prog.ir" ]; then
  echo "   wrote $(wc -l <"$WORK/prog.ir" | tr -d ' ') lines of IR"
  if [ "$HOST_ID" != darwin-arm64 ]; then
    host_limited "backend selection: rebuilding and executing the emitted IR requires macOS arm64 Mach-O"
  elif "$WORK/tool$EXE" "$WORK_NATIVE/prog.ir" -o "$WORK_NATIVE/from_ir" >"$WORK/from_ir.log" 2>&1 && native_signature_ok "$WORK/from_ir"; then
    "$WORK/from_ir" >/dev/null 2>&1
    ir_rc=$?
    if [ "$ir_rc" = "$hosted_rc" ]; then
      echo "   the rebuilt IR runs to exit $ir_rc, equal to the hosted build"
    else
      echo "FAIL: the rebuilt IR exits $ir_rc, the hosted build exits $hosted_rc"
      status=1
    fi
  else
    echo "FAIL: the tool refused the emitted IR: $(awk '/Error|error/ { print; exit }' "$WORK/from_ir.log")"
    status=1
  fi
else
  echo "FAIL: --emit ir wrote no IR: $(awk '/Error|error/ { print; exit }' "$WORK/emit.log")"
  status=1
fi

echo "== 4b. IR for another target is refused by its target: exit 1, the message, nothing written"
# The refusal comes before any linking, so it holds on every host.
LINUX_IR="$REPO_NATIVE/bench/fixtures/backend_select_linux_target.ir"
want_target="$LINUX_IR: the module's target is not aarch64-apple-darwin"
# Returns 0 when the tool refuses the fixture as it should, 1 when it accepted it or wrote an image, 2 when the
# check itself cannot run.
check_foreign_target_refused() {
  local tool="$1" rc got
  rm -f "$WORK/foreign_out"
  "$tool" "$LINUX_IR" -o "$WORK_NATIVE/foreign_out" >"$WORK/foreign.out" 2>"$WORK/foreign.err"
  rc=$?
  got=$(tr -d '\r' <"$WORK/foreign.err")
  if [ "$rc" = 1 ] && [ "$got" = "iyi-compile-native: $want_target" ] && [ ! -e "$WORK/foreign_out" ]; then
    return 0
  fi
  if [ "$rc" = 0 ] || [ -e "$WORK/foreign_out" ]; then
    echo "decisive: the tool exited $rc on an x86_64 Linux module and wrote: $([ -e "$WORK/foreign_out" ] && echo an image || echo nothing)"
    return 1
  fi
  echo "unexpected: exit $rc, stderr '$got'"
  return 2
}
check_foreign_target_refused "$WORK/tool$EXE"
case $? in
  0) echo "   x86_64-unknown-linux-gnu IR: refused with exit 1, the message verbatim, nothing written" ;;
  *) echo "FAIL: the tool did not refuse IR for x86_64-unknown-linux-gnu by its target"; status=1 ;;
esac

echo "== 5. mutation: a triple in NATIVE_TARGETS must turn its print from llvm to native"
# The check fails (is caught) when the mutated tool prints native for x86_64-linux-gnu.
check_native_mutant() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut_tool$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/mut.log" 2>&1; then
    cat "$WORK/mut.log"
    return 2
  fi
  if ! got=$("$WORK/mut_tool$EXE" "$REPO_NATIVE/bench/fixtures/backend_select_exit.iyi" -o "$WORK_NATIVE/mut_out" --print-backend --target x86_64-linux-gnu 2>"$WORK/mut.err"); then
    cat "$WORK/mut.err"
    return 2
  fi
  case "$got" in
    llvm) return 0 ;;
    native) echo "decisive: x86_64-linux-gnu selected native"; return 1 ;;
    *) echo "unexpected backend '$got'"; return 2 ;;
  esac
}
mut_run=1
mut_caught=0
if prove_mutation "a triple joins NATIVE_TARGETS" "$BACKEND_SRC" \
    'NATIVE_TARGETS = [] of String' 'NATIVE_TARGETS = ["x86_64-linux-gnu"] of String' \
    -- check_native_mutant; then
  mut_caught=1
  echo "    caught: a triple in NATIVE_TARGETS moves its print from llvm to native"
else
  status=1
  echo "FAIL: the mutation was not caught"
fi
echo "  Mutation summary: $mut_caught/$mut_run attempted caught; 0 host-limited"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL NATIVE BACKEND SELECTION CHECKS PASSED!"
else
  echo "SOME NATIVE BACKEND SELECTION CHECKS FAILED"
fi
exit "$status"
