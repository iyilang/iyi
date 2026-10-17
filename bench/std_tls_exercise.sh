#!/usr/bin/env bash
# Exercises `std/tls`.
#
#     bash bench/std_tls_exercise.sh
#
# The exercise holds RFC 8448's simple 1-RTT trace byte for byte through
# the key schedule and the record protection, and TLS 1.2's PRF to its
# vectors; this gate runs it plain and --release, then runs every scenario
# of bench/std_tls_server.py - a TLS 1.3 server written over Python's
# cryptography that breaks the protocol one rule at a time, TLS 1.2's
# ServerHello among its rules - against the client, connects to OpenSSL's
# own s_server across its suites, key types, a HelloRetryRequest, a
# request for a client certificate and ALPN, a client certificate of each
# kind it holds. Then TLS 1.2: s_server and Python's ssl pinned to it, each
# suite, client certificates, the exporter, a HelloRequest, a server
# without the extended master secret, and bench/std_tls12_proxy.py
# changing an honest server's ServerKeyExchange or random; and a copy whose
# ClientHello offers 1.2 alone meets a real server's downgrade sentinel.
# Then the server: its configurations judged, and the exercise
# serving - on an Ed25519 key, a P-256 one, a 2048-bit RSA one (PKCS #8)
# and a 4096-bit RSA one (PKCS #1) - bench/std_tls_client.py, the scripted
# client's every scenario, a handshake checked step by step or one rule
# broken and the alert named; the std/tls client, Python's ssl, OpenSSL's
# s_client (an RSA server held to the RSA-PSS scheme the client lists
# first, and refusing a client that offers PKCS #1 v1.5 alone), curl and
# Node; client certificates of each kind, RSA among them. It shows an
# error value's sentence through `.or_panic`, reads the module with `iyi
# doc`, checks the formatting, typechecks the exercise for five targets and
# builds it from its artifacts, and proves on broken copies of the module
# that the checks fail where they say, the handshake's own against the
# scripted peers.
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
for phrase in "== RFC 8448's simple 1-RTT handshake, through the key schedule" "== the trace's records, sealed and opened" "== TLS 1.2's PRF, through the key schedule"; do
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
    for kind in p256 ed25519 rsa; do
      case $kind in
        p256) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-256" ;;
        ed25519) opt="-newkey ed25519" ;;
        rsa) opt="-newkey rsa:2048" ;;
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
  # client_alert <binary>: its std/tls client refusing OpenSSL's server for
  # a host the certificate does not name; s_server must have read alert 42
  # (bad_certificate), which it can only under the client's handshake keys.
  client_alert() {
    local port pid
    port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    "$OPENSSL" s_server -accept "127.0.0.1:$port" -www -tls1_3 -cert "$PKI/p256.pem" -key "$PKI/p256.key" \
      >"$WORK/s_server-alert.log" 2>&1 </dev/null &
    pid=$!
    for _ in $(seq 1 50); do
      "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
      sleep 0.1
    done
    "$1" get "$port" "$PKI/ca.pem" example.com >/dev/null 2>&1
    sleep 0.3
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if grep -q "SSL alert number 42" "$WORK/s_server-alert.log"; then
      echo "  the std/tls client's refusal, as OpenSSL read it: alert bad_certificate (42)"
      return 0
    fi
    echo "  FAIL no alert read by OpenSSL: $(tail -2 "$WORK/s_server-alert.log" | tr '\n' ' ')"
    return 1
  }
  if client_alert "$WORK/tls-release"; then
    interop=$((interop + 1))
  else
    status=1
  fi
  # client_export <binary>: what its std/tls client exports for a label,
  # against what OpenSSL's server exports for it (RFC 8446 section 7.5).
  client_export() {
    local port pid got theirs
    port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    # One connection, not -www: only then does s_server print what it
    # exported. Its stdin stays open, as at EOF it would shut down; and a
    # probe of the port would be that one connection, so its ACCEPT is
    # waited for instead.
    : >"$WORK/s_server-export.log"
    { sleep 6 | "$OPENSSL" s_server -accept "127.0.0.1:$port" -naccept 1 -tls1_3 -cert "$PKI/p256.pem" -key "$PKI/p256.key" \
      -keymatexport "EXPERIMENTAL iyi" -keymatexportlen 16 >"$WORK/s_server-export.log" 2>&1; } &
    pid=$!
    for _ in $(seq 1 50); do
      grep -q ACCEPT "$WORK/s_server-export.log" && break
      sleep 0.1
    done
    got="$(TLS_EXPORT="EXPERIMENTAL iyi" "$1" get "$port" "$PKI/ca.pem" localhost 2>&1 | grep -o 'exported=[0-9a-f]*' | cut -d= -f2)"
    # The server goes when its stdin ends, after the connection.
    wait "$pid" 2>/dev/null
    theirs="$(grep -o 'Keying material: [0-9A-Fa-f]*' "$WORK/s_server-export.log" | head -1 | cut -d' ' -f3 | tr 'A-F' 'a-f')"
    if [ -n "$got" ] && [ "$got" = "$theirs" ]; then
      echo "  exported for \"EXPERIMENTAL iyi\", the same at both ends: $got"
      return 0
    fi
    echo "  FAIL the client exported '$got', OpenSSL's server '$theirs'"
    return 1
  }
  if client_export "$WORK/tls-release"; then
    interop=$((interop + 1))
  else
    status=1
  fi
  # TLS 1.2 is not offered unless asked for (the next section asks): a
  # server of 1.2 alone refuses the ClientHello, which offers it nothing.
  interop "TLS 1.2 alone, not asked for" "alert protocol_version (70)" localhost - -tls1_2 -cert p256.pem -key p256.key
  interop "secp256r1 alone, asked for by a HelloRetryRequest" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert p256.pem -key p256.key -groups P-256
  interop "groups the client offers none of" "alert handshake_failure (40)" localhost - -tls1_3 -cert p256.pem -key p256.key -groups P-384
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
  identity=(client-rsa.pem client-rsa.key)
  interop "a client certificate required, an RSA one presented, under the request's first RSA-PSS scheme" "HTTP/1.0 200 ok" \
    localhost - "${mtls[@]}" -client_sigalgs RSA-PSS+SHA512:RSA-PSS+SHA256
  # OpenSSL sends internal_error rather than ask for PKCS #1 v1.5 alone in
  # TLS 1.3, so the request names ECDSA beside it.
  interop "a request naming PKCS #1 v1.5 and ecdsa_secp256r1_sha256, an RSA one held back" "alert certificate_required (116)" \
    localhost - "${mtls[@]}" -client_sigalgs RSA+SHA256:ECDSA+SHA256
  identity=()
  cd "$REPO" || exit 1
  echo "  $interop answers from OpenSSL as they should be"
fi

echo
echo "== TLS 1.2: the client against servers that speak nothing newer"
# The client told to speak TLS 1.2 (`min_version = TlsVersion::TLS12`, the
# exercise's TLS_MIN_VERSION=1.2), which it does only when told: the
# scripted server's "tls12" scenario and the section above hold the default
# to 1.3 alone. OpenSSL's s_server pinned to TLS 1.2 (-tls1_2), each of the six suites on
# its certificate's kind; a ServerKeyExchange signed under PKCS #1 v1.5
# and RSA-PSS, ECDSA under SHA-384, Ed25519; secp256r1; ALPN; a server
# without the extended master secret (-no_ems) refused by name, a P-384
# certificate refused by the server (the ClientHello names no P-384),
# client certificates of each kind; the exporter against OpenSSL's; a
# HelloRequest answered with no_renegotiation; and through
# bench/std_tls12_proxy.py, a man in the middle, a ServerKeyExchange's
# signature or point one bit off and the downgrade sentinel written into
# an honest server's random, each refused. Then Python's ssl, pinned to
# TLS 1.2 by maximum_version, each suite set by set_ciphers on ECDSA and
# RSA certificates.
tls12=0
if [ "$windows" = yes ] || ! command -v "$OPENSSL" >/dev/null 2>&1 || [ -z "$PY" ] || ! [ -s "${PKI:-/nonexistent}/p256.pem" ]; then
  echo "  no openssl and python here, so TLS 1.2 goes unasked"
