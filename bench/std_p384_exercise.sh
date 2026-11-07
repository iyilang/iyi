#!/usr/bin/env bash
# Exercises `std/p384`.
#
#     bash bench/std_p384_exercise.sh
#
# The exercise holds RFC 6979's P-384 key and its six signatures byte for
# byte, the keys at the ends of [1, n - 1], every hash through std/ecdsa,
# digests signed as they are, the keys that are not one, NIST's CAVP
# vectors for ECDH, key pairs and public key validation, and the points
# that are not P-384's. This gate runs it plain and --release; holds 1,500
# keys and signatures and 300 digests to Python's cryptography (OpenSSL's
# deterministic ECDSA, RFC 6979, under SHA-256, -384 and -512), byte for
# byte, and has Python verify them; holds 500 shared secrets to Python both
# ways; reads private keys as OpenSSL writes them, PKCS #8 and SEC 1, and
# refuses the ones that are not P-384's; runs Wycheproof's ECDH vectors
# for secp384r1; prints how long keygen, ECDH and signing take beside
# OpenSSL; and proves on broken copies of the module that the checks fail
# where they say.
#
# Wycheproof's ECDSA P-384 vectors are verification tests - a signature
# and whether it holds - which is std/ecdsa's domain, not this module's;
# signing is held instead to RFC 6979 and to Python, byte for byte.
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
ec.generate_private_key(ec.SECP384R1()).sign(b"x", ec.ECDSA(hashes.SHA384(), deterministic_signing=True))
' >/dev/null 2>&1; then
  HAVE_ORACLE=1
fi
HAVE_ECDH=0
if [ -n "$PY" ] && "$PY" -c '
from cryptography.hazmat.primitives.asymmetric import ec
k = ec.generate_private_key(ec.SECP384R1())
k.exchange(ec.ECDH(), k.public_key())
' >/dev/null 2>&1; then
  HAVE_ECDH=1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_p384_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
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

echo "== the std/p384 exercise, plain build"
build_and_run "plain" p384-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/p384-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every p384 section reported"
for phrase in "== RFC 6979's P-384 key and signatures (appendix A.2.6)" "== the keys at the ends of the range" \
  "== every hash, checked by std/ecdsa" "== digests signed as they are (sign_digest)" "== what is not a private key" \
  "== Diffie-Hellman (ECDH): NIST's CAVP vectors" "== points that are not P-384's"; do
  if ! grep -qF "$phrase" "$WORK/p384-plain.out" 2>/dev/null; then
    echo "  missing: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" p384-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/p384-release.out" 2>/dev/null; then
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
# must write the same x, y and DER, and Python then verifies what the
# exercise wrote under the key it wrote.
if [ "$HAVE_ORACLE" -ne 1 ]; then
  echo "  no python cryptography with deterministic ECDSA here, so the signatures go uncompared"
else
  "$PY" - "$WORK/cases.txt" "$WORK/want.txt" <<'PY'
