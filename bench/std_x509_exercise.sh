#!/usr/bin/env bash
# Exercises `std/x509`.
#
#     bash bench/std_x509_exercise.sh
#
# The exercise holds chains Python's cryptography made, each judged as
# Python's own verifier judges it and each refusal for its reason, hosts
# matched, certificates that are not certificates, and Ed25519 keys and
# signatures (RFC 8410); this gate runs it plain and --release, holds 200
# fresh chains - random keys (P-256, P-384, RSA, Ed25519), depths and
# defects - to Python's verifier, reads every certificate in the machine's
# CA bundle as Python reads it, shows an error value's sentence through
# `.or_panic`, and proves on broken copies of the module that the checks
# fail where they say.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_x509_exercise.iyi" \
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

echo "== the std/x509 exercise, plain build"
build_and_run "plain" x509-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/x509-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every x509 section reported"
for phrase in "== chains Python's cryptography made" "== hosts matched" "== certificates that are not certificates" "== Ed25519 (RFC 8410)"; do
  if ! grep -q "$phrase" "$WORK/x509-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" x509-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/x509-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== 200 fresh chains held to Python's verifier"
# Keys drawn from a pool of P-256, P-384, 2048-bit RSA and Ed25519; zero
# to two intermediates; and one defect or none: a host the leaf does not
# name, a certificate out of its time, an issuer that is not a CA or may
# not sign or allows no CA under it, extKeyUsage without serverAuth, a
# leaf that is a CA, an unknown critical extension, a signature by another
# key under the issuer's name, an intermediate left out, a wildcard, an IP.
# Python's verifier refuses an Ed25519 issuer outright (the Web PKI's
# rule; std/x509 takes one, as OpenSSL and Go do), so a chain with one is
# judged as its twin - the same chain, each Ed25519 key swapped for an EC
# key of its own - and every link of the real one is held to Python's own
# Ed25519 check.
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.x509 import verification' >/dev/null 2>&1; then
  echo "  no python cryptography with a verifier here, so the chains go uncompared"
else
  "$PY" - "$WORK/cases.txt" "$WORK/want.txt" <<'PY'
import datetime as dt, ipaddress, os, random, sys, zlib
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
from cryptography.x509 import verification as v
NOW = dt.datetime(2026, 6, 1, tzinfo=dt.timezone.utc)
DAY = dt.timedelta(days=1)
rng = random.Random(int.from_bytes(os.urandom(8), "big"))
pool = [ec.generate_private_key(ec.SECP256R1()) for _ in range(6)] + \
       [ec.generate_private_key(ec.SECP384R1()) for _ in range(4)] + \
       [rsa.generate_private_key(public_exponent=65537, key_size=2048) for _ in range(4)] + \
       [ed25519.Ed25519PrivateKey.generate() for _ in range(4)]
def is_ed(key): return isinstance(key, ed25519.Ed25519PrivateKey)
TWIN = {id(k): ec.generate_private_key(ec.SECP256R1()) for k in pool if is_ed(k)}
def name(cn): return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
# The hash by the name, not a draw, so a chain and its twin are signed alike.
def cert(cn, key, issuer, issuer_key, ca, path_len=None, cert_sign=True, eku=None, sans=None,
         start=NOW - 30 * DAY, end=NOW + 300 * DAY, unknown=False, bc=True):
    b = (x509.CertificateBuilder().subject_name(name(cn)).issuer_name(issuer)
         .public_key(key.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(start).not_valid_after(end))
    if bc:
        b = b.add_extension(x509.BasicConstraints(ca=ca, path_length=path_len), critical=True)
    b = b.add_extension(x509.KeyUsage(digital_signature=not ca, content_commitment=False, key_encipherment=False,
                                      data_encipherment=False, key_agreement=False, key_cert_sign=ca and cert_sign,
                                      crl_sign=ca, encipher_only=False, decipher_only=False), critical=True)
    if eku: b = b.add_extension(x509.ExtendedKeyUsage(eku), critical=False)
    if sans is not None: b = b.add_extension(x509.SubjectAlternativeName(sans), critical=False)
    b = b.add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
    if issuer != name(cn) or issuer_key is not key:
        b = b.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()), critical=False)
    if unknown:
        b = b.add_extension(x509.UnrecognizedExtension(x509.ObjectIdentifier("1.3.6.1.4.1.55555.7"), b"\x05\x00"), critical=True)
    if is_ed(issuer_key):
        return b.sign(issuer_key, None)
    sha384 = not isinstance(issuer_key, rsa.RSAPrivateKey) and zlib.crc32(cn.encode()) % 10 < 3
    return b.sign(issuer_key, hashes.SHA384() if sha384 else hashes.SHA256())
