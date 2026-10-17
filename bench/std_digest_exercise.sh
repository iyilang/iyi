#!/usr/bin/env bash
# Exercises `std/digest`.
#
#     bash bench/std_digest_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_digest_exercise.iyi" \
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

echo "== the std/digest exercise, plain build"
build_and_run "plain" digest-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/digest-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every digest section reported"
for phrase in "== md5" "== sha" "== sha-2" "== every length" "== in pieces" "== state" "== sha-3" "== shake reads" "== checksum" "== crc-64" "== xxh64"; do
  if ! grep -q "$phrase" "$WORK/digest-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" digest-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/digest-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what a digest refuses"
# A digest that has given its final has nothing left to give: a second
# final, or more bytes, would answer a hash of nothing anyone asked for.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/digest::{SHA1, SHA256, SHA224, SHA3_256, SHAKE128, CRC32, CRC64, Adler32, XXH64}

d = SHA256.new
case Program.args[0]
when "final-twice"
  d.final
  d.final
when "update-after-final"
  d.final
  d.update("more")
when "other-algorithm"
  d.copy_from(SHA224.new)
when "short-buffer"
  d.final(Array(UInt8).new(31, 0_u8))
when "negative-count"
  d.update("abc".to_unsafe, -1)
when "crc-negative-count"
  CRC32.update(0_u32, "abc".to_unsafe, -1)
when "crc64-negative-count"
  CRC64.update(0_u64, "abc".to_unsafe, -1)
when "adler-negative-count"
  Adler32.update(1_u32, "abc".to_unsafe, -1)
when "sha3-other-algorithm"
  SHA3_256.new.copy_from(SHA256.new)
when "shake-update-after-read"
  x = SHAKE128.new
  x.read(1)
  x.update("more")
when "shake-negative-count"
  SHAKE128.new.update("abc".to_unsafe, -1)
when "shake-negative-read"
  SHAKE128.new.read(-1)
when "xxh64-negative-count"
  XXH64.new.update("abc".to_unsafe, -1)
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
refuse final-twice "final called twice; reset first"
refuse update-after-final "update after final; reset first"
refuse other-algorithm "cannot take the state of a"
refuse short-buffer "31 bytes cannot hold a 32-byte digest"
refuse negative-count "a negative count of bytes: -1"
refuse crc-negative-count "CRC32: a negative count of bytes: -1"
refuse crc64-negative-count "CRC64: a negative count of bytes: -1"
refuse adler-negative-count "Adler32: a negative count of bytes: -1"
refuse sha3-other-algorithm "SHA3_256: cannot take the state of a Std::Digest::SHA256"
# Absorbing after squeezing would be another function, not more input.
refuse shake-update-after-read "SHAKE128: update after read; reset first"
refuse shake-negative-count "SHAKE128: a negative count of bytes: -1"
refuse shake-negative-read "SHAKE128: a negative count of bytes to read: -1"
refuse xxh64-negative-count "XXH64: a negative count of bytes: -1"

echo
echo "== sha-3 and shake against python's hashlib"
# 3,000 random messages of 0 to 700 bytes, each given in random pieces,
# rotating through the four SHA-3s and the two SHAKEs; a SHAKE reads 0
# to 600 bytes in random pieces. Both sides draw from the same splitmix64,
# so the cases are not shipped across; python hashes each message whole
# and reads its output in one piece. The same program then times 4 MB
# through SHA3-256, SHAKE128 and SHA-256, in a release build.
cat >"$WORK/sha3_random.iyi" <<'IYI'
module sha3_random

import std/digest::{SHA256, SHA3_224, SHA3_256, SHA3_384, SHA3_512, SHAKE128, SHAKE256, Shake}

class Mix
  @s : UInt64

  def initialize(@s : UInt64)
  end

  def draw : UInt64
    @s = @s &+ 0x9e3779b97f4a7c15_u64
    z = @s
    z = (z ^ z.unsafe_shr(30)) &* 0xbf58476d1ce4e5b9_u64
    z = (z ^ z.unsafe_shr(27)) &* 0x94d049bb133111eb_u64
    z ^ z.unsafe_shr(31)
  end

  def below(n : Int32) : Int32
    (draw % n.to_u64).to_i32
  end
