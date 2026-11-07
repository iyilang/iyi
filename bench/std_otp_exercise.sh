#!/usr/bin/env bash
# Exercises `std/otp`.
#
#     bash bench/std_otp_exercise.sh
#
# The exercise holds RFC 4226's appendix D, RFC 6238's appendix B under
# all three hashes, the verify window, the clock, and key URIs against
# hand-written strings; this gate runs it plain and --release, holds the
# codes and `verify` to an HOTP written here in Python on `hmac` and
# `hashlib` over random secrets, counters, times, steps and digits, has
# Python's `urllib.parse` read the URIs this writes and this read the ones
# Python writes, names what is refused with its sentence, and proves on
# broken copies of the module that the checks fail where they say.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_otp_exercise.iyi" \
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

echo "== the std/otp exercise, plain build"
build_and_run "plain" otp-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/otp-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every otp section reported"
for phrase in "== HOTP, RFC 4226 appendix D" "== TOTP, RFC 6238 appendix B" "== verify" "== the clock" "== otpauth URIs"; do
  if ! grep -q "$phrase" "$WORK/otp-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" otp-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/otp-release.out" 2>/dev/null; then
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
echo "== an HOTP written on python's hmac agrees"
# 400 codes: secrets of 1 to 64 random bytes, the three hashes, 6 to 10
# digits, HOTP at counters anywhere in 0 to 2^63 - 1 and TOTP at times to
# 2^40 seconds with steps of 30, 60 or 1 to 600; then 300 verifications,
# the code sent being the one for a step up to three either side or a
# made-up one, against windows of 0 to 3.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the codes go uncompared"
else
  HELPERS="$HELPERS" "$PY" - "$WORK" <<'PY'
import hashlib, hmac, os, random, struct, sys
work = sys.argv[1]
rng = random.Random(6238)
hashes = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}

def hotp(key, counter, digits, name):
    mac = hmac.new(key, struct.pack(">Q", counter), hashes[name]).digest()
    offset = mac[-1] & 0x0F
    number = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(number % 10 ** digits).zfill(digits)

lines = ["module code_cases", "", "import std/otp::{HOTP, TOTP, OTPAlgorithm}", "", os.environ["HELPERS"]]
expected = []
for i in range(400):
    key = bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 64)))
    name = rng.choice(list(hashes))
    digits = rng.randint(6, 10)
    if i % 2 == 0:
        counter = rng.choice([rng.randint(0, 1000), rng.getrandbits(32), rng.getrandbits(63)])
        lines.append(f'puts HOTP.code(b("{key.hex()}"), {counter}_i64, {digits}, OTPAlgorithm::{name})')
        expected.append(f"{hotp(key, counter, digits, name)}\tHOTP {name} counter {counter} digits {digits}")
    else:
        t = rng.randint(0, 2 ** 40)
        step = rng.choice([30, 60, rng.randint(1, 600)])
        lines.append(f'puts TOTP.code(b("{key.hex()}"), {t}_i64, {step}, {digits}, OTPAlgorithm::{name})')
        expected.append(f"{hotp(key, t // step, digits, name)}\tTOTP {name} time {t} step {step} digits {digits}")
