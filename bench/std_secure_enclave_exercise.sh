#!/usr/bin/env bash
# Exercises std/secure_enclave. No keychain-persistent keys are created.
# On macOS with an enclave this runs the hardware and resident-memory checks;
# on a Mac without one it checks the named unavailable error. Other targets
# must refuse the import at compile time.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac
export IYI_PATH="$REPO/src"

cat >"$WORK/import.iyi" <<'IYI'
import std/secure_enclave::{SecureEnclave}
puts SecureEnclave.available?
IYI

refusal='std/secure_enclave requires macOS and its Secure Enclave; this target is not darwin'
refuse() {
  local label="$1"; shift
  if "$IYI" build "$@" -o "$WORK/refusal-$label" "$WORK/import.iyi" >"$WORK/refusal-$label.log" 2>&1; then
    echo "FAIL: $label accepted an unsupported import"
    return 1
  fi
  if ! grep -Fq "$refusal" "$WORK/refusal-$label.log"; then
    echo "FAIL: $label did not name the unsupported platform"
    tail -20 "$WORK/refusal-$label.log"
    return 1
  fi
  echo "  $label: refused with expected sentence"
}

case "$(uname -s)" in
  Darwin) ;;
  *)
    echo '== native unsupported-platform import'
    refuse native || exit 1
    echo 'ALL CHECKS PASSED (macOS-only module refused)'
    exit 0
    ;;
esac

# Cross-target the real importer as well as the machine's ordinary native build.
echo '== unsupported Linux, Windows and WASI targets'
for target in x86_64-linux-gnu aarch64-linux-gnu x86_64-windows-msvc x86_64-windows-gnu wasm32-wasi; do
  refuse "$target" --cross-compile --target "$target" || exit 1
done

echo '== Darwin enclave exercise (plain and --release)'
for mode in plain release; do
  args=()
  [ "$mode" = release ] && args+=(--release)
  if ! "$IYI" build "${args[@]}" -o "$WORK/$mode" "$REPO/bench/std_secure_enclave_exercise.iyi" >"$WORK/$mode.build.log" 2>&1; then
    echo "FAIL: $mode build"
    tail -30 "$WORK/$mode.build.log"
    exit 1
  fi
  if ! "$WORK/$mode" </dev/null >"$WORK/$mode.out" 2>&1; then
    echo "FAIL: $mode exercise"
    cat "$WORK/$mode.out"
    exit 1
  fi
  sed 's/^/  /' "$WORK/$mode.out"
  grep -Fq 'ALL CHECKS PASSED' "$WORK/$mode.out" || { echo "FAIL: $mode lacks success line"; exit 1; }
  if ! grep -Fq 'enclave-dependent checks skipped' "$WORK/$mode.out" &&
     ! grep -Fq 'generated-key handles: three unattended restore/sign checks passed' "$WORK/$mode.out"; then
    echo "FAIL: $mode did not exercise unattended generated-key restoration"; exit 1
  fi
done

echo '== the module through its .iyimod artifact'
mkdir -p "$WORK/mods"
if ! "$IYI" build --emit-iyimod "$WORK/mods" -o "$WORK/from-source" "$REPO/bench/std_secure_enclave_exercise.iyi" >"$WORK/emit.log" 2>&1; then
  echo 'FAIL: artifact producer'; tail -30 "$WORK/emit.log"; exit 1
fi
if ! "$IYI" build --use-iyimod "$WORK/mods" -o "$WORK/from-artifact" "$REPO/bench/std_secure_enclave_exercise.iyi" >"$WORK/use.log" 2>&1; then
  echo 'FAIL: artifact consumer'; tail -30 "$WORK/use.log"; exit 1
fi
if ! "$WORK/from-artifact" </dev/null >"$WORK/artifact.out" 2>&1; then
  echo 'FAIL: artifact exercise'; cat "$WORK/artifact.out"; exit 1
fi
if ! cmp -s "$WORK/plain.out" "$WORK/artifact.out"; then
  echo 'FAIL: source and artifact answered differently'; diff -u "$WORK/plain.out" "$WORK/artifact.out"; exit 1
fi
echo '  source and artifact exercised with identical output'

if grep -Fq 'enclave-dependent checks skipped' "$WORK/plain.out"; then
  grep -Fq 'enclave-dependent checks skipped' "$WORK/release.out" || { echo 'FAIL: availability changed between builds'; exit 1; }
  echo '  No enclave on this host: hardware, memory and hardware-dependent mutations not exercised.'
  echo 'ALL CHECKS PASSED (unavailable-enclave path)'
  exit 0
