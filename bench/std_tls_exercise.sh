#!/usr/bin/env bash
# Exercises `std/tls`.
#
#     bash bench/std_tls_exercise.sh
#
# The exercise holds RFC 8448's simple 1-RTT trace byte for byte through
# the key schedule and the record protection; this gate runs it plain and
# --release, then runs every scenario of bench/std_tls_server.py - a TLS
# 1.3 server written over Python's cryptography that breaks the protocol
# one rule at a time - against the client, connects to OpenSSL's own
# s_server across its suites, key types, a HelloRetryRequest, a request
# for a client certificate and ALPN. Then the server: its configurations
# judged, and the exercise serving - on an Ed25519 key, then a P-256 one -
# bench/std_tls_client.py, the scripted client's every scenario, a
# handshake checked step by step or one rule broken and the alert named;
# the std/tls client, Python's ssl, OpenSSL's s_client, curl and Node. It
# shows an error value's sentence through `.or_panic`, and proves on
# broken copies of the module that the checks fail where they say, the
# handshake's own against the scripted peers.
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

SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_tls_exercise.iyi" \
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

echo "== the std/tls exercise, plain build"
build_and_run "plain" tls-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/tls-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every tls section reported"
for phrase in "== RFC 8448's simple 1-RTT handshake, through the key schedule" "== the trace's records, sealed and opened"; do
  if ! grep -q "$phrase" "$WORK/tls-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" tls-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/tls-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== every scenario of the scripted server"
# The server runs for the rest of the gate: the failure proofs below hold
# the handshake's own checks against it too.
SERVER_DIR="$WORK/server"
mkdir -p "$SERVER_DIR"
scripted=no
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import x25519' >/dev/null 2>&1; then
  echo "  no python cryptography here, so there is no scripted server to hold the handshake to"
else
  "$PY" "$REPO/bench/std_tls_server.py" "$SERVER_DIR" >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 120); do
    [ -s "$SERVER_DIR/port" ] && break
    sleep 0.5
  done
  if [ ! -s "$SERVER_DIR/port" ]; then
    echo "  the scripted server did not start:"
    sed 's/^/    /' "$WORK/server.log" | head -5
    status=1
  else
    scripted=yes
    if ! "$WORK/tls-release" scenarios "$SERVER_DIR" >"$WORK/scenarios.out" 2>&1; then
      sed 's/^/  /' "$WORK/scenarios.out" | tail -3
      status=1
    else
      cat "$WORK/scenarios.out"
    fi
  fi
fi

echo
echo "== OpenSSL's own server"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) windows=yes ;;
  *) windows=no ;;
esac
# OpenSSL itself: macOS's `openssl` is LibreSSL, whose `req -x509` adds its
# configuration's own `v3_ca` to the extensions asked for - a CA with two
# basicConstraints, which x509 rightly refuses - so Homebrew's OpenSSL 3
# is asked where it is installed. And every certificate is made from a
# configuration written here, so its extensions are the ones below and
# no library's defaults.
OPENSSL=openssl
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if [ -x "$candidate" ]; then
    OPENSSL="$candidate"
    break
  fi
done
if [ "$windows" = yes ] || ! command -v "$OPENSSL" >/dev/null 2>&1 || [ -z "$PY" ]; then
  echo "  no openssl and python here (or Windows, whose s_server this gate does not drive), so OpenSSL goes unasked"
else
  echo "  $("$OPENSSL" version)"
  PKI="$WORK/pki"
  mkdir -p "$PKI"
  (
    cd "$PKI" || exit 1
    printf '[ req ]\ndistinguished_name = dn\nprompt = no\n[ dn ]\nCN = Interop-Root\n[ ca ]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign\n' >ca.cnf
    printf '[ req ]\ndistinguished_name = dn\nprompt = no\n[ dn ]\nCN = localhost\n' >leaf.cnf
    "$OPENSSL" req -x509 -config ca.cnf -extensions ca -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout ca.key -out ca.pem -days 30
    printf 'subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' >leaf.ext
    for kind in p256 p384 rsa ed25519; do
      case $kind in
        p256) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-256" ;;
        p384) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-384" ;;
        rsa) opt="-newkey rsa:2048" ;;
        ed25519) opt="-newkey ed25519" ;;
      esac
      # shellcheck disable=SC2086
      "$OPENSSL" req -new -config leaf.cnf $opt -nodes -keyout $kind.key -out $kind.csr &&
        "$OPENSSL" x509 -req -in $kind.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $kind.pem -days 20 -extfile leaf.ext
    done
    # Client certificates, for clientAuth, as std/tls presents them.
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' >client.ext
    for kind in p256 ed25519; do
      case $kind in
        p256) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-256" ;;
        ed25519) opt="-newkey ed25519" ;;
      esac
      # shellcheck disable=SC2086
      "$OPENSSL" req -new -config leaf.cnf $opt -nodes -keyout client-$kind.key -out client-$kind.csr &&
        "$OPENSSL" x509 -req -in client-$kind.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out client-$kind.pem -days 20 -extfile client.ext
    done
  ) >"$WORK/pki.log" 2>&1
  interop=0
  # interop <label> <expected phrase> <host> <alpn or -> <s_server args...>;
  # the std/tls client presents `identity`'s chain and key, when set.
  identity=()
  interop() {
    local label="$1" want="$2" host="$3" alpn="$4" port pid got
    shift 4
    port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    "$OPENSSL" s_server -accept "127.0.0.1:$port" -www "$@" >"$WORK/s_server.log" 2>&1 </dev/null &
    pid=$!
    for _ in $(seq 1 50); do
      "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
      sleep 0.1
    done
    got="$("$WORK/tls-release" get "$port" "$PKI/ca.pem" "$host" "$alpn" ${identity[@]+"${identity[@]}"} 2>&1)"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if printf '%s' "$got" | grep -qF -e "$want"; then
      interop=$((interop + 1))
      echo "  $label: $got"
    else
      echo "  $label: expected \"$want\", got: $got"
      status=1
    fi
  }
  cd "$PKI" || exit 1
  interop "P-256, the default suites" "HTTP/1.0 200 ok TLS_AES_128_GCM_SHA256" localhost - -tls1_3 -cert p256.pem -key p256.key
  interop "P-384" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert p384.pem -key p384.key
  interop "RSA, CertificateVerify under RSASSA-PSS" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert rsa.pem -key rsa.key
  interop "Ed25519, CertificateVerify under ed25519" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert ed25519.pem -key ed25519.key
  interop "AES-256-GCM alone" "HTTP/1.0 200 ok TLS_AES_256_GCM_SHA384" localhost - -tls1_3 -cert p256.pem -key p256.key -ciphersuites TLS_AES_256_GCM_SHA384
  interop "ChaCha20-Poly1305 alone" "HTTP/1.0 200 ok TLS_CHACHA20_POLY1305_SHA256" localhost - -tls1_3 -cert p256.pem -key p256.key -ciphersuites TLS_CHACHA20_POLY1305_SHA256
  interop "stateless, so a HelloRetryRequest with a cookie" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert p256.pem -key p256.key -stateless
  interop "a client certificate asked for" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert p256.pem -key p256.key -verify 1
  interop "ALPN" "alpn=http/1.1" localhost http/1.1 -tls1_3 -cert p256.pem -key p256.key -alpn http/1.1
  interop "a host the certificate does not name" "is not valid for example.com" example.com - -tls1_3 -cert p256.pem -key p256.key
  interop "TLS 1.2 alone" "alert protocol_version (70)" localhost - -tls1_2 -cert p256.pem -key p256.key
  interop "groups without X25519" "alert handshake_failure (40)" localhost - -tls1_3 -cert p256.pem -key p256.key -groups P-256
  # A client certificate required and checked: -verify_return_error ends
  # the handshake on any fault OpenSSL finds in the chain or its signature.
  mtls=(-tls1_3 -cert p256.pem -key p256.key -Verify 1 -verify_return_error -CAfile ca.pem)
  interop "a client certificate required, none held" "alert certificate_required (116)" localhost - "${mtls[@]}"
  identity=(client-p256.pem client-p256.key)
  interop "a client certificate required, a P-256 one presented" "HTTP/1.0 200 ok" localhost - "${mtls[@]}"
  identity=(client-ed25519.pem client-ed25519.key)
  interop "a client certificate required, an Ed25519 one presented" "HTTP/1.0 200 ok" localhost - "${mtls[@]}"
  interop "a request naming ecdsa_secp256r1_sha256 alone, an Ed25519 one held back" "alert certificate_required (116)" \
    localhost - "${mtls[@]}" -client_sigalgs ECDSA+SHA256
  identity=()
  cd "$REPO" || exit 1
  echo "  $interop answers from OpenSSL as they should be"
