#!/usr/bin/env bash
# Generated enum primitives have no written return annotation. Hosted and port
# must still type the primitive body as the enum base type.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh"
require_test_host
cd "$REPO"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
export IYI_CACHE_DIR="$WORK_NATIVE/cache"
export IYI_PATH="$REPO_NATIVE/src"
IYI="${IYI_COMPILER:-$REPO/bin/iyi}"
HOSTED_COMPILER="$REPO/bin/crystal"
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_typed_oracle.cr" > "$WORK/oracle.build" 2>&1 || { cat "$WORK/oracle.build"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/typed$EXE" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/typed.build" 2>&1 || { cat "$WORK/typed.build"; exit 1; }
fixture="$REPO_NATIVE/bench/fixtures/bodies_enum_primitive.iyi"
"$WORK/oracle$EXE" "$fixture" > "$WORK/hosted"
"$WORK/typed$EXE" "$fixture" "$REPO_NATIVE/src" > "$WORK/port"
for expected in '7:9 Call UInt8' '7:9 Var FiberState'; do
  grep -Fx "$expected" "$WORK/hosted" || { echo HOSTED; cat "$WORK/hosted"; exit 1; }
  grep -Fx "$expected" "$WORK/port" || { echo PORT; cat "$WORK/port"; exit 1; }
done
if grep -F 'primitive enum_value without a declared return type' "$WORK/port"; then
  echo 'Port still refused the generated enum primitive' >&2
  exit 1
fi
