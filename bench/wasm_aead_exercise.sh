#!/usr/bin/env bash
# Run the native AEAD exercise on wasm32-wasi and prove SIMD checks can fail.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WASI_SDK_PATH="${WASI_SDK_PATH:-/opt/wasi-sdk}"
WASMTIME="${WASMTIME:-$HOME/.wasmtime/bin/wasmtime}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-aead-exercise.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export IYI_PATH="$REPO/src"

build_wasm() {
  local output="$1" source="$2" command
  shift 2
  command="$("$IYI" build --cross-compile --target wasm32-wasi "$@" -o "$output" "$source")"
  case "$command" in
    cc\ *) command="\"$WASI_SDK_PATH/bin/clang\" ${command#cc }" ;;
    *) echo "unexpected wasm link command: $command" >&2; return 1 ;;
  esac
  eval "$command -o \"$output.wasm\""
}

"$IYI" build -o "$WORK/native" "$REPO/bench/std_aead_exercise.iyi"
"$WORK/native" >"$WORK/native.out"
grep -qx 'ALL CHECKS PASSED' "$WORK/native.out"
for mode in plain plain-simd release release-simd; do
  flags=()
  case "$mode" in release*) flags+=(--release) ;; esac
  case "$mode" in *-simd) flags+=(--mattr +simd128) ;; esac
  build_wasm "$WORK/$mode" "$REPO/bench/std_aead_exercise.iyi" "${flags[@]}"
  "$WASMTIME" "$WORK/$mode.wasm" >"$WORK/$mode.out"
  cmp "$WORK/native.out" "$WORK/$mode.out"
  grep -qx 'ALL CHECKS PASSED' "$WORK/$mode.out"
  echo "$mode: native output identical, ALL CHECKS PASSED"
done

