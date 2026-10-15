#!/usr/bin/env bash
# Exercises `std/rsa`.
#
#     bash bench/std_rsa_exercise.sh
#
# The exercise holds signatures Python's cryptography made, encodings made
# by hand that break one rule each with the digest still matching, and keys
# that are not keys; this gate runs it plain and --release, holds 600
# signatures over six key sizes, both schemes, four hashes and the salt
# lengths PSS allows, half of them broken some way, to Python's verdicts,
# checks every RSA root certificate's signature with its own key as Python
# does, shows an error value's sentence through `.or_panic`, and proves on
# broken copies of the module that the checks fail where they say.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_rsa_exercise.iyi" \
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

echo "== the std/rsa exercise, plain build"
build_and_run "plain" rsa-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/rsa-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every rsa section reported"
for phrase in "== signatures Python's cryptography made" "== keys that are not keys"; do
  if ! grep -q "$phrase" "$WORK/rsa-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" rsa-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/rsa-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== 600 signatures held to Python's cryptography"
# Six keys, the odd sizes for PSS's short encoding; each signature over
# random bytes, half of them then broken: a bit of the message or of the
# signature, the wrong hash, the wrong salt length, the other scheme, a
# byte short, or the signature plus the modulus where that still fits.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import rsa' >/dev/null 2>&1; then
  echo "  no python cryptography here, so the signatures go uncompared"
else
  "$PY" - "$WORK/cases.txt" "$WORK/want.txt" <<'PY'
import os, random, sys
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
rng = random.Random(8017)
H = {"SHA1": hashes.SHA1(), "SHA256": hashes.SHA256(), "SHA384": hashes.SHA384(), "SHA512": hashes.SHA512()}
keys = [rsa.generate_private_key(public_exponent=e, key_size=bits)
        for bits, e in ((1024, 65537), (1025, 3), (2047, 65537), (2048, 65537), (3072, 65537), (4096, 65537))]
def pad(scheme, h, salt):
    return padding.PKCS1v15() if scheme == "v15" else padding.PSS(mgf=padding.MGF1(H[h]), salt_length=salt)
cases, want = [], []
for _ in range(600):
    k = rng.choice(keys)
    pub = k.public_key()
    n = pub.public_numbers().n
    size = (pub.key_size + 7) // 8
    h = rng.choice(list(H))
    scheme = rng.choice(["v15", "pss"])
    longest = (pub.key_size - 1 + 7) // 8 - H[h].digest_size - 2
    if scheme == "pss" and longest < 0:
        scheme = "v15"
    salt = rng.choice([0, min(H[h].digest_size, longest), longest]) if scheme == "pss" else -1
    msg = os.urandom(rng.randint(0, 200))
    sig = k.sign(msg, pad(scheme, h, salt), H[h])
    if rng.random() < 0.5:
        kind = rng.randrange(7)
        if kind == 0 and msg:
            at = rng.randrange(len(msg)); msg = msg[:at] + bytes([msg[at] ^ (1 << rng.randrange(8))]) + msg[at + 1:]
        elif kind == 1:
            at = rng.randrange(len(sig)); sig = sig[:at] + bytes([sig[at] ^ (1 << rng.randrange(8))]) + sig[at + 1:]
        elif kind == 2:
            h = rng.choice([x for x in H if x != h])
        elif kind == 3 and scheme == "pss":
            salt = salt + 1 if salt < longest else salt - 1
        elif kind == 4:
            scheme, salt = ("pss", H[h].digest_size) if scheme == "v15" else ("v15", -1)
        elif kind == 5:
            sig = sig[1:]
        elif kind == 6 and int.from_bytes(sig, "big") + n < 1 << (8 * size):
            sig = (int.from_bytes(sig, "big") + n).to_bytes(size, "big")
    spki = pub.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    try:
        if scheme == "pss" and salt > (pub.key_size - 1 + 7) // 8 - H[h].digest_size - 2:
            raise InvalidSignature()
        # RFC 8017's first step for either scheme: a signature that is not
        # k bytes is invalid. OpenSSL's PSS path takes a shorter one, padding
        # it with zeros - a 1025-bit key's signature often starts with 0x00,
        # so dropping that byte left one Python accepted - and this does not.
        if len(sig) != size:
            raise InvalidSignature()
        pub.verify(sig, msg, pad(scheme, h, salt), H[h]); verdict = "true"
    except (InvalidSignature, ValueError):
        verdict = "false"
    cases.append(f"{spki.hex()} {scheme} {h} {salt} {msg.hex()} {sig.hex()}")
    want.append(verdict)
open(sys.argv[1], "w").write("\n".join(cases) + "\n")
open(sys.argv[2], "w").write("\n".join(want) + "\n")
PY
  "$WORK/rsa-release" verify "$WORK/cases.txt" >"$WORK/got.txt" 2>&1
  if ! "$PY" - "$WORK/want.txt" "$WORK/got.txt" "$WORK/cases.txt" <<'PY'
import sys
want = open(sys.argv[1]).read().split()
got = open(sys.argv[2]).read().splitlines()
cases = open(sys.argv[3]).read().splitlines()
bad = [(i, w, g) for i, (w, g) in enumerate(zip(want, got)) if w != g]
if len(want) != len(got):
    bad.append((-1, f"{len(want)} answers", f"{len(got)} answers"))
if bad:
    print(f"  {len(bad)} of {len(want)} verdicts differ from Python's:")
    for i, w, g in bad[:6]:
        f = cases[i].split() if i >= 0 else ["?"] * 6
        print(f"    case {i}: {f[1]} {f[2]} salt {f[3]}: python {w}, iyi {g}")
    sys.exit(1)
