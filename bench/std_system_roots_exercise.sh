#!/usr/bin/env bash
# Exercises `std/system_roots`.
#
#     bash bench/std_system_roots_exercise.sh
#
# The exercise reads the platform's own store - at least one root, each
# once - and the roots `$SSL_CERT_FILE` and `$SSL_CERT_DIR` name, over
# files it writes; this gate runs it plain and --release, holds the Linux
# store to the bundle Python's cryptography reads and the Windows store to
# what Python's ssl reads of it - each root's purposes and the Disallowed
# store - shows an error value's sentence through `.or_panic`, and proves
# on broken copies of the module that the checks fail where they say.
# darwin's store is read by the exercise there; nothing is an oracle for
# it.
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

# What Python's ssl reads of the Windows stores, for the exercise to hold
# the module to: `enum_certificates` answers each certificate with True,
# good for every purpose, or the purposes the store's property names -
# and, where there is no property, the ones the certificate's own
# extension names, which is std/x509's to judge and so is `either` here.
# A root the store holds twice is dropped if either copy is.
unset SYSTEM_ROOTS_ORACLE
windows=no
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) windows=yes ;;
esac
if [ "$windows" = yes ] && [ -n "$PY" ]; then
  if "$PY" - "$WORK/oracle.txt" <<'PY'
import hashlib, ssl, sys
SERVER, ANY = "1.3.6.1.5.5.7.3.1", "2.5.29.37.0"
EXTENSION = bytes([0x06, 0x03, 0x55, 0x1D, 0x25])   # id-ce-extKeyUsage, as DER
RANK = {"keep": 0, "either": 1, "drop": 2}
verdicts = {}
for der, encoding, trust in ssl.enum_certificates("ROOT"):
    if encoding != "x509_asn":
        continue
    if trust is True or SERVER in trust or ANY in trust:
        verdict = "keep"
    elif EXTENSION in der:
        verdict = "either"
    else:
        verdict = "drop"
    f = hashlib.sha256(der).hexdigest()
    if RANK[verdict] >= RANK[verdicts.get(f, "keep")]:
        verdicts[f] = verdict
distrusted = {hashlib.sha256(der).hexdigest() for der, encoding, _ in ssl.enum_certificates("Disallowed")
              if encoding == "x509_asn"}
with open(sys.argv[1], "w", encoding="ascii", newline="\n") as out:
    for f, verdict in sorted(verdicts.items()):
        out.write(f"{verdict} {f}\n")
    for f in sorted(distrusted):
        out.write(f"distrusted {f}\n")
PY
  then
    export SYSTEM_ROOTS_ORACLE="$WORK/oracle.txt"
  else
    echo "Python could not read the Windows stores"
    status=1
  fi
fi

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_system_roots_exercise.iyi" \
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

echo "== the std/system_roots exercise, plain build"
build_and_run "plain" roots-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/roots-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every system_roots section reported"
for phrase in "== the platform's own store" "== what the platform denies and what it restricts" "== the platform's store held to another reader of it" "== roots named by \$SSL_CERT_FILE and \$SSL_CERT_DIR"; do
  if ! grep -q "$phrase" "$WORK/roots-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" roots-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/roots-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== the Linux store held to the bundle Python reads"
case "$(uname -s)" in
  Linux) linux=yes ;;
  *) linux=no ;;
esac
if [ "$linux" = no ]; then
  echo "  not Linux: the platform's store is read by the exercise above, and nothing here is an oracle for it"
elif [ -z "$PY" ] || ! "$PY" -c 'from cryptography import x509' >/dev/null 2>&1; then
  echo "  no python cryptography here, so the store goes uncompared"
else
  env -u SSL_CERT_FILE -u SSL_CERT_DIR "$WORK/roots-release" fingerprints >"$WORK/ours.txt" 2>&1
  if ! "$PY" - "$WORK/ours.txt" <<'PY'
import hashlib, re, sys, warnings
warnings.simplefilter("ignore")
from cryptography import x509
from cryptography.hazmat.primitives import serialization
BUNDLES = ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/ca-bundle.pem",
           "/etc/pki/tls/cacert.pem", "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", "/etc/ssl/cert.pem"]
import os
bundle = next((b for b in BUNDLES if os.path.isfile(b)), None)
if bundle is None:
    print("  no bundle file here, so the store goes uncompared"); sys.exit(0)
text = open(bundle, encoding="ascii", errors="replace").read()
theirs = set()
for body in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", text, re.S):
    c = x509.load_pem_x509_certificate(body.encode())
    theirs.add(hashlib.sha256(c.public_bytes(serialization.Encoding.DER)).hexdigest())
lines = open(sys.argv[1]).read().splitlines()
unreadable = int(lines[-1].split()[1])
ours = set(lines[:-1])
if not ours <= theirs or len(theirs) - len(ours) != unreadable:
    print(f"  {bundle}: Python reads {len(theirs)} certificates, iyi {len(ours)} and {unreadable} unreadable;"
          f" {len(ours - theirs)} only iyi has, {len(theirs - ours)} only Python")
    sys.exit(1)
print(f"  {bundle}: the same {len(ours)} certificates Python reads, by SHA-256, {unreadable} unreadable")
PY
  then
    status=1
  fi
fi

echo
echo "== the Windows store held to what Python's ssl reads of it"
if [ "$windows" = no ]; then
  echo "  not Windows"
elif [ -z "${SYSTEM_ROOTS_ORACLE:-}" ]; then
  echo "  no python here, so the store goes uncompared"
