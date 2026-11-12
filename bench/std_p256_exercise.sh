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
# refuses the ones that are not P-256's; reads in the --release assembly
# how a table's entry is picked by a secret digit, and in the IR how the
# fixed-base table's address reaches a second thread; and proves on broken
# copies of the module that the checks fail where they say.
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
  "== every hash, checked by std/ecdsa" "== what is not a private key" "== Diffie-Hellman (ECDH)"; do
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
echo "== 500 shared secrets against Python's cryptography"
# d at random and from the edges against a peer's key Python makes; then
# peer points that are not P-256's - off the curve, an x of p and of
# 2^256 - 1, the identity's zeros - which must be refused, as Python
# refuses them.
if [ "$HAVE_ORACLE" -ne 1 ]; then
  echo "  no python cryptography here, so the shared secrets go uncompared"
else
  "$PY" - "$WORK/ecdh.txt" "$WORK/ecdh-want.txt" <<'PY'
import os, random, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
n = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551
p = 2**256 - 2**224 + 2**192 + 2**96 - 1
rng = random.Random(int.from_bytes(os.urandom(8), "big"))
edges = [1, 2, n - 1, n - 2, 2**255, 2**128]
cases, want = [], []
for i in range(500):
    d = edges[i] if i < len(edges) else rng.randrange(1, n)
    own = ec.derive_private_key(d, ec.SECP256R1())
    peer = ec.generate_private_key(ec.SECP256R1())
    point = peer.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    cases.append(f"{d:064x} {point.hex()}")
    want.append(own.exchange(ec.ECDH(), peer.public_key()).hex())
good = ec.generate_private_key(ec.SECP256R1()).public_key().public_numbers()
bad = [(good.x, (good.y + 1) % p), (p, good.y), (2**256 - 1, good.y), (0, 0)]
for x, y in bad:
    point = b"\x04" + x.to_bytes(32, "big") + y.to_bytes(32, "big")
    try:
        ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), point)
        verdict = "taken"
    except ValueError:
        verdict = "refused"
    cases.append(f"{rng.randrange(1, n):064x} {point.hex()}")
    want.append(verdict)
open(sys.argv[1], "w", newline="\n").write("\n".join(cases) + "\n")
open(sys.argv[2], "w", newline="\n").write("\n".join(want) + "\n")
PY
  "$WORK/p256-release" ecdh "$WORK/ecdh.txt" >"$WORK/ecdh-got.txt" 2>&1
  if diff "$WORK/ecdh-want.txt" "$WORK/ecdh-got.txt" >"$WORK/ecdh.diff"; then
    echo "  500 shared secrets as Python's, 6 keys from the edges; 4 points Python refuses refused"
  else
    echo "  FAIL: $(grep -c '^<' "$WORK/ecdh.diff") of 504 differ from Python's:"
    head -n 6 "$WORK/ecdh.diff" | sed 's/^/    /'
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
echo "== how a table's entry is picked, read off the machine code"
# A selector made from a digit of the nonce or the key is 0 or 1, and a
# compiler that sees so may pick the entry with a conditional jump on the
# digit, or by reading one entry's address: the same signatures, so
# nothing above shows it, and a timing shows the first on a quiet machine
# and never the second. The instructions do. A small program's --release
# assembly is read for two pinned targets, whatever the host is
# (`--cross-compile` writes the assembly and links nothing, so neither
# target's toolchain is needed). `P256BaseTable.pick`, `P256BaseTable.top`
# and `P256Point.lookup` each have to hold the value barriers their
# selectors go through (an empty `#APP`/`#NO_APP` pair is what std/digest's
# `ValueBarrier` leaves), no conditional move in them may keep one of two
# pointers that a load then reads through, and their only conditional
# jumps may be their loop's and their counters' checks.
cat >"$WORK/pick.iyi" <<'IYI'
module pick

import std/p256::{P256PrivateKey}
import std/ecdsa::{EcdsaHash, EcdsaError}

def bytes_of(seed : Int32) : Array(UInt8)
  Array(UInt8).new(32) { |i| ((i * 37 + seed * 11 + 1) & 0x7f).to_u8 }
end

key = P256PrivateKey.from_bytes(bytes_of(Program.args.size)).or_panic
other = P256PrivateKey.from_bytes(bytes_of(Program.args.size + 1)).or_panic
puts key.sign(EcdsaHash::SHA256, "hello").size
shared = key.shared_secret(other.public_point)
puts shared.is_a?(EcdsaError) ? "refused" : shared.size
IYI
# machine.py FILE.s FUNCTION BARRIERS [lookup]: what in FUNCTION's
# instructions picks by a secret where a mask should, a line each.
cat >"$WORK/machine.py" <<'PY'
import re, sys
path, name, need, leaf = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:] == ["lookup"]
body, inside = [], False
for line in open(path, encoding="utf-8", errors="replace"):
    line = line.rstrip("\n")
    if not inside:
        inside = line.startswith('"') and line.endswith('":') and name in line
    elif line.startswith("\t.size\t"):
        break
    elif line.strip() and not line.startswith("\t.") and not line.startswith(".Ltmp"):
        body.append(line.strip())