else
  free_port() { "$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
  wait_port() {
    for _ in $(seq 1 50); do
      "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $1), 1).close()" 2>/dev/null && return 0
      sleep 0.1
    done
  }
  # tls12_round <binary>: the binary's std/tls client against TLS 1.2
  # servers, a line each; "FAIL" before what did not hold.
  tls12_round() {
    local bin="$1" failed=0 port pid proxy got
    cd "$PKI" || return 1
    one() {
      local label="$1" want="$2" mode="$3"
      shift 3
      port="$(free_port)"
      "$OPENSSL" s_server -accept "127.0.0.1:$port" -www "$@" >"$WORK/s12.log" 2>&1 </dev/null &
      pid=$!
      wait_port "$port"
      if [ "$mode" = direct ]; then
        got="$(TLS_MIN_VERSION=1.2 "$bin" get "$port" ca.pem localhost "${ALPN12:--}" ${CLIENT12[@]+"${CLIENT12[@]}"} 2>&1)"
      else
        rm -f "$WORK/proxyport"
        "$PY" "$REPO/bench/std_tls12_proxy.py" "$WORK/proxyport" "$port" "$mode" >"$WORK/proxy.log" 2>&1 &
        proxy=$!
        for _ in $(seq 1 50); do [ -s "$WORK/proxyport" ] && break; sleep 0.1; done
        got="$(TLS_MIN_VERSION=1.2 "$bin" get "$(cat "$WORK/proxyport")" ca.pem localhost 2>&1)"
        kill "$proxy" 2>/dev/null
        wait "$proxy" 2>/dev/null
      fi
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      if printf '%s' "$got" | grep -qF -e "$want"; then
        echo "  $label: $got"
      else
        echo "  FAIL $label: expected \"$want\", got: $got"
        failed=1
      fi
    }
    for suite in ECDHE-ECDSA-AES128-GCM-SHA256:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 ECDHE-ECDSA-AES256-GCM-SHA384:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 \
      ECDHE-ECDSA-CHACHA20-POLY1305:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256; do
      one "s_server -tls1_2, P-256, ${suite%%:*}" "HTTP/1.0 200 ok ${suite#*:} alpn=- TLSv1.2" direct -tls1_2 -cert p256.pem -key p256.key -cipher "${suite%%:*}"
    done
    for suite in ECDHE-RSA-AES128-GCM-SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 ECDHE-RSA-AES256-GCM-SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 \
      ECDHE-RSA-CHACHA20-POLY1305:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256; do
      one "s_server -tls1_2, RSA, ${suite%%:*}" "HTTP/1.0 200 ok ${suite#*:} alpn=- TLSv1.2" direct -tls1_2 -cert rsa.pem -key rsa.key -cipher "${suite%%:*}"
    done
    one "a ServerKeyExchange under rsa_pkcs1_sha256" "HTTP/1.0 200 ok TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256" direct -tls1_2 -cert rsa.pem -key rsa.key -sigalgs RSA+SHA256
    one "a ServerKeyExchange under rsa_pkcs1_sha512" "HTTP/1.0 200 ok TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256" direct -tls1_2 -cert rsa.pem -key rsa.key -sigalgs RSA+SHA512
    one "a ServerKeyExchange under rsa_pss_rsae_sha384" "HTTP/1.0 200 ok TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256" direct -tls1_2 -cert rsa.pem -key rsa.key -sigalgs RSA-PSS+SHA384
    one "a ServerKeyExchange under ECDSA with SHA-384, on P-256" "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" direct -tls1_2 -cert p256.pem -key p256.key -sigalgs ECDSA+SHA384
    one "an Ed25519 certificate (RFC 8422)" "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" direct -tls1_2 -cert ed25519.pem -key ed25519.key
    one "secp256r1 alone" "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" direct -tls1_2 -cert p256.pem -key p256.key -groups P-256
    ALPN12=http/1.1 one "ALPN" "alpn=http/1.1 TLSv1.2" direct -tls1_2 -cert p256.pem -key p256.key -alpn http/1.1
    one "a server without the extended master secret" "does not do the extended master secret (RFC 7627), which a TLS 1.2 handshake here requires (handshake_failure)" \
      direct -tls1_2 -cert p256.pem -key p256.key -no_ems
    one "a P-384 certificate, which this ClientHello's groups rule out" "the server sent alert handshake_failure (40)" direct -tls1_2 -cert p384.pem -key p384.key
    local kind
    for kind in p256 ed25519 rsa; do
      CLIENT12=(client-$kind.pem client-$kind.key)
      one "a client certificate required, a $kind one presented" "HTTP/1.0 200 ok" direct -tls1_2 -cert p256.pem -key p256.key -Verify 1 -verify_return_error -CAfile ca.pem
    done
    CLIENT12=(client-rsa.pem client-rsa.key)
    one "a request naming PKCS #1 v1.5 and ECDSA, an RSA one held back" "the server sent alert handshake_failure (40)" \
      direct -tls1_2 -cert p256.pem -key p256.key -Verify 1 -verify_return_error -CAfile ca.pem -client_sigalgs RSA+SHA256:ECDSA+SHA256
    CLIENT12=()
    one "through a man in the middle who changes nothing" "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" none -tls1_2 -cert p256.pem -key p256.key
    one "a ServerKeyExchange's signature one bit off" "the server's ServerKeyExchange is not its key's signature (decrypt_error)" ske-signature -tls1_2 -cert p256.pem -key p256.key
    one "an RSA ServerKeyExchange's signature one bit off" "the server's ServerKeyExchange is not its key's signature (decrypt_error)" ske-signature -tls1_2 -cert rsa.pem -key rsa.key
    one "a ServerKeyExchange's point one bit off" "the server's ServerKeyExchange is not its key's signature (decrypt_error)" ske-point -tls1_2 -cert p256.pem -key p256.key
    one "the downgrade sentinel written into a TLS 1.2 ServerHello" "carrying RFC 8446's downgrade sentinel, where TLS 1.3 was offered: a downgrade (illegal_parameter)" \
      sentinel -tls1_2 -cert p256.pem -key p256.key
    # The exporter (RFC 5705) against OpenSSL's, one connection.
    port="$(free_port)"
    : >"$WORK/s12-export.log"
    { sleep 6 | "$OPENSSL" s_server -accept "127.0.0.1:$port" -naccept 1 -tls1_2 -cert p256.pem -key p256.key \
      -keymatexport "EXPERIMENTAL iyi" -keymatexportlen 16 >"$WORK/s12-export.log" 2>&1; } &
    pid=$!
    for _ in $(seq 1 50); do grep -q ACCEPT "$WORK/s12-export.log" && break; sleep 0.1; done
    got="$(TLS_MIN_VERSION=1.2 TLS_EXPORT="EXPERIMENTAL iyi" "$bin" get "$port" ca.pem localhost 2>&1 | grep -o 'exported=[0-9a-f]*' | cut -d= -f2)"
    wait "$pid" 2>/dev/null
    local theirs
    theirs="$(grep -o 'Keying material: [0-9A-Fa-f]*' "$WORK/s12-export.log" | head -1 | cut -d' ' -f3 | tr 'A-F' 'a-f')"
    if [ -n "$got" ] && [ "$got" = "$theirs" ]; then
      echo "  exported for \"EXPERIMENTAL iyi\" over TLS 1.2, the same at both ends: $got"
    else
      echo "  FAIL the TLS 1.2 exporter: the client's '$got', OpenSSL's '$theirs'"
      failed=1
    fi
    # A HelloRequest: s_server renegotiates ("r" on its stdin) once "first"
    # has reached it; its -msg log must show the no_renegotiation warning.
    port="$(free_port)"
    rm -f "$WORK/fifo12" && mkfifo "$WORK/fifo12"
    : >"$WORK/s12-reneg.log"
    "$OPENSSL" s_server -accept "127.0.0.1:$port" -naccept 1 -tls1_2 -msg -cert p256.pem -key p256.key <"$WORK/fifo12" >"$WORK/s12-reneg.log" 2>&1 &
    pid=$!
    exec 7>"$WORK/fifo12"
    for _ in $(seq 1 50); do grep -q ACCEPT "$WORK/s12-reneg.log" && break; sleep 0.1; done
    "$bin" renegotiate "$port" ca.pem localhost >"$WORK/reneg.out" 2>&1 &
    local client=$!
    for _ in $(seq 1 50); do grep -q '^first' "$WORK/s12-reneg.log" && break; sleep 0.1; done
    # In a subshell: a server already gone would SIGPIPE the gate itself.
    (echo r >&7) 2>/dev/null
    wait "$client"
    exec 7>&-
    sleep 0.3
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if grep -q 'HelloRequest' "$WORK/s12-reneg.log" && grep -q 'warning no_renegotiation' "$WORK/s12-reneg.log"; then
      echo "  a HelloRequest answered: OpenSSL read \"warning no_renegotiation\"; the client: $(head -1 "$WORK/reneg.out")"
    else
      echo "  FAIL a HelloRequest: OpenSSL read no no_renegotiation: $(tr '\n' ' ' <"$WORK/reneg.out")"
      failed=1
    fi
    cd "$REPO" || return 1
    return $failed
  }
  if tls12_round "$WORK/tls-release" >"$WORK/tls12.out" 2>&1; then
    cat "$WORK/tls12.out"
  else
    cat "$WORK/tls12.out"
    status=1
  fi
  tls12=$(grep -c -v FAIL "$WORK/tls12.out")
  # Python's ssl, maximum_version TLS 1.2, one connection a suite.
  cat >"$WORK/py12.py" <<'PY'
import socket, ssl, sys
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
ctx.load_cert_chain(sys.argv[2], sys.argv[3])
ctx.set_ciphers(sys.argv[4])
ctx.set_alpn_protocols(["http/1.1"])
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(1)
open(sys.argv[1], "w").write(str(listener.getsockname()[1]))
conn, _ = listener.accept()
conn.settimeout(10)
with ctx.wrap_socket(conn, server_side=True) as s:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.sendall(f"HTTP/1.0 200 ok\r\n\r\n{s.version()} {s.cipher()[0]}\n".encode())
    s.unwrap()
PY
  for pair in p256:ECDHE-ECDSA-AES128-GCM-SHA256 p256:ECDHE-ECDSA-AES256-GCM-SHA384 p256:ECDHE-ECDSA-CHACHA20-POLY1305 \
    rsa:ECDHE-RSA-AES128-GCM-SHA256 rsa:ECDHE-RSA-AES256-GCM-SHA384 rsa:ECDHE-RSA-CHACHA20-POLY1305; do
    kind="${pair%%:*}"
    suite="${pair#*:}"
    rm -f "$WORK/py12port"
    "$PY" "$WORK/py12.py" "$WORK/py12port" "$PKI/$kind.pem" "$PKI/$kind.key" "$suite" >"$WORK/py12.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do [ -s "$WORK/py12port" ] && break; sleep 0.1; done
    got="$(TLS_MIN_VERSION=1.2 "$WORK/tls-release" get "$(cat "$WORK/py12port")" "$PKI/ca.pem" localhost http/1.1 2>&1)"
    wait "$pid" 2>/dev/null
    if printf '%s' "$got" | grep -qE "^HTTP/1.0 200 ok TLS_ECDHE_.* alpn=http/1.1 TLSv1.2$" && ! [ -s "$WORK/py12.log" ]; then
      tls12=$((tls12 + 1))
      echo "  Python's ssl, TLS 1.2, $kind, $suite: $got"
    else
      echo "  FAIL Python's ssl, TLS 1.2, $kind, $suite: $got; Python said: $(tail -1 "$WORK/py12.log")"
      status=1
    fi
  done
  # Not told to speak TLS 1.2, the client offers Python's 1.2-only server
  # nothing it takes: refused, as before 1.2 was here.
  rm -f "$WORK/py12port"
  "$PY" "$WORK/py12.py" "$WORK/py12port" "$PKI/p256.pem" "$PKI/p256.key" ECDHE-ECDSA-AES128-GCM-SHA256 >"$WORK/py12.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do [ -s "$WORK/py12port" ] && break; sleep 0.1; done
  got="$("$WORK/tls-release" get "$(cat "$WORK/py12port")" "$PKI/ca.pem" localhost http/1.1 2>&1)"
  wait "$pid" 2>/dev/null
  if printf '%s' "$got" | grep -qF "alert protocol_version (70)"; then
    tls12=$((tls12 + 1))
    echo "  Python's ssl, TLS 1.2 alone, the client not told to speak it: $got"
  else
    echo "  FAIL Python's ssl, TLS 1.2 alone, the client not told to speak it: $got"
    status=1
  fi
  # The downgrade sentinel from a real server: a copy whose ClientHello
  # offers TLS 1.2 alone, as one a man in the middle rewrote would, meets
  # OpenSSL speaking 1.3 too, which writes the sentinel - refused; and a
  # second copy with the check removed connects, which proves the refusal
  # is the check's.
  downgraded() {
    local name="$1"
    shift
    rm -rf "$WORK/$name" && mkdir -p "$WORK/$name/std"
    OLD="tls12 ? [4_u8, 3_u8, 4_u8, 3_u8, 3_u8]" NEW="tls12 ? [2_u8, 3_u8, 3_u8]" \
      CHECK="${1:-}" "$PY" - "$REPO/src/std/tls.iyi" "$WORK/$name/std/tls.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
for old, new in [(os.environ["OLD"], os.environ["NEW"])] + ([(os.environ["CHECK"], "if false")] if os.environ["CHECK"] else []):
    if src.count(old) != 1:
        raise SystemExit("patch site missing or not one: " + old)
    src = src.replace(old, new, 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$name/tlsx" "$REPO/bench/std_tls_exercise.iyi" >"$WORK/$name/build.log" 2>&1 ||
      { echo "build failed: $(grep -m1 Error "$WORK/$name/build.log")"; return; }
    local port pid
    port="$(free_port)"
    "$OPENSSL" s_server -accept "127.0.0.1:$port" -www -cert "$PKI/p256.pem" -key "$PKI/p256.key" >/dev/null 2>&1 </dev/null &
    pid=$!
    wait_port "$port"
    TLS_MIN_VERSION=1.2 "$WORK/$name/tlsx" get "$port" "$PKI/ca.pem" localhost 2>&1
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  }
  got="$(downgraded downgrade)"
  if printf '%s' "$got" | grep -qF "carrying RFC 8446's downgrade sentinel, where TLS 1.3 was offered: a downgrade (illegal_parameter)"; then
    tls12=$((tls12 + 1))
    echo "  a ClientHello offering TLS 1.2 alone, to OpenSSL speaking 1.3 too: $got"
  else
    echo "  FAIL a ClientHello offering TLS 1.2 alone, to OpenSSL speaking 1.3 too: $got"
    status=1
  fi
  got="$(downgraded downgrade-unchecked "if tail == DOWNGRADE_TLS12 || tail == DOWNGRADE_TLS11")"
  if printf '%s' "$got" | grep -qF "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 alpn=- TLSv1.2"; then
    echo "  the sentinel check removed, the same is taken: $got"
  else
    echo "  FAIL the sentinel check removed, the downgrade was still refused: $got"
    status=1
  fi
  echo "  $tls12 answers from TLS 1.2 servers as they should be"
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
def leaf_for(key, host="localhost"):
    return (x509.CertificateBuilder().subject_name(name(host)).issuer_name(root.subject)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=20))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(host)]), critical=False)
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
# A second identity, for other.test, beside each server's own: shown to a
# client that asks for that host by server_name.
other_host = ec.generate_private_key(ec.SECP256R1())
for where in ("", "p256/"):
    write(where + "other-chain.pem", pem(leaf_for(other_host, "other.test")) + pem(root))
    write(where + "other-key.pem", pkcs8(other_host))