DEFECTS = ["none", "none", "none", "host", "leaf_expired", "leaf_early", "issuer_expired", "not_ca", "no_bc", "no_cert_sign",
           "path_len", "leaf_client", "issuer_client", "leaf_ca", "unknown_leaf", "unknown_issuer", "wrong_signer",
           "missing", "wildcard", "wildcard_deep", "ip", "ip_other"]
# One case built from its drawn keys, each passed through *swap*: the
# leaf, the intermediates as handed over, the root, and the chain in order
# from the root down.
def build(i, defect, depth, keys, wrong, order, sans, swap):
    def k_(k): return swap(k)
    root_key = k_(keys[0])
    root = cert(f"Root {i}", root_key, name(f"Root {i}"), root_key, True)
    chain, issuer, issuer_key = [], root, root_key
    for d in range(depth):
        k = k_(keys[d + 1])
        top = d == depth - 1
        kw = {}
        if top:
            if defect == "issuer_expired": kw["end"] = NOW - DAY
            if defect == "not_ca": kw["ca_flag"] = False
            if defect == "no_bc": kw["bc"] = False
            if defect == "no_cert_sign": kw["cert_sign"] = False
            if defect == "issuer_client": kw["eku"] = [ExtendedKeyUsageOID.CLIENT_AUTH]
            if defect == "unknown_issuer": kw["unknown"] = True
        if defect == "path_len" and d == 0: kw["path_len"] = 0
        ca_flag = kw.pop("ca_flag", True)
        inter = cert(f"Inter {i}.{d}", k, issuer.subject, issuer_key, ca_flag, **kw)
        chain.append(inter); issuer, issuer_key = inter, k
    kw = {}
    if defect == "leaf_expired": kw["end"] = NOW - DAY
    if defect == "leaf_early": kw["start"] = NOW + DAY
    if defect == "leaf_client": kw["eku"] = [ExtendedKeyUsageOID.CLIENT_AUTH]
    if defect == "unknown_leaf": kw["unknown"] = True
    signer = k_(wrong) if defect == "wrong_signer" else issuer_key
    leaf = cert(f"leaf {i}", k_(keys[-1]), issuer.subject, signer, defect == "leaf_ca", sans=sans, **kw)
    inters = list(reversed(chain))
    if defect == "missing": inters = inters[1:]
    return leaf, [inters[j] for j in order], root, [root] + chain + [leaf]