import os, random, sys
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
n = 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
rng = random.Random(int.from_bytes(os.urandom(8), "big"))
edges = [1, 2, 3, n - 1, n - 2, 2**383, 2**256, 2**192, 2**128, 2**64 - 1, 2**320 + 1, (2**384 - 1) % n, n // 2]
names = {"sha256": hashes.SHA256, "sha384": hashes.SHA384, "sha512": hashes.SHA512}
cases, want = [], []
for i in range(1500):
    d = edges[i] if i < len(edges) else rng.randrange(1, n)
    name = ["sha256", "sha384", "sha512"][i % 3]
    message = os.urandom(rng.randrange(0, 301))
    key = ec.derive_private_key(d, ec.SECP384R1())
    public = key.public_key().public_numbers()
    signature = key.sign(message, ec.ECDSA(names[name](), deterministic_signing=True))
    cases.append(f"{name} {d:096x} {message.hex()}")
    want.append(f"{public.x:096x} {public.y:096x} {signature.hex()}")
open(sys.argv[1], "w", newline="\n").write("\n".join(cases) + "\n")
open(sys.argv[2], "w", newline="\n").write("\n".join(want) + "\n")
PY
  "$WORK/p384-release" oracle "$WORK/cases.txt" >"$WORK/got.txt" 2>&1
  if ! diff "$WORK/want.txt" "$WORK/got.txt" >"$WORK/oracle.diff"; then
    echo "  FAIL: $(grep -c '^<' "$WORK/oracle.diff") of 1500 differ from Python's:"
    head -n 6 "$WORK/oracle.diff" | sed 's/^/    /'
    status=1
  elif ! "$PY" - "$WORK/cases.txt" "$WORK/got.txt" <<'PY'
import sys
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
names = {"sha256": hashes.SHA256, "sha384": hashes.SHA384, "sha512": hashes.SHA512}
bad = 0
for case, got in zip(open(sys.argv[1]).read().split("\n"), open(sys.argv[2]).read().split("\n")):
    if not case:
        continue
    name, _, message = (case.split(" ") + [""])[:3]
    x, y, signature = got.split(" ")
    public = ec.EllipticCurvePublicNumbers(int(x, 16), int(y, 16), ec.SECP384R1()).public_key()
    try:
        public.verify(bytes.fromhex(signature), bytes.fromhex(message), ec.ECDSA(names[name]()))
    except InvalidSignature:
        bad += 1
        print(f"    Python refuses {got[:60]}...")
sys.exit(1 if bad else 0)
PY
  then
    echo "  FAIL: Python refuses signatures the exercise wrote"
    status=1
  else
    echo "  1500 public keys and signatures as Python's, and Python verifies each: 500 under each of SHA-256, SHA-384 and SHA-512,"
    echo "  13 keys from the edges"
  fi
fi

echo
echo "== 300 digests signed as they are, against Python's Prehashed"
# Random digests of each hash's size, and some of 0xff bytes and of n and
# above (2^384 - 1, n, n + 1, n written into a SHA-512 digest's leftmost
# 48 bytes), where bits2octets' reduction mod n decides the nonce; then
# digests of the wrong size, which must be refused.
if [ "$HAVE_ORACLE" -ne 1 ]; then
  echo "  no python cryptography with deterministic ECDSA here, so the digests go unsigned"
else
  "$PY" - "$WORK/digests.txt" "$WORK/digests-want.txt" <<'PY'
import os, random, sys
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed
n = 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
rng = random.Random(int.from_bytes(os.urandom(8), "big"))
names = {"sha256": (hashes.SHA256, 32), "sha384": (hashes.SHA384, 48), "sha512": (hashes.SHA512, 64)}
high = [("sha384", (2**384 - 1).to_bytes(48, "big")), ("sha384", n.to_bytes(48, "big")), ("sha384", (n + 1).to_bytes(48, "big")),
        ("sha512", b"\xff" * 64), ("sha512", n.to_bytes(48, "big") + os.urandom(16)), ("sha256", b"\xff" * 32)]
cases, want = [], []
for i in range(300):
    if i < len(high):
        name, digest = high[i]
    else:
        name = ["sha256", "sha384", "sha512"][i % 3]
        digest = os.urandom(names[name][1])
        if i % 5 == 0 and name != "sha256":
            digest = (rng.randrange(n, 2**384)).to_bytes(48, "big") + digest[48:]
    d = rng.randrange(1, n)
    key = ec.derive_private_key(d, ec.SECP384R1())
    signature = key.sign(digest, ec.ECDSA(Prehashed(names[name][0]()), deterministic_signing=True))
    cases.append(f"{name} {d:096x} {digest.hex()}")
    want.append(signature.hex())
for name, size in (("sha256", 48), ("sha384", 32), ("sha384", 64), ("sha512", 48), ("sha384", 0)):
    cases.append(f"{name} {rng.randrange(1, n):096x} {os.urandom(size).hex()}")
    want.append("refused")
open(sys.argv[1], "w", newline="\n").write("\n".join(cases) + "\n")
open(sys.argv[2], "w", newline="\n").write("\n".join(want) + "\n")
PY
  "$WORK/p384-release" digest "$WORK/digests.txt" >"$WORK/digests-got.txt" 2>&1
  if diff "$WORK/digests-want.txt" "$WORK/digests-got.txt" >"$WORK/digests.diff"; then
    echo "  300 signatures of digests as Python's, 39 drawn from n up and 5 edges at or past n among them; 5 wrong sizes refused"
  else
    echo "  FAIL: $(grep -c '^<' "$WORK/digests.diff") of 305 differ from Python's:"
    head -n 6 "$WORK/digests.diff" | sed 's/^/    /'
    status=1
  fi
fi

echo
echo "== 500 shared secrets against Python's cryptography, both ways"
# d at random and from the edges against a peer's key Python makes: the
# exercise's answer must be what Python gets from the same d and the peer's
# point, and what Python gets from the peer's own d and the public point
# the exercise wrote. Then peer points that are not P-384's - off the
# curve, an x of p and of 2^384 - 1, (0, 0), 49 bytes, a 0x02 mark, the
# byte 0x00 - which the exercise must refuse, as Python refuses them.
if [ "$HAVE_ECDH" -ne 1 ]; then
  echo "  no python cryptography here, so the shared secrets go uncompared"
else
  "$PY" - "$WORK/ecdh.txt" "$WORK/ecdh-peers.txt" <<'PY'
import os, random, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
n = 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
p = 2**384 - 2**128 - 2**96 + 2**32 - 1
rng = random.Random(int.from_bytes(os.urandom(8), "big"))
edges = [1, 2, n - 1, n - 2, 2**383, 2**192]
cases, peers = [], []
for i in range(500):
    d = edges[i] if i < len(edges) else rng.randrange(1, n)
    peer = rng.randrange(1, n)
    point = ec.derive_private_key(peer, ec.SECP384R1()).public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    cases.append(f"{d:096x} {point.hex()}")
    peers.append(f"{peer:096x}")
good = ec.generate_private_key(ec.SECP384R1()).public_key()
numbers = good.public_numbers()
encoded = good.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
def raw(x, y): return b"\x04" + x.to_bytes(48, "big") + y.to_bytes(48, "big")
bad = [raw(numbers.x, (numbers.y + 1) % p), raw(p, numbers.y), raw(2**384 - 1, numbers.y), raw(0, 0),
       encoded[:49], b"\x02" + encoded[1:], b"\x00"]
for point in bad:
    try:
        ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP384R1(), point)
        verdict = "taken"
    except ValueError:
        verdict = "refused"
    cases.append(f"{rng.randrange(1, n):096x} {point.hex()}")
    peers.append(verdict)
