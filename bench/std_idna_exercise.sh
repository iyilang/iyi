#!/usr/bin/env bash
# Exercises `std/idna`: Punycode (RFC 3492) and host names to and from
# their ASCII form (IDNA2008), against Python's `punycode` and `idna`
# codecs and the `idna` package where they are installed.
#
#     bash bench/std_idna_exercise.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The oracles and the negative proofs are python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
export PYTHONIOENCODING=utf-8

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_idna_exercise.iyi" \
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

echo "== the std/idna exercise, plain build"
build_and_run "plain" idna-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/idna-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every idna section reported"
for phrase in "== punycode rfc 3492 samples" "== punycode refusals" "== punycode round trips" "== to_ascii" \
              "== to_unicode" "== labels refused" "== lengths" "== context rules" "== property"; do
  if ! grep -q "$phrase" "$WORK/idna-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" idna-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/idna-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

# The oracles write an iyi program of their cases, run it, and read what it
# printed against Python's answers. Every string is written to the program
# as escapes, so neither side's source encoding is in question.
LIT_HELPER='
def lit(s):
    out = []
    for ch in s:
        o = ord(ch)
        if 32 <= o < 127 and ch not in "\"\\#":
            out.append(ch)
        else:
            out.append("\\u{%X}" % o)
    return "\"" + "".join(out) + "\""
'

echo
echo "== punycode against python's codec"
# 300 random strings over ASCII, Latin, CJK and the astral planes, every
# label of the name corpus below, and a delta past 32 bits: iyi encodes
# each, and decodes Python's encoding of each.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so Punycode goes uncompared"
else
  LIT_HELPER="$LIT_HELPER" "$PY" - "$WORK" <<'PY'
import os, random, sys
exec(os.environ["LIT_HELPER"])
work = sys.argv[1]
rng = random.Random(20261015)
def point():
    r = rng.randrange(4)
    if r == 0: return rng.randrange(32, 127)
    if r == 1: return rng.randrange(0xA0, 0x5A0)
    if r == 2: return rng.randrange(0x4E00, 0x9E00)
    while True:
        p = rng.randrange(0x10000, 0x110000)
        if p & 0xFFFE != 0xFFFE: return p
cases = ["".join(chr(point()) for _ in range(rng.randrange(0, 50))) for _ in range(300)]
cases += ["bücher", "münchen", "例え", "テスト", "пример", "испытание", "παράδειγμα", "مثال", "उदाहरण", "실례", "faß", "a" * 3000 + "\U0010FFFF"]
# Decoded strings come back as hex, so a code point is compared as bytes.
lines = ["module puny_cases", "", "import std/idna::{Punycode, PunycodeError}", "", """
def hex_of(text : String) : String
  digits = "0123456789abcdef"
  String.build do |io|
    i = 0
    while i < text.bytesize
      b = text.to_unsafe[i].to_i32
      io << digits[b >> 4]
      io << digits[b & 15]
      i = i + 1
    end
  end
end
"""]
for s in cases:
    enc = s.encode("punycode").decode("ascii")
    lines.append(f"puts Punycode.encode({lit(s)})")
    lines.append(f"d = Punycode.decode({lit(enc)})")
    lines.append('puts d.is_a?(PunycodeError) ? "refused: #{d.message}" : hex_of(d)')
