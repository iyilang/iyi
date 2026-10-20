#!/usr/bin/env bash
# Holds what std/asn1, std/x509, std/tls, std/http and std/hpack read from
# a peer to their policy on malformed input: an error value, never a
# panic, in bounded time and memory.
#
#     bash bench/std_fuzz_exercise.sh
#     FUZZ_ITERATIONS=60000 bash bench/std_fuzz_exercise.sh
#
# bench/std_fuzz_exercise.iyi makes its inputs from seeds - certificates,
# PEM, recorded TLS handshakes, HTTP/1.1 heads, HTTP/2 frames, HPACK
# blocks - mutated by a seeded generator, so every run reads the same
# ones; its header says what each target covers and what the long runs
# found. FUZZ_ITERATIONS is the inputs of each pure target (a connection
# target takes a quarter as many); the default keeps the gate near three
# minutes on CI. The gate runs the regression inputs, the connection
# targets' seeds unmutated, and every target; sets x509's accept and
# refuse decisions beside Python's cryptography's and HPACK's decoding
# beside Python's hpack where they are installed, saying so where they
# are not - each disagreement is reported by kind, to be judged against
# the RFC, not failed on; and proves on broken copies of each module
# that its regression input catches the fix undone.
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
# patched copies are never read and the proofs quietly stop proving.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

# The oracles and the patches are python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

ITERATIONS="${FUZZ_ITERATIONS:-4000}"
case "$ITERATIONS" in
  '' | *[!0-9]*)
    echo "FUZZ_ITERATIONS is a count of inputs, not '$ITERATIONS'"
    exit 2
    ;;
esac
# The inputs each oracle compares: a pure target's first ones.
ORACLE="${FUZZ_ORACLE:-2000}"

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

echo "== the fuzz exercise, plain build, $ITERATIONS inputs a pure target"
if ! "$IYI" build -o "$WORK/fuzz" "$REPO/bench/std_fuzz_exercise.iyi" >"$WORK/build.log" 2>&1; then
  echo "  build failed"
  tail -12 "$WORK/build.log"
  exit 1
fi
# A panic a target answers inside its task is printed to stderr by the
# runtime as well; the verdicts on stdout are what is judged.
"$WORK/fuzz" all "$ITERATIONS" >"$WORK/all.out" 2>"$WORK/all.err"
code=$?
sed 's/^/  /' "$WORK/all.out"
if [ "$code" -ne 0 ]; then
  echo "  exited $code"
  tail -5 "$WORK/all.err" | sed 's/^/    /'
  status=1
fi
grep -q "ALL CHECKS PASSED" "$WORK/all.out" || { echo "  missing pass sentinel"; status=1; }
for phrase in "== the regression inputs" "== the connection targets' seeds, unmutated" "== every target:"; do
  grep -qF "$phrase" "$WORK/all.out" || { echo "  missing section: $phrase"; status=1; }
done
for target in der x509 pem keys record http1 hpack tls-server tls-client h1-server h2-server h1-client h2-client; do
  grep -q "^  $target: [0-9]* inputs" "$WORK/all.out" || { echo "  missing target: $target"; status=1; }
done

echo
echo "== x509's accept and refuse decisions against Python's cryptography"
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography import x509' >/dev/null 2>&1; then
  echo "  skipped: no python cryptography here, so the mutated certificates go uncompared"
else
  "$WORK/fuzz" corpus x509 0 "$ORACLE" >"$WORK/x509.corpus" 2>/dev/null
  "$PY" - "$WORK/x509.corpus" <<'PY' || status=1
import re
import warnings
import sys
from collections import Counter

from cryptography import x509

warnings.simplefilter("ignore")


def kind(sentence):
    return re.sub(r"[0-9]+", "#", sentence.split("\n")[0])[:110]


def theirs(der):
    try:
        cert = x509.load_der_x509_certificate(der)
        cert.subject
        cert.issuer
        cert.serial_number
        cert.not_valid_before_utc
        cert.not_valid_after_utc
        cert.signature_algorithm_oid
        cert.extensions
        cert.public_key()
        return None
    except Exception as e:
        return type(e).__name__ + ": " + str(e)


agree = 0
total = 0
ours_only = Counter()
theirs_only = Counter()
examples = {}
for line in open(sys.argv[1]):
    index, hexed, verdict = line.rstrip("\n").split("\t", 2)
    if verdict.startswith("PANIC: ") or verdict.startswith("PROPERTY: "):
        continue
    total += 1
    der = bytes.fromhex(hexed)
    ours = verdict[len("refused: "):] if verdict.startswith("refused: ") else None
    their = theirs(der)
    if (ours is None) == (their is None):
        agree += 1
    elif ours is None:
        k = "iyi reads, cryptography refuses: " + kind(their)
        theirs_only[k] += 1
        examples.setdefault(k, index)
    else:
        k = "iyi refuses, cryptography reads: " + kind(ours)
        ours_only[k] += 1
        examples.setdefault(k, index)
