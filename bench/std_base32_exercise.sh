#!/usr/bin/env bash
# Exercises `std/base32`.
#
#     bash bench/std_base32_exercise.sh
#
# The exercise holds RFC 4648's section 10 vectors, round trips and the
# refusals by their sentence; this gate runs it plain and --release, holds
# both alphabets to Python's `base64.b32encode`, `b32hexencode` and their
# decoders on random data, holds what decode accepts to what Python
# accepts on texts broken at random (Python ignoring the bits past the
# data, which this refuses, and nothing else), shows an error value's
# sentence through `.or_panic`, and proves on broken copies of the module
# that the checks fail where they say.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_base32_exercise.iyi" \
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

echo "== the std/base32 exercise, plain build"
build_and_run "plain" base32-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/base32-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every base32 section reported"
for phrase in "== RFC 4648 section 10" "== round trips" "== what decode reads leniently" "== what decode refuses, as a value"; do
  if ! grep -q "$phrase" "$WORK/base32-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" base32-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/base32-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# The oracles below write an iyi program of their cases, run it, and read
# what it printed against Python's answers.
HELPERS='def b(hex : String) : Array(UInt8)
  p = hex.to_unsafe
  Array(UInt8).new(hex.bytesize // 2) do |i|
    hi = p[i * 2].to_i32
    lo = p[i * 2 + 1].to_i32
    hi = hi >= 97 ? hi - 87 : hi - 48
    lo = lo >= 97 ? lo - 87 : lo - 48
    (hi * 16 + lo).to_u8
  end
end

def hex(answer : Array(UInt8) | Base32Error) : String
  return "refused" if answer.is_a?(Base32Error)
  digits = "0123456789abcdef"
  text = "ok "
  answer.each do |x|
    text = text + digits[x.to_i32 >> 4].to_s + digits[x.to_i32 & 15].to_s
  end
  text
end
'

echo
echo "== python's base64 agrees: b32encode, b32hexencode, b32decode, b32hexdecode"
# 300 random byte strings of 0 to 80 bytes: both alphabets encoded padded
# and not, and Python's text decoded back as it is, in lower case and with
# its padding taken off.
if [ -z "$PY" ] || ! "$PY" -c 'import base64; base64.b32hexencode(b"")' >/dev/null 2>&1; then
  echo "  no python3 with base64.b32hexencode (3.10) on this machine, so base32 goes uncompared"
else
  HELPERS="$HELPERS" "$PY" - "$WORK" <<'PY'
import base64, os, random, sys
work = sys.argv[1]
rng = random.Random(20261015)
lines = ["module encode_cases", "", "import std/base32::{Base32, Base32Hex, Base32Error}", "", os.environ["HELPERS"]]
expected = []
for _ in range(300):
    data = bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 80)))
    b32 = base64.b32encode(data).decode()
    b32hex = base64.b32hexencode(data).decode()
    h = data.hex()
    lines.append(f'puts Base32.encode(b("{h}"))')
    lines.append(f'puts Base32.encode(b("{h}"), padding: false)')
    lines.append(f'puts Base32Hex.encode(b("{h}"))')
    lines.append(f'puts Base32Hex.encode(b("{h}"), padding: false)')
    lines.append(f'puts hex(Base32.decode("{b32}"))')
    lines.append(f'puts hex(Base32.decode("{b32.lower().rstrip("=")}"))')
    lines.append(f'puts hex(Base32Hex.decode("{b32hex.lower()}"))')
    lines.append(f'puts hex(Base32Hex.decode("{b32hex.rstrip("=")}"))')
    expected += [b32, b32.rstrip("="), b32hex, b32hex.rstrip("="), "ok " + h, "ok " + h, "ok " + h, "ok " + h]
open(os.path.join(work, "encode_cases.iyi"), "w").write("\n".join(lines) + "\n")
open(os.path.join(work, "encode_expected.txt"), "w").write("\n".join(expected) + "\n")
PY
  if ! "$IYI" run "$WORK/encode_cases.iyi" >"$WORK/encode_got.txt" 2>&1; then
    echo "  the cases did not run: $(tail -1 "$WORK/encode_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
