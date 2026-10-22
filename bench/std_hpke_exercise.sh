#!/usr/bin/env bash
# Exercises `std/hpke`.
#
#     bash bench/std_hpke_exercise.sh
#
# The exercise holds HPKE (RFC 9180) to the RFC's test vectors - the
# subset of the CFRG's test-vectors.json for the suites std/hpke has,
# vendored in bench/std_hpke_fixture - and to its own round trips, failed
# opens, refusals and nonce limit; this gate runs it plain and --release,
# again over every vector of the file and every encryption of each when
# the network answers, sets it beside an HPKE written in Python over the
# primitives of Python's cryptography (bench/std_hpke_oracle.py, itself
# held to the RFC's vectors first), records what seal and open take, asks
# the refusals, checks the formatting, and proves on broken copies of the
# module, and of std/curve25519 where the all-zero check lives, that the
# checks fail where they say.
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
VECTORS="$REPO/bench/std_hpke_fixture/rfc9180_vectors.json"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_hpke_exercise.iyi" \
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

echo "== the std/hpke exercise, plain build, the vendored RFC 9180 vectors"
build_and_run "plain" hpke-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/hpke-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every hpke section reported"
for phrase in "== sizes and code points" "== rfc 9180 vectors (rfc9180_vectors.json)" "== embedded rfc 9180 vectors" \
  "== known answers for p-384 and hkdf-sha384" "== round trips in every suite and mode" "== x25519 points of small order refused" \
  "== encapsulations and keys refused" "== failed opens" "== the nonce limit"; do
  if ! grep -qF "$phrase" "$WORK/hpke-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" hpke-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/hpke-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== the same program with no argument: the vectors it embeds alone"
# What CI's run of every exercise with no argument sees: no file, no
# network, no Python.
if "$WORK/hpke-release" >"$WORK/hpke-noarg.out" 2>&1 && grep -q "ALL CHECKS PASSED" "$WORK/hpke-noarg.out" &&
  grep -qF "== embedded rfc 9180 vectors" "$WORK/hpke-noarg.out" && ! grep -qF "== rfc 9180 vectors (" "$WORK/hpke-noarg.out"; then
  grep '^  [a-z0-9]' "$WORK/hpke-noarg.out" | sed 's/^/  /'
else
  echo "  FAIL with no argument: $(tail -2 "$WORK/hpke-noarg.out" | tr '\n' ' ')"
  status=1
fi

# cut <source> <destination> <subset|every>: the vectors of the suites
# std/hpke has, in the shape bench/std_hpke_fixture/NOTICE describes - the
# rule the vendored file was cut by.
cut_vectors() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import hashlib, json, sys
src, dst, shape = sys.argv[1], sys.argv[2], sys.argv[3]
fields = ("mode", "kem_id", "kdf_id", "aead_id", "info", "ikmR", "ikmE", "ikmS", "skRm", "skEm", "skSm", "pkRm", "pkEm", "pkSm",
          "psk", "psk_id", "enc", "shared_secret", "key", "base_nonce")
out = []
for v in json.load(open(src)):
    if v["kem_id"] not in (0x10, 0x11, 0x20) or v["kdf_id"] not in (1, 2, 3) or v["aead_id"] not in (1, 2, 3, 0xFFFF):
        continue
    case = {k: v[k] for k in fields if k in v}
    sealed = v["encryptions"]
    base = int(v["base_nonce"] or "0", 16)
    for i, e in enumerate(sealed):
        if e["pt"] != sealed[0]["pt"] or bytes.fromhex(e["aad"]) != b"Count-%d" % i or int(e["nonce"], 16) ^ base != i:
            raise SystemExit(f"  a vector's encryption {i} is not the plaintext, Count-{i} and nonce the gate assumes")
    case["count"] = len(sealed)
    case["ciphertexts_sha256"] = hashlib.sha256(b"".join(bytes.fromhex(e["ct"]) for e in sealed)).hexdigest()
    case["encryptions"] = [dict(e, seq=i) for i, e in enumerate(sealed) if shape == "every" or i in (0, 1, 2, 255, 256)]
    case["exports"] = v["exports"]
    out.append(case)
