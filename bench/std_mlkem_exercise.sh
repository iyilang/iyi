#!/usr/bin/env bash
# Exercises `std/mlkem`.
#
#     bash bench/std_mlkem_exercise.sh
#
# The exercise holds ML-KEM-768 to NIST's ACVP vectors - key generation,
# encapsulation, decapsulation (implicit rejection among it) and both key
# checks - from the subset vendored in bench/std_mlkem_fixture, and to its
# own round trips; this gate runs it plain and --release, runs it again
# over every ML-KEM-768 case of the ACVP files when the network answers,
# sets it beside OpenSSL (3.5 and later, which have ML-KEM) and Python's
# cryptography (48 and later, on an OpenSSL that has it), each side's keys
# encapsulated to by the other, records the time each step takes, asks the
# refusals, checks the formatting, and proves on broken copies of the
# module that the checks fail where they say.
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
VECTORS="$REPO/bench/std_mlkem_fixture/acvp_ml_kem_768.json"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_mlkem_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" "$VECTORS" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/mlkem exercise, plain build, the vendored ACVP vectors"
build_and_run "plain" mlkem-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/mlkem-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every mlkem section reported"
for phrase in "== acvp keyGen (ml-kem-768)" "== acvp encapsulation (ml-kem-768)" "== acvp decapsulation (ml-kem-768)" \
  "== acvp decapsulation key check (ml-kem-768)" "== acvp encapsulation key check (ml-kem-768)" \
  "== round trips and the implicit rejection" "== refusals"; do
  if ! grep -qF "$phrase" "$WORK/mlkem-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" mlkem-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/mlkem-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== every ML-KEM-768 case of NIST's ACVP files"
# The two files the vendored subset was cut from, at the commit its NOTICE
# names, checked against the digests recorded there, then cut by the same
# rule with no case left out: 25 key pairs, 25 encapsulations and the 30
# decapsulation and key-check cases. Offline, or without curl or python,
# the vendored subset above is what was checked.
ACVP="https://raw.githubusercontent.com/usnistgov/ACVP-Server/975de31eb83d87039ec88934fdc47d8c312b892d/gen-val/json-files"
if [ -z "$PY" ] || ! command -v curl >/dev/null 2>&1; then
  echo "  no curl or python here, so only the vendored subset was checked"
elif ! curl -sSfL --max-time 60 -o "$WORK/keygen.json" "$ACVP/ML-KEM-keyGen-FIPS203/internalProjection.json" 2>"$WORK/curl.log" ||
  ! curl -sSfL --max-time 60 -o "$WORK/encdec.json" "$ACVP/ML-KEM-encapDecap-FIPS203/internalProjection.json" 2>>"$WORK/curl.log"; then
  echo "  the ACVP files could not be fetched ($(tail -1 "$WORK/curl.log")), so only the vendored subset was checked"
elif ! "$PY" - "$WORK/keygen.json" "$WORK/encdec.json" "$WORK/acvp-all.json" <<'PY'; then
import hashlib, json, sys
wanted = {sys.argv[1]: "d7a62a2c3476957f56dd8d24f9004ea6776ccfe995ffe71a65bb9506dc9c7b1b",
          sys.argv[2]: "a556952ce869bb89c3a3196a701dad89647c193a34c86eafb61a9d710d5b810f"}
for path, digest in wanted.items():
    got = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if got != digest:
        raise SystemExit(f"  {path}: sha256 {got}, not the {digest} bench/std_mlkem_fixture/NOTICE records")
keep = {"keyGen": ("d", "z", "ek", "dk"), "encapsulation": ("ek", "m", "c", "k"), "decapsulation": ("dk", "c", "k", "reason"),
        "decapsulationKeyCheck": ("dk", "testPassed", "reason"), "encapsulationKeyCheck": ("ek", "testPassed", "reason")}
