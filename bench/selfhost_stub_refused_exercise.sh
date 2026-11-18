#!/usr/bin/env bash
# Diagnostic stubs never change strict compilation and stop when actually called.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
FIXTURE="$REPO_NATIVE/bench/fixtures/stub_refused.iyi"
REFUSAL='proc literal: a nested proc, def or class inside a proc literal (hosted closure)'
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"

check_stub() {
  local rc=0 expected_exit
  rm -f "$WORK/strict" "$WORK/model.ir" "$WORK/model.ir.stubs" "$WORK/model"
  if ! "$IYI" build -o "$WORK_NATIVE/stage1$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/build.log" 2>&1; then
    echo 'INVALID: stub compiler did not build'; cat "$WORK/build.log"; return 2
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/stage1$EXE"; then return 2; fi
  "$WORK/stage1$EXE" "$FIXTURE" -o "$WORK_NATIVE/strict" --pipeline typed --emit ir >"$WORK/strict.out" 2>"$WORK/strict.err" || rc=$?
  if [ "$rc" -ne 1 ] || [ -s "$WORK/strict.out" ] || [ -e "$WORK/strict" ] ||
     ! grep -Fxq "iyi-compile-native: lower: $REFUSAL" "$WORK/strict.err" ||
     ! grep -Eq '^  in .*StubExercise#refused' "$WORK/strict.err"; then
    echo "INVALID: strict compilation did not refuse StubExercise#refused (exit $rc, output exists: $([ -e "$WORK/strict" ] && echo yes || echo no))"
    cat "$WORK/strict.out" "$WORK/strict.err"; return 2
  fi
  if ! "$WORK/stage1$EXE" "$FIXTURE" -o "$WORK_NATIVE/model.ir" --pipeline typed --stub-refused --emit ir >"$WORK/stub.log" 2>&1 ||
     ! grep -q 'DIAGNOSTIC BUILD' "$WORK/stub.log" ||
     ! grep -F 'StubExercise#refused' "$WORK/model.ir.stubs" | grep -Fq "$REFUSAL"; then
    echo 'INVALID: diagnostic IR or stub sidecar missing'; cat "$WORK/stub.log"; return 2
  fi
  awk '/^define .*StubExercise#refused/ {inside=1} inside {print} inside && /^}/ {inside=0}' "$WORK/model.ir" >"$WORK/stub-body.ir"
  if [ ! -s "$WORK/stub-body.ir" ]; then
    echo 'INVALID: refused function body is absent from diagnostic IR'; return 2
  fi
  if grep -Eq 'call .*@"?exit"?\(i32 70\)' "$WORK/stub-body.ir"; then
    expected_exit=70
  elif grep -Eq 'call .*@"?exit"?\(i32 71\)' "$WORK/stub-body.ir"; then
    expected_exit=71
  else
    echo 'INVALID: diagnostic stub has no expected exit instruction'; return 2
  fi
  if [ "$HOST_ID" = darwin-arm64 ]; then
    if ! "$WORK/stage1$EXE" "$FIXTURE" -o "$WORK_NATIVE/model" --pipeline typed --stub-refused >"$WORK/native-stub.log" 2>&1 ||
       ! codesign -v --strict "$WORK/model"; then
      echo 'INVALID: diagnostic native executable did not build'; cat "$WORK/native-stub.log"; return 2
    fi
    "$WORK/model" >"$WORK/normal.out" 2>"$WORK/normal.err"; local normal=$?
    "$WORK/hosted$EXE" >"$WORK/hosted.out" 2>"$WORK/hosted.err"; local hosted=$?
    if [ "$normal" -ne 23 ] || [ "$hosted" -ne 23 ] || ! cmp -s "$WORK/normal.out" "$WORK/hosted.out" || ! cmp -s "$WORK/normal.err" "$WORK/hosted.err"; then
      echo 'INVALID: unmodified path differs from hosted'; return 2
    fi
    "$WORK/model" hit >"$WORK/hit.out" 2>"$WORK/hit.err"; local hit=$?
    if [ "$hit" -ne "$expected_exit" ] || [ "$(wc -l <"$WORK/hit.err" | tr -d ' ')" -ne 1 ] ||
       ! grep -Fq 'iyi: refused def hit at runtime:' "$WORK/hit.err" ||
       ! grep -Fq 'StubExercise#refused' "$WORK/hit.err" || ! grep -Fq "$REFUSAL" "$WORK/hit.err"; then
      echo 'INVALID: native stub did not produce the expected diagnostic and status'; cat "$WORK/hit.err"; return 2
    fi
  fi
  if [ "$expected_exit" -eq 71 ]; then echo 'decisive: compiled stub exits 71 instead of 70'; return 1; fi
  return 0
}

"$IYI" build --prelude empty -o "$WORK_NATIVE/hosted$EXE" "$FIXTURE" >"$WORK/hosted.build.log" 2>&1 || { cat "$WORK/hosted.build.log"; exit 1; }
if [ "$HOST_ID" != darwin-arm64 ]; then
  host_limited 'stub refused: native diagnostic executable linking and execution require Darwin arm64; strict refusal and stub IR checks still run'
fi
if ! check_stub; then
  echo 'FAIL: diagnostic stub behavior'
  exit 1
fi
echo 'PASS: strict refusal and diagnostic stub; native execution checked on Darwin arm64'
prove_mutation 'stub exits with status 70' "$REPO/src/compiler/lower/fun.iyi" 'b.const_int(m.types.int32, 70)' 'b.const_int(m.types.int32, 71)' -- check_stub || exit 1
