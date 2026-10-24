#!/usr/bin/env bash
# Exercises `std/number_format`: `Number#format`, `Number#humanize` and
# `Int#humanize_bytes`.
#
#     bash bench/std_number_format_exercise.sh
#
# Proves the exercise holds plain and --release; that every case its
# `oracle` mode prints - random doubles, singles, integers and byte counts,
# and the ties, carries and powers where rounding decides - is what exact
# decimal arithmetic (Python's `decimal`) writes, and the same from the
# optimised build; and that a broken module is caught, at a named check or
# by the oracle.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The oracle and the patches are written in python, and windows answers
# `python3` with a store stub that prints and exits rather than running it,
# so the interpreter is measured here instead of assumed.
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
EXERCISE="$REPO/bench/std_number_format_exercise.iyi"

build_and_run() { # build_and_run <label> <name> [flags...]
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
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
  if ! grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    echo "$label: missing pass sentinel"
    status=1
    return 1
  fi
}

echo "== the std/number_format exercise, plain build"
build_and_run "plain" nf-plain

echo
echo "== every section reported"
for phrase in "== digits in groups" "== scaled to a prefix" "== bytes" "== what it refuses"; do
  if ! grep -q "$phrase" "$WORK/nf-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" nf-release --release >/dev/null

# The oracle: every case the exercise prints, recomputed from the bits or
# the integer in exact decimal arithmetic - Decimal's `adjusted` for the
# leading digit's place, `quantize` half to even for every rounding, and
# `repr` for a double's shortest digits - written apart from the module's
# own way of reaching them.
cat >"$WORK/oracle.py" <<'PY'
import struct, sys
from decimal import Decimal as D, ROUND_HALF_EVEN, getcontext

getcontext().prec = 2000
SI = dict(zip(range(-30, 33, 3), "q r y z a f p n µ m _ k M G T P E Z Y R Q".split()))
SI[0] = ""
IEC = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
JEDEC = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]


def double(bits):
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


