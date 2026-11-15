#!/usr/bin/env bash
# Exercises `std/ecdsa`.
#
#     bash bench/std_ecdsa_exercise.sh
#
# The exercise holds signatures Python's cryptography made on P-256, P-384
# and P-521, signatures made by hand that break one rule each, keys whose
# private value is 1 and n - 1, and keys that are not keys; this gate runs
# it plain and --release, holds 600 signatures over the three curves and
# three hashes, most of them broken some way, to Python's verdicts, checks
# every ECDSA root certificate's signature with its own key as Python does,
# shows an error value's sentence through `.or_panic`, reads in the IR how
# P-256's table of G's multiples reaches a second thread, and proves on
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_ecdsa_exercise.iyi" \
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

echo "== the std/ecdsa exercise, plain build"
build_and_run "plain" ec-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/ec-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every ecdsa section reported"
for phrase in "== signatures Python's cryptography made" "== keys that are not keys"; do
  if ! grep -q "$phrase" "$WORK/ec-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" ec-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/ec-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== 600 signatures held to Python's cryptography"
# Each signature over random bytes on a random curve under a random hash;
# most then broken: a bit of the message or of the signature, the wrong
# hash, s past n, another key on the same curve, a byte short, r and s
# swapped. And n - s, the other valid signature, which is taken.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import ec' >/dev/null 2>&1; then
  echo "  no python cryptography here, so the signatures go uncompared"
else
  "$PY" - "$WORK/cases.txt" "$WORK/want.txt" <<'PY'
import os, random, sys
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature
H = {"SHA256": hashes.SHA256(), "SHA384": hashes.SHA384(), "SHA512": hashes.SHA512()}
N = {
    "secp256r1": 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551,
    "secp384r1": 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973,
    "secp521r1": int("01fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51868783bf2f966b7fcc0148f709a5d03bb5c9b8899c47aebb6fb71e91386409", 16),
}
rng = random.Random(int.from_bytes(os.urandom(8), "big"))
keys = [ec.generate_private_key(c) for c in (ec.SECP256R1(), ec.SECP384R1(), ec.SECP521R1()) for _ in range(2)]
cases, want = [], []
for i in range(600):
    at = rng.randrange(len(keys))
    key = keys[at]
    pub = key.public_key()
    other = keys[at ^ 1].public_key()
    h = rng.choice(list(H))
    msg = os.urandom(rng.randrange(0, 200))
    sig = key.sign(msg, ec.ECDSA(H[h]))
    n = N[key.curve.name]
    kind = rng.randrange(9)
    if kind == 0 and msg:
        b = bytearray(msg); b[rng.randrange(len(b))] ^= 1 << rng.randrange(8); msg = bytes(b)
    elif kind == 1:
        b = bytearray(sig); b[rng.randrange(len(b))] ^= 1 << rng.randrange(8); sig = bytes(b)
    elif kind == 2:
        h = rng.choice([x for x in H if x != h])
    elif kind == 3:
        r, s = decode_dss_signature(sig); sig = encode_dss_signature(r, n - s)
    elif kind == 4:
        r, s = decode_dss_signature(sig); sig = encode_dss_signature(r, s + n)
    elif kind == 5:
        pub = other
    elif kind == 6:
        sig = sig[:-1]
    elif kind == 7:
        r, s = decode_dss_signature(sig); sig = encode_dss_signature(s, r)
    spki = pub.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    try:
        pub.verify(sig, msg, ec.ECDSA(H[h])); verdict = "true"
    except InvalidSignature:
        verdict = "false"
    cases.append(f"{spki.hex()} {h} {msg.hex()} {sig.hex()}")
    want.append(verdict)
open(sys.argv[1], "w").write("\n".join(cases) + "\n")
open(sys.argv[2], "w").write("\n".join(want) + "\n")
PY
  "$WORK/ec-release" verify "$WORK/cases.txt" >"$WORK/got.txt" 2>&1
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
        f = cases[i].split() if i >= 0 else ["?"] * 4
        print(f"    case {i}: {f[1]} signature {f[3] if len(f) > 3 else ''}: python {w}, iyi {g}")
    sys.exit(1)
print(f"  {len(want)} verdicts as Python's: {want.count('true')} signatures accepted, {want.count('false')} refused")
PY
  then
    status=1
  fi
fi

