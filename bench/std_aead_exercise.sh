#!/usr/bin/env bash
# Exercises `std/aead`.
#
#     bash bench/std_aead_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_aead_exercise.iyi" \
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

echo "== the std/aead exercise, plain build"
build_and_run "plain" aead-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/aead-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every aead section reported"
for phrase in "== aes" "== aes-gcm" "== aes-gcm refuses what was not sealed" "== chacha20" \
              "== poly1305" "== poly1305 key generation" "== chacha20-poly1305" \
              "== chacha20-poly1305 refuses what was not sealed" "== errors are values"; do
  if ! grep -qx -- "$phrase" "$WORK/aead-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" aead-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/aead-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== std/aead reaches nothing"
# `iyi mod reach` reads a package's reach off its import lines and the C
# it declares, transitively through std; this is that rule for std/aead:
# what it imports, and what those import, declare no C and call no
# runtime hook, so a package that seals reaches no clock, entropy or
# file.
reached="std/aead"
todo="std/aead"
while [ -n "$todo" ]; do
  next=""
  for module in $todo; do
    for imported in $(sed -n 's/^import \(std\/[a-z_]*\).*/\1/p' "$REPO/src/$module.iyi"); do
      case " $reached " in
        *" $imported "*) ;;
        *) reached="$reached $imported"; next="$next $imported" ;;
      esac
    done
  done
  todo="$next"
done
bound=""
for module in $reached; do
  if grep -nE '^\s*(lib [A-Z]|fun [a-z_]|asm\(|@\[Link)|__iyi_' "$REPO/src/$module.iyi" >/dev/null; then
    bound="$bound $module"
  fi
done
if [ -n "$bound" ]; then
  echo "  FAIL: std/aead reaches the platform through:$bound"
  status=1
else
  echo "  std/aead imports$(echo " $reached" | sed 's/ std\/aead//'), and none of it calls C"
fi

echo
echo "== against python's cryptography"
# Python writes the cases and its own answers; one iyi program, --release,
# reads them on stdin. 3,000 AES-GCM messages (a thousand per key size)
# and 3,000 ChaCha20-Poly1305 ones, plaintexts of 0 to 300 bytes with the
# block edges (15, 16, 17, 63, 64, 65 ...) drawn often and one in fifty
# up to 5,000, additional data of 0 to 80: iyi seals each and opens
# Python's sealing; the sealed bytes must be Python's, Python must open
# iyi's, and iyi's opening must be the plaintext. Each case carries one
# tamper as well - a bit of the ciphertext or tag turned, the additional
# data or the nonce changed, the sealed bytes cut or grown - which iyi
# must refuse, as Python does. Then 500 ChaCha20 streams at random
# counters and 500 Poly1305 messages, each fed in random pieces, and
# 1,000 AES blocks both ways against Python's ChaCha20, Poly1305 and
# AES-ECB.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305; from cryptography.hazmat.primitives.poly1305 import Poly1305' >/dev/null 2>&1; then
  echo "  python's cryptography package is not installed here, so std/aead goes uncompared with it"
else
  cat >"$WORK/oracle.iyi" <<'IYI'
module oracle

import std/aead::{AES, AesGcm, ChaCha20, Poly1305, ChaCha20Poly1305, AeadError}
import std/text

# A field is "x" and then hex, so an empty one is still a field.
def b(field : String) : String
  p = field.to_unsafe + 1_i64
  size = (field.bytesize - 1) // 2
  String.new(size) do |buf|
    i = 0
    while i < size
      hi = p[i * 2].to_i32
      lo = p[i * 2 + 1].to_i32
      hi = hi >= 97 ? hi - 87 : hi - 48
      lo = lo >= 97 ? lo - 87 : lo - 48
      buf[i] = (hi * 16 + lo).to_u8
      i = i + 1
    end
  end
end

def x(bytes : String) : String
  digits = "0123456789abcdef".to_unsafe
  p = bytes.to_unsafe
  String.new(bytes.bytesize * 2 + 1) do |buf|
    buf[0] = 120_u8
    i = 0
    while i < bytes.bytesize
      buf[i * 2 + 1] = digits[p[i].to_i32 >> 4]
      buf[i * 2 + 2] = digits[p[i].to_i32 & 15]
      i = i + 1
    end
  end
end

def said(result : String | AeadError) : String
  result.is_a?(String) ? x(result) : "REFUSED"