end

def piece(rng : Mix, left : Int32) : Int32
  rng.below((left < 300 ? left : 300) + 1)
end

def shake_hex(x : Shake, rng : Mix) : String
  total = rng.below(600)
  all = [] of UInt8
  while all.size < total
    all.concat(x.read(piece(rng, total - all.size)))
  end
  digits = "0123456789abcdef".to_unsafe
  String.new(total * 2) do |buf|
    i = 0
    while i < total
      buf[i * 2] = digits[all[i].to_i32 >> 4]
      buf[i * 2 + 1] = digits[all[i].to_i32 & 15]
      i = i + 1
    end
  end
end

rng = Mix.new(20261015_u64)
k = 0
while k < 3000
  kind = k % 6
  data = Array(UInt8).new(rng.below(700)) { (rng.draw & 255_u64).to_u8 }
  d = case kind
      when 0 then SHA3_224.new
      when 1 then SHA3_256.new
      when 2 then SHA3_384.new
      when 3 then SHA3_512.new
      else        nil
      end
  x = kind == 4 ? SHAKE128.new : SHAKE256.new
  at = 0
  while at < data.size
    n = piece(rng, data.size - at)
    if d
      d.update(data.to_unsafe + at.to_i64, n)
    else
      x.update(data.to_unsafe + at.to_i64, n)
    end
    at = at + n
  end
  puts d ? d.hexfinal : shake_hex(x, rng)
  k = k + 1
end

big = Array(UInt8).new(4 << 20) { |i| (i & 255).to_u8 }
squeezed = Array(UInt8).new(4 << 20, 0_u8)
t0 = IyiMark.now_ns
SHA3_256.hash_bytes(big)
t1 = IyiMark.now_ns
SHAKE128.new.read(squeezed)
t2 = IyiMark.now_ns
SHA256.hash_bytes(big)
t3 = IyiMark.now_ns
STDERR.puts "  iyi --release, 4 MB: SHA3-256 #{(t1 - t0) // 1000000} ms, SHAKE128 read #{(t2 - t1) // 1000000} ms, SHA-256 #{(t3 - t2) // 1000000} ms"
IYI
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so SHA-3 goes uncompared"
elif ! "$IYI" build --release -o "$WORK/sha3_random" "$WORK/sha3_random.iyi" >"$WORK/sha3_random.log" 2>&1; then
  echo "  the random SHA-3 program did not build"
  tail -12 "$WORK/sha3_random.log"
  status=1
elif ! "$WORK/sha3_random" >"$WORK/sha3_random.out" 2>"$WORK/sha3_random.err"; then
  echo "  the random SHA-3 program failed"
  tail -3 "$WORK/sha3_random.err"
  status=1
elif ! "$PY" - "$WORK/sha3_random.out" <<'PY'
import hashlib, sys, time
M = (1 << 64) - 1
class Mix:
    def __init__(self, s): self.s = s
    def next(self):
        self.s = (self.s + 0x9e3779b97f4a7c15) & M
        z = self.s
        z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & M
        z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & M
        return z ^ (z >> 31)
    def below(self, n): return self.next() % n
def piece(rng, left): return rng.below(min(left, 300) + 1)
rng = Mix(20261015)
got = open(sys.argv[1]).read().splitlines()
names = ["sha3_224", "sha3_256", "sha3_384", "sha3_512", "shake_128", "shake_256"]
bad = 0
for k in range(3000):
    kind = k % 6
    size = rng.below(700)
    data = bytes(rng.next() & 255 for _ in range(size))
    at = 0
    while at < size:
        at += piece(rng, size - at)
    h = hashlib.new(names[kind], data)
    if kind < 4:
        want = h.hexdigest()
    else:
        total = rng.below(600)
        done = 0
        while done < total:
            done += piece(rng, total - done)
        want = h.hexdigest(total)
    if k >= len(got) or got[k] != want:
        bad += 1
        if bad <= 3:
            print(f"  case {k} ({names[kind]}, {size} bytes): python {want[:32]}..., iyi {got[k][:32] if k < len(got) else 'nothing'}...")