# RSA servers: a 2048-bit key as PKCS #8 and a 4096-bit one as PKCS #1,
# each with its leaf; and RSA keys a server must refuse - another key, a
# 1024-bit one with its own leaf, and the 2048-bit key with qi broken.
from cryptography.hazmat.primitives.asymmetric import rsa
rsa_keys = {}
for bits, fmt in ((2048, serialization.PrivateFormat.PKCS8), (4096, serialization.PrivateFormat.TraditionalOpenSSL)):
    rk = rsa.generate_private_key(public_exponent=65537, key_size=bits)
    rsa_keys[bits] = rk
    os.makedirs(os.path.join(out, f"rsa{bits}"), exist_ok=True)
    write(f"rsa{bits}/chain.pem", pem(leaf_for(rk)) + pem(root))
    write(f"rsa{bits}/key.pem", rk.private_bytes(serialization.Encoding.PEM, fmt, serialization.NoEncryption()))
    write(f"rsa{bits}/other-chain.pem", pem(leaf_for(other_host, "other.test")) + pem(root))
    write(f"rsa{bits}/other-key.pem", pkcs8(other_host))
write("rsa-other.key", pkcs8(rsa.generate_private_key(public_exponent=65537, key_size=2048)))
small = rsa.generate_private_key(public_exponent=65537, key_size=1024)
write("rsa1024.pem", pem(leaf_for(small)) + pem(root))
write("rsa1024.key", pkcs8(small))
def der_int(v):
    raw = v.to_bytes(v.bit_length() // 8 + 1, "big")
    return b"\x02" + der_len(len(raw)) + raw
def der_len(n):
    return bytes([n]) if n < 128 else bytes([0x80 | ((n.bit_length() + 7) // 8)]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
numbers = rsa_keys[2048].private_numbers()
broken = [0, numbers.public_numbers.n, numbers.public_numbers.e, numbers.d, numbers.p, numbers.q, numbers.dmp1, numbers.dmq1, numbers.iqmp + 1]
body = b"".join(der_int(v) for v in broken)
import base64
text = base64.b64encode(b"\x30" + der_len(len(body)) + body).decode()
write("rsa-bad-qi.key", ("-----BEGIN RSA PRIVATE KEY-----\n" + "\n".join(text[i:i + 64] for i in range(0, len(text), 64)) + "\n-----END RSA PRIVATE KEY-----\n").encode())
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
        ("client-rsa", "client rsa", rsa.generate_private_key(public_exponent=65537, key_size=2048), client_ca, client_ca_key, ExtendedKeyUsageOID.CLIENT_AUTH),
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
check "two keys" chain.pem two.key "2 blocks of PRIVATE KEY, EC PRIVATE KEY or RSA PRIVATE KEY, not one"
check "no key" chain.pem chain.pem "0 blocks of PRIVATE KEY, EC PRIVATE KEY or RSA PRIVATE KEY, not one"
check "no certificate" key.pem key.pem "the certificates: none"
check "a version 2 key carrying another public key" chain.pem v2-wrong.key "its public key is not the seed's"
check "a version 1 key carrying a public key" chain.pem v0-public.key "a public key in version 0"
check "an Ed25519 algorithm with parameters" chain.pem params.key "an Ed25519 algorithm with parameters"
check "a P-256 chain and its PKCS #8 key" p256.pem ec.key "config: 2 certificates, leaf CN=localhost"
check "a P-256 chain and its SEC 1 key" p256.pem ec-sec1.key "config: 2 certificates, leaf CN=localhost"
check "another P-256 key" p256.pem other-ec.key "the private key is not the certificate's"
check "a P-384 key" p256.pem p384.key "the private key is on 1.3.132.0.34, not prime256v1"
check "an RSA chain and its PKCS #8 key" rsa2048/chain.pem rsa2048/key.pem "config: 2 certificates, leaf CN=localhost"
check "a 4096-bit RSA chain and its PKCS #1 key" rsa4096/chain.pem rsa4096/key.pem "config: 2 certificates, leaf CN=localhost"
check "another RSA key" rsa2048/chain.pem rsa-other.key "the private key is not the certificate's"
check "an RSA key for an Ed25519 certificate" chain.pem rsa-other.key "the certificate's key is not RSA, as the private key is"
check "an Ed25519 key for an RSA certificate" rsa2048/chain.pem key.pem "the certificate's key is not Ed25519"
check "a 1024-bit RSA key" rsa1024.pem rsa1024.key "1024 bits, under the 2048 this signs with"
check "an RSA key whose qi is not q's inverse" rsa2048/chain.pem rsa-bad-qi.key "qi is not the inverse of q mod p"
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
  # serve_and_ask <dir> <ed25519|p256|rsa2048|rsa4096>: the exercise serving
  # the chain and key in <dir>, the scripted client and the others against
  # it.
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
    case "$kind" in
      p256) flag=(--p256) ;;
      rsa*) flag=(--rsa) ;;
    esac
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
      case "$kind" in
        p256)
          served_check "OpenSSL, p256, ecdsa_secp256r1_sha256 alone" "name=localhost alpn=-" sclient -tls1_3 -sigalgs ECDSA+SHA256
          served_check "OpenSSL, p256, no ecdsa_secp256r1_sha256 among its signature algorithms" "SSL alert number 40" sclient -tls1_3 -sigalgs ed25519:RSA-PSS+SHA256
          ;;
        rsa*)
          # The scheme the client lists first, and never PKCS #1 v1.5.
          served_check "OpenSSL, $kind, rsa_pss_rsae_sha256 alone" "Peer signature type: rsa_pss_rsae_sha256" sclient -tls1_3 -sigalgs RSA-PSS+SHA256
          served_check "OpenSSL, $kind, rsa_pss_rsae_sha384 alone" "Peer signature type: rsa_pss_rsae_sha384" sclient -tls1_3 -sigalgs RSA-PSS+SHA384
          served_check "OpenSSL, $kind, rsa_pss_rsae_sha512 before -256" "Peer signature type: rsa_pss_rsae_sha512" sclient -tls1_3 -sigalgs RSA-PSS+SHA512:RSA-PSS+SHA256
          served_check "OpenSSL, $kind, PKCS #1 v1.5 and no RSA-PSS among its signature algorithms" "SSL alert number 40" sclient -tls1_3 -sigalgs RSA+SHA256:RSA+SHA384:ECDSA+SHA256
          ;;
        *)
          served_check "OpenSSL, ed25519, ed25519 alone" "name=localhost alpn=-" sclient -tls1_3 -sigalgs ed25519
          served_check "OpenSSL, ed25519, no ed25519 among its signature algorithms" "SSL alert number 40" sclient -tls1_3 -sigalgs ECDSA+SHA256:RSA-PSS+SHA256
          ;;
      esac
      served_check "OpenSSL, $kind, ALPN this server does not speak" "SSL alert number 120" sclient -tls1_3 -alpn spdy/3
      # What the server exports for a label, in its answer, against what
      # OpenSSL's client exports for it.
      export_both() {
        local out ours theirs
        out="$(sclient -tls1_3 -keymatexport "EXPERIMENTAL iyi" -keymatexportlen 16)"
        ours="$(printf '%s' "$out" | grep -o 'exported=[0-9a-f]*' | head -1 | cut -d= -f2)"
        theirs="$(printf '%s' "$out" | grep -o 'Keying material: [0-9A-Fa-f]*' | head -1 | cut -d' ' -f3 | tr 'A-F' 'a-f')"
        [ -n "$ours" ] && [ "$ours" = "$theirs" ] && echo "the same at both ends: $ours" || echo "server $ours, OpenSSL $theirs"
      }
      served_check "OpenSSL, $kind, exported keying material" "the same at both ends" export_both
    else
      echo "  no openssl here (or Windows), so s_client goes unasked"
    fi
    # curl on LibreSSL (macOS's) or schannel (Windows') takes no Ed25519
    # certificate, and is refused it, rightly; on OpenSSL it takes both.
    # Schannel (Windows') offers no X25519: it is answered in secp256r1. It
    # also asks whether a certificate was revoked, which these made here
    # cannot say: "the revocation status is unknown" unless told not to.
    local norevoke=()
    curl --version 2>/dev/null | head -1 | grep -q 'Schannel' && norevoke=(--ssl-no-revoke)
    if command -v curl >/dev/null 2>&1 && { [ "$kind" = p256 ] || curl --version | head -1 | grep -q 'OpenSSL/'; }; then
      local before=$served_ok
      served_check "curl, $kind" "name=localhost alpn=http/1.1" curl -sS --http1.1 ${norevoke[@]+"${norevoke[@]}"} --cacert "$SRV/roots.pem" \
        --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/"
      # Refused: what curl's TLS said of the handshake, step by step.
      if [ "$served_ok" -eq "$before" ]; then
        curl -v --http1.1 ${norevoke[@]+"${norevoke[@]}"} --cacert "$SRV/roots.pem" --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/" 2>&1 |
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
  serve_and_ask "$SRV/rsa2048" rsa2048
  serve_and_ask "$SRV/rsa4096" rsa4096
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
    served_check "the std/tls client presenting an RSA certificate" "HTTP/1.0 200 ok" \
      "$WORK/tls-release" get "$port" "$SRV/roots.pem" localhost - "$M/client-rsa.pem" "$M/client-rsa.key"
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
      served_check "OpenSSL presenting an RSA certificate" "peer=CN=client rsa" sh -c \
        'printf "GET / HTTP/1.0\r\n\r\n" | "$1" s_client -connect "127.0.0.1:$2" -servername localhost -CAfile "$3" -verify_return_error -ign_eof -cert "$4" -key "$5" 2>&1' \
        sh "$OPENSSL" "$port" "$SRV/roots.pem" "$M/client-rsa.pem" "$M/client-rsa.key"
    fi
    if command -v curl >/dev/null 2>&1 && curl --version | head -1 | grep -q 'OpenSSL/'; then
      served_check "curl presenting a P-256 certificate" "peer=CN=client" curl -sS --http1.1 --cacert "$SRV/roots.pem" \
        --cert "$M/client.pem" --key "$M/client.key" --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/"
      served_check "curl presenting an RSA certificate" "peer=CN=client rsa" curl -sS --http1.1 --cacert "$SRV/roots.pem" \
        --cert "$M/client-rsa.pem" --key "$M/client-rsa.key" --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/"
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
echo "== a handshake's time, by the server's key (--release; measured, not checked)"
# Python's ssl makes 200 full TLS 1.3 handshakes with the exercise's
# server, one after another over loopback, and closes each: the median
# wall time of one, its own side's work included. What changes from key to
# key is the CertificateVerify the server signs.
if [ "$served" = yes ]; then
  for pair in "ed25519:$SRV" "p256:$SRV/p256" "rsa2048:$SRV/rsa2048" "rsa4096:$SRV/rsa4096"; do
    kind="${pair%%:*}"
    dir="${pair#*:}"
    rm -f "$dir/port"
    "$WORK/tls-release" serve "$dir" 200 >"$WORK/time-$kind.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
      [ -s "$dir/port" ] && break
      sleep 0.1
    done
    "$PY" - "$(cat "$dir/port" 2>/dev/null || echo 1)" "$SRV/roots.pem" "$kind" <<'PY'
