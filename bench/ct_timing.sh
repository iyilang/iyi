#!/usr/bin/env bash
# A dudect-style timing check of std's secret paths (bench/ct_timing.iyi
# says how): std/big's `inverse_mod_secret`, std/rsa's `sign_pss`, P-256
# and P-384 signing, Ed25519 signing, X25519, ML-KEM-768 decapsulation
# (valid against tampered ciphertexts, one key against others) and the
# AEADs' tag checks, one class against another, interleaved, Welch's t
# between the two. Then the extended Euclid's
# algorithm std/rsa used to invert its blinding factor, which leaks, so that
# a run that cannot see a leak says so instead of passing.
#
#     bash bench/ct_timing.sh            # the default sample counts
#     CT_SCALE=4 bash bench/ct_timing.sh # four times as many
#
# Fails loudly when a secret path's |t| is over 10, or the leaky Euclid's
# is not. A tool, not a gate: run it by hand on a quiet machine (here,
# inside ~/.cache/heavy.sh). CI does not run it, and should not - on a
# shared runner another job's load lands on one class more than the other
# often enough to put |t| past 10 with nothing leaking. An RSA key is made
# with openssl or Python's cryptography; with neither, the RSA path is
# skipped with a sentence.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
SCALE="${CT_SCALE:-1}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export IYI_PATH="$REPO/src"

if ! "$IYI" build --release -o "$WORK/ct" "$REPO/bench/ct_timing.iyi" >"$WORK/build.log" 2>&1; then
  echo "FAIL: bench/ct_timing.iyi did not build"
  sed -n '1,12p' "$WORK/build.log"
  exit 1
fi

key=""
if command -v openssl >/dev/null 2>&1 && openssl genrsa -out "$WORK/k.pem" 2048 >/dev/null 2>&1; then
  key="$WORK/k.pem"
elif command -v python3 >/dev/null 2>&1 && python3 -c '
import sys
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
open(sys.argv[1], "wb").write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
' "$WORK/k.pem" >/dev/null 2>&1; then
  key="$WORK/k.pem"
fi

status=0
# t_of <target> <samples> [pem]: the largest |t| the program printed.
t_of() {
  local line
  if ! line="$("$WORK/ct" "$@" 2>&1)"; then
    echo "  FAIL: $1 did not run: $line" >&2
    echo 999
    return
  fi
  echo "  $line" >&2
  echo "$line" | sed 's/.*max |t| = \([0-9.]*\).*/\1/'
}
over() { awk -v t="$1" 'BEGIN { exit !(t > 10) }'; }

echo "== secret paths: |t| must stay at or under 10"
for pair in "inverse:$((100000 * SCALE))" "p256:$((100000 * SCALE))" "p384:$((50000 * SCALE))" "ed25519:$((100000 * SCALE))" \
  "x25519:$((100000 * SCALE))" "mlkem-ct:$((50000 * SCALE))" "mlkem-key:$((50000 * SCALE))" "aes-gcm:$((100000 * SCALE))" \
  "chacha:$((100000 * SCALE))" "rsa:$((20000 * SCALE))"; do
  target="${pair%%:*}"
  samples="${pair#*:}"
  if [ "$target" = rsa ] && [ -z "$key" ]; then
    echo "  no openssl and no Python cryptography to make an RSA key, so sign_pss goes untimed"
    continue
  fi
  t="$(t_of "$target" "$samples" $([ "$target" = rsa ] && echo "$key"))"
  if over "$t"; then
    echo "  FAIL: $target's time tells its classes apart, |t| = $t"
    status=1
  fi
done

echo
echo "== the leak the check has to see: the old extended Euclid inverse"
t="$(t_of euclid $((5000 * SCALE)))"
if over "$t"; then
  echo "  seen, |t| = $t"
else
  echo "  FAIL: the Euclid inverse's leak went unseen (|t| = $t), so the numbers above prove nothing"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "no secret path's time told its classes apart, and the leaky one's did"
else
  echo "TIMING CHECK FAILED"
fi
exit "$status"
