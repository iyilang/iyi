#!/usr/bin/env bash
# Exercises `std/bzip2`: bzip2 read and written in iyi, against Python's
# `bz2` (libbzip2) as the oracle in both directions, and bzip2(1) where
# the machine has it.
#
#     bash bench/std_bzip2_exercise.sh
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

# What libbzip2 writes, through Python's `bz2`, at levels 1 and 9, for
# iyi to read: nothing, one byte, text, a long run, a period of two, runs
# of every length around the run-length code's edges, noise, every byte,
# and 350 KB that level 1 cuts into four blocks; forty streams one after
# another, of every level and some empty; and one stream of 64 MiB, with
# its size and CRC-32 beside it.
mkdir -p "$WORK/fixtures"
if [ -z "$PY" ]; then
  echo "no python3 on this machine: the bz2 oracle cannot be written, so std/bzip2 goes unmeasured"
  exit 0
fi
if ! "$PY" - "$WORK/fixtures" <<'PY'
import bz2, os, random, sys, zlib
out = sys.argv[1]
rng = random.Random(20261017)
text = b"".join(b"%d: the quick brown fox jumps over the lazy dog %d times\n" % (i, i % 13) for i in range(6000))
runs = b"".join(bytes([rng.getrandbits(8)]) * n for n in [1, 2, 3, 4, 5, 6, 250, 251, 254, 255, 256, 257, 259, 260, 509, 510, 511, 512, 1000] * 20)
corpora = {
    "empty": b"",
    "byte": b"\x7f",
    "text": text,
    "repeat": b"z" * 400000,
    "ab": b"ab" * 200000,
    "runs": runs,
    "random": rng.randbytes(250000),
    "every": bytes(range(256)) * 300,
    "multi": text[:200000] + rng.randbytes(50000) + text[:100000],
}
for name, data in corpora.items():
    open(os.path.join(out, name + ".bin"), "wb").write(data)
    for level in (1, 9):
        open(os.path.join(out, f"{name}.{level}.bz2"), "wb").write(bz2.compress(data, level))
parts = []
streams = []
for i in range(40):
    part = b"" if i % 7 == 0 else text[i * 997:(i * 997) + i * 300] + rng.randbytes(i * 5) + b"q" * (i * 13)
    parts.append(part)
    streams.append(bz2.compress(part, i % 9 + 1))
open(os.path.join(out, "many.bin"), "wb").write(b"".join(parts))
open(os.path.join(out, "many.bz2"), "wb").write(b"".join(streams))
# 64 MiB a megabyte at a time through one compressor: one stream.
comp = bz2.BZ2Compressor(9)
crc = 0
total = 0
with open(os.path.join(out, "big.bz2"), "wb") as f:
    for i in range(64):
        chunk = b"".join(b"%08d %s\n" % (j, b"x" * (j % 40)) for j in range(i * 20000, i * 20000 + 20000))
        chunk = (chunk * 2)[:1 << 20]
        crc = zlib.crc32(chunk, crc)
        total += len(chunk)
        f.write(comp.compress(chunk))
    f.write(comp.flush())
open(os.path.join(out, "big.expect"), "w").write("%d %08x\n" % (total, crc))
PY
then
  echo "the bz2 oracle could not be written; nothing below would be measuring the module" >&2
  exit 2
fi
# Nine corpora, each `.bin` and two levels; forty streams and their
# `.bin`; the 64 MiB stream and its size and CRC: 9 * 3 + 2 + 2.
fixture_count="$(find "$WORK/fixtures" -type f | wc -l | tr -d ' ')"
if [ "$fixture_count" -ne 31 ]; then
  echo "the bz2 oracle wrote $fixture_count files where 31 were expected" >&2
  exit 2
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_bzip2_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" "$WORK/fixtures" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/bzip2 exercise, plain build"
build_and_run "plain" bzip2-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/bzip2-plain.out" 2>/dev/null; then
  echo "plain: ALL CHECKS PASSED missing"
  status=1
fi

echo
echo "== every bzip2 section reported"
for phrase in "== round trips" "== the format's own words" "== streaming" "== concatenated streams" \
              "== refused as a value" "== against python" "== 64 MiB in bounded memory" "== timings"; do
  if ! grep -qF "$phrase" "$WORK/bzip2-plain.out"; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== what iyi wrote, read by Python's bz2"
