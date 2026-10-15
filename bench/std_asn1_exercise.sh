#!/usr/bin/env bash
# Exercises `std/asn1`.
#
#     bash bench/std_asn1_exercise.sh
#
# The exercise holds X.690's DER rules on hand-written values, each kind
# accepted and refused, and the walk's depth bound; this gate runs it
# plain and --release, reads every certificate in the machine's root store
# and holds each value's offset, depth, header, length, form and tag to
# `openssl asn1parse`, holds each certificate's serial, signature
# algorithm, validity and names to Python's `cryptography`, reads
# thousands of those certificates broken at random without a panic, shows
# an error value's sentence through `.or_panic`, and proves on broken
# copies of the module that the checks fail where they say.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_asn1_exercise.iyi" \
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

echo "== the std/asn1 exercise, plain build"
build_and_run "plain" asn1-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/asn1-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every asn1 section reported"
for phrase in "== headers and lengths" "== integers" "== object identifiers" \
              "== bit strings, booleans, null and octets" "== strings" "== times" "== the walk"; do
  if ! grep -q "$phrase" "$WORK/asn1-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" asn1-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/asn1-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# The certificates: the machine's root store, one DER file each. A bundle
# is split by its PEM armour; each body is base64, which Python decodes.
echo
echo "== the machine's root certificates"
mkdir -p "$WORK/der"
BUNDLE=""
for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [ -f "$candidate" ]; then
    BUNDLE="$candidate"
    break
  fi
done
CERTS=0
if [ -z "$PY" ] || [ -z "$BUNDLE" ]; then
  echo "  no python3 or no CA bundle on this machine, so the certificates go unread"
else
  CERTS="$("$PY" - "$BUNDLE" "$WORK/der" <<'PY'
import base64, re, sys
text = open(sys.argv[1], encoding="ascii", errors="replace").read()
bodies = re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)
for i, body in enumerate(bodies):
    open(f"{sys.argv[2]}/{i:04d}.der", "wb").write(base64.b64decode("".join(body.split())))
print(len(bodies))
PY
)"
  echo "  $CERTS certificates from $BUNDLE"
fi

echo
echo "== every value as openssl asn1parse reads it"
if [ "$CERTS" -eq 0 ] || ! command -v openssl >/dev/null 2>&1; then
  echo "  no certificates or no openssl here, so the structure goes uncompared"
