#!/bin/bash
# Backend selection (SPEC 2.1, slice B3). The native-only tool names the backend each target builds with, refuses LLVM by
# name, and writes its verified IR as text that the same tool rebuilds into the executable the hosted compiler builds.
#
# 1. --print-backend prints llvm for each of the five targets while NATIVE_TARGETS is empty.
# 2. --backend llvm is refused with the message a compiler without the LLVM backend gives: exit 1, nothing written.
# 3. --emit ir writes the program's IR; the tool rebuilds that IR and its exit equals the hosted build's.
# 4. Mutation: a triple added to NATIVE_TARGETS changes that target's print from llvm to native, and the gate goes red.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IYI="$REPO/bin/iyi"
TOOL_SRC="$REPO/src/compiler/tools/compile_native.iyi"
BACKEND_SRC="$REPO/src/compiler/backend/backend.iyi"
FIXTURE="$REPO/bench/fixtures/backend_select_exit.iyi"
. "$REPO/bench/lib/mutation.sh"
. "$REPO/bench/lib/native_signature.sh"

WORK="$(mktemp -d /tmp/iyi-backend-select.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
status=0
TARGETS="aarch64-apple-darwin x86_64-linux-gnu aarch64-linux-gnu x86_64-pc-windows-msvc wasm32-wasi"

echo "== 1. build the native tool from its source with ./bin/iyi"
if ! "$IYI" build -o "$WORK/tool" "$TOOL_SRC" >"$WORK/tool.build.log" 2>&1; then
  echo "FAIL: ./bin/iyi could not build $TOOL_SRC"
  exit 1
fi
echo "   built the native tool"

echo "== 2. --print-backend for the five targets: llvm while NATIVE_TARGETS is empty"
for t in $TARGETS; do
  got=$("$WORK/tool" "$FIXTURE" -o "$WORK/print_out" --print-backend --target "$t" 2>/dev/null)
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
  "$WORK/tool" "$FIXTURE" -o "$WORK/llvm_out" --backend llvm --target "$t" >"$WORK/llvm.out" 2>"$WORK/llvm.err"
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
if ! "$IYI" build -o "$WORK/hosted" "$FIXTURE" >"$WORK/hosted.log" 2>&1; then
  echo "FAIL: the hosted compiler could not build $FIXTURE"
  exit 1
fi
"$WORK/hosted" >/dev/null 2>&1
hosted_rc=$?
if "$WORK/tool" "$FIXTURE" -o "$WORK/prog.ir" --emit ir >"$WORK/emit.log" 2>&1 && [ -s "$WORK/prog.ir" ]; then
  echo "   wrote $(wc -l <"$WORK/prog.ir" | tr -d ' ') lines of IR"
  if "$WORK/tool" "$WORK/prog.ir" -o "$WORK/from_ir" >"$WORK/from_ir.log" 2>&1 && native_signature_ok "$WORK/from_ir"; then
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

echo "== 5. mutation: a triple in NATIVE_TARGETS must turn its print from llvm to native"
# The check fails (is caught) when the mutated tool prints native for x86_64-linux-gnu.
check_native_mutant() {
  "$IYI" build -o "$WORK/mut_tool" "$TOOL_SRC" >"$WORK/mut.log" 2>&1 || return 1
  got=$("$WORK/mut_tool" "$FIXTURE" -o "$WORK/mut_out" --print-backend --target x86_64-linux-gnu 2>/dev/null)
  [ "$got" = "llvm" ]
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
echo "  Mutation summary: $mut_caught/$mut_run source mutations caught"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL NATIVE BACKEND SELECTION CHECKS PASSED!"
else
  echo "SOME NATIVE BACKEND SELECTION CHECKS FAILED"
fi
exit "$status"
