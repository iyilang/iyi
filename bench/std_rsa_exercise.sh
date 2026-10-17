#!/usr/bin/env bash
# Exercises `std/rsa`.
#
#     bash bench/std_rsa_exercise.sh
#
# The exercise holds signatures Python's cryptography made, encodings made
# by hand that break one rule each with the digest still matching, keys
# that are not keys, and a private key cryptography drew - read every way,
# its PKCS #1 v1.5 signatures byte for byte cryptography's, and its
# numbers broken one at a time and refused; this gate runs it plain and
# --release, holds 600 signatures over six key sizes, both schemes, four
# hashes and the salt lengths PSS allows, half of them broken some way, to
# Python's verdicts, has cryptography check 240 signatures this makes over
# five keys it drew, refuse its keys with a parameter broken, and time a
# 2048- and a 4096-bit signature; checks every RSA root certificate's
# signature with its own key as Python does, shows an error value's
# sentence through `.or_panic` and a signature over SHA-1 refused, reads
# the module with `iyi doc`, checks the formatting, typechecks the
# exercise for five targets and builds it from its artifacts, and proves
# on broken copies of the module that the checks fail where they say.
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
for phrase in "== signatures Python's cryptography made" "== keys that are not keys" "== private keys: read, signing, and refused"; do
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
echo "== 240 signatures this makes, checked by Python's cryptography"
# Five keys cryptography draws - 2048 bits, 2050 (the top seven bits of
# PSS's encoding masked off; OpenSSL rounds an odd size down, so none whose
# encoding is a byte short), 3072, 4096 and 2048 with e = 3 - written as PKCS
# #1 and as PKCS #8; each signs random messages under both schemes and the
# three hashes. A PSS signature must verify with a salt as long as the
# hash, a PKCS #1 v1.5 one must be cryptography's own, byte for byte. Then
# the 3072-bit key with each CRT parameter broken, and a 1024-bit key:
# each refused, for its reason.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import rsa' >/dev/null 2>&1; then
  echo "  no python cryptography here, so the signatures go unchecked"
else
  mkdir -p "$WORK/keys"
  "$PY" - "$WORK/keys" "$WORK/sign.txt" "$WORK/sign_cases.txt" <<'PY'
import os, random, sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric import rsa
out = sys.argv[1]
rng = random.Random(3447)
def pem(key, fmt):
    return key.private_bytes(s.Encoding.PEM, fmt, s.NoEncryption())
keys = []
for i, (bits, e) in enumerate(((2048, 65537), (2050, 65537), (3072, 65537), (4096, 65537), (2048, 3))):
    k = rsa.generate_private_key(public_exponent=e, key_size=bits)
    path = os.path.join(out, f"k{i}.pem")
    open(path, "wb").write(pem(k, s.PrivateFormat.PKCS8 if i % 2 else s.PrivateFormat.TraditionalOpenSSL))
    open(path + ".der", "wb").write(k.private_bytes(s.Encoding.DER, s.PrivateFormat.TraditionalOpenSSL, s.NoEncryption()))
    keys.append(path)