for _ in range(300):
    key = bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 64)))
    name = rng.choice(list(hashes))
    digits = rng.choice([6, 8])
    step = rng.choice([30, 60])
    t = rng.randint(0, 2 ** 34)
    window = rng.randint(0, 3)
    off = rng.randint(-3, 3)
    if rng.random() < 0.2 or t // step + off < 0:
        code = str(rng.randint(0, 10 ** digits - 1)).zfill(digits)
    else:
        code = hotp(key, t // step + off, digits, name)
    accepted = any(hotp(key, t // step + k, digits, name) == code for k in range(-window, window + 1) if t // step + k >= 0)
    lines.append(f'puts TOTP.verify(b("{key.hex()}"), "{code}", {t}_i64, {window}, {step}, {digits}, OTPAlgorithm::{name})')
    expected.append(f"{'true' if accepted else 'false'}\tverify {name} time {t} step {step} window {window} code {code}")
open(os.path.join(work, "code_cases.iyi"), "w").write("\n".join(lines) + "\n")
open(os.path.join(work, "code_expected.txt"), "w").write("\n".join(expected) + "\n")
PY
  if ! "$IYI" run "$WORK/code_cases.iyi" >"$WORK/code_got.txt" 2>&1; then
    echo "  the cases did not run: $(tail -1 "$WORK/code_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
got = open(os.path.join(work, "code_got.txt")).read().splitlines()
want = [line.split("\t", 1) for line in open(os.path.join(work, "code_expected.txt")).read().splitlines()]
bad = [(w, g) for w, g in zip(want, got + [""] * len(want)) if w[0] != g]
for w, g in bad[:8]:
    print(f"  {w[1]}: python {w[0]}, iyi {g}")
accepted = sum(1 for w in want if w[0] == "true")
print(f"  {len(want) - len(bad)} of {len(want)} agree: 400 codes and 300 verifications ({accepted} accepted)")
sys.exit(1 if bad else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== python's urllib.parse reads the key URIs this writes, and this reads python's"
# 150 URIs written here, of random issuers and accounts drawn from
# letters, spaces, `@ + & = % / ? #`, accented letters, CJK and an emoji,
# read by `urlsplit`, `unquote` and `parse_qs` and held to what was given;
# then 150 URIs Python writes itself (`quote` on the label and
# `urlencode` on the parameters, so a space in a value is `+`), read here
# and held to what Python put in.
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the URIs go uncompared"
else
  HELPERS="$HELPERS" "$PY" - "$WORK" <<'PY'
import base64, os, random, sys, urllib.parse
work = sys.argv[1]
rng = random.Random(4226)
pool = list("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 @+&=%/?#.-_~") + ["é", "ü", "中", "文", "😀"]
def text():
    return "".join(rng.choice(pool) for _ in range(rng.randint(1, 12))).strip() or "x"
def literal(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("#", "\\#")
algorithms = ["SHA1", "SHA256", "SHA512"]
lines = ["module uri_cases", "", "import std/otp::{OTPAuth, OTPAlgorithm, OTPError}", "", os.environ["HELPERS"]]
written = []
for i in range(150):
    key = bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 40)))
    account = text()
    issuer = text() if i % 3 else ""
    name = rng.choice(algorithms)
    digits = rng.randint(6, 10)
    if i % 4 == 0:
        counter = rng.getrandbits(40)
        lines.append(f'puts OTPAuth.hotp(b("{key.hex()}"), "{literal(account)}", {counter}_i64, "{literal(issuer)}", OTPAlgorithm::{name}, {digits}).to_s')
        written.append(dict(type="hotp", key=key.hex(), account=account, issuer=issuer, algorithm=name, digits=digits, counter=counter))
    else:
        period = rng.choice([30, 60, rng.randint(1, 300)])
        lines.append(f'puts OTPAuth.totp(b("{key.hex()}"), "{literal(account)}", "{literal(issuer)}", OTPAlgorithm::{name}, {digits}, {period}).to_s')
        written.append(dict(type="totp", key=key.hex(), account=account, issuer=issuer, algorithm=name, digits=digits, period=period))
lines.append('puts "--"')
read = []
for i in range(150):
    key = bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 40)))
    account = text()
    issuer = text() if i % 3 else None
    name = rng.choice(algorithms)
    digits = rng.choice([6, 8])
    kind = "hotp" if i % 4 == 0 else "totp"
    label = urllib.parse.quote(account)
    args = {"secret": base64.b32encode(key).decode().rstrip("=")}
    if issuer is not None:
        label = urllib.parse.quote(issuer) + ":" + label
        args["issuer"] = issuer
    if kind == "hotp":
        args["counter"] = rng.getrandbits(40)
    if name != "SHA1":
        args["algorithm"] = name
    if digits != 6:
        args["digits"] = digits
    if kind == "totp":
        period = rng.choice([30, 45])
        if period != 30:
            args["period"] = period
    uri = f"otpauth://{kind}/{label}?{urllib.parse.urlencode(args)}"
    lines.append(f'p = OTPAuth.parse("{literal(uri)}")')
    lines.append("if p.is_a?(OTPError)")
    lines.append('  puts "error " + p.message')
    lines.append("else")
    lines.append(f'  puts "#{{hex(p.secret)}}|#{{p.account}}|#{{p.issuer}}|#{{p.algorithm}}|#{{p.digits}}|#{{p.hotp? ? p.counter : p.period}}"')
    lines.append("end")
    read.append(f"{key.hex()}|{account}|{issuer or ''}|{name}|{digits}|{args['counter'] if kind == 'hotp' else period}\t{uri}")
