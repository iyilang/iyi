#!/usr/bin/env bash
# Exercises `std/password`.
#
#     bash bench/std_password_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_password_exercise.iyi" \
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

echo "== the std/password exercise, plain build"
build_and_run "plain" password-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/password-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every password section reported"
for phrase in "== scrypt" "== bcrypt" "== bcrypt vectors"; do
  if ! grep -q "$phrase" "$WORK/password-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" password-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/password-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# The oracles below write an iyi program of their cases, run it, and read
# what it printed against Python's answers.
B_HELPER='def b(hex : String) : Array(UInt8)
  p = hex.to_unsafe
  Array(UInt8).new(hex.bytesize // 2) do |i|
    hi = p[i * 2].to_i32
    lo = p[i * 2 + 1].to_i32
    hi = hi >= 97 ? hi - 87 : hi - 48
    lo = lo >= 97 ? lo - 87 : lo - 48
    (hi * 16 + lo).to_u8
  end
end

def hex(bytes : Array(UInt8)) : String
  digits = "0123456789abcdef"
  text = ""
  bytes.each do |x|
    text = text + digits[x.to_i32 >> 4].to_s + digits[x.to_i32 & 15].to_s
  end
  text
end
'

echo
echo "== scrypt against python's hashlib"
# Thirty random cases: passwords and salts of 0 to 40 random bytes, n from
# 2 to 2048, r 1 to 8, p 1 to 4, keys of 1 to 100 bytes.
if [ -z "$PY" ] || ! "$PY" -c 'import hashlib; hashlib.scrypt(b"", salt=b"", n=2, r=1, p=1)' >/dev/null 2>&1; then
  echo "  no python3 with hashlib.scrypt on this machine, so scrypt goes uncompared"
else
  B_HELPER="$B_HELPER" "$PY" - "$WORK" <<'PY'
import hashlib, os, random, sys
work = sys.argv[1]
rng = random.Random(20261014)
lines = ["module scrypt_cases", "", "import std/password::{Scrypt}", "", os.environ["B_HELPER"]]
expected = []
for _ in range(30):
    pw = bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 40)))
    salt = bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 40)))
    n = 2 ** rng.randint(1, 11)
    r = rng.randint(1, 8)
    p = rng.randint(1, 4)
    length = rng.randint(1, 100)
    lines.append(f'puts hex(Scrypt.derive(b("{pw.hex()}"), b("{salt.hex()}"), {n}, {r}, {p}, {length}))')
    expected.append(f"{hashlib.scrypt(pw, salt=salt, n=n, r=r, p=p, dklen=length).hex()} n={n} r={r} p={p} length={length}")
open(os.path.join(work, "scrypt_cases.iyi"), "w").write("\n".join(lines) + "\n")
open(os.path.join(work, "scrypt_expected.txt"), "w").write("\n".join(expected) + "\n")
PY
  if ! "$IYI" run "$WORK/scrypt_cases.iyi" >"$WORK/scrypt_got.txt" 2>&1; then
    echo "  the scrypt cases did not run: $(tail -1 "$WORK/scrypt_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
got = open(os.path.join(work, "scrypt_got.txt")).read().split()
want = [line.split(" ", 1) for line in open(os.path.join(work, "scrypt_expected.txt")).read().splitlines()]
bad = [(w, g) for w, g in zip(want, got + [""] * len(want)) if w[0] != g]
for w, g in bad:
    print(f"  {w[1]}: python {w[0][:32]}..., iyi {g[:32]}...")
print(f"  {len(want) - len(bad)} of {len(want)} random cases agree with hashlib.scrypt")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== bcrypt against python's bcrypt"
# Python's bcrypt package hashes sixteen random passwords (1 to 255 each
# byte, no NUL, 0 to 100 bytes, so past 72 too) at costs 4 and 5 under
# `$2a$`, `$2b$` and `$2y$`, and iyi must verify each and refuse it a
# changed password; iyi hashes ten more, which Python must verify.
if [ -z "$PY" ] || ! "$PY" -c 'import bcrypt' >/dev/null 2>&1; then
  echo "  python's bcrypt package is not installed here, so bcrypt goes uncompared with it"
else
  B_HELPER="$B_HELPER" "$PY" - "$WORK" <<'PY'
import bcrypt, os, random, sys
work = sys.argv[1]
rng = random.Random(20261015)
def password():
    return bytes(rng.randint(1, 255) for _ in range(rng.randint(0, 100)))
