#!/usr/bin/env bash
# Exercises `std/curve25519`.
#
#     bash bench/std_curve25519_exercise.sh
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

# Python's `cryptography` (OpenSSL underneath) is the oracle where it is
# installed; without it the comparisons say so and the rest still runs.
HAVE_CRYPTOGRAPHY=0
if [ -n "$PY" ] && "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import ed25519, x25519' >/dev/null 2>&1; then
  HAVE_CRYPTOGRAPHY=1
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_curve25519_exercise.iyi" \
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

echo "== the std/curve25519 exercise, plain build"
build_and_run "plain" curve-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/curve-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every curve25519 section reported"
for phrase in "== x25519 (rfc 7748 section 5.2)" "== x25519 iterated (rfc 7748 section 5.2)" \
  "== x25519 diffie-hellman (rfc 7748 section 6.1)" "== x25519 refusals" \
  "== ed25519 (rfc 8032 section 7.1)" "== ed25519 strict verification"; do
  if ! grep -qF "$phrase" "$WORK/curve-plain.out" 2>/dev/null; then
    echo "  missing: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

# The release build runs RFC 7748's millionth iteration as well, which
# took about 25 seconds of the run on the machine this was written on.
echo
echo "== the same program with optimisation on (--release), the 1,000,000 iterations included"
build_and_run "release" curve-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/curve-release.out" 2>/dev/null; then
  echo "release: ALL CHECKS PASSED missing"
  sed 's/^/  /' "$WORK/curve-release.out" | tail -3
  status=1
elif ! grep -qF "1, 1,000 and 1,000,000 iterations" "$WORK/curve-release.out"; then
  echo "release: the 1,000,000-iteration vector did not run"
  status=1
else
  echo "  ALL CHECKS PASSED, 1,000,000 iterations among them"
fi

# One program reads cases from its standard input, a line each, and
# answers a line each; Python writes the cases and reads the answers
# against `cryptography`'s own.
#
#     x <private> <peer>      -> <public of private> <shared secret | refused>
#     s <seed> <message>      -> <public key> <signature>
#     v <public> <message> <signature> -> true | false
#
# Everything is hex; an empty message is "-".
cat >"$WORK/oracle.iyi" <<'IYI'
module oracle

import std/curve25519::{X25519, Ed25519, CurveError}

def b(hex : String) : String
  return "" if hex == "-"
  p = hex.to_unsafe
  String.new(hex.bytesize // 2) do |buf|
    i = 0
    while i < hex.bytesize // 2
      hi = p[i * 2].to_i32
      lo = p[i * 2 + 1].to_i32
      hi = hi >= 97 ? hi - 87 : hi - 48
      lo = lo >= 97 ? lo - 87 : lo - 48
      buf[i] = (hi * 16 + lo).to_u8
      i = i + 1
    end
  end
end

def hex(s : String) : String
  digits = "0123456789abcdef".to_unsafe
  String.new(s.bytesize * 2) do |buf|
    p = s.to_unsafe
    i = 0
    while i < s.bytesize
      buf[i * 2] = digits[p[i] >> 4]
      buf[i * 2 + 1] = digits[p[i] & 15_u8]
      i = i + 1
    end
  end
end

while line = STDIN.gets(chomp: true)
  f = line.split(' ')
  case f[0]
  when "x"
    secret = X25519.shared(b(f[1]), b(f[2]))
    puts "#{hex(X25519.public_key(b(f[1])))} #{secret.is_a?(CurveError) ? "refused" : hex(secret)}"
  when "s"
    puts "#{hex(Ed25519.public_key(b(f[1])))} #{hex(Ed25519.sign(b(f[1]), b(f[2])))}"
  when "v"
    puts Ed25519.verify(b(f[1]), b(f[2]), b(f[3]))
  end
end
IYI
ORACLE_OK=0
if [ "$HAVE_CRYPTOGRAPHY" -eq 1 ]; then
  if "$IYI" build -o "$WORK/oracle" "$WORK/oracle.iyi" >"$WORK/oracle.build.log" 2>&1; then
    ORACLE_OK=1
  else
    echo "  the oracle program did not build: $(tail -1 "$WORK/oracle.build.log")"
    status=1
  fi
fi

echo
echo "== x25519 against python's cryptography, both ways"
# 2,000 cases. 1,600 against a key pair cryptography made: iyi's public
# key must be cryptography's for the same private key, iyi's secret must
# be the one cryptography computes from either side. 300 against 32 random
# bytes as the peer's u (half of them with bit 255 set, and any of them
# possibly past p), and 100 against the seven small-order points, where
# cryptography raises and iyi must answer a CurveError.
if [ "$ORACLE_OK" -eq 1 ]; then
  "$PY" - "$WORK" <<'PY'
import os, random, sys, json
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives import serialization as ser
work = sys.argv[1]
rng = random.Random(20261015)
raw = lambda key: key.public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw)
small = ["00" * 32, "01" + "00" * 31, "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
         "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", "ec" + "ff" * 30 + "7f",
         "ed" + "ff" * 30 + "7f", "ee" + "ff" * 30 + "7f"]