print(f"  {total} mutated certificates: {agree} judged alike, {sum(theirs_only.values())} read by iyi alone, {sum(ours_only.values())} by cryptography alone")
for k, n in (theirs_only + ours_only).most_common():
    print(f"    {n} x {k} (#{examples[k]})")
PY
fi

echo
echo "== HPACK decoding against Python's hpack"
if [ -z "$PY" ] || ! "$PY" -c 'import hpack' >/dev/null 2>&1; then
  echo "  skipped: no python hpack here, so the mutated header blocks go uncompared"
else
  "$WORK/fuzz" corpus hpack 0 "$ORACLE" >"$WORK/hpack.corpus" 2>/dev/null
  "$PY" - "$WORK/hpack.corpus" <<'PY' || status=1
import re
import sys
from collections import Counter

import hpack


def blocks(data):
    res = []
    at = 0
    while at + 2 <= len(data):
        n = (data[at] << 8) | data[at + 1]
        if at + 2 + n > len(data):
            break
        res.append(data[at + 2:at + 2 + n])
        at += 2 + n
    if at < len(data):
        res.append(data[at:])
    return res


def theirs(data):
    decoder = hpack.Decoder()
    res = ""
    for block in blocks(data):
        try:
            fields = decoder.decode(block, raw=True)
        except Exception as e:
            return res + "refused: " + type(e).__name__ + ": " + str(e)
        res += "[" + ";".join(n.hex() + ":" + v.hex() + ("!" if isinstance(f, hpack.NeverIndexedHeaderTuple) else "") for f in fields for n, v in [f]) + "]"
    return res


def kind(sentence):
    return re.sub(r"[0-9]+", "#", sentence)[:110]


agree = 0
total = 0
apart = Counter()
examples = {}
for line in open(sys.argv[1]):
    index, hexed, ours = line.rstrip("\n").split("\t", 2)
    total += 1
    their = theirs(bytes.fromhex(hexed))
    if ours == their:
        agree += 1
        continue
    cut_ours = ours.find("refused: ")
    cut_theirs = their.find("refused: ")
    if cut_ours >= 0 and cut_theirs >= 0 and ours[:cut_ours] == their[:cut_theirs]:
        agree += 1
        continue
    if cut_ours >= 0 and (cut_theirs < 0 or cut_theirs > cut_ours):
        k = "iyi refuses where hpack reads: " + kind(ours[cut_ours + 9:])
    elif cut_theirs >= 0 and (cut_ours < 0 or cut_ours > cut_theirs):
        k = "hpack refuses where iyi reads: " + kind(their[cut_theirs + 9:])
    else:
        k = "both read, the fields differ"
    apart[k] += 1
    examples.setdefault(k, index)
print(f"  {total} mutated HPACK streams: {agree} decoded alike, {sum(apart.values())} apart")
for k, n in apart.most_common():
    print(f"    {n} x {k} (#{examples[k]})")
PY
fi

echo
echo "== each fix undone in a copy of its module, caught by its regression input"
# fix_proof <label> <module> <phrase> <old> <new>: the module's copy with
# <old> written back as <new>, which the regression inputs must fail on
# with <phrase> in what they say.
fix_proof() {
  local label="$1" module="$2" phrase="$3" old="$4" new="$5"
  local name="undo$((++proofs))"
  if [ -z "$PY" ]; then
    echo "  skipped: no working python3, so $label is unproven"
    return
  fi
  mkdir -p "$WORK/$name/std"
  if ! "$PY" - "$REPO/src/std/$module.iyi" "$WORK/$name/std/$module.iyi" "$old" "$new" <<'PY'; then
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
if sys.argv[3] not in src:
    raise SystemExit("patch site missing: " + sys.argv[3])
Path(sys.argv[2]).write_text(src.replace(sys.argv[3], sys.argv[4], 1))
PY
    echo "  the patch for $label did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$name.bin" "$REPO/bench/std_fuzz_exercise.iyi" >"$WORK/$name.out" 2>&1; then
    echo "  the copy with $label did not build"
    tail -3 "$WORK/$name.out" | sed 's/^/    /'
    status=1
  elif "$WORK/$name.bin" regressions >"$WORK/$name.out" 2>&1; then
    echo "  the regressions PASSED with $label"
    status=1
  elif grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label is caught"
  else
    echo "  $label failed, but not at '$phrase':"
    tail -3 "$WORK/$name.out" | sed 's/^/    /'
    status=1
  fi
}
proofs=0
# The fix in std/asn1: a UniversalString's code built in Int32 again.
fix_proof "a UniversalString's code read in Int32" asn1 "out of char range" \
  '        code = 0_i64
        width.times { |k| code = (code << 8) | @data[i + k].to_i64 }' \
  '        code = 0
        width.times { |k| code = (code << 8) | @data[i + k].to_i32 }'
# The fix in std/http: a peer's boundary of any length handed to Multipart.new.
fix_proof "a multipart boundary of any length" http "a multipart boundary is 1 to 70 characters" \
  '    return nil unless found && found.bytesize >= 1 && found.bytesize <= 70' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the fuzz exercise holds"
else
  echo "the fuzz exercise did not hold"
fi
exit $status
