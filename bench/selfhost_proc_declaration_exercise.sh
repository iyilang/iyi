#!/usr/bin/env bash
# Hosted and port must accept matching proc declarations, and reject bad inputs.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
REPO_NATIVE="$(native_path "$REPO")"
cd "$REPO"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK_NATIVE="$(native_path "$WORK")"
export IYI_PATH="$REPO_NATIVE/src"
export IYI_CACHE_DIR="$WORK_NATIVE/cache"
CRYSTAL_PATH="$REPO_NATIVE/src" IYI_CONFIG_PATH="$REPO_NATIVE/src" "${CRYSTAL:-crystal}" build -Di_know_what_im_doing -o "$WORK_NATIVE/oracle$EXE" "$REPO_NATIVE/bench/selfhost_typed_oracle.cr" > "$WORK/oracle.build" 2>&1 || { cat "$WORK/oracle.build"; exit 1; }
bin/iyi build -o "$WORK_NATIVE/typed$EXE" "$REPO_NATIVE/src/compiler/tools/typed_dump.iyi" > "$WORK/typed.build" 2>&1 || { cat "$WORK/typed.build"; exit 1; }
bin/iyi build -o "$WORK_NATIVE/native$EXE" "$REPO_NATIVE/src/compiler/tools/compile_native.iyi" > "$WORK/native.build" 2>&1 || { cat "$WORK/native.build"; exit 1; }
positive="$REPO_NATIVE/bench/fixtures/bodies_proc_decl_compatible.iyi"
negative="$REPO_NATIVE/bench/fixtures/bodies_proc_decl_incompatible.iyi"
"$WORK/oracle$EXE" "$positive" > "$WORK/hosted"
"$WORK/typed$EXE" "$positive" "$REPO_NATIVE/src" > "$WORK/port"
echo "HOSTED"; cat "$WORK/hosted"
echo "PORT"; cat "$WORK/port"
for line in 6 7; do
  expected=$(grep "^${line}:.* TypeDeclaration " "$WORK/hosted") || exit 1
  grep -Fx "$expected" "$WORK/port" || exit 1
done
if "$WORK/oracle$EXE" "$negative" > "$WORK/invalid-hosted" 2>&1; then
  echo 'Hosted accepted mismatched proc argument types' >&2; exit 1
fi
"$WORK/native$EXE" "$negative" -o "$WORK_NATIVE/out" --pipeline typed --probe-phase > "$WORK/invalid-port" 2>&1 || true
grep -F 'expected type' "$WORK/invalid-port" || { cat "$WORK/invalid-port"; exit 1; }