with open(dst, "w", newline="\n") as f:
    f.write("[\n" + ",\n".join(json.dumps(c, separators=(",", ":")) for c in out) + "\n]\n")
print(f"  {len(out)} vectors, {sum(c['count'] for c in out)} encryptions, {sum(len(c['exports']) for c in out)} exports")
PY
}

echo
echo "== every vector of the CFRG's test-vectors.json, every encryption"
# The file the vendored subset was cut from, at the commit its NOTICE
# names, checked against the digest recorded there, then cut again: by the
# vendored rule, which must give the vendored file value for value (as
# JSON: a Windows checkout may have its line ends rewritten), and with no
# encryption left out, which the exercise checks one by one. Offline, or
# without curl or python, the vendored subset above is what was checked.
CFRG="https://raw.githubusercontent.com/cfrg/draft-irtf-cfrg-hpke/5f503c564da00b0687b3de75f1dfbdfc4079ad31/test-vectors.json"
FETCHED=0
if [ -z "$PY" ] || ! command -v curl >/dev/null 2>&1; then
  echo "  no curl or python here, so only the vendored subset was checked"
elif ! curl -sSfL --max-time 60 -o "$WORK/test-vectors.json" "$CFRG" 2>"$WORK/curl.log"; then
  echo "  the file could not be fetched ($(tail -1 "$WORK/curl.log")), so only the vendored subset was checked"
elif ! "$PY" -c 'import hashlib, sys; sys.exit(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest() != "61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6")' "$WORK/test-vectors.json"; then
  echo "  FAIL test-vectors.json: not the sha256 bench/std_hpke_fixture/NOTICE records"
  status=1
elif ! cut_vectors "$WORK/test-vectors.json" "$WORK/subset.json" subset >/dev/null ||
  ! "$PY" -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' "$WORK/subset.json" "$VECTORS"; then
  echo "  FAIL the file cut by the vendored rule is not bench/std_hpke_fixture/rfc9180_vectors.json"
  status=1
elif ! cut_vectors "$WORK/test-vectors.json" "$WORK/every.json" every; then
  status=1
elif "$WORK/hpke-release" "$WORK/every.json" >"$WORK/every.out" 2>&1; then
  FETCHED=1
  echo "  cut by the vendored rule, the file is the vendored subset, value for value"
  grep -A1 '^== rfc 9180 vectors' "$WORK/every.out" | grep '^  [0-9]' | sed 's/^  /  checked: /'
else
  tail -3 "$WORK/every.out" | sed 's/^/  /'
  status=1
fi

echo
echo "== the Python HPKE, held to the same vectors first"
HAVE_CRYPTOGRAPHY=0
if [ -n "$PY" ] && "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import x25519' >/dev/null 2>&1; then
  HAVE_CRYPTOGRAPHY=1
fi
if [ "$HAVE_CRYPTOGRAPHY" -eq 0 ]; then
  echo "  no python with cryptography here, so the Python HPKE goes unasked"
else
  "$PY" "$REPO/bench/std_hpke_oracle.py" vectors "$VECTORS" || status=1
  if [ "$FETCHED" -eq 1 ]; then
    "$PY" "$REPO/bench/std_hpke_oracle.py" vectors "$WORK/every.json" | sed 's/vectors itself/vectors of the whole file itself/' || status=1
  fi
  # The known answers the exercise embeds for DHKEM(P-384) and
  # HKDF-SHA384 are what this HPKE answers now.
  "$PY" "$REPO/bench/std_hpke_oracle.py" answers >"$WORK/answers.json"
  if "$PY" - "$REPO/bench/std_hpke_exercise.iyi" "$WORK/answers.json" <<'PY'; then