cases = []
for i in range(2000):
    a = rng.randbytes(32)
    mine = X25519PrivateKey.from_private_bytes(a)
    if i < 1600:
        peer_key = X25519PrivateKey.from_private_bytes(rng.randbytes(32))
        peer, peer_private = raw(peer_key.public_key()), peer_key.private_bytes_raw().hex()
    elif i < 1900:
        peer, peer_private = bytearray(rng.randbytes(32)), None
        if i % 2:
            peer[31] |= 0x80
        peer = bytes(peer)
    else:
        peer, peer_private = bytes.fromhex(rng.choice(small)), None
    try:
        secret = mine.exchange(X25519PublicKey.from_public_bytes(peer)).hex()
    except ValueError:
        secret = "refused"
    cases.append({"a": a.hex(), "peer": peer.hex(), "public": raw(mine.public_key()).hex(), "secret": secret, "peer_private": peer_private})
open(os.path.join(work, "x_in.txt"), "w").write("".join(f"x {c['a']} {c['peer']}\n" for c in cases))
json.dump(cases, open(os.path.join(work, "x_cases.json"), "w"))
PY
  if ! "$WORK/oracle" <"$WORK/x_in.txt" >"$WORK/x_got.txt" 2>&1; then
    echo "  the x25519 cases did not run: $(tail -1 "$WORK/x_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys, json
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
work = sys.argv[1]
cases = json.load(open(os.path.join(work, "x_cases.json")))
got = [line.split() for line in open(os.path.join(work, "x_got.txt")).read().splitlines()]
bad = refused = back = 0
for i, (c, g) in enumerate(zip(cases, got + [["", ""]] * len(cases))):
    if g != [c["public"], c["secret"]]:
        if bad < 5:
            print(f"  case {i}: python {c['public'][:16]}.. {c['secret'][:16]}.., iyi {' '.join(x[:16] + '..' for x in g)}")
        bad += 1
        continue
    refused += c["secret"] == "refused"
    # The other way: the peer's private key with iyi's public key.
    if c["peer_private"]:
        theirs = X25519PrivateKey.from_private_bytes(bytes.fromhex(c["peer_private"]))
        if theirs.exchange(X25519PublicKey.from_public_bytes(bytes.fromhex(g[0]))).hex() != g[1]:
            print(f"  case {i}: python's secret from iyi's public key differs"); bad += 1
        back += 1
if len(got) != len(cases):
    print(f"  {len(got)} answers came back for {len(cases)} cases"); bad += 1
print(f"  {len(cases) - bad} of {len(cases)} cases agree with cryptography ({refused} refused by both); python computed the same secret from iyi's public key {back} times")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
else
  echo "  python's cryptography is not installed here, so x25519 goes uncompared with it"
fi

echo
echo "== ed25519 against python's cryptography, both ways"
# 1,500 seeds and messages (0 to 300 random bytes, a few to 4,096): iyi's
# public key and signature must be the ones cryptography makes (Ed25519
# signs deterministically), and cryptography must verify iyi's signature.
# Then 2,500 verifications, iyi's answer against cryptography's: a
# signature cryptography made, under its key and another, of its message
# and another, with one bit of R or S flipped, with S + L for S (the
# malleated twin), and under 32 random bytes as the key.
if [ "$ORACLE_OK" -eq 1 ]; then
  "$PY" - "$WORK" <<'PY'
