#!/usr/bin/env bash
# Exercises `std/acme`, and the certificate requests and self-signed
# certificates std/x509 writes for it.
#
#     bash bench/std_acme_exercise.sh
#
# The exercise holds base64url to RFC 4648's values, the JWK thumbprint to
# RFC 7638's and RFC 8037's, the JWS signatures to RFC 7515 appendix A's
# and RFC 8037's (RS256 and EdDSA byte for byte, ES256 and ES384 as R ||
# S), the requests std/x509 writes read back field by field, the
# tls-alpn-01 certificate's extension, and a whole order against a server
# in the exercise that holds the client to RFC 8555; this gate runs it
# plain and --release, has OpenSSL (`openssl req -verify`) and Python's
# cryptography (`load_der_x509_csr`) read its requests, check its JWS
# signatures and read the tls-alpn-01 certificate's critical extension,
# makes a tls-alpn-01 handshake with Python's ssl, then - where Go is
# here to build it - runs whole orders against Let's Encrypt's Pebble by
# http-01, dns-01 (through pebble-challtestsrv) and tls-alpn-01, and has
# `openssl verify` check every chain it issued. Then `iyi doc`, the
# formatting, five targets, the artifacts, and broken copies of the
# modules, each caught at the check that names it.
#
# Where Pebble runs in CI: the Linux module-exercise shards, whose job
# sets Go up for it (`actions/setup-go`); darwin's and Windows' runners
# run it where their image puts `go` on the PATH, and say so where not.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# Windows answers `python3` with a store stub that prints and exits, so the
# interpreter is measured here instead of assumed.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