end

def pieces(field : String) : Array(Int32)
  field == "-" ? [] of Int32 : field.split(',').map { |n| n.to_i }
end

while line = STDIN.read_line(chomp: true)
  f = line.split(' ')
  case f[0]
  when "gcm", "cp"
    key, nonce, plain, aad, theirs = b(f[1]), b(f[2]), b(f[3]), b(f[4]), b(f[5])
    if f[0] == "gcm"
      box = AesGcm.new(key)
      puts "#{x(box.seal(nonce, plain, aad))} #{said(box.open(nonce, theirs, aad))} #{said(box.open(b(f[6]), b(f[7]), b(f[8])))}"
    else
      box = ChaCha20Poly1305.new(key)
      puts "#{x(box.seal(nonce, plain, aad))} #{said(box.open(nonce, theirs, aad))} #{said(box.open(b(f[6]), b(f[7]), b(f[8])))}"
    end
  when "chacha"
    stream = ChaCha20.new(b(f[1]), b(f[2]), f[3].to_i64.to_u32)
    data = b(f[4])
    xored = ""
    at = 0
    pieces(f[5]).each do |n|
      xored = xored + stream.xor(data[at, n])
      at = at + n
    end
    puts x(xored + stream.xor(data[at, data.bytesize - at]))
  when "poly"
    mac = Poly1305.new(b(f[1]))
    data = b(f[2])
    at = 0
    pieces(f[3]).each do |n|
      mac.update(data[at, n])
      at = at + n
    end
    mac.update(data[at, data.bytesize - at])
    puts x(mac.final)
  when "aes"
    cipher = AES.new(b(f[1]))
    puts "#{x(cipher.encrypt_block(b(f[2])))} #{x(cipher.decrypt_block(b(f[2])))}"
  end
end
IYI
  if ! "$PY" - "$WORK" <<'PY'
import os, random, sys
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
from cryptography.hazmat.primitives.poly1305 import Poly1305

work = sys.argv[1]
rng = random.Random(20261015)
EDGES = [0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 63, 64, 65, 127, 128, 129, 255, 256, 257]

def size():
    roll = rng.random()
    if roll < 0.3:
        return rng.choice(EDGES)
    if roll < 0.32:
        return rng.randint(0, 5000)
    return rng.randint(0, 300)

def x(data):
    return "x" + data.hex()

def split(total):
    out = []
    left = total
    while left > 0 and rng.random() < 0.8:
        n = rng.randint(0, min(left, 150))
        out.append(n)
        left -= n
    return ",".join(map(str, out)) or "-"

def tamper(nonce, sealed, aad):
    kind = rng.randrange(6)
    if kind == 0:
        at = rng.randrange(len(sealed))
        sealed = sealed[:at] + bytes([sealed[at] ^ (1 << rng.randrange(8))]) + sealed[at + 1:]
    elif kind == 1:
        if aad and rng.random() < 0.7:
            at = rng.randrange(len(aad))
            aad = aad[:at] + bytes([aad[at] ^ (1 << rng.randrange(8))]) + aad[at + 1:]
        else:
            aad = aad + bytes([rng.randrange(256)])
    elif kind == 2:
        at = rng.randrange(12)
        nonce = nonce[:at] + bytes([nonce[at] ^ (1 << rng.randrange(8))]) + nonce[at + 1:]
    elif kind == 3:
        sealed = sealed[:rng.randrange(len(sealed))]
    elif kind == 4:
        sealed = sealed + bytes([rng.randrange(256)])
    else:
        # The tag moved to the front: every byte is there, in another order.
        sealed = sealed[-16:] + sealed[:-16]
        if len(sealed) == 16:
            sealed = bytes([sealed[0] ^ 1]) + sealed[1:]
    return nonce, sealed, aad

cases, expected = [], []
for i in range(6000):
    kind = "gcm" if i < 3000 else "cp"
    key = rng.randbytes([16, 24, 32][i % 3] if kind == "gcm" else 32)
    nonce = rng.randbytes(12)
    plain = rng.randbytes(size())
    aad = rng.randbytes(rng.choice([0, 0, rng.randint(0, 80)]))
    box = AESGCM(key) if kind == "gcm" else ChaCha20Poly1305(key)
    sealed = box.encrypt(nonce, plain, aad)
    t_nonce, t_sealed, t_aad = tamper(nonce, sealed, aad)
    try:
        box.decrypt(t_nonce, t_sealed, t_aad)
        raise SystemExit(f"case {i}: python opened its own tampered case")
    except InvalidTag:
        pass
    cases.append(" ".join([kind, x(key), x(nonce), x(plain), x(aad), x(sealed), x(t_nonce), x(t_sealed), x(t_aad)]))
    expected.append((kind, key, nonce, plain, aad, sealed))