fi

echo
echo "== the server: TlsServer against a scripted client and real ones"
# An Ed25519 leaf under a P-256 root, made here, and keys that are not a
# server's: TlsServerConfig must refuse each for its reason. Then the
# exercise's `serve` mode, one connection at a time, against
# bench/std_tls_client.py - every scenario a correct handshake or one rule
# broken, each answered with the alert RFC 8446 names - and against
# clients that are not this one's: the std/tls client, Python's ssl,
# OpenSSL's s_client across suites, a HelloRetryRequest and refusals,
# curl, and Node.
SRV="$WORK/srv"
mkdir -p "$SRV"
served=no
if [ -z "$PY" ] || ! "$PY" -c 'from cryptography.hazmat.primitives.asymmetric import ed25519, x25519' >/dev/null 2>&1; then
  echo "  no python cryptography here, so the server goes unasked"
else
  "$PY" - "$SRV" <<'PY'
import datetime as dt, os, sys
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
out = sys.argv[1]
now = dt.datetime.now(dt.timezone.utc)
def name(cn): return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
def write(file, data): open(os.path.join(out, file), "wb").write(data)
def pem(c): return c.public_bytes(serialization.Encoding.PEM)
def pkcs8(k): return k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
def raw(k): return k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
def der_pem(der):
    import base64
    text = base64.b64encode(der).decode()
    return ("-----BEGIN PRIVATE KEY-----\n" + "\n".join(text[i:i + 64] for i in range(0, len(text), 64)) + "\n-----END PRIVATE KEY-----\n").encode()
def tlv(tag, content):
    n = len(content)
    return bytes([tag]) + (bytes([n]) if n < 128 else bytes([0x81, n])) + content
root_key = ec.generate_private_key(ec.SECP256R1())
root = (x509.CertificateBuilder().subject_name(name("Gate Root")).issuer_name(name("Gate Root"))
        .public_key(root_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()), critical=False)
        .sign(root_key, hashes.SHA256()))
def leaf_for(key):
    return (x509.CertificateBuilder().subject_name(name("localhost")).issuer_name(root.subject)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=20))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), critical=False)
            .sign(root_key, hashes.SHA256()))
key = ed25519.Ed25519PrivateKey.generate()
other = ed25519.Ed25519PrivateKey.generate()
ec_key = ec.generate_private_key(ec.SECP256R1())
write("chain.pem", pem(leaf_for(key)) + pem(root))
write("roots.pem", pem(root))
write("key.pem", pkcs8(key))
write("leaf.pem", pem(leaf_for(key)))
write("other.key", pkcs8(other))
write("p256.pem", pem(leaf_for(ec_key)) + pem(root))
write("ec.key", pkcs8(ec_key))
write("two.key", pkcs8(key) + pkcs8(other))
seed = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
algorithm = bytes.fromhex("300506032b6570")
inner = tlv(0x04, tlv(0x04, seed))
write("v2.key", der_pem(tlv(0x30, bytes.fromhex("020101") + algorithm + inner + tlv(0x81, b"\x00" + raw(key)))))
write("v2-wrong.key", der_pem(tlv(0x30, bytes.fromhex("020101") + algorithm + inner + tlv(0x81, b"\x00" + raw(other)))))
write("v0-public.key", der_pem(tlv(0x30, bytes.fromhex("020100") + algorithm + inner + tlv(0x81, b"\x00" + raw(key)))))
write("params.key", der_pem(tlv(0x30, bytes.fromhex("020100") + bytes.fromhex("300706032b65700500") + inner)))
# The same server on P-256: its chain, its key as PKCS #8 and as SEC 1;
# a P-384 key, and a P-256 key that is not the leaf's.
os.makedirs(os.path.join(out, "p256"), exist_ok=True)
write("p256/chain.pem", pem(leaf_for(ec_key)) + pem(root))
write("p256/key.pem", pkcs8(ec_key))
write("ec-sec1.key", ec_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
write("p384.key", pkcs8(ec.generate_private_key(ec.SECP384R1())))
write("other-ec.key", pkcs8(ec.generate_private_key(ec.SECP256R1())))
# The same Ed25519 server asking for a client's certificate under its own
# root: certificates from it for clientAuth (P-256 and Ed25519), one from
# another root, and one for serverAuth alone.
os.makedirs(os.path.join(out, "mtls"), exist_ok=True)
write("mtls/chain.pem", pem(leaf_for(key)) + pem(root))
write("mtls/key.pem", pkcs8(key))
def client_root(cn):
    k = ec.generate_private_key(ec.SECP256R1())
    c = (x509.CertificateBuilder().subject_name(name(cn)).issuer_name(name(cn)).public_key(k.public_key())
         .serial_number(x509.random_serial_number()).not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=30))
         .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
         .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
         .add_extension(x509.SubjectKeyIdentifier.from_public_key(k.public_key()), critical=False)
         .sign(k, hashes.SHA256()))
    return c, k
