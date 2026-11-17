#!/usr/bin/env bash
# Hosted and port must accept matching proc declarations, and reject bad inputs.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export IYI_CACHE_DIR="$WORK/cache"
CRYSTAL_PATH="$REPO/src" IYI_CONFIG_PATH="$REPO/src" "${CRYSTAL:-crystal}" build -Di_know_what_im_doing -o "$WORK/oracle" bench/selfhost_typed_oracle.cr > "$WORK/oracle.build" 2>&1 || { cat "$WORK/oracle.build"; exit 1; }
bin/iyi build -o "$WORK/typed" src/compiler/tools/typed_dump.iyi > "$WORK/typed.build" 2>&1 || { cat "$WORK/typed.build"; exit 1; }
bin/iyi build -o "$WORK/native" src/compiler/tools/compile_native.iyi > "$WORK/native.build" 2>&1 || { cat "$WORK/native.build"; exit 1; }
positive="$REPO/bench/fixtures/bodies_proc_decl_compatible.iyi"
negative="$REPO/bench/fixtures/bodies_proc_decl_incompatible.iyi"
"$WORK/oracle" "$positive" > "$WORK/hosted"
"$WORK/typed" "$positive" "$REPO/src" > "$WORK/port"
echo "HOSTED"; cat "$WORK/hosted"
echo "PORT"; cat "$WORK/port"
for line in 6 7; do
  expected=$(grep "^${line}:.* TypeDeclaration " "$WORK/hosted") || exit 1
  grep -Fx "$expected" "$WORK/port" || exit 1
done
if "$WORK/oracle" "$negative" > "$WORK/invalid-hosted" 2>&1; then
  echo 'Hosted accepted mismatched proc argument types' >&2; exit 1
fi
"$WORK/native" "$negative" -o "$WORK/out" --pipeline typed --probe-phase > "$WORK/invalid-port" 2>&1 || true
grep -F 'expected type' "$WORK/invalid-port" || { cat "$WORK/invalid-port"; exit 1; }
