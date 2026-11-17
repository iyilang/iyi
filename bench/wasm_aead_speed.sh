#!/usr/bin/env bash
# Compare scalar and SIMD AES-256-GCM against WebCrypto in headless Chrome.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
IYI_CHROME="${IYI_CHROME:?set IYI_CHROME to an isolated headless Chrome executable}"
SIZES="${IYI_AEAD_MIB:-1,16,64}"
[[ "$SIZES" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || { echo 'IYI_AEAD_MIB must be comma-separated positive MiB sizes' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-aead-speed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export IYI_PATH="$REPO/src"
for name in scalar simd; do
  flags=()
  [ "$name" != simd ] || flags+=(--mattr +simd128)
  PATH="$WASI_SDK_PATH/bin:$PATH" "$IYI" build --target wasm32-unknown-unknown --release -D iyi_aead_bench "${flags[@]}" -o "$WORK/$name.wasm" "$REPO/bench/wasm_aead_speed.iyi"
done
cp "$REPO/src/iyi/wasm/iyi.mjs" "$WORK/iyi.mjs"
cp "$REPO/bench/wasm_aead_speed.mjs" "$WORK/wasm_aead_speed.mjs"
printf '{"sizes":[%s]}\n' "$SIZES" >"$WORK/aead-config.json"
node "$REPO/bench/wasm_browser.mjs" --chrome "$IYI_CHROME" --root "$WORK" --script wasm_aead_speed.mjs --timeout 1200000
