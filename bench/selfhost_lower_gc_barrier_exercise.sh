#!/usr/bin/env bash
# Check concurrent marking and hosted write-barrier parity on live heap stores.
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'if [ "$status" -ne 0 ]; then echo "GC barrier logs: $WORK"; else rm -rf "$WORK"; fi' EXIT
. "$REPO/bench/lib/mutation.sh"
fixture="$REPO/bench/fixtures/low_gc_barrier.iyi"

"$IYI" build --emit llvm-ir --no-debug -o "$WORK/hosted" "$fixture" >"$WORK/hosted.log" 2>&1 || { cat "$WORK/hosted.log"; exit 1; }
"$IYI" build -o "$WORK/ir" "$REPO/src/compiler/tools/ir.iyi" >"$WORK/ir.log" 2>&1 || { cat "$WORK/ir.log"; exit 1; }
codesign -v --strict "$WORK/hosted" && "$WORK/hosted" > "$WORK/hosted.out" || exit 1
grep -qx 'OK' "$WORK/hosted.out" || exit 1

check_barriers() {
  "$IYI" build -o "$WORK/stage1" "$REPO/src/compiler/tools/compile_native.iyi" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; touch "$WORK/invalid"; return 1; }
  codesign -v --strict "$WORK/stage1" || return 1
  "$WORK/stage1" "$fixture" -o "$WORK/program" --pipeline typed --prelude >"$WORK/native-build.log" 2>&1 || { cat "$WORK/native-build.log"; touch "$WORK/invalid"; return 1; }
  codesign -v --strict "$WORK/program" || return 1
  for n in 1 2 3; do
    "$WORK/program" > "$WORK/native.out" 2>&1 || { cat "$WORK/native.out"; return 1; }
    cmp -s "$WORK/hosted.out" "$WORK/native.out" || { cat "$WORK/native.out"; return 1; }
  done
  "$WORK/stage1" "$fixture" -o "$WORK/port.ir" --pipeline typed --prelude --emit ir >"$WORK/emit.log" 2>&1 || return 1
  "$WORK/ir" translate "$WORK/port.ir" > "$WORK/port.ll" || return 1
  for ir in "$WORK/hosted.ll" "$WORK/port.ll"; do
    awk '/^define / { fn=$0; selected = (fn ~ /Array\(GcValue|Array\(GcBranch|Pointer\(GcValue|Pointer\(GcBranch|GcBranch#initialize/) } selected && /call.*__iyi_write_barrier\(/ { n++ } END { print n+0 }' "$ir"
  done > "$WORK/barrier-counts"
  hosted_count="$(sed -n '1p' "$WORK/barrier-counts")"
  port_count="$(sed -n '2p' "$WORK/barrier-counts")"
  [ "$hosted_count" -gt 0 ] && [ "$hosted_count" = "$port_count" ] || return 1
  /opt/homebrew/opt/llvm/bin/llc -O0 -filetype=obj -mtriple=arm64-apple-macosx "$WORK/port.ll" -o "$WORK/port.o" || return 1
  cc "$WORK/port.o" -o "$WORK/port-llvm" || return 1
  codesign -v --strict "$WORK/port-llvm" || return 1
  "$WORK/port-llvm" > "$WORK/port-llvm.out" 2>&1 || return 1
  cmp -s "$WORK/hosted.out" "$WORK/port-llvm.out"
}
if check_barriers; then
  echo "GC barrier: hosted/native/port-LLVM match, $hosted_count write-barrier sites each"
else
  echo 'FAIL: GC barrier runtime or IR parity'
  status=1
fi
prove_mutation 'same-type ivar stores bypass their barrier' "$REPO/src/compiler/lower/instance_var.iyi" \
  '  assign(low, ptr, ivar_t, value_type, value)' \
  '  store_aligned(low, value, ptr)' -- check_barriers || status=1
prove_mutation 'same-type pointer stores bypass their barrier' "$REPO/src/compiler/lower/primitives.iyi" \
  '      assign(low, values[0], target, actual, ref_stored)' \
  '      store_aligned(low, ref_stored, values[0])' -- check_barriers || status=1
if [ -e "$WORK/invalid" ]; then echo 'FAIL: mutation failed to build'; status=1; fi
exit "$status"