if not body:
    raise SystemExit(f"no function named {name} in the assembly, so nothing of it was read")
found = []
barriers = sum(1 for a, b in zip(body, body[1:]) if a.endswith("APP") and b.endswith("NO_APP") and not a.endswith("NO_APP"))
if barriers < need:
    found.append(f"{name}: not the {need} value barriers its source asks for in its machine code, but {barriers}")
code = [l for l in body if not l.endswith("APP")]
labels = {l[:-1]: i for i, l in enumerate(code) if l.endswith(":")}
split = lambda l: (l.split(None, 1) + [""])[:2]
leaves = re.compile(r"j\w+|b|bl|blr|br|b\.\w+|cbn?z|tbn?z|call|ret")
for i, l in enumerate(code):
    op, args = split(l)
    # A pointer kept by a conditional move and then read through: which of
    # the two it was is the address of that load.
    kept = re.match(r"(r[a-z0-9]+|x\d+),", args) if re.fullmatch(r"cmov\w+|csel", op) else None
    if kept and not re.search(r"\d[dwb]$", kept.group(1)):
        reg = kept.group(1)
        for later in code[i + 1:i + 13]:
            lop, largs = split(later)
            if later.endswith(":") or leaves.fullmatch(lop):
                break
            if re.search(r"\[[^\]]*\b" + reg + r"\b", largs):
                found.append(f"{name}: `{' '.join(l.split())}` keeps one of two pointers and `{' '.join(later.split())}` reads through it")
                break
            first, _, rest = largs.partition(",")
            if first == reg and not re.search(r"\b" + reg + r"\b", rest):
                break
    # In a lookup a conditional jump is its loop going round, or a check of
    # a counter (an overflow, an index past the table) leaving for a panic;
    # any other is a branch on what was looked up.
    if leaf and re.fullmatch(r"j(?!mp)\w+|b\.\w+|cbn?z|tbn?z", op):
        at = labels.get(args.split(",")[-1].strip(), -1)
        block = []
        for later in code[at + 1:at + 25] if at > i else []:
            if later.endswith(":") or split(later)[0] in ("ret", "jmp", "b", "br"):
                break
            block.append(later)
        if at > i and not any("raise" in x for x in block):
            found.append(f"{name}: `{' '.join(l.split())}` is neither its loop nor a counter's check")
print("\n".join(found), end="\n" if found else "")
sys.exit(1 if found else 0)
PY
# machine_code <search path> <dir>: what is wrong with the picks built from
# <search path>, a line each, and 1 if anything is.
machine_code() {
  local target wrong=0 name count mode
  mkdir -p "$2"
  for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    if ! IYI_PATH="$1" "$IYI" build --release --emit asm,llvm-ir --x86-asm-syntax intel --cross-compile --target "$target" \
      -o "$2/$target" "$WORK/pick.iyi" >"$2/$target.log" 2>&1 || [ ! -s "$2/$target.s" ]; then
      echo "$target: no assembly was written: $(grep -m1 -E 'Error|BUG' "$2/$target.log")"
      wrong=1
      continue
    fi
    while read -r name count mode; do
      if ! "$PY" "$WORK/machine.py" "$2/$target.s" "$name" "$count" $mode >"$2/$target.read" 2>&1; then
        sed "s/^/$target: /" "$2/$target.read"
        wrong=1
      fi
    done <<'READ'
P256BaseTable::pick< 3 lookup
P256BaseTable::top< 1 lookup
P256Point::lookup< 1 lookup
READ
  done
  return $wrong
}
if [ -z "$PY" ]; then
  echo "  no python here to read the assembly with, so the picks' machine code goes unread"
elif machine_code "$IYI_PATH" "$WORK/machine" >"$WORK/machine.out"; then
  echo "  x86_64 and aarch64, --release: every selector goes through its barrier, every entry is read and masked, and nothing branches but the loops"
else
  sed 's/^/  /' "$WORK/machine.out"
  status=1
fi

echo
echo "== how the table's address reaches a second thread, read off the IR"
# The fixed-base table is worked out by the first thread that wants it,
# and a second thread must never read it part written: a wrong multiple
# gives a signature a wrong point under the right nonce, which beside the
# right signature of the same message gives the key away. On x86_64 a
# plain store of the table's address after its entries is seen in that
# order by every thread; on a machine that orders its stores loosely it is
# not, and no run on this one would show it. So it is read off the IR of
# the program built above (x86_64's, the orderings being the module's
# request and the same for every target): every read of the word the
# address is kept in has to be an acquire load and its one write a release
# store.
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
if [ -z "$PY" ]; then
  echo "  no python here, so the program above was not built and its IR goes unread"