fi

echo '== 1,000 hardware generate, sign and release cycles'
if ! "$WORK/plain" memory >"$WORK/memory.out" 2>&1; then
  cat "$WORK/memory.out"
  echo 'FAIL: resident-memory check'
  exit 1
fi
cat "$WORK/memory.out"
grep -Fq '1000 generate, sign and native release cycles: PASS' "$WORK/memory.out" || exit 1

# Change exactly one source expression in a fresh IYI_PATH overlay, and
# require the intended named behavioral failure rather than a build failure.
PY=''
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then PY="$candidate"; break; fi
done
[ -n "$PY" ] || { echo 'FAIL: Python is required for mutation proofs'; exit 1; }
mutate() {
  local name="$1"; mkdir -p "$WORK/$name/std"
  "$PY" - "$REPO/src/std/secure_enclave.iyi" "$WORK/$name/std/secure_enclave.iyi" "$name" <<'PY'
import pathlib, sys
src, dst, name = map(pathlib.Path, sys.argv[1:])
text = src.read_text()
mutations = {
    'algorithm': ('kSecKeyAlgorithmECDSASignatureMessageX962SHA256',
                  'kSecKeyAlgorithmECDSASignatureMessageX962SHA384'),
    'leak': ('public_key = LibEnclaveSecurity.SecKeyCopyPublicKey(key)\n    LibEnclaveCF.CFRelease(key)',
             'public_key = LibEnclaveSecurity.SecKeyCopyPublicKey(key)\n    # Mutation: do not release key.'),
    'unavailable': ('key = LibEnclaveSecurity.SecKeyCreateRandomKey(attrs, pointerof(error))',
                    'key = SecureEnclaveNative.null'),
}
old, new = mutations[str(name)]
expected = 1
if text.count(old) != expected:
    raise SystemExit(f'{name}: expected {expected} mutation sites, found {text.count(old)}')
dst.write_text(text.replace(old, new, 1))
if dst.read_text() == text:
    raise SystemExit(f'{name}: source did not change')
print(f'  {name}: mutated exactly one source site')
PY
}

build_mutant() {
  local name="$1"
  mutate "$name" || return 1
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src" "$IYI" build -o "$WORK/$name/program" "$REPO/bench/std_secure_enclave_exercise.iyi" >"$WORK/$name/build.log" 2>&1; then
    echo "FAIL: $name mutant did not build"
    tail -30 "$WORK/$name/build.log"
    return 1
  fi
}

echo '== prove the verifier catches the wrong signing algorithm'
build_mutant algorithm || exit 1
if "$WORK/algorithm/program" >"$WORK/algorithm/out" 2>&1; then
  echo 'FAIL: wrong-algorithm mutant passed'; exit 1
fi
if ! grep -Fq 'pure iyi signature verification 0' "$WORK/algorithm/out"; then
  echo 'FAIL: wrong-algorithm mutant failed somewhere else'; cat "$WORK/algorithm/out"; exit 1
fi
echo '  wrong SHA-384 signing algorithm: pure iyi rejected the first signature'

echo '== prove absence is reported when generation is unavailable'
build_mutant unavailable || exit 1
if ! "$WORK/unavailable/program" >"$WORK/unavailable/out" 2>&1 || ! grep -Fq 'ALL CHECKS PASSED (enclave-dependent checks skipped)' "$WORK/unavailable/out"; then
  echo 'FAIL: unavailable-enclave mutant'; cat "$WORK/unavailable/out"; exit 1
fi
sed 's/^/  /' "$WORK/unavailable/out"

echo '== prove the resident-memory check catches a missing SecKey release'
build_mutant leak || exit 1
if "$WORK/leak/program" memory >"$WORK/leak/out" 2>&1; then
  echo 'FAIL: missing-release mutant passed'; cat "$WORK/leak/out"; exit 1
fi
if ! grep -Fq 'resident memory grew beyond 1600000 bytes' "$WORK/leak/out"; then
  echo 'FAIL: missing-release mutant failed somewhere else'; cat "$WORK/leak/out"; exit 1
fi
sed 's/^/  /' "$WORK/leak/out"
echo '  missing native key release: resident-memory guard failed as expected'
echo 'ALL CHECKS PASSED'