# Each corpus at levels 1 and 9 and the forty streams' bytes as one, which
# Python reads whole and through a decompressor fed 4,099 bytes at a time;
# and every corrupt stream the exercise refused, which Python refuses too.
"$PY" - "$WORK/fixtures" <<'PY' || status=1
import bz2, os, sys
d = sys.argv[1]
failed = False
names = ["empty", "byte", "text", "repeat", "ab", "runs", "random", "every", "multi"]
pairs = [(f"{n}.iyi{level}.bz2", f"{n}.bin") for n in names for level in (1, 9)] + [("many.iyi.bz2", "many.bin")]
for stream, plain in pairs:
    data = open(os.path.join(d, stream), "rb").read()
    want = open(os.path.join(d, plain), "rb").read()
    try:
        whole = bz2.decompress(data)
        dec = bz2.BZ2Decompressor()
        pieces = b"".join(dec.decompress(data[i:i + 4099]) for i in range(0, len(data), 4099))
        ok = whole == want and pieces == want and dec.eof and dec.unused_data == b""
    except Exception as e:
        print(f"  {stream}: Python refused it: {e}")
        failed = True
        continue
    if not ok:
        print(f"  {stream}: Python read {len(whole)} bytes, not the {len(want)} given")
        failed = True
print(f"  {len(pairs)} streams read back by Python, whole and 4,099 bytes at a time")
bad = sorted(n for n in os.listdir(d) if n.startswith("bad_"))
for name in bad:
    try:
        bz2.decompress(open(os.path.join(d, name), "rb").read())
        print(f"  {name}: Python read it, the exercise refused it")
        failed = True
    except (OSError, ValueError, EOFError) as e:
        print(f"  {name}: Python refuses it too ({type(e).__name__}: {e})")
if len(bad) != 13:
    print(f"  {len(bad)} corrupt streams written, where 13 were expected")
    failed = True
sys.exit(1 if failed else 0)
PY

echo
echo "== what iyi wrote, tested by bzip2(1)"
if command -v bzip2 >/dev/null 2>&1; then
  tested=0
  for f in "$WORK"/fixtures/*.iyi*.bz2; do
    plain="$WORK/fixtures/$(basename "$f" | sed 's/\.iyi[0-9]*\.bz2$/.bin/')"
    if ! bzip2 -t "$f" 2>/dev/null || ! bzip2 -dc "$f" | cmp -s - "$plain"; then
      echo "  $(basename "$f"): bzip2 does not read it back"
      status=1
    fi
    tested=$((tested + 1))
  done
  echo "  $tested streams tested and read back by $(bzip2 --help 2>&1 | head -1 | sed 's/,.*//')"
else
  echo "  no bzip2 on this machine; Python's libbzip2 above is the oracle"
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" bzip2-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/bzip2-release.out" 2>/dev/null; then
  echo "release: ALL CHECKS PASSED missing"
  status=1
fi
sed -n '/== 64 MiB/,$p' "$WORK/bzip2-release.out" | sed 's/^/  /'

echo
echo "== std/bzip2 reaches nothing"
# `iyi mod reach` reads a package's reach off its import lines and the C
# it declares, transitively through std; this is that rule for std/bzip2:
# what it imports, and what those import, declare no C and call no
# runtime hook, so a package that unpacks a .bz2 reaches no file, clock
# or socket - the bytes come from the caller's block.
reached="std/bzip2"
todo="std/bzip2"
while [ -n "$todo" ]; do
  next=""
  for module in $todo; do
    for imported in $(sed -n 's/^import \(std\/[a-z_0-9]*\).*/\1/p' "$REPO/src/$module.iyi"); do
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
  echo "  FAIL: std/bzip2 reaches the platform through:$bound"
  status=1
else
  echo "  std/bzip2 imports$(echo " $reached" | sed 's/ std\/bzip2//'), and none of it calls C"
fi

echo
echo "== what a caller's mistake panics with, by name"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/bzip2::{Bzip2, Bzip2Reader, Bzip2Error}\n\nputs (%s).to_s.bytesize\n' \
    "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -qF "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase' (exit $code, $(wc -c < "$WORK/$name.out") bytes said)"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 -oF "$phrase" "$WORK/$name.out")"
}
refuses "a level of 0" level0 "Bzip2.compress: level must be 1 to 9, not 0" 'Bzip2.compress("abc", 0)'
refuses "a level of 10" level10 "Bzip2.compress: level must be 1 to 9, not 10" 'Bzip2.compress("abc", 10)'
refuses "a read of no bytes" read_zero "Bzip2Reader: read wants at least one byte, not 0" \
  'Bzip2Reader.new { nil }.read(0)'

