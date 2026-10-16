#!/usr/bin/env bash
# Exercises `std/p256`.
#
#     bash bench/std_p256_exercise.sh
#
# The exercise holds RFC 6979's P-256 key and signatures byte for byte,
# the keys at the ends of [1, n - 1], every hash through std/ecdsa, and
# the keys that are not one. This gate runs it plain and --release; holds
# 1,500 keys and signatures to Python's cryptography (OpenSSL's
# deterministic ECDSA, RFC 6979, under SHA-256, -384 and -512), byte for
# byte; reads private keys as OpenSSL writes them, PKCS #8 and SEC 1, and
# refuses the ones that are not P-256's; and proves on broken copies of
# the module that the checks fail where they say.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The oracles below are written in python, and windows answers `python3`
# with a store stub that prints and exits rather than running it, so the
# interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

# Python's cryptography with deterministic ECDSA (OpenSSL 3.2 and later
# underneath) is the oracle where it is installed; without it the
# comparisons say so and the rest still runs.
HAVE_ORACLE=0
if [ -n "$PY" ] && "$PY" -c '
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes
ec.generate_private_key(ec.SECP256R1()).sign(b"x", ec.ECDSA(hashes.SHA256(), deterministic_signing=True))
' >/dev/null 2>&1; then
  HAVE_ORACLE=1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_p256_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/p256 exercise, plain build"
build_and_run "plain" p256-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/p256-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every p256 section reported"
for phrase in "== RFC 6979's P-256 key and signatures (appendix A.2.5)" "== the keys at the ends of the range" \
  "== every hash, checked by std/ecdsa" "== what is not a private key"; do
  if ! grep -qF "$phrase" "$WORK/p256-plain.out" 2>/dev/null; then
    echo "  missing: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" p256-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/p256-release.out" 2>/dev/null; then
  echo "release: ALL CHECKS PASSED missing"
  status=1
else
  echo "  ALL CHECKS PASSED"
fi

echo
echo "== 1,500 keys and signatures against Python's cryptography, byte for byte"
# d drawn at random and from the edges - 1, 2, n - 1, n - 2, powers of
# two, words of all ones - with messages of every length up to 300 bytes,
# under SHA-256, -384 and -512. Python makes the public key and the
# deterministic signature (RFC 6979, as OpenSSL does it); the exercise
# must write the same x, y and DER.
if [ "$HAVE_ORACLE" -ne 1 ]; then
  echo "  no python cryptography with deterministic ECDSA here, so the signatures go uncompared"
else
  "$PY" - "$WORK/cases.txt" "$WORK/want.txt" <<'PY'
