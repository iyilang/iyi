#!/usr/bin/env bash
# Exercises `std/system_roots`.
#
#     bash bench/std_system_roots_exercise.sh
#
# The exercise reads the platform's own store - at least one root, each
# once - and the roots `$SSL_CERT_FILE` and `$SSL_CERT_DIR` name, over
# files it writes; this gate runs it plain and --release, holds the Linux
# store to the bundle Python's cryptography reads, shows an error value's
# sentence through `.or_panic`, and proves on broken copies of the module
# that the checks fail where they say. darwin's and Windows' stores are
# read by the exercise there; nothing on those two is an oracle for them.
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
for phrase in "== the platform's own store" "== roots named by \$SSL_CERT_FILE and \$SSL_CERT_DIR"; do
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
prove_broken "an unreadable block not counted" "a broken block counted 0 times" \
  '    if certificate.is_a?(X509Error)
      @unreadable = @unreadable + 1' '    if certificate.is_a?(X509Error)'
prove_broken "\$SSL_CERT_DIR passed over" "a file and a directory" \
  "      dirs.split(':').each { |dir| collected.read_directory(dir) unless dir.empty? } if dirs && !dirs.empty?" ''
prove_broken "an empty store answered as a store" "a bundle with no root refused" \
  '    return X509Error.new("no root certificates in #{where}") if @certificates.empty?' ''
# A bundle's certificates dropped: the platform's own store is the first
# to come back empty.
prove_broken "a bundle's certificates dropped" "no root certificates in" \
  '    blocks.each { |der| add(der) }' '    return'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/system_roots exercise holds ($mutations breaks caught)"
else
  echo "the std/system_roots exercise did not hold"
fi
exit $status