cases, want = [], []
twinned = 0
ed_keys = 0
def hexes(cs): return ",".join(c.public_bytes(serialization.Encoding.DER).hex() for c in cs) or "-"
for i in range(200):
    defect = rng.choice(DEFECTS)
    depth = rng.randrange(3)
    if defect in ("path_len", "missing"): depth = 2
    if defect in ("issuer_expired", "not_ca", "no_bc", "no_cert_sign", "issuer_client", "unknown_issuer"): depth = max(depth, 1)
    keys = rng.sample(pool, depth + 2)
    wrong = rng.choice([k for k in pool if k is not keys[-2]]) if defect == "wrong_signer" else None
    order = list(range(depth - 1 if defect == "missing" else depth))
    rng.shuffle(order)
    host = f"www{i}.example.com"
    sans = [x509.DNSName(host)]
    if defect == "host": host = f"mail{i}.example.com"
    if defect == "wildcard": sans = [x509.DNSName("*.example.com")]
    if defect == "wildcard_deep": sans = [x509.DNSName("*.example.com")]; host = f"a.www{i}.example.com"
    if defect in ("ip", "ip_other"):
        sans = [x509.IPAddress(ipaddress.ip_address(f"192.0.2.{i % 250 + 1}"))]
        host = f"192.0.2.{i % 250 + 1}" if defect == "ip" else f"198.51.100.{i % 250 + 1}"
    leaf, inters, root, ordered = build(i, defect, depth, keys, wrong, order, sans, lambda k: k)
    ed_keys += sum(1 for k in keys if is_ed(k))
    if any(is_ed(k) for k in keys[:-1]) or (wrong is not None and is_ed(wrong)):
        twinned += 1
        # Every link of the real chain, by Python's own signature check:
        # each holds but the leaf's when another key signed it - which
        # Python answers with ValueError when that key is of another kind
        # than the issuer's.
        for upper, lower in zip(ordered, ordered[1:]):
            try:
                lower.verify_directly_issued_by(upper)
                good = True
            except (InvalidSignature, ValueError):
                good = False
            if good != (lower is not leaf or defect != "wrong_signer"):
                raise SystemExit(f"case {i} ({defect}): Python's check of {lower.subject.rfc4514_string()} says {good}")
        judged = build(i, defect, depth, keys, wrong, order, sans, lambda k: TWIN.get(id(k), k))
    else:
        judged = (leaf, inters, root, ordered)
    subject = v.IPAddress(ipaddress.ip_address(host)) if defect in ("ip", "ip_other") else v.DNSName(host)
    try:
        v.PolicyBuilder().store(v.Store([judged[2]])).time(NOW).build_server_verifier(subject).verify(judged[0], judged[1])
        verdict = "true"
    except v.VerificationError:
        verdict = "false"
    cases.append(f"{host} {hexes([leaf])} {hexes(inters)} {hexes([root])} {defect}")
    want.append(verdict)
print(f"  {ed_keys} Ed25519 keys among the cases; {twinned} chains with an Ed25519 signer judged by their twins")
open(sys.argv[1], "w").write("\n".join(cases) + "\n")
open(sys.argv[2], "w").write("\n".join(want) + "\n")
PY
  "$WORK/x509-release" verify "$WORK/cases.txt" >"$WORK/got.txt" 2>&1
  if ! "$PY" - "$WORK/want.txt" "$WORK/got.txt" "$WORK/cases.txt" <<'PY'
import sys
want = open(sys.argv[1]).read().split()
got = [g.split(":")[0] for g in open(sys.argv[2]).read().splitlines()]
full = open(sys.argv[2]).read().splitlines()
cases = open(sys.argv[3]).read().splitlines()
bad = [(i, w, g) for i, (w, g) in enumerate(zip(want, got)) if w != g]
if len(want) != len(got):
    bad.append((-1, f"{len(want)} answers", f"{len(got)} answers"))
if bad:
    print(f"  {len(bad)} of {len(want)} verdicts differ from Python's:")
    for i, w, g in bad[:6]:
        defect = cases[i].split()[-1] if i >= 0 else "?"
        print(f"    case {i} ({defect}): python {w}, iyi {full[i] if i >= 0 else g}")
    sys.exit(1)
defects = {c.split()[-1] for c in cases}
print(f"  {len(want)} verdicts as Python's: {want.count('true')} chains held, {want.count('false')} refused, over {len(defects)} kinds of defect")
PY
  then
    status=1
  fi
fi

echo
echo "== every certificate in the CA bundle, read as Python reads it"
BUNDLE=""
for candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [ -f "$candidate" ]; then
    BUNDLE="$candidate"
    break
  fi
done
if [ -z "$PY" ] || [ -z "$BUNDLE" ] || ! "$PY" -c 'from cryptography import x509' >/dev/null 2>&1; then
  echo "  no python cryptography or no CA bundle here, so the roots go unread"
else
  "$PY" - "$BUNDLE" "$WORK/roots_want.txt" <<'PY'
import re, sys, warnings
warnings.simplefilter("ignore")
from cryptography import x509
from cryptography.exceptions import InvalidSignature, UnsupportedAlgorithm
from cryptography.x509.oid import ExtensionOID, SignatureAlgorithmOID
text = open(sys.argv[1], encoding="ascii", errors="replace").read()
lines = []
KU = ["digital_signature", "content_commitment", "key_encipherment", "data_encipherment", "key_agreement",
      "key_cert_sign", "crl_sign", "encipher_only", "decipher_only"]