def single(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def grouped(whole):
    return "{:,}".format(int(whole))


def text(sign, whole, frac):
    zero = int(whole) == 0 and (frac == "" or int(frac) == 0)
    return ("-" if sign and not zero else "") + grouped(whole) + ("." + frac if frac else "")


def split(dec):
    whole, _, frac = format(abs(dec), "f").partition(".")
    return whole, frac


def shortest_format(shortest, negative):
    whole, frac = split(D(shortest))
    return text(negative, whole, frac.rstrip("0") or "0")


def fixed(x, places, only):
    q = D(x).quantize(D(1).scaleb(-places), rounding=ROUND_HALF_EVEN)
    whole, frac = split(q)
    return text(x < 0, whole, frac.rstrip("0") if only else frac)


def floor3(d):
    return max(-30, min(30, (d // 3) * 3))


def mantissa_text(m, trim, group=True):
    whole, frac = split(m)
    if trim:
        frac = frac.rstrip("0")
    return (grouped(whole) if group else whole) + ("." + frac if frac else "")


def humanize(a, negative, n, sig):
    if a == 0:
        return "0"
    if sig:
        d = a.adjusted()
        r = a.scaleb(n - 1 - d).quantize(D(1), rounding=ROUND_HALF_EVEN)
        if r >= 10 ** n:
            d += 1
            r = a.scaleb(n - 1 - d).quantize(D(1), rounding=ROUND_HALF_EVEN)
        p = floor3(d)
        body = mantissa_text(r.scaleb(d - n + 1 - p), True)
    else:
        p = floor3(a.adjusted())
        while True:
            r = a.scaleb(-p).quantize(D(1).scaleb(-n), rounding=ROUND_HALF_EVEN)
            if r >= 1000 and p < 30:
                p += 3
                continue
            break
        body = mantissa_text(r, False)
    return ("-" if negative else "") + body + SI[p]


def bytes_text(v, n, sig, units):
    if v < 1024:
        return "%dB" % v
    k = 0
    while k < 6 and v >= 1024 ** (k + 1):
        k += 1
    while True:
        m = D(v) / D(1024 ** k)
        if sig:
            d = m.adjusted()
            r = m.scaleb(n - 1 - d).quantize(D(1), rounding=ROUND_HALF_EVEN)
            value = r.scaleb(d - n + 1)
        else:
            value = m.quantize(D(1).scaleb(-n), rounding=ROUND_HALF_EVEN)
        if value >= 1024 and k < 6:
            k += 1
            continue
        # Under 1024 in its unit, a byte count is never grouped.
        return mantissa_text(value, sig, False) + units[k]


def single_shortest(x):
    for n in range(1, 10):
        s = "%.*e" % (n - 1, x)
        if single(struct.unpack("<I", struct.pack("<f", float(s)))[0]) == x:
            return s
    raise SystemExit("no shortest for %r" % x)


def expected(kind, fields):
    if kind in ("FN", "FP", "FS", "HS", "HP"):
        x = double(int(fields[0]))
        if kind == "FN":
            return shortest_format(repr(abs(x)), x < 0)
        n = int(fields[1])
        if kind == "FP":
            return fixed(x, n, False)
        if kind == "FS":
            return fixed(x, n, True)
        return humanize(abs(D(x)), x < 0, n, kind == "HS")
    if kind == "GN":
        x = single(int(fields[0]))
        return shortest_format(single_shortest(abs(x)), x < 0)
    v = int(fields[0])
    if kind == "IN":
        return text(v < 0, str(abs(v)), "")
    n = int(fields[1])
    if kind in ("IH", "IP"):
        return humanize(D(abs(v)), v < 0, n, kind == "IH")
    if kind == "BI":
        return bytes_text(v, n, True, IEC)
    if kind == "BJ":
        return bytes_text(v, n, False, JEDEC)
    raise SystemExit("unknown case kind " + kind)


counts, wrong = {}, []
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split(" ")
    kind = parts[0]
    arity = 1 if kind in ("FN", "GN", "IN") else 2
    fields, said = parts[1:1 + arity], " ".join(parts[1 + arity:])
    want = expected(kind, fields)
    counts[kind] = counts.get(kind, 0) + 1
    if said != want:
        wrong.append("%s %s: wrote %s, exact is %s" % (kind, " ".join(fields), said, want))
total = sum(counts.values())
if total < 25000:
    raise SystemExit("  only %d cases came out" % total)
if wrong:
    print("  %d of %d cases differ from exact decimal arithmetic:" % (len(wrong), total))
    for w in wrong[:8]:
        print("    " + w)
    sys.exit(1)
print("  %d cases agree with exact decimal arithmetic (%s)" % (total, ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
PY

# oracle <binary> <name>: runs its oracle mode and checks every case.
oracle() {
  "$1" oracle >"$WORK/$2.cases" 2>&1 || { echo "  $2: the oracle mode exited $?"; tail -3 "$WORK/$2.cases"; return 1; }
  "$PY" "$WORK/oracle.py" "$WORK/$2.cases"
}

echo
echo "== every case against exact decimal arithmetic"
if [ -z "$PY" ]; then
  echo "  no python on this machine, so the oracle is unmeasured"
else
  oracle "$WORK/nf-plain" plain || status=1
  # The optimised build writes the same text for every case.
  if "$WORK/nf-release" oracle >"$WORK/release.cases" 2>&1 && cmp -s "$WORK/plain.cases" "$WORK/release.cases"; then
    echo "  the --release build wrote the same $(wc -l <"$WORK/release.cases" | tr -d ' ') cases"
  else
    echo "  the --release build wrote different cases:"
    diff "$WORK/plain.cases" "$WORK/release.cases" | head -5 | sed 's/^/    /'
    status=1
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
# patch <name> <old> <new>: a copy of std/number_format.iyi with <old>
# replaced, under $WORK/<name>/std.
patch() {
  mkdir -p "$WORK/$1/std"
  SRC="$REPO/src/std/number_format.iyi" DST="$WORK/$1/std/number_format.iyi" OLD="$2" NEW="$3" "$PY" - <<'PY'
import os
from pathlib import Path
src = Path(os.environ["SRC"]).read_text(encoding="utf-8")
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path(os.environ["DST"]).write_text(src.replace(old, os.environ["NEW"], 1), encoding="utf-8")
PY
}

# breaks <label> <name> <old> <new> <check>: the exercise stops at the
# assertion that names <check>. The message proves the broken copy built
# and ran up to it.
breaks() {
  local label="$1" name="$2" old="$3" new="$4" check="$5"
  if ! patch "$name" "$old" "$new"; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  IYI_PATH="$WORK/$name${PSEP}$IYI_PATH" "$IYI" run "$EXERCISE" >"$WORK/$name.out" 2>&1
  if grep -q "ALL CHECKS PASSED" "$WORK/$name.out"; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "ASSERTION FAILED: $check" "$WORK/$name.out"; then
    echo "  $label: it failed, but not at '$check'"
    sed -n '1,5p' "$WORK/$name.out" | sed 's/^/    /'
    status=1
  else
    echo "  $label: caught at \"$check\""
  fi
}

# misleads <label> <name> <old> <new> <kind>: the named checks pass, and
# the oracle finds the broken copy's <kind> cases wrong.
misleads() {
  local label="$1" name="$2" old="$3" new="$4" kind="$5"
  if ! patch "$name" "$old" "$new"; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$name${PSEP}$IYI_PATH" "$IYI" build -o "$WORK/$name.bin" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: the broken copy did not build"
    tail -5 "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return
  fi
  if oracle "$WORK/$name.bin" "$name" >"$WORK/$name.verdict" 2>&1; then
    echo "  $label: the oracle passed a broken module"
    status=1
  elif ! grep -q "^    $kind " "$WORK/$name.verdict"; then
    echo "  $label: the oracle failed it, but not on $kind cases:"
    sed -n '1,4p' "$WORK/$name.verdict"
    status=1
  else
    echo "  $label: caught by the oracle, $(sed -n '1p' "$WORK/$name.verdict" | sed 's/^ *//; s/ differ.*//') wrong, first on $kind"
  fi
}

if [ -z "$PY" ]; then
  echo "  no python on this machine, so the broken-module proofs are unmeasured"
else
  breaks "groups counted from the left" groups \
    '      first = group if first == 0
' '' '1e20 written out is'
  breaks "a zero that keeps its sign" signed_zero \
    'text = (negative && !zero ? "-" : "")' 'text = (negative ? "-" : "")' \
    'a value that prints as zero has no sign'
  breaks "a prefix below one truncated toward zero" truncated \
    'prefix = lead >= 0 ? (lead // 3) * 3 : 0 - ((2 - lead) // 3) * 3' 'prefix = (lead // 3) * 3' \
    'below one, the small prefixes'
  breaks "bytes that never round into the next unit" no_bump \
    'if power < 6 && whole.to_i >= 1024' 'if false' \
    '1048575 at four digits is'
  breaks "significant digits with their zeros kept" untrimmed \
    '      fraction = trim_zeros(fraction)
    else' '    else' \
    'a thousand is 1k'
  breaks "a float written without its point" pointless \
    '    fraction = "0" if fraction.empty? && !only_significant
' '' '1e20 written out is 100,000,000,000,000,000,000'
  # 1023.5 KiB rounds at four digits to 1024, which is 0.9995 MiB; read at
  # the ones place it is "1000", and was 1 MiB.
  misleads "a 10...0 taken at the place guessed" guessed \
    'elsif power_of_ten?(digits)' 'elsif false' BI
  # 961.6 zetta at one digit is 1000: without the look one prefix lower,
  # it was 1.0Y at places.
  misleads "a prefix from a value rounded up to a thousand" rounded_up \
    'prefix = prefix - 3 if place(lower, 0 - precision)[0].bytesize <= 3' '# the prefix kept' HP
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/number_format exercise holds"
else
  echo "the std/number_format exercise did not hold"
fi
exit $status