lines = ["module bcrypt_cases", "", "import std/password::{Bcrypt}", "", os.environ["B_HELPER"]]
for i in range(16):
    pw = password()
    prefix = [b"2a", b"2b", b"2b"][i % 3]
    # Python's bcrypt refuses a password past 72 bytes rather than cut
    # it; it is given the 72 that count, and iyi the whole password.
    stored = bcrypt.hashpw(pw[:72], bcrypt.gensalt(4 + i % 2, prefix=prefix)).decode()
    if i % 3 == 2:
        stored = "$2y$" + stored[4:]
    # A changed password: one byte more when that byte still counts,
    # else its first byte turned.
    other = pw + b"x" if len(pw) < 72 else bytes([pw[0] ^ 1]) + pw[1:]
    lines.append(f'puts "verify {i} {stored[:7]} #{{Bcrypt.verify(b("{pw.hex()}"), "{stored}")}} #{{Bcrypt.verify(b("{other.hex()}"), "{stored}")}}"')
made = [password() for _ in range(10)]
for i, pw in enumerate(made):
    lines.append(f'puts "made {i} #{{Bcrypt.hash(b("{pw.hex()}"), 4)}}"')
open(os.path.join(work, "bcrypt_cases.iyi"), "w").write("\n".join(lines) + "\n")
open(os.path.join(work, "bcrypt_made.txt"), "w").write("\n".join(pw.hex() for pw in made) + "\n")
PY
  if ! "$IYI" run "$WORK/bcrypt_cases.iyi" >"$WORK/bcrypt_got.txt" 2>&1; then
    echo "  the bcrypt cases did not run: $(tail -1 "$WORK/bcrypt_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import bcrypt, os, sys
work = sys.argv[1]
got = open(os.path.join(work, "bcrypt_got.txt")).read().splitlines()
made = [bytes.fromhex(line) for line in open(os.path.join(work, "bcrypt_made.txt")).read().splitlines()]
bad = 0
verified = [line.split() for line in got if line.startswith("verify ")]
for _, i, prefix, right, wrong in verified:
    if right != "true" or wrong != "false":
        print(f"  python's hash {i} ({prefix}): iyi answered {right} for its password and {wrong} for another"); bad += 1
hashed = [line.split() for line in got if line.startswith("made ")]
for _, i, stored in hashed:
    if not bcrypt.checkpw(made[int(i)][:72], stored.encode()):
        print(f"  iyi's hash {i} does not verify in python: {stored}"); bad += 1
if len(verified) != 16 or len(hashed) != 10:
    print(f"  {len(verified)} verifications and {len(hashed)} hashes came back, not 16 and 10"); bad += 1
print(f"  iyi verified {len(verified)} of python's hashes ($2a$, $2b$, $2y$) and python verified {len(hashed)} of iyi's")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
fi
if command -v htpasswd >/dev/null 2>&1; then
  stored="$(htpasswd -nbBC 5 user 'apache wrote this' | cut -d: -f2- | tr -d '\r\n')"
  printf 'module htpasswd_case\n\nimport std/password::{Bcrypt}\n\nputs Bcrypt.verify("apache wrote this", "%s")\nputs Bcrypt.verify("apache wrote that", "%s")\n' "$stored" "$stored" >"$WORK/htpasswd.iyi"
  if [ "$("$IYI" run "$WORK/htpasswd.iyi" 2>&1 | tr '\n' ' ')" = "true false " ]; then
    echo "  htpasswd -B's ${stored:0:7} hash verifies, and not for another password"
  else
    echo "  htpasswd -B's hash $stored did not verify as it should"
    status=1
  fi
else
  echo "  no htpasswd on this machine, so Apache's bcrypt goes unread"
fi

echo
echo "== what bcrypt at cost 10 takes"
# Recorded, not held to a figure: the time is the machine's as much as the
# code's. The best of three, --release, against Python's bcrypt when it is
# here.
cat >"$WORK/cost.iyi" <<'IYI'
module cost

import std/password::{Bcrypt}

best = 0_i64
3.times do |k|
  t0 = IyiMark.now_ns
  stored = Bcrypt.hash("correct horse battery staple", 10)
  t1 = IyiMark.now_ns
  raise "cost 10 did not verify" unless Bcrypt.verify("correct horse battery staple", stored)
  best = (t1 - t0).to_i64 if k == 0 || (t1 - t0).to_i64 < best
end
puts "iyi #{best // 1_000_000} ms"
IYI
if "$IYI" build --release -o "$WORK/cost" "$WORK/cost.iyi" >"$WORK/cost.build.log" 2>&1 && "$WORK/cost" >"$WORK/cost.out" 2>&1; then
  python_ms=""
  if [ -n "$PY" ] && "$PY" -c 'import bcrypt' >/dev/null 2>&1; then
    python_ms="$("$PY" -c '
