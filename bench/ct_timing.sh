#!/usr/bin/env bash
# A dudect-style timing check of std's secret paths (bench/ct_timing.iyi
# says how): std/big's `inverse_mod_secret`, std/rsa's `sign_pss`, P-256
# and P-384 signing, Ed25519 signing, X25519, ML-KEM-768 decapsulation
# (valid against tampered ciphertexts, one key against others) and the
# AEADs' tag checks, one class against another, interleaved, Welch's t
# between the two. Then the extended Euclid's
# algorithm std/rsa used to invert its blinding factor, which leaks, so that
# a run that cannot see a leak says so instead of passing. Then what no
# timing shows: the --release assembly of the same program, read for how
# each pick by a secret is made (the last section says what is read).
#
#     bash bench/ct_timing.sh            # the default sample counts
#     CT_SCALE=4 bash bench/ct_timing.sh # four times as many
#
# Fails loudly when a secret path's |t| is over 10, or the leaky Euclid's
# is not, or a pick's machine code is not masks behind a barrier. A tool,
# not a gate: run it by hand on a quiet machine (here,
# inside ~/.cache/heavy.sh). CI does not run it, and should not - on a
# shared runner another job's load lands on one class more than the other
# often enough to put |t| past 10 with nothing leaking. An RSA key is made
# with openssl or Python's cryptography; with neither, the RSA path is
# skipped with a sentence.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
SCALE="${CT_SCALE:-1}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export IYI_PATH="$REPO/src"

if ! "$IYI" build --release -o "$WORK/ct" "$REPO/bench/ct_timing.iyi" >"$WORK/build.log" 2>&1; then
  echo "FAIL: bench/ct_timing.iyi did not build"
  sed -n '1,12p' "$WORK/build.log"
  exit 1
fi

key=""
if command -v openssl >/dev/null 2>&1 && openssl genrsa -out "$WORK/k.pem" 2048 >/dev/null 2>&1; then
  key="$WORK/k.pem"
elif command -v python3 >/dev/null 2>&1 && python3 -c '
import sys
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
k = rsa.generate_private_key(public_exponent=65537, key_size=2048)
open(sys.argv[1], "wb").write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
' "$WORK/k.pem" >/dev/null 2>&1; then
  key="$WORK/k.pem"
fi

status=0
# t_of <target> <samples> [pem]: the largest |t| the program printed.
t_of() {
  local line
  if ! line="$("$WORK/ct" "$@" 2>&1)"; then
    echo "  FAIL: $1 did not run: $line" >&2
    echo 999
    return
  fi
  echo "  $line" >&2
  echo "$line" | sed 's/.*max |t| = \([0-9.]*\).*/\1/'
}
over() { awk -v t="$1" 'BEGIN { exit !(t > 10) }'; }

echo "== secret paths: |t| must stay at or under 10"
for pair in "inverse:$((100000 * SCALE))" "p256-length:$((100000 * SCALE))" "p384:$((50000 * SCALE))" "ed25519:$((100000 * SCALE))" \
  "x25519:$((100000 * SCALE))" "mlkem-ct:$((50000 * SCALE))" "mlkem-key:$((50000 * SCALE))" "aes-gcm:$((100000 * SCALE))" \
  "chacha:$((100000 * SCALE))" "rsa:$((20000 * SCALE))"; do
  target="${pair%%:*}"
  samples="${pair#*:}"
  if [ "$target" = rsa ] && [ -z "$key" ]; then
    echo "  no openssl and no Python cryptography to make an RSA key, so sign_pss goes untimed"
    continue
  fi
  t="$(t_of "$target" "$samples" $([ "$target" = rsa ] && echo "$key"))"
  if over "$t"; then
    echo "  FAIL: $target's time tells its classes apart, |t| = $t"
    status=1
  fi
done

echo
echo "== the leak the check has to see: the old extended Euclid inverse"
t="$(t_of euclid $((5000 * SCALE)))"
if over "$t"; then
  echo "  seen, |t| = $t"
else
  echo "  FAIL: the Euclid inverse's leak went unseen (|t| = $t), so the numbers above prove nothing"
  status=1
fi

echo
echo "== what no timing shows: how each pick by a secret is made, read off the machine code"
# A masked choice that a compiler turned into one of two addresses kept by
# a conditional move, and a single load through it, takes the same time
# whichever it kept: ML-KEM's decapsulation was that, K against K-bar, at
# |t| = 2.4 above. Which was kept is in the address read, which a cache
# shows and a clock does not. And a selector a compiler turned into a
# branch shows only once its mispredictions rise over the machine's noise.
# So the instructions are read, in this program's --release assembly for
# two pinned targets whatever the host is (`--cross-compile` writes the
# assembly and links nothing, so neither target's toolchain is needed).
# Each function below has to hold the value barriers its masks go through
# (an empty `#APP`/`#NO_APP` pair is what std/digest's `ValueBarrier`
# leaves), no conditional move in it may keep one of two pointers that a
# load then reads through, and a lookup's only conditional jumps may be
# its loop's and its counters' checks. The gates of std/mlkem, std/p256,
# std/p384 and std/curve25519 read the same of their own modules, prove
# on broken copies that the reading can fail, and read `P256Point.lookup`
# too, the window over a peer's point, which this program, signing and
# never agreeing on a P-256 key, does not hold.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
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
if [ -z "$PY" ]; then
  echo "  no python here to read the assembly with, so the picks' machine code goes unread"
else
  for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu; do
    if ! "$IYI" build --release --emit asm --x86-asm-syntax intel --cross-compile --target "$target" \
      -o "$WORK/$target" "$REPO/bench/ct_timing.iyi" >"$WORK/$target.log" 2>&1 || [ ! -s "$WORK/$target.s" ]; then
      echo "  FAIL: $target: no assembly was written: $(grep -m1 -E 'Error|BUG' "$WORK/$target.log")"
      status=1
      continue
    fi
    wrong=0
    while read -r name count mode; do
      if ! "$PY" "$WORK/machine.py" "$WORK/$target.s" "$name" "$count" $mode >"$WORK/$target.read" 2>&1; then
        sed "s/^/  FAIL: $target: /" "$WORK/$target.read"
        wrong=1
        status=1
      fi
    done <<'READ'
MlKem768PrivateKey#decapsulate< 1
P256BaseTable::pick< 3 lookup
P256BaseTable::top< 1 lookup
P384Point::lookup< 1 lookup
CurveLadder::x25519< 2 lookup
CurveBaseTable::pick< 2 lookup
READ
    [ "$wrong" -eq 0 ] && echo "  $target: decapsulate's pick, P-256's fixed-base and P-384's window lookups, the ladder's swap and Ed25519's lookup are masks behind their barriers"
  done
fi

echo
if [ "$status" -eq 0 ]; then
  echo "no secret path's time told its classes apart, and the leaky one's did"
else
  echo "TIMING CHECK FAILED"
fi
exit "$status"