import socket, ssl, statistics, sys, time
ctx = ssl.create_default_context(cafile=sys.argv[2])
took = []
for _ in range(200):
    started = time.perf_counter()
    with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost"):
        took.append(time.perf_counter() - started)
print(f"  {sys.argv[3]}: {statistics.median(took) * 1000:.2f} ms a handshake (median of 200)")
PY
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
else
  echo "  no server here, so nothing is timed"
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
  # A read of nothing would answer "", which is the peer's close: refused
  # as a mistake of the program's, by name.
  cat >"$WORK/readzero.iyi" <<'IYI'
module readzero

import std/tls::{TlsClient, TlsConfig}
import std/socket::{IyiSocket}
import std/x509::{Certificate}
import std/file::{File}
import std/env::{ENV}

config = TlsConfig.new
config.roots = Certificate.from_pem(File.read(ENV["TLS_DIR"] + "/roots.pem")).or_panic
socket = IyiSocket.connect("127.0.0.1", File.read(ENV["TLS_DIR"] + "/port").to_i)
raise "no socket" unless socket.is_a?(IyiSocket)
conn = TlsClient.over(socket, "ok.tls.test", config).or_panic
conn.read(0)
puts "read nothing"
IYI
  if TLS_DIR="$SERVER_DIR" "$IYI" run "$WORK/readzero.iyi" >"$WORK/readzero.out" 2>&1; then
    echo "  a read of 0 bytes was taken"
    status=1
  elif ! grep -qF "a TLS read of 0 bytes: at least 1" "$WORK/readzero.out"; then
    echo "  a read of 0 bytes was refused without saying why: $(tr -d '\r' <"$WORK/readzero.out" | tail -1)"
    status=1
  else
    echo "  a TLS read of 0 bytes: at least 1"
  fi