print(f"  {3000 - bad} of 3000 random cases agree with hashlib, pieces and reads split at random")
big = bytes(i & 255 for i in range(4 << 20))
t0 = time.perf_counter(); hashlib.sha3_256(big).digest(); t1 = time.perf_counter()
hashlib.shake_128(b"").digest(4 << 20); t2 = time.perf_counter()
print(f"  python's hashlib (OpenSSL), 4 MB: SHA3-256 {int((t1 - t0) * 1000)} ms, SHAKE128 read {int((t2 - t1) * 1000)} ms")
sys.exit(1 if bad else 0)
PY
then
  status=1
else
  cat "$WORK/sha3_random.err"
fi

echo
echo "== crc-64 against liblzma"
# 3,000 random messages of 0 to 700 bytes, each given to CRC64.update in
# random pieces; python has no CRC-64 of its own, so the oracle is the
# one liblzma stores: the eight bytes before the index of
# `lzma.compress(message, check=CHECK_CRC64)`, which xz's decoder holds
# every block to. The same splitmix64 on both sides, as above.
cat >"$WORK/crc64_random.iyi" <<'IYI'
module crc64_random

import std/digest::{CRC64}

class Mix
  @s : UInt64

  def initialize(@s : UInt64)
  end

  def draw : UInt64
    @s = @s &+ 0x9e3779b97f4a7c15_u64
    z = @s
    z = (z ^ z.unsafe_shr(30)) &* 0xbf58476d1ce4e5b9_u64
    z = (z ^ z.unsafe_shr(27)) &* 0x94d049bb133111eb_u64
    z ^ z.unsafe_shr(31)
  end

  def below(n : Int32) : Int32
    (draw % n.to_u64).to_i32
  end
end

rng = Mix.new(20261017_u64)
digits = "0123456789abcdef".to_unsafe
3000.times do
  size = rng.below(700)
  data = String.new(size) do |buf|
    i = 0
    while i < size
      buf[i] = (rng.draw & 255_u64).to_u8
      i = i + 1
    end
  end
  crc = 0_u64
  at = 0
  while at < size
    n = rng.below((size - at < 300 ? size - at : 300) + 1)
    crc = CRC64.update(crc, data.to_unsafe + at.to_i64, n)
    at = at + n
  end
  puts String.new(16) { |buf| 16.times { |k| buf[k] = digits[(crc.unsafe_shr(60 - 4 * k) & 15_u64).to_i32] } }
end
IYI
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so CRC-64 goes uncompared"
elif ! "$IYI" build -o "$WORK/crc64_random" "$WORK/crc64_random.iyi" >"$WORK/crc64_random.log" 2>&1; then
  echo "  the random CRC-64 program did not build"
  tail -12 "$WORK/crc64_random.log"
  status=1
elif ! "$WORK/crc64_random" >"$WORK/crc64_random.out" 2>&1; then
  echo "  the random CRC-64 program failed"
  tail -3 "$WORK/crc64_random.out"
  status=1
elif ! "$PY" - "$WORK/crc64_random.out" <<'PY'
import lzma, struct, sys
M = (1 << 64) - 1
class Mix:
    def __init__(self, s): self.s = s
    def next(self):
        self.s = (self.s + 0x9e3779b97f4a7c15) & M
        z = self.s
        z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & M
        z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & M
        return z ^ (z >> 31)
    def below(self, n): return self.next() % n
rng = Mix(20261017)
got = open(sys.argv[1]).read().splitlines()
bad = 0
for k in range(3000):
    size = rng.below(700)
    data = bytes(rng.next() & 255 for _ in range(size))
    at = 0
    while at < size:
        at += rng.below(min(size - at, 300) + 1)
    if size == 0:
        want = "0" * 16
    else:
        x = lzma.compress(data, check=lzma.CHECK_CRC64, preset=0)
        index = len(x) - 12 - (struct.unpack("<I", x[-8:-4])[0] + 1) * 4
        want = "%016x" % struct.unpack("<Q", x[index - 8:index])[0]
    if k >= len(got) or got[k] != want:
        bad += 1
        if bad <= 3:
            print(f"  case {k} ({size} bytes): liblzma {want}, iyi {got[k] if k < len(got) else 'nothing'}")