import json, sys
src = open(sys.argv[1]).read()
block = src.split("PYTHON_ANSWERS = <<-JSON\n", 1)[1].split("\n  JSON\n", 1)[0]
sys.exit(json.loads(block) != json.load(open(sys.argv[2])))
PY
    echo "  the exercise's known answers for P-384 and HKDF-SHA384 are the Python HPKE's"
  else
    echo "  FAIL the exercise's known answers for P-384 and HKDF-SHA384 are not what the Python HPKE answers"
    status=1
  fi
fi

echo
echo "== against the Python HPKE, both ways"
# Five rounds of each of the 144 suites and modes (bench/std_hpke_oracle.py
# says what a round asks), random inputs drawn there.
if [ "$HAVE_CRYPTOGRAPHY" -eq 1 ]; then
  "$PY" "$REPO/bench/std_hpke_oracle.py" drive "$WORK/hpke-release" 5 || status=1
else
  echo "  no python with cryptography here, so it goes unasked"
fi

echo
echo "== what seal and open take"
# Recorded, not held to a figure: the time is the machine's as much as the
# code's. The best of five runs of 200, --release, in microseconds.
if "$WORK/hpke-release" cost >"$WORK/cost.out" 2>&1; then
  sed 's/^/  /' "$WORK/cost.out"
else
  echo "  the timing did not run: $(tail -1 "$WORK/cost.out")"
  status=1
fi

echo
echo "== what hpke refuses"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/int
import std/hpke::{HpkeSuite, HpkeKem, HpkeKdf, HpkeAead, HpkePrivateKey, HpkeSender, HpkeRecipient}

x = HpkeSuite.new(HpkeKem::X25519Sha256, HpkeKdf::HkdfSha256, HpkeAead::Aes128Gcm)
only = HpkeSuite.new(HpkeKem::X25519Sha256, HpkeKdf::HkdfSha256, HpkeAead::ExportOnly)
key = HpkePrivateKey.derive(x.kem, "k" * 32)
psk = "p" * 32
case Program.args[0]
when "short-ikm"
  HpkePrivateKey.derive(HpkeKem::P384Sha384, "k" * 47)
when "short-randomness"
  x.sender(key.public_key, "info", "r" * 31)
when "short-psk"
  x.sender(key.public_key, "info", "r" * 32, "p" * 31, "id")
when "psk-without-id"
  x.sender(key.public_key, "info", "r" * 32, psk: psk)
when "id-without-psk"
  x.recipient(key, key.public_key.bytes, "info", psk_id: "id")
when "empty-psk-id"
  x.sender(key.public_key, "info", "r" * 32, psk, "")
when "long-export"
  x.sender(key.public_key, "info", "r" * 32).as(HpkeSender).export("", 255 * 32 + 1)
when "export-only-seal"
  only.sender(key.public_key, "info", "r" * 32).as(HpkeSender).seal("message")
when "export-only-open"
  only.recipient(key, key.public_key.bytes, "info").as(HpkeRecipient).open("message")
when "other-kem"
  x.sender(HpkePrivateKey.derive(HpkeKem::P256Sha256, "k" * 32).public_key, "info", "r" * 32)
when "backwards"
  sender = x.sender(key.public_key, "info", "r" * 32).as(HpkeSender)
  sender.advance_to(5_u128)
  sender.advance_to(4_u128)