fi

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/tls.iyi" >"$WORK/doc.txt" 2>&1 && grep -q "scheme_for" "$WORK/doc.txt"; then
  echo "  iyi doc reads std/tls, TlsIdentity's schemes included"
else
  echo "  FAIL: iyi doc: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/tls.iyi" "$REPO/bench/std_tls_exercise.iyi" >"$WORK/format.log" 2>&1; then
  echo "  the module and its exercise are formatted"
else
  echo "  FAIL: not formatted: $(grep -m1 produced "$WORK/format.log")"
  status=1
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_tls_exercise.iyi" >"$WORK/cross.log" 2>&1; then
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
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_tls_exercise.iyi" &&
  "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_tls_exercise.iyi") >"$WORK/r1/build.log" 2>&1; then
  "$WORK/r1/from-source" >"$WORK/r1/source.out" 2>&1
  "$WORK/r1/from-artifact" >"$WORK/r1/artifact.out" 2>&1
  if cmp -s "$WORK/r1/source.out" "$WORK/r1/artifact.out" && grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out"; then
    echo "  built from its artifacts, the exercise prints what it prints from source"
  else
    echo "  FAIL: from its artifacts the exercise prints otherwise:"
    diff "$WORK/r1/source.out" "$WORK/r1/artifact.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
  # The server from its artifacts, an RSA handshake through it: what is
  # compiled from an artifact's text is the signing.
  if [ -s "$SRV/rsa2048/chain.pem" ]; then
    mkdir -p "$WORK/r1/srv"
    cp "$SRV/rsa2048/chain.pem" "$SRV/rsa2048/key.pem" "$WORK/r1/srv/"
    "$WORK/r1/from-artifact" serve "$WORK/r1/srv" 1 >"$WORK/r1/serve.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
      [ -s "$WORK/r1/srv/port" ] && break
      sleep 0.1
    done
    got="$("$WORK/r1/from-source" get "$(cat "$WORK/r1/srv/port" 2>/dev/null || echo 1)" "$SRV/roots.pem" localhost 2>&1)"
    wait "$pid" 2>/dev/null
    if printf '%s' "$got" | grep -qF "HTTP/1.0 200 ok"; then
      echo "  the server built from its artifacts signs with RSA for the client built from source: $got"
    else
      echo "  FAIL: an RSA handshake with the server built from its artifacts: $got; it said $(tail -1 "$WORK/r1/serve.log")"
      status=1
    fi
  fi
else
  echo "  FAIL: the artifacts did not build: $(grep -m1 -E 'Error|BUG' "$WORK/r1/build.log")"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove_broken <label> <phrase> <old> <new> [mode]: the exercise must fail
# on a copy of the module with <old> replaced, at the check that names
# <phrase> - over the trace; against the scripted server (`scenarios`);
# as a server, before the scripted client (`server`, on the Ed25519 key,
# `server-p256`, `server-rsa` on the 2048-bit RSA key, `server-mtls`,
# asking for a client's certificate, or `server-mtls-optional`, asking
# without requiring one; the client's report must name the scenario);
# judging the server's configurations (`config`); or the TLS 1.2 client
# against OpenSSL, Python's ssl and the man in the middle (`client12`).
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  local mode="${5:-trace}"
  if [ -z "$PY" ] || { [ "$mode" = scenarios ] && [ "$scripted" = no ]; } ||
     { { [ "$mode" = server ] || [ "$mode" = server-p256 ] || [ "$mode" = server-rsa ] || [ "$mode" = server-mtls ] || [ "$mode" = server-mtls-optional ] || [ "$mode" = config ]; } && [ "$served" = no ]; } ||
     { { [ "$mode" = client-alert ] || [ "$mode" = client-export ] || [ "$mode" = client12 ]; } && ! [ -s "${PKI:-/nonexistent}/p256.pem" ]; }; then
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
  if [ "$mode" = server ] || [ "$mode" = server-p256 ] || [ "$mode" = server-rsa ] || [ "$mode" = server-mtls ] || [ "$mode" = server-mtls-optional ] || [ "$mode" = config ] || [ "$mode" = client-alert ] || [ "$mode" = client-export ] || [ "$mode" = client12 ]; then
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
    elif [ "$mode" = client-alert ]; then
      client_alert "$WORK/patched/tlsx" >"$WORK/mut.out" 2>&1
      rc=$?
    elif [ "$mode" = client-export ]; then
      client_export "$WORK/patched/tlsx" >"$WORK/mut.out" 2>&1
      rc=$?
    elif [ "$mode" = client12 ]; then
      tls12_round "$WORK/patched/tlsx" >"$WORK/mut.out" 2>&1
      rc=$?
    else
      mkdir -p "$WORK/patched/srv"
      local keys="$SRV" flag=()
      [ "$mode" = server-p256 ] && keys="$SRV/p256" && flag=(--p256)
      [ "$mode" = server-rsa ] && keys="$SRV/rsa2048" && flag=(--rsa ok pss-sha384 pss-sha512 no-rsa-pss no-ed25519 no-p256)
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
    # The panic's sentence, not the last frames of its backtrace.
    echo "  $label failed, but not where it should have:"
    { grep -m1 -F 'panic' "$WORK/mut.out" || tail -2 "$WORK/mut.out"; } | sed 's/^/    /'
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
  '    return TlsError.new("#{@peer}'"'"'s CertificateVerify is not its key'"'"'s signature", TlsAlert::DECRYPT_ERROR) unless ok' '' scenarios
prove_broken "CertificateVerify over the client's context string" "ok: refused" \
  '    problem = certificate_verify(message, chain[0], "server")' '    problem = certificate_verify(message, chain[0], "client")' scenarios
# Taken, the signature verifies (SHA-256 on P-384 is sound ECDSA) and the
# client writes its flight to a server already gone: refused at that write
# on Linux, held on darwin, where the write was buffered - either fails
# the scenario by name.
prove_broken "an ECDSA scheme taken for any curve" "cv-wrong-curve:" \
  'unless key.is_a?(EcdsaPublicKey) && key.curve == curve' 'unless key.is_a?(EcdsaPublicKey)' scenarios
prove_broken "an Ed25519 CertificateVerify unchecked" "bad-cv-ed25519: expected a refusal" \
  '           key.verify(signed, signature)' '           true' scenarios
prove_broken "a server's Certificate of any length searched" "cert-many:" \
  '      return TlsError.new("a Certificate of more than #{X509::MAX_CHAIN} certificates", TlsAlert::BAD_CERTIFICATE) if chain.size == X509::MAX_CHAIN' '' scenarios
prove_broken "a client's handshake bounded by each wait alone" "slow-server: refused with" \
  '    return @socket.read(buffer, count) if @deadline_ns == 0_i64' '    return @socket.read(buffer, count) if true' scenarios
prove_broken "a KeyUpdate's request taken whatever it is" "keyupdate-bad:" \
  '        return TlsError.new("a KeyUpdate asking #{message[4]}", TlsAlert::ILLEGAL_PARAMETER) unless message[4] <= 1_u8' '' scenarios
prove_broken "handshake bytes after the ServerHello taken under the keys" "sh-and-more:" \
  '    return TlsError.new("handshake bytes after the ServerHello in its record", TlsAlert::UNEXPECTED_MESSAGE) unless handshake_left == 0' '' scenarios