for i in range(500):
    key, nonce = rng.randbytes(32), rng.randbytes(12)
    data = rng.randbytes(size())
    blocks = (len(data) + 63) // 64
    counter = rng.choice([0, 1, rng.randrange(2 ** 32 - blocks), 2 ** 32 - max(blocks, 1)])
    enc = Cipher(algorithms.ChaCha20(key, counter.to_bytes(4, "little") + nonce), None).encryptor()
    cases.append(" ".join(["chacha", x(key), x(nonce), str(counter), x(data), split(len(data))]))
    expected.append(("chacha", enc.update(data)))
for i in range(500):
    key = rng.randbytes(32)
    data = rng.randbytes(size())
    cases.append(" ".join(["poly", x(key), x(data), split(len(data))]))
    expected.append(("poly", Poly1305.generate_tag(key, data)))
for i in range(1000):
    key, block = rng.randbytes([16, 24, 32][i % 3]), rng.randbytes(16)
    cipher = Cipher(algorithms.AES(key), modes.ECB())
    cases.append(" ".join(["aes", x(key), x(block)]))
    expected.append(("aes", cipher.encryptor().update(block), cipher.decryptor().update(block)))
open(os.path.join(work, "cases.txt"), "w").write("\n".join(cases) + "\n")
import pickle
pickle.dump(expected, open(os.path.join(work, "expected.pickle"), "wb"))
PY
  then
    echo "  the cases were not written"
    status=1
  elif ! "$IYI" build --release -o "$WORK/oracle" "$WORK/oracle.iyi" >"$WORK/oracle.log" 2>&1; then
    echo "  the oracle program did not build"
    tail -12 "$WORK/oracle.log"
    status=1
  elif ! "$WORK/oracle" <"$WORK/cases.txt" >"$WORK/oracle.out" 2>"$WORK/oracle.err"; then
    echo "  the oracle program failed: $(tail -3 "$WORK/oracle.err")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, pickle, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

work = sys.argv[1]
expected = pickle.load(open(os.path.join(work, "expected.pickle"), "rb"))
got = open(os.path.join(work, "oracle.out")).read().splitlines()
bad = 0
def report(text):
    global bad
    bad += 1
    if bad <= 5:
        print("  " + text)
counts = {"gcm": 0, "cp": 0, "chacha": 0, "poly": 0, "aes": 0}
for i, want in enumerate(expected):
    if i >= len(got):
        report(f"case {i} and after: iyi answered nothing")
        break
    fields = got[i].split(" ")
    kind = want[0]
    if kind in ("gcm", "cp"):
        _, key, nonce, plain, aad, sealed = want
        mine, opened, tampered = fields
        mine = bytes.fromhex(mine[1:])
        box = AESGCM(key) if kind == "gcm" else ChaCha20Poly1305(key)
        name = f"case {i} ({kind}, {len(key)}-byte key, {len(plain)} bytes, {len(aad)} of additional data)"
        if mine != sealed:
            report(f"{name}: iyi sealed {mine.hex()[:32]}..., python {sealed.hex()[:32]}...")
            continue
        if box.decrypt(nonce, mine, aad) != plain:
            report(f"{name}: python did not open iyi's sealing to the plaintext")
            continue
        if opened == "REFUSED" or bytes.fromhex(opened[1:]) != plain:
            report(f"{name}: iyi opened python's sealing to {opened[:33]}")
            continue
        if tampered != "REFUSED":
            report(f"{name}: iyi opened a tampered sealing")
            continue
    elif kind == "aes":
        if fields != ["x" + want[1].hex(), "x" + want[2].hex()]:
            report(f"case {i} (aes): iyi {got[i]}, python x{want[1].hex()} x{want[2].hex()}")
            continue
    elif got[i] != "x" + want[1].hex():
        report(f"case {i} ({kind}): iyi {got[i][:33]}..., python x{want[1].hex()[:32]}...")
        continue
    counts[kind] += 1