def client_leaf(cn, k, issuer, issuer_key, usage):
    return (x509.CertificateBuilder().subject_name(name(cn)).issuer_name(issuer.subject).public_key(k.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=20))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
            .add_extension(x509.ExtendedKeyUsage([usage]), critical=False)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(k.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()), critical=False)
            .sign(issuer_key, hashes.SHA256()))
client_ca, client_ca_key = client_root("Client CA")
other_ca, other_ca_key = client_root("Other CA")
write("mtls/client-roots.pem", pem(client_ca))
for who, cn, k, issuer, issuer_key, usage in [
        ("client", "client", ec.generate_private_key(ec.SECP256R1()), client_ca, client_ca_key, ExtendedKeyUsageOID.CLIENT_AUTH),
        ("client-ed", "client ed", ed25519.Ed25519PrivateKey.generate(), client_ca, client_ca_key, ExtendedKeyUsageOID.CLIENT_AUTH),
        ("other", "client", ec.generate_private_key(ec.SECP256R1()), other_ca, other_ca_key, ExtendedKeyUsageOID.CLIENT_AUTH),
        ("server-only", "client", ec.generate_private_key(ec.SECP256R1()), client_ca, client_ca_key, ExtendedKeyUsageOID.SERVER_AUTH)]:
    write("mtls/" + who + ".pem", pem(client_leaf(cn, k, issuer, issuer_key, usage)) + pem(issuer))
    write("mtls/" + who + ".key", pkcs8(k))
PY
  # The configurations, judged by the binary given: each line the files,
  # what must be said.
  cat >"$WORK/server-configs.sh" <<'SH'