echo
echo "== every ECDSA root certificate's own signature"
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
from cryptography.hazmat.primitives.asymmetric import ec
text = open(sys.argv[1], encoding="ascii", errors="replace").read()
lines = []
for i, body in enumerate(re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)):
    name = f"{i:04d}.der"
    der = base64.b64decode("".join(body.split()))
    open(f"{sys.argv[2]}/{name}", "wb").write(der)
    c = x509.load_der_x509_certificate(der)
    key = c.public_key()
    if not isinstance(key, ec.EllipticCurvePublicKey) or key.curve.name not in ("secp256r1", "secp384r1", "secp521r1") \
            or c.signature_algorithm_oid.dotted_string not in ("1.2.840.10045.4.3.2", "1.2.840.10045.4.3.3", "1.2.840.10045.4.3.4"):
        lines.append(f"{name} skip"); continue
    try:
        key.verify(c.signature, c.tbs_certificate_bytes, ec.ECDSA(c.signature_hash_algorithm))
        lines.append(f"{name} true")
    except InvalidSignature:
        lines.append(f"{name} false")
open(sys.argv[3], "w").write("\n".join(lines) + "\n")
PY
  "$WORK/ec-release" roots "$WORK/der" >"$WORK/roots_got.txt" 2>&1
  if cmp -s "$WORK/roots_want.txt" "$WORK/roots_got.txt"; then
    echo "  $(grep -c ' true$' "$WORK/roots_got.txt") ECDSA roots verified with their own keys as Python verifies them, $(grep -c ' skip$' "$WORK/roots_got.txt") not ECDSA"
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

import std/ecdsa::{EcdsaPublicKey}

EcdsaPublicKey.from_spki([2_u8, 1_u8, 1_u8]).or_panic
puts "accepted"
IYI
if "$IYI" run "$WORK/refuse.iyi" >"$WORK/refuse.out" 2>&1; then
  echo "  an INTEGER was accepted as a key"
  status=1
elif ! grep -qF "ecdsa: asn1: expected a SEQUENCE, found INTEGER at offset 0" "$WORK/refuse.out"; then
  echo "  an INTEGER was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
  status=1
else
  echo "  ecdsa: asn1: expected a SEQUENCE, found INTEGER at offset 0"
fi

echo
echo "== how a table's address reaches a second thread, read off the IR"
# P-256's table of G's odd multiples is worked out by the first check that
# wants it, and a second thread must never read it part written: a good
# signature would be refused. On x86_64 a plain store of the table's
# address after its entries is seen in that order by every thread; on a
# machine that orders its stores loosely it is not, and no run on this one
# would show it. So it is read off the IR of a small program: every read
# of the word the address is kept in has to be an acquire load and its one
# write a release store.
cat >"$WORK/published.iyi" <<'IYI'
module published

import std/ecdsa::{EcdsaPublicKey, EcdsaCurve, EcdsaHash}

