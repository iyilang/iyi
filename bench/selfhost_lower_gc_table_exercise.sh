#!/usr/bin/env bash
# Compares the emitted table with the existing hosted type/layout oracle.
# A real-prelude table comparison and collection are proved by the strict path.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo 'FAIL: a functional Python interpreter is required' >&2
  exit 1
fi
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/wait_lower_gc_layout_table.iyi"
if ! "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK_NATIVE/host$EXE" "$(native_path "$fixture")" > "$WORK/host.log" 2>&1; then
  echo 'FAIL: hosted fixture did not compile'
  cat "$WORK/host.log"
  exit 1
fi
triple="$(awk -F '"' '/^target triple/ { print $2; exit }' "$WORK/host.ll")"
if ! CRYSTAL_PATH="$REPO_NATIVE/src" "${CRYSTAL:-crystal}" build -Di_know_what_im_doing -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_lower_types_oracle.cr" > "$WORK/oracle-build.log" 2>&1; then
  echo 'FAIL: hosted type oracle did not compile'
  cat "$WORK/oracle-build.log"
  exit 1
fi
"$WORK/oracle$EXE" "$(native_path "$fixture")" "$triple" ids > "$WORK/ids" || exit 1
"$WORK/oracle$EXE" "$(native_path "$fixture")" "$triple" > "$WORK/rows" || exit 1
check_table() {
  if ! "$IYI" build -o "$WORK_NATIVE/port$EXE" "$REPO_NATIVE/bench/selfhost_lower_core_exercise.iyi" > "$WORK/port-build.log" 2>&1; then
    echo 'INVALID: GC table driver failed to build'
    cat "$WORK/port-build.log"
    return 2
  fi
  if ! "$WORK/port$EXE" emit "$(native_path "$fixture")" "$WORK_NATIVE/host.ll" > "$WORK/port.ir" 2> "$WORK/port.err"; then
    echo 'INVALID: GC table driver failed to emit IR'
    cat "$WORK/port.err"
    return 2
  fi
  "$PY" "$REPO_NATIVE/bench/check_gc_table.py" "$WORK_NATIVE/port.ir" "$WORK_NATIVE/ids" "$WORK_NATIVE/rows"
}
if ! check_table; then
  echo 'FAIL: GC table baseline differs from hosted layouts or its emitted encoding is invalid'
  cat "$WORK/port-build.log" "$WORK/port.err"
  exit 1
fi
if ! prove_mutation 'a pointer offset is replaced by zero' "$REPO/src/compiler/lower/gc_table.iyi" \
  '  offsets.each { |offset| words << offset }' \
  '  offsets.each { |offset| words << 0_i64 }' -- check_table; then
  exit 1
fi
echo 'GC TABLE GATE PASSED; real-prelude IR and live collection remain pending'