PIDS=""
cleanup() {
  for pid in $PIDS; do
    kill "$pid" >/dev/null 2>&1
    wait "$pid" >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_acme_exercise.iyi" \
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

echo "== the std/acme exercise, plain build"
build_and_run "plain" acme-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/acme-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every acme section reported"
for phrase in "== base64url without padding" "== JWK thumbprints" "== JWS signatures" "== certificate requests" \
  "== the tls-alpn-01 certificate" "== http-01's responder" "== a whole order against a server"; do
  if ! grep -q "$phrase" "$WORK/acme-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" acme-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/acme-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== requests, signatures and a certificate, read by OpenSSL and Python's cryptography"
mkdir -p "$WORK/art"
if ! "$WORK/acme-release" write "$WORK/art" >"$WORK/write.out" 2>&1; then
  echo "  FAIL: the artifacts were not written: $(tail -1 "$WORK/write.out")"
  status=1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "  no openssl here, so OpenSSL reads nothing"
else
  read_ok=0
  for kind in p256 p384 rsa ed25519; do
    if openssl req -inform DER -in "$WORK/art/csr-$kind.der" -verify -noout -text >"$WORK/req-$kind.txt" 2>&1 &&
      grep -q "verify OK" "$WORK/req-$kind.txt" && grep -q "DNS:www.iyi-acme.example, DNS:iyi-acme.example" "$WORK/req-$kind.txt" &&
      grep -q "Subject: CN *= *www.iyi-acme.example" "$WORK/req-$kind.txt"; then
      read_ok=$((read_ok + 1))
    else
      echo "  FAIL: openssl req -verify on the $kind request: $(tr -d '\r' <"$WORK/req-$kind.txt" | head -3)"
      status=1
    fi
  done
  echo "  openssl req -verify: $read_ok of 4 requests (P-256, P-384, RSA, Ed25519) verify OK, their subject and both names read"
  if openssl x509 -inform DER -in "$WORK/art/alpn.der" -noout -text >"$WORK/alpn.txt" 2>&1 &&
    grep -q "1.3.6.1.5.5.7.1.31: critical" "$WORK/alpn.txt" && grep -q "DNS:alpn.iyi-acme.example" "$WORK/alpn.txt"; then
    echo "  openssl x509: the tls-alpn-01 certificate carries 1.3.6.1.5.5.7.1.31, critical, and DNS:alpn.iyi-acme.example"
  else
    echo "  FAIL: openssl x509 on the tls-alpn-01 certificate: $(grep -m2 -E 'critical|DNS|rror' "$WORK/alpn.txt")"
    status=1
  fi
fi
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography import x509' >/dev/null 2>&1; then
  echo "  no python cryptography here, so the requests and signatures go unread by it"
elif ! "$PY" - "$WORK/art" <<'PY'
import hashlib, sys
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.x509.oid import NameOID
art = sys.argv[1]
bad = []
names = ["www.iyi-acme.example", "iyi-acme.example"]
for kind in ("p256", "p384", "rsa", "ed25519"):
    csr = x509.load_der_x509_csr(open(f"{art}/csr-{kind}.der", "rb").read())
    if not csr.is_signature_valid:
        bad.append(f"the {kind} request's signature is not valid")
    san = csr.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
    if san != names:
        bad.append(f"the {kind} request asks for {san}")
    cn = [a.value for a in csr.subject.get_attributes_for_oid(NameOID.COMMON_NAME)]
    if cn != [names[0]]:
        bad.append(f"the {kind} request's subject CN is {cn}")
want_input = b"eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ"
checked = []
for line in open(f"{art}/jws.txt"):
    alg, spki, data, sig = line.split()
    key = serialization.load_der_public_key(bytes.fromhex(spki))
    data, sig = bytes.fromhex(data), bytes.fromhex(sig)
    try:
        if alg in ("ES256", "ES384"):
            size = 32 if alg == "ES256" else 48
            if len(sig) != 2 * size:
                raise InvalidSignature(f"{len(sig)} bytes, not R || S")
            der = encode_dss_signature(int.from_bytes(sig[:size], "big"), int.from_bytes(sig[size:], "big"))
            key.verify(der, data, ec.ECDSA(hashes.SHA256() if alg == "ES256" else hashes.SHA384()))
        elif alg == "RS256":
            key.verify(sig, data, padding.PKCS1v15(), hashes.SHA256())
        else:
            key.verify(sig, data)
        checked.append(alg)
    except InvalidSignature as e:
        bad.append(f"{alg}: the signature does not verify ({e})")
    if alg == "ES256" and data[:len(want_input)] != want_input:
        bad.append("ES256: the signing input is not RFC 7515 A.3's")
cert = x509.load_der_x509_certificate(open(f"{art}/alpn.der", "rb").read())
domain, authorization = open(f"{art}/alpn.txt").read().split()
ext = cert.extensions.get_extension_for_oid(x509.ObjectIdentifier("1.3.6.1.5.5.7.1.31"))
if not ext.critical:
    bad.append("the acmeIdentifier extension is not critical")
if ext.value.value != b"\x04\x20" + hashlib.sha256(authorization.encode()).digest():
    bad.append("the acmeIdentifier extension does not hold the key authorization's SHA-256")
if cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName) != [domain]:
    bad.append("the tls-alpn-01 certificate does not name its domain alone")
try:
    cert.verify_directly_issued_by(cert)
except (ValueError, TypeError, InvalidSignature) as e:
    bad.append(f"the tls-alpn-01 certificate is not signed by its own key: {e}")
if bad:
    for b in bad:
        print(f"  FAIL: {b}")
    sys.exit(1)
print("  load_der_x509_csr: 4 requests (P-256, P-384, RSA, Ed25519), each signature valid, CN and both names read")
print(f"  JWS signatures verified by cryptography: {', '.join(checked)} (ES256 and ES384 as R || S, over RFC 7515 A.3's signing input)")
print("  the tls-alpn-01 certificate: acmeIdentifier critical, holding the key authorization's SHA-256; one dNSName; self-signed")
PY
then
  status=1
fi

echo
echo "== a tls-alpn-01 handshake, Python's ssl offering acme-tls/1"
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography import x509; import ssl' >/dev/null 2>&1; then
  echo "  no python with ssl and cryptography here, so no handshake is made"
