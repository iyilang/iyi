#!/usr/bin/env bash
# Exercises `std/crypto`.
#
#     bash bench/std_crypto_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# the patches and oracles below are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it, so
# the interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from `pwd` is `/c/...` and finds no prelude at all, and a
# scratch directory named `/tmp/tmp.X` is silently ignored on that path, so
# the patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_crypto_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/crypto exercise, plain build"
build_and_run "plain" crypto-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/crypto-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every crypto section reported"
for phrase in "== hmac" "== hmac streaming" "== hkdf" "== pbkdf2" "== constant-time compare"; do
  if ! grep -q "$phrase" "$WORK/crypto-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" crypto-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/crypto-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what crypto refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/digest::{SHA256}
import std/crypto::{HMAC, HKDF, PBKDF2}

case Program.args[0]
when "final-twice"
  mac = HMAC.new(SHA256, "key")
  mac.final
  mac.final
when "update-after-final"
  mac = HMAC.new(SHA256, "key")
  mac.final
  mac.update("more")
when "short-buffer"
  HMAC.new(SHA256, "key").final(Array(UInt8).new(31, 0_u8))
when "hkdf-too-long"
  HKDF.expand(SHA256, "prk", "", 255 * 32 + 1)
when "hkdf-negative"
  HKDF.expand(SHA256, "prk", "", -1)
when "pbkdf2-no-iterations"
  PBKDF2.derive(SHA256, "password", "salt", 0, 32)
when "pbkdf2-no-length"
  PBKDF2.derive(SHA256, "password", "salt", 1, 0)
end
puts "accepted"
IYI
refuse() { # refuse <case> <phrase>
  if "$IYI" run "$WORK/refuse.iyi" -- "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qF "$2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  else
    echo "  $1: $(tr -d '\r' <"$WORK/refuse.out" | grep -oF "$2" | head -1)"
  fi
}
refuse final-twice "HMAC: final called twice; reset first"
refuse update-after-final "HMAC: update after final; reset first"
refuse short-buffer "31 bytes cannot hold a 32-byte MAC"
refuse hkdf-too-long "cannot expand to 8161 bytes; the most is 255 * 32 = 8160"
refuse hkdf-negative "cannot expand to -1 bytes"
refuse pbkdf2-no-iterations "the iteration count must be at least 1, not 0"
refuse pbkdf2-no-length "the key length must be at least 1 byte, not 0"

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
prove_broken() {
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/crypto.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/crypto.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_crypto_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
# A key longer than a block cut to the block, rather than hashed: only
# RFC 4231's cases 6 and 7 have one.
prove_broken "a long key cut to a block" "case 6" \
  '    if count > block
      @inner.update(bytes, count)
      @inner.final(pad)
      @inner.reset
    else
      pad.to_unsafe.copy_from(bytes, count)
' '    pad.to_unsafe.copy_from(bytes, count > block ? block : count)
    if false
'
prove_broken "HMAC's two pads the same" "hmac-md5 case 1" \
  '(0x36_u8 ^ 0x5c_u8)' '0_u8'
# Each block after the first starts from the one before it: case 1's 42
# bytes are two blocks, and its second half is where that shows.
prove_broken "HKDF blocks that do not chain" "case 1 okm" \
  '      mac.update(block.to_unsafe, size) if n > 1
' ''
prove_broken "PBKDF2 keeping the last round alone" "4096 iterations" \
  '          t[i] = t[i] ^ u[i]' '          t[i] = u[i]'
prove_broken "PBKDF2 numbering its blocks from zero" "sha1, 1 iteration" \
  '    block = 1
    while done < length' '    block = 0
    while done < length'
prove_broken "a comparison that keeps only the last byte's difference" "first byte differs" \
  'diff = diff | (pa[i] ^ pb[i])' 'diff = pa[i] ^ pb[i]'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/crypto exercise holds"
else
  echo "the std/crypto exercise did not hold"
fi
exit $status