for i, body in enumerate(re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", text, re.S)):
    c = x509.load_pem_x509_certificate(body.encode())
    ext = lambda cls: next((e.value for e in c.extensions if isinstance(e.value, cls)), None)
    bc = ext(x509.BasicConstraints)
    ku = ext(x509.KeyUsage)
    bits = "-"
    if ku is not None:
        n = 0
        for k, f in enumerate(KU):
            try:
                if getattr(ku, f): n |= 1 << k
            except ValueError:
                pass
        bits = str(n)
    eku = ext(x509.ExtendedKeyUsage)
    san = ext(x509.SubjectAlternativeName)
    dns = san.get_values_for_type(x509.DNSName) if san else []
    if c.signature_algorithm_oid in (SignatureAlgorithmOID.RSA_WITH_SHA1, SignatureAlgorithmOID.ECDSA_WITH_SHA1):
        verdict = "sha1"
    else:
        try:
            c.verify_directly_issued_by(c); verdict = "true"
        except (InvalidSignature, ValueError, UnsupportedAlgorithm):
            verdict = "false"
    lines.append(" ".join([str(i), str(c.version.value + 1), "true" if bc and bc.ca else "false",
                           str(bc.path_length) if bc and bc.path_length is not None else "-", bits,
                           ",".join(o.dotted_string for o in eku) if eku else "-",
                           ",".join(d.lower() for d in dns) or "-", verdict]))
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
PY
  "$WORK/x509-release" roots "$BUNDLE" >"$WORK/roots_got.txt" 2>&1
  if cmp -s "$WORK/roots_want.txt" "$WORK/roots_got.txt"; then
    echo "  $(wc -l <"$WORK/roots_got.txt" | tr -d ' ') certificates read as Python reads them: version, basicConstraints, keyUsage, extKeyUsage, DNS names; $(grep -c ' true$' "$WORK/roots_got.txt") self-signatures checked, $(grep -c ' sha1$' "$WORK/roots_got.txt") under SHA-1 refused"
  else
    echo "  the bundle reads differently from Python:"
    diff "$WORK/roots_want.txt" "$WORK/roots_got.txt" | head -6 | cut -c1-200 | sed 's/^/    /'
    status=1
  fi
fi

echo
echo "== an error value's sentence, through .or_panic"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/x509::{Certificate}

Certificate.parse([2_u8, 1_u8, 1_u8]).or_panic
puts "accepted"
IYI
if "$IYI" run "$WORK/refuse.iyi" >"$WORK/refuse.out" 2>&1; then
  echo "  an INTEGER was accepted as a certificate"
  status=1
elif ! grep -qF "x509: asn1: expected a SEQUENCE, found INTEGER at offset 0" "$WORK/refuse.out"; then
  echo "  an INTEGER was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
  status=1
else
  echo "  x509: asn1: expected a SEQUENCE, found INTEGER at offset 0"
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [module]: the exercise must
# fail on a copy of the module (std/x509 unless named) with <old>
# replaced, at the check that names <phrase>.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" MODULE="${5:-x509}" "$PY" - <<PY
import os
from pathlib import Path
module = os.environ["MODULE"]
src = Path("$REPO/src/std/" + module + ".iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/" + module + ".iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_x509_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a leaf out of its time taken" "a leaf past its end: expected a refusal" \
  '    return "#{leaf.subject_name} is not valid at #{now}' '    return nil if false && "#{leaf.subject_name} is not valid at #{now}'
prove_broken "an issuer out of its time taken" "an intermediate past its end: expected a refusal" \
  '    return "#{name} is not valid at #{now}' '    return nil if false && "#{name} is not valid at #{now}'
prove_broken "an issuer that is no CA taken" "an intermediate that is not a CA: expected a refusal" \
  '    return "#{name} is not a CA" unless issuer.basic_constraints && issuer.ca' ''
prove_broken "keyCertSign unchecked" "an intermediate not allowed keyCertSign: expected a refusal" \
  'if usage && (usage >> Certificate::KEY_CERT_SIGN) & 1 == 0' 'if false'
prove_broken "pathLenConstraint off by one" "a pathLenConstraint of 0 over another CA: expected a refusal" \
  'if length && chain.size - 1 > length' 'if length && chain.size - 2 > length'
prove_broken "extKeyUsage unchecked" "a leaf for clientAuth only: expected a refusal" \
  '    return true unless usages' '    return true'
prove_broken "a CA taken as the leaf" "a leaf that is a CA: expected a refusal" \
  '    return "#{leaf.subject_name} is a CA certificate, not a server'"'"'s" if leaf.ca' ''
prove_broken "unknown critical extensions passed over" "a leaf with an unknown critical extension: expected a refusal" \
  '        @unhandled_critical << oid if critical' ''
prove_broken "the issuer's signature unchecked" "a leaf signed by another key under the same name: expected a refusal" \
  '    child.signature_error(issuer)
  end' '    nil
  end'
prove_broken "the first candidate issuer only" "a decoy intermediate under the same name, tried first: refused" \
  '        failures << problem
        next' '        failures << problem
        return nil'
prove_broken "SHA-1 taken" "a leaf signed under SHA-1: expected a refusal" \
  '    when X509Oids::SHA1_RSA, X509Oids::ECDSA_SHA1
      return "#{@subject_name} is signed under SHA-1, which is refused"' '    when X509Oids::SHA1_RSA, X509Oids::ECDSA_SHA1
      return nil'
prove_broken "a wildcard for any number of labels" "a wildcard for two labels: expected a refusal" \
  '      return host[dot + 1, host.size - dot - 1] == rest' '      return host.ends_with?("." + rest)'
prove_broken "a host matched as a suffix" "another host: expected a refusal" \
  '    pattern == host
  end' '    pattern.ends_with?(host[host.index('"'"'.'"'"') || 0, host.size - (host.index('"'"'.'"'"') || 0)])
  end'
prove_broken "a name constraint matched as a bare suffix" "a name that only ends like the permitted one: expected a refusal" \
  '    name == constraint || name.ends_with?("." + constraint)' '    name.ends_with?(constraint)'
prove_broken "excluded names unchecked" "a name in the excluded subtree: expected a refusal" \
  '      if issuer.excluded_dns.any? { |c| X509Names.within?(dns, c) }' '      if false'
prove_broken "an IP range compared unmasked" "an address inside the permitted range: refused" \
  '      return false unless byte & mask == range[i] & mask' '      return false unless byte == range[i]'
prove_broken "IPv6 :: unexpanded" "an IPv6 address: refused" \
  '    head + Array(UInt8).new(16 - head.size - tail.size, 0_u8) + tail' '    head + tail'
prove_broken "inner and outer algorithms unchecked" "an outer algorithm that is not the inner one refused" \
  '    unless inner_algorithm.raw == outer_algorithm.raw' '    if false'
prove_broken "a duplicate extension taken" "an extension written twice refused" \
  '      return X509Error.new("extension #{oid} appears twice") if seen.includes?(oid)' ''
# Unchecked, the bad byte reaches std/base64, which panics: the refusal
# the check expects never comes.
prove_broken "PEM's base64 unchecked" "base64: invalid byte" \
  '      return X509Error.new("a #{label} block with byte #{b} in its base64, at #{i}") unless ok' ''
prove_broken "an Ed25519 key's parameters taken" "an Ed25519 key whose algorithm carries parameters refused" \
  '      return X509Error.new("an Ed25519 key with parameters, which RFC 8410 says are absent") unless algorithm.size == 1' ''
prove_broken "an Ed25519 signature unchecked" "an Ed25519 leaf signed by another key under the root's name: expected a refusal" \
  '      return nil if key.verify(@tbs, @signature)' '      return nil'
prove_broken "an Ed25519 signature's parameters taken" "an Ed25519 signature whose algorithm carries parameters: expected a refusal" \
  '    when X509Oids::ED25519
      return "#{@signature_algorithm} with parameters" unless @signature_parameters.nil?' '    when X509Oids::ED25519'
prove_broken "an Ed25519 key off the curve taken" "an Ed25519 key off the curve refused" \
  '    return CurveError.new("Ed25519: the public key is not a point on the curve, or not its canonical encoding") unless CurvePoint.decode(p)' '' curve25519

echo
if [ "$status" -eq 0 ]; then
  echo "the std/x509 exercise holds ($mutations breaks caught)"
else
  echo "the std/x509 exercise did not hold"
fi
exit $status