import os, random, sys
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
n = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
rng = random.Random(int.from_bytes(os.urandom(8), "big"))
edges = [1, 2, 3, n - 1, n - 2, 2**255, 2**128, 2**64 - 1, 2**192 + 1, (2**256 - 1) % n, n // 2]
names = {"sha256": hashes.SHA256, "sha384": hashes.SHA384, "sha512": hashes.SHA512}
cases, want = [], []
for i in range(1500):
    d = edges[i] if i < len(edges) else rng.randrange(1, n)
    name = ["sha256", "sha384", "sha512"][i % 3]
    message = os.urandom(rng.randrange(0, 301))
    key = ec.derive_private_key(d, ec.SECP256R1())
    public = key.public_key().public_numbers()
    signature = key.sign(message, ec.ECDSA(names[name](), deterministic_signing=True))
    cases.append(f"{name} {d:064x} {message.hex()}")
    want.append(f"{public.x:x} {public.y:x} {signature.hex()}")
open(sys.argv[1], "w", newline="\n").write("\n".join(cases) + "\n")
open(sys.argv[2], "w", newline="\n").write("\n".join(want) + "\n")
PY
  "$WORK/p256-release" oracle "$WORK/cases.txt" >"$WORK/got.txt" 2>&1
  if diff "$WORK/want.txt" "$WORK/got.txt" >"$WORK/oracle.diff"; then
    echo "  1500 public keys and signatures as Python's: 500 under each of SHA-256, SHA-384 and SHA-512, 11 keys from the edges"
  else
    echo "  FAIL: $(grep -c '^<' "$WORK/oracle.diff") of 1500 differ from Python's:"
    head -n 6 "$WORK/oracle.diff" | sed 's/^/    /'
    status=1
  fi
fi

echo
echo "== private keys as OpenSSL writes them"
# PKCS #8 and SEC 1, from Python's cryptography (OpenSSL's encoders), with
# and without the curve and the public key; and the ones that are not a
# P-256 key: P-384's, Ed25519's, a public key that is not d's, a d of n, a
# SEC 1 version 2.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import ec, ed25519' >/dev/null 2>&1; then
  echo "  no python cryptography here, so OpenSSL's encodings go unread"
else
  mkdir -p "$WORK/keys"
  "$PY" - "$WORK/keys" <<'PY'
import os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
out = sys.argv[1]
n = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
def tlv(t, c): return bytes([t]) + (bytes([len(c)]) if len(c) < 128 else bytes([0x81, len(c)])) + c
listed, want = [], []
def put(name, der, expect):
    open(os.path.join(out, name), "wb").write(der)
    listed.append(name)
    want.append(f"{name} {expect}")
for i in range(20):
    k = ec.generate_private_key(ec.SECP256R1())
    pub = k.public_key().public_numbers()
    point = f"{pub.x:x} {pub.y:x}"
    put(f"key{i}.p8", k.private_bytes(s.Encoding.DER, s.PrivateFormat.PKCS8, s.NoEncryption()), point)
    put(f"key{i}.sec1", k.private_bytes(s.Encoding.DER, s.PrivateFormat.TraditionalOpenSSL, s.NoEncryption()), point)
    d = k.private_numbers().private_value.to_bytes(32, "big")
    put(f"bare{i}.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, d)), point)
other = ec.generate_private_key(ec.SECP256R1()).public_key().public_bytes(s.Encoding.X962, s.PublicFormat.UncompressedPoint)
d = ec.generate_private_key(ec.SECP256R1()).private_numbers().private_value.to_bytes(32, "big")
put("p384.p8", ec.generate_private_key(ec.SECP384R1()).private_bytes(s.Encoding.DER, s.PrivateFormat.PKCS8, s.NoEncryption()),
    "refused: ecdsa: the private key is on 1.3.132.0.34, not prime256v1 (1.2.840.10045.3.1.7)")
put("ed25519.p8", ed25519.Ed25519PrivateKey.generate().private_bytes(s.Encoding.DER, s.PrivateFormat.PKCS8, s.NoEncryption()),
    "refused: ecdsa: the private key is for 1.3.101.112, not id-ecPublicKey (1.2.840.10045.2.1)")
put("other-public.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, d) + tlv(0xa1, tlv(0x03, b"\x00" + other))),
    "refused: ecdsa: the private key: its public key is not the private key's")
put("order.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, n.to_bytes(32, "big"))),
    "refused: ecdsa: a P-256 private key is a number from 1 to n - 1")
put("version2.sec1", tlv(0x30, bytes.fromhex("020102") + tlv(0x04, d)),
    "refused: ecdsa: the private key: an ECPrivateKey whose version is not 1")
put("short.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, d[1:])),
    "refused: ecdsa: a P-256 private key is 32 bytes, not 31")
open(os.path.join(out, "list"), "w", newline="\n").write("\n".join(listed) + "\n")
open(os.path.join(out, "want"), "w", newline="\n").write("\n".join(want) + "\n")
PY
  "$WORK/p256-release" keys "$WORK/keys" >"$WORK/keys.out" 2>&1
  if diff "$WORK/keys/want" "$WORK/keys.out" >"$WORK/keys.diff"; then
    echo "  60 keys read as Python wrote them (PKCS #8, SEC 1 with and without its curve and public key); P-384's, Ed25519's,"
    echo "  another public key, d = n, version 2 and 31 bytes refused, each for its reason"
  else
    echo "  FAIL: the keys read otherwise:"
    head -n 8 "$WORK/keys.diff" | sed 's/^/    /'
    status=1
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new>: the exercise must fail on a
# copy of the module with <old> replaced, at the check that names <phrase>.
# A wrong field or point operation is caught where the first key is made:
# its public point fails std/ecdsa's own check of the curve's equation,
# done in std/big's arithmetic, which shares none of this module's.
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
src = Path("$REPO/src/std/p256.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/p256.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_p256_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a product whose last subtraction never happens" "a point that is not on P256" \
  '    P256Num.choose(keep & 1_u64, d, P256Num.new(t0, t1, t2, t3))' '    P256Num.new(t0, t1, t2, t3)'
prove_broken "a sum that keeps what passes m" "a point that is not on P256" \
  '    P256Num.choose((carry | (borrow ^ 1_u64)) & 1_u64, d, sum)' '    sum'
prove_broken "a difference that never adds m back" "a point that is not on P256" \
  '    mask = 0_u64 &- borrow
    w = d.l0.to_u128' '    mask = 0_u64
    w = d.l0.to_u128'
prove_broken "an addition with b left out" "a point that is not on P256" \
  '    z3 = f.mul(b, t2)
    x3 = f.sub(y3, z3)' '    z3 = t2
    x3 = f.sub(y3, z3)'
prove_broken "a doubling short of its last step" "a point that is not on P256" \
  '    z3 = f.add(z3, z3)
    z3 = f.add(z3, z3)
    P256Point.new(x3, y3, z3)' '    z3 = f.add(z3, z3)
    P256Point.new(x3, y3, z3)'
prove_broken "a constant-time lookup that answers the next entry" "a point that is not on P256" \
  '      bit = ((i.to_u64 ^ digit) &- 1_u64).unsafe_shr(63)' '      bit = ((i.to_u64 ^ (digit &+ 1_u64)) &- 1_u64).unsafe_shr(63)'
prove_broken "an inverse to the power m - 3" "a point that is not on P256" \
  '    e = P256Num.sub_raw(@m, P256Num.new(2_u64, 0_u64, 0_u64, 0_u64))[0]' '    e = P256Num.sub_raw(@m, P256Num.new(3_u64, 0_u64, 0_u64, 0_u64))[0]'
prove_broken "a borrow that ignores the one coming in" "a P-256 private key is a number from 1 to n - 1" \
  '    ((~x & y) | (~(x ^ y) & d)).unsafe_shr(63)' '    (~x & y).unsafe_shr(63)'
prove_broken "RFC 6979's second round of K and V left out" "the signature of \"sample\" under SHA-256" \
  '    k = P256Hmac.mac(hash, k, v + [1_u8] + x + h)
    v = P256Hmac.mac(hash, k, v)' ''
prove_broken "a nonce from the message alone" "the signature of \"sample\" under SHA-256" \
  '    k = P256Hmac.mac(hash, k, v + [0_u8] + x + h)' '    k = P256Hmac.mac(hash, k, v + [0_u8] + h)'
prove_broken "s computed with k, not its inverse" "the signature of \"sample\" under SHA-256" \
  '          s = m.from_mont(m.mul(m.inverse(km), m.add(m.to_mont(e), rd)))' '          s = m.from_mont(m.mul(km, m.add(m.to_mont(e), rd)))'
prove_broken "a d of n or more taken" "d = 2^256 - 1: accepted" \
  '    unless P256Num.below?(d, P256Num.n) && !d.zero?' '    unless !d.zero?'
prove_broken "SEC 1's public key unchecked" "an ECPrivateKey carrying another public key: accepted" \
  '        return EcdsaError.new("the private key: its public key is not the private key'"'"'s") unless carried.is_a?(EcdsaPublicKey) && carried.x == key.public_key.x && carried.y == key.public_key.y' ''
prove_broken "SEC 1's curve unchecked" "an ECPrivateKey naming P-384: accepted" \
  '        return EcdsaError.new("the private key names a curve that is not prime256v1") unless oid == P256Point::CURVE_OID' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/p256 exercise holds ($mutations breaks caught)"
else
  echo "the std/p256 exercise did not hold"
fi
exit $status