echo
echo "== proving the checks can fail when the module is broken"
mutations=0
mutate() { # mutate <label> <old> <new> <phrase>
  # A binary of its own each: on Windows the last one's file can still be
  # held a moment after it ended, and the next link over it failed with
  # LNK1104.
  mutations=$((mutations + 1))
  local label="$1" old="$2" new="$3" phrase="$4"
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/bzip2.iyi").read_text()
old = os.environ["OLD"]
if old not in src:
    raise SystemExit("patch site missing: " + old)
Path("$WORK/patched/std/bzip2.iyi").write_text(src.replace(old, os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  # Build first, then run: a patch that does not compile would also "fail",
  # and that proves nothing about whether the exercise catches the break.
  elif ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mut-$mutations.bin" "$REPO/bench/std_bzip2_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/mut.out"
    status=1
  elif "$WORK/mut-$mutations.bin" "$WORK/fixtures" >"$WORK/mut.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF "$phrase" "$WORK/mut.out"; then
    echo "  $label: failed, but not at the check that names '$phrase':"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught at \"$phrase\""
  fi
}
# The decoder's checks, each where the exercise breaks a stream for it.
mutate "a block CRC never compared" 'unless got == @block_crc' 'unless true' \
  "a block CRC one bit off"
mutate "a combined CRC never compared" 'unless want == @combined' 'unless true' \
  "a combined CRC one bit off"
mutate "a CRC table from the wrong polynomial" '0x04c11db7_u32' '0x04c11db6_u32' \
  "fc891918"
mutate "an origin pointer one past the block let through" 'if origin >= nblock' 'if origin > nblock' \
  "an origin pointer one past the block"
mutate "a selector as far as the table count let through" 'if j >= groups' 'if j > groups' \
  "a selector past the tables"
mutate "a group past the selectors read anyway" 'if group >= nsel' 'if group > nsel' \
  "a block with one selector too few"
mutate "a code length of 21 let through" 'curr < 1 || curr > 20' 'curr < 1 || curr > 21' \
  "a code length walked to 21"
mutate "an over-subscribed table let through" 'return false if left < 0' 'return false if left < 0 && len > MAX_LEN' \
  "every code one bit long"
# What the decoder undoes: the run-length count, the selectors, the codes
# past the fast table's ten bits.
mutate "a run-length count one more" 'repeat = b.to_i32' 'repeat = b.to_i32 + 1' \
  "four equal at level 1"
mutate "every group read with the first table" '@selectors[i] = v' '@selectors[i] = 0_u8' \
  "three equal at level 1"
mutate "codes of eleven bits never looked for" 'len = Bzip2Table::FAST + 1' 'len = Bzip2Table::FAST + 2' \
  "text at level 1"
# The streaming reader's own: a read that runs on into the next block, and
# what is left over.
mutate "a read that runs on past a block's end" 'break if n > 0 && !core.output?' 'break if false' \
  "a read stops where a block ends"
mutate "a leftover without the bytes loaded ahead" 'held = @count // 8' 'held = 0' \
  "what is left over is what was fed past the stream"
# The writer: the sort, the zero runs, and the table choice, which only
# the size against libbzip2's can see.
mutate "a sort whose prefix grows fourfold" 'h = h << 1' 'h = h << 2' \
  "four equal at level 1"
mutate "a sort that stops after one round" 'while classes < n && h < n' 'while classes < n && h < 2' \
  "four equal at level 1"
mutate "RUNA and RUNB swapped" 'sym = (z & 1) == 1 ? RUNB : RUNA' 'sym = (z & 1) == 1 ? RUNA : RUNB' \
  "one byte at level 1"
mutate "each group given the table that codes it worst" 'best = t if cost[t] < cost[best]' 'best = t if cost[t] > cost[best]' \
  "against libbzip2's"

echo
if [ "$status" -eq 0 ]; then
  echo "the std/bzip2 exercise holds"
else
  echo "the std/bzip2 exercise did not hold"
fi
exit $status