prove_broken "a leaf whose keyUsage forbids signing taken" "ku-no-sign:" \
  '    if (usage = leaf.key_usage) && (usage >> Certificate::KEY_DIGITAL_SIGNATURE) & 1 == 0' '    if false' scenarios
prove_broken "a client Certificate past 2^14 bytes sent in one record" "certreq-ed25519:" \
  '        sent = send_flight(presented)' '        sent = send_protected(TlsRecords::HANDSHAKE, presented)' scenarios
prove_broken "a read past its timeout taken as the connection's end" "slow-echo:" \
  '        return record if record.timed_out? || record.cancelled?' '' scenarios
prove_broken "a KeyUpdate's request never answered" "keyupdate:" \
  '        @update_owed = true if message[4] == 1_u8' '' scenarios
prove_broken "no new keys at the key limit" "client-rekey:" \
  '    return nil unless @update_owed || writer.sequence >= @key_limit' '    return nil unless @update_owed' scenarios
prove_broken "key_update(true) sent as a KeyUpdate asking nothing" "client-rekey:" \
  '    sent = send_protected(TlsRecords::HANDSHAKE, TlsBytes.message(24, [request ? 1_u8 : 0_u8]))' '    sent = send_protected(TlsRecords::HANDSHAKE, TlsBytes.message(24, [0_u8]))' scenarios
prove_broken "a CertificateRequest's context taken in the handshake" "certreq-context:" \
  '    return TlsError.new("a CertificateRequest with a request context in the handshake", TlsAlert::ILLEGAL_PARAMETER) unless context.empty?' '' scenarios
prove_broken "a certificate entry's extensions passed over" "cert-entry-ext:" \
  '      return TlsError.new("a certificate entry with extensions nobody asked for", TlsAlert::UNSUPPORTED_EXTENSION) unless entry_extensions.empty?' '' scenarios
prove_broken "a server_name acknowledgement with something in it taken" "sni-ack-data:" \
  '    return TlsError.new("a server_name acknowledgement that is not empty", TlsAlert::DECODE_ERROR) unless data.empty?' '' scenarios
prove_broken "user_canceled after the handshake taken as an end" "user-canceled:" \
  '        next if content.size == 2 && content[1] == TlsAlert::USER_CANCELED' '' scenarios
prove_broken "the session id's echo unchecked" "no-echo: refused with" \
  '    return TlsError.new("a ServerHello that does not echo the session id", TlsAlert::ILLEGAL_PARAMETER) unless echo == session' '' scenarios
prove_broken "the certificate checked for no host" "wrong-host: refused with" \
  'verified = X509.verify(chain[0], chain[1, chain.size - 1], roots, @host,' 'verified = X509.verify(chain[0], chain[1, chain.size - 1], roots, nil,' scenarios
prove_broken "a KeyUpdate's read keys kept" "keyupdate:" \
  '        @read_secret = @schedule.next_secret(@read_secret)' '' scenarios
prove_broken "a HelloRetryRequest's transcript restarted as something else" "hrr-cookie: refused" \
  '      @transcript = [254_u8, 0_u8, 0_u8, first.size.to_u8] + first + server' '      @transcript = first + server' scenarios
prove_broken "a CertificateRequest not answered" "certreq: the echo came back as" \
  '    if (context = @certificate_request)' '    if (context = nil)' scenarios
# The scripted server hangs up on the unwanted certificate while the
# client is still writing: the echo is wrong, or (Windows) the write fails.
prove_broken "the identity sent whatever schemes the request names" "certreq: " \
  '      scheme = identity ? identity.scheme_for(@requested_schemes) : nil' '      scheme = identity ? identity.schemes[0] : nil' scenarios
prove_broken "a request naming the identity's scheme answered with no certificate" "certreq-ed25519: the echo came back as" \
  '      if identity && scheme' '      if false && identity && scheme' scenarios
prove_broken "the client's CertificateVerify over the server's context string" "certreq-ed25519: the echo came back as" \
  '"TLS 1.3, client CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
        signature = identity.sign(scheme, signed)' '"TLS 1.3, server CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
        signature = identity.sign(scheme, signed)' scenarios
prove_broken "a CertificateRequest without signature_algorithms passed over" "certreq-no-sigalgs: refused with" \
  '    return TlsError.new("a CertificateRequest with no signature_algorithms", TlsAlert::MISSING_EXTENSION) unless schemes' '    return nil unless schemes' scenarios
prove_broken "handshake bytes after Finished passed over" "trailing-after-finished: refused with" \
  '    return TlsError.new("handshake bytes left after the server'"'"'s Finished", TlsAlert::UNEXPECTED_MESSAGE) unless handshake_left == 0' '' scenarios
prove_broken "ALPN answers taken whatever they are" "alpn-unoffered: refused with" \
  'return TlsError.new("the server chose #{chosen.inspect} by ALPN, which was not offered", TlsAlert::NO_APPLICATION_PROTOCOL) unless @config.alpn.includes?(chosen)' '' scenarios
prove_broken "an unknown extension in EncryptedExtensions passed over" "unsolicited-ext: refused with" \
  '        return TlsError.new("extension #{type} in EncryptedExtensions, which was not offered", TlsAlert::UNSUPPORTED_EXTENSION)' '' scenarios
# Past the refusal, any 32 bytes stand in for the secret: the handshake
# goes on to a server that has already hung up.
prove_broken "a share of small order taken" "zero-share:" \
  '      return TlsError.new("the server'"'"'s X25519 share gives no secret", TlsAlert::ILLEGAL_PARAMETER) if shared.is_a?(CurveError)' \
  '      shared = X25519.public_key(private_key) if shared.is_a?(CurveError)' scenarios
prove_broken "a HelloRetryRequest for secp256r1 answered with X25519 again" "hrr-p256: refused" \
  '      if reply.named_group == GROUP_SECP256R1' '      if false' scenarios
prove_broken "a ServerHello's share taken in a group its ClientHello did not send" "sh-wrong-group: refused with" \
  '    return TlsError.new("a ServerHello'"'"'s share in #{group_name(reply.named_group)}, where the share sent was #{group_name(group)}'"'"'s", TlsAlert::ILLEGAL_PARAMETER) unless reply.named_group == group' '' scenarios
# TLS 1.2: opt-in, so the default must be 1.3 alone; then the ServerHello's
# rules against the scripted server's 1.2 ServerHellos, the rest against
# OpenSSL, Python and the man in the middle.
prove_broken "TLS 1.2 offered by default" "tls12: refused with" \
  '  property min_version : TlsVersion = TlsVersion::TLS13' '  property min_version : TlsVersion = TlsVersion::TLS12' scenarios
prove_broken "a TLS 1.2 ServerHello taken from a client not asked for 1.2" "tls12: refused with" \
  '    if !seen.includes?(43) && @config.min_version == TlsVersion::TLS12' '    if !seen.includes?(43)' scenarios
prove_broken "a ClientHello offering TLS 1.2's suites unasked" "tls12: refused with" \
  '    TlsSuites::TLS12.each { |suite| suites = suites + TlsBytes.u16(suite) } if tls12' '    TlsSuites::TLS12.each { |suite| suites = suites + TlsBytes.u16(suite) }' scenarios
prove_broken "the downgrade sentinel unchecked" "tls12-downgrade: refused with" \
  '    if tail == DOWNGRADE_TLS12 || tail == DOWNGRADE_TLS11' '    if false' scenarios
prove_broken "the TLS 1.1 sentinel unchecked" "tls12-downgrade11: refused with" \
  'if tail == DOWNGRADE_TLS12 || tail == DOWNGRADE_TLS11' 'if tail == DOWNGRADE_TLS12' scenarios
prove_broken "the downgrade sentinel unchecked, before a real server" "FAIL the downgrade sentinel written into a TLS 1.2 ServerHello" \
  '    if tail == DOWNGRADE_TLS12 || tail == DOWNGRADE_TLS11' '    if false' client12
prove_broken "a server without the extended master secret taken" "tls12-no-ems: refused with" \
  '    unless extended
      return' '    if false
      return' scenarios
prove_broken "a TLS 1.2 ServerHello's echo of the session id taken" "tls12-resume: refused with" \
  ' if echo == session
' ' if false
' scenarios
prove_broken "a renegotiation_info with something in it taken" "tls12-reneg: refused with" \
  'TlsAlert::HANDSHAKE_FAILURE) unless data == [0_u8]' 'TlsAlert::HANDSHAKE_FAILURE) if false' scenarios
prove_broken "a TLS 1.3 suite taken for TLS 1.2" "tls12-suite13: refused with" \
  'unless TlsSuites::TLS12.includes?(suite)' 'if false' scenarios
prove_broken "the ClientHello's TLS 1.2 offer without the extended master secret" "tls12-hello: refused with" \
  '    extensions = extensions + TlsBytes.extension(23, [] of UInt8)' '' scenarios