print(f"  AES-GCM {counts['gcm']} of 3000 and ChaCha20-Poly1305 {counts['cp']} of 3000: iyi's sealing is python's and python opens it, iyi opens python's, and refuses each tampered one")
print(f"  ChaCha20 {counts['chacha']} of 500 and Poly1305 {counts['poly']} of 500 in random pieces, AES {counts['aes']} of 1000 blocks both ways")
sys.exit(1 if bad or len(got) != len(expected) else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== what sealing takes"
# Recorded, not held to a figure: the time is the machine's as much as the
# code's. 16 MiB sealed, the best of three, --release, against Python's
# cryptography (OpenSSL, AES-NI where the processor has it) when it is here.
cat >"$WORK/speed.iyi" <<'IYI'
module speed

import std/aead::{AesGcm, ChaCha20Poly1305}

def best(& : -> String) : Int64
  fastest = 0_i64
  3.times do |k|
    t0 = IyiMark.now_ns
    sealed = yield
    t = (IyiMark.now_ns - t0).to_i64
    raise "sealed #{sealed.bytesize} bytes" unless sealed.bytesize == (16 << 20) + 16
    fastest = t if k == 0 || t < fastest
  end
  fastest
end

size = 16 << 20
data = String.new(size) do |buf|
  i = 0
  while i < size
    buf[i] = (i & 255).to_u8
    i = i + 1
  end
end
nonce = "twelve bytes"
g128 = AesGcm.new("sixteen byte key")
g256 = AesGcm.new("thirty-two bytes of key material")
box = ChaCha20Poly1305.new("thirty-two bytes of key material")
a = best { g128.seal(nonce, data) }
c = best { g256.seal(nonce, data) }
d = best { box.seal(nonce, data) }
puts "iyi: AES-128-GCM #{size.to_i64 * 1000 // a} MB/s, AES-256-GCM #{size.to_i64 * 1000 // c} MB/s, ChaCha20-Poly1305 #{size.to_i64 * 1000 // d} MB/s"
IYI
if "$IYI" build --release -o "$WORK/speed" "$WORK/speed.iyi" >"$WORK/speed.log" 2>&1 && "$WORK/speed" >"$WORK/speed.out" 2>&1; then
  echo "  $(cat "$WORK/speed.out")"
  if [ -n "$PY" ] && "$PY" -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM' >/dev/null 2>&1; then
    "$PY" - <<'PY'
import time
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
data = bytes(i & 255 for i in range(16 << 20))
def best(box):
    fastest = None
    for _ in range(3):
        t = time.perf_counter()
        box.encrypt(b"twelve bytes", data, None)
        d = time.perf_counter() - t
        fastest = d if fastest is None or d < fastest else fastest
    return int(len(data) / fastest / 1e6)
print(f"  python's cryptography (OpenSSL): AES-128-GCM {best(AESGCM(b'sixteen byte key'))} MB/s, AES-256-GCM {best(AESGCM(b'thirty-two bytes of key material'))} MB/s, ChaCha20-Poly1305 {best(ChaCha20Poly1305(b'thirty-two bytes of key material'))} MB/s")
PY
  fi
else
  echo "  the timing did not build or run: $(tail -1 "$WORK/speed.log" "$WORK/speed.out" 2>/dev/null | tail -1)"
  status=1
fi

echo
echo "== what aead refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/aead::{AES, AesGcm, ChaCha20, Poly1305, ChaCha20Poly1305}

key16 = "sixteen byte key"
key32 = "thirty-two bytes of key material"
nonce = "twelve bytes"
case Program.args[0]
when "aes-key-15"
  AES.new("fifteen bytes!!")
when "aes-block-17"
  AES.new(key16).encrypt_block("seventeen bytes!!")
when "aes-decrypt-block-0"
  AES.new(key16).decrypt_block("")
when "gcm-key-20"
  AesGcm.new("twenty bytes of key!")
when "gcm-seal-nonce-8"
  AesGcm.new(key16).seal("8 bytes!", "plaintext")
when "gcm-open-nonce-16"
  AesGcm.new(key16).open("sixteen byte iv!", "sealed bytes and the tag")
when "chacha-key-16"
  ChaCha20.new(key16, nonce)
when "chacha-nonce-8"
  ChaCha20.new(key32, "8 bytes!")
when "chacha-counter-wraps"
  stream = ChaCha20.new(key32, nonce, 0xffffffff_u32)
  stream.xor(String.new(64) { |buf| 64.times { |i| buf[i] = 0_u8 } })
  stream.xor("one byte past block 2^32 - 1")
when "chacha-negative-count"
  ChaCha20.new(key32, nonce).xor(key32.to_unsafe, key32.to_unsafe, -1)
when "poly-key-16"
  Poly1305.new(key16)
when "poly-final-twice"
  mac = Poly1305.new(key32)
  mac.final
  mac.final
when "poly-update-after-final"
  mac = Poly1305.new(key32)
  mac.final
  mac.update("more")
when "poly-negative-count"
  Poly1305.new(key32).update(key32.to_unsafe, -1)
when "cp-key-31"
  ChaCha20Poly1305.new(key32[0, 31])
when "cp-nonce-24"
  ChaCha20Poly1305.new(key32).seal("an xchacha20 nonce: 24 b", "plaintext")
when "cp-open-nonce-0"
  ChaCha20Poly1305.new(key32).open("", "sealed bytes and the tag")
when "forged-or-panic"
  AesGcm.new(key16).open(nonce, "sixteen and more bytes").or_panic
end
puts "accepted"
IYI
if ! "$IYI" build -o "$WORK/refuse" "$WORK/refuse.iyi" >"$WORK/refuse.build.log" 2>&1; then
  echo "  the refusal program did not build"
  tail -12 "$WORK/refuse.build.log"
  status=1
fi
refuse() { # refuse <case> <phrase>
  if "$WORK/refuse" "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qF "$2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  else
    echo "  $1: $(tr -d '\r' <"$WORK/refuse.out" | grep -oF "$2" | head -1)"
  fi
}
refuse aes-key-15 "AES: a key is 16, 24 or 32 bytes, not 15"
refuse aes-block-17 "AES: a block is 16 bytes, not 17"
refuse aes-decrypt-block-0 "AES: a block is 16 bytes, not 0"
refuse gcm-key-20 "AesGcm: a key is 16, 24 or 32 bytes, not 20"
refuse gcm-seal-nonce-8 "AesGcm: a nonce is 12 bytes, not 8"
refuse gcm-open-nonce-16 "AesGcm: a nonce is 12 bytes, not 16"
refuse chacha-key-16 "ChaCha20: a key is 32 bytes, not 16"
refuse chacha-nonce-8 "ChaCha20: a nonce is 12 bytes, not 8"
refuse chacha-counter-wraps "ChaCha20: the key stream ends at block 2^32 - 1; RFC 8439's counter is 32 bits and is not wrapped"
refuse chacha-negative-count "ChaCha20: a negative count of bytes: -1"
refuse poly-key-16 "Poly1305: a key is 32 bytes, not 16"
refuse poly-final-twice "Poly1305: final called twice; a key authenticates one message"
refuse poly-update-after-final "Poly1305: update after final; a key authenticates one message"
refuse poly-negative-count "Poly1305: a negative count of bytes: -1"
refuse cp-key-31 "ChaCha20Poly1305: a key is 32 bytes, not 31"
refuse cp-nonce-24 "ChaCha20Poly1305: a nonce is 12 bytes, not 24"
refuse cp-open-nonce-0 "ChaCha20Poly1305: a nonce is 12 bytes, not 0"
# A forged message is a value; a program that chooses to panic on one
# panics with its sentence.
refuse forged-or-panic "AesGcm: the tag does not match: the sealed bytes, the additional data, the nonce or the key is not what was sealed"

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
src = Path("$REPO/src/std/aead.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/aead.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_aead_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
# One gate of the S-box circuit's last layer without its NOT: every byte
# substituted is wrong, from the first block on.
prove_broken "an S-box output bit not inverted" "fips 197 appendix b" \
  's6 = t56 ^ ~t62' 's6 = t56 ^ t62'
# Rcon past 0x80 must be reduced to 0x1b; unreduced, its ninth bit lands
# in the next byte of the word. AES-128 is the key size that gets that far.
prove_broken "Rcon doubled without reduction" "fips 197 appendix b" \
  '(rcon.unsafe_shr(7) &* 0x11b_u32)' '(rcon.unsafe_shr(7) &* 0x01b_u32)'
# Only a 32-byte key has a SubWord in the middle of each eight words, so
# only AES-256 sees it gone.
prove_broken "AES-256's middle SubWord left out" "fips 197 c.3 cipher" \
  '      elsif nk > 6 && j == 4
        tmp = sub_word(q, tmp)
' ''
prove_broken "a wrong coefficient in InvMixColumns" "fips 197 appendix b, inverse" \
  'q[7] = q4 ^ q5 ^ q6 ^ r4 ^ r6 ^ r7 ^ rotr32(q4 ^ q5 ^ q7 ^ r4 ^ r7)' \
  'q[7] = q4 ^ q5 ^ q6 ^ r4 ^ r6 ^ r7 ^ rotr32(q4 ^ q5 ^ q7 ^ r4)'
# Case 1 has no plaintext and no additional data, and its GHASH input is
# the zero lengths block, so it is case 2 where a counter off by one shows.
prove_broken "GCM's counter starting at the tag's own block" "gcm test case 2" \
  '    counter = 2_u32' '    counter = 1_u32'
prove_broken "GHASH's reduction missing its x^7 term" "gcm test case 2" \
  'v2 = v2 ^ v0 ^ v0.unsafe_shr(1) ^ v0.unsafe_shr(2) ^ v0.unsafe_shr(7)' \
  'v2 = v2 ^ v0 ^ v0.unsafe_shr(1) ^ v0.unsafe_shr(2)'
# Case 4 is the first with additional data.
prove_broken "the additional data's length in bytes, not bits" "gcm test case 4" \
  'AeadBytes.put_be64(lengths, aad_size.to_u64 &* 8_u64)' 'AeadBytes.put_be64(lengths, aad_size.to_u64)'
# Case 4's 60 bytes end 12 bytes into a block: the last 4 of them are in
# the block's low half.
prove_broken "GHASH dropping a short last block's low half" "gcm test case 4" \
  '        y0 = y0 ^ AeadBytes.be64_upto(at + 8_i64, left - 8) if left > 8
' ''
# A comparison that keeps only the last byte's difference passes a tag
# that is wrong anywhere else.
prove_broken "a tag compared by its last byte" "gcm: a tag with its first byte flipped is refused" \
  'diff = diff | (a[i] ^ b[i])' 'diff = a[i] ^ b[i]'
prove_broken "a tag compared short of its last byte" "gcm: a tag with its last byte flipped is refused" \
  '    while i < 16
      diff' '    while i < 15
      diff'
prove_broken "ChaCha20 at eighteen rounds" "rfc 8439 2.3.2 block" \
  'while double_round < 10' 'while double_round < 9'
prove_broken "a ChaCha20 piece starting a new block" "chacha20 in pieces" \
  '      next_block if @used == 64' '      next_block'
# The clamp clears byte 3's top four bits, and §2.5.2's r has three of
# them set.
prove_broken "Poly1305's r unclamped" "rfc 8439 2.5.2" \
  '& 0x3ffff03_u64' '& 0x3ffffff_u64'
prove_broken "a short last block given 2^128 rather than its 1 byte" "rfc 8439 2.5.2" \
  'PolyCore.blocks(@state, @buffer, 16, 0_u64)' 'PolyCore.blocks(@state, @buffer, 16, PolyCore::FULL)'
# Vector #5's accumulator ends at 2^130 - 2, past p and short of 2^130:
# only the final subtraction of p brings it down to 3.
prove_broken "Poly1305's last reduction mod p left out" "rfc 8439 a.3 #5" \
  'keep_g = g4.unsafe_shr(63) &- 1_u64' 'keep_g = 0_u64'
prove_broken "the AEAD's one-time key from block 1, not block 0" "rfc 8439 2.8.2" \
  '    state[12] = 0_u32
    ChaChaCore.block(state, one_time)' '    state[12] = 1_u32
    ChaChaCore.block(state, one_time)'
prove_broken "the AEAD's two lengths swapped" "rfc 8439 2.8.2" \
  'AeadBytes.put_le64(lengths, aad_size.to_u64)
    AeadBytes.put_le64(lengths + 8_i64, size.to_u64)' 'AeadBytes.put_le64(lengths, size.to_u64)
    AeadBytes.put_le64(lengths + 8_i64, aad_size.to_u64)'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/aead exercise holds"
else
  echo "the std/aead exercise did not hold"
fi
exit $status