bin="$1"; dir="$2"; failed=0
check() {
  local label="$1" chain="$2" key="$3" want="$4" got
  got="$("$bin" config "$dir/$chain" "$dir/$key" 2>&1)"
  if printf '%s' "$got" | grep -qF -e "$want"; then
    echo "  $label: $got"
  else
    echo "  FAIL $label: expected \"$want\", got: $got"
    failed=1
  fi
}
check "a chain and its key" chain.pem key.pem "config: 2 certificates, leaf CN=localhost"
check "a version 2 key with its public key" chain.pem v2.key "config: 2 certificates"
check "another key" chain.pem other.key "the private key is not the certificate's"
check "a P-256 certificate" p256.pem key.pem "the certificate's key is not Ed25519"
check "a P-256 key for an Ed25519 certificate" chain.pem ec.key "the certificate's key is not P-256, as the private key is"
check "two keys" chain.pem two.key "2 blocks of PRIVATE KEY or EC PRIVATE KEY, not one"
check "no key" chain.pem chain.pem "0 blocks of PRIVATE KEY or EC PRIVATE KEY, not one"
check "no certificate" key.pem key.pem "the certificates: none"
check "a version 2 key carrying another public key" chain.pem v2-wrong.key "its public key is not the seed's"
check "a version 1 key carrying a public key" chain.pem v0-public.key "a public key in version 0"
check "an Ed25519 algorithm with parameters" chain.pem params.key "an Ed25519 algorithm with parameters"
check "a P-256 chain and its PKCS #8 key" p256.pem ec.key "config: 2 certificates, leaf CN=localhost"
check "a P-256 chain and its SEC 1 key" p256.pem ec-sec1.key "config: 2 certificates, leaf CN=localhost"
check "another P-256 key" p256.pem other-ec.key "the private key is not the certificate's"
check "a P-384 key" p256.pem p384.key "the private key is on 1.3.132.0.34, not prime256v1"
exit $failed
SH
  if ! bash "$WORK/server-configs.sh" "$WORK/tls-release" "$SRV"; then
    status=1
  fi
  # served <label> <expected phrase> <command...>: the command's output
  # must hold the phrase; when it does not, the server's own last word
  # (SERVE_LOG) says whether it refused, and why.
  served_ok=0
  SERVE_LOG=
  served_check() {
    local label="$1" want="$2" got
    shift 2
    got="$("$@" 2>&1 | tr -d '\r')"
    if printf '%s' "$got" | grep -qF -e "$want"; then
      served_ok=$((served_ok + 1))
      echo "  $label: $(printf '%s' "$got" | grep -F -e "$want" | head -1)"
    else
      echo "  $label: expected \"$want\", got: $(printf '%s' "$got" | tail -3)"
      [ -n "$SERVE_LOG" ] && echo "    the server said: $(tail -1 "$SERVE_LOG")"
      status=1
    fi
  }
  # serve_and_ask <dir> <ed25519|p256>: the exercise serving the chain and
  # key in <dir>, the scripted client and the others against it.
  serve_and_ask() {
    local dir="$1" kind="$2" port
    "$WORK/tls-release" serve "$dir" 1000 >"$WORK/serve-$kind.log" 2>&1 &
    SERVE_PID=$!
    SERVE_LOG="$WORK/serve-$kind.log"
    for _ in $(seq 1 100); do
      [ -s "$dir/port" ] && break
      sleep 0.1
    done
    if [ ! -s "$dir/port" ]; then
      echo "  the $kind server did not start:"
      sed 's/^/    /' "$WORK/serve-$kind.log" | head -5
      status=1
      return
    fi
    served=yes
    port="$(cat "$dir/port")"
    local flag=()
    [ "$kind" = p256 ] && flag=(--p256)
    if "$PY" "$REPO/bench/std_tls_client.py" "$port" "$SRV/roots.pem" ${flag[@]+"${flag[@]}"} >"$WORK/client-$kind.out" 2>&1; then
      echo "  the scripted client, $kind: $(tail -1 "$WORK/client-$kind.out")"
    else
      grep -F "FAIL" "$WORK/client-$kind.out" | sed 's/^/  /'
      tail -1 "$WORK/client-$kind.out" | sed 's/^/  /'
      status=1
    fi
    served_check "the std/tls client, $kind, ALPN h2" "HTTP/1.0 200 ok TLS_AES_128_GCM_SHA256 alpn=h2" \
      "$WORK/tls-release" get "$port" "$SRV/roots.pem" localhost h2
    served_check "the std/tls client, $kind, for a name the certificate does not hold" "is not valid for example.com" \
      "$WORK/tls-release" get "$port" "$SRV/roots.pem" example.com
    served_check "Python's ssl, $kind" "TLSv1.3 http/1.1 name=localhost alpn=http/1.1" "$PY" -c '
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
ctx.set_alpn_protocols(["http/1.1"])
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost") as s:
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    print(s.version(), s.selected_alpn_protocol(), data.decode().split("\r\n\r\n")[1].strip())
' "$port" "$SRV/roots.pem"
    if [ "$windows" = no ] && command -v "$OPENSSL" >/dev/null 2>&1; then
      # -ign_eof: the request's end on stdin is not the end of the answer.
      sclient() {
        printf 'GET / HTTP/1.0\r\n\r\n' | "$OPENSSL" s_client -connect "127.0.0.1:$port" -servername localhost \
          -CAfile "$SRV/roots.pem" -verify_return_error -ign_eof "$@" 2>&1
      }
      served_check "OpenSSL, $kind, AES-128-GCM" "name=localhost alpn=- TLS_AES_128_GCM_SHA256" sclient -tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256
      served_check "OpenSSL, $kind, AES-256-GCM" "name=localhost alpn=- TLS_AES_256_GCM_SHA384" sclient -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384
      served_check "OpenSSL, $kind, ChaCha20-Poly1305" "name=localhost alpn=- TLS_CHACHA20_POLY1305_SHA256" sclient -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256
      served_check "OpenSSL, $kind, ALPN" "name=localhost alpn=h2" sclient -tls1_3 -alpn h2,http/1.1
      hrr() { sclient -tls1_3 -groups "$1" -msg | grep -c '<<< TLS 1.3, Handshake \[length [0-9a-f]*\], ServerHello'; }
      served_check "OpenSSL, $kind, a P-384 share first: a HelloRetryRequest for X25519, then a ServerHello" "2" hrr P-384:X25519
      served_check "OpenSSL, $kind, P-384 and P-256, a P-384 share: a HelloRetryRequest for secp256r1" "2" hrr P-384:P-256
      served_check "OpenSSL, $kind, secp256r1 alone" "name=localhost alpn=-" sclient -tls1_3 -groups P-256
      # Refusals by the alert's number, which every OpenSSL prints the same;
      # its name is worded differently from one version to the next.
      served_check "OpenSSL, $kind, TLS 1.2 alone" "SSL alert number 70" sclient -tls1_2
      served_check "OpenSSL, $kind, groups without X25519 or secp256r1" "SSL alert number 40" sclient -tls1_3 -groups P-384
      if [ "$kind" = p256 ]; then
        served_check "OpenSSL, p256, ecdsa_secp256r1_sha256 alone" "name=localhost alpn=-" sclient -tls1_3 -sigalgs ECDSA+SHA256
        served_check "OpenSSL, p256, no ecdsa_secp256r1_sha256 among its signature algorithms" "SSL alert number 40" sclient -tls1_3 -sigalgs ed25519:RSA-PSS+SHA256
      else
        served_check "OpenSSL, ed25519, ed25519 alone" "name=localhost alpn=-" sclient -tls1_3 -sigalgs ed25519
        served_check "OpenSSL, ed25519, no ed25519 among its signature algorithms" "SSL alert number 40" sclient -tls1_3 -sigalgs ECDSA+SHA256:RSA-PSS+SHA256
      fi
      served_check "OpenSSL, $kind, ALPN this server does not speak" "SSL alert number 120" sclient -tls1_3 -alpn spdy/3
    else
      echo "  no openssl here (or Windows), so s_client goes unasked"
    fi
    # curl on LibreSSL (macOS's) or schannel (Windows') takes no Ed25519
    # certificate, and is refused it, rightly; on OpenSSL it takes both.
    # Schannel (Windows') offers no X25519: it is answered in secp256r1.
    if command -v curl >/dev/null 2>&1 && { [ "$kind" = p256 ] || curl --version | head -1 | grep -q 'OpenSSL/'; }; then
      local before=$served_ok
      served_check "curl, $kind" "name=localhost alpn=http/1.1" curl -sS --http1.1 --cacert "$SRV/roots.pem" \
        --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/"
      # Refused: what curl's TLS said of the handshake, step by step.
      if [ "$served_ok" -eq "$before" ]; then
        curl -v --http1.1 --cacert "$SRV/roots.pem" --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/" 2>&1 |
          grep -i 'schannel\|tls\|ssl\|alpn' | tail -n 14 | sed 's/^/    /'
      fi
    elif command -v curl >/dev/null 2>&1; then
      echo "  curl, $kind: not asked, its TLS ($(curl --version | head -1 | grep -o '[A-Za-z]*SSL/[0-9.]*\|Schannel\|SecureTransport' | head -1)) takes no Ed25519 certificate"
    fi
    if command -v node >/dev/null 2>&1; then
      served_check "Node's tls, $kind" "name=localhost alpn=h2" node -e '
const tls = require("tls"), fs = require("fs");
const s = tls.connect({host: "127.0.0.1", port: +process.argv[1], servername: "localhost",
  ca: fs.readFileSync(process.argv[2]), ALPNProtocols: ["h2"]}, () => s.write("GET / HTTP/1.0\r\n\r\n"));
let got = ""; s.on("data", d => got += d); s.on("end", () => console.log(s.alpnProtocol, got));
s.on("error", e => console.log("error", e.message));
' "$port" "$SRV/roots.pem"
    fi
    kill "$SERVE_PID" 2>/dev/null
    wait "$SERVE_PID" 2>/dev/null
  }
  serve_and_ask "$SRV" ed25519
  serve_and_ask "$SRV/p256" p256
  # The server asking for a client's certificate: the scripted client's
  # MTLS scenarios, then real clients presenting one.
  M="$SRV/mtls"
  "$WORK/tls-release" serve "$M" 1000 >"$WORK/serve-mtls.log" 2>&1 &
  SERVE_PID=$!
  SERVE_LOG="$WORK/serve-mtls.log"
  for _ in $(seq 1 100); do
    [ -s "$M/port" ] && break
    sleep 0.1
  done
  if [ ! -s "$M/port" ]; then
    echo "  the server that asks did not start:"
    sed 's/^/    /' "$WORK/serve-mtls.log" | head -5
    status=1
  else
    port="$(cat "$M/port")"
    if "$PY" "$REPO/bench/std_tls_client.py" "$port" "$SRV/roots.pem" --mtls "$M" >"$WORK/client-mtls.out" 2>&1; then
      echo "  the scripted client, a client certificate asked for: $(tail -1 "$WORK/client-mtls.out")"
    else
      grep -F "FAIL" "$WORK/client-mtls.out" | sed 's/^/  /'
      tail -1 "$WORK/client-mtls.out" | sed 's/^/  /'
      status=1
    fi
    served_check "the std/tls client presenting a P-256 certificate" "HTTP/1.0 200 ok" \
      "$WORK/tls-release" get "$port" "$SRV/roots.pem" localhost - "$M/client.pem" "$M/client.key"
    served_check "the std/tls client presenting an Ed25519 certificate" "HTTP/1.0 200 ok" \
      "$WORK/tls-release" get "$port" "$SRV/roots.pem" localhost - "$M/client-ed.pem" "$M/client-ed.key"
    served_check "the std/tls client presenting none" "alert certificate_required (116)" \
      "$WORK/tls-release" get "$port" "$SRV/roots.pem" localhost -
    served_check "Python's ssl presenting a P-256 certificate" "TLSv1.3 name=localhost alpn=- TLS_AES_256_GCM_SHA384 peer=CN=client" "$PY" -c '
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
ctx.load_cert_chain(sys.argv[3], sys.argv[4])
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost") as s:
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    print(s.version(), data.decode().split("\r\n\r\n")[1].strip())
' "$port" "$SRV/roots.pem" "$M/client.pem" "$M/client.key"
    if [ "$windows" = no ] && command -v "$OPENSSL" >/dev/null 2>&1; then
      served_check "OpenSSL presenting an Ed25519 certificate" "peer=CN=client ed" sh -c \
        'printf "GET / HTTP/1.0\r\n\r\n" | "$1" s_client -connect "127.0.0.1:$2" -servername localhost -CAfile "$3" -verify_return_error -ign_eof -cert "$4" -key "$5" 2>&1' \
        sh "$OPENSSL" "$port" "$SRV/roots.pem" "$M/client-ed.pem" "$M/client-ed.key"
    fi
    if command -v curl >/dev/null 2>&1 && curl --version | head -1 | grep -q 'OpenSSL/'; then
      served_check "curl presenting a P-256 certificate" "peer=CN=client" curl -sS --http1.1 --cacert "$SRV/roots.pem" \
        --cert "$M/client.pem" --key "$M/client.key" --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/"
    fi
    if command -v node >/dev/null 2>&1; then
      served_check "Node's tls presenting a P-256 certificate" "peer=CN=client" node -e '