lines, cases = [], []
for _ in range(240):
    path = rng.choice(keys)
    scheme = rng.choice(["v15", "pss"])
    h = rng.choice(["SHA256", "SHA384", "SHA512"])
    msg = os.urandom(rng.randint(0, 300))
    lines.append(f"{path} {scheme} {h} {msg.hex()}")
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
# The 3072-bit key's numbers, one at a time broken; a 1024-bit key.
def tlv(tag, content):
    n = len(content)
    head = bytes([n]) if n < 128 else (n.to_bytes((n.bit_length() + 7) // 8, "big"))
    return bytes([tag]) + (head if n < 128 else bytes([0x80 | len(head)]) + head) + content
def integer(v):
    raw = v.to_bytes(v.bit_length() // 8 + 1, "big")
    return tlv(0x02, raw)
k = rsa.generate_private_key(public_exponent=65537, key_size=3072)
n = k.private_numbers()
fields = [n.public_numbers.n, n.public_numbers.e, n.d, n.p, n.q, n.dmp1, n.dmq1, n.iqmp]
broken = {"n": (0, 2, "p times q is not its modulus"), "d": (2, 2, "d is not e's inverse"), "dp": (5, 2, "dp is not d mod (p - 1)"),
          "dq": (6, 2, "dq is not d mod (q - 1)"), "qi": (7, 1, "qi is not the inverse of q mod p")}
for name, (at, plus, why) in broken.items():
    numbers = list(fields)
    numbers[at] += plus
    der = tlv(0x30, integer(0) + b"".join(integer(x) for x in numbers))
    import base64
    body = base64.encodebytes(der).decode().replace("\n", "")
    text = "-----BEGIN RSA PRIVATE KEY-----\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64)) + "\n-----END RSA PRIVATE KEY-----\n"
    path = os.path.join(out, f"broken-{name}.pem")
    open(path, "w").write(text)
    cases.append(f"{path}|{why}")
small = rsa.generate_private_key(public_exponent=65537, key_size=1024)
path = os.path.join(out, "small.pem")
open(path, "wb").write(pem(small, s.PrivateFormat.PKCS8))
cases.append(f"{path}|1024 bits, under the 2048 this signs with")
open(sys.argv[3], "w").write("\n".join(cases) + "\n")
PY
  "$WORK/rsa-release" sign "$WORK/sign.txt" >"$WORK/signed.txt" 2>&1
  if ! "$PY" - "$WORK/sign.txt" "$WORK/signed.txt" <<'PY'
import sys
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
H = {"SHA256": hashes.SHA256, "SHA384": hashes.SHA384, "SHA512": hashes.SHA512}
cases = open(sys.argv[1]).read().splitlines()
got = open(sys.argv[2]).read().splitlines()
keys, bad, sizes = {}, [], set()
if len(cases) != len(got):
    bad.append((-1, f"{len(cases)} cases, {len(got)} answers"))
for i, (case, sig) in enumerate(zip(cases, got)):
    path, scheme, h, msg = case.split(" ")
    key = keys.setdefault(path, serialization.load_pem_private_key(open(path, "rb").read(), None))
    sizes.add(key.key_size)
    msg = bytes.fromhex(msg)
    try:
        signature = bytes.fromhex(sig)
    except ValueError:
        bad.append((i, f"answered {sig[:80]!r}")); continue
    if scheme == "v15":
        if signature != key.sign(msg, padding.PKCS1v15(), H[h]()):
            bad.append((i, f"v15 {h} over {key.key_size} bits is not cryptography's signature"))
        continue
    try:
        key.public_key().verify(signature, msg, padding.PSS(mgf=padding.MGF1(H[h]()), salt_length=padding.PSS.DIGEST_LENGTH), H[h]())
    except InvalidSignature:
        bad.append((i, f"pss {h} over {key.key_size} bits does not verify"))
if bad:
    print(f"  {len(bad)} of {len(cases)} signatures wrong:")
    for i, why in bad[:6]:
        print(f"    case {i}: {why}")
    sys.exit(1)
v15 = sum(1 for c in cases if c.split()[1] == "v15")
print(f"  {len(cases)} signatures over {', '.join(str(b) for b in sorted(sizes))}-bit keys: {v15} PKCS #1 v1.5 byte for byte cryptography's, {len(cases) - v15} PSS verified by it")
PY
  then
    status=1
  fi
  refusals=0
  while IFS='|' read -r path why; do
    [ -n "$path" ] || continue
    printf '%s pss SHA256 00\n' "$path" >"$WORK/one.txt"
    got="$("$WORK/rsa-release" sign "$WORK/one.txt" 2>&1)"
    if printf '%s' "$got" | grep -qF -e "$why"; then
      refusals=$((refusals + 1))
    else
      echo "  $(basename "$path"): expected \"$why\", got: $got"
      status=1
    fi
  done <"$WORK/sign_cases.txt"
  echo "  $refusals keys cryptography wrote refused, each for its reason: a 3072-bit key with n, d, dp, dq or qi broken, a 1024-bit key"

  echo
  echo "== signing time, --release"
  # Not a check: what a signature costs on this machine, PSS over SHA-256.
  "$WORK/rsa-release" time "$WORK/keys/k0.pem" 200 | sed 's/^/  /'
  "$WORK/rsa-release" time "$WORK/keys/k3.pem" 40 | sed 's/^/  /'
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
# Signing over SHA-1 is the program's mistake, not the key's: a panic
# that names it.
cat >"$WORK/sha1.iyi" <<'IYI'
module sha1

import std/rsa::{RsaPrivateKey, RsaHash}
import std/file::{File}
import std/env::{ENV}

RsaPrivateKey.from_pem(File.read(ENV["RSA_KEY"])).or_panic.sign_pss(RsaHash::SHA1, "abc")
puts "signed"
IYI
if [ ! -s "$WORK/keys/k0.pem" ]; then
  echo "  no key drawn here, so a signature over SHA-1 goes unasked"
elif RSA_KEY="$WORK/keys/k0.pem" "$IYI" run "$WORK/sha1.iyi" >"$WORK/sha1.out" 2>&1; then
  echo "  a signature over SHA-1 was made"
  status=1
elif ! grep -qF "rsa: a signature over SHA-1, which this checks and does not make" "$WORK/sha1.out"; then
  echo "  a signature over SHA-1 was refused without saying why: $(tr -d '\r' <"$WORK/sha1.out" | tail -1)"
  status=1
else
  echo "  rsa: a signature over SHA-1, which this checks and does not make"
fi

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/rsa.iyi" >"$WORK/doc.txt" 2>&1 && grep -q "sign_pss" "$WORK/doc.txt"; then
  echo "  iyi doc reads std/rsa, RsaPrivateKey's signing included"
else
  echo "  FAIL: iyi doc: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/rsa.iyi" "$REPO/bench/std_rsa_exercise.iyi" >"$WORK/format.log" 2>&1; then
  echo "  the module and its exercise are formatted"
else
  echo "  FAIL: not formatted: $(grep -m1 produced "$WORK/format.log")"
  status=1
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_rsa_exercise.iyi" >"$WORK/cross.log" 2>&1; then
    echo "  $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross.log")"
    apart="$apart $target"
  fi
done
if [ -n "$apart" ]; then
  echo "  FAIL: does not typecheck for$apart"
  status=1
else
  echo "  the exercise typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
fi
mkdir -p "$WORK/r1"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_rsa_exercise.iyi" &&
  "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_rsa_exercise.iyi") >"$WORK/r1/build.log" 2>&1; then
  "$WORK/r1/from-source" >"$WORK/r1/source.out" 2>&1
  "$WORK/r1/from-artifact" >"$WORK/r1/artifact.out" 2>&1
  if cmp -s "$WORK/r1/source.out" "$WORK/r1/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
    echo "  built from its artifacts, the exercise prints what it prints from source"
  else
    echo "  FAIL: from its artifacts the exercise prints otherwise:"
    diff "$WORK/r1/source.out" "$WORK/r1/artifact.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
else
  echo "  FAIL: the artifacts did not build: $(grep -m1 -E 'Error|BUG' "$WORK/r1/build.log")"
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
  'unless oid == RSA_ENCRYPTION
    unless algorithm.size == 2 && algorithm[1].universal?(DerTag::NULL) && !algorithm[1].null.is_a?(Asn1Error)' 'unless oid == RSA_ENCRYPTION
    if false'
# The private key's own checks, each against the key the exercise breaks
# for it, and the signing.
prove_broken "a private key's p times q unchecked" "a modulus that is not p times q refused" \
  '    return RsaError.new("a private key whose p times q is not its modulus") unless bp * bq == n' ''
prove_broken "a private key's d unchecked" "a d that is not e's inverse refused" \
  "unless (e * bd) % p1.lcm(q1) == one" "if false"
prove_broken "a private key's dp unchecked" "a dp that is not d's residue refused" \
  '    return RsaError.new("a private key whose dp is not d mod (p - 1)") unless bd % p1 == bdp' ''
prove_broken "a private key's dq unchecked" "a dq that is not d's residue refused" \
  '    return RsaError.new("a private key whose dq is not d mod (q - 1)") unless bd % q1 == bdq' ''
prove_broken "a private key's qi unchecked" "a qi that is not q's inverse refused" \
  'unless bqi < bp && (bqi * bq) % bp == one' 'if false'
# Without the check a p of 1 is no error value: lcm(0, q - 1) is 0, and
# the d check divides by it.
prove_broken "p and q unchecked: a p of 1 panics" "modulo by zero" \
  'unless bp > one && bq > one' 'if false'
prove_broken "a 1024-bit key taken for signing" "a 1024-bit key refused for signing" \
  '  MIN_BITS        = 2048' '  MIN_BITS        = 1024'
prove_broken "a key of three primes read as two" "a key of more than two primes refused" \
  '    if version.is_a?(Int64) && version == 1_i64' '    if false'
prove_broken "an RSASSA-PSS key read as rsaEncryption" "an RSASSA-PSS key refused by name" \
  ' if oid == RSASSA_PSS' ' if false'
prove_broken "a PKCS #8 key's parameters unchecked" "a PKCS #8 key without rsaEncryption's NULL refused" \
  'unless oid == RsaPublicKey::RSA_ENCRYPTION
    unless algorithm.size == 2 && algorithm[1].universal?(DerTag::NULL) && !algorithm[1].null.is_a?(Asn1Error)' 'unless oid == RsaPublicKey::RSA_ENCRYPTION
    if false'
prove_broken "an encrypted key read as base64" "an encrypted key refused by name" \
  '    if text.includes?("-----BEGIN ENCRYPTED PRIVATE KEY-----") || text.includes?(ENCRYPTED_PKCS1)' '    if false'
# A fault in one half of the CRT: the check before the signature goes out
# must be what stops it, by its own sentence.
prove_broken "a fault in the CRT's first half" "does not check against its own public key, which a fault makes" \
  '    s1 = (c % @p).pow_mod_secret(@dp, @p)' '    s1 = (c % @p).pow_mod_secret(@dp, @p) + BigInt.new(1)'
prove_broken "the blinding left on the signature" "does not check against its own public key, which a fault makes" \
  '    s = ((s2 + h * @q) * r_inverse) % @n' '    s = (s2 + h * @q) % @n'
prove_broken "the CRT's recombination by p's inverse" "does not check against its own public key, which a fault makes" \
  '    h = (@qi * (s1 - s2)) % @p' '    h = (s1 - s2) % @p'
prove_broken "PKCS #1 v1.5 signed with a block type of 2" "PKCS #1 v1.5 over SHA256 as cryptography signs it" \
  '    em[1] = 1_u8
    em[size - t.size - 1] = 0_u8' '    em[1] = 2_u8
    em[size - t.size - 1] = 0_u8'
prove_broken "a PSS salt a byte short of the hash" "a PSS signature over SHA256 checks with a salt as long as the hash" \
  '    db = Array(UInt8).new(db_len - h_len - 1, 0_u8) + [1_u8] + salt' '    db = Array(UInt8).new(db_len - h_len, 0_u8) + [1_u8] + salt[1, h_len - 1]'
prove_broken "PSS signed without the eight zero bytes" "a PSS signature over SHA256 checks with a salt as long as the hash" \
  '    h = hash.digest(Array(UInt8).new(8, 0_u8) + m_hash + salt)' '    h = hash.digest(m_hash + salt)'
prove_broken "PSS's mask over the salt, not H" "a PSS signature over SHA256 checks with a salt as long as the hash" \
  '    mask = RsaBytes.mgf1(hash, h, db_len)
    masked = ' '    mask = RsaBytes.mgf1(hash, salt, db_len)
    masked = '

echo
if [ "$status" -eq 0 ]; then
  echo "the std/rsa exercise holds ($mutations breaks caught)"
else
  echo "the std/rsa exercise did not hold"
fi
exit $status