print(f"  {3000 - bad} of 3000 random cases agree with liblzma's CRC64, pieces split at random")
sys.exit(1 if bad else 0)
PY
then
  status=1
fi

echo
echo "== xxh64 against python's zstd"
# 3,000 random messages of 0 to 700 bytes, each given to XXH64#update in
# random pieces. Python has no xxhash, so the oracle is a reference
# written below from xxhash's spec, itself held to what Python's zstd
# stores as a frame's content checksum - the low 32 bits - for every
# message; and the 64 bits iyi answers held to the reference. The same
# splitmix64 on both sides, as above.
cat >"$WORK/xxh64_random.iyi" <<'IYI'
module xxh64_random

import std/digest::{XXH64}

class Mix
  @s : UInt64

  def initialize(@s : UInt64)
  end

  def draw : UInt64
    @s = @s &+ 0x9e3779b97f4a7c15_u64
    z = @s
    z = (z ^ z.unsafe_shr(30)) &* 0xbf58476d1ce4e5b9_u64
    z = (z ^ z.unsafe_shr(27)) &* 0x94d049bb133111eb_u64
    z ^ z.unsafe_shr(31)
  end

  def below(n : Int32) : Int32
    (draw % n.to_u64).to_i32
  end
end

rng = Mix.new(20261017_u64)
digits = "0123456789abcdef".to_unsafe
3000.times do
  size = rng.below(700)
  data = String.new(size) do |buf|
    i = 0
    while i < size
      buf[i] = (rng.draw & 255_u64).to_u8
      i = i + 1
    end
  end
  h = XXH64.new
  at = 0
  while at < size
    n = rng.below((size - at < 300 ? size - at : 300) + 1)
    h.update(data.to_unsafe + at.to_i64, n)
    at = at + n
  end
  sum = h.digest
  puts String.new(16) { |buf| 16.times { |k| buf[k] = digits[(sum.unsafe_shr(60 - 4 * k) & 15_u64).to_i32] } }
end
IYI
if [ -z "$PY" ] || ! "$PY" -c 'import compression.zstd' >/dev/null 2>&1; then
  echo "  no python with compression.zstd (3.14) on this machine, so XXH64 goes uncompared"
elif ! "$IYI" build -o "$WORK/xxh64_random" "$WORK/xxh64_random.iyi" >"$WORK/xxh64_random.log" 2>&1; then
  echo "  the random XXH64 program did not build"
  tail -12 "$WORK/xxh64_random.log"
  status=1
elif ! "$WORK/xxh64_random" >"$WORK/xxh64_random.out" 2>&1; then
  echo "  the random XXH64 program failed"
  tail -3 "$WORK/xxh64_random.out"
  status=1
elif ! "$PY" - "$WORK/xxh64_random.out" <<'PY'
import sys
from compression import zstd
M = (1 << 64) - 1
P1, P2, P3, P4, P5 = 0x9E3779B185EBCA87, 0xC2B2AE3D27D4EB4F, 0x165667B19E3779F9, 0x85EBCA77C2B2AE63, 0x27D4EB2F165667C5
def rotl(x, r): return ((x << r) | (x >> (64 - r))) & M
def rnd(acc, v): return (rotl((acc + v * P2) & M, 31) * P1) & M
def xxh64(d, seed=0):
    n, i = len(d), 0
    word = lambda k: int.from_bytes(d[k:k + 8], "little")
    if n >= 32:
        v = [(seed + P1 + P2) & M, (seed + P2) & M, seed, (seed - P1) & M]
        while i + 32 <= n:
            v = [rnd(v[j], word(i + 8 * j)) for j in range(4)]
            i += 32
        h = (rotl(v[0], 1) + rotl(v[1], 7) + rotl(v[2], 12) + rotl(v[3], 18)) & M
        for x in v:
            h = ((h ^ rnd(0, x)) * P1 + P4) & M
    else:
        h = (seed + P5) & M
    h = (h + n) & M
    while i + 8 <= n:
        h = (rotl(h ^ rnd(0, word(i)), 27) * P1 + P4) & M
        i += 8
    if i + 4 <= n:
        h = (rotl(h ^ (int.from_bytes(d[i:i + 4], "little") * P1 & M), 23) * P2 + P3) & M
        i += 4
    while i < n:
        h = (rotl(h ^ (d[i] * P5 & M), 11) * P1) & M
        i += 1
    h ^= h >> 33
    h = (h * P2) & M
    h ^= h >> 29
    h = (h * P3) & M
    return h ^ (h >> 32)