const tls = require("tls"), fs = require("fs");
const s = tls.connect({host: "127.0.0.1", port: +process.argv[1], servername: "localhost", ca: fs.readFileSync(process.argv[2]),
  cert: fs.readFileSync(process.argv[3]), key: fs.readFileSync(process.argv[4])}, () => s.write("GET / HTTP/1.0\r\n\r\n"));
let got = ""; s.on("data", d => got += d); s.on("end", () => console.log(got));
s.on("error", e => console.log("error", e.message));
' "$port" "$SRV/roots.pem" "$M/client.pem" "$M/client.key"
    fi
    kill "$SERVE_PID" 2>/dev/null
    wait "$SERVE_PID" 2>/dev/null
  fi
  # The same server, not requiring one: a client without is let in, a
  # client with one is still checked.
  O="$SRV/mtls-optional"
  mkdir -p "$O"
  cp "$M/chain.pem" "$M/key.pem" "$M/client-roots.pem" "$O/"
  : >"$O/client-optional"
  "$WORK/tls-release" serve "$O" 1000 >"$WORK/serve-mtls-optional.log" 2>&1 &
  SERVE_PID=$!
  SERVE_LOG="$WORK/serve-mtls-optional.log"
  for _ in $(seq 1 100); do
    [ -s "$O/port" ] && break
    sleep 0.1
  done
  port="$(cat "$O/port" 2>/dev/null || echo 1)"
  if "$PY" "$REPO/bench/std_tls_client.py" "$port" "$SRV/roots.pem" --mtls "$M" mtls-optional-none mtls-ok mtls-bad-cv mtls-untrusted >"$WORK/client-mtls-optional.out" 2>&1; then
    echo "  the scripted client, a client certificate asked for and not required: $(tail -1 "$WORK/client-mtls-optional.out")"
  else
    grep -F "FAIL" "$WORK/client-mtls-optional.out" | sed 's/^/  /'
    tail -1 "$WORK/client-mtls-optional.out" | sed 's/^/  /'
    status=1
  fi
  served_check "the std/tls client presenting none, where none is required" "HTTP/1.0 200 ok" \
    "$WORK/tls-release" get "$port" "$SRV/roots.pem" localhost -
  kill "$SERVE_PID" 2>/dev/null
  wait "$SERVE_PID" 2>/dev/null
  echo "  $served_ok answers from other clients as they should be"
fi

echo
echo "== an error value's sentence, through .or_panic"
if [ "$scripted" = no ]; then
  echo "  no scripted server to refuse a handshake, so the sentence goes unshown"
else
  cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/tls::{TlsClient, TlsConfig}
import std/socket::{IyiSocket}
import std/env::{ENV}