import os, random, sys, json
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization as ser
from cryptography.exceptions import InvalidSignature
work = sys.argv[1]
rng = random.Random(20261016)
L = 2**252 + 27742317777372353535851937790883648493
raw = lambda key: key.public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw)
def verdict(public, message, signature):
    try:
        Ed25519PublicKey.from_public_bytes(public).verify(signature, message)
        return "true"
    except (InvalidSignature, ValueError):
        return "false"
def message():
    return rng.randbytes(rng.randint(0, 4096) if rng.random() < 0.02 else rng.randint(0, 300))
h = lambda data: data.hex() or "-"
lines, signs, checks = [], [], []
for _ in range(1500):
    seed, m = rng.randbytes(32), message()
    key = Ed25519PrivateKey.from_private_bytes(seed)
    signs.append({"public": raw(key.public_key()).hex(), "signature": key.sign(m).hex(), "message": m.hex()})
    lines.append(f"s {seed.hex()} {h(m)}")
kinds = ["good", "other key", "other message", "flipped bit", "S + L", "random key"]
for i in range(2500):
    kind = kinds[i % len(kinds)]
    key = Ed25519PrivateKey.from_private_bytes(rng.randbytes(32))
    public, m = raw(key.public_key()), message()
    signature = key.sign(m)
    if kind == "other key":
        public = raw(Ed25519PrivateKey.from_private_bytes(rng.randbytes(32)).public_key())
    elif kind == "other message":
        m = m + b"\x00" if rng.random() < 0.5 or not m else m[:-1]
    elif kind == "flipped bit":
        flipped = bytearray(signature)
        bit = rng.randrange(512)
        flipped[bit // 8] ^= 1 << (bit % 8)
        signature = bytes(flipped)
    elif kind == "S + L":
        s = int.from_bytes(signature[32:], "little") + L
        signature = signature[:32] + s.to_bytes(32, "little")
    elif kind == "random key":
        public = rng.randbytes(32)
    checks.append({"kind": kind, "want": verdict(public, m, signature)})
    lines.append(f"v {public.hex()} {h(m)} {signature.hex()}")
open(os.path.join(work, "e_in.txt"), "w").write("\n".join(lines) + "\n")
json.dump({"signs": signs, "checks": checks}, open(os.path.join(work, "e_cases.json"), "w"))
PY
  if ! "$WORK/oracle" <"$WORK/e_in.txt" >"$WORK/e_got.txt" 2>&1; then
    echo "  the ed25519 cases did not run: $(tail -1 "$WORK/e_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys, json
from collections import Counter
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature
work = sys.argv[1]
cases = json.load(open(os.path.join(work, "e_cases.json")))
got = open(os.path.join(work, "e_got.txt")).read().splitlines()
signs, checks = cases["signs"], cases["checks"]
bad = 0
if len(got) != len(signs) + len(checks):
    print(f"  {len(got)} answers came back for {len(signs) + len(checks)} cases"); bad += 1
got += [""] * (len(signs) + len(checks))
for i, c in enumerate(signs):
    g = got[i].split()
    if g != [c["public"], c["signature"]]:
        if bad < 5:
            print(f"  signing case {i}: python {c['public'][:16]}.. {c['signature'][:16]}.., iyi {got[i][:40]}..")
        bad += 1
        continue
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(g[0])).verify(bytes.fromhex(g[1]), bytes.fromhex(c["message"]))
    except InvalidSignature:
        print(f"  signing case {i}: python does not verify iyi's signature"); bad += 1
agree, accepted = Counter(), Counter()
for i, c in enumerate(checks):
    g = got[len(signs) + i]
    if g != c["want"]:
        if bad < 5:
            print(f"  verification case {i} ({c['kind']}): python {c['want']}, iyi {g}")
        bad += 1
        continue
    agree[c["kind"]] += 1
    accepted[c["kind"]] += g == "true"