elif published "$WORK/machine/x86_64-unknown-linux-gnu.ll" 'Std::P256::P256BaseTable::table' >"$WORK/published.out"; then
  echo "  the table's address is read by an acquire load and written, once the table is whole, by a release store"
else
  sed 's/^/  /' "$WORK/published.out"
  status=1
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
# [d]Q's window over a peer's point; [d]G has a table of its own now, so
# it is the first shared secret that sees this one wrong.
prove_broken "a constant-time lookup that answers the next entry" "RFC 5903's girx, from the initiator" \
  '      bit = ValueBarrier.u64(((i.to_u64 ^ digit) &- 1_u64).unsafe_shr(63))' '      bit = ValueBarrier.u64(((i.to_u64 ^ (digit &+ 1_u64)) &- 1_u64).unsafe_shr(63))'
# The fixed-base table's three ways to go wrong. Its rows read one entry
# along answer nothing for a digit of 8, (0, 0), which is off the curve,
# and so is what it is added into. A digit's sign dropped, or the
# recoding's last carry left out (RFC 6979's d starts 0xc9, so its top
# digit carries), still lands on the curve, so it is the key's x that
# shows it.
prove_broken "a fixed-base lookup that answers the next entry" "a point that is not on P256" \
  '      bit = ValueBarrier.u64(((j.to_u64 ^ index) &- 1_u64).unsafe_shr(63))' '      bit = ValueBarrier.u64(((j.to_u64 ^ (index &+ 1_u64)) &- 1_u64).unsafe_shr(63))'
prove_broken "a fixed-base digit whose sign is dropped" "the key's x" \
  '    y = P256Num.choose(negative, f.sub(P256Num.zero, y), y)' '    y = P256Num.choose(0_u64, f.sub(P256Num.zero, y), y)'
prove_broken "the fixed-base recoding's last carry left out" "the key's x" \
  '    acc + P256BaseTable.top(table, carry)' '    acc'
# The order's inverse is the generic one, used for s alone.
prove_broken "an inverse to the power m - 3" "the signature of \"sample\" under SHA-256" \
  '    e = P256Num.sub_raw(@m, P256Num.new(2_u64, 0_u64, 0_u64, 0_u64))[0]' '    e = P256Num.sub_raw(@m, P256Num.new(3_u64, 0_u64, 0_u64, 0_u64))[0]'
# The field's inverse is the addition chain; short of its last product
# it is z^(p - 3), and the public key it encodes is off the curve.
prove_broken "a field inverse short of its last product" "a point that is not on P256" \
  '    f.mul(f.square_times(r, 2), a)' '    f.square_times(r, 2)'
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
prove_broken "a peer point off the curve taken" "a point off the curve: accepted" \
  '    return EcdsaError.new("a point that is not on P-256") unless f.square(ym).to_bytes == right.to_bytes' ''
prove_broken "a peer coordinate of p or more taken" "a point whose x is p: accepted" \
  '    unless P256Num.below?(x, P256Num.p) && P256Num.below?(y, P256Num.p)' '    if false'
prove_broken "[d]G answered for [d]Q" "RFC 5903's girx, from the initiator" \
  '    P256Point.mult(q, @d).affine_x.to_bytes' '    P256Point.base_mult(@d).affine_x.to_bytes'
prove_broken "the table built from G whatever the point" "RFC 5903's girx, from the initiator" \
  '      table[i] = table[i - 1] + point' '      table[i] = table[i - 1] + P256Point.base'
prove_broken "SEC 1's curve unchecked" "an ECPrivateKey naming P-384: accepted" \
  '        return EcdsaError.new("the private key names a curve that is not prime256v1") unless oid == P256Point::CURVE_OID' ''
# prove_unmasked <label> <phrase> <old> <new>: the exercise cannot tell a
# pick by masks from one a compiler was left free to make a choice of, the
# answers being the same; the reading of the machine code has to, with
# <phrase> in what it says, for both targets.
# patched_copy <old> <new>: a copy of the module with <old>, which it has
# once, replaced, under $WORK/patched.
patched_copy() {
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$1" NEW="$2" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/p256.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/p256.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8", newline="\n")
PY
}
prove_unmasked() {
  mutations=$((mutations + 1))
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! patched_copy "$3" "$4"; then
    echo "  the $1 patch did not apply"
    status=1
  elif machine_code "$WORK/patched${PSEP}$IYI_PATH" "$WORK/patched/machine" >"$WORK/mut.out"; then
    echo "  the machine code of $1 was read as sound"
    status=1
  elif [ "$(grep -cF "$2" "$WORK/mut.out")" -eq 2 ]; then
    echo "  $1 is caught, on both targets"
  else
    echo "  $1 was refused, but not for what it is:"
    sed 's/^/    /' "$WORK/mut.out"
    status=1
  fi
}
prove_unmasked "a fixed-base selector the compiler can see" "P256BaseTable::pick<: not the 3 value barriers" \
  '      bit = ValueBarrier.u64(((j.to_u64 ^ index) &- 1_u64).unsafe_shr(63))' '      bit = ((j.to_u64 ^ index) &- 1_u64).unsafe_shr(63)'
