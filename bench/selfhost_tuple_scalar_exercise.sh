#!/usr/bin/env bash
# Scalar tuple indexing against the hosted typed dump. Range indexing is later.
# Expectations are hosted's dump, not positions guessed from the source.
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
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_typed_oracle.cr" > "$WORK/oracle.build" 2>&1 || { cat "$WORK/oracle.build"; exit 1; }
"$IYI" build -o "$WORK_NATIVE/typed$EXE" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/typed.build" 2>&1 || { cat "$WORK/typed.build"; exit 1; }
fixture="$REPO_NATIVE/bench/fixtures/sem_bodies_tuple_scalar.iyi"
"$WORK/oracle$EXE" "$fixture" > "$WORK/hosted" 2> "$WORK/hosted.err" || { echo ORACLE; cat "$WORK/hosted.err"; exit 1; }
"$WORK/typed$EXE" "$fixture" "$REPO_NATIVE/src" > "$WORK/port" 2> "$WORK/port.err" || { echo PORT; cat "$WORK/port.err"; exit 1; }
# Hosted's actual call lines (s1d24 gate log), not the old guessed positions.
for expected in '30:10 Call Int32' '31:13 Call Int32' '32:12 Call UInt8' '33:10 Call Nil' '34:9 Call Int32'; do
  grep -Fx "$expected" "$WORK/hosted" || { echo "HOSTED missing $expected"; cat "$WORK/hosted"; exit 1; }
  grep -Fx "$expected" "$WORK/port" || { echo "PORT missing $expected"; cat "$WORK/port"; exit 1; }
done
if ! diff -q "$WORK/hosted" "$WORK/port" >/dev/null; then
  echo "scalar tuple dump differs from hosted"
  diff -u "$WORK/hosted" "$WORK/port"
  exit 1
fi
echo "sem_bodies_tuple_scalar.iyi matches hosted node by node"