print(f"  {len(signs)} public keys and signatures the same as cryptography's, each verified by it")
print(f"  {sum(agree.values())} of {len(checks)} verifications agree: " + ", ".join(f"{k} {accepted[k]}/{agree[k]} accepted" for k in agree))
if accepted["S + L"]:
    print("  a malleated signature (S + L) was accepted"); bad += 1
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
else
  echo "  python's cryptography is not installed here, so ed25519 goes uncompared with it"
fi

echo
echo "== where verify is stricter than python's cryptography"
# The exercise refuses two non-canonical spellings of the identity as a
# public key (y = p + 1, and x = 0 with the sign bit set) and takes the
# canonical one, with a signature that is (enc([S]B), S) for S = 12345.
# RFC 8032 §5.1.3 says decoding fails for both; this asks OpenSSL, through
# cryptography, what it does with the same three, and records it.
if [ "$HAVE_CRYPTOGRAPHY" -eq 1 ]; then
  "$PY" - <<'PY'
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature
forged = bytes.fromhex("ef4f62f8479733ad879cfaced3c89a9c39dd4fc795ef2efa1c3eafe4d729a081" + "3930" + "00" * 30)
said = []
for name, key, ours in [("the canonical identity", "01" + "00" * 31, "accepts"),
                        ("y = p + 1", "ee" + "ff" * 30 + "7f", "refuses"),
                        ("x = 0 with the sign bit", "01" + "00" * 30 + "80", "refuses")]:
    try:
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(key)).verify(forged, b"any message")
        theirs = "accepts"
    except (InvalidSignature, ValueError):
        theirs = "refuses"
    said.append(f"{name}: cryptography {theirs}, iyi {ours}")
print("  " + "\n  ".join(said))
PY
else
  echo "  python's cryptography is not installed here, so there is nothing to set beside the exercise's refusals"
fi

echo
echo "== what a ladder, a signature and a verification take"
# Recorded, not held to a figure: the time is the machine's as much as the
# code's. The best of five runs of 200, --release, in microseconds, against
# cryptography's when it is here.
cat >"$WORK/cost.iyi" <<'IYI'
module cost

import std/curve25519::{X25519, Ed25519}

def best_of(& : -> Nil) : Int64
  best = 0_i64
  5.times do |k|
    t0 = IyiMark.now_ns
    200.times { yield }
    took = (IyiMark.now_ns - t0).to_i64
    best = took if k == 0 || took < best
  end
  best // 200_000
end

private_key = "k" * 32
peer = X25519.public_key("p" * 32)
seed = "s" * 32
public = Ed25519.public_key(seed)
signature = Ed25519.sign(seed, "a message of some length, as a message is")
ok = true
ladder = best_of { X25519.shared(private_key, peer).or_panic }
sign = best_of { Ed25519.sign(seed, "a message of some length, as a message is") }
verify = best_of { ok = ok && Ed25519.verify(public, "a message of some length, as a message is", signature) }
raise "the timed signature did not verify" unless ok
puts "iyi: x25519 #{ladder} us, ed25519 sign #{sign} us, verify #{verify} us"
IYI
if "$IYI" build --release -o "$WORK/cost" "$WORK/cost.iyi" >"$WORK/cost.build.log" 2>&1 && "$WORK/cost" >"$WORK/cost.out" 2>&1; then
  echo "  $(cat "$WORK/cost.out")"
  if [ "$HAVE_CRYPTOGRAPHY" -eq 1 ]; then
    "$PY" - <<'PY'
import time
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
def best_of(f):
    best = None
    for _ in range(5):
        t = time.perf_counter()
        for _ in range(200):
            f()
        d = (time.perf_counter() - t) / 200
        best = d if best is None or d < best else best
    return int(best * 1e6)
mine = X25519PrivateKey.from_private_bytes(b"k" * 32)
peer = X25519PrivateKey.from_private_bytes(b"p" * 32).public_key()
key = Ed25519PrivateKey.from_private_bytes(b"s" * 32)
public = key.public_key()
m = b"a message of some length, as a message is"
signature = key.sign(m)
print(f"  cryptography (OpenSSL): x25519 {best_of(lambda: mine.exchange(peer))} us, ed25519 sign {best_of(lambda: key.sign(m))} us, verify {best_of(lambda: public.verify(signature, m))} us")
PY
  fi