prove_broken "the PRF's key expansion under another label" "FAIL s_server -tls1_2, P-256, ECDHE-ECDSA-AES128-GCM-SHA256" \
  '"key expansion"' '"key expansions"' client12
prove_broken "the master secret over the randoms, not the session hash" "FAIL s_server -tls1_2, P-256, ECDHE-ECDSA-AES128-GCM-SHA256" \
  '@schedule.prf(secret, "extended master secret", @schedule.hash(@transcript), 48)' '@schedule.prf(secret, "master secret", client_random + server_random, 48)' client12
prove_broken "the session hash short of the ClientKeyExchange" "FAIL s_server -tls1_2, P-256, ECDHE-ECDSA-AES128-GCM-SHA256" \
  '    flight = flight + key_exchange
    @transcript = @transcript + key_exchange' '    flight = flight + key_exchange' client12
prove_broken "the client's Finished over the PRF's server label" "FAIL s_server -tls1_2, RSA, ECDHE-RSA-AES128-GCM-SHA256" \
  '"client finished"' '"server finished"' client12
prove_broken "AES-GCM's explicit nonce sent and not sealed with" "FAIL s_server -tls1_2, P-256, ECDHE-ECDSA-AES256-GCM-SHA384" \
  'gcm.seal(@iv + explicit, content, aad)' 'gcm.seal(@iv + Array(UInt8).new(8, 0_u8), content, aad)' client12
prove_broken "AES-GCM's explicit nonce read as the sequence number" "FAIL s_server -tls1_2, P-256, ECDHE-ECDSA-AES128-GCM-SHA256" \
  'gcm.open(@iv + body[0, 8], ' 'gcm.open(@iv + sequence_bytes, ' client12
prove_broken "TLS 1.2's ChaCha20-Poly1305 nonce without the sequence number" "FAIL s_server -tls1_2, RSA, ECDHE-RSA-CHACHA20-POLY1305" \
  '             TlsBytes.of(chacha.seal(nonce, content, aad))' '             TlsBytes.of(chacha.seal(@iv, content, aad))' client12
prove_broken "TLS 1.2's additional data without the sequence number" "FAIL s_server -tls1_2, RSA, ECDHE-RSA-AES256-GCM-SHA384" \
  '    aad = explicit + [type, 3_u8, 3_u8] + TlsBytes.u16(content.size)' '    aad = [type, 3_u8, 3_u8] + TlsBytes.u16(content.size)' client12
prove_broken "the ServerKeyExchange's signature unchecked" "FAIL a ServerKeyExchange's signature one bit off" \
  '    return TlsError.new("the server'"'"'s ServerKeyExchange is not its key'"'"'s signature", TlsAlert::DECRYPT_ERROR) unless ok' '' client12
prove_broken "the ServerKeyExchange signed without the client's random" "FAIL s_server -tls1_2, P-256, ECDHE-ECDSA-AES128-GCM-SHA256" \
  '    exchange = server_key_exchange(message, leaf, client_random + server_random)' '    exchange = server_key_exchange(message, leaf, server_random + client_random)' client12
prove_broken "PKCS #1 v1.5 refused in a ServerKeyExchange" "FAIL a ServerKeyExchange under rsa_pkcs1_sha256" \
  '         when 0x0401, 0x0501, 0x0601' '         when 0x0201' client12
prove_broken "a HelloRequest left unanswered" "FAIL a HelloRequest" \
  '        @renegotiation_refused = true' '' client12
prove_broken "TLS 1.2's exporter over the randoms in the server's order" "FAIL the TLS 1.2 exporter" \
  '    @randoms12 = client_random + server_random' '    @randoms12 = server_random + client_random' client12