when "past-the-end"
  x.sender(key.public_key, "info", "r" * 32).as(HpkeSender).advance_to(1_u128.unsafe_shl(96))
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
refuse short-ikm "HPKE: a DHKEM(P-384, HKDF-SHA384) key's input keying material is at least 48 bytes, not 47"
refuse short-randomness "HPKE: a DHKEM(X25519, HKDF-SHA256) key's input keying material is at least 32 bytes, not 31"
refuse short-psk "HPKE: a psk is at least 32 bytes (section 5.1.2), not 31"
refuse psk-without-id "HPKE: a psk needs its psk_id, and a psk_id its psk (section 5.1)"
refuse id-without-psk "HPKE: a psk needs its psk_id, and a psk_id its psk (section 5.1)"
refuse empty-psk-id "HPKE: a psk_id is not empty: the empty one means no psk (section 5.1)"
refuse long-export "HPKE: an export is 0 to 8160 bytes under HKDF-SHA256, not 8161"
refuse export-only-seal "HPKE: an export-only context seals nothing"
refuse export-only-open "HPKE: an export-only context opens nothing"
refuse other-kem "HPKE: the recipient's public key is a DHKEM(P-256, HKDF-SHA256) key, not DHKEM(X25519, HKDF-SHA256)"
refuse backwards "HPKE: a context's sequence goes forward only: it is at 5, not back to 4"
refuse past-the-end "HPKE: a context's sequence ends at 2^96 - 1, not 79228162514264337593543950336"

echo
echo "== doc and format"
if "$IYI" doc "$REPO/src/std/hpke.iyi" >"$WORK/doc.txt" 2>&1 && grep -q "advance_to" "$WORK/doc.txt"; then
  echo "  iyi doc reads the module"
else
  echo "  iyi doc: $(tail -2 "$WORK/doc.txt")"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/hpke.iyi" "$REPO/bench/std_hpke_exercise.iyi" >"$WORK/format.log" 2>&1; then
  echo "  formatted"