else
  rm -f "$WORK/art/port"
  "$WORK/acme-release" alpn-serve "$WORK/art" >"$WORK/alpn-serve.out" 2>&1 &
  serve_pid=$!
  PIDS="$PIDS $serve_pid"
  if "$PY" - "$WORK/art" <<'PY'
import hashlib, os, socket, ssl, sys, time
from cryptography import x509
art = sys.argv[1]
for _ in range(300):
    if os.path.exists(f"{art}/port") and open(f"{art}/port").read().strip():
        break
    time.sleep(0.05)
port = int(open(f"{art}/port").read())
domain, authorization = open(f"{art}/alpn.txt").read().split()
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ctx.set_alpn_protocols(["acme-tls/1"])
with socket.create_connection(("127.0.0.1", port), timeout=15) as raw:
    with ctx.wrap_socket(raw, server_hostname=domain) as tls:
        chosen = tls.selected_alpn_protocol()
        cert = x509.load_der_x509_certificate(tls.getpeercert(binary_form=True))
ext = cert.extensions.get_extension_for_oid(x509.ObjectIdentifier("1.3.6.1.5.5.7.1.31"))
names = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
ok = chosen == "acme-tls/1" and ext.critical and ext.value.value == b"\x04\x20" + hashlib.sha256(authorization.encode()).digest() and names == [domain]
print(f"  Python's ssl: ALPN chose {chosen}, the certificate names {names}, acmeIdentifier critical and holding the digest: {ok}")
sys.exit(0 if ok else 1)
PY
  then
    wait "$serve_pid"
    if ! grep -q "alpn acme-tls/1" "$WORK/alpn-serve.out"; then
      echo "  FAIL: the server's side said: $(tr -d '\r' <"$WORK/alpn-serve.out" | tail -1)"
      status=1
    fi
  else
    echo "  FAIL: the handshake under acme-tls/1; the server said: $(tr -d '\r' <"$WORK/alpn-serve.out" | tail -1)"
    kill "$serve_pid" >/dev/null 2>&1
    status=1
  fi
fi

echo
echo "== whole orders against Let's Encrypt's Pebble"
# Pebble is Let's Encrypt's test ACME server (github.com/letsencrypt/pebble)
# and pebble-challtestsrv its DNS for the challenges: every name resolves
# to 127.0.0.1 and dns-01's TXT records are set through its management
# API's /set-txt. Built from source here with `go install ...@latest`.
# PEBBLE_VA_NOSLEEP takes out the validation's random sleep;
# PEBBLE_AUTHZREUSE=0 makes every order prove its names afresh, so all
# three challenges are answered; PEBBLE_WFE_NONCEREJECT=30 refuses 30% of
# good nonces with badNonce, which the client sends again - one run while
# this was written sent 24 again over five sessions' requests - and with
# ten tries again a request fails only if eleven refusals come in a row
# (0.3^11, about 2e-6 a request).
GO="${GO:-go}"
if [ -z "$PY" ] || ! command -v "$GO" >/dev/null 2>&1; then
  echo "  no Go here (or no python to drive it), so Pebble is not built and the orders go unplaced"
else
  GOBIN="$WORK/gobin"
  mkdir -p "$GOBIN"
  if ! GOBIN="$GOBIN" "$GO" install github.com/letsencrypt/pebble/v2/cmd/pebble@latest \
      github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@latest >"$WORK/go-install.log" 2>&1; then
    echo "  Pebble could not be fetched or built here (no network?), so the orders go unplaced: $(tail -1 "$WORK/go-install.log")"
  else
    # `go version -m` reads the binary by its file's name, which on
    # Windows ends in .exe; bash runs it by either.
    binary="$GOBIN/pebble"
    [ -f "$binary.exe" ] && binary="$binary.exe"
    version="$("$GO" version -m "$binary" 2>/dev/null | awk '$1 == "mod" && $2 == "github.com/letsencrypt/pebble/v2" { print $3 }')"
    certs="$("$GO" env GOMODCACHE)/github.com/letsencrypt/pebble/v2@$version/test/certs"
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN* | Windows_NT) certs="$(cygpath -m "$certs")" ;;
    esac
    mkdir -p "$WORK/pebble"
    # Six free ports, each held open until all six are drawn so none is
    # drawn twice; Pebble's config and the exercise's arguments from them.
    if ! "$PY" - "$WORK/pebble" "$certs" <<'PY'