import bcrypt, time
best = None
for _ in range(3):
    t = time.perf_counter()
    bcrypt.hashpw(b"correct horse battery staple", bcrypt.gensalt(10))
    d = time.perf_counter() - t
    best = d if best is None or d < best else best
print(f", python bcrypt {int(best * 1000)} ms")')"
  fi
  echo "  $(cat "$WORK/cost.out")$python_ms"
else
  echo "  the cost-10 timing did not build or run: $(tail -1 "$WORK/cost.build.log" "$WORK/cost.out" 2>/dev/null | tail -1)"
  status=1
fi

echo
echo "== what password refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/password::{Scrypt, Bcrypt}

case Program.args[0]
when "bcrypt-cost-3"
  Bcrypt.hash("password", 3)
when "bcrypt-cost-32"
  Bcrypt.hash("password", 32)
when "scrypt-n-1000"
  Scrypt.derive("password", "salt", 1000, 8, 1, 32)
when "scrypt-n-1"
  Scrypt.derive("password", "salt", 1, 8, 1, 32)
when "scrypt-r-0"
  Scrypt.derive("password", "salt", 16, 0, 1, 32)
when "scrypt-p-0"
  Scrypt.derive("password", "salt", 16, 1, 0, 32)
when "scrypt-no-length"
  Scrypt.derive("password", "salt", 16, 1, 1, 0)
when "scrypt-n-past-r"
  Scrypt.derive("password", "salt", 65536, 1, 1, 32)
when "scrypt-too-wide"
  Scrypt.derive("password", "salt", 2, 1024, 16384, 32, 9_000_000_000_000_i64)
when "scrypt-rfc-case-4"
  Scrypt.derive("pleaseletmein", "SodiumChloride", 1048576, 8, 1, 64)
when "scrypt-one-byte-short"
  Scrypt.derive("pleaseletmein", "SodiumChloride", 16384, 8, 1, 64, 16_780_287_i64)
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
refuse bcrypt-cost-3 "Bcrypt: the cost must be from 4 to 31, not 3"
refuse bcrypt-cost-32 "Bcrypt: the cost must be from 4 to 31, not 32"
refuse scrypt-n-1000 "Scrypt: n must be a power of two above 1, not 1000"
refuse scrypt-n-1 "Scrypt: n must be a power of two above 1, not 1"
refuse scrypt-r-0 "Scrypt: r must be at least 1, not 0"
refuse scrypt-p-0 "Scrypt: p must be at least 1, not 0"
refuse scrypt-no-length "Scrypt: the key length must be at least 1 byte, not 0"
refuse scrypt-n-past-r "Scrypt: n = 65536 must be below 2^(16 * r) = 2^16"
refuse scrypt-too-wide "Scrypt: p * r = 16777216 is past the 2^24 one derivation can hold"
refuse scrypt-rfc-case-4 "Scrypt: n = 1048576, r = 8, p = 1 need 1073744896 bytes, past the limit of 33554432"
refuse scrypt-one-byte-short "Scrypt: n = 16384, r = 8, p = 1 need 16780288 bytes, past the limit of 16780287"

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
src = Path("$REPO/src/std/password.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/password.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_password_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
# One word of Blowfish's first S-box off by a bit: bcrypt still agrees
# with itself, so it is the published vectors that see it.
prove_broken "a wrong Blowfish S-box word" "bcrypt vector \"\" at cost 06" \
  '0xd1310ba6_u32' '0xd1310ba7_u32'
prove_broken "a bcrypt that never uses its salt" "a hash given another salt does not verify" \
  '    st = Pointer(UInt32).malloc(1042_u64)' '    4.times { |z| salted[z] = 0_u32 }
    st = Pointer(UInt32).malloc(1042_u64)'
prove_broken "a bcrypt that ignores its cost" "a hash relabelled with another cost does not verify" \
  'rounds = 1_i64.unsafe_shl(cost)' 'rounds = 16_i64'
prove_broken "Salsa20 at six rounds rather than eight" "rfc 7914 case 1" \
  'while double_round < 4' 'while double_round < 3'
# With r = 1 the two halves are one block each and either order is the
# same, so case 1 passes and case 2, r = 8, is where it shows.
prove_broken "BlockMix writing its blocks in order, not even then odd" "rfc 7914 case 2" \
  '      to = (i & 1) == 0 ? half : r + half' '      to = i'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/password exercise holds"
else
  echo "the std/password exercise did not hold"
fi
exit $status