# G itself, uncompressed, and a signature of r = 1, s = 1.
g = [
  0x04_u8, 0x6b_u8, 0x17_u8, 0xd1_u8, 0xf2_u8, 0xe1_u8, 0x2c_u8, 0x42_u8, 0x47_u8, 0xf8_u8, 0xbc_u8,
  0xe6_u8, 0xe5_u8, 0x63_u8, 0xa4_u8, 0x40_u8, 0xf2_u8, 0x77_u8, 0x03_u8, 0x7d_u8, 0x81_u8, 0x2d_u8,
  0xeb_u8, 0x33_u8, 0xa0_u8, 0xf4_u8, 0xa1_u8, 0x39_u8, 0x45_u8, 0xd8_u8, 0x98_u8, 0xc2_u8, 0x96_u8,
  0x4f_u8, 0xe3_u8, 0x42_u8, 0xe2_u8, 0xfe_u8, 0x1a_u8, 0x7f_u8, 0x9b_u8, 0x8e_u8, 0xe7_u8, 0xeb_u8,
  0x4a_u8, 0x7c_u8, 0x0f_u8, 0x9e_u8, 0x16_u8, 0x2b_u8, 0xce_u8, 0x33_u8, 0x57_u8, 0x6b_u8, 0x31_u8,
  0x5e_u8, 0xce_u8, 0xcb_u8, 0xb6_u8, 0x40_u8, 0x68_u8, 0x37_u8, 0xbf_u8, 0x51_u8, 0xf5_u8,
]
key = EcdsaPublicKey.from_point(EcdsaCurve::P256, g).or_panic
puts key.verify(EcdsaHash::SHA256, "hello", [0x30_u8, 6_u8, 2_u8, 1_u8, 1_u8, 2_u8, 1_u8, 1_u8])
IYI
# published <file.ll> <class variable>: what in the IR reads or writes the
# word a table's address is kept in other than by an acquire load and a
# release store, a line each; 1 if anything does, or if either is missing.
# The zero the word starts from is a plain store, made before the
# program's first line.
published() {
  awk -v name="$2" '
    !(index($0, "@\"" name "\"") || index($0, "@\"" name ".")) || /^@/ || /store i64 0, ptr @/ { next }
    / = load atomic i64, ptr @[^ ]* acquire,/ { loads++; next }
    /store atomic i64 [^,]*, ptr @[^ ]* release,/ { stores++; next }
    { print name ": neither an acquire load nor a release store:" $0; other++ }
    END {
      if (!loads) print name ": no acquire load of it"
      if (!stores) print name ": no release store to it"
      exit (other || !loads || !stores) ? 1 : 0
    }' "$1"
}
# The IR is one pinned target's whatever the host is: the orderings are
# the module's request, the same for every target, and `--cross-compile`
# writes the IR and links nothing, so no toolchain for it is needed.
# published_ir <search path> <file>: the program above built into <file>.ll.
published_ir() {
  IYI_PATH="$1" "$IYI" build --release --emit llvm-ir --cross-compile --target x86_64-unknown-linux-gnu \
    -o "$2" "$WORK/published.iyi" >"$2.log" 2>&1 && [ -s "$2.ll" ]
}
: >"$WORK/published.out"
if ! published_ir "$IYI_PATH" "$WORK/published"; then
  echo "  no IR was written: $(grep -m1 -E 'Error|BUG' "$WORK/published.log")"
  status=1
elif published "$WORK/published.ll" 'Std::Ecdsa::EcdsaP256::g_table' >>"$WORK/published.out"; then
  echo "  the table's address is read by an acquire load and written, once the table is whole, by a release store"