# The server's own checks, each before the scripted client: the scenario
# that breaks the rule must be reported as answered wrongly.
prove_broken "the client's Finished unchecked" "FAIL bad-finished " \
  '    unless Subtle.constant_time_compare(message[4, message.size - 4], expected)
      return TlsError.new("the client'"'"'s Finished' '    if false
      return TlsError.new("the client'"'"'s Finished' server
prove_broken "the server's CertificateVerify over the client's context string" "FAIL ok " \
  '"TLS 1.3, server CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
    signature = @identity.sign(@scheme, signed)' '"TLS 1.3, client CertificateVerify") + [0_u8] + @schedule.hash(@transcript)
    signature = @identity.sign(@scheme, signed)' server
prove_broken "the server's HelloRetryRequest transcript restarted as something else" "FAIL hrr " \
  '      @transcript = [254_u8, 0_u8, 0_u8, first.size.to_u8] + first + retry' '      @transcript = first + retry' server
prove_broken "the server's writes kept on its handshake keys after its Finished" "FAIL ok " \
  '    @writer = TlsRecordCipher.new(@suite, @schedule, server_application)
    @write_secret = server_application' '    @write_secret = server_application' server
prove_broken "early data under keys the server lacks not passed over" "FAIL early-skip " \
  '      if opened.is_a?(TlsError) && opened.alert == TlsAlert::BAD_RECORD_MAC && @early_left > 0 && body.size <= @early_left' '      if false' server
prove_broken "early data before a second ClientHello not passed over" "FAIL early-after-hrr " \
  '        if @early_left > 0 && body.size <= @early_left' '        if false' server
prove_broken "a ChangeCipherSpec during the handshake not passed over" "FAIL ccs " \
  '      if type == TlsRecords::CHANGE_CIPHER_SPEC && @handshaking' '      if type == TlsRecords::CHANGE_CIPHER_SPEC && false' server
prove_broken "a ClientHello's duplicate extension taken" "FAIL dup-ext " \
  '      return TlsError.new("extension #{type} twice in a ClientHello", TlsAlert::ILLEGAL_PARAMETER) if seen.has_key?(type)' '' server
prove_broken "pre_shared_key's place unchecked" "FAIL psk-not-last " \
  '      return TlsError.new("pre_shared_key not last in a ClientHello", TlsAlert::ILLEGAL_PARAMETER) if seen.has_key?(41)' '' server
prove_broken "a compression method taken" "FAIL compression " \
  '    return TlsError.new("a ClientHello whose compression methods are not null alone", TlsAlert::ILLEGAL_PARAMETER) unless compression == [0_u8]' '' server
prove_broken "a session id of any length echoed" "FAIL long-session " \
  '    return TlsError.new("a ClientHello with a session id of #{session.size} bytes", TlsAlert::ILLEGAL_PARAMETER) if session.size > 32' '' server
prove_broken "a client without ed25519 answered anyway" "FAIL no-ed25519 " \
  '    return @identity if @identity.scheme_for(schemes)' '    return @identity' server
prove_broken "a client without ecdsa_secp256r1_sha256 answered anyway by a P-256 server" "FAIL no-p256 " \
  '    return @identity if @identity.scheme_for(schemes)' '    return @identity' server-p256
prove_broken "a P-256 CertificateVerify signed over SHA-384" "FAIL ok " \
  '      key.sign(EcdsaHash::SHA256, content)' '      key.sign(EcdsaHash::SHA384, content)' server-p256
prove_broken "a P-256 key that is not the certificate's taken" "FAIL another P-256 key" \
  '    return TlsError.new("the private key is not the certificate'"'"'s") unless public.x == key.public_key.x && public.y == key.public_key.y' '' config
# An RSA server: the client's order of RSA-PSS schemes, each scheme's
# hash, PKCS #1 v1.5 never, and the key the certificate's.
prove_broken "a client without RSA-PSS answered anyway by an RSA server" "FAIL no-rsa-pss " \
  '    return @identity if @identity.scheme_for(schemes)' '    return @identity' server-rsa
prove_broken "the server's order of RSA-PSS schemes put before the client's" "FAIL pss-sha384 " \
  '    offered.find { |scheme| @schemes.includes?(scheme) }' '    @schemes.find { |scheme| offered.includes?(scheme) }' server-rsa
prove_broken "rsa_pss_rsae_sha384 signed over SHA-256" "FAIL pss-sha384 " \
  'scheme == RSA_PSS_SHA384 ? RsaHash::SHA384' 'scheme == RSA_PSS_SHA384 ? RsaHash::SHA256' server-rsa
prove_broken "rsa_pss_rsae_sha512 signed over SHA-384" "FAIL pss-sha512 " \
  ' : RsaHash::SHA512), content)' ' : RsaHash::SHA384), content)' server-rsa
prove_broken "PKCS #1 v1.5 among an RSA key's schemes" "FAIL no-rsa-pss " \
  '[RSA_PSS_SHA256, RSA_PSS_SHA384, RSA_PSS_SHA512], nil, nil, key)' '[0x0401, RSA_PSS_SHA256, RSA_PSS_SHA384, RSA_PSS_SHA512], nil, nil, key)' server-rsa
prove_broken "an RSA key that is not the certificate's taken" "FAIL another RSA key" \
  '    unless public.modulus == key.public_key.modulus && public.exponent == key.public_key.exponent' '    if false' config
prove_broken "an RSA PRIVATE KEY block passed over" "FAIL a 4096-bit RSA chain and its PKCS #1 key" \
  '    count = pkcs8.size + sec1.size + pkcs1.size' '    count = pkcs8.size + sec1.size' config
prove_broken "a second ClientHello's session id unchecked" "FAIL hrr-other-session " \
  '      return TlsError.new("a second ClientHello with another session id", TlsAlert::ILLEGAL_PARAMETER) unless again.session == offer.session' '' server
prove_broken "the server's suite order put before the client's" "FAIL client-order " \
  '    @suite = offer.suites.find { |s| SUITES.includes?(s) } || 0' '    @suite = SUITES.find { |s| offer.suites.includes?(s) } || 0' server
prove_broken "the client's ALPN order put before the server's" "FAIL alpn-order " \
  '    @config.alpn.find { |protocol| wanted.includes?(protocol) }' '    wanted.find { |protocol| @config.alpn.includes?(protocol) }' server
prove_broken "an ALPN offer with nothing in common answered anyway" "FAIL alpn-mismatch " \
  '    if (wanted = offer.alpn) && !@config.alpn.empty? && @alpn_protocol.nil?' '    if (wanted = offer.alpn) && @config.alpn.empty? && @alpn_protocol.nil?' server
prove_broken "no alert sent before hanging up" "FAIL dup-ext " \
  '    code = error.alert' '    code = nil.as(UInt8?)' server
prove_broken "an alert in the clear after the server's keys" "FAIL bad-finished " \
  '      sent = if @writer' '      sent = if false' server
prove_broken "a private key that is not the certificate's taken" "FAIL another key" \
  '    return TlsError.new("the private key is not the certificate'"'"'s") unless TlsBytes.of(Ed25519.public_key(seed)) == key.bytes' '' config
prove_broken "a secp256r1 share taken before an X25519 one" "FAIL both-shares " \
  '    @x25519 ? TlsConnection::GROUP_X25519 : (@p256 ? TlsConnection::GROUP_SECP256R1 : 0)' '    @p256 ? TlsConnection::GROUP_SECP256R1 : (@x25519 ? TlsConnection::GROUP_X25519 : 0)' server
prove_broken "a HelloRetryRequest for secp256r1 whatever the groups" "FAIL hrr " \
  '      group = offer.groups.includes?(GROUP_X25519) ? GROUP_X25519 : GROUP_SECP256R1' '      group = GROUP_SECP256R1' server
prove_broken "the server's secp256r1 share not its key's" "FAIL p256-share " \
  '      public = ephemeral.public_point' '      public = p256_ephemeral.public_point' server
prove_broken "an exporter under another label" "FAIL the client exported" \
  '    @schedule.expand_label(secret, "exporter", @schedule.hash(context), length)' '    @schedule.expand_label(secret, "exported", @schedule.hash(context), length)' client-export
prove_broken "the exporter's secret over the transcript to the client's flight" "FAIL the client exported" \
  '    @exporter_secret = @schedule.derive_secret(master, "exp master", @transcript)

    # The client'"'"'s flight:' '    @exporter_secret = @schedule.derive_secret(master, "exp master", @transcript + @transcript)

    # The client'"'"'s flight:' client-export
prove_broken "a server_name's own certificate passed over" "FAIL sni-other " \
  '      @others.each { |other| return other if other.leaf.matches_host?(name) && other.scheme_for(schemes) }' '' server
prove_broken "a client that hangs up without an alert" "FAIL no alert read by OpenSSL" \
  '    return client.fail(problem) if problem' '    return problem if problem' client-alert
prove_broken "a handshake bounded by each wait alone" "FAIL slow-hello " \
  '    return @socket.read(buffer, count) if @deadline_ns == 0_i64' '    return @socket.read(buffer, count) if true' server
prove_broken "a handshake message rebuilt for each record of it" "FAIL byte-records " \
  '    @handshake.concat(content)' '    @handshake = @handshake + content' server
prove_broken "ChangeCipherSpec records passed over without end" "FAIL ccs-flood " \
  '    return TlsError.new("more than #{MAX_CCS} ChangeCipherSpec records", TlsAlert::UNEXPECTED_MESSAGE) if @ccs_seen > MAX_CCS' '' server
prove_broken "a ChangeCipherSpec before the ClientHello passed over" "FAIL ccs-first " \
  '    return TlsError.new("a ChangeCipherSpec before the ClientHello", TlsAlert::UNEXPECTED_MESSAGE) if server_side? && @transcript.empty?' '' server
prove_broken "handshake bytes after the ClientHello taken under the keys" "FAIL hello-and-more " \
  '    return TlsError.new("handshake bytes after the ClientHello in its record", TlsAlert::UNEXPECTED_MESSAGE) unless handshake_left == 0' '' server
prove_broken "a second ClientHello's suite unchecked" "FAIL hrr-other-suite " \
  '      return TlsError.new("a second ClientHello that leaves out the suite chosen", TlsAlert::ILLEGAL_PARAMETER) unless again.suites.includes?(@suite)' '' server
prove_broken "early data in a second ClientHello taken" "FAIL hrr-early-again " \
  '      return TlsError.new("a second ClientHello offering early data", TlsAlert::ILLEGAL_PARAMETER) if again.early_data' '' server
prove_broken "early data passed over after the second ClientHello" "FAIL junk-after-hrr " \
  '      # (section 4.2.10): nothing after it is passed over.
      @early_left = 0' '      # (section 4.2.10): nothing after it is passed over.' server
prove_broken "any record that does not open passed over as early data" "FAIL early-malformed " \
  'opened.alert == TlsAlert::BAD_RECORD_MAC && ' '' server
prove_broken "a server_name of two host names taken" "FAIL sni-two " \
  '          return TlsError.new("a server_name with two host names", TlsAlert::ILLEGAL_PARAMETER) if server_name' '' server
prove_broken "a server_name of any bytes taken" "FAIL sni-bad " \
  '          unless name.all? { |b| b > 0x20_u8 && b < 0x7F_u8 } && name[name.size - 1] != 0x2E_u8' '          unless true' server
prove_broken "a client certificate entry's extensions passed over" "FAIL mtls-entry-ext " \
  '      return TlsError.new("a client certificate entry with extensions nobody asked for", TlsAlert::UNSUPPORTED_EXTENSION) unless entry_extensions.empty?' '' server-mtls
prove_broken "a CertificateRequest sent to a client the server was not told to ask" "FAIL ok " \
  '    if @config.client_roots
      request = certificate_request' '    if true
      request = certificate_request' server
prove_broken "the client's CertificateVerify unchecked" "FAIL mtls-bad-cv " \
  '    return TlsError.new("#{@peer}'"'"'s CertificateVerify is not its key'"'"'s signature", TlsAlert::DECRYPT_ERROR) unless ok' '' server-mtls
prove_broken "the client's CertificateVerify checked under the server's context string" "FAIL mtls-ok " \
  '    problem = certificate_verify(verify, chain[0], "client")' '    problem = certificate_verify(verify, chain[0], "server")' server-mtls
prove_broken "a client certificate checked for serverAuth" "FAIL mtls-ok " \
  '@config.now || Time.utc, X509Purpose::Client)' '@config.now || Time.utc, X509Purpose::Server)' server-mtls
prove_broken "a client with no certificate let in" "FAIL mtls-none " \
  '      return TlsError.new("the client sent no certificate", TlsAlert::CERTIFICATE_REQUIRED) if @config.client_required' '' server-mtls
prove_broken "a client Certificate's request context unchecked" "FAIL mtls-context " \
  '    return TlsError.new("a client Certificate whose request context is not the server'"'"'s", TlsAlert::ILLEGAL_PARAMETER) unless context.empty?' '' server-mtls
prove_broken "a certificate required where it is optional" "FAIL mtls-optional-none " \
  '      return TlsError.new("the client sent no certificate", TlsAlert::CERTIFICATE_REQUIRED) if @config.client_required' '      return TlsError.new("the client sent no certificate", TlsAlert::CERTIFICATE_REQUIRED)' server-mtls-optional
prove_broken "a refused client's flight left unread at the close" "FAIL mtls-late " \
  '      linger if server_side? && !sent' '' server-mtls
prove_broken "a client certificate with no CertificateVerify after it taken" "FAIL mtls-no-cv " \
  '    return TlsError.new("#{TlsBytes.handshake_name(verify[0])} where the client'"'"'s CertificateVerify belongs", TlsAlert::UNEXPECTED_MESSAGE) unless verify[0] == 15_u8' '' server-mtls
prove_broken "a client Certificate of any length searched" "FAIL mtls-long-chain " \
  '      return TlsError.new("a client Certificate of more than #{X509::MAX_CHAIN} certificates", TlsAlert::BAD_CERTIFICATE) if chain.size == X509::MAX_CHAIN' '' server-mtls
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
