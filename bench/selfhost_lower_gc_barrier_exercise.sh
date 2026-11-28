#!/usr/bin/env bash
# Check concurrent marking and hosted write-barrier parity on live heap stores.
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
REPO_NATIVE="$(native_path "$REPO")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
WORK="$(mktemp -d)"
WORK_NATIVE="$(native_path "$WORK")" || exit 1
trap 'if [ "$status" -ne 0 ]; then echo "GC barrier logs: $WORK"; else rm -rf "$WORK"; fi' EXIT
. "$REPO/bench/lib/mutation.sh"
# The LLVM bridge reads its version, targets and link flags from build arguments this host supplies: read them once.
LLVM_BRIDGE_ARGS=()
llvm_bridge_text=$(llvm_bridge_build_args) || { echo "FAILED: no LLVM build arguments for this host, see the sentence above"; exit 1; }
while IFS= read -r llvm_arg; do LLVM_BRIDGE_ARGS+=("$llvm_arg"); done <<< "$llvm_bridge_text"
fixture="$REPO_NATIVE/bench/fixtures/low_gc_barrier.iyi"

# The port's typed pipeline targets Darwin AArch64. The hosted IR must use that
# ABI even when the hosted compiler and its executable run on another host.
"$IYI" build --emit llvm-ir --no-debug -o "$WORK_NATIVE/hosted$EXE" "$fixture" >"$WORK/hosted.log" 2>&1 || { cat "$WORK/hosted.log"; exit 1; }
if [ "$HOST_ID" = darwin-arm64 ]; then
  hosted_ir="$WORK/hosted.ll"
else
  "$IYI" build --cross-compile --target aarch64-apple-darwin --emit llvm-ir --no-debug \
    -o "$WORK_NATIVE/hosted-arm64.o" "$fixture" >"$WORK/hosted-arm64.log" 2>&1 || { cat "$WORK/hosted-arm64.log"; exit 1; }
  hosted_ir="$WORK/hosted-arm64.ll"
  host_limited "GC barrier: AArch64 Mach-O link, codesign, and runtime comparisons require macOS arm64 ($HOST_ID runs IR parity and object emission)"
fi
"$IYI" build "${LLVM_BRIDGE_ARGS[@]}" -o "$WORK_NATIVE/ir$EXE" "$REPO_NATIVE/src/compiler/tools/ir.iyi" >"$WORK/ir.log" 2>&1 || { cat "$WORK/ir.log"; exit 1; }
if [ "$HOST_OS" = darwin ]; then
  codesign -v --strict "$WORK/hosted$EXE" || exit 1
fi
"$WORK/hosted$EXE" > "$WORK/hosted.out" || exit 1
grep -qx 'OK' "$WORK/hosted.out" || exit 1

LLC="${LLC:-$(command -v llc || true)}"
if [ "$HOST_OS" = windows ]; then
  case "$LLC" in [A-Za-z]:[\\/]*) LLC="$(cygpath -u "$LLC")" || exit 1 ;; esac
fi
if [ -z "$LLC" ] && [ -n "${LLVM_CONFIG:-}" ]; then
  llvm_bin="$("$LLVM_CONFIG" --bindir)" || exit 1
  if [ "$HOST_OS" = windows ]; then llvm_bin="$(cygpath -u "$llvm_bin")" || exit 1; fi
  LLC="$llvm_bin/llc$EXE"
fi
if [ -z "$LLC" ] && [ "$HOST_OS" = windows ]; then
  for llvm_bin in "${LLVM_PATH:-}" "${ProgramFiles:+$ProgramFiles/LLVM}" "/c/Program Files/LLVM"; do
    [ -n "$llvm_bin" ] || continue
    case "$llvm_bin" in [A-Za-z]:[\\/]*) llvm_bin="$(cygpath -u "$llvm_bin")" || continue ;; esac
    if [ -x "$llvm_bin/bin/llc.exe" ]; then LLC="$llvm_bin/bin/llc.exe"; break; fi
  done