open(sys.argv[1], "w", newline="\n").write("\n".join(cases) + "\n")
open(sys.argv[2], "w", newline="\n").write("\n".join(peers) + "\n")
PY
  "$WORK/p384-release" ecdh "$WORK/ecdh.txt" >"$WORK/ecdh-got.txt" 2>&1
  if "$PY" - "$WORK/ecdh.txt" "$WORK/ecdh-peers.txt" "$WORK/ecdh-got.txt" <<'PY'
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
cases = open(sys.argv[1]).read().split("\n")[:-1]
peers = open(sys.argv[2]).read().split("\n")[:-1]
got = open(sys.argv[3]).read().split("\n")[:-1]
if len(got) != len(cases):
    print(f"    {len(got)} answers for {len(cases)} cases: {got[-1:]}")
    sys.exit(1)
wrong, agreed, refused = 0, 0, 0
for case, peer, answer in zip(cases, peers, got):
    d, point = case.split(" ")
    if peer in ("taken", "refused"):
        if peer == "refused" and answer == "refused":
            refused += 1
        else:
            wrong += 1
            print(f"    the point {point[:40]}...: Python {peer}, the exercise {answer[:20]}")
        continue
    shared, public = answer.split(" ")
    own = ec.derive_private_key(int(d, 16), ec.SECP384R1())
    theirs = ec.derive_private_key(int(peer, 16), ec.SECP384R1())
    ours = own.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint).hex()
    forward = own.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP384R1(), bytes.fromhex(point))).hex()
    backward = theirs.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP384R1(), bytes.fromhex(public))).hex()
    if public == ours and shared == forward == backward:
        agreed += 1
    else:
        wrong += 1
        print(f"    d {d[:16]}...: the exercise {shared[:16]}..., Python {forward[:16]}... and {backward[:16]}...")
print(f"  {agreed} shared secrets as Python's both ways (its d and the peer's point; the peer's d and the exercise's point),")
print(f"  6 keys from the edges; {refused} points Python refuses refused")
sys.exit(1 if wrong else 0)
PY
  then
    :
  else
    echo "  FAIL: the shared secrets differ from Python's"
    status=1
  fi