print(f"  {len(want)} verdicts as Python's: {want.count('true')} signatures accepted, {want.count('false')} refused")
PY
  then
    status=1
  fi
fi

echo
echo "== every RSA root certificate's own signature"
BUNDLE=""
for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [ -f "$candidate" ]; then
    BUNDLE="$candidate"
    break
  fi
done
if [ -z "$PY" ] || [ -z "$BUNDLE" ] || ! "$PY" -c 'from cryptography import x509' >/dev/null 2>&1; then
  echo "  no python cryptography or no CA bundle here, so the roots go unchecked"
else
  mkdir -p "$WORK/der"
  "$PY" - "$BUNDLE" "$WORK/der" "$WORK/roots_want.txt" <<'PY'
import base64, re, sys, warnings
warnings.simplefilter("ignore")
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric import rsa
text = open(sys.argv[1], encoding="ascii", errors="replace").read()
lines = []
for i, body in enumerate(re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)):
    name = f"{i:04d}.der"
    der = base64.b64decode("".join(body.split()))
    open(f"{sys.argv[2]}/{name}", "wb").write(der)
    c = x509.load_der_x509_certificate(der)
    key = c.public_key()
    if not isinstance(key, rsa.RSAPublicKey) or c.signature_algorithm_oid.dotted_string not in (
            "1.2.840.113549.1.1.5", "1.2.840.113549.1.1.11", "1.2.840.113549.1.1.12", "1.2.840.113549.1.1.13", "1.2.840.113549.1.1.10"):
        lines.append(f"{name} skip"); continue
    try:
        key.verify(c.signature, c.tbs_certificate_bytes, c.signature_algorithm_parameters, c.signature_hash_algorithm)
        lines.append(f"{name} true")
    except InvalidSignature:
        lines.append(f"{name} false")
open(sys.argv[3], "w").write("\n".join(lines) + "\n")
PY
  "$WORK/rsa-release" roots "$WORK/der" >"$WORK/roots_got.txt" 2>&1
  if cmp -s "$WORK/roots_want.txt" "$WORK/roots_got.txt"; then
    echo "  $(grep -c ' true$' "$WORK/roots_got.txt") RSA roots verified with their own keys as Python verifies them, $(grep -c ' skip$' "$WORK/roots_got.txt") not RSA"
  else
    echo "  the roots' verdicts differ from Python's:"
    diff "$WORK/roots_want.txt" "$WORK/roots_got.txt" | head -6 | sed 's/^/    /'
    status=1
  fi
fi

echo
echo "== an error value's sentence, through .or_panic"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/rsa::{RsaPublicKey}

RsaPublicKey.from_spki([2_u8, 1_u8, 1_u8]).or_panic
puts "accepted"
IYI
if "$IYI" run "$WORK/refuse.iyi" >"$WORK/refuse.out" 2>&1; then
  echo "  an INTEGER was accepted as a key"
  status=1
elif ! grep -qF "rsa: asn1: expected a SEQUENCE, found INTEGER at offset 0" "$WORK/refuse.out"; then
  echo "  an INTEGER was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
  status=1
else
  echo "  rsa: asn1: expected a SEQUENCE, found INTEGER at offset 0"
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/rsa.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/rsa.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_rsa_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -qF -e "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "PKCS #1 v1.5 checked by its first two bytes" "expected false, got true" \
  '    em == expected' '    em[0, 2] == expected[0, 2]'
prove_broken "a signature past the modulus opened" "expected false, got true" \
  '    return nil unless s < @modulus' ''
prove_broken "a signature of any length opened" "expected false, got true" \
  '    return nil unless signature.size == @size' ''
prove_broken "PSS without its 0xBC" "expected false, got true" \
  '    return false unless em[em_len - 1] == 0xBC_u8' ''
prove_broken "PSS with its top bits unchecked" "expected false, got true" \
  '    return false unless top == 0 || em[0] >> (8 - top) == 0_u8' ''
prove_broken "PSS padding with any bytes" "expected false, got true" \
  '      return false unless db[i] == 0_u8' ''
prove_broken "MGF1's counter little-endian" "expected true, got false" \
  'block = seed + [(counter >> 24).to_u8, ((counter >> 16) & 0xFF_u32).to_u8,
                      ((counter >> 8) & 0xFF_u32).to_u8, (counter & 0xFF_u32).to_u8]' \
  'block = seed + [(counter & 0xFF_u32).to_u8, ((counter >> 8) & 0xFF_u32).to_u8,
                      ((counter >> 16) & 0xFF_u32).to_u8, (counter >> 24).to_u8]'
prove_broken "PSS encoded in the modulus's bits" "expected true, got false" \
  '    em_bits = @bits - 1' '    em_bits = @bits'
prove_broken "SHA-384's DigestInfo with SHA-256's OID" "expected true, got false" \
  '"3041300d060960864801650304020205000430"' '"3041300d060960864801650304020105000430"'
prove_broken "a salt of nothing when none is named" "a PSS salt as long as the hash when none is named" \
  's_len = salt_length || hash.size' 's_len = salt_length || 0'
prove_broken "an even modulus taken" "an even modulus refused" \
  '    return RsaError.new("an even modulus, which is no product of two odd primes") if n.even?' ''
prove_broken "an exponent of any size taken" "an exponent past 31 bits refused" \
  'if ebits > 31' 'if ebits > 64'
prove_broken "rsaEncryption's parameters unchecked" "rsaEncryption without its NULL refused" \
  'unless algorithm.size == 2 && algorithm[1].universal?(DerTag::NULL) && !algorithm[1].null.is_a?(Asn1Error)' 'if false'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/rsa exercise holds ($mutations breaks caught)"
else
  echo "the std/rsa exercise did not hold"
fi
exit $status