class Mix:
    def __init__(self, s): self.s = s
    def next(self):
        self.s = (self.s + 0x9e3779b97f4a7c15) & M
        z = self.s
        z = ((z ^ (z >> 30)) * 0xbf58476d1ce4e5b9) & M
        z = ((z ^ (z >> 27)) * 0x94d049bb133111eb) & M
        return z ^ (z >> 31)
    def below(self, n): return self.next() % n
rng = Mix(20261017)
got = open(sys.argv[1]).read().splitlines()
bad = 0
for k in range(3000):
    size = rng.below(700)
    data = bytes(rng.next() & 255 for _ in range(size))
    at = 0
    while at < size:
        at += rng.below(min(size - at, 300) + 1)
    want = xxh64(data)
    frame = zstd.compress(data, options={zstd.CompressionParameter.checksum_flag: 1})
    if int.from_bytes(frame[-4:], "little") != want & 0xFFFFFFFF:
        raise SystemExit(f"  case {k}: the reference disagrees with zstd's checksum, so it proves nothing")
    if k >= len(got) or got[k] != "%016x" % want:
        bad += 1
        if bad <= 3:
            print(f"  case {k} ({size} bytes): reference {want:016x}, iyi {got[k] if k < len(got) else 'nothing'}")
print(f"  {3000 - bad} of 3000 random cases agree with the reference, which zstd's checksums agree with, pieces split at random")
sys.exit(1 if bad else 0)
PY
then
  status=1