socket = IyiSocket.connect("127.0.0.1", ENV["TLS_PORT"].to_i)
raise "no socket" unless socket.is_a?(IyiSocket)
TlsClient.over(socket, "alert.tls.test").or_panic
puts "accepted"
IYI
  if TLS_PORT="$(cat "$SERVER_DIR/port")" "$IYI" run "$WORK/refuse.iyi" >"$WORK/refuse.out" 2>&1; then
    echo "  a server's handshake_failure was accepted"
    status=1
  elif ! grep -qF "tls: the server sent alert handshake_failure (40)" "$WORK/refuse.out"; then
    echo "  a refused handshake did not say why: $(tr -d '\r' <"$WORK/refuse.out" | tail -1)"
    status=1
  else
    echo "  tls: the server sent alert handshake_failure (40)"
  fi
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [mode]: the exercise must fail
# on a copy of the module with <old> replaced, at the check that names
# <phrase> - over the trace; against the scripted server (`scenarios`);
# as a server, before the scripted client (`server`, on the Ed25519 key,
# `server-p256`, `server-mtls`, asking for a client's certificate, or
# `server-mtls-optional`, asking without requiring one; the client's
# report must name the scenario); or judging the server's configurations
# (`config`).
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  local mode="${5:-trace}"
  if [ -z "$PY" ] || { [ "$mode" = scenarios ] && [ "$scripted" = no ]; } ||
     { { [ "$mode" = server ] || [ "$mode" = server-p256 ] || [ "$mode" = server-mtls ] || [ "$mode" = server-mtls-optional ] || [ "$mode" = config ]; } && [ "$served" = no ]; }; then
    echo "  no scripted peer or python3 here, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/tls.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/tls.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    echo "  the $1 patch did not apply"
    status=1
    return
  fi
  if [ "$mode" = server ] || [ "$mode" = server-p256 ] || [ "$mode" = server-mtls ] || [ "$mode" = server-mtls-optional ] || [ "$mode" = config ]; then
    if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/patched/tlsx" \
         "$REPO/bench/std_tls_exercise.iyi" >"$WORK/patched/build.log" 2>&1; then
      echo "  the $1 copy did not build:"
      tail -3 "$WORK/patched/build.log" | sed 's/^/    /'
      status=1
      return
    fi
    local rc
    if [ "$mode" = config ]; then
      bash "$WORK/server-configs.sh" "$WORK/patched/tlsx" "$SRV" >"$WORK/mut.out" 2>&1
      rc=$?
    else
      mkdir -p "$WORK/patched/srv"
      local keys="$SRV" flag=()
      [ "$mode" = server-p256 ] && keys="$SRV/p256" && flag=(--p256)
      [ "$mode" = server-mtls ] && keys="$SRV/mtls" && flag=(--mtls "$SRV/mtls")
      [ "$mode" = server-mtls-optional ] && keys="$SRV/mtls" && flag=(--mtls "$SRV/mtls" mtls-optional-none mtls-ok mtls-bad-cv)
      cp "$keys/chain.pem" "$keys/key.pem" "$WORK/patched/srv/"
      case "$mode" in server-mtls*) cp "$keys/client-roots.pem" "$WORK/patched/srv/" ;; esac
      [ "$mode" = server-mtls-optional ] && : >"$WORK/patched/srv/client-optional"
      "$WORK/patched/tlsx" serve "$WORK/patched/srv" 1000 >"$WORK/patched/serve.log" 2>&1 &
      local pid=$!
      for _ in $(seq 1 100); do
        [ -s "$WORK/patched/srv/port" ] && break
        sleep 0.1
      done
      "$PY" "$REPO/bench/std_tls_client.py" "$(cat "$WORK/patched/srv/port" 2>/dev/null || echo 1)" "$SRV/roots.pem" ${flag[@]+"${flag[@]}"} >"$WORK/mut.out" 2>&1
      rc=$?
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    fi
    if [ "$rc" -eq 0 ]; then
      echo "  the server held on $1"
      status=1
    elif grep -qF -e "$2" "$WORK/mut.out"; then
      echo "  $1 is caught"
    else
      echo "  $1 failed, but not where it should have:"
      grep -F "FAIL" "$WORK/mut.out" | head -2 | sed 's/^/    /'
      status=1
    fi
    return
  fi
  if [ "$mode" = scenarios ]; then
    set -- "$1" "$2" scenarios "$SERVER_DIR"
  else
    set -- "$1" "$2"
  fi
  local label="$1" phrase="$2"
  shift 2
  if IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_tls_exercise.iyi" -- "$@" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on $label"
    status=1
  elif grep -qF -e "$phrase" "$WORK/mut.out"; then
    echo "  $label is caught"
  else
    echo "  $label failed, but not where it should have:"
    tail -2 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
# Against the scripted server a broken check shows as a refusal for another
# reason: the server hangs up after the one rule it breaks, so the client
# that let it pass fails a step later. The exercise holds each refusal to
# its reason, so that is where the proof lands: "<scenario>: refused with".
prove_broken "HKDF-Expand-Label without its tls13 prefix" "the handshake secret" \
  '    full = "tls13 " + label' '    full = "tls12 " + label'
prove_broken "the master secret derived from the early one" "the master secret" \
  '    extract(derive_secret(handshake_secret, "derived", [] of UInt8), zeros)' '    extract(derive_secret(early_secret, "derived", [] of UInt8), zeros)'
prove_broken "Finished keyed without its label" "the server's Finished" \
  '    hmac(expand_label(secret, "finished", [] of UInt8, @hash_size), hash(transcript))' '    hmac(secret, hash(transcript))'
prove_broken "the sequence number XORed into the nonce's front" "the server's data opened" \
  '    8.times { |i| nonce[11 - i] = nonce[11 - i] ^ ((@sequence >> (8 * i)) & 0xFF_u64).to_u8 }' \
  '    8.times { |i| nonce[i] = nonce[i] ^ ((@sequence >> (8 * i)) & 0xFF_u64).to_u8 }'
prove_broken "a record's length in its additional data left out" "the client's Finished sealed as the trace's record" \
  '    length = inner.size + 16' '    length = inner.size'
