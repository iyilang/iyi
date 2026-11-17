#!/usr/bin/env bash
# Compares the emitted table with the existing hosted type/layout oracle.
# A real-prelude table comparison and collection are proved by the strict path.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/wait_lower_gc_layout_table.iyi"
if ! "$IYI" build --prelude empty --emit llvm-ir --no-debug -o "$WORK/host" "$fixture" > "$WORK/host.log" 2>&1; then
  echo 'FAIL: hosted fixture did not compile'
  cat "$WORK/host.log"
  exit 1
fi
triple="$(awk -F '"' '/^target triple/ { print $2; exit }' "$WORK/host.ll")"
if ! CRYSTAL_PATH="$REPO/src" "$REPO/bin/crystal" build -Di_know_what_im_doing -o "$WORK/oracle" "$REPO/bench/selfhost_lower_types_oracle.cr" > "$WORK/oracle-build.log" 2>&1; then
  echo 'FAIL: hosted type oracle did not compile'
  cat "$WORK/oracle-build.log"
  exit 1
fi
"$WORK/oracle" "$fixture" "$triple" ids > "$WORK/ids" || exit 1
"$WORK/oracle" "$fixture" "$triple" > "$WORK/rows" || exit 1
check_table() {
  if ! "$IYI" build -o "$WORK/port" "$REPO/bench/selfhost_lower_core_exercise.iyi" > "$WORK/port-build.log" 2>&1; then
    touch "$WORK/invalid"
    return 1
  fi
  if ! "$WORK/port" emit "$fixture" "$WORK/host.ll" > "$WORK/port.ir" 2> "$WORK/port.err"; then
    touch "$WORK/invalid"
    return 1
  fi
  python3 "$REPO/bench/check_gc_table.py" "$WORK/port.ir" "$WORK/ids" "$WORK/rows"
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
if [ -e "$WORK/invalid" ]; then
  echo 'FAIL: GC table mutant did not compile or emit IR'
  exit 1
fi
echo 'GC TABLE GATE PASSED; real-prelude IR and live collection remain pending'