fi

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
src = Path("$REPO/src/std/digest.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/digest.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_digest_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "MD5 from the wrong state" "ASSERTION FAILED: empty" \
  '@h[0] = 0x67452301_u32' '@h[0] = 0_u32'
# A 128-byte block keeps sixteen bytes for the length, so 112 to 119
# bytes left over need a block of their own; an eight-byte field fits
# them in the last one.
prove_broken "a 128-byte block's length field taken as eight bytes" "896 bits" \
  'field = @block_size == 128 ? 16 : 8' 'field = 8'
prove_broken "a short piece filling the block it cannot fill" "in pieces" \
  '      take = count if count < take
' ''
# `dup` is a `copy_from` into a new digest, so its check is the first to see it.
prove_broken "copy_from without the block in progress" "a dup goes on from where it was copied" \
  '    @fill = other.@fill
' ''
# A checksum of one piece starts from 0 (CRC-32) and 1 (Adler-32), so an
# `update` that drops what it was given still answers every one-piece
# check; only the checks in pieces see it.
prove_broken "a CRC-32 update that forgets the checksum it goes on from" "crc in pieces" \
  '    crc = crc ^ 0xffffffff_u32' '    crc = 0xffffffff_u32'
prove_broken "a CRC-64 update that forgets the checksum it goes on from" "crc64 in pieces" \
  '    crc = crc ^ 0xffffffffffffffff_u64' '    crc = 0xffffffffffffffff_u64'
prove_broken "a CRC-64 over ECMA-182's polynomial unreflected" "crc64 check value" \
  'c.unsafe_shr(1) ^ 0xc96c5795d7870f42_u64' 'c.unsafe_shr(1) ^ 0x42f0e1eba9ea3693_u64'
# The eight-byte step, which the bytewise table alone does not see: the
# check value's first eight bytes go through it.
prove_broken "a CRC-64 step with two of its tables swapped" "crc64 check value" \
  't[768 + (x.unsafe_shr(32) & 255_u64).to_i32] ^ t[512 + (x.unsafe_shr(40) & 255_u64).to_i32]' 't[512 + (x.unsafe_shr(32) & 255_u64).to_i32] ^ t[768 + (x.unsafe_shr(40) & 255_u64).to_i32]'
prove_broken "an Adler-32 update that forgets the sum of sums" "adler in pieces" \
  '    b = sum.unsafe_shr(16) % 65521_u32' '    b = 0_u32'
# SHA-3's four: each breaks every Keccak output, so the first SHA-3
# check sees it, except a wrong rate, which only its own hash uses.
prove_broken "a wrong Keccak round constant" "ASSERTION FAILED: sha3-224 empty" \
  '0x0000000000008082_u64' '0x0000000000008083_u64'
prove_broken "a rho rotation off by one" "ASSERTION FAILED: sha3-224 empty" \
  '1_u64, 3_u64, 6_u64, 10_u64' '1_u64, 3_u64, 7_u64, 10_u64'
prove_broken "SHA-3 padded with Keccak's 0x01 for 0x06" "ASSERTION FAILED: sha3-224 empty" \
  '0x06_u8' '0x01_u8'
prove_broken "SHA3-256 at SHA3-224's rate" "ASSERTION FAILED: sha3-256 empty" \
  'super(200 - 2 * 32)' 'super(200 - 2 * 28)'
prove_broken "a SHAKE read that forgets to permute between blocks" "shake128 of 200 bytes" \
  '        Keccak.permute(@a, @c)
' ''
# XXH64's: a lane started from the wrong prime breaks every hash of a
# stripe or more; an update that drops the stripe in progress only what
# arrives in pieces; a tail byte mixed with the wrong prime the shortest.
prove_broken "an XXH64 lane started from the wrong prime" "xxh64 of one stripe" \
  '    @v2 = @seed &+ P2' '    @v2 = @seed &+ P1'
prove_broken "an XXH64 update that drops the stripe in progress" "xxh64 in pieces" \
  '      (@stripe + @fill.to_i64).copy_from(data, take)
' ''
prove_broken "an XXH64 tail byte mixed with the wrong prime" "xxh64 of 'a'" \
  '      h = XXH64.rotl(h, 11) &* P1' '      h = XXH64.rotl(h, 11) &* P2'

# The checksums' costs, against the shapes they had: CRC-32 a bit at a
# time, Adler-32 reduced every byte.
cost_proof() { # cost_proof <label> <phrase> <old> <new>
  rm -rf "$WORK/costly"
  mkdir -p "$WORK/costly/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/digest.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/costly/std/digest.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/costly${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_digest_exercise.iyi" >"$WORK/costly.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -q "$2" "$WORK/costly.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not at the cost check:"
    tail -2 "$WORK/costly.out" | sed 's/^/    /'
    status=1
  fi
}
cost_proof "a CRC-32 a bit at a time" "crc cost" \
  '    while i + 8 <= n
      one' \
  '    while i < n
      crc = crc ^ p[i].to_u32
      b = 0
      while b < 8
        crc = (crc & 1_u32) == 1_u32 ? crc.unsafe_shr(1) ^ 0xedb88320_u32 : crc.unsafe_shr(1)
        b = b + 1
      end
      i = i + 1
    end
    while i + 8 <= n
      one'
# A divide is a few cycles on arm64 and on the Windows runners' processors:
# there Adler-32 reduced every byte stays inside the bound, and the time
# cannot tell the two shapes apart. The check runs everywhere; its proof on
# Linux x86_64, where reducing every byte costs seven byte sums.
case "$(uname -s) $(uname -m)" in
  "Linux x86_64") ;;
  *) no_adler_proof=1 ;;
esac
case "${no_adler_proof:-}" in
  1)
    echo "  an Adler-32 reduced every byte: not proven here, because this processor's divide is too cheap for its time to show"
    ;;
  *)
    cost_proof "an Adler-32 reduced every byte" "adler cost" \
      '        a = a + p[i].to_u32
        b = b + a' \
      '        a = (a + p[i].to_u32) % 65521_u32
        b = (b + a) % 65521_u32'
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "the std/digest exercise holds"
else
  echo "the std/digest exercise did not hold"
fi
exit $status