out = {k: [] for k in keep}
for path in (sys.argv[1], sys.argv[2]):
    for g in json.load(open(path))["testGroups"]:
        if g["parameterSet"] != "ML-KEM-768":
            continue
        f = g.get("function", "keyGen")
        out[f] += [dict({"tcId": t["tcId"]}, **{x: t[x] for x in keep[f]}) for t in g["tests"]]
with open(sys.argv[3], "w", newline="\n") as f:
    json.dump(out, f)
print("  " + ", ".join(f"{len(v)} {k}" for k, v in out.items()))
PY
  status=1
elif "$WORK/mlkem-release" "$WORK/acvp-all.json" >"$WORK/acvp-all.out" 2>&1; then
  grep '^  [0-9]' "$WORK/acvp-all.out" | sed 's/^  /  checked: /'
else
  tail -3 "$WORK/acvp-all.out" | sed 's/^/  /'
  status=1
fi

# The oracle mode answers a line for a line (see the exercise's header);
# the comparisons below drive it.
ORACLE="$WORK/mlkem-release"

echo
echo "== against OpenSSL, both ways"
# OpenSSL itself: macOS's `openssl` is LibreSSL, which has no ML-KEM, so
# Homebrew's OpenSSL 3 is asked where it is installed. ML-KEM came in
# OpenSSL 3.5; the Linux container's 3.0 lacks it, and this says so.
#
# 25 seeds drawn here. For each: the key pair of the seed, iyi's and
# OpenSSL's (`genpkey -pkeyopt hexseed:`), both keys byte for byte;
# OpenSSL encapsulating to iyi's encapsulation key and iyi decapsulating;
# iyi encapsulating to OpenSSL's and OpenSSL decapsulating; and one byte of
# a ciphertext changed, decapsulated by iyi and by OpenSSL reading iyi's
# own 2,400-byte decapsulation key (PKCS #8, the expandedKey form): the
# implicit rejection's key must be the same at both ends. Then a key that
# fails each check of FIPS 203 section 7, refused by both.
OPENSSL=openssl
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if [ -x "$candidate" ]; then
    OPENSSL="$candidate"
    break
  fi
done
if [ -z "$PY" ] || ! command -v "$OPENSSL" >/dev/null 2>&1; then
  echo "  no openssl and python here, so OpenSSL goes unasked"
elif ! "$OPENSSL" list -kem-algorithms 2>/dev/null | grep -q 'ML-KEM-768'; then
  echo "  $("$OPENSSL" version 2>&1 | head -1) has no ML-KEM-768 (OpenSSL has it from 3.5), so OpenSSL goes unasked"
else
  echo "  $("$OPENSSL" version)"
  if ! "$PY" - "$ORACLE" "$OPENSSL" "$WORK" <<'PY'; then