elif ! grep -q "held to the oracle" "$WORK/roots-plain.out" 2>/dev/null \
  || ! grep -q "held to the oracle" "$WORK/roots-release.out" 2>/dev/null; then
  echo "  the exercise did not hold the store to the oracle"
  status=1
else
  grep "held to the oracle" "$WORK/roots-release.out" | sed 's/^ *held to the oracle:/  the roots Python keeps for a server, by SHA-256:/'
fi

echo
echo "== an error value's sentence, through .or_panic"
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/system_roots::{SystemRoots}
import std/env::{ENV}

ENV["SSL_CERT_FILE"] = ENV["REFUSE_EMPTY"]
SystemRoots.load.or_panic
puts "accepted"
IYI
printf 'no certificates\n' >"$WORK/empty.pem"
if REFUSE_EMPTY="$WORK/empty.pem" "$IYI" run "$WORK/refuse.iyi" >"$WORK/refuse.out" 2>&1; then
  echo "  a bundle with no certificate was accepted as a store"
  status=1
elif ! grep -qF "x509: no root certificates in \$SSL_CERT_FILE and \$SSL_CERT_DIR ($WORK/empty.pem)" "$WORK/refuse.out"; then
  echo "  an empty store was refused without saying why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
  status=1
else
  echo "  x509: no root certificates in \$SSL_CERT_FILE and \$SSL_CERT_DIR (.../empty.pem)"
fi

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
src = Path("$REPO/src/std/system_roots.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/system_roots.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_system_roots_exercise.iyi" >"$WORK/mut.out" 2>&1; then
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
prove_broken "a root kept as often as it is written" "a root written twice read 2 times" \
  '    return if @seen.has_key?(key) || @denied.has_key?(key)' '    return if @denied.has_key?(key)'
# Without the oracle, which the count answers to first on a machine whose
# own store holds a certificate std/x509 cannot read (a hosted Windows
# runner's has seven): there the roots the oracle keeps and this does not
# are allowed by that count, so a count of nothing fails that comparison
# before the broken block's own is reached.
SYSTEM_ROOTS_ORACLE= prove_broken "an unreadable block not counted" "a broken block counted 0 times" \
  '    if certificate.is_a?(X509Error)
      @unreadable = @unreadable + 1' '    if certificate.is_a?(X509Error)'
prove_broken "\$SSL_CERT_DIR passed over" "a file and a directory" \
  '      dirs.split(separator).each { |dir| collected.read_directory(dir) unless dir.empty? } if dirs && !dirs.empty?' ''
prove_broken "an empty store answered as a store" "a bundle with no root refused" \
  '    return X509Error.new("no root certificates in #{where}") if @certificates.empty?' ''
# A bundle's certificates dropped: the platform's own store is the first
# to come back empty.
prove_broken "a bundle's certificates dropped" "no root certificates in" \
  '    blocks.each { |der| add(der) }' '    return'
prove_broken "a denied root left where it was" "a denied root is dropped" \
  '    @certificates = @certificates.reject { |c| SystemRootsCollector.key(c.raw) == key }' ''
prove_broken "a denied root kept when met again" "a denied root is not kept after" \
  '    @denied[key] = true
    at = @seen[key]?' '    at = @seen[key]?'
prove_broken "a denied certificate not held as distrusted" "a denied certificate is distrusted once, and was 0 times" \
  '    @distrusted << der unless @listed.has_key?(key)' ''
prove_broken "a denied certificate held as often as it is denied" "a denied certificate is distrusted once, and was 2 times" \
  '    @distrusted << der unless @listed.has_key?(key)' '    @distrusted << der'
prove_broken "the distrusted left out of the answer" "the store answers what was denied" \
  '    SystemRoots.new(@certificates, @unreadable, where, @restricted, @distrusted)' '    SystemRoots.new(@certificates, @unreadable, where)'
prove_broken "a root restricted counted twice" "a root restricted twice counted 2 times" \
  '    @restricted = @restricted + 1 unless @limited.has_key?(key)' '    @restricted = @restricted + 1'
# The Windows reader's own lines: the oracle is what catches them, so they
# are proved where there is one.
if [ -n "${SYSTEM_ROOTS_ORACLE:-}" ]; then
  prove_broken "a root trusted whatever Windows keeps it for" "a root the platform keeps from server authentication is trusted" \
    '        if serves?(context)' '        if serves?(context) || true'
  prove_broken "a root with no purpose property left out" "a root the platform trusts for a server is missing" \
    'Pointer(Void).new(0_u64), pointerof(size)) == 0
        return LibKernel32.GetLastError == NOT_FOUND' 'Pointer(Void).new(0_u64), pointerof(size)) == 0
        return false'
  prove_broken "a root whose property names serverAuth left out" "a root the platform trusts for a server is missing" \
    '        return true if names?(identifier, SERVER_AUTH) || names?(identifier, ANY_USE)' '        return true if names?(identifier, ANY_USE)'
  prove_broken "a purpose read by its first bytes" "a root the platform keeps from server authentication is trusted" \
    '        return false unless text[i] == oid.to_unsafe[i]' '        return false unless i > 14 || text[i] == oid.to_unsafe[i]'
else
  echo "  no Windows oracle here, so the purpose property's four breaks are unmeasured"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/system_roots exercise holds ($mutations breaks caught)"
else
  echo "the std/system_roots exercise did not hold"
fi
exit $status
