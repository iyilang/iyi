#!/usr/bin/env bash
# Compare external-variable address typing and ordinary function refusal with hosted.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh"
require_test_host
cd "$REPO"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
export IYI_CACHE_DIR="$WORK_NATIVE/cache" IYI_PATH="$REPO_NATIVE/src"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
HOSTED_COMPILER="$REPO/bin/crystal"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_typed_oracle.cr"
"$IYI" build -o "$WORK_NATIVE/typed$EXE" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi"
positive="$REPO_NATIVE/bench/fixtures/bodies_external_var_address.iyi"
negative="$REPO_NATIVE/bench/fixtures/bodies_pointer_function_call.iyi"
"$WORK/oracle$EXE" "$positive" > "$WORK/hosted"
"$WORK/typed$EXE" "$positive" "$REPO_NATIVE/src" > "$WORK/port"
for expected in '7:1 PointerOf Pointer(Int32)' '8:1 PointerOf Pointer(Pointer(UInt8))'; do
  grep -Fx "$expected" "$WORK/hosted"
  grep -Fx "$expected" "$WORK/port"
done
if "$WORK/oracle$EXE" "$negative" > "$WORK/invalid-hosted" 2>&1; then
  echo 'Hosted accepted pointerof an ordinary function call' >&2
  exit 1
fi
"$WORK/typed$EXE" "$negative" "$REPO_NATIVE/src" > "$WORK/invalid-port"
grep -F 'untyped: pointerof of' "$WORK/invalid-port"
if grep -F 'PointerOf Pointer(' "$WORK/invalid-port"; then
  echo 'Port accepted pointerof an ordinary function call' >&2
  exit 1
fi