# This 128-byte vector exercises both lanes. The expected value was generated
# with Python cryptography's AESGCM, independently of the implementation here.
cat >"$WORK/lanes.iyi" <<'IYI'
@[Unsafe("decodes a fixed known-answer vector")]
import std/aead::{AesGcm, AeadError}
def unhex(hex : String) : String
  p = hex.to_unsafe
  String.new(hex.bytesize // 2) do |dst|
    i = 0
    while i < hex.bytesize // 2
      hi = p[i * 2].to_i32
      lo = p[i * 2 + 1].to_i32
      hi = hi >= 97 ? hi - 87 : hi - 48
      lo = lo >= 97 ? lo - 87 : lo - 48
      dst[i] = (hi * 16 + lo).to_u8
      i = i + 1
    end
  end
end
key = unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
nonce = unhex("000102030405060708090a0b")
aad = unhex("7761736d2d6c616e6573")
plain = unhex("0726456483a2c1e0ff1e3d5c7b9ab9d8f71635547392b1d0ef0e2d4c6b8aa9c8e70625446382a1c0dffe1d3c5b7a99b8d7f61534537291b0cfee0d2c4b6a89a8c7e60524436281a0bfdefd1c3b5a7998b7d6f51433527190afceed0c2b4a6988a7c6e504234261809fbeddfc1b3a597897b6d5f4133251708faecdec0b2a4968")
want = unhex("4024937f464703fb725faad7ca73c1b574c0b26083e9eeacd769c8c976e3a97ae6168bb8cc43b358ab5a62d1d3fdb18039af75b909a4326af079273553897c4637dac35e90b3a7c1a38a5772d4d577708f5c3c76453122f8523373c053bad0056c3ebce28703a99a01a2e34e534f78072dd1b75ff0f774eac2519a2189cc2766b76c37a3964139b9edcede2702ff77fe")
box = AesGcm.new(key)
raise "ASSERTION FAILED: gcm eight-block lane seal" unless box.seal(nonce, plain, aad) == want
opened = box.open(nonce, want, aad)
raise "ASSERTION FAILED: gcm eight-block lane open" unless opened.is_a?(String) && opened == plain
puts "ALL CHECKS PASSED"
IYI
build_wasm "$WORK/lanes" "$WORK/lanes.iyi" --release --mattr +simd128
"$WASMTIME" "$WORK/lanes.wasm" >"$WORK/lanes.out"
grep -qx 'ALL CHECKS PASSED' "$WORK/lanes.out"
echo 'eight-block lane vector: independent AES-GCM ciphertext matched'

if python3 -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305; from cryptography.hazmat.primitives.poly1305 import Poly1305' >/dev/null 2>&1; then
  # Extract the existing native driver's oracle verbatim, so both exercises
  # receive the same deterministic 8,000 cases and comparison rules.
  python3 - "$REPO/bench/std_aead_exercise.sh" "$WORK" <<'PYEXTRACT'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
work = pathlib.Path(sys.argv[2])
for name, start, end in [
    ("oracle.iyi", "  cat >\"$WORK/oracle.iyi\" <<'IYI'\n", "\nIYI\n"),
    ("generate.py", "  if ! \"$PY\" - \"$WORK\" <<'PY'\n", "\nPY\n"),
    ("compare.py", "  elif ! \"$PY\" - \"$WORK\" <<'PY'\n", "\nPY\n"),
]:
    assert source.count(start) == 1, f"oracle marker missing or duplicated: {name}"
    work.joinpath(name).write_text(source.split(start, 1)[1].split(end, 1)[0] + "\n")
PYEXTRACT
  python3 "$WORK/generate.py" "$WORK"
  build_wasm "$WORK/oracle" "$WORK/oracle.iyi" --release --mattr +simd128
  "$WASMTIME" "$WORK/oracle.wasm" <"$WORK/cases.txt" >"$WORK/oracle.out"
  python3 "$WORK/compare.py" "$WORK"
else
  echo 'SKIPPED: Python cryptography is unavailable; 3,000 AES-GCM and 3,000 ChaCha20-Poly1305 oracle cases were not run' >&2
fi

prove_broken() {
  local label="$1" section="$2" old="$3" replacement="$4" source="${5:-$REPO/bench/std_aead_exercise.iyi}" exit_code
  mkdir -p "$WORK/broken/std"
  python3 - "$REPO/src/std/aead.iyi" "$WORK/broken/std/aead.iyi" "$section" "$old" "$replacement" <<'PYMUTATE'
import pathlib, sys
source, target, section, old, replacement = sys.argv[1:]
text = pathlib.Path(source).read_text()
prefix, marker, tail = text.partition(section)
if not marker or old not in tail:
    raise SystemExit("mutation site missing: " + section)
target = pathlib.Path(target)
target.write_text(prefix + marker + tail.replace(old, replacement, 1))
PYMUTATE
  IYI_PATH="$WORK/broken:$REPO/src" build_wasm "$WORK/broken-program" "$source" --release --mattr +simd128
  set +e
  "$WASMTIME" "$WORK/broken-program.wasm" >"$WORK/broken.out" 2>&1
  exit_code=$?
  set -e
  if [ "$exit_code" -eq 0 ] || grep -q 'ALL CHECKS PASSED' "$WORK/broken.out"; then
    echo "FAIL: $label mutation escaped" >&2; exit 1
  fi
  grep -q 'ASSERTION FAILED: gcm' "$WORK/broken.out" || { echo "FAIL: $label failed before an AEAD assertion" >&2; cat "$WORK/broken.out" >&2; exit 1; }
  echo "$label: caught (exit $exit_code)"
}
prove_broken 'SIMD S-box gate' 'def self.simd_sbox' 's6 = t56 ^ ~t62' 's6 = t56 ^ t62'
prove_broken 'SIMD MixColumns rotation' 'def self.simd_rows_up' 'simd_rotr(x, 20)' 'simd_rotr(x, 21)'
prove_broken 'SIMD second-lane pairing' 'def self.encrypt_simd' 'UInt64x2.new(low[i], high[i])' 'UInt64x2.new(low[i], low[i])' "$WORK/lanes.iyi"
echo 'ALL WASM AEAD CHECKS PASSED'