got = open(os.path.join(work, "encode_got.txt")).read().splitlines()
want = open(os.path.join(work, "encode_expected.txt")).read().splitlines()
bad = [(i, w, g) for i, (w, g) in enumerate(zip(want, got + [""] * len(want))) if w != g]
for i, w, g in bad[:8]:
    print(f"  case {i // 8}, answer {i % 8}: python {w[:40]!r}, iyi {g[:40]!r}")
print(f"  {len(want) - len(bad)} of {len(want)} answers on 300 random byte strings agree with python")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== what decode takes is what python takes, less the bits past the data"
# 1,500 texts broken at random from valid encodings, both alphabets: a
# character changed (to another in the alphabet, a lower-case one, `=`, or
# a byte outside it), dropped, doubled, the padding cut or lengthened.
# Python's verdict is `b32decode(text, casefold=True)` (the hex decoder for
# base32hex), the text padded out to eight first when it has no `=`, since
# Python requires padding and this does not; then a text Python takes must
# also be the canonical encoding of what it decodes to, which Python does
# not ask and RFC 4648 section 3.5 lets a decoder ask.
if [ -z "$PY" ] || ! "$PY" -c 'import base64; base64.b32hexdecode(b"")' >/dev/null 2>&1; then
  echo "  no python3 with base64.b32hexdecode (3.10) on this machine, so the refusals go uncompared"
else
  HELPERS="$HELPERS" "$PY" - "$WORK" <<'PY'
import base64, binascii, os, random, sys
work = sys.argv[1]
rng = random.Random(4648)
lines = ["module broken_cases", "", "import std/base32::{Base32, Base32Hex, Base32Error}", "", os.environ["HELPERS"]]
expected = []
junk = "*0189@ -_.,:;!?$%&()[]{}<>\n\t"
kinds = {"refused": 0, "ok": 0, "non-canonical": 0}
for i in range(1500):
    hexa = i % 2 == 1
    alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUV" if hexa else "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    data = bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 24)))
    text = (base64.b32hexencode if hexa else base64.b32encode)(data).decode()
    if rng.random() < 0.3:
        text = text.rstrip("=")
    chars = list(text)
    for _ in range(rng.randint(1, 2)):
        r = rng.random()
        at = rng.randint(0, len(chars))
        if r < 0.35 and chars:
            at = min(at, len(chars) - 1)
            chars[at] = rng.choice(alphabet)
        elif r < 0.45 and chars:
            at = min(at, len(chars) - 1)
            chars[at] = chars[at].lower()
        elif r < 0.55:
            chars.insert(at, "=")
        elif r < 0.65 and chars:
            del chars[min(at, len(chars) - 1)]
        elif r < 0.75:
            chars.insert(at, rng.choice(junk))
        elif r < 0.85 and chars:
            chars.insert(at, chars[min(at, len(chars) - 1)])
        else:
            chars.append("=")
    broken = "".join(chars)
    decode = base64.b32hexdecode if hexa else base64.b32decode
    encode = base64.b32hexencode if hexa else base64.b32encode
    padded = broken if "=" in broken else broken + "=" * (-len(broken) % 8)
    try:
        out = decode(padded, casefold=True)
        if encode(out).decode().rstrip("=") != broken.upper().rstrip("="):
            verdict = "refused"
            kinds["non-canonical"] += 1
        else:
            verdict = "ok " + out.hex()
            kinds["ok"] += 1
    except (binascii.Error, ValueError):
        verdict = "refused"
        kinds["refused"] += 1
    literal = broken.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("#", "\\#")
    lines.append(f'puts hex({"Base32Hex" if hexa else "Base32"}.decode("{literal}"))')
    expected.append(verdict + "\t" + repr(broken))
open(os.path.join(work, "broken_cases.iyi"), "w").write("\n".join(lines) + "\n")
open(os.path.join(work, "broken_expected.txt"), "w").write("\n".join(expected) + "\n")
open(os.path.join(work, "broken_kinds.txt"), "w").write(f"{kinds['ok']} decode, {kinds['refused']} python refuses, {kinds['non-canonical']} python takes with bits past the data\n")
PY
  if ! "$IYI" run "$WORK/broken_cases.iyi" >"$WORK/broken_got.txt" 2>&1; then
    echo "  the cases did not run: $(tail -1 "$WORK/broken_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