else
  echo "  the timing did not build or run: $(tail -1 "$WORK/cost.build.log" "$WORK/cost.out" 2>/dev/null | tail -1)"
  status=1
fi

echo
echo "== what curve25519 refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/curve25519::{X25519, Ed25519}

case Program.args[0]
when "x25519-short-private"
  X25519.public_key("k" * 31)
when "x25519-long-private"
  X25519.shared("k" * 33, "p" * 32)
when "x25519-short-peer"
  X25519.shared("k" * 32, "p" * 31).or_panic
when "x25519-small-order"
  X25519.shared("k" * 32, "\u{1}" + "\0" * 31).or_panic
when "ed25519-empty-seed"
  Ed25519.public_key("")
when "ed25519-long-seed"
  Ed25519.sign("s" * 64, "message")
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
refuse x25519-short-private "X25519: a private key is 32 bytes, not 31"
refuse x25519-long-private "X25519: a private key is 32 bytes, not 33"
refuse x25519-short-peer "X25519: a public key is 32 bytes, not 31"
refuse x25519-small-order "X25519: the shared secret is all zero bytes: the peer's public key is a point of small order (RFC 7748 section 6.1)"
refuse ed25519-empty-seed "Ed25519: a seed is 32 bytes, not 0"
refuse ed25519-long-seed "Ed25519: a seed is 32 bytes, not 64"

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
src = Path("$REPO/src/std/curve25519.iyi").read_text()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/curve25519.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_curve25519_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a ladder whose a24 is 121666" "rfc 7748 section 5.2 vector 1" \
  'e.mul_small(121665_u64)' 'e.mul_small(121666_u64)'
prove_broken "a ladder that never swaps" "rfc 7748 section 5.2 vector 1" \
  '      mask = 0_u64 &- swap' '      mask = 0_u64'
prove_broken "a product that folds its top carry back without the 19" "rfc 7748 section 5.2 vector 1" \
  '    carried((r0.unsafe_to_u64 & MASK) &+ c4 &* 19_u64,' '    carried((r0.unsafe_to_u64 & MASK) &+ c4,'
prove_broken "a u whose top bit is not masked" "the top bit of u is masked" \
  '      w3.unsafe_shr(12) & MASK)' '      w3.unsafe_shr(12))'
# Without the last step of the reduction a value from p up stays as it
# is: the ladder's zero for u = 0 comes out as p's bytes, not zeros, and
# is not refused.
prove_broken "a reduction that leaves values from p up unreduced" "the small-order u 00000000... is refused" \
  '    r0 = v.l0 &+ c &* 19_u64' '    r0 = v.l0'
prove_broken "a constant-time lookup that answers the next entry" "rfc 8032 test 1: the public key" \
  '      diff = j.to_u64 ^ index' '      diff = j.to_u64 ^ (index &+ 1_u64)'
prove_broken "a group order one off" "rfc 8032 test 1: the signature" \
  'L0 = 0x5812631a5cf5d3ed_u64' 'L0 = 0x5812631a5cf5d3ec_u64'
prove_broken "a challenge hashed without the public key" "rfc 8032 test 1: the signature" \
  'challenge = SHA512.new.update(sig, 32).update(pp, 32).update(mp, mn).final' 'challenge = SHA512.new.update(sig, 32).update(mp, mn).final'
prove_broken "a verify that takes S of L or more" "a signature with S + L is refused" \
  '    return false unless CurveScalar.canonical?(sp + 32)' '    true'
prove_broken "a decoding that takes y of p or more" "a public key with y = p + 1 is refused" \
  '    y.to_bytes(ap)' '    ap.copy_from(src, 32)
    ap[31] = ap[31] & 127_u8'
prove_broken "a decoding that takes x = 0 with the sign bit set" "a public key of x = 0 with the sign bit set is refused" \
  '    return nil if sign == 1_u8 && x.zero?
' ''
prove_broken "a decoding that never sets x's sign" "rfc 8032 test 1: the signature verifies" \
  '    x = x.negate unless x.parity == sign' '    x = x * CurveField.one'

echo
if [ "$status" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit $status