open(os.path.join(work, "uri_cases.iyi"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
import json
json.dump(written, open(os.path.join(work, "uri_written.json"), "w"))
open(os.path.join(work, "uri_read.txt"), "w", encoding="utf-8").write("\n".join(read) + "\n")
PY
  if ! "$IYI" run "$WORK/uri_cases.iyi" >"$WORK/uri_got.txt" 2>&1; then
    echo "  the cases did not run: $(tail -1 "$WORK/uri_got.txt")"
    status=1
  elif ! "$PY" - "$WORK" <<'PY'
import base64, json, os, sys, urllib.parse
work = sys.argv[1]
got = open(os.path.join(work, "uri_got.txt"), encoding="utf-8").read().split("\n--\n")
uris = got[0].splitlines()
written = json.load(open(os.path.join(work, "uri_written.json")))
bad = 0
for w, uri in zip(written, uris + [""] * len(written)):
    parts = urllib.parse.urlsplit(uri)
    query = urllib.parse.parse_qs(parts.query, strict_parsing=True)
    label = urllib.parse.unquote(parts.path[1:])
    issuer, _, account = label.rpartition(":")
    secret = query["secret"][0]
    seen = dict(
        type=parts.netloc, key=base64.b32decode(secret + "=" * (-len(secret) % 8)).hex(), account=account,
        issuer=query.get("issuer", [""])[0], algorithm=query.get("algorithm", ["SHA1"])[0],
        digits=int(query.get("digits", ["6"])[0]))
    if w["type"] == "hotp":
        seen["counter"] = int(query["counter"][0])
    else:
        seen["period"] = int(query.get("period", ["30"])[0])
    ok = parts.scheme == "otpauth" and seen == w and issuer == w["issuer"] and secret == secret.upper() and "=" not in secret
    if not ok:
        bad += 1
        if bad <= 6:
            print(f"  python read {uri!r} as {seen}, not {w}")
print(f"  python read {len(written) - bad} of {len(written)} written URIs back to what was given")
want = [line.split("\t", 1) for line in open(os.path.join(work, "uri_read.txt"), encoding="utf-8").read().splitlines()]
answers = got[1].splitlines() if len(got) > 1 else []
wrong = [(w, g) for w, g in zip(want, answers + [""] * len(want)) if w[0] != g]
for w, g in wrong[:6]:
    print(f"  {w[1]!r}: python put in {w[0]!r}, iyi read {g!r}")
print(f"  {len(want) - len(wrong)} of {len(want)} URIs python wrote read back to what it put in")
sys.exit(1 if bad or wrong else 0)
PY
  then
    status=1
  fi
fi

echo
echo "== what otp refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/otp::{HOTP, TOTP, OTPAuth, OTPAlgorithm}

key = [1_u8, 2_u8, 3_u8]
case Program.args[0]
when "digits-5"
  HOTP.code(key, 0_i64, 5)
when "digits-11"
  TOTP.code(key, 0_i64, 30, 11)
when "negative-counter"
  HOTP.code(key, -1_i64)
when "empty-secret"
  HOTP.code([] of UInt8, 0_i64)
when "step-0"
  TOTP.code(key, 59_i64, 0)
when "before-1970"
  TOTP.verify(key, "123456", -30_i64)
when "negative-window"
  TOTP.verify(key, "123456", 59_i64, -1)
when "colon-account"
  OTPAuth.totp(key, "alice:work", "Example")
when "colon-issuer"
  OTPAuth.totp(key, "alice", "Ex:ample")
when "empty-account"
  OTPAuth.totp(key, "", "Example")
when "period-0"
  OTPAuth.totp(key, "alice", "Example", OTPAlgorithm::SHA1, 6, 0)
when "uri-digits-12"
  OTPAuth.hotp(key, "alice", 0_i64, "", OTPAlgorithm::SHA1, 12)
when "uri-negative-counter"
  OTPAuth.hotp(key, "alice", -5_i64)
when "parse-or-panic"
  OTPAuth.parse("otpauth://totp/alice?secret=JBSWY3DPEHPK3PXPA").or_panic
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
refuse digits-5 "HOTP: digits must be from 6 to 10, not 5"
refuse digits-11 "HOTP: digits must be from 6 to 10, not 11"
refuse negative-counter "HOTP: the counter must not be negative, not -1"
refuse empty-secret "HOTP: the secret is empty"
refuse step-0 "TOTP: the step must be at least 1 second, not 0"
refuse before-1970 "TOTP: the Unix time must not be negative, not -30"
refuse negative-window "TOTP: the window must not be negative, not -1"
refuse colon-account "OTPAuth: the account \"alice:work\" holds a colon, which the label cannot carry"
refuse colon-issuer "OTPAuth: the issuer \"Ex:ample\" holds a colon, which the label cannot carry"
refuse empty-account "OTPAuth: the account is empty"
refuse period-0 "OTPAuth: the period must be at least 1 second, not 0"
refuse uri-digits-12 "OTPAuth: digits must be from 6 to 10, not 12"
refuse uri-negative-counter "OTPAuth: the counter must not be negative, not -5"
# An error value is not a panic until it is asked to be one.
refuse parse-or-panic "otpauth: the secret is not base32: base32: a last group of 1 data character ends on no whole byte"

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
src = Path("$REPO/src/std/otp.iyi").read_text(encoding="utf-8")
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/otp.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_otp_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
# SHA-1's MAC is 20 bytes, so byte 19 is its last and RFC 4226 still
# passes: the longer hashes are where it shows.
prove_broken "the truncation offset read from byte 19 whatever the hash" "RFC 6238 SHA256 at 59" \
  'offset = mac[mac.size - 1].to_i32 & 15' 'offset = mac[19].to_i32 & 15'
prove_broken "the truncation offset cut to three bits" "RFC 4226 count" \
  'offset = mac[mac.size - 1].to_i32 & 15' 'offset = mac[mac.size - 1].to_i32 & 7'
prove_broken "the counter's bytes little-endian" "RFC 4226 count 1" \
  'message[k] = ((counter >> (56 - 8 * k)) & 255_i64).to_u8' 'message[k] = ((counter >> (8 * k)) & 255_i64).to_u8'
prove_broken "a window one step short ahead" "a code one step ahead verifies" \
  'while k <= window' 'while k < window'
prove_broken "a window one step long behind" "a code two steps behind does not verify" \
  'k = -window' 'k = -window - 1'
prove_broken "every step thirty seconds" "a step of 60" \
  'unix_time // step.to_i64' 'unix_time // 30_i64'
prove_broken "SHA-512 asked for and SHA-256 used" "RFC 6238 SHA512 at 59" \
  'HMAC.digest(SHA512, secret, message)' 'HMAC.digest(SHA256, secret, message)'
prove_broken "an escape's digits both the low nibble" "the key URI format's example" \
  'io.write_byte(hex[b.to_i32 >> 4])' 'io.write_byte(hex[b.to_i32 & 15])'
prove_broken "+ kept in a parameter" "+ as a space" \
  'buffer[o] = plus && b == 43_u8 ? 32_u8 : b' 'buffer[o] = b'
prove_broken "issuers that disagree taken" "issuers that disagree" \
  'if colon >= 0 && label_issuer != issuer_text' 'if false'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/otp exercise holds"
else
  echo "the std/otp exercise did not hold"
fi
exit $status