prove_broken "the server's Finished unchecked" "bad-finished: refused with" \
  '    unless Subtle.constant_time_compare(message[4, message.size - 4], expected)
      return TlsError.new("the server'"'"'s Finished' '    if false
      return TlsError.new("the server'"'"'s Finished' scenarios
prove_broken "CertificateVerify unchecked" "bad-cv: refused with" \
  '    return TlsError.new("#{@peer}'"'"'s CertificateVerify is not its key'"'"'s signature (decrypt_error)") unless ok' '' scenarios
prove_broken "CertificateVerify over the client's context string" "ok: refused" \
  '    problem = certificate_verify(message, chain[0], "server")' '    problem = certificate_verify(message, chain[0], "client")' scenarios
prove_broken "an ECDSA scheme taken for any curve" "cv-wrong-curve: refused with" \
  'unless key.is_a?(EcdsaPublicKey) && key.curve == curve' 'unless key.is_a?(EcdsaPublicKey)' scenarios
prove_broken "an Ed25519 CertificateVerify unchecked" "bad-cv-ed25519: expected a refusal" \
  '           key.verify(signed, signature)' '           true' scenarios
prove_broken "the session id's echo unchecked" "no-echo: refused with" \
  '    return TlsError.new("a ServerHello that does not echo the session id (illegal_parameter)") unless echo == session' '' scenarios
prove_broken "the certificate checked for no host" "wrong-host: refused with" \
  'verified = X509.verify(chain[0], chain[1, chain.size - 1], roots, @host,' 'verified = X509.verify(chain[0], chain[1, chain.size - 1], roots, nil,' scenarios
prove_broken "a KeyUpdate never answered" "keyupdate: the echo came back" \
  '        if message[4] == 1_u8' '        if false' scenarios
prove_broken "a KeyUpdate's read keys kept" "keyupdate:" \
  '        @read_secret = @schedule.next_secret(@read_secret)' '' scenarios
prove_broken "a HelloRetryRequest's transcript restarted as something else" "hrr-cookie: refused" \
  '      @transcript = [254_u8, 0_u8, 0_u8, first.size.to_u8] + first + server' '      @transcript = first + server' scenarios
prove_broken "a CertificateRequest not answered" "certreq: the echo came back as" \
  '    if (context = @certificate_request)' '    if (context = nil)' scenarios
# The scripted server hangs up on the unwanted certificate while the
# client is still writing: the echo is wrong, or (Windows) the write fails.
prove_broken "the identity sent whatever schemes the request names" "certreq: " \
  '      if identity && @requested_schemes.includes?(identity.scheme)' '      if identity' scenarios
prove_broken "a request naming the identity's scheme answered with no certificate" "certreq-ed25519: the echo came back as" \
  '      if identity && @requested_schemes.includes?(identity.scheme)' '      if false && identity' scenarios
prove_broken "the client's CertificateVerify over the server's context string" "certreq-ed25519: the echo came back as" \
  '"TLS 1.3, client CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
        signature = identity.sign(signed)' '"TLS 1.3, server CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
        signature = identity.sign(signed)' scenarios
prove_broken "a CertificateRequest without signature_algorithms passed over" "certreq-no-sigalgs: refused with" \
  '    return TlsError.new("a CertificateRequest with no signature_algorithms (missing_extension)") unless schemes' '    return nil unless schemes' scenarios
prove_broken "handshake bytes after Finished passed over" "trailing-after-finished: refused with" \
  '    return TlsError.new("handshake bytes left after the server'"'"'s Finished (unexpected_message)") unless @handshake.empty?' '' scenarios
prove_broken "ALPN answers taken whatever they are" "alpn-unoffered: refused with" \
  'return TlsError.new("the server chose #{chosen.inspect} by ALPN, which was not offered (no_application_protocol)") unless @config.alpn.includes?(chosen)' '' scenarios
prove_broken "an unknown extension in EncryptedExtensions passed over" "unsolicited-ext: refused with" \
  '        return TlsError.new("extension #{type} in EncryptedExtensions, which was not offered (unsupported_extension)")' '' scenarios
# Past the refusal, any 32 bytes stand in for the secret: the handshake
# goes on to a server that has already hung up.
prove_broken "a share of small order taken" "zero-share:" \
  '    return TlsError.new("the server'"'"'s X25519 share gives no secret (illegal_parameter)") if shared.is_a?(CurveError)' \
  '    shared = X25519.public_key(private_key) if shared.is_a?(CurveError)' scenarios
# The server's own checks, each before the scripted client: the scenario
# that breaks the rule must be reported as answered wrongly.
prove_broken "the client's Finished unchecked" "FAIL bad-finished " \
  '    unless Subtle.constant_time_compare(message[4, message.size - 4], expected)
      return TlsError.new("the client'"'"'s Finished' '    if false
      return TlsError.new("the client'"'"'s Finished' server
prove_broken "the server's CertificateVerify over the client's context string" "FAIL ok " \
  '"TLS 1.3, server CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
    signature = @config.sign(signed)' '"TLS 1.3, client CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
    signature = @config.sign(signed)' server
prove_broken "the server's HelloRetryRequest transcript restarted as something else" "FAIL hrr " \
  '      @transcript = [254_u8, 0_u8, 0_u8, first.size.to_u8] + first + retry' '      @transcript = first + retry' server
prove_broken "the server's writes kept on its handshake keys after its Finished" "FAIL ok " \
  '    @writer = TlsRecordCipher.new(@suite, @schedule, server_application)
    @write_secret = server_application' '    @write_secret = server_application' server
prove_broken "early data under keys the server lacks not passed over" "FAIL early-skip " \
  '      if opened.is_a?(TlsError) && @early_left > 0 && body.size <= @early_left' '      if false' server
prove_broken "early data before a second ClientHello not passed over" "FAIL early-after-hrr " \
  '        if @early_left > 0 && body.size <= @early_left' '        if false' server
prove_broken "a ChangeCipherSpec during the handshake not passed over" "FAIL ccs " \
  '      if type == TlsRecords::CHANGE_CIPHER_SPEC && @handshaking' '      if type == TlsRecords::CHANGE_CIPHER_SPEC && false' server
prove_broken "a ClientHello's duplicate extension taken" "FAIL dup-ext " \
  '      return TlsError.new("extension #{type} twice in a ClientHello (illegal_parameter)") if seen.includes?(type)' '' server
prove_broken "pre_shared_key's place unchecked" "FAIL psk-not-last " \
  '      return TlsError.new("pre_shared_key not last in a ClientHello (illegal_parameter)") if seen.includes?(41)' '' server
prove_broken "a compression method taken" "FAIL compression " \
  '    return TlsError.new("a ClientHello whose compression methods are not null alone (illegal_parameter)") unless compression == [0_u8]' '' server
prove_broken "a session id of any length echoed" "FAIL long-session " \
  '    return TlsError.new("a ClientHello with a session id of #{session.size} bytes (illegal_parameter)") if session.size > 32' '' server
prove_broken "a client without ed25519 answered anyway" "FAIL no-ed25519 " \
  '    unless schemes.includes?(@config.scheme)' '    if false' server
prove_broken "a client without ecdsa_secp256r1_sha256 answered anyway by a P-256 server" "FAIL no-p256 " \
  '    unless schemes.includes?(@config.scheme)' '    if false' server-p256
prove_broken "a P-256 CertificateVerify signed over SHA-384" "FAIL ok " \
  '      key.sign(EcdsaHash::SHA256, content)' '      key.sign(EcdsaHash::SHA384, content)' server-p256
prove_broken "a P-256 key that is not the certificate's taken" "FAIL another P-256 key" \
  '    return TlsError.new("the private key is not the certificate'"'"'s") unless public.x == key.public_key.x && public.y == key.public_key.y' '' config
prove_broken "a second ClientHello's session id unchecked" "FAIL hrr-other-session " \
  '      return TlsError.new("a second ClientHello with another session id (illegal_parameter)") unless again.session == offer.session' '' server
prove_broken "the server's suite order put before the client's" "FAIL client-order " \
  '    @suite = offer.suites.find { |s| SUITES.includes?(s) } || 0' '    @suite = SUITES.find { |s| offer.suites.includes?(s) } || 0' server
prove_broken "the client's ALPN order put before the server's" "FAIL alpn-order " \
  '    @config.alpn.find { |protocol| wanted.includes?(protocol) }' '    wanted.find { |protocol| @config.alpn.includes?(protocol) }' server
prove_broken "an ALPN offer with nothing in common answered anyway" "FAIL alpn-mismatch " \
  '    if (wanted = offer.alpn) && !@config.alpn.empty? && @alpn_protocol.nil?' '    if (wanted = offer.alpn) && @config.alpn.empty? && @alpn_protocol.nil?' server
prove_broken "no alert sent before hanging up" "FAIL dup-ext " \
  '    code = TlsBytes.alert_code(error.message)' '    code = nil.as(UInt8?)' server
prove_broken "an alert in the clear after the server's keys" "FAIL bad-finished " \
  '      sent = if @writer' '      sent = if false' server
prove_broken "a private key that is not the certificate's taken" "FAIL another key" \
  '    return TlsError.new("the private key is not the certificate'"'"'s") unless TlsBytes.of(Ed25519.public_key(seed)) == key.bytes' '' config
prove_broken "a secp256r1 share taken before an X25519 one" "FAIL both-shares " \
  '    @x25519 ? TlsServer::GROUP_X25519 : (@p256 ? TlsServer::GROUP_SECP256R1 : 0)' '    @p256 ? TlsServer::GROUP_SECP256R1 : (@x25519 ? TlsServer::GROUP_X25519 : 0)' server
prove_broken "a HelloRetryRequest for secp256r1 whatever the groups" "FAIL hrr " \
  '      group = offer.groups.includes?(GROUP_X25519) ? GROUP_X25519 : GROUP_SECP256R1' '      group = GROUP_SECP256R1' server
prove_broken "the server's secp256r1 share not its key's" "FAIL p256-share " \
  '      public = ephemeral.public_point' '      public = p256_ephemeral.public_point' server
prove_broken "a CertificateRequest sent to a client the server was not told to ask" "FAIL ok " \
  '    if @config.client_roots
      request = certificate_request' '    if true
      request = certificate_request' server
prove_broken "the client's CertificateVerify unchecked" "FAIL mtls-bad-cv " \
  '    return TlsError.new("#{@peer}'"'"'s CertificateVerify is not its key'"'"'s signature (decrypt_error)") unless ok' '' server-mtls
prove_broken "the client's CertificateVerify checked under the server's context string" "FAIL mtls-ok " \
  '    problem = certificate_verify(verify, chain[0], "client")' '    problem = certificate_verify(verify, chain[0], "server")' server-mtls
prove_broken "a client certificate checked for serverAuth" "FAIL mtls-ok " \
  '@config.now || Time.utc, X509Purpose::Client)' '@config.now || Time.utc, X509Purpose::Server)' server-mtls
prove_broken "a client with no certificate let in" "FAIL mtls-none " \
  '      return TlsError.new("the client sent no certificate (certificate_required)") if @config.client_required' '' server-mtls
prove_broken "a client Certificate's request context unchecked" "FAIL mtls-context " \
  '    return TlsError.new("a client Certificate whose request context is not the server'"'"'s (illegal_parameter)") unless context.empty?' '' server-mtls
prove_broken "a certificate required where it is optional" "FAIL mtls-optional-none " \
  '      return TlsError.new("the client sent no certificate (certificate_required)") if @config.client_required' '      return TlsError.new("the client sent no certificate (certificate_required)")' server-mtls-optional
prove_broken "a refused client's flight left unread at the close" "FAIL mtls-late " \
  '      linger unless sent' '' server-mtls
prove_broken "a client certificate with no CertificateVerify after it taken" "FAIL mtls-no-cv " \
  '    return TlsError.new("#{TlsBytes.handshake_name(verify[0])} where the client'"'"'s CertificateVerify belongs (unexpected_message)") unless verify[0] == 15_u8' '' server-mtls
prove_broken "a client's chain taken as its own roots" "FAIL mtls-untrusted " \
  'X509.verify(chain[0], chain[1, chain.size - 1], roots, nil,' 'X509.verify(chain[0], chain[1, chain.size - 1], roots + chain[1, chain.size - 1], nil,' server-mtls
prove_broken "a PKCS #8 public key unchecked" "FAIL a version 2 key carrying another public key" \
  '        return TlsError.new("the private key: its public key is not the seed'"'"'s") unless bits.size == 33 && bits[0] == 0_u8 && bits[1, 32] == TlsBytes.of(Ed25519.public_key(seed))' '' config

echo
if [ "$status" -eq 0 ]; then
  echo "the std/tls exercise holds ($mutations breaks caught)"
else
  echo "the std/tls exercise did not hold"
fi
exit $status