open(os.path.join(work, "puny_cases.iyi"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
open(os.path.join(work, "puny_expected.txt"), "w", encoding="utf-8").write(
    "\n".join(f"{s.encode('punycode').decode('ascii')}\n{s.encode('utf-8').hex()}" for s in cases) + "\n")
PY
  if ! "$IYI" run "$WORK/puny_cases.iyi" >"$WORK/puny_got.txt" 2>&1; then
    echo "  the Punycode cases did not run: $(tail -1 "$WORK/puny_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
got = open(os.path.join(work, "puny_got.txt"), encoding="utf-8").read().splitlines()
want = open(os.path.join(work, "puny_expected.txt"), encoding="utf-8").read().splitlines()
bad = [(i, w, g) for i, (w, g) in enumerate(zip(want, got + [""] * len(want))) if w != g]
for i, w, g in bad[:10]:
    print(f"  case {i // 2} {'encode' if i % 2 == 0 else 'decode'}: python {w[:60]!r}, iyi {g[:60]!r}")
print(f"  {len(want) // 2 - len({i // 2 for i, _, _ in bad})} of {len(want) // 2} strings encode as python's codec does and decode from it")
sys.exit(1 if bad or len(got) != len(want) else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== names against python's idna codec and the idna package"
# A corpus of real internationalized names: IANA's IDN test domains,
# country-code IDN TLDs and names in use. Each goes through to_ascii and
# its ASCII form back through to_unicode. The idna package (IDNA2008, the
# rules this module follows) must give the same answers; Python's built-in
# `idna` codec (IDNA2003) must too, but for ß, which it maps to `ss`, and
# that difference is checked as the one expected. The refused names must
# be refused by the idna package too; the names on which this module and
# the idna package are known to differ - an underscore label, which this
# module passes through; a right-to-left label the Bidi rule refuses,
# which this module does not check; ZWNJ in Persian, which the CONTEXTJ
# rule allows and this module refuses - are checked to differ just so.
if [ -z "$PY" ] || ! "$PY" -c 'import idna' >/dev/null 2>&1; then
  echo "  the idna package is not installed here, so names go uncompared with IDNA2008"
else
  LIT_HELPER="$LIT_HELPER" "$PY" - "$WORK" <<'PY'
import os, sys, json
exec(os.environ["LIT_HELPER"])
work = sys.argv[1]
good = [
    "bücher.example", "münchen.de", "köln.de", "zürich.ch", "café.fr", "naïve.example", "øl.no", "ålesund.no",
    "español.com", "ñandú.com.ar", "türkiye.com", "例え.テスト", "例子.测试", "例子.測試", "日本語.jp", "中国.cn",
    "台灣.tw", "香港.hk", "ドメイン名例.jp", "пример.испытание", "правительство.рф", "россия.рф", "укр.ua",
    "срб.rs", "мон.mn", "қазақстан.kz", "παράδειγμα.δοκιμή", "ελληνικά.gr", "ευ.eu", "مثال.إختبار", "مصر.eg",
    "عربي.com", "ایران.ir", "בײַשפּיל.טעסט", "उदाहरण.परीक्षा", "भारत.in", "বাংলা.bd", "ලංකා.lk",
    "உதாரணம்.பரிட்சை", "சிங்கப்பூர்.sg", "실례.테스트", "한국.kr", "ไทย.ไทย", "հայ.am", "გე.ge",
    "straße.de", "col·lecció.cat", "WWW.Bücher.Example", "a.bücher.example.", "例え。テスト",
]
refused = [
    "", ".", "a..b", "-a.com", "a-.com", "ab--c.com", "a b.com", "xn--abc-.com", "xn--a-9.com", "bÜcher.de",
    "ｅｘａｍｐｌｅ.com", "ﬁ.example", "☃.net", "xn--n3h.net", "u\u0308.de", "\u0301a.de", "a·b.cat", "a͵.gr",
    "a׳.il", "a・b.jp", "ب٠۱.eg", "\u0378.com", "a" * 64 + ".com", ".".join(["a" * 63] * 3 + ["a" * 62]),
    "a" * 60 + "ü.de", ".".join(["ü"] * 50), "a\u200db.de", "ⅷ.com",
]
# name, what this module answers ("refused" or the ASCII form), what the
# idna package answers, and why they differ.
differ = [
    ("_dmarc.example.com", "_dmarc.example.com", "refused", "an underscore label passes through here"),
    ("0א.il", "xn--0-0hc.il", "refused", "the Bidi rule of RFC 5893 is not checked here"),
    ("می\u200cخواهم.ir", "refused", "xn--mgbn2ecje63gr19l.ir", "ZWNJ's CONTEXTJ rule is not checked here, so ZWNJ is refused"),
]
def ascii_lower(s):
    return "".join(c.lower() if "A" <= c <= "Z" else c for c in s)
lines = ["module name_cases", "", "import std/idna::{IDNA, IdnaError}", ""]
names = good + refused + [d[0] for d in differ]
for n in names:
    lines.append(f"a = IDNA.to_ascii({lit(n)})")
    lines.append('puts a.is_a?(IdnaError) ? "refused" : a')
    lines.append(f"u = IDNA.to_unicode(a.is_a?(IdnaError) ? {lit(n)} : a)")
    lines.append('puts u.is_a?(IdnaError) ? "refused" : u')
open(os.path.join(work, "name_cases.iyi"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
json.dump({"good": good, "refused": refused, "differ": differ}, open(os.path.join(work, "names.json"), "w", encoding="utf-8"))
PY
  if ! "$IYI" run "$WORK/name_cases.iyi" >"$WORK/name_got.txt" 2>&1; then
    echo "  the name cases did not run: $(tail -1 "$WORK/name_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import idna, json, os, sys
work = sys.argv[1]
cases = json.load(open(os.path.join(work, "names.json"), encoding="utf-8"))
got = open(os.path.join(work, "name_got.txt"), encoding="utf-8").read().splitlines()
pairs = [(got[i], got[i + 1]) for i in range(0, len(got) - 1, 2)]
bad = 0
def ascii_lower(s):
    return "".join(c.lower() if "A" <= c <= "Z" else c for c in s)
def package(name):
    try:
        return idna.encode(ascii_lower(name)).decode("ascii")
    except idna.IDNAError:
        return "refused"
def package_back(name):
    try:
        return idna.decode(name)
    except idna.IDNAError:
        return "refused"
def codec(name):
    try:
        return name.lower().encode("idna").decode("ascii")
    except UnicodeError:
        return "refused"
names = cases["good"] + cases["refused"] + [d[0] for d in cases["differ"]]
if len(pairs) != len(names):
    print(f"  {len(pairs)} answers came back for {len(names)} names"); sys.exit(1)
answers = dict(zip(names, pairs))
codec_same = 0
for n in cases["good"]:
    a, u = answers[n]
    want = package(n)
    if a != want:
        print(f"  {n!r}: idna package {want!r}, iyi {a!r}"); bad += 1; continue
    back = package_back(want)
    if u != back:
        print(f"  {n!r} back from {want!r}: idna package {back!r}, iyi {u!r}"); bad += 1
    old = codec(n)
    if "ß" in n:
        if old == a or old != ascii_lower(n).replace("ß", "ss").replace("。", "."):
            print(f"  {n!r}: python's IDNA2003 codec answered {old!r}, not the ss it was expected to"); bad += 1
    elif old != a:
        print(f"  {n!r}: python's idna codec {old!r}, iyi {a!r}"); bad += 1
    else:
        codec_same += 1
for n in cases["refused"]:
    a, u = answers[n]
    if a != "refused" or u != "refused" or package(n) != "refused":
        print(f"  {n!r}: iyi {a!r} and {u!r}, idna package {package(n)!r}; both should refuse"); bad += 1
for n, mine, theirs, why in cases["differ"]:
    a, _ = answers[n]
    if a != mine or package(n) != theirs:
        print(f"  {n!r} ({why}): iyi {a!r}, idna package {package(n)!r}; expected {mine!r} and {theirs!r}"); bad += 1
print(f"  {len(cases['good'])} names agree with the idna package both ways, {codec_same} with python's IDNA2003 codec too "
      f"(ß is ss there); {len(cases['refused'])} refused by both; {len(cases['differ'])} known differences hold as documented")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== the rfc 5892 property of every code point against the idna package"
# IDNA.property derives RFC 5892's property from std/unicode; the idna
# package carries it as tables. Compared over every code point Python's
# Unicode (16.0) assigns. One known disagreement: OUTLINED DIGIT ZERO to
# NINE (U+1CCF0..U+1CCF9, new in 16.0) are PVALID in the idna package's
# table, but their NFKC is the ASCII digit, which makes them Unstable and
# DISALLOWED by RFC 5892 section 2.3 - the package's own UTS #46 table maps
# them to the digits.
if [ -z "$PY" ] || ! "$PY" -c 'import idna.idnadata' >/dev/null 2>&1; then
  echo "  the idna package is not installed here, so the property goes uncompared"
else
  cat >"$WORK/prop.iyi" <<'IYI'
module prop

import std/idna::{IDNA, IdnaProperty}

start = 0
current = IDNA.property(0.unsafe_chr)
cp = 1
while cp <= 0x110000
  p = cp == 0x110000 || (cp >= 0xD800 && cp <= 0xDFFF) ? IdnaProperty::Disallowed : IDNA.property(cp.unsafe_chr)
  if p != current || cp == 0x110000
    puts "#{start} #{cp - 1} #{current}"
    start = cp
    current = p
  end
  cp = cp + 1
end
IYI
  if ! "$IYI" build --release -o "$WORK/prop" "$WORK/prop.iyi" >"$WORK/prop.build.log" 2>&1 || ! "$WORK/prop" >"$WORK/prop.txt" 2>&1; then
    echo "  the property table did not build or run: $(tail -1 "$WORK/prop.build.log" "$WORK/prop.txt" 2>/dev/null | tail -1)"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys, unicodedata
import idna.idnadata as data
from idna.intranges import intranges_contain
work = sys.argv[1]
def package(cp):
    for name in ("PVALID", "CONTEXTJ", "CONTEXTO"):
        if intranges_contain(cp, data.codepoint_classes[name]):
            return name
    return "OTHER"
ours = {"PValid": "PVALID", "ContextJ": "CONTEXTJ", "ContextO": "CONTEXTO", "Disallowed": "OTHER", "Unassigned": "OTHER"}
known = set(range(0x1CCF0, 0x1CCFA))
compared = 0
differ = []
for line in open(os.path.join(work, "prop.txt")):
    lo, hi, prop = line.split()
    for cp in range(int(lo), int(hi) + 1):
        if unicodedata.category(chr(cp)) == "Cn":
            continue
        compared += 1
        if ours[prop] != package(cp):
            differ.append((cp, prop, package(cp)))
unexpected = [d for d in differ if d[0] not in known]
for cp, mine, theirs in unexpected[:20]:
    print(f"  U+{cp:04X} {unicodedata.name(chr(cp), '?')}: iyi {mine}, idna package {theirs}")
if {d[0] for d in differ} != known:
    print(f"  the outlined digits were expected to differ, and {len(differ) - len(unexpected)} of 10 did")
print(f"  {compared} assigned code points compared (Unicode {unicodedata.unidata_version}); {compared - len(differ)} agree, "
      f"and the {len(differ) - len(unexpected)} that differ are the outlined digits")
sys.exit(1 if unexpected or {d[0] for d in differ} != known else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== what idna refuses"
# An error value passed to `.or_panic` panics with its sentence.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/idna::{Punycode, IDNA}

case Program.args[0]
when "punycode-overflow"
  Punycode.decode("99999999999999999999").or_panic
when "punycode-digit"
  Punycode.decode("abc-d!e").or_panic
when "punycode-surrogate"
  Punycode.decode("ib9b").or_panic
when "label-too-long"
  IDNA.to_ascii("a" * 64 + ".com").or_panic
when "name-too-long"
  IDNA.to_ascii((["a" * 63] * 4).join(".")).or_panic
when "hyphens"
  IDNA.to_ascii("ab--cd.example").or_panic
when "uppercase"
  IDNA.to_unicode("MÜNCHEN.de").or_panic
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
refuse punycode-overflow "Punycode: the number at byte 17 overflows"
refuse punycode-digit "Punycode: '!' at byte 5 is not a base-36 digit"
refuse punycode-surrogate "Punycode: the number ending at byte 3 is U+D800, a surrogate, which UTF-8 does not hold"
refuse label-too-long "IDNA: label \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" is 64 octets, past the 63 a DNS label holds"
refuse name-too-long "IDNA: the name is 255 octets in ASCII, past the 253 a DNS name holds"
refuse hyphens "IDNA: label \"ab--cd\" has \"--\" at its third and fourth characters and is not an A-label"
refuse uppercase "IDNA: label \"MÜNCHEN\" holds U+00DC, which IDNA2008 does not allow; case folding and NFKC make it \"ü\", which UTS #46 would map it to and this module does not"

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
src = Path("$REPO/src/std/idna.iyi").read_text(encoding="utf-8")
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/idna.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_idna_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a bias that never damps its first delta" "rfc 3492 sample A encodes" \
  'delta = first ? delta // DAMP : delta // 2_i64' 'delta = delta // 2_i64'
prove_broken "tmax at 27 rather than 26" "rfc 3492 sample A encodes" \
  'TMAX         =  26_i64' 'TMAX         =  27_i64'
# Bounded at 32 bits, the twenty 9s overflow ten bytes sooner.
prove_broken "a 32-bit decoder" "ASSERTION FAILED: overflow" \
  'MAXINT = 0x7FFFFFFFFFFFFFFF_i64' 'MAXINT = 0x7FFFFFFF_i64'
prove_broken "a decoder that lets a surrogate through" "a surrogate" \
  'if n >= 0xD800_i64 && n <= 0xDFFF_i64' 'if false'
prove_broken "an A-label taken when it decodes to ASCII" "a fake A-label" \
  '        if ascii?(decoded)' '        if false'
prove_broken "-- allowed at the third and fourth characters" "-- at three and four" \
  "if chars.size >= 4 && chars[2] == '-' && chars[3] == '-'" 'if false'
prove_broken "upper case taken as it is" "upper case is not mapped" \
  '    return IdnaProperty::Disallowed if unstable(char)' ''
prove_broken "ß without its exception" "ß is itself, not ss" \
  'when 0x00DF, 0x03C2,' 'when 0x03C2,'
prove_broken "a label NFC does not change unchecked" "not NFC" \
  '    unless Unicode.normalized?(label)' '    unless true'
prove_broken "a middle dot taken anywhere" "a middle dot elsewhere" \
  "i > 0 && i + 1 < chars.size && chars[i - 1] == 'l' && chars[i + 1] == 'l'" 'true'
prove_broken "labels of 64 octets" "a 64-octet label" \
  'MAX_LABEL =  63' 'MAX_LABEL =  64'
prove_broken "the ideographic full stop not a separator" "an ideographic full stop separates labels" \
  'cp == 0x2E || cp == 0x3002 ||' 'cp == 0x2E ||'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/idna exercise holds"
else
  echo "the std/idna exercise did not hold"
fi
exit $status