import json, socket, sys
out, certs = sys.argv[1], sys.argv[2]
held = []
for _ in range(6):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    held.append(s)
ports = [s.getsockname()[1] for s in held]
for s in held:
    s.close()
acme, management, http01, tlsalpn, dns, chall = ports
json.dump({"pebble": {"listenAddress": f"127.0.0.1:{acme}", "managementListenAddress": f"127.0.0.1:{management}",
    "certificate": f"{certs}/localhost/cert.pem", "privateKey": f"{certs}/localhost/key.pem",
    "httpPort": http01, "tlsPort": tlsalpn, "ocspResponderURL": "", "externalAccountBindingRequired": False,
    "domainBlocklist": ["blocked.example"], "retryAfter": {"authz": 1, "order": 1}, "keyAlgorithm": "ecdsa"}},
    open(f"{out}/config.json", "w", newline="\n"))
open(f"{out}/ports", "w", newline="\n").write(" ".join(str(p) for p in ports) + "\n")
PY
    then
      echo "  FAIL: no ports for Pebble"
      status=1
    else
      read -r P_ACME P_MANAGEMENT P_HTTP P_TLS P_DNS P_CHALL <"$WORK/pebble/ports"
      "$GOBIN/pebble-challtestsrv" -defaultIPv4 127.0.0.1 -defaultIPv6 "" -dnsserver "127.0.0.1:$P_DNS" \
        -management "127.0.0.1:$P_CHALL" -http01 "" -https01 "" -tlsalpn01 "" -doh "" >"$WORK/pebble/challtestsrv.log" 2>&1 &
      PIDS="$PIDS $!"
      PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=30 PEBBLE_AUTHZREUSE=0 "$GOBIN/pebble" -config "$WORK/pebble/config.json" \
        -dnsserver "127.0.0.1:$P_DNS" >"$WORK/pebble/pebble.log" 2>&1 &
      PIDS="$PIDS $!"
      if ! "$PY" - "$P_ACME" "$P_CHALL" "$certs/pebble.minica.pem" <<'PY'
import socket, ssl, sys, time, urllib.request
acme, chall, minica = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ctx = ssl.create_default_context(cafile=minica)
deadline = time.time() + 30
while time.time() < deadline:
    try:
        urllib.request.urlopen(f"https://localhost:{acme}/dir", context=ctx, timeout=2).read()
        socket.create_connection(("127.0.0.1", chall), timeout=2).close()
        sys.exit(0)
    except OSError:
        time.sleep(0.2)
sys.exit(1)
PY
      then
        echo "  FAIL: Pebble or challtestsrv did not come up in 30 s:"
        tail -3 "$WORK/pebble/pebble.log" "$WORK/pebble/challtestsrv.log" | sed 's/^/    /'
        status=1
      else
        # Two RSA keys: one an RS256 account's, one a certificate's.
        "$PY" - "$WORK/pebble" <<'PY'