import os, subprocess, sys
oracle_bin, openssl, work = sys.argv[1], sys.argv[2], sys.argv[3]
# Windows' compiler writes the binary with .exe after the name it was given.
oracle_bin += ".exe" if not os.path.exists(oracle_bin) and os.path.exists(oracle_bin + ".exe") else ""
oracle = subprocess.Popen([oracle_bin, "oracle"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
def ask(line):
    oracle.stdin.write(line + "\n")
    oracle.stdin.flush()
    return oracle.stdout.readline().strip()
def ossl(*args):
    r = subprocess.run([openssl, *args], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"  FAIL openssl {' '.join(args[:2])}: {r.stderr.decode(errors='replace').strip().splitlines()[:2]}")
    return r
def path(name):
    return os.path.join(work, name)
OID = bytes.fromhex("300b0609608648016503040402")
def spki(ek):
    return bytes.fromhex("308204b2") + OID + bytes.fromhex("038204a100") + ek
def expanded(dk):
    return bytes.fromhex("30820978020100") + OID + bytes.fromhex("0482096404820960") + dk
def write(name, data):
    with open(path(name), "wb") as f:
        f.write(data)
    return path(name)
def read(name):
    with open(path(name), "rb") as f:
        return f.read()
failed = 0
unexpanded = 0
def fail(what):
    global failed
    failed += 1
    print("  FAIL " + what)
for n in range(25):
    seed = os.urandom(64)
    ek_i, dk_i = (bytes.fromhex(x) for x in ask("g " + seed.hex()).split())
    ossl("genpkey", "-algorithm", "ML-KEM-768", "-pkeyopt", "hexseed:" + seed.hex(), "-outform", "DER", "-out", path("k.der"))
    k = read("k.der")
    # OpenSSL 3.5 writes the seed and the expanded key both, the
    # expandedKey's OCTET STRING the last 2,404 bytes; one configured to
    # write the seed alone leaves the decapsulation keys uncompared.
    both = k[-2404:-2400] == bytes.fromhex("04820960") and k[-2474:-2468] == bytes.fromhex("308209a60440")
    dk_o = k[-2400:] if both else None
    unexpanded += 0 if both else 1
    ossl("pkey", "-inform", "DER", "-in", path("k.der"), "-pubout", "-outform", "DER", "-out", path("pub.der"))
    ek_o = read("pub.der")[22:]
    if ek_i != ek_o:
        fail(f"seed {n}: the encapsulation keys differ")
    if dk_o is not None and dk_i != dk_o:
        fail(f"seed {n}: the decapsulation keys differ")
    # OpenSSL encapsulates to iyi's key; iyi decapsulates.
    write("ek-i.der", spki(ek_i))
    ossl("pkeyutl", "-encap", "-inkey", path("ek-i.der"), "-keyform", "DER", "-pubin", "-out", path("c.bin"), "-secret", path("s.bin"))
    c, s = read("c.bin"), read("s.bin")
    if ask(f"d {dk_i.hex()} {c.hex()}") != s.hex():
        fail(f"seed {n}: iyi's decapsulation of OpenSSL's ciphertext is not OpenSSL's secret")
    # iyi encapsulates to OpenSSL's key; OpenSSL decapsulates.
    c2, k2 = ask(f"e {ek_o.hex()} {os.urandom(32).hex()}").split()
    write("c2.bin", bytes.fromhex(c2))
    ossl("pkeyutl", "-decap", "-inkey", path("k.der"), "-keyform", "DER", "-in", path("c2.bin"), "-secret", path("s2.bin"))
    if read("s2.bin").hex() != k2:
        fail(f"seed {n}: OpenSSL's decapsulation of iyi's ciphertext is not iyi's secret")
    # A changed byte: both ends answer the implicit rejection's key, OpenSSL
    # from iyi's expanded decapsulation key.
    bad = bytearray(c)
    at = int.from_bytes(os.urandom(2), "big") % len(bad)
    bad[at] ^= 1 << (n % 8)
    write("bad.bin", bytes(bad))
    write("dk-i.der", expanded(dk_i))
    ossl("pkeyutl", "-decap", "-inkey", path("dk-i.der"), "-keyform", "DER", "-in", path("bad.bin"), "-secret", path("s3.bin"))
    mine = ask(f"d {dk_i.hex()} {bytes(bad).hex()}")
    if mine != read("s3.bin").hex():
        fail(f"seed {n}: a ciphertext changed at byte {at}: iyi answers {mine[:16]}..., OpenSSL {read('s3.bin').hex()[:16]}...")
    if mine == s.hex():
        fail(f"seed {n}: a ciphertext changed at byte {at} decapsulated to the real secret")
if unexpanded:
    print(f"  {unexpanded} of OpenSSL's keys were written as the seed alone, so their decapsulation keys went uncompared")
print("  25 seeds: both keys the same; OpenSSL's ciphertexts decapsulated by iyi and iyi's by OpenSSL; 25 changed ones implicitly rejected alike")
# Section 7.2: the first coefficient of t set to q. Section 7.3: one bit
# of the stored H(ek) flipped.
over = bytearray(ek_i)
over[0] = 0x01
over[1] = (over[1] & 0xf0) | 0x0d
mine = ask(f"e {bytes(over).hex()} {os.urandom(32).hex()}")
write("over.der", spki(bytes(over)))
theirs = subprocess.run([openssl, "pkeyutl", "-encap", "-inkey", path("over.der"), "-keyform", "DER", "-pubin", "-out", path("x.bin"), "-secret", path("y.bin")], capture_output=True)
if "modulus check" in mine and theirs.returncode != 0:
    print("  an encapsulation key with a coefficient of q: refused by both")
else:
    fail(f"an encapsulation key with a coefficient of q: iyi {mine[:60]!r}, OpenSSL exit {theirs.returncode}")
hashed = bytearray(dk_i)
hashed[2340] ^= 1
mine = ask(f"d {bytes(hashed).hex()} {c.hex()}")
write("hashed.der", expanded(bytes(hashed)))
theirs = subprocess.run([openssl, "pkeyutl", "-decap", "-inkey", path("hashed.der"), "-keyform", "DER", "-in", path("c.bin"), "-secret", path("y.bin")], capture_output=True)
if "hash check" in mine and theirs.returncode != 0:
    print("  a decapsulation key whose H(ek) is one bit off: refused by both")
else:
    fail(f"a decapsulation key whose H(ek) is one bit off: iyi {mine[:60]!r}, OpenSSL exit {theirs.returncode}")
oracle.stdin.close()
oracle.wait()
sys.exit(1 if failed else 0)
PY
    status=1
  fi
fi

echo
echo "== against python's cryptography, both ways"
# `cryptography` has ML-KEM from 48 on, over an OpenSSL that has it (its
# own wheels carry one). 200 seeds: the encapsulation key of each from both;
# cryptography encapsulating to iyi's key, iyi decapsulating; iyi
# encapsulating to cryptography's key, cryptography decapsulating; and a
# changed ciphertext answered alike by both.
HAVE_MLKEM=0
if [ -n "$PY" ] && "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import mlkem; mlkem.MLKEM768PrivateKey.generate()' >/dev/null 2>&1; then
  HAVE_MLKEM=1
fi
if [ "$HAVE_MLKEM" -eq 0 ]; then
  echo "  no python cryptography with ML-KEM here ($([ -n "$PY" ] && "$PY" -c 'import cryptography; print("cryptography " + cryptography.__version__)' 2>/dev/null || echo "none")), so it goes unasked"
elif ! "$PY" - "$ORACLE" <<'PY'; then
import os, subprocess, sys
import cryptography
from cryptography.hazmat.primitives.asymmetric import mlkem
oracle_bin = sys.argv[1]
oracle_bin += ".exe" if not os.path.exists(oracle_bin) and os.path.exists(oracle_bin + ".exe") else ""
oracle = subprocess.Popen([oracle_bin, "oracle"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
def ask(line):
    oracle.stdin.write(line + "\n")
    oracle.stdin.flush()
    return oracle.stdout.readline().strip()
failed = 0
def fail(what):
    global failed
    failed += 1
    print("  FAIL " + what)
for n in range(200):
    seed = os.urandom(64)
    ek_i, dk_i = ask("g " + seed.hex()).split()
    key = mlkem.MLKEM768PrivateKey.from_seed_bytes(seed)
    ek_c = key.public_key().public_bytes_raw().hex()
    if ek_i != ek_c:
        fail(f"seed {n}: the encapsulation keys differ")
        continue
    secret, ciphertext = mlkem.MLKEM768PublicKey.from_public_bytes(bytes.fromhex(ek_i)).encapsulate()
    if ask(f"d {dk_i} {ciphertext.hex()}") != secret.hex():
        fail(f"seed {n}: iyi's decapsulation of cryptography's ciphertext is not its secret")
    c, k = ask(f"e {ek_c} {os.urandom(32).hex()}").split()
    if key.decapsulate(bytes.fromhex(c)).hex() != k:
        fail(f"seed {n}: cryptography's decapsulation of iyi's ciphertext is not iyi's secret")
    bad = bytearray(ciphertext)
    bad[n * 5 % len(bad)] ^= 0x80
    if ask(f"d {dk_i} {bytes(bad).hex()}") != key.decapsulate(bytes(bad)).hex():
        fail(f"seed {n}: a changed ciphertext answered differently")
over = bytearray(bytes.fromhex(ek_i))
over[0] = 0x01
over[1] = (over[1] & 0xf0) | 0x0d
try:
    mlkem.MLKEM768PublicKey.from_public_bytes(bytes(over))
    theirs = "taken"
except ValueError:
    theirs = "refused"
mine = ask(f"e {bytes(over).hex()} {os.urandom(32).hex()}")
print(f"  cryptography {cryptography.__version__}: 200 seeds, both ways, and 200 changed ciphertexts answered alike")
print(f"  an encapsulation key with a coefficient of q: iyi {'refused' if 'modulus check' in mine else 'took it'}, cryptography {theirs}")
if "modulus check" not in mine:
    fail("iyi took an encapsulation key with a coefficient of q")
oracle.stdin.close()
oracle.wait()
sys.exit(1 if failed else 0)
PY
  status=1
fi

echo
echo "== what a key pair, an encapsulation and a decapsulation take"
# Recorded, not held to a figure: the time is the machine's as much as the
# code's. iyi's is the best of five runs of 200, --release, in
# microseconds; OpenSSL's is its own `speed`, for a second each.
if "$WORK/mlkem-release" cost >"$WORK/cost.out" 2>&1; then
  sed 's/^/  /' "$WORK/cost.out"
else
  echo "  the timing did not run: $(tail -1 "$WORK/cost.out")"
  status=1
fi
if command -v "$OPENSSL" >/dev/null 2>&1 && "$OPENSSL" list -kem-algorithms 2>/dev/null | grep -q 'ML-KEM-768'; then
  "$OPENSSL" speed -seconds 1 -kem-algorithms ML-KEM-768 2>/dev/null | tr -d '\r' | awk '
    $1 == "ML-KEM-768" { printf "  OpenSSL: ML-KEM-768 key pair %d us, encapsulation %d us, decapsulation %d us\n", $2 * 1e6, $3 * 1e6, $4 * 1e6 }'
fi

echo
echo "== what mlkem refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/mlkem::{MlKem768, MlKem768PrivateKey}

case Program.args[0]
when "short-seed"
  MlKem768PrivateKey.from_seed("s" * 63)
when "long-seed"
  MlKem768PrivateKey.from_seed("s" * 96)
when "short-m"
  MlKem768.encapsulate(MlKem768PrivateKey.from_seed("s" * 64).encapsulation_key, "m" * 31)
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
refuse short-seed "ML-KEM-768: a seed is 64 bytes (d, then z), not 63"
refuse long-seed "ML-KEM-768: a seed is 64 bytes (d, then z), not 96"
refuse short-m "ML-KEM-768: the randomness of an encapsulation is 32 bytes, not 31"

echo
echo "== doc and format"
if "$IYI" doc "$REPO/src/std/mlkem.iyi" >"$WORK/doc.txt" 2>&1 && grep -q "decapsulate" "$WORK/doc.txt"; then
  echo "  iyi doc reads the module"
else
  echo "  iyi doc: $(tail -2 "$WORK/doc.txt")"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/mlkem.iyi" "$REPO/bench/std_mlkem_exercise.iyi" >"$WORK/format.log" 2>&1; then
  echo "  formatted"
else
  sed 's/^/  /' "$WORK/format.log" | tail -5
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
src = Path("$REPO/src/std/mlkem.iyi").read_text()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/mlkem.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_mlkem_exercise.iyi" -- "$VECTORS" >"$WORK/mut.out" 2>&1; then
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
prove_broken "an NTT twiddle one off (zeta 1 = 1730)" "acvp keyGen 26: the encapsulation key" \
  '1_u32, 1729_u32, 2580_u32' '1_u32, 1730_u32, 2580_u32'
prove_broken "a base-case gamma one off" "acvp keyGen 26: the encapsulation key" \
  '17_u32, 3312_u32, 2761_u32' '17_u32, 3313_u32, 2761_u32'
prove_broken "an inverse NTT without 128^-1" "acvp encapsulation 26: the ciphertext" \
  'f[j] = MlKemField.mul(f[j], 3303_u32)' 'f[j] = MlKemField.mul(f[j], 1_u32)'
prove_broken "a CBD with eta 3" "acvp keyGen 26: the encapsulation key" \
  '  ETA = 2' '  ETA = 3'
prove_broken "a key generation without its k byte in G (FIPS 203's ipd)" "acvp keyGen 26: the encapsulation key" \
  'g = SHA3_512.new.update(sp, 32).update(pointerof(k), 1).final' 'g = SHA3_512.new.update(sp, 32).final'
prove_broken "A sampled from rho || i || j" "acvp keyGen 26: the encapsulation key" \
  '    ip[0] = j
    ip[1] = i' '    ip[0] = i
    ip[1] = j'
prove_broken "encryption by A, not A transposed" "acvp encapsulation 26: the ciphertext" \
  'MlKemPoly.dot(a, i, 3, y, u)' 'MlKemPoly.dot(a, i * 3, 1, y, u)'
prove_broken "compression that truncates rather than rounds" "acvp encapsulation 26: the ciphertext" \
  '      quotient = quotient &+ (((1664_u32 &- remainder) >> 31) & 1_u32)
' ''
prove_broken "decompression that truncates rather than rounds" "acvp encapsulation 26: the ciphertext" \
  'f[i] = dividend.unsafe_shr(d) &+ (dividend.unsafe_shr(d - 1) & 1_u32)' 'f[i] = dividend.unsafe_shr(d)'
prove_broken "a Barrett reduction without its last subtraction" "acvp keyGen 26: the encapsulation key" \
  '    reduce_once(a &- quotient &* Q)' '    a &- quotient &* Q'
prove_broken "implicit rejection returning the real key" "acvp decapsulation 88 (modified ciphertext): the shared secret" \
  'secret[i] = (g[i] & keep) | (rejected[i] & ~keep)' 'secret[i] = g[i]'
prove_broken "a rejection key of J(z) without the ciphertext" "acvp decapsulation 88 (modified ciphertext): the shared secret" \
  'rejected = SHAKE256.new.update(@z).update(c, n).read(32)' 'rejected = SHAKE256.new.update(@z).read(32)'
prove_broken "a ciphertext comparison that stops short of the last byte" "acvp decapsulation 88 (modified ciphertext): the shared secret" \
  '    while i < MlKem768::CIPHERTEXT_SIZE
      diff' '    while i < MlKem768::CIPHERTEXT_SIZE - 1
      diff'
prove_broken "the modulus check skipped" "acvp encapsulationKeyCheck 137 (noisy linear system values too large): refused" \
  '      return false if d1 >= MlKemField::Q || d2 >= MlKemField::Q
' ''
prove_broken "a modulus check that takes q itself" "a coefficient of q refused by the modulus check" \
  'return false if d1 >= MlKemField::Q || d2 >= MlKemField::Q' 'return false if d1 > MlKemField::Q || d2 > MlKemField::Q'
prove_broken "the hash check skipped" "acvp decapsulationKeyCheck 128 (modified H): refused" \
  '    unless seen == 0_u8
      return' '    if false
      return'
prove_broken "a decapsulation key's s read unreduced" "a decapsulation key whose s is spelled with a coefficient past q is read as the canonical one" \
  '        v[i * 256 + j] = MlKemField.reduce_once(v[i * 256 + j])' '        v[i * 256 + j] = v[i * 256 + j]'

echo
if [ "$status" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit $status