prove_unmasked "a window selector the compiler can see" "P256Point::lookup<: not the 1 value barriers" \
  '      bit = ValueBarrier.u64(((i.to_u64 ^ digit) &- 1_u64).unsafe_shr(63))' '      bit = ((i.to_u64 ^ digit) &- 1_u64).unsafe_shr(63)'
prove_unmasked "the last carry's selector in the compiler's sight" "P256BaseTable::top<: not the 1 value barriers" \
  '    carry = ValueBarrier.u64(carry)
' ''
# What stood in for the barrier before: each selector xored with a zero
# read by an atomic load from a class variable. Nothing ever writes that
# variable, so an optimising build knows the zero and the xor is gone
# from its instructions.
prove_unmasked "the selectors xored with a zero no one writes, as they were" "P256BaseTable::pick<: not the 3 value barriers" \
  '  @[NoInline]
  def self.pick(table : Pointer(P256Num), row : Int32, digit : UInt64) : P256Point
    f = P256Modulus.field
    negative = ValueBarrier.u64(digit.unsafe_shr(63))
    index = (digit ^ (0_u64 &- negative)) &+ negative
    x = P256Num.zero
    y = P256Num.zero
    base = table + (row * 16).to_i64
    j = 1
    while j <= 8
      bit = ValueBarrier.u64(((j.to_u64 ^ index) &- 1_u64).unsafe_shr(63))
      x = P256Num.choose(bit, base[2 * j - 2], x)
      y = P256Num.choose(bit, base[2 * j - 1], y)
      j = j + 1
    end
    y = P256Num.choose(negative, f.sub(P256Num.zero, y), y)
    nonzero = ValueBarrier.u64((index | (0_u64 &- index)).unsafe_shr(63))' '  @@opaque = ::Atomic(UInt64).new(0_u64)

  @[NoInline]
  def self.pick(table : Pointer(P256Num), row : Int32, digit : UInt64) : P256Point
    f = P256Modulus.field
    zero = @@opaque.get
    negative = digit.unsafe_shr(63) ^ zero
    index = (digit ^ (0_u64 &- negative)) &+ negative
    x = P256Num.zero
    y = P256Num.zero
    base = table + (row * 16).to_i64
    j = 1
    while j <= 8
      bit = ((j.to_u64 ^ index) &- 1_u64).unsafe_shr(63) ^ zero
      x = P256Num.choose(bit, base[2 * j - 2], x)
      y = P256Num.choose(bit, base[2 * j - 1], y)
      j = j + 1
    end
    y = P256Num.choose(negative, f.sub(P256Num.zero, y), y)
    nonzero = (index | (0_u64 &- index)).unsafe_shr(63) ^ zero'
# prove_unpublished <label> <phrase> <old> <new>: nor can the exercise tell
# how the table's address reaches a second thread; the reading of the IR
# has to refuse the copy, with <phrase> in what it says.
prove_unpublished() {
  mutations=$((mutations + 1))
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! patched_copy "$3" "$4"; then
    echo "  the $1 patch did not apply"
    status=1
  elif ! machine_code "$WORK/patched${PSEP}$IYI_PATH" "$WORK/patched/machine" >"$WORK/mut.out"; then
    echo "  $1: its picks' machine code was refused, which is not what it breaks:"
    sed 's/^/    /' "$WORK/mut.out"
    status=1
  elif published "$WORK/patched/machine/x86_64-unknown-linux-gnu.ll" 'Std::P256::P256BaseTable::table' >"$WORK/mut.out"; then
    echo "  the IR of $1 was read as sound"
    status=1
  elif grep -qF "$2" "$WORK/mut.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 was refused, but not for what it is:"
    sed 's/^/    /' "$WORK/mut.out"
    status=1
  fi
}
prove_unpublished "a table's address stored with no ordering" "no release store to it" \
  '    @@table.set_release(table.address)' '    @@table.set_relaxed(table.address)'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/p256 exercise holds ($mutations breaks caught)"
else
  echo "the std/p256 exercise did not hold"
fi
exit $status