else
  "$WORK/asn1-plain" dump "$WORK"/der/*.der >"$WORK/dump.txt" 2>&1
  if ! "$PY" - "$WORK/dump.txt" "$WORK"/der/*.der <<'PY'
import os, re, subprocess, sys
# openssl's names for the universal tags, back to their numbers.
names = {"BOOLEAN": 1, "INTEGER": 2, "BIT STRING": 3, "OCTET STRING": 4, "NULL": 5, "OBJECT": 6,
         "ENUMERATED": 10, "UTF8STRING": 12, "SEQUENCE": 16, "SET": 17, "NUMERICSTRING": 18,
         "PRINTABLESTRING": 19, "T61STRING": 20, "IA5STRING": 22, "UTCTIME": 23, "GENERALIZEDTIME": 24,
         "VISIBLESTRING": 26, "UNIVERSALSTRING": 28, "BMPSTRING": 30}
want = []
for f in sys.argv[2:]:
    want.append("file " + os.path.basename(f))
    out = subprocess.run(["openssl", "asn1parse", "-inform", "DER", "-in", f], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r"\s*(\d+):d=\s*(\d+)\s+hl=\s*(\d+)\s+l=\s*(\d+)\s+(prim|cons):\s+([^:]*)", line)
        if not m:
            raise SystemExit("  openssl wrote a line this cannot read: " + line)
        tag = m.group(6).replace("[HEX DUMP]", "").strip()
        t = re.match(r"(cont|appl|priv) \[\s*(\d+)\s*\]", tag)
        kind = ({"cont": "c", "appl": "a", "priv": "p"}[t.group(1)] + t.group(2)) if t else "u%d" % names[tag]
        want.append(f"{m.group(2)} {m.group(1)} {m.group(3)} {m.group(4)} {m.group(5)} {kind}")
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
bad = [(w, g) for w, g in zip(want, got) if w != g]
if len(want) != len(got):
    bad.append((f"{len(want)} lines", f"{len(got)} lines"))
values = sum(1 for w in want if not w.startswith("file"))
if bad:
    print(f"  {len(bad)} of {values} values differ from openssl asn1parse:")
    for w, g in bad[:6]:
        print(f"    openssl {w!r}, iyi {g!r}")
    sys.exit(1)
print(f"  {values} values in {len(sys.argv) - 2} certificates: offset, depth, header, length, form and tag as openssl reads them")
PY
  then
    status=1
  fi
fi

echo
echo "== each certificate as Python's cryptography reads it"
if [ "$CERTS" -eq 0 ] || ! "$PY" -c 'from cryptography import x509' >/dev/null 2>&1; then
  echo "  no certificates or no python cryptography here, so the fields go uncompared"
else
  "$WORK/asn1-plain" fields "$WORK"/der/*.der >"$WORK/fields.txt" 2>&1
  if ! "$PY" - "$WORK/fields.txt" "$WORK"/der/*.der <<'PY'
import os, sys, warnings
warnings.simplefilter("ignore")  # a negative serial is read with a warning
from cryptography import x509
def names(n):
    return "|".join(f"{a.oid.dotted_string}={a.value}" for a in n)
want = []
for f in sys.argv[2:]:
    c = x509.load_der_x509_certificate(open(f, "rb").read())
    s = c.serial_number
    want.append("\t".join([os.path.basename(f), "negative" if s < 0 else format(s, "x"),
                           c.signature_algorithm_oid.dotted_string,
                           str(int(c.not_valid_before_utc.timestamp())), str(int(c.not_valid_after_utc.timestamp())),
                           names(c.subject), names(c.issuer)]))
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
bad = [(w, g) for w, g in zip(want, got) if w != g]
if len(want) != len(got):
    bad.append((f"{len(want)} lines", f"{len(got)} lines"))
if bad:
    print(f"  {len(bad)} of {len(want)} certificates read differently:")
    for w, g in bad[:4]:
        print(f"    python {w[:150]!r}\n    iyi    {g[:150]!r}")
    sys.exit(1)
print(f"  {len(want)} certificates: serial, signature algorithm, validity and every name attribute as cryptography reads them")
PY
  then
    status=1
  fi
fi

echo
echo "== certificates broken at random, read without a panic"
# Bytes flipped, cut and inserted, 4,000 times over: each is read, walked
# and every primitive decoded by its tag, and the answer is a value or an
# Asn1Error, never a panic, an index past the bytes or a hang.
if [ "$CERTS" -eq 0 ]; then
  echo "  no certificates here, so nothing to break"
else
  "$PY" - "$WORK/der" "$WORK/broken.txt" <<'PY'
import glob, random, sys
rng = random.Random(1690)
certs = [open(f, "rb").read() for f in sorted(glob.glob(sys.argv[1] + "/*.der"))]
with open(sys.argv[2], "w") as out:
    for _ in range(4000):
        b = bytearray(rng.choice(certs))
        for _ in range(rng.randint(1, 4)):
            kind = rng.randrange(4)
            at = rng.randrange(len(b))
            if kind == 0:
                b[at] = rng.randrange(256)
            elif kind == 1:
                b[at] ^= 1 << rng.randrange(8)
            elif kind == 2:
                del b[at:at + rng.randint(1, 16)]
            else:
                b[at:at] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 4)))
            if not b:
                b = bytearray(b"\x30")
        out.write(b.hex() + "\n")
PY
  if out="$(timeout 300 "$WORK/asn1-release" robust "$WORK/broken.txt" 2>&1)"; then
    echo "  $out"
  else
    echo "  the broken certificates were not all read: $(printf '%s' "$out" | tail -3)"
    status=1
  fi
fi

echo
echo "== an error value's sentence, through .or_panic"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/asn1::{Der}

case Program.args[0]
when "indefinite"
  Der.parse([0x30_u8, 0x80_u8, 0_u8, 0_u8]).or_panic
when "integer"
  Der.parse([2_u8, 2_u8, 0_u8, 1_u8]).or_panic.integer.or_panic
when "time"
  Der.parse([0x17_u8, 3_u8, 0x34_u8, 0x39_u8, 0x5A_u8]).or_panic.time.or_panic
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
refuse indefinite "asn1: an indefinite length, which is BER's and not DER's at offset 1"
refuse integer "asn1: an INTEGER with a redundant leading byte at offset 2"
refuse time "asn1: a UTCTime of 3 bytes, where DER writes YYMMDDHHMMSSZ at offset 0"

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
src = Path("$REPO/src/std/asn1.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/asn1.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_asn1_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "an indefinite length read as empty" "an indefinite length refused" \
  '      return Asn1Error.new("an indefinite length, which is BER'"'"'s and not DER'"'"'s", at - 1)' '      size = 0'
prove_broken "a short length taken in the long form" "a short length in the long form refused" \
  'if long < 128' 'if false'
prove_broken "a length's leading zero taken" "a length with a leading zero refused" \
  '      return Asn1Error.new("a length with a leading zero byte", at) if data[at] == 0_u8' ''
prove_broken "a low tag number taken in the high form" "a low tag number in the high form refused" \
  '      return Asn1Error.new("a tag number of #{tag} written in the high form", start) if tag < 0x1F' ''
prove_broken "bytes after the value taken" "bytes after the value refused" \
  'if value.end_offset != bytes.size' 'if false'
prove_broken "a constructed INTEGER taken" "a constructed INTEGER refused" \
  'if constructed && tag != DerTag::SEQUENCE && tag != DerTag::SET' 'if false'
prove_broken "a redundant INTEGER byte taken" "a redundant 0x00 refused" \
  'if (first == 0x00_u8 && second < 0x80_u8) || (first == 0xFF_u8 && second >= 0x80_u8)' 'if false'
# An ENUMERATED taken for an INTEGER: the shape that let an ECDSA signature
# with r or s tagged 0x0a verify.
prove_broken "an ENUMERATED read as an INTEGER" "an ENUMERATED asked as an INTEGER refused" \
  'unless universal?(DerTag::INTEGER)' 'unless universal?(DerTag::INTEGER) || universal?(DerTag::ENUMERATED)'
prove_broken "a subidentifier's leading 0x80 taken" "a subidentifier with a leading 0x80 refused" \
  '      return Asn1Error.new("a subidentifier with a leading 0x80 byte", at) if @data[at] == 0x80_u8' ''
prove_broken "a set unused bit taken" "an unused bit set refused" \
  'if unused > 0 && last & ((1_u8 << unused) - 1_u8) != 0_u8' 'if false'
prove_broken "any non-zero byte read as TRUE" "a BOOLEAN of 0x01 refused" \
  'return true if byte == 0xFF_u8' 'return true if byte != 0x00_u8'
prove_broken "UTCTime's century turning at 49" "UTCTime 49 is 2049" \
  'year = yy >= 50 ? 1900 + yy : 2000 + yy' 'year = yy >= 49 ? 1900 + yy : 2000 + yy'
# std/time's `Time.utc` panics on a day the month does not have, so without
# this module's own check the refusal becomes that panic instead of a value.
prove_broken "a day past the month's taken" "invalid day: 29 for year 2023 month 2" \
  'unless day >= 1 && day <= days' 'unless day >= 1 && day <= 31'
prove_broken "a fraction's scale dropped" "a fraction of a second" \
  '        (9 - count).times { nanos = nanos * 10 }' ''
prove_broken "a fraction ending in 0 taken" "a fraction ending in 0 refused" \
  '        return Asn1Error.new("a GeneralizedTime fraction that ends in 0", end_offset - 2) if @data[end_offset - 2] == '"'"'0'"'"'.ord.to_u8' ''
prove_broken "a PrintableString that takes anything" "a * in a PrintableString refused" \
  '{ |b| DerText.printable?(b) }' '{ |b| true }'
prove_broken "an overlong UTF-8 lead taken" "an overlong form refused" \
  'if b >= 0xC2_u8 && b <= 0xDF_u8' 'if b >= 0xC0_u8 && b <= 0xDF_u8'
prove_broken "the walk without its depth bound" "a value 65 deep refused" \
  '      return Asn1Error.new("a value nested deeper than #{MAX_DEPTH}", current.offset) if depth > MAX_DEPTH' ''
prove_broken "the first two arcs split at 39" "sha256WithRSAEncryption" \
  'head = first < 40 ? "0.#{first}" : (first < 80 ? "1.#{first - 40}" : "2.#{first - 80}")' \
  'head = first < 39 ? "0.#{first}" : (first < 79 ? "1.#{first - 39}" : "2.#{first - 79}")'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/asn1 exercise holds ($mutations breaks caught)"
else
  echo "the std/asn1 exercise did not hold"
fi
exit $status