fi

echo
echo "== private keys as OpenSSL writes them"
# PKCS #8 and SEC 1, from Python's cryptography (OpenSSL's encoders), with
# and without the curve and the public key; and the ones that are not a
# P-384 key: P-256's, Ed25519's, a public key that is not d's, a d of n, a
# SEC 1 version 2, 47 bytes.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import ec, ed25519' >/dev/null 2>&1; then
  echo "  no python cryptography here, so OpenSSL's encodings go unread"
else
  mkdir -p "$WORK/keys"
  "$PY" - "$WORK/keys" <<'PY'
import os, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
out = sys.argv[1]
n = 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
def tlv(t, c): return bytes([t]) + (bytes([len(c)]) if len(c) < 128 else bytes([0x81, len(c)])) + c
listed, want = [], []
def put(name, der, expect):
    open(os.path.join(out, name), "wb").write(der)
    listed.append(name)
    want.append(f"{name} {expect}")
curve = tlv(0xa0, bytes.fromhex("06052b81040022"))
for i in range(20):
    k = ec.generate_private_key(ec.SECP384R1())
    pub = k.public_key().public_numbers()
    point = f"{pub.x:096x} {pub.y:096x}"
    put(f"key{i}.p8", k.private_bytes(s.Encoding.DER, s.PrivateFormat.PKCS8, s.NoEncryption()), point)
    put(f"key{i}.sec1", k.private_bytes(s.Encoding.DER, s.PrivateFormat.TraditionalOpenSSL, s.NoEncryption()), point)
    d = k.private_numbers().private_value.to_bytes(48, "big")
    put(f"bare{i}.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, d)), point)
    put(f"curve{i}.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, d) + curve), point)
other = ec.generate_private_key(ec.SECP384R1()).public_key().public_bytes(s.Encoding.X962, s.PublicFormat.UncompressedPoint)
d = ec.generate_private_key(ec.SECP384R1()).private_numbers().private_value.to_bytes(48, "big")
put("p256.p8", ec.generate_private_key(ec.SECP256R1()).private_bytes(s.Encoding.DER, s.PrivateFormat.PKCS8, s.NoEncryption()),
    "refused: ecdsa: the private key is on 1.2.840.10045.3.1.7, not secp384r1 (1.3.132.0.34)")
put("ed25519.p8", ed25519.Ed25519PrivateKey.generate().private_bytes(s.Encoding.DER, s.PrivateFormat.PKCS8, s.NoEncryption()),
    "refused: ecdsa: the private key is for 1.3.101.112, not id-ecPublicKey (1.2.840.10045.2.1)")
put("other-public.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, d) + tlv(0xa1, tlv(0x03, b"\x00" + other))),
    "refused: ecdsa: the private key: its public key is not the private key's")
put("order.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, n.to_bytes(48, "big"))),
    "refused: ecdsa: a P-384 private key is a number from 1 to n - 1")
put("version2.sec1", tlv(0x30, bytes.fromhex("020102") + tlv(0x04, d)),
    "refused: ecdsa: the private key: an ECPrivateKey whose version is not 1")
put("short.sec1", tlv(0x30, bytes.fromhex("020101") + tlv(0x04, d[1:])),
    "refused: ecdsa: a P-384 private key is 48 bytes, not 47")
open(os.path.join(out, "list"), "w", newline="\n").write("\n".join(listed) + "\n")
open(os.path.join(out, "want"), "w", newline="\n").write("\n".join(want) + "\n")
PY
  "$WORK/p384-release" keys "$WORK/keys" >"$WORK/keys.out" 2>&1
  if diff "$WORK/keys/want" "$WORK/keys.out" >"$WORK/keys.diff"; then
    echo "  80 keys read as Python wrote them (PKCS #8, SEC 1 with and without its curve and public key); P-256's, Ed25519's,"
    echo "  another public key, d = n, version 2 and 47 bytes refused, each for its reason"
  else
    echo "  FAIL: the keys read otherwise:"
    head -n 8 "$WORK/keys.diff" | sed 's/^/    /'
    status=1
  fi
fi

echo
echo "== Wycheproof's ECDH vectors for secp384r1 (ecpoint encoding)"
# Downloaded each run, not vendored: the file is C2SP's, and the gate reads
# whatever it holds now. Each case's private key is written as Wycheproof
# writes an INTEGER - a leading 00 when the top bit is set, or shorter than
# 48 bytes - and taken to 48 here. Every `valid` case must give `shared`,
# every `invalid` one must be refused; the `acceptable` ones (a compressed
# point, which this module does not take) are reported.
WYCHEPROOF_URL="https://raw.githubusercontent.com/C2SP/wycheproof/main/testvectors_v1/ecdh_secp384r1_ecpoint_test.json"
if [ -z "$PY" ]; then
  echo "  no python here to read Wycheproof's JSON, so its vectors go unrun"
elif ! "$PY" - "$WYCHEPROOF_URL" "$WORK/wycheproof.txt" <<'PY' 2>"$WORK/wycheproof.err"
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=30) as answer:
    data = json.load(answer)
lines = []
for group in data["testGroups"]:
    for test in group["tests"]:
        private = int(test["private"], 16) if test["private"] else 0
        if private >= 2**384:
            private_hex = test["private"]
        else:
            private_hex = f"{private:096x}"
        lines.append(f'{test["tcId"]} {test["result"]} {private_hex} {test["public"] or "-"} {test["shared"] or "-"}')
open(sys.argv[2], "w", newline="\n").write("\n".join(lines) + "\n")
PY
then
  echo "  Wycheproof's file could not be fetched or read here ($(tail -n 1 "$WORK/wycheproof.err")), so its vectors go unrun"
else
  if "$WORK/p384-release" wycheproof "$WORK/wycheproof.txt" >"$WORK/wycheproof.out" 2>&1; then
    sed 's/^/  /' "$WORK/wycheproof.out"
  else
    echo "  FAIL: Wycheproof's vectors:"
    sed 's/^/    /' "$WORK/wycheproof.out" | tail -n 20
    status=1
  fi
fi

echo
echo "== how long keygen, ECDH and signing take (--release), measured, not checked"
# The median of 1,001 runs of each, one at a time. Keygen is from_bytes:
# [d]G, its inverse to affine, and std/ecdsa's check of the point. ECDH
# is shared_secret with a valid peer (NIST's first CDH peer). Signing is
# SHA-384 of "sample". Each runs for d = RFC 6979's key, d = 1 and
# d = n - 1: the work is the same for every d, so the three should be
# close - a note for a reader, since a shared machine's noise is no
# basis for a check.
if "$WORK/p384-release" time 1001 >"$WORK/time.out" 2>&1; then
  awk '
    function ms(ns) { return sprintf("%.3f ms", ns / 1000000) }
    { t[$1] = $2 }
    END {
      printf "  keygen (from_bytes) %s, ECDH (shared_secret) %s, sign (SHA-384) %s: medians of 1,001 runs\n", ms(t["keygen"]), ms(t["ecdh-rfc"]), ms(t["sign-rfc"])
      printf "  timing note: ECDH for RFC 6979'"'"'s d %s, d = 1 %s, d = n - 1 %s;\n", ms(t["ecdh-rfc"]), ms(t["ecdh-one"]), ms(t["ecdh-last"])
      printf "  signing for RFC 6979'"'"'s d %s, d = 1 %s, d = n - 1 %s\n", ms(t["sign-rfc"]), ms(t["sign-one"]), ms(t["sign-last"])
    }' "$WORK/time.out"
else
  echo "  the timing run failed:"
  tail -n 3 "$WORK/time.out" | sed 's/^/    /'
  status=1
fi
if command -v openssl >/dev/null 2>&1 && openssl speed -seconds 1 ecdhp384 ecdsap384 >"$WORK/speed.out" 2>/dev/null; then
  awk '
    /ecdsa \(nistp384\)/ { sign = $(NF - 1) }
    /ecdh \(nistp384\)/ { ecdh = $NF }
    END {
      if (sign == "" || ecdh == "") { print "  openssl speed answered in a shape this does not read"; exit }
      printf "  OpenSSL (openssl speed -seconds 1): ECDH %.3f ms (%s/s), sign %.3f ms (%s/s)\n", 1000 / ecdh, ecdh, 1000 / sign, sign
    }' "$WORK/speed.out"
  echo "  ($(openssl version))"
else
  echo "  no openssl here with speed for P-384, so nothing to set these beside"
fi
# openssl speed has no keygen line: Python's cryptography makes a key on
# OpenSSL's own code, so its median stands in, Python's call included.
if [ -n "$PY" ] && "$PY" - >"$WORK/keygen.out" 2>/dev/null <<'PY'
import statistics, time
from cryptography.hazmat.primitives.asymmetric import ec
took = []
for _ in range(1001):
    started = time.perf_counter()
    ec.generate_private_key(ec.SECP384R1())
    took.append(time.perf_counter() - started)
print(f"  OpenSSL's keygen, through Python's cryptography: {statistics.median(took) * 1000:.3f} ms (median of 1,001)")
PY
then
  cat "$WORK/keygen.out"
else
  echo "  no python cryptography here, so OpenSSL's keygen goes untimed"
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [<old2> <new2>]: the exercise
# must fail on a copy of the module with <old> replaced (and <old2>, when
# given), at the check that names <phrase>. Each <old> must be found once.
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
  if ! OLD="$3" NEW="$4" OLD2="${5-}" NEW2="${6-}" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/p384.iyi").read_text(encoding="utf-8")
pairs = [(os.environ["OLD"], os.environ["NEW"])]
if os.environ["OLD2"]:
    pairs.append((os.environ["OLD2"], os.environ["NEW2"]))
for old, new in pairs:
    if src.count(old) != 1:
        raise SystemExit("patch site missing or not one")
    src = src.replace(old, new, 1)
Path("$WORK/patched/std/p384.iyi").write_text(src, encoding="utf-8", newline="\n")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_p384_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
# said_too <label> <phrase>: the run prove_broken just made also printed
# <phrase> - what a break left standing, read from the same output.
said_too() {
  if [ -z "$PY" ]; then
    return
  fi
  if grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1"
  else
    echo "  FAIL: $1 - not said:"
    grep -F "(0, 0)" "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken "a product whose last subtraction never happens" "a point that is not on P384" \
  '    P384Num.choose(keep & 1_u64, d, t)' '    t'
prove_broken "a sum that keeps what passes m" "a point that is not on P384" \
  '    P384Num.choose((carry | (borrow ^ 1_u64)) & 1_u64, d, sum)' '    sum'
prove_broken "a difference that never adds m back" "a point that is not on P384" \
  '    mask = 0_u64 &- borrow
    w = d.l0.to_u128' '    mask = 0_u64
    w = d.l0.to_u128'
prove_broken "b with one limb wrong" "a point that is not on P384" \
  '      0xe3374bee94938ae2_u64, 0xb62b21f41f022094_u64, 0xcd08114b604fbff9_u64)' \
  '      0xe3374bee94938ae3_u64, 0xb62b21f41f022094_u64, 0xcd08114b604fbff9_u64)'
prove_broken "the order's R^2 with one limb wrong" "the signature of \"sample\" under SHA-256" \
  '        0xd40d49174aab1cc5_u64, 0x3fb05b7a28266895_u64, 0x0c84ee012b39bf21_u64))' \
  '        0xd40d49174aab1cc5_u64, 0x3fb05b7a28266895_u64, 0x0c84ee012b39bf22_u64))'
prove_broken "a doubling short of its last step" "a point that is not on P384" \
  '    z3 = f.add(z3, z3)
    z3 = f.add(z3, z3)
    P384Point.new(x3, y3, z3)' '    z3 = f.add(z3, z3)
    P384Point.new(x3, y3, z3)'
prove_broken "a window lookup whose mask answers the next entry" "a point that is not on P384" \
  '      bit = ((i.to_u64 ^ digit) &- 1_u64).unsafe_shr(63)' '      bit = ((i.to_u64 ^ (digit &+ 1_u64)) &- 1_u64).unsafe_shr(63)'
prove_broken "an inverse to the power m - 3" "a point that is not on P384" \
  '    e = P384Num.sub_raw(@m, P384Num.new(2_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64))[0]' \
  '    e = P384Num.sub_raw(@m, P384Num.new(3_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64))[0]'
prove_broken "a borrow that ignores the one coming in" "a point that is not on P384" \
  '    ((~x & y) | (~(x ^ y) & d)).unsafe_shr(63)' '    (~x & y).unsafe_shr(63)'
prove_broken "RFC 6979's second round of K and V left out" "the signature of \"sample\" under SHA-256" \
  '    k = P384Hmac.mac(hash, k, v + [1_u8] + x + h)
    v = P384Hmac.mac(hash, k, v)' ''
prove_broken "a nonce from the message alone" "the signature of \"sample\" under SHA-256" \
  '    k = P384Hmac.mac(hash, k, v + [0_u8] + x + h)' '    k = P384Hmac.mac(hash, k, v + [0_u8] + h)'
# The digest past n: a message's digest is that rarely (2^-189 or so), so
# only the 0xff digests sign_digest takes reach it.
prove_broken "the nonce's digest not reduced mod n" "the SHA-384 digest of 48 bytes 0xff" \
  '    e = P384Num.reduce_once(P384Num.bits2int(h1), P384Num.n)' '    e = P384Num.bits2int(h1)'
# A SHA-256 nonce from one HMAC block: 32 bytes, taken as the number they
# are (bits2int pads the short block on the left; read as 48 bytes they
# would run past the array's end before any check).
prove_broken "a SHA-256 nonce from a single HMAC block" "the signature of \"sample\" under SHA-256" \
  '      while t.size < 48' '      while t.size < 1' \
  '      candidate = P384Num.from_bytes(t, 0)' '      candidate = P384Num.bits2int(t)'
prove_broken "s computed with k, not its inverse" "the signature of \"sample\" under SHA-256" \
  '          s = m.from_mont(m.mul(m.inverse(km), m.add(m.to_mont(e), rd)))' '          s = m.from_mont(m.mul(km, m.add(m.to_mont(e), rd)))'
prove_broken "a d of n or more taken" "d = 2^384 - 1: accepted" \
  '    unless P384Num.below?(d, P384Num.n) && !d.zero?' '    unless !d.zero?'
prove_broken "SEC 1's public key unchecked" "an ECPrivateKey carrying another public key: accepted" \
  '        return EcdsaError.new("the private key: its public key is not the private key'"'"'s") unless carried.is_a?(EcdsaPublicKey) && carried.x == key.public_key.x && carried.y == key.public_key.y' ''
prove_broken "SEC 1's curve unchecked" "an ECPrivateKey naming prime256v1: accepted" \
  '        return EcdsaError.new("the private key names a curve that is not secp384r1") unless oid == P384Point::CURVE_OID' ''
prove_broken "a peer point off the curve taken" "a point off the curve: accepted" \
  '    return EcdsaError.new("a point that is not on P-384") unless f.square(ym).to_bytes == right.to_bytes' ''
# With the curve check gone, (0, 0) still meets the second wall: the run
# above printed which refusal it met before the flipped bit failed it.
said_too "with only the curve check gone, (0, 0) is refused as the point at infinity" \
  "(0, 0) refused: ecdsa: the shared point is the point at infinity"
# Both walls gone: (0, 0) is taken, and its "secret" is the x of a point
# at infinity. It is the first point refused, so it is where this fails.
prove_broken "no curve check and no check of the point at infinity" "(0, 0): accepted" \
  '    return EcdsaError.new("a point that is not on P-384") unless f.square(ym).to_bytes == right.to_bytes' '' \
  '    return EcdsaError.new("the shared point is the point at infinity") if product.z.zero?' ''
prove_broken "a peer coordinate of p or more taken" "a point whose x is p: accepted" \
  '    unless P384Num.below?(x, P384Num.p) && P384Num.below?(y, P384Num.p)' '    if false'
prove_broken "[d]G answered for [d]Q" "NIST's CDH vector 0: ZIUT" \
  '    product = P384Point.mult(q, @d)' '    product = P384Point.base_mult(@d)'
prove_broken "the table built from G whatever the point" "NIST's CDH vector 0: ZIUT" \
  '      table[i] = table[i - 1] + point' '      table[i] = table[i - 1] + P384Point.base'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/p384 exercise holds ($mutations breaks caught)"
else
  echo "the std/p384 exercise did not hold"
fi
exit $status