got = open(os.path.join(work, "broken_got.txt")).read().splitlines()
want = [line.split("\t", 1) for line in open(os.path.join(work, "broken_expected.txt")).read().splitlines()]
bad = [(w, g) for w, g in zip(want, got + [""] * len(want)) if w[0] != g]
for w, g in bad[:8]:
    print(f"  {w[1]}: python {w[0]!r}, iyi {g!r}")
kinds = open(os.path.join(work, "broken_kinds.txt")).read().strip()
print(f"  {len(want) - len(bad)} of {len(want)} broken texts answered as python's verdict says ({kinds})")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== an error value's sentence, through .or_panic"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/base32::{Base32, Base32Hex}

case Program.args[0]
when "outside"
  Base32.decode("MZXW6Y*B").or_panic
when "after-padding"
  Base32.decode("MY======MZXQ====").or_panic
when "short-padding"
  Base32.decode("MZXQ===").or_panic
when "ragged"
  Base32.decode("MZXW6YTBO").or_panic
when "past-the-data"
  Base32.decode("MZXW6YTBOJ").or_panic
when "hex-outside"
  Base32Hex.decode("CPNMUOJ1EZ").or_panic
end
puts "accepted"
IYI
refuse() { # refuse <case> <phrase>
  if "$IYI" run "$WORK/refuse.iyi" -- "$1" >"$WORK/refuse.out" 2>&1; then
    echo "  $1 was accepted: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  elif ! grep -qF -e "$2" "$WORK/refuse.out"; then
    echo "  $1 was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  else
    echo "  $1: $(tr -d '\r' <"$WORK/refuse.out" | grep -oF -e "$2" | head -1)"
  fi
}
refuse outside "base32: byte 6 is '*', which is not in the alphabet"
refuse after-padding "base32: data after the padding, at byte 8"
refuse short-padding "base32: 3 padding characters after 4 data characters, where 4 close the group"
refuse ragged "base32: a last group of 1 data character ends on no whole byte"
refuse past-the-data "base32: the last data character, 'J' at byte 9, sets bits past the data; canonically it is 'I'"
refuse hex-outside "base32hex: byte 9 is 'Z', which is not in the alphabet"

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
src = Path("$REPO/src/std/base32.iyi").read_text(encoding="utf-8")
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/base32.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_base32_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
# Encoder and decoder share the alphabet, so the round trips still hold:
# it is the RFC's vectors that see it.
prove_broken "the alphabet with M and N swapped" 'RFC 4648 base32 "f"' \
  '"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"' '"ABCDEFGHIJKLNMOPQRSTUVWXYZ234567"'
prove_broken "base32hex with V for U" 'RFC 4648 base32hex "foo"' \
  '"0123456789ABCDEFGHIJKLMNOPQRSTUV"' '"0123456789ABCDEFGHIJKLMNOPQRSTVU"'
prove_broken "the last character's bits not shifted up" 'RFC 4648 base32 "f"' \
  'dst[o] = table[(acc << (5 - bits)) & 31]' 'dst[o] = table[acc & 31]'
prove_broken "upper case alone" "a round trip of 1 bytes in lower case" \
  'values[c.to_i32 + 32] = k if c >= 65_u8 && c <= 90_u8' 'values[c.to_i32] = k'
prove_broken "padding of any length taken" "short padding refused" \
  'if pads > 0 && pads != wanted' 'if false'
prove_broken "bits past the data ignored" "bits past the data" \
  '      if clean != last' '      if false'
prove_broken "a last group of six characters taken" "a last group of 6" \
  'if rest == 1 || rest == 3 || rest == 6' 'if rest == 1 || rest == 3'
prove_broken "data after the padding taken" "data after padding" \
  '        return Base32Error.new("#{name}: data after the padding, at byte #{j}")' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/base32 exercise holds"
else
  echo "the std/base32 exercise did not hold"
fi
exit $status