import sys
from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric import rsa
for name in ("rsa-account.pem", "rsa-domain.pem"):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    open(f"{sys.argv[1]}/{name}", "wb").write(key.private_bytes(s.Encoding.PEM, s.PrivateFormat.PKCS8, s.NoEncryption()))
PY
        mkdir -p "$WORK/pebble/out"
        bounded=""
        command -v timeout >/dev/null 2>&1 && bounded="timeout 300"
        $bounded "$WORK/acme-release" pebble "https://localhost:$P_ACME/dir" "$certs/pebble.minica.pem" "https://localhost:$P_MANAGEMENT" \
          "http://127.0.0.1:$P_CHALL" "$P_HTTP" "$P_TLS" "$WORK/pebble/out" 30 \
          "$WORK/pebble/rsa-account.pem" "$WORK/pebble/rsa-domain.pem" >"$WORK/pebble/run.out" 2>&1
        code=$?
        tr -d '\r' <"$WORK/pebble/run.out" | sed 's/^/  /'
        if [ "$code" -ne 0 ] || ! grep -q "PEBBLE HELD" "$WORK/pebble/run.out"; then
          echo "  FAIL: the orders against Pebble exited $code"
          tail -5 "$WORK/pebble/pebble.log" | sed 's/^/    pebble: /'
          status=1
        elif ! command -v openssl >/dev/null 2>&1; then
          echo "  no openssl here, so the chains go unverified by it"
        else
          verified=0
          for chain in "$WORK"/pebble/out/*.iyi-acme.example.pem; do
            domain="$(basename "$chain" .pem)"
            "$PY" - "$chain" "$WORK/pebble/leaf.pem" "$WORK/pebble/rest.pem" <<'PY'
import re, sys
blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?", open(sys.argv[1]).read(), re.S)
open(sys.argv[2], "w", newline="\n").write(blocks[0])
open(sys.argv[3], "w", newline="\n").write("".join(blocks[1:]))
PY
            if openssl verify -CAfile "$WORK/pebble/out/root.pem" -untrusted "$WORK/pebble/rest.pem" -verify_hostname "$domain" \
                -purpose sslserver "$WORK/pebble/leaf.pem" >"$WORK/pebble/verify.txt" 2>&1; then
              verified=$((verified + 1))
            else
              echo "  FAIL: openssl verify, $domain: $(tr -d '\r' <"$WORK/pebble/verify.txt" | tail -2)"
              status=1
            fi
          done
          if [ "$verified" -ge 5 ]; then
            echo "  openssl verify: $verified chains to Pebble's root, each for its name and for a server"
          else
            echo "  FAIL: openssl verify checked $verified chains, not the five issued"
            status=1
          fi
        fi
      fi
    fi
  fi
fi

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/acme.iyi" >"$WORK/doc.txt" 2>&1 && grep -q "wait_authorization" "$WORK/doc.txt"; then
  echo "  iyi doc reads std/acme, AcmeClient's waits included"
else
  echo "  FAIL: iyi doc: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/acme.iyi" "$REPO/src/std/x509.iyi" "$REPO/bench/std_acme_exercise.iyi" >"$WORK/format.log" 2>&1; then
  echo "  the module, std/x509 and the exercise are formatted"
else
  echo "  FAIL: not formatted: $(grep -m1 produced "$WORK/format.log")"
  status=1
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_acme_exercise.iyi" >"$WORK/cross.log" 2>&1; then
    echo "  $target: $(grep -m1 -E 'Error|BUG' "$WORK/cross.log")"
    apart="$apart $target"
  fi
done
if [ -n "$apart" ]; then
  echo "  FAIL: does not typecheck for$apart"
  status=1
else
  echo "  the exercise typechecks for x86_64-linux-gnu, aarch64-darwin, x86_64-windows-msvc, aarch64-linux-gnu, x86_64-linux-musl"
fi
mkdir -p "$WORK/r1"
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_acme_exercise.iyi" &&
  "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_acme_exercise.iyi") >"$WORK/r1/build.log" 2>&1; then
  "$WORK/r1/from-artifact" >"$WORK/r1/artifact.out" 2>&1
  if grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out" && cmp -s "$WORK/acme-plain.out" "$WORK/r1/artifact.out"; then
    echo "  built from its artifacts, the exercise prints what it prints from source"
  else
    echo "  FAIL: from its artifacts the exercise prints otherwise:"
    diff "$WORK/acme-plain.out" "$WORK/r1/artifact.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
else
  echo "  FAIL: the artifacts did not build: $(grep -m1 -E 'Error|BUG' "$WORK/r1/build.log")"
  status=1
fi

echo
echo "== proving the checks can fail when the modules are broken"
# prove_broken <module> <label> <phrase> <old> <new>: the exercise must
# fail on a copy of std/<module> with <old> replaced, at the check that
# names <phrase>.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $2 proof is unmeasured"
    return
  fi
  if ! OLD="$4" NEW="$5" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/$1.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/$1.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8", newline="\n")
PY
  then
    echo "  the $2 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_acme_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $2"
    status=1
  elif grep -qF -e "$3" "$WORK/mut.out"; then
    echo "  $2 is caught"
  else
    echo "  $2 failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken acme "a nonce reused" "each nonce used once" \
  '      @nonce = response.nonce' '      @nonce = nonce'
prove_broken acme "the thumbprint over non-canonical JSON" "RFC 7638's thumbprint" \
  '"{\"e\":\"#{b64u(AcmeJws.minimal(key.exponent.to_bytes(4) || [] of UInt8))}\",\"kty\":\"RSA\",\"n\":\"#{b64u(n)}\"}"' \
  '"{\"kty\":\"RSA\",\"n\":\"#{b64u(n)}\",\"e\":\"#{b64u(AcmeJws.minimal(key.exponent.to_bytes(4) || [] of UInt8))}\"}"'
prove_broken acme "an ECDSA signature sent as DER, not R || S" "an ES256 signature is R || S" \
  '    raw(signed, public.curve.size)' '    signed'
prove_broken acme "a jwk where the kid belongs" "jwk for newAccount alone and kid after it" \
  '      use_jwk = url == @directory.new_account' '      use_jwk = true'
prove_broken acme "Retry-After ignored" "Retry-After: 2 honoured" \
  '      wait = AcmeClient.delay(response.retry_after, @poll_ms, Time.utc)' '      wait = @poll_ms.to_i64'
prove_broken acme "a problem document taken as success" "a problem document is an error naming its type and detail" \
  '    return nil if @status < 400' '    return nil if @status < 600'
prove_broken x509 "the CSR signed by another key" "the CSR's signature verifies under its own key" \
  '    X509Der.sequence([info, key.algorithm_identifier, X509Der.bit_string(key.sign(info))])' \
  '    X509Der.sequence([info, key.algorithm_identifier, X509Der.bit_string(SigningKey.p256.sign(info))])'
prove_broken acme "a badNonce answer not sent again" "a badNonce answer is sent again" \
  '  MAX_BAD_NONCE = 10' '  MAX_BAD_NONCE = 0'
prove_broken acme "a wait past max_polls" "a wait stops at max_polls" \
  'if polls >= @max_polls' 'if polls >= @max_polls * 10'
prove_broken acme "POST-as-GET sent with {}" "POST-as-GET's payload empty" \
  '    body = payload ? b64u(payload) : ""' '    body = b64u(payload || "{}")'
prove_broken acme "the key authorization without its thumbprint" "the key authorization is token.thumbprint" \
  '"#{token}.#{@thumbprint}"' '"#{token}"'
prove_broken acme "the acmeIdentifier extension not critical" "the acmeIdentifier extension is critical" \
  'X509Extension.new(ACME_IDENTIFIER, true, value)' 'X509Extension.new(ACME_IDENTIFIER, false, value)'
prove_broken x509 "a request without its extensionRequest" "by subjectAltName" \
  '      X509Der.tlv(0xA0_u8, attribute),' '      X509Der.tlv(0xA0_u8, [] of UInt8),'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/acme exercise holds ($mutations breaks caught)"
else
  echo "the std/acme exercise did not hold"
fi
exit $status