else
  sed 's/^/  /' "$WORK/format.log" | tail -5
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <module> <label> <phrase> <old> <new>: the exercise must fail
# on a copy of src/std/<module>.iyi with <old> replaced, at the check that
# names <phrase>.
prove_broken() {
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $2 proof is unmeasured"
    return
  fi
  if ! OLD="$4" NEW="$5" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/$1.iyi").read_text()
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/$1.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $2 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_hpke_exercise.iyi" -- "$VECTORS" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $2"
    status=1
  elif grep -qF "$3" "$WORK/mut.out"; then
    echo "  $2 is caught"
  else
    echo "  $2 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
V0="vector 0 (base, kem 0x0020, kdf 0x0001, aead 0x0001)"
prove_broken hpke "a LabeledExtract that leaves suite_id out" "$V0: skRm from ikmR" \
  '@kdf.mac(salt).update(VERSION).update(@suite_id).update(label)' '@kdf.mac(salt).update(VERSION).update(label)'
prove_broken hpke "the key schedule's suite_id with the KDF and the AEAD swapped" "vector 4 (base, kem 0x0020, kdf 0x0001, aead 0x0002): encryption 0" \
  'HpkeBytes.two(suite.kdf.value) + HpkeBytes.two(suite.aead.value)' 'HpkeBytes.two(suite.aead.value) + HpkeBytes.two(suite.kdf.value)'
prove_broken hpke "the key schedule under the KEM's suite_id" "$V0: encryption 0" \
  '@labels = HpkeLabels.suite(suite)' '@labels = HpkeLabels.kem(suite.kem)'
prove_broken hpke "a nonce without the sequence XORed in" "$V0: encryption 1" \
  'buf[i] = base[i] ^ seq.unsafe_shr((11 - i) * 8).unsafe_to_u8' 'buf[i] = base[i]'
prove_broken hpke "the sequence XORed in little-endian" "$V0: encryption 1" \
  'seq.unsafe_shr((11 - i) * 8)' 'seq.unsafe_shr(i * 8)'
prove_broken hpke "a sender whose sequence is not incremented" "$V0: encryption 1" \
  '    sealed = box.seal(nonce, plaintext, aad)
    @sequence = @sequence &+ 1_u128' '    sealed = box.seal(nonce, plaintext, aad)'
prove_broken hpke "a recipient whose sequence is not incremented" "$V0: encryption 1 opened" \
  '    return HpkeError.new("HPKE: the ciphertext does not open: #{opened.message}") if opened.is_a?(AeadError)
    @sequence = @sequence &+ 1_u128' '    return HpkeError.new("HPKE: the ciphertext does not open: #{opened.message}") if opened.is_a?(AeadError)'
prove_broken hpke "a failed open that spends a sequence number" "a failed open leaves the sequence at 0" \
  '    opened = box.open(nonce, ciphertext, aad)
    return' '    opened = box.open(nonce, ciphertext, aad)
    @sequence = @sequence &+ 1_u128 if opened.is_a?(AeadError)
    return'
prove_broken hpke "a psk_id the key schedule does not bind" "vector 1 (psk, kem 0x0020, kdf 0x0001, aead 0x0001): encryption 0" \
  '"psk_id_hash", psk_id.nil? ? none : HpkeBytes.array(psk_id))' '"psk_id_hash", none)'
prove_broken hpke "an info the key schedule does not bind" "$V0: encryption 0" \
  '"info_hash", HpkeBytes.array(info))' '"info_hash", none)'
prove_broken hpke "a psk the key schedule does not bind" "vector 1 (psk, kem 0x0020, kdf 0x0001, aead 0x0001): encryption 0" \
  '"secret", psk.nil? ? none : HpkeBytes.array(psk))' '"secret", none)'
prove_broken hpke "a mode byte left out of the key schedule" "vector 1 (psk, kem 0x0020, kdf 0x0001, aead 0x0001): encryption 0" \
  'key_schedule_context = [@mode.value.to_u8] + psk_id_hash' 'key_schedule_context = [0_u8] + psk_id_hash'
prove_broken curve25519 "the all-zero X25519 check removed" "an X25519 encapsulation of small order (u = 00000000...) refused" \
  '    if seen == 0_u8
      return CurveError' '    if false
      return CurveError'
prove_broken hpke "AuthEncap without the sender's key" "vector 2 (auth, kem 0x0020, kdf 0x0001, aead 0x0001): the encapsulation's shared secret" \
  'dh2 = sender.agree(recipient.bytes)' 'dh2 = ephemeral.agree(recipient.bytes)'
prove_broken hpke "AuthDecap without the sender's public key" "vector 2 (auth, kem 0x0020, kdf 0x0001, aead 0x0001): the decapsulated shared secret" \
  'dh2 = key.agree(sender.bytes)' 'dh2 = key.agree(sent)'
prove_broken hpke "an auth kem_context without pkS" "vector 2 (auth, kem 0x0020, kdf 0x0001, aead 0x0001): the encapsulation's shared secret" \
  'kem_context = kem_context + sender.public_key.bytes' 'kem_context = kem_context + Array(UInt8).new'
prove_broken hpke "a kem_context without pkR" "$V0: the encapsulation's shared secret" \
  'kem_context = enc + recipient.bytes' 'kem_context = enc'
prove_broken hpke "DeriveKeyPair's candidates counted from 1" "vector 32 (psk, kem 0x0010, kdf 0x0001, aead 0x0001): skRm from ikmR" \
  '"candidate", [counter.to_u8]' '"candidate", [(counter + 1).to_u8]'
prove_broken hpke "an X25519 private key serialised unclamped" "$V0: skRm from ikmR" \
  '    clamped[0] = clamped[0] & 248_u8
' ''
prove_broken hpke "exports under the label exp" "$V0: export 0" \
  '"sec", HpkeBytes.array(exporter_context)' '"exp", HpkeBytes.array(exporter_context)'
prove_broken hpke "a nonce limit one past 2^96 - 1" "$V0: sealing at sequence 2^96 - 1 refused" \
  'sequence 2^96 - 1 is never sealed at") if @sequence >= LAST' 'sequence 2^96 - 1 is never sealed at") if @sequence > LAST'
prove_broken hpke "a P-256 public key read unvalidated" "a P-256 public key off the curve refused" \
  '      return HpkeError.new("HPKE: the #{kem.name} public key is refused: #{point.message}") if point.is_a?(EcdsaError)
' ''

echo
if [ "$status" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit $status