else
  sed 's/^/  /' "$WORK/published.out"
  status=1
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
src = Path("$REPO/src/std/ecdsa.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/ecdsa.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_ecdsa_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "s past n taken" "s plus n (P256 SHA256): expected false, got true" \
  'r < n && s.positive? && s < n' 'r < n && s.positive?'
prove_broken "a third INTEGER read past" "a third INTEGER (P256 SHA256): expected false, got true" \
  '    return false unless fields.size == 2
    r_bytes' '    r_bytes'
prove_broken "the digest never cut" "P256 SHA384 (P256 SHA384): expected true, got false" \
  '    e = e >> excess if excess > 0' ''
prove_broken "G + Q precomputed as G + G" "expected true, got false" \
  '    add_points(g, q, both)' '    add_points(g, g, both)'
prove_broken "the scalars' bits read low first" "expected true, got false" \
  '        x = (a[i] >> bit) & 1_u8' '        x = (a[i] >> (7 - bit)) & 1_u8'
prove_broken "a point added to itself as the identity" "D1 over abc (P384 SHA384): expected true, got false" \
  '      zero?(rr) ? double(p, r) : clear(r + (2 * k).to_i64)' '      clear(r + (2 * k).to_i64)'
prove_broken "a point added to its negative as a doubling" "DNEG over abc (P384 SHA384): expected true, got false" \
  '      zero?(rr) ? double(p, r) : clear(r + (2 * k).to_i64)' '      double(p, r)'
prove_broken "doubling without a = -3's factor" "expected true, got false" \
  '    add(u, t, t)' '    copy(u, t, k)'
# P-256's own path: the coincident points, both digits' signs, the table
# of G, the recoding's carry, the field's last subtraction and its
# borrow, and the doubling.
prove_broken "a P-256 point added to itself as the identity" "D1 where the digits meet (P256 SHA256): expected true, got false" \
  '    rr.zero? ? double : EcdsaP256Point.identity' '    EcdsaP256Point.identity'
prove_broken "a P-256 point added to its negative as a doubling" "DNEG where the digits meet (P256 SHA256): expected true, got false" \
  '    rr.zero? ? double : EcdsaP256Point.identity' '    double'
prove_broken "Q's negative digits added as positive" "(P256 SHA256): expected true, got false" \
  '        acc = acc.add(odd[(-d) >> 1].negate)' '        acc = acc.add(odd[(-d) >> 1])'
prove_broken "G's negative digits added as positive" "(P256 SHA256): expected true, got false" \
  'EcdsaP256Num.sub(EcdsaP256Num.zero, table[-d])' 'table[-d]'
prove_broken "G's table one G apart, not two" "(P256 SHA256): expected true, got false" \
  '      points[i] = points[i - 1].add(twice)' '      points[i] = points[i - 1].add(g)'
prove_broken "a negative digit's carry left out of the scalar" "(P256 SHA256): expected true, got false" \
  '          carry = full &- low' '          carry = 0_u64'
prove_broken "a P-256 product that never takes p off" "(P256 SHA256): expected true, got false" \
  '    keep = 0_u64 &- ((top | (w.unsafe_shr(127).unsafe_to_u64 ^ 1_u64)) & 1_u64)' '    keep = 0_u64'
prove_broken "a P-256 difference that never adds p back" "(P256 SHA256): expected true, got false" \
  '    mask = 0_u64 &- w.unsafe_shr(127).unsafe_to_u64' '    mask = 0_u64'
prove_broken "a P-256 doubling without a = -3's factor" "(P256 SHA256): expected true, got false" \
  '    alpha = EcdsaP256Num.add(alpha, EcdsaP256Num.add(alpha, alpha))' '    alpha = EcdsaP256Num.add(alpha, alpha)'
# The Montgomery product is below 2p before its last subtraction; one
# that never subtracts leaves values the comparisons do not match.
prove_broken "a product that never takes p off" "expected true, got false" \
  '    if t[k] != 0_u64 || !below?(t, m)' '    if false'
prove_broken "SHA-384 as SHA-512" "SHA384 (P256 SHA384): expected true, got false" \
  'when EcdsaHash::SHA384 then Std::Digest::SHA384.hash_bytes(data)' 'when EcdsaHash::SHA384 then Std::Digest::SHA512.hash_bytes(data)'
prove_broken "a point off the curve taken" "a point off the curve refused" \
  '    return EcdsaError.new("a point that is not on #{curve}") unless group.on_curve?(x, y)' ''
prove_broken "a coordinate past p taken" "a coordinate past p refused" \
  '    return EcdsaError.new("a coordinate not below the field'"'"'s prime") unless x < group.p && y < group.p' ''
prove_broken "explicit parameters read as a curve's name" "explicit curve parameters refused" \
  'unless algorithm.size == 2 && algorithm[1].universal?(DerTag::OBJECT_IDENTIFIER)' 'if false'

# prove_unpublished <label> <variable> <phrase> <sed script>: the exercise
# cannot tell how a table's address reaches a second thread, its answers
# being the same; the reading of the IR has to refuse the copy, with
# <phrase> in what it says.
prove_unpublished() {
  rm -rf "$WORK/unpublished"
  mkdir -p "$WORK/unpublished/std"
  sed -e "$4" "$REPO/src/std/ecdsa.iyi" >"$WORK/unpublished/std/ecdsa.iyi"
  if cmp -s "$REPO/src/std/ecdsa.iyi" "$WORK/unpublished/std/ecdsa.iyi"; then
    echo "  $1: the patch changed nothing, so this proves nothing"
    status=1
  elif ! published_ir "$WORK/unpublished${PSEP}$IYI_PATH" "$WORK/unpublished/ir"; then
    echo "  $1: the patched module did not build: $(grep -m1 -E 'Error|BUG' "$WORK/unpublished/ir.log")"
    status=1
  elif published "$WORK/unpublished/ir.ll" "$2" >"$WORK/mut.out"; then
    echo "  the IR of $1 was read as sound"
    status=1
  elif grep -qF "$3" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 was refused, but not for what it is:"
    sed 's/^/    /' "$WORK/mut.out"
    status=1
  fi
}
prove_unpublished "a table's address stored with no ordering" 'Std::Ecdsa::EcdsaP256::g_table' "no release store to it" \
  's/^    @@g_table.set_release(table.address)$/    @@g_table.set_relaxed(table.address)/'
echo
if [ "$status" -eq 0 ]; then
  echo "the std/ecdsa exercise holds ($mutations breaks caught)"
else
  echo "the std/ecdsa exercise did not hold"
fi
exit $status