fi
if [ -z "$LLC" ] && [ "$HOST_OS" = darwin ] && [ -x /opt/homebrew/opt/llvm/bin/llc ]; then
  LLC=/opt/homebrew/opt/llvm/bin/llc
fi
if [ -z "$LLC" ] && [ "$HOST_OS" = windows ]; then
  # The Windows runner's LLVM is the Crystal package's libraries and the official installer's clang, neither with an
  # llc; the barrier counts and the native Mach-O link below still run.
  host_limited "GC barrier: the Darwin AArch64 object from the port's IR needs llc, which no LLVM on the Windows runner ships"
elif [ -z "$LLC" ]; then
  echo 'FAIL: llc is required to emit the Darwin AArch64 object' >&2
  exit 1
fi

check_barriers() {
  if ! "$IYI" build -o "$WORK_NATIVE/stage1$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" >"$WORK/build.log" 2>&1; then
    echo 'INVALID: GC barrier compiler did not build'
    cat "$WORK/build.log"
    return 2
  fi
  if [ "$HOST_OS" = darwin ] && ! codesign -v --strict "$WORK/stage1$EXE"; then
    echo 'INVALID: GC barrier compiler signature failed'
    return 2
  fi
  if ! "$WORK/stage1$EXE" "$fixture" -o "$WORK_NATIVE/port.ir" --pipeline typed --prelude --emit ir >"$WORK/emit.log" 2>&1; then
    echo 'INVALID: GC barrier compiler did not emit IR'
    cat "$WORK/emit.log"
    return 2
  fi
  if ! "$WORK/ir$EXE" translate "$WORK_NATIVE/port.ir" > "$WORK/port.ll" 2>"$WORK/translate.log"; then
    echo 'INVALID: emitted GC barrier IR could not be translated'
    cat "$WORK/translate.log"
    return 2
  fi
  for ir in "$hosted_ir" "$WORK/port.ll"; do
    awk '/^define / { fn=$0; selected = (fn ~ /Array\(GcValue|Array\(GcBranch|Pointer\(GcValue|Pointer\(GcBranch|GcBranch#initialize/) } selected && /call.*__iyi_write_barrier\(/ { n++ } END { print n+0 }' "$ir"
  done > "$WORK/barrier-counts"
  hosted_count="$(sed -n '1p' "$WORK/barrier-counts")"
  port_count="$(sed -n '2p' "$WORK/barrier-counts")"
  [ "$hosted_count" -gt 0 ] || { echo 'INVALID: hosted IR has no selected write-barrier sites'; return 2; }
  [ "$hosted_count" = "$port_count" ] || return 1
  if [ -n "$LLC" ] && ! "$LLC" -O0 -filetype=obj -mtriple=arm64-apple-macosx "$WORK_NATIVE/port.ll" -o "$WORK_NATIVE/port.o" >"$WORK/llc.log" 2>&1; then
    echo 'INVALID: LLVM failed to emit the port object'
    cat "$WORK/llc.log"
    return 2
  fi
  if ! "$WORK/stage1$EXE" "$fixture" -o "$WORK_NATIVE/program" --pipeline typed --prelude >"$WORK/native-build.log" 2>&1; then
    echo 'INVALID: GC barrier fixture did not link'
    cat "$WORK/native-build.log"
    return 2
  fi
  if [ "$HOST_ID" != darwin-arm64 ]; then return 0; fi
  codesign -v --strict "$WORK/program" || return 2
  for n in 1 2 3; do
    "$WORK/program" > "$WORK/native.out" 2>&1 || { cat "$WORK/native.out"; return 1; }
    cmp -s "$WORK/hosted.out" "$WORK/native.out" || { cat "$WORK/native.out"; return 1; }
  done
  cc "$WORK/port.o" -o "$WORK/port-llvm" || return 2
  codesign -v --strict "$WORK/port-llvm" || return 2
  "$WORK/port-llvm" > "$WORK/port-llvm.out" 2>&1 || return 1
  cmp -s "$WORK/hosted.out" "$WORK/port-llvm.out"
}
if check_barriers; then
  echo "GC barrier: $hosted_count hosted and port write-barrier sites match"
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
exit "$status"
