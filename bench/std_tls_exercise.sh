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
# serving - on an Ed25519 key, a P-256 one, a P-384 one, a 2048-bit RSA
# one (PKCS #8) and a 4096-bit RSA one (PKCS #1) - bench/std_tls_client.py, the scripted
# client's every scenario, a handshake checked step by step or one rule
# broken and the alert named; the std/tls client, Python's ssl, OpenSSL's
# s_client (an RSA server held to the RSA-PSS scheme the client lists
# first, and refusing a client that offers PKCS #1 v1.5 alone), curl and
# Node; client certificates of each kind, RSA among them. X25519MLKEM768 is
# held at both ends to OpenSSL's s_server and s_client (s_client naming the
# group it negotiated) and Python's ssl, where their OpenSSL is 3.5 or
# later, to the std/tls client and server between them, and to the
# scripted peers' hybrid scenarios - shares and ciphertexts of the wrong
# size, a ciphertext of random bytes, a HelloRetryRequest for a share
# already sent. Then the server told to speak TLS 1.2 too, on each key:
# the scripted client's 1.2 handshakes and refusals, s_client -tls1_2
# across suites, schemes, groups, -no_ems, -fallback_scsv, a renegotiation
# and the exporter, Python's ssl, curl and Node held to 1.2, the std/tls
# client answered in 1.3 and its 1.2-alone copy meeting the downgrade
# sentinel; client certificates in 1.2. Then OCSP stapling: the client
# against s_server -status_file's good, revoked, unknown and broken
# staples and none, in 1.3 and 1.2, must-staple and require_staple, and
# the server stapling for s_client -status and the std/tls client. It shows an
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
# The scratch directory of the helpers that a broken copy also runs
# (client_alert to client_hybrid, tls12_round, server12_round): the gate's
# own here, and each copy's own in its subshell, so that copies run side
# by side keep their servers' ports, logs and directories apart.
CW="$WORK"

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
for phrase in "== RFC 8448's simple 1-RTT handshake, through the key schedule" "== the trace's records, sealed and opened" "== TLS 1.2's PRF, through the key schedule" "== server_name's form (RFC 6066 section 3)" "== a session's tickets, between this run's own client and server"; do
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
    # The end of the log, where Python names the exception: its first five
    # lines are the traceback's frames and never say what failed.
    echo "  the scripted server did not start:"
    tail -5 "$WORK/server.log" | sed 's/^/    /'
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
hybrid_openssl=no
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
    for kind in p256 p384 p521 rsa ed25519; do
      case $kind in
        p256) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-256" ;;
        p384) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-384" ;;
        p521) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-521" ;;
        rsa) opt="-newkey rsa:2048" ;;
        ed25519) opt="-newkey ed25519" ;;
      esac
      # shellcheck disable=SC2086
      "$OPENSSL" req -new -config leaf.cnf $opt -nodes -keyout $kind.key -out $kind.csr &&
        "$OPENSSL" x509 -req -in $kind.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $kind.pem -days 20 -extfile leaf.ext
    done
    # A leaf for an internationalised name, by its A-label (bücher.example),
    # which s_server sends for that server_name alone.
    printf 'subjectAltName=DNS:xn--bcher-kva.example\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' >idn.ext
    "$OPENSSL" req -new -config leaf.cnf -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout idn.key -out idn.csr &&
      "$OPENSSL" x509 -req -in idn.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out idn.pem -days 20 -extfile idn.ext
    # Client certificates, for clientAuth, as std/tls presents them.
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' >client.ext
    for kind in p256 p384 ed25519 rsa; do
      case $kind in
        p256) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-256" ;;
        p384) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-384" ;;
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
      >"$CW/s_server-alert.log" 2>&1 </dev/null &
    pid=$!
    for _ in $(seq 1 50); do
      "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
      sleep 0.1
    done
    "$1" get "$port" "$PKI/ca.pem" example.com >/dev/null 2>&1
    sleep 0.3
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if grep -q "SSL alert number 42" "$CW/s_server-alert.log"; then
      echo "  the std/tls client's refusal, as OpenSSL read it: alert bad_certificate (42)"
      return 0
    fi
    echo "  FAIL no alert read by OpenSSL: $(tail -2 "$CW/s_server-alert.log" | tr '\n' ' ')"
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
    : >"$CW/s_server-export.log"
    { sleep 6 | "$OPENSSL" s_server -accept "127.0.0.1:$port" -naccept 1 -tls1_3 -cert "$PKI/p256.pem" -key "$PKI/p256.key" \
      -keymatexport "EXPERIMENTAL iyi" -keymatexportlen 16 >"$CW/s_server-export.log" 2>&1; } &
    pid=$!
    for _ in $(seq 1 50); do
      grep -q ACCEPT "$CW/s_server-export.log" && break
      sleep 0.1
    done
    got="$(TLS_EXPORT="EXPERIMENTAL iyi" "$1" get "$port" "$PKI/ca.pem" localhost 2>&1 | grep -o 'exported=[0-9a-f]*' | cut -d= -f2)"
    # The server goes when its stdin ends, after the connection.
    wait "$pid" 2>/dev/null
    theirs="$(grep -o 'Keying material: [0-9A-Fa-f]*' "$CW/s_server-export.log" | head -1 | cut -d' ' -f3 | tr 'A-F' 'a-f')"
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
  # client_sni <binary>: the server_name its std/tls client sends for a
  # host written in Unicode with a final dot, and for an ASCII one with a
  # final dot, as OpenSSL's server reads it. `-servername` with
  # `-servername_fatal` makes s_server refuse any other name with alert
  # unrecognized_name, and send `-cert2` - the leaf for that name, where
  # `-cert` names another - only for that one, so a handshake that checks
  # proves the name matched; `-msg` makes it print the name it read
  # ("Hostname in TLS extension"). RFC 6066 section 3: ASCII, A-labels,
  # no trailing dot. Before, both went out as written and were refused.
  client_sni() {
    local bin="$1" failed=0 host name first second port pid got
    for case_line in "bücher.example.|xn--bcher-kva.example|p256|idn" "localhost.|localhost|idn|p256"; do
      IFS='|' read -r host name first second <<<"$case_line"
      port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
      # The name's own leaf is the second: sent only when the name matches.
      "$OPENSSL" s_server -accept "127.0.0.1:$port" -www -msg -tls1_3 -cert "$PKI/$first.pem" -key "$PKI/$first.key" \
        -cert2 "$PKI/$second.pem" -key2 "$PKI/$second.key" -servername "$name" -servername_fatal >"$CW/s_server-sni.log" 2>&1 </dev/null &
      pid=$!
      for _ in $(seq 1 50); do
        "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
        sleep 0.1
      done
      got="$("$bin" get "$port" "$PKI/ca.pem" "$host" 2>&1)"
      sleep 0.2
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      if ! printf '%s' "$got" | grep -qF "HTTP/1.0 200 ok"; then
        echo "  FAIL server_name for \"$host\": $got"
        failed=1
      elif ! grep -q "Hostname in TLS extension" "$CW/s_server-sni.log"; then
        echo "  server_name for \"$host\": s_server took it under -servername_fatal; this s_server does not print the name it read"
      elif ! grep -qF "Hostname in TLS extension: \"$name\"" "$CW/s_server-sni.log"; then
        echo "  FAIL server_name for \"$host\": s_server read $(grep -m1 'Hostname in TLS extension' "$CW/s_server-sni.log")"
        failed=1
      else
        echo "  server_name for \"$host\", as OpenSSL read it: \"$name\", and its certificate checked: $got"
      fi
    done
    return $failed
  }
  if client_sni "$WORK/tls-release"; then
    interop=$((interop + 2))
  else
    status=1
  fi
  # client_resume <binary>: its std/tls client through one TlsSession to
  # OpenSSL's s_server, which issues tickets: three connections, the first
  # new and the next two resumed by them, as s_server's own -www page says
  # ("Reused, TLSv1.3") and the client too, the server's certificate still
  # its peer's; under the default suites, under AES-256-GCM alone (a
  # SHA-384 ticket), and with secp256r1 alone, so that the ClientHello that
  # resumes follows a HelloRetryRequest its binder covers.
  client_resume() {
    local failed=0 port pid got label extra
    for case in "the default suites:" "AES-256-GCM alone:-ciphersuites TLS_AES_256_GCM_SHA384" \
      "secp256r1 alone, through a HelloRetryRequest:-groups P-256"; do
      label="${case%%:*}"
      extra="${case#*:}"
      port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
      # shellcheck disable=SC2086
      "$OPENSSL" s_server -accept "127.0.0.1:$port" -www -tls1_3 -cert "$PKI/p256.pem" -key "$PKI/p256.key" $extra \
        >"$CW/s_server-resume.log" 2>&1 </dev/null &
      pid=$!
      for _ in $(seq 1 50); do
        "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
        sleep 0.1
      done
      got="$("$1" resume "$port" "$PKI/ca.pem" localhost - 3 2>&1)"
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      if printf '%s\n' "$got" | sed -n 1p | grep -q 'resumed=no .*peer=CN=localhost said=New, TLSv1.3' &&
         [ "$(printf '%s\n' "$got" | grep -c 'resumed=yes .*peer=CN=localhost said=Reused, TLSv1.3')" = 2 ]; then
        echo "  resumed by OpenSSL's tickets, $label: $(printf '%s\n' "$got" | sed -n 2p)"
      else
        echo "  FAIL resumed by OpenSSL's tickets, $label: $(printf '%s' "$got" | tr '\n' ' ')"
        failed=1
      fi
    done
    return $failed
  }
  # client_early <binary>: its std/tls client giving each of two
  # connections through one session "iyi-early-data" to send early, to
  # OpenSSL's s_server: with -early_data the first sends it after the
  # handshake (no ticket yet) and the second with its ClientHello, which
  # s_server reads as early data ("Early data received:"); without it the
  # ticket allows none and both send it late; with secp256r1 alone, the
  # HelloRetryRequest refuses it and it is sent again after the handshake.
  client_early() {
    local failed=0 port pid got label extra want log="$CW/s_server-early.log"
    for case in "taken:Accepted:-early_data" "a server that takes none:Late:" "through a HelloRetryRequest:Resent:-early_data -groups P-256"; do
      label="${case%%:*}"
      want="${case#*:}"
      extra="${want#*:}"
      want="${want%%:*}"
      port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
      : >"$log"
      # shellcheck disable=SC2086
      { sleep 5 | "$OPENSSL" s_server -accept "127.0.0.1:$port" -naccept 2 -tls1_3 -cert "$PKI/p256.pem" -key "$PKI/p256.key" $extra >"$log" 2>&1; } &
      pid=$!
      for _ in $(seq 1 50); do grep -q ACCEPT "$log" && break; sleep 0.1; done
      got="$("$1" resume "$port" "$PKI/ca.pem" localhost - 2 iyi-early-data 2>&1)"
      wait "$pid" 2>/dev/null
      if printf '%s\n' "$got" | sed -n 1p | grep -q 'early=Late resumed=no' &&
         printf '%s\n' "$got" | sed -n 2p | grep -q "early=$want " &&
         # After a HelloRetryRequest s_server sees the ticket a second time,
         # which its own anti-replay answers with a full handshake.
         { [ "$want" = Resent ] || printf '%s\n' "$got" | sed -n 2p | grep -q 'resumed=yes'; } &&
         [ "$(grep -o iyi-early-data "$log" | wc -l | tr -d ' ')" = 2 ] &&
         { [ "$want" != Accepted ] || grep -q 'Early data received:' "$log"; }; then
        echo "  early data to OpenSSL's s_server, $label: $(printf '%s\n' "$got" | sed -n 2p)$([ "$want" = Accepted ] && echo ', and s_server: Early data received')"
      else
        echo "  FAIL early data to OpenSSL's s_server, $label: $(printf '%s' "$got" | tr '\n' ' '); s_server: $(grep -i 'early' "$log" | tr '\n' ' ')"
        failed=1
      fi
    done
    return $failed
  }
  if client_early "$WORK/tls-release"; then
    interop=$((interop + 3))
  else
    status=1
  fi
  if client_resume "$WORK/tls-release"; then
    interop=$((interop + 3))
  else
    status=1
  fi
  # TLS 1.2 is not offered unless asked for (the next section asks): a
  # server of 1.2 alone refuses the ClientHello, which offers it nothing.
  interop "TLS 1.2 alone, not asked for" "alert protocol_version (70)" localhost - -tls1_2 -cert p256.pem -key p256.key
  interop "secp256r1 alone, asked for by a HelloRetryRequest" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert p256.pem -key p256.key -groups P-256
  interop "secp384r1 alone, asked for by a HelloRetryRequest, a P-384 certificate" "HTTP/1.0 200 ok TLS_AES_128_GCM_SHA256 alpn=- TLSv1.3 group=secp384r1" localhost - -tls1_3 -cert p384.pem -key p384.key -groups P-384
  interop "secp384r1 alone and ecdsa_secp384r1_sha384 alone" "TLSv1.3 group=secp384r1" localhost - -tls1_3 -cert p384.pem -key p384.key -groups P-384 -sigalgs ECDSA+SHA384
  interop "groups the client offers none of" "alert handshake_failure (40)" localhost - -tls1_3 -cert p256.pem -key p256.key -groups P-521
  # X25519MLKEM768, where this OpenSSL has it (3.5 on; the Linux
  # container's 3.0 has not): alone, by OpenSSL's own default groups (which
  # put it first), behind a stateless server's cookie, and refused by a
  # client told not to offer it.
  # client_hybrid <binary>: its std/tls client against s_server offering
  # X25519MLKEM768 alone, which must hold in that group.
  client_hybrid() {
    local port pid got
    port="$("$PY" -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
    "$OPENSSL" s_server -accept "127.0.0.1:$port" -www -tls1_3 -cert "$PKI/p256.pem" -key "$PKI/p256.key" -groups X25519MLKEM768 \
      >"$CW/s_server-hybrid.log" 2>&1 </dev/null &
    pid=$!
    for _ in $(seq 1 50); do
      "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
      sleep 0.1
    done
    got="$("$1" get "$port" "$PKI/ca.pem" localhost 2>&1)"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if printf '%s' "$got" | grep -qF "HTTP/1.0 200 ok" && printf '%s' "$got" | grep -qF "group=X25519MLKEM768"; then
      echo "  X25519MLKEM768 alone: $got"
      return 0
    fi
    echo "  FAIL s_server -groups X25519MLKEM768: $got"
    return 1
  }
  hybrid_openssl=no
  if "$OPENSSL" list -kem-algorithms 2>/dev/null | grep -q 'X25519MLKEM768'; then
    hybrid_openssl=yes
    if client_hybrid "$WORK/tls-release"; then
      interop=$((interop + 1))
    else
      status=1
    fi
    interop "OpenSSL's default groups, X25519MLKEM768 first" "group=X25519MLKEM768" localhost - -tls1_3 -cert p256.pem -key p256.key
    interop "X25519MLKEM768 alone, stateless: a HelloRetryRequest with a cookie" "group=X25519MLKEM768" localhost - -tls1_3 -cert p256.pem -key p256.key \
      -groups X25519MLKEM768 -stateless
    TLS_POST_QUANTUM=0 interop "X25519MLKEM768 alone, to a client told not to offer it" "alert handshake_failure (40)" localhost - -tls1_3 \
      -cert p256.pem -key p256.key -groups X25519MLKEM768
  else
    echo "  $("$OPENSSL" version) has no X25519MLKEM768 (OpenSSL has it from 3.5), so the client's hybrid goes unasked by it"
  fi
  # A client certificate required and checked: -verify_return_error ends
  # the handshake on any fault OpenSSL finds in the chain or its signature.
  mtls=(-tls1_3 -cert p256.pem -key p256.key -Verify 1 -verify_return_error -CAfile ca.pem)
  interop "a client certificate required, none held" "alert certificate_required (116)" localhost - "${mtls[@]}"
  identity=(client-p256.pem client-p256.key)
  interop "a client certificate required, a P-256 one presented" "HTTP/1.0 200 ok" localhost - "${mtls[@]}"
  identity=(client-ed25519.pem client-ed25519.key)
  interop "a client certificate required, an Ed25519 one presented" "HTTP/1.0 200 ok" localhost - "${mtls[@]}"
  identity=(client-p384.pem client-p384.key)
  interop "a client certificate required, a P-384 one presented" "HTTP/1.0 200 ok" localhost - "${mtls[@]}"
  interop "a request naming ecdsa_secp384r1_sha384 alone, a P-384 one presented" "HTTP/1.0 200 ok" localhost - "${mtls[@]}" -client_sigalgs ECDSA+SHA384
  interop "a request naming ecdsa_secp256r1_sha256 alone, a P-384 one held back" "alert certificate_required (116)" \
    localhost - "${mtls[@]}" -client_sigalgs ECDSA+SHA256
  identity=(client-ed25519.pem client-ed25519.key)
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
# and RSA-PSS, ECDSA under SHA-384, Ed25519; secp256r1 and secp384r1; a
# P-384 certificate; ALPN; a server without the extended master secret
# (-no_ems) refused by name, a P-521 certificate refused by the server
# (the ClientHello names no P-521, RFC 8422 section 5.1.1), client
# certificates of each kind; the exporter against OpenSSL's; a
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
      "$OPENSSL" s_server -accept "127.0.0.1:$port" -www "$@" >"$CW/s12.log" 2>&1 </dev/null &
      pid=$!
      wait_port "$port"
      if [ "$mode" = direct ]; then
        got="$(TLS_MIN_VERSION=1.2 "$bin" get "$port" ca.pem localhost "${ALPN12:--}" ${CLIENT12[@]+"${CLIENT12[@]}"} 2>&1)"
      else
        rm -f "$CW/proxyport"
        "$PY" "$REPO/bench/std_tls12_proxy.py" "$CW/proxyport" "$port" "$mode" >"$CW/proxy.log" 2>&1 &
        proxy=$!
        for _ in $(seq 1 50); do [ -s "$CW/proxyport" ] && break; sleep 0.1; done
        got="$(TLS_MIN_VERSION=1.2 "$bin" get "$(cat "$CW/proxyport")" ca.pem localhost 2>&1)"
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
    one "secp384r1 alone" "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 alpn=- TLSv1.2 group=secp384r1" direct -tls1_2 -cert p256.pem -key p256.key -groups P-384
    one "a P-384 certificate, its ServerKeyExchange under ECDSA with SHA-384" "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256" direct -tls1_2 -cert p384.pem -key p384.key -sigalgs ECDSA+SHA384
    ALPN12=http/1.1 one "ALPN" "alpn=http/1.1 TLSv1.2" direct -tls1_2 -cert p256.pem -key p256.key -alpn http/1.1
    # `-no_ems` is not in every s_server: the OpenSSL 3.0 of the Linux CI
    # container has none, its s_server did not start, and the client found
    # no connection.
    if "$OPENSSL" s_server -help 2>&1 | grep -q -- '-no_ems'; then
      one "a server without the extended master secret" "does not do the extended master secret (RFC 7627), which a TLS 1.2 handshake here requires (handshake_failure)" \
        direct -tls1_2 -cert p256.pem -key p256.key -no_ems
    else
      echo "  a server without the extended master secret: this OpenSSL ($("$OPENSSL" version | cut -d' ' -f2)) cannot serve one, so it goes unasked"
    fi
    one "a P-521 certificate, which this ClientHello's groups rule out" "the server sent alert handshake_failure (40)" direct -tls1_2 -cert p521.pem -key p521.key
    local kind
    for kind in p256 p384 ed25519 rsa; do
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
    : >"$CW/s12-export.log"
    { sleep 6 | "$OPENSSL" s_server -accept "127.0.0.1:$port" -naccept 1 -tls1_2 -cert p256.pem -key p256.key \
      -keymatexport "EXPERIMENTAL iyi" -keymatexportlen 16 >"$CW/s12-export.log" 2>&1; } &
    pid=$!
    for _ in $(seq 1 50); do grep -q ACCEPT "$CW/s12-export.log" && break; sleep 0.1; done
    got="$(TLS_MIN_VERSION=1.2 TLS_EXPORT="EXPERIMENTAL iyi" "$bin" get "$port" ca.pem localhost 2>&1 | grep -o 'exported=[0-9a-f]*' | cut -d= -f2)"
    wait "$pid" 2>/dev/null
    local theirs
    theirs="$(grep -o 'Keying material: [0-9A-Fa-f]*' "$CW/s12-export.log" | head -1 | cut -d' ' -f3 | tr 'A-F' 'a-f')"
    if [ -n "$got" ] && [ "$got" = "$theirs" ]; then
      echo "  exported for \"EXPERIMENTAL iyi\" over TLS 1.2, the same at both ends: $got"
    else
      echo "  FAIL the TLS 1.2 exporter: the client's '$got', OpenSSL's '$theirs'"
      failed=1
    fi
    # A HelloRequest: s_server renegotiates ("r" on its stdin) once "first"
    # has reached it; its -msg log must show the no_renegotiation warning.
    port="$(free_port)"
    rm -f "$CW/fifo12" && mkfifo "$CW/fifo12"
    : >"$CW/s12-reneg.log"
    "$OPENSSL" s_server -accept "127.0.0.1:$port" -naccept 1 -tls1_2 -msg -cert p256.pem -key p256.key <"$CW/fifo12" >"$CW/s12-reneg.log" 2>&1 &
    pid=$!
    exec 7>"$CW/fifo12"
    for _ in $(seq 1 50); do grep -q ACCEPT "$CW/s12-reneg.log" && break; sleep 0.1; done
    "$bin" renegotiate "$port" ca.pem localhost >"$CW/reneg.out" 2>&1 &
    local client=$!
    for _ in $(seq 1 50); do grep -q '^first' "$CW/s12-reneg.log" && break; sleep 0.1; done
    # In a subshell: a server already gone would SIGPIPE the gate itself.
    (echo r >&7) 2>/dev/null
    wait "$client"
    exec 7>&-
    sleep 0.3
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    if grep -q 'HelloRequest' "$CW/s12-reneg.log" && grep -q 'warning no_renegotiation' "$CW/s12-reneg.log"; then
      echo "  a HelloRequest answered: OpenSSL read \"warning no_renegotiation\"; the client: $(head -1 "$CW/reneg.out")"
    else
      echo "  FAIL a HelloRequest: OpenSSL read no no_renegotiation: $(tr '\n' ' ' <"$CW/reneg.out")"
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
    if printf '%s' "$got" | grep -qE "^HTTP/1.0 200 ok TLS_ECDHE_.* alpn=http/1.1 TLSv1.2 group=[A-Za-z0-9]+$" && ! [ -s "$WORK/py12.log" ]; then
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
# The same server on P-384: its chain and PKCS #8 key; its key as SEC 1,
# and as SEC 1 naming no curve (RFC 5915 makes the parameters optional:
# the private key's 48 bytes say P-384); a P-384 key that is not the
# leaf's, and a P-521 key, a curve no server here signs on.
p384_key = ec.generate_private_key(ec.SECP384R1())
os.makedirs(os.path.join(out, "p384"), exist_ok=True)
write("p384/chain.pem", pem(leaf_for(p384_key)) + pem(root))
write("p384/key.pem", pkcs8(p384_key))
write("p384-sec1.key", p384_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
point = p384_key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
bare = tlv(0x30, bytes.fromhex("020101") + tlv(0x04, p384_key.private_numbers().private_value.to_bytes(48, "big")) + tlv(0xa1, tlv(0x03, b"\x00" + point)))
import base64 as b64
text = b64.b64encode(bare).decode()
write("p384-bare.key", ("-----BEGIN EC PRIVATE KEY-----\n" + "\n".join(text[i:i + 64] for i in range(0, len(text), 64)) + "\n-----END EC PRIVATE KEY-----\n").encode())
write("other-p384.key", pkcs8(ec.generate_private_key(ec.SECP384R1())))
write("p521.key", pkcs8(ec.generate_private_key(ec.SECP521R1())))
# A second identity, for other.test, beside each server's own: shown to a
# client that asks for that host by server_name.
other_host = ec.generate_private_key(ec.SECP256R1())
for where in ("", "p256/", "p384/"):
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
# The server that asks for a client's certificate takes no early data.
write("mtls/no-early", b"")
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
check "a P-384 key for a P-256 certificate" p256.pem p384.key "the certificate's key is not P-384, as the private key is"
check "a P-384 chain and its PKCS #8 key" p384/chain.pem p384/key.pem "config: 2 certificates, leaf CN=localhost"
check "a P-384 chain and its SEC 1 key" p384/chain.pem p384-sec1.key "config: 2 certificates, leaf CN=localhost"
check "a P-384 chain and its SEC 1 key naming no curve" p384/chain.pem p384-bare.key "config: 2 certificates, leaf CN=localhost"
check "another P-384 key" p384/chain.pem other-p384.key "the private key is not the certificate's"
check "a P-256 key for a P-384 certificate" p384/chain.pem ec.key "the certificate's key is not P-256, as the private key is"
check "a P-521 key" p256.pem p521.key "the private key is on 1.3.132.0.35, not prime256v1 (1.2.840.10045.3.1.7) or secp384r1 (1.3.132.0.34)"
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
  # sess_twice <file> <s_client args...>: s_client's session kept by
  # -sess_out and offered again by -sess_in; what OpenSSL says of the
  # second connection ("Reused, TLSv1.3" or "New, TLSv1.3"), the client's
  # certificate as the server names it, and whether it says it resumed.
  sess_twice() {
    local file="$1" out
    shift
    printf 'GET / HTTP/1.0\r\n\r\n' | "$OPENSSL" s_client "$@" -sess_out "$file" >/dev/null 2>&1
    out="$(printf 'GET / HTTP/1.0\r\n\r\n' | "$OPENSSL" s_client "$@" -sess_in "$file" 2>&1 | tr -d '\r')"
    printf '%s %s %s\n' "$(printf '%s\n' "$out" | grep -o '^Reused, TLSv1.3\|^New, TLSv1.3' | head -1)" \
      "$(printf '%s\n' "$out" | grep -o 'peer=.* shown=' | head -1 | sed 's/ shown=$//')" "$(printf '%s\n' "$out" | grep -o 'resumed=[a-z]*' | head -1)"
  }
  # Python's ssl, twice to the server: the second connection offers the
  # session the first was sent; whether it was reused, and the client's
  # certificate and the resumption as the server names them. With a chain
  # and key, presented.
  PY_RESUME='
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
if len(sys.argv) > 3:
    ctx.load_cert_chain(sys.argv[3], sys.argv[4])
session = None
for _ in range(2):
    with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost", session=session) as s:
        s.sendall(b"GET / HTTP/1.0\r\n\r\n")
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        session = s.session
        said = data.decode().split("\r\n\r\n")[1].strip()
        reused = s.session_reused
peer = said.split(" peer=")[1].split(" shown=")[0]
print("session_reused=%s peer=%s %s" % (reused, peer, said[said.index("resumed="):]))
'
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
  # hybrid_served <port> <kind>: OpenSSL's s_client and X25519MLKEM768
  # against the server on <port> - offering it alone, where OpenSSL must
  # say it negotiated it; its default groups, whose two shares are
  # X25519MLKEM768's and X25519's, where the server must take the hybrid;
  # and an X25519 share alone with X25519MLKEM768 listed after it, where
  # the server, preferring the hybrid, asks for it by HelloRetryRequest -
  # a line each, "FAIL" on a miss.
  hybrid_served() {
    local port="$1" kind="$2" out failed=0
    hybrid_client() {
      printf 'GET / HTTP/1.0\r\n\r\n' | "$OPENSSL" s_client -connect "127.0.0.1:$port" -servername localhost \
        -CAfile "$SRV/roots.pem" -verify_return_error -ign_eof -tls1_3 "$@" 2>&1 | tr -d '\r'
    }
    out="$(hybrid_client -groups X25519MLKEM768)"
    if printf '%s' "$out" | grep -qF "Negotiated TLS1.3 group: X25519MLKEM768" && printf '%s' "$out" | grep -qF "group=X25519MLKEM768"; then
      echo "  OpenSSL, $kind, X25519MLKEM768 alone: $(printf '%s' "$out" | grep -m1 -F "Negotiated TLS1.3 group")"
    else
      echo "  FAIL OpenSSL, $kind, X25519MLKEM768 alone: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
      failed=1
    fi
    out="$(hybrid_client)"
    if printf '%s' "$out" | grep -qF "name=localhost" && printf '%s' "$out" | grep -qF "group=X25519MLKEM768"; then
      echo "  OpenSSL, $kind, its default groups, X25519MLKEM768 and X25519 shares: the hybrid taken"
    else
      echo "  FAIL OpenSSL, $kind, its default groups: $(printf '%s' "$out" | grep -o 'group=[A-Za-z0-9]*' | head -1) $(printf '%s' "$out" | tail -1)"
      failed=1
    fi
    out="$(hybrid_client -groups X25519:X25519MLKEM768 -msg)"
    if [ "$(printf '%s' "$out" | grep -c '<<< TLS 1.3, Handshake \[length [0-9a-f]*\], ServerHello')" = 2 ] &&
      printf '%s' "$out" | grep -qF "group=X25519MLKEM768"; then
      echo "  OpenSSL, $kind, an X25519 share, X25519MLKEM768 listed: a HelloRetryRequest for the hybrid, then a ServerHello in it"
    else
      echo "  FAIL OpenSSL, $kind, an X25519 share, X25519MLKEM768 listed: $(printf '%s' "$out" | grep -c 'ServerHello') ServerHellos, $(printf '%s' "$out" | grep -o 'group=[A-Za-z0-9]*' | head -1)"
      failed=1
    fi
    return $failed
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
      p384) flag=(--p384) ;;
      rsa*) flag=(--rsa) ;;
    esac
    if "$PY" "$REPO/bench/std_tls_client.py" "$port" "$SRV/roots.pem" ${flag[@]+"${flag[@]}"} >"$WORK/client-$kind.out" 2>&1; then
      echo "  the scripted client, $kind: $(tail -1 "$WORK/client-$kind.out")"
    else
      grep -F "FAIL" "$WORK/client-$kind.out" | sed 's/^/  /'
      tail -1 "$WORK/client-$kind.out" | sed 's/^/  /'
      status=1
    fi
    served_check "the std/tls client, $kind, ALPN h2" "HTTP/1.0 200 ok TLS_AES_128_GCM_SHA256 alpn=h2 TLSv1.3 group=X25519MLKEM768" \
      "$WORK/tls-release" get "$port" "$SRV/roots.pem" localhost h2
    # X25519 is a prefix of X25519MLKEM768's name, so the group is cut out
    # and ended with a full stop.
    served_check "the std/tls client, $kind, told not to offer X25519MLKEM768" "agreed in X25519." sh -c \
      'TLS_POST_QUANTUM=0 "$1" get "$2" "$3" localhost | sed -n "s/.*group=\([A-Za-z0-9]*\).*/agreed in \1./p"' \
      sh "$WORK/tls-release" "$port" "$SRV/roots.pem"
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
    # Resumption: the std/tls client through one TlsSession, then Python's
    # ssl offering the session its first connection was sent; each side's
    # word on whether the second resumed.
    iyi_resume() {
      "$WORK/tls-release" resume "$port" "$SRV/roots.pem" localhost h2 2 2>&1 | sed -n 2p |
        sed -E 's/^2: .* resumed=([a-z]+) .* peer=([^ ]+) said=.* resumed=([a-z]+) held=.*$/client resumed=\1 peer=\2, server resumed=\3/'
    }
    served_check "the std/tls client, $kind, its session resumed" "client resumed=yes peer=CN=localhost, server resumed=yes" iyi_resume
    served_check "Python's ssl, $kind, its session reused" "session_reused=True peer=- resumed=yes" "$PY" -c "$PY_RESUME" "$port" "$SRV/roots.pem"
    # Early data: the std/tls client's second connection sends GET / with
    # its ClientHello, and the server answers what came early.
    iyi_early() {
      "$WORK/tls-release" resume "$port" "$SRV/roots.pem" localhost h2 2 get 2>&1 | sed -n 2p |
        sed -E 's/^2: .* resumed=([a-z]+) early=([A-Za-z]+) .* said=.* (early=".*") resumed=([a-z]+) held=.*$/client early=\2, server \3 resumed=\4/'
    }
    served_check "the std/tls client, $kind, GET / as early data" 'client early=Accepted, server early="GET / HTTP/1.0\r\n\r\n" resumed=yes' iyi_early
    # Python's ssl offers what its OpenSSL offers by default, which from
    # 3.5 on is X25519MLKEM768 first, both shares sent; older, X25519.
    if "$PY" -c 'import ssl, sys; sys.exit(0 if ssl.OPENSSL_VERSION_INFO >= (3, 5) else 1)' 2>/dev/null; then
      served_check "Python's ssl, $kind, its OpenSSL's default groups" "group=X25519MLKEM768" "$PY" -c '
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost") as s:
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    print(ssl.OPENSSL_VERSION, data.decode().split("\r\n\r\n")[1].strip())
' "$port" "$SRV/roots.pem"
    else
      echo "  Python's ssl, $kind: $("$PY" -c 'import ssl; print(ssl.OPENSSL_VERSION)') offers no X25519MLKEM768 by default (OpenSSL does from 3.5), so it is not asked for the hybrid"
    fi
    # set_ecdh_curve names the one group Python's OpenSSL offers, TLS 1.3's
    # included: the server must answer in it.
    served_check "Python's ssl, $kind, secp384r1 alone" "group=secp384r1" "$PY" -c '
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
ctx.set_ecdh_curve("secp384r1")
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost") as s:
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    print(s.version(), data.decode().split("\r\n\r\n")[1].strip())
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
      # A share in a group the server has is taken, the one round trip
      # kept; a share in one it does not have (P-521) is asked again for
      # the first group of the client's this server has, X25519 before
      # secp256r1 before secp384r1.
      served_check "OpenSSL, $kind, a P-384 share first: taken, one ServerHello" "1" hrr P-384:X25519
      served_check "OpenSSL, $kind, a P-384 share first: answered in secp384r1" "group=secp384r1" sclient -tls1_3 -groups P-384:X25519
      served_check "OpenSSL, $kind, a P-521 share first: a HelloRetryRequest for X25519, then a ServerHello" "2" hrr P-521:X25519
      served_check "OpenSSL, $kind, P-521 and P-256, a P-521 share: a HelloRetryRequest for secp256r1" "2" hrr P-521:P-256
      served_check "OpenSSL, $kind, P-521 and P-384, a P-521 share: a HelloRetryRequest for secp384r1" "2" hrr P-521:P-384
      served_check "OpenSSL, $kind, secp256r1 alone" "name=localhost alpn=-" sclient -tls1_3 -groups P-256
      served_check "OpenSSL, $kind, secp384r1 alone" "group=secp384r1" sclient -tls1_3 -groups P-384
      if [ "$hybrid_openssl" = yes ]; then
        if hybrid_served "$port" "$kind"; then
          served_ok=$((served_ok + 3))
        else
          status=1
        fi
      else
        echo "  OpenSSL, $kind: no X25519MLKEM768 in this OpenSSL (it has it from 3.5), so the server's hybrid goes unasked by s_client"
      fi
      # Refusals by the alert's number, which every OpenSSL prints the same;
      # its name is worded differently from one version to the next.
      served_check "OpenSSL, $kind, TLS 1.2 alone" "SSL alert number 70" sclient -tls1_2
      served_check "OpenSSL, $kind, groups without X25519, secp256r1 or secp384r1" "SSL alert number 40" sclient -tls1_3 -groups P-521
      case "$kind" in
        p256)
          served_check "OpenSSL, p256, ecdsa_secp256r1_sha256 alone" "name=localhost alpn=-" sclient -tls1_3 -sigalgs ECDSA+SHA256
          served_check "OpenSSL, p256, no ecdsa_secp256r1_sha256 among its signature algorithms" "SSL alert number 40" sclient -tls1_3 -sigalgs ed25519:RSA-PSS+SHA256
          ;;
        p384)
          served_check "OpenSSL, p384, ecdsa_secp384r1_sha384 alone" "name=localhost alpn=-" sclient -tls1_3 -sigalgs ECDSA+SHA384
          served_check "OpenSSL, p384, secp384r1 alone and ecdsa_secp384r1_sha384 alone" "group=secp384r1" sclient -tls1_3 -groups P-384 -sigalgs ECDSA+SHA384
          served_check "OpenSSL, p384, no ecdsa_secp384r1_sha384 among its signature algorithms" "SSL alert number 40" sclient -tls1_3 -sigalgs ECDSA+SHA256:ed25519:RSA-PSS+SHA256
          ;;
        rsa*)
          # The scheme the client lists first, and never PKCS #1 v1.5. OpenSSL
          # 3.2 on names the scheme (`Peer signature type: rsa_pss_rsae_sha256`);
          # 3.0, the Linux container's, names the type and the digest apart
          # (`RSA-PSS`, then `Peer signing digest: SHA256`), which say the same
          # of a certificate whose key is rsaEncryption.
          pss() {
            sclient -tls1_3 -sigalgs "$1" | tr -d '\r' | awk '
              /^Peer signing digest:/ { d = tolower($4) }
              /^Peer signature type:/ { t = $4 }
              END { if (t == "RSA-PSS") t = "rsa_pss_rsae_" d; print "scheme " t }'
          }
          served_check "OpenSSL, $kind, rsa_pss_rsae_sha256 alone" "scheme rsa_pss_rsae_sha256" pss RSA-PSS+SHA256
          served_check "OpenSSL, $kind, rsa_pss_rsae_sha384 alone" "scheme rsa_pss_rsae_sha384" pss RSA-PSS+SHA384
          served_check "OpenSSL, $kind, rsa_pss_rsae_sha512 before -256" "scheme rsa_pss_rsae_sha512" pss RSA-PSS+SHA512:RSA-PSS+SHA256
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
      served_check "OpenSSL, $kind, -sess_out then -sess_in" "Reused, TLSv1.3 peer=- resumed=yes" \
        sess_twice "$WORK/sess-$kind.pem" -connect "127.0.0.1:$port" -servername localhost -CAfile "$SRV/roots.pem" -verify_return_error -ign_eof -tls1_3
      # Early data: s_client's session kept, then GET / as its early data
      # (-early_data), which OpenSSL says was accepted and the server
      # answers before the client's Finished.
      early_twice() {
        local out
        printf 'GET / HTTP/1.0\r\n\r\n' >"$WORK/early-request"
        sclient -tls1_3 -sess_out "$WORK/early-$kind.pem" >/dev/null
        out="$("$OPENSSL" s_client -connect "127.0.0.1:$port" -servername localhost -CAfile "$SRV/roots.pem" -verify_return_error -ign_eof -tls1_3 \
          -sess_in "$WORK/early-$kind.pem" -early_data "$WORK/early-request" </dev/null 2>&1 | tr -d '\r')"
        printf '%s %s\n' "$(printf '%s\n' "$out" | grep -o '^Early data was [a-z]*' | head -1)" "$(printf '%s\n' "$out" | grep -o 'early=.*resumed=[a-z]*' | head -1)"
      }
      served_check "OpenSSL, $kind, GET / as -early_data" 'Early data was accepted early="GET / HTTP/1.0\r\n\r\n" resumed=yes' early_twice
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
    if command -v curl >/dev/null 2>&1 && { [ "$kind" = p256 ] || [ "$kind" = p384 ] || curl --version | head -1 | grep -q 'OpenSSL/'; }; then
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
  # Python's TLS client is these checks' oracle, and its first certificate
  # check on a runner is not the server's to time. On Windows CI the first
  # Python ssl handshake against the Ed25519 server failed twice (jobs
  # 117686264720 and 118404949498): the server's 3 and 5 s handshake
  # deadline ran out while it waited for the client's Finished, closed, and
  # Python's sendall then met the reset (10053). Python held the time, not
  # the server: replaying those shards' last seven siblings and then this
  # gate (debug run 39478397131), the server's whole flight reached Python
  # in one record within a millisecond, and Python's own step from its
  # Certificate to its CertificateVerify took 12, 32, 33, 975 and 1,598 ms
  # on five runners, the machine's CPU low. It is the first read of library
  # pages no process on the runner has read: pip checks certificates
  # through Windows' store, so OpenSSL's X.509 code first runs here. That
  # step takes 11 to 49 ms on an idle runner the first time, 0.4 to 1.1 ms
  # in every later process, and 5 to 76 ms with the page cache purged (runs
  # 39490370881 and 39494266485). Read in beforehand, as below, the same
  # library took 6,301 and 2,354 ms on two loaded runners and the timed
  # check 0.6 ms on both, where two runners without it took 24 and 14 ms
  # (run 39498721736). So the oracle reads its library in, and runs one
  # handshake with a server of its own over memory, before any server here
  # times it; the deadline still bounds every handshake that follows.
  "$PY" - "$SRV" <<'PY'
import os, ssl, sys, time
started = time.perf_counter()
read = []
if sys.platform == "win32":
    # Every page of the _ssl, libssl and libcrypto images this interpreter
    # maps, read once; a page that cannot be read is passed over.
    import ctypes
    import ctypes.wintypes as w
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.GetCurrentProcess.restype = w.HANDLE
    k32.K32EnumProcessModules.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD)]
    k32.K32GetModuleBaseNameW.argtypes = [w.HANDLE, w.HMODULE, w.LPWSTR, w.DWORD]
    k32.ReadProcessMemory.argtypes = [w.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    me = k32.GetCurrentProcess()
    modules = (w.HMODULE * 1024)()
    needed = w.DWORD()
    k32.K32EnumProcessModules(me, modules, ctypes.sizeof(modules), ctypes.byref(needed))
    page = ctypes.create_string_buffer(1)
    for module in modules[: needed.value // ctypes.sizeof(w.HMODULE)]:
        name = ctypes.create_unicode_buffer(260)
        k32.K32GetModuleBaseNameW(me, module, name, 260)
        if not name.value.lower().startswith(("_ssl", "libssl", "libcrypto")):
            continue
        # SizeOfImage: e_lfanew at 0x3C, then 0x50 into the NT headers.
        size = ctypes.c_uint32.from_address(module + ctypes.c_uint32.from_address(module + 0x3C).value + 0x50).value
        for offset in range(0, size, 4096):
            k32.ReadProcessMemory(me, module + offset, page, 1, None)
        read.append(f"{name.value} ({size // 1024} KiB)")
paged = time.perf_counter()
# One handshake between a client set up as the checks' are and a server
# on this Ed25519 chain, over memory, so that OpenSSL's X.509 path has run.
srv = sys.argv[1]
server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server.load_cert_chain(os.path.join(srv, "chain.pem"), os.path.join(srv, "key.pem"))
client = ssl.create_default_context(cafile=os.path.join(srv, "roots.pem"))
ends = [ssl.MemoryBIO() for _ in range(4)]
pair = [(client.wrap_bio(ends[0], ends[1], server_hostname="localhost"), ends[1], ends[2]),
        (server.wrap_bio(ends[2], ends[3], server_side=True), ends[3], ends[0])]
done = [False, False]
problem = ""
for _ in range(20):
    for i, (end, out, peer) in enumerate(pair):
        if not done[i]:
            try:
                end.do_handshake()
                done[i] = True
            except ssl.SSLWantReadError:
                pass
            except ssl.SSLError as e:
                problem = f", and its handshake failed: {e}"
                done[i] = True
        peer.write(out.read())
    if all(done):
        break
held = f"a {pair[0][0].version()} handshake with itself" if not problem and all(done) else "a handshake with itself"
library = f"{', '.join(read)} read in ({(paged - started) * 1000:.0f} ms), then " if read else ""
print(f"  Python's TLS client before it is timed: {library}{held} in {(time.perf_counter() - paged) * 1000:.0f} ms{problem}")
PY
  serve_and_ask "$SRV" ed25519
  serve_and_ask "$SRV/p256" p256
  serve_and_ask "$SRV/p384" p384
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
    served_check "Python's ssl presenting a P-256 certificate, its session reused: the certificate carried" "session_reused=True peer=CN=client resumed=yes" \
      "$PY" -c "$PY_RESUME" "$port" "$SRV/roots.pem" "$M/client.pem" "$M/client.key"
    if [ "$windows" = no ] && command -v "$OPENSSL" >/dev/null 2>&1; then
      served_check "OpenSSL presenting an Ed25519 certificate" "peer=CN=client ed" sh -c \
        'printf "GET / HTTP/1.0\r\n\r\n" | "$1" s_client -connect "127.0.0.1:$2" -servername localhost -CAfile "$3" -verify_return_error -ign_eof -cert "$4" -key "$5" 2>&1' \
        sh "$OPENSSL" "$port" "$SRV/roots.pem" "$M/client-ed.pem" "$M/client-ed.key"
      served_check "OpenSSL presenting an RSA certificate" "peer=CN=client rsa" sh -c \
        'printf "GET / HTTP/1.0\r\n\r\n" | "$1" s_client -connect "127.0.0.1:$2" -servername localhost -CAfile "$3" -verify_return_error -ign_eof -cert "$4" -key "$5" 2>&1' \
        sh "$OPENSSL" "$port" "$SRV/roots.pem" "$M/client-rsa.pem" "$M/client-rsa.key"
      served_check "OpenSSL presenting an Ed25519 certificate, -sess_out then -sess_in: the certificate carried" "Reused, TLSv1.3 peer=CN=client ed resumed=yes" \
        sess_twice "$WORK/sess-mtls.pem" -connect "127.0.0.1:$port" -servername localhost -CAfile "$SRV/roots.pem" -verify_return_error -ign_eof \
        -cert "$M/client-ed.pem" -key "$M/client-ed.key"
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
echo "== TLS 1.2 at the server, when asked"
# The server told to speak TLS 1.2 too (`TlsServerConfig#min_version =
# TlsVersion::TLS12`, the exercise's serve mode under TLS_MIN_VERSION=1.2;
# the section above holds the default to 1.3 alone), on the Ed25519, P-256,
# P-384 and 2048-bit RSA keys made above: bench/std_tls_client.py's TLS12
# scenarios - every 1.2 handshake checked step by step, or one rule broken
# and the alert named - and three of TLS 1.3's, still answered in 1.3.
# Then OpenSSL's s_client pinned to 1.2 (-tls1_2): each suite of the key's
# kind, ALPN, the group - secp384r1 alone too, which a P-256 key refuses
# as a P-384 key refuses secp256r1 alone - RSA's schemes, a client without
# the extended master secret (-no_ems, where this OpenSSL has it) and one
# falling back (-fallback_scsv) refused, the exporter against OpenSSL's, a
# renegotiation ("R") refused with no_renegotiation; Python's ssl with
# maximum_version TLSv1_2, each suite of the key's kind; curl and Node held
# to 1.2; the std/tls client, which offers 1.3 and is answered in it, and
# the copies built above that offer 1.2 alone - the downgrade sentinel
# refused, and with the check removed, a 1.2 connection. Then client
# certificates in 1.2: the scripted client's MTLS12 scenarios, s_client
# presenting each kind, Python's ssl and the std/tls client's copy
# presenting one, and none refused.
# server12_round <binary> [scripted|all]: the binary serving, a line each,
# "FAIL" before what did not hold; `scripted` asks the scripted client
# alone.
server12_round() {
  local bin="$1" scope="${2:-all}" failed=0 kind dir port pid suite suites
  local flag=()
  ask12() {
    local label="$1" want="$2" got
    shift 2
    got="$("$@" 2>&1 | tr -d '\r')"
    if printf '%s' "$got" | grep -qF -e "$want"; then
      answered12=$((answered12 + 1))
      echo "  $label: $(printf '%s' "$got" | grep -F -e "$want" | head -1)"
    else
      echo "  FAIL $label: expected \"$want\", got: $(printf '%s' "$got" | tail -3)"
      echo "    the server said: $(tail -1 "$CW/serve12.log")"
      failed=1
    fi
  }
  # start12 <dir> [optional]: the binary serving the chain, key and client
  # roots in <dir>, a certificate not required when asked to be optional.
  start12() {
    rm -rf "$CW/srv12" && mkdir -p "$CW/srv12" && cp "$1"/*.pem "$CW/srv12/"
    [ -n "${2:-}" ] && : >"$CW/srv12/client-optional"
    TLS_MIN_VERSION=1.2 "$bin" serve "$CW/srv12" 1000 >"$CW/serve12.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
      [ -s "$CW/srv12/port" ] && break
      sleep 0.1
    done
    port="$(cat "$CW/srv12/port" 2>/dev/null || echo 1)"
  }
  stop12() {
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  }
  scripted12() {
    local label="$1"
    shift
    if "$PY" "$REPO/bench/std_tls_client.py" "$port" "$SRV/roots.pem" --tls12 "$@" >"$CW/client12.out" 2>&1; then
      echo "  the scripted client, $label: $(tail -1 "$CW/client12.out")"
    else
      grep -F "FAIL" "$CW/client12.out" | sed 's/^/  /'
      tail -1 "$CW/client12.out" | sed 's/^/  /'
      failed=1
    fi
  }
  local openssl=no
  [ "$windows" = no ] && command -v "$OPENSSL" >/dev/null 2>&1 && openssl=yes
  sclient12() {
    printf 'GET / HTTP/1.0\r\n\r\n' | "$OPENSSL" s_client -connect "127.0.0.1:$port" -servername localhost \
      -CAfile "$SRV/roots.pem" -verify_return_error -ign_eof "$@" 2>&1
  }
  # The scheme a ServerKeyExchange was signed under, as OpenSSL names it:
  # 3.2 on name it whole, 3.0 the type and the digest apart.
  scheme12() {
    sclient12 -tls1_2 -sigalgs "$1" | tr -d '\r' | awk '
      /^Peer signing digest:/ { d = tolower($4) }
      /^Peer signature type:/ { t = $4 }
      END { if (t == "RSA-PSS") t = "rsa_pss_rsae_" d; if (t == "RSA") t = "rsa_pkcs1_" d; print "scheme " t }'
  }
  export12() {
    local out ours theirs
    out="$(sclient12 -tls1_2 -keymatexport "EXPERIMENTAL iyi" -keymatexportlen 16)"
    ours="$(printf '%s' "$out" | grep -o 'exported=[0-9a-f]*' | head -1 | cut -d= -f2)"
    theirs="$(printf '%s' "$out" | grep -o 'Keying material: [0-9A-Fa-f]*' | head -1 | cut -d' ' -f3 | tr 'A-F' 'a-f')"
    [ -n "$ours" ] && [ "$ours" = "$theirs" ] && echo "the same at both ends: $ours" || echo "server $ours, OpenSSL $theirs"
  }
  # "R" on s_client's stdin renegotiates, once the handshake is done.
  renegotiate12() {
    { printf 'R\n'; sleep 1; } | "$OPENSSL" s_client -connect "127.0.0.1:$port" -servername localhost \
      -CAfile "$SRV/roots.pem" -tls1_2 -msg 2>&1
  }
  py12() {
    "$PY" -c '
import socket, ssl, sys
ctx = ssl.create_default_context(cafile=sys.argv[2])
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
ctx.set_ciphers(sys.argv[3])
ctx.set_alpn_protocols(["http/1.1"])
if len(sys.argv) > 4:
    ctx.load_cert_chain(sys.argv[4], sys.argv[5])
with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost") as s:
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    print(s.version(), s.cipher()[0], data.decode().split("\r\n\r\n")[1].strip())
' "$port" "$SRV/roots.pem" "$@"
  }
  for kind in ed25519 p256 p384 rsa2048; do
    case "$kind" in
      ed25519) dir="$SRV" flag=() ;;
      p256) dir="$SRV/p256" flag=(--p256) ;;
      p384) dir="$SRV/p384" flag=(--p384) ;;
      *) dir="$SRV/rsa2048" flag=(--rsa) ;;
    esac
    start12 "$dir"
    scripted12 "$kind" ${flag[@]+"${flag[@]}"}
    if [ "$scope" = all ]; then
      case "$kind" in
        rsa*) suites="ECDHE-RSA-AES128-GCM-SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 ECDHE-RSA-AES256-GCM-SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 ECDHE-RSA-CHACHA20-POLY1305:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256" ;;
        *) suites="ECDHE-ECDSA-AES128-GCM-SHA256:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 ECDHE-ECDSA-AES256-GCM-SHA384:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 ECDHE-ECDSA-CHACHA20-POLY1305:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256" ;;
      esac
      if [ "$openssl" = yes ]; then
        for suite in $suites; do
          ask12 "OpenSSL, TLS 1.2, $kind, ${suite%%:*}" "name=localhost alpn=- ${suite#*:} peer=- shown=CN=localhost" sclient12 -tls1_2 -cipher "${suite%%:*}"
        done
        ask12 "OpenSSL, TLS 1.2, $kind, ALPN" "name=localhost alpn=h2 TLS_ECDHE_" sclient12 -tls1_2 -alpn h2,http/1.1
        ask12 "OpenSSL, TLS 1.2, $kind, X25519 first" "Temp Key: X25519" sclient12 -tls1_2
        # An ECDSA key's curve must be among the client's groups (RFC 8422
        # section 5.1.1).
        case "$kind" in
          p256)
            ask12 "OpenSSL, TLS 1.2, p256, secp256r1 alone" "Temp Key: ECDH, prime256v1" sclient12 -tls1_2 -groups P-256
            ask12 "OpenSSL, TLS 1.2, p256, groups without secp256r1, the certificate's curve" "SSL alert number 40" sclient12 -tls1_2 -groups X25519
            ask12 "OpenSSL, TLS 1.2, p256, secp384r1 alone, without the certificate's curve" "SSL alert number 40" sclient12 -tls1_2 -groups P-384
            ;;
          p384)
            ask12 "OpenSSL, TLS 1.2, p384, secp384r1 alone" "Temp Key: ECDH, secp384r1" sclient12 -tls1_2 -groups P-384
            ask12 "OpenSSL, TLS 1.2, p384, groups without secp384r1, the certificate's curve" "SSL alert number 40" sclient12 -tls1_2 -groups X25519:P-256
            ;;
          *)
            ask12 "OpenSSL, TLS 1.2, $kind, secp256r1 alone" "Temp Key: ECDH, prime256v1" sclient12 -tls1_2 -groups P-256
            ask12 "OpenSSL, TLS 1.2, $kind, secp384r1 alone" "Temp Key: ECDH, secp384r1" sclient12 -tls1_2 -groups P-384
            ask12 "OpenSSL, TLS 1.2, $kind, X25519 alone" "Temp Key: X25519" sclient12 -tls1_2 -groups X25519
            ;;
        esac
        case "$kind" in
          rsa*)
            ask12 "OpenSSL, TLS 1.2, RSA, RSA-PSS and PKCS #1 v1.5: RSA-PSS" "scheme rsa_pss_rsae_sha256" scheme12 RSA-PSS+SHA256:RSA+SHA256
            ask12 "OpenSSL, TLS 1.2, RSA, rsa_pkcs1_sha512 listed before rsa_pss_rsae_sha384" "scheme rsa_pss_rsae_sha384" scheme12 RSA+SHA512:RSA-PSS+SHA384
            ask12 "OpenSSL, TLS 1.2, RSA, PKCS #1 v1.5 alone" "scheme rsa_pkcs1_sha384" scheme12 RSA+SHA384:RSA+SHA256
            ;;
        esac
        if "$OPENSSL" s_client -help 2>&1 | grep -q -- '-no_ems'; then
          ask12 "OpenSSL, TLS 1.2, $kind, no extended master secret" "SSL alert number 40" sclient12 -tls1_2 -no_ems
        else
          echo "  OpenSSL, TLS 1.2, $kind, no extended master secret: this OpenSSL ($("$OPENSSL" version | cut -d' ' -f2)) cannot leave it out, so it goes unasked"
        fi
        ask12 "OpenSSL, TLS 1.2, $kind, falling back (TLS_FALLBACK_SCSV)" "SSL alert number 86" sclient12 -tls1_2 -fallback_scsv
        ask12 "OpenSSL, TLS 1.2, $kind, exported keying material" "the same at both ends" export12
        ask12 "OpenSSL, TLS 1.2, $kind, a renegotiation" "warning no_renegotiation" renegotiate12
        ask12 "OpenSSL, $kind, TLS 1.3 offered too: answered in 1.3" "name=localhost alpn=- TLS_AES_" sclient12
      fi
      for suite in $suites; do
        ask12 "Python's ssl, TLS 1.2, $kind, ${suite%%:*}" "TLSv1.2 ${suite%%:*} name=localhost alpn=http/1.1 ${suite#*:}" py12 "${suite%%:*}"
      done
      if command -v curl >/dev/null 2>&1 && { [ "$kind" != ed25519 ] || curl --version | head -1 | grep -q 'OpenSSL/'; }; then
        local norevoke=()
        curl --version 2>/dev/null | head -1 | grep -q 'Schannel' && norevoke=(--ssl-no-revoke)
        # curl12: curl's answer, then what the server said of that
        # connection, once it has said it.
        curl12() {
          local before
          before="$(wc -l <"$CW/serve12.log")"
          curl -sS --http1.1 --tls-max 1.2 ${norevoke[@]+"${norevoke[@]}"} \
            --cacert "$SRV/roots.pem" --resolve "localhost:$port:127.0.0.1" "https://localhost:$port/" 2>&1
          for _ in $(seq 1 30); do
            [ "$(wc -l <"$CW/serve12.log")" -gt "$before" ] && break
            sleep 0.1
          done
          tail -n +"$((before + 1))" "$CW/serve12.log"
        }
        if curl --version | head -1 | grep -q 'LibreSSL/'; then
          # LibreSSL - macOS's curl's, 3.3.6 on the darwin runner - has
          # never implemented RFC 7627 and sends no extended_master_secret,
          # so its 1.2 is refused, by name, as this server refuses every
          # client without it: the refusal is what is expected of it.
          ask12 "curl on LibreSSL, TLS 1.2 at most, $kind: no extended master secret, refused" \
            "refused: tls: the client does not do the extended master secret (RFC 7627)" curl12
        else
          ask12 "curl, TLS 1.2 at most, $kind" "alpn=http/1.1 TLS_ECDHE_" curl12
        fi
      fi
      if command -v node >/dev/null 2>&1; then
        ask12 "Node's tls, TLS 1.2 at most, $kind" "TLSv1.2 name=localhost alpn=h2 TLS_ECDHE_" node -e '
const tls = require("tls"), fs = require("fs");
const s = tls.connect({host: "127.0.0.1", port: +process.argv[1], servername: "localhost", maxVersion: "TLSv1.2",
  ca: fs.readFileSync(process.argv[2]), ALPNProtocols: ["h2"]}, () => s.write("GET / HTTP/1.0\r\n\r\n"));
let got = ""; s.on("data", d => got += d); s.on("end", () => console.log(s.getProtocol(), got.split("\r\n\r\n")[1].trim()));
s.on("error", e => console.log("error", e.message));
' "$port" "$SRV/roots.pem"
      fi
      ask12 "the std/tls client, $kind: TLS 1.3, offered" "HTTP/1.0 200 ok TLS_AES_128_GCM_SHA256 alpn=h2 TLSv1.3" "$bin" get "$port" "$SRV/roots.pem" localhost h2
      ask12 "the std/tls client told to speak 1.2 too, $kind: TLS 1.3, offered" "HTTP/1.0 200 ok TLS_AES_128_GCM_SHA256 alpn=- TLSv1.3" \
        env TLS_MIN_VERSION=1.2 "$bin" get "$port" "$SRV/roots.pem" localhost
      if [ -x "$WORK/downgrade/tlsx" ] && [ -x "$WORK/downgrade-unchecked/tlsx" ]; then
        ask12 "the std/tls client offering TLS 1.2 alone, $kind: the sentinel" "carrying RFC 8446's downgrade sentinel, where TLS 1.3 was offered: a downgrade (illegal_parameter)" \
          env TLS_MIN_VERSION=1.2 "$WORK/downgrade/tlsx" get "$port" "$SRV/roots.pem" localhost
        ask12 "the same, its sentinel check removed, $kind: TLS 1.2" "HTTP/1.0 200 ok TLS_ECDHE_" \
          env TLS_MIN_VERSION=1.2 "$WORK/downgrade-unchecked/tlsx" get "$port" "$SRV/roots.pem" localhost
      fi
    fi
    stop12
  done
  start12 "$SRV/mtls"
  scripted12 "a client certificate asked for" --mtls "$SRV/mtls"
  if [ "$scope" = all ]; then
    if [ "$openssl" = yes ]; then
      ask12 "OpenSSL, TLS 1.2, presenting a P-256 certificate" "peer=CN=client shown" sclient12 -tls1_2 -cert "$SRV/mtls/client.pem" -key "$SRV/mtls/client.key"
      ask12 "OpenSSL, TLS 1.2, presenting an Ed25519 certificate" "peer=CN=client ed" sclient12 -tls1_2 -cert "$SRV/mtls/client-ed.pem" -key "$SRV/mtls/client-ed.key"
      ask12 "OpenSSL, TLS 1.2, presenting an RSA certificate" "peer=CN=client rsa" sclient12 -tls1_2 -cert "$SRV/mtls/client-rsa.pem" -key "$SRV/mtls/client-rsa.key"
      ask12 "OpenSSL, TLS 1.2, presenting none" "SSL alert number 40" sclient12 -tls1_2
    fi
    ask12 "Python's ssl, TLS 1.2, presenting a P-256 certificate" "TLSv1.2 ECDHE-ECDSA-AES128-GCM-SHA256 name=localhost alpn=http/1.1 TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 peer=CN=client" \
      py12 ECDHE-ECDSA-AES128-GCM-SHA256 "$SRV/mtls/client.pem" "$SRV/mtls/client.key"
    if [ -x "$WORK/downgrade-unchecked/tlsx" ]; then
      ask12 "the std/tls client's TLS 1.2, presenting an RSA certificate" "HTTP/1.0 200 ok TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 alpn=- TLSv1.2" \
        env TLS_MIN_VERSION=1.2 "$WORK/downgrade-unchecked/tlsx" get "$port" "$SRV/roots.pem" localhost - "$SRV/mtls/client-rsa.pem" "$SRV/mtls/client-rsa.key"
    fi
  fi
  stop12
  start12 "$SRV/mtls" optional
  scripted12 "a client certificate asked for and not required" --mtls "$SRV/mtls" 12-mtls-optional-none 12-mtls-ok 12-mtls-bad-cv
  stop12
  return $failed
}
if [ "$served" = no ]; then
  echo "  no python cryptography here, so the TLS 1.2 server goes unasked"
else
  answered12=0
  if ! server12_round "$WORK/tls-release" >"$WORK/server12.out" 2>&1; then
    status=1
  fi
  cat "$WORK/server12.out"
  echo "  $answered12 answers from other clients as they should be"
fi

echo
echo "== OCSP stapling (RFC 6066, RFC 8446 section 4.4.2.1, RFC 7633)"
# A CA of its own and leaves under it - one good, one revoked, one its
# responder does not know, one that must staple (TLS Feature
# status_request) - with responses `openssl ocsp -index` makes, from the
# CA and from a delegated responder, and three Python's cryptography
# makes: one past its nextUpdate, one signed by another key under the
# CA's name, and one for another certificate. The std/tls client against
# OpenSSL's s_server stapling each (-status_file), in TLS 1.3 and 1.2: a
# good staple's status on the connection, a revoked one refused with
# certificate_revoked, an unknown or an invalid one with
# bad_certificate_status_response, each alert as s_server read it; no
# staple taken by default, refused under require_staple, and refused for
# the must-staple leaf. Then the std/tls server stapling (TlsServerConfig
# #staple) to OpenSSL's s_client -status in TLS 1.3 and 1.2, which shows
# the response; to s_client without -status, which is sent none; and to
# the std/tls client. A staple past its nextUpdate is not sent, and one
# for another certificate is refused by the config. An identity that
# `identity_source` answers, as std/autocert's manager does, is sent with
# the staple given to it, where the config's own identity has none.
# stapling_round <binary> [client|server|all]: the binary against
# OpenSSL, a line each, "FAIL" on the ones that are not as they should be.
OCSP_PKI="$WORK/ocsp"
stapling_ready=no
if [ "$windows" = yes ] || ! command -v "$OPENSSL" >/dev/null 2>&1 || [ -z "$PY" ] || ! [ -s "${PKI:-/nonexistent}/p256.pem" ] ||
   ! "$OPENSSL" s_server -help 2>&1 | grep -q -- '-status_file' || ! "$PY" -c 'from cryptography.x509 import ocsp' >/dev/null 2>&1; then
  echo "  no OpenSSL with s_server -status_file, or no python cryptography with x509.ocsp, here (or Windows), so stapling goes unasked"
else
  mkdir -p "$OCSP_PKI"
  if (
    cd "$OCSP_PKI" || exit 1
    printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=Staple Root\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' >ca.cnf
    "$OPENSSL" req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem -days 30 -config ca.cnf -extensions v3 || exit 1
    leaf='subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n'
    for name in good revoked unknown must responder; do
      printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n' "$name.staple.test" >"$name.cnf"
      case $name in
        must) printf "${leaf}tlsfeature=status_request\n" >"$name.ext" ;;
        responder) printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=OCSPSigning\nnoCheck=ignored\n' >"$name.ext" ;;
        *) printf "$leaf" >"$name.ext" ;;
      esac
      "$OPENSSL" req -new -config "$name.cnf" -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$name.key" -out "$name.csr" &&
        "$OPENSSL" x509 -req -in "$name.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -out "$name.pem" -days 20 -extfile "$name.ext" || exit 1
    done
    "$PY" - <<'PY' || exit 1
import datetime as d, subprocess
from cryptography import x509
from cryptography.x509 import ocsp
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
now = d.datetime.now(d.timezone.utc)
day = d.timedelta(days=1)
load = lambda n: x509.load_pem_x509_certificate(open(f"{n}.pem", "rb").read())
ca, good, revoked = load("ca"), load("good"), load("revoked")
ca_key = serialization.load_pem_private_key(open("ca.key", "rb").read(), None)
def entry(state, cert, revocation=""):
    return "\t".join([state, cert.not_valid_after_utc.strftime("%y%m%d%H%M%SZ"), revocation, format(cert.serial_number, "X"),
                      "unknown", "/CN=" + cert.subject.rfc4514_string()[3:]]) + "\n"
with open("index.txt", "w", newline="\n") as f:
    f.write(entry("V", good) + entry("R", revoked, (now - day).strftime("%y%m%d%H%M%SZ") + ",keyCompromise") + entry("V", load("must")))
def build(name, cert, key=ca_key, signer=ca, this=now - d.timedelta(hours=1), nxt=now + day):
    b = (ocsp.OCSPResponseBuilder().add_response(cert=cert, issuer=ca, algorithm=hashes.SHA1(), cert_status=ocsp.OCSPCertStatus.GOOD,
         this_update=this, next_update=nxt, revocation_time=None, revocation_reason=None).responder_id(ocsp.OCSPResponderEncoding.NAME, signer))
    open(name, "wb").write(b.sign(key, hashes.SHA256()).public_bytes(serialization.Encoding.DER))
build("expired.resp", good, this=now - 10 * day, nxt=now - 3 * day)
other_key = ec.generate_private_key(ec.SECP256R1())
impostor = (x509.CertificateBuilder().subject_name(ca.subject).issuer_name(ca.subject).public_key(other_key.public_key())
            .serial_number(7).not_valid_before(now - day).not_valid_after(now + 9 * day).sign(other_key, hashes.SHA256()))
build("forged.resp", good, key=other_key, signer=impostor)
PY
    for name in good revoked unknown must; do
      "$OPENSSL" ocsp -issuer ca.pem -cert "$name.pem" -no_nonce -reqout "$name.req" &&
        "$OPENSSL" ocsp -index index.txt -CA ca.pem -rsigner ca.pem -rkey ca.key -reqin "$name.req" -respout "$name.resp" -ndays 1 || exit 1
    done
    "$OPENSSL" ocsp -index index.txt -CA ca.pem -rsigner responder.pem -rkey responder.key -reqin good.req -respout delegated.resp -ndays 1 || exit 1
    for name in good revoked must; do
      mkdir -p "serve-$name" && cp "$name.pem" "serve-$name/chain.pem" && cp "$name.key" "serve-$name/key.pem" && : >"serve-$name/no-early"
    done
    cp good.resp serve-good/staple.der && cp revoked.resp serve-revoked/staple.der && cp must.resp serve-must/staple.der
    mkdir -p serve-expired serve-wrong
    cp good.pem serve-expired/chain.pem && cp good.key serve-expired/key.pem && cp expired.resp serve-expired/staple.der
    cp good.pem serve-wrong/chain.pem && cp good.key serve-wrong/key.pem && cp revoked.resp serve-wrong/staple.der
    cp -R serve-good serve-sourced && : >serve-sourced/sourced
  ) >"$WORK/ocsp-pki.log" 2>&1; then
    stapling_ready=yes
  else
    echo "  FAIL the stapling PKI was not made: $(tail -3 "$WORK/ocsp-pki.log" | tr '\n' ' ')"
    status=1
  fi
fi
stapling_round() {
  local bin="$1" scope="${2:-all}" failed=0 port pid got log
  local O="$OCSP_PKI"
  # staple_client <label> <want> [!<not wanted>] [<env>] -- <s_server args...>
  staple_client() {
    local label="$1" want="$2" alert="$3" env="$4"
    shift 4
    log="$CW/s_server-staple.log"
    port="$(free_port)"
    "$OPENSSL" s_server -accept "127.0.0.1:$port" -www "$@" >"$log" 2>&1 </dev/null &
    pid=$!
    wait_port "$port"
    # shellcheck disable=SC2086
    got="$(env $env "$bin" get "$port" "$O/ca.pem" localhost 2>&1)"
    # Whether this s_server staples at all here, asked of s_client -status
    # on the same server, for an alert it may never be put to (below).
    local sent=yes
    if [ "${alert%\?}" != "$alert" ]; then
      printf 'GET / HTTP/1.0\r\n\r\n' | "$OPENSSL" s_client -connect "127.0.0.1:$port" -servername localhost -status -ign_eof 2>&1 |
        grep -q 'OCSP Response Status' || sent=no
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    # A <want> of re:<pattern> is an extended regular expression: the group
    # agreed is whatever this OpenSSL has (X25519 in 3.0, the hybrid from
    # 3.5), and is not what these cases are about.
    local how=-F
    case "$want" in re:*) how=-E want="${want#re:}" ;; esac
    if printf '%s' "$got" | grep -q $how -e "$want" && { [ "$alert" = - ] || grep -q "alert number ${alert%\?}" "$log"; }; then
      echo "  $label: $got$([ "$alert" = - ] || echo ", and s_server read alert ${alert%\?}")"
    elif [ "$sent" = no ] && printf '%s' "$got" | grep -q '^HTTP/1.0 200 ' && ! printf '%s' "$got" | grep -q 'staple='; then
      # An alert ending in ? is one s_server may never be put to: where
      # s_client -status reads no response from it either, it sent none,
      # and the client rightly took the connection unstapled. Where it
      # sends one, the client must refuse it, as above.
      echo "  $label: this s_server staples nothing for it (s_client -status read none), so the client had none to refuse; the scripted server's staple-other-cert holds the refusal"
    else
      echo "  FAIL $label: $got; s_server: $(grep -i 'alert\|error' "$log" | head -2 | tr '\n' ' ')"
      failed=1
    fi
  }
  # staple_served <label> <dir> <want> <unwanted or -> <client: iyi [env] | s_client args...>:
  # the server's directory copied to this round's own, where it writes its
  # port, since broken copies run side by side.
  staple_served() {
    local label="$1" from="$O/$2" dir="$CW/staple-$2" want="$3" unwanted="$4" out
    shift 4
    rm -rf "$dir" && cp -R "$from" "$dir"
    TLS_MIN_VERSION=1.2 "$bin" serve "$dir" 1 >"$CW/serve-staple.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do [ -s "$dir/port" ] && break; sleep 0.1; done
    port="$(cat "$dir/port" 2>/dev/null || echo 1)"
    if [ "$1" = iyi ]; then
      shift
      # shellcheck disable=SC2086
      out="$(env ${1:-} "$bin" get "$port" "$O/ca.pem" localhost 2>&1)"
    else
      out="$(printf 'GET / HTTP/1.0\r\n\r\n' | "$OPENSSL" s_client -connect "127.0.0.1:$port" -servername localhost -CAfile "$O/ca.pem" -ign_eof "$@" 2>&1 | tr -d '\r')"
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    # A <want> of re:<pattern> is an extended regular expression.
    local how=-F
    case "$want" in re:*) how=-E want="${want#re:}" ;; esac
    if printf '%s\n' "$out" | grep -q $how -e "$want" && { [ "$unwanted" = - ] || ! printf '%s\n' "$out" | grep -qF -e "$unwanted"; }; then
      echo "  $label: $(printf '%s\n' "$out" | grep $how -e "$want" | head -1 | sed 's/^ *//')"
    else
      echo "  FAIL $label: $(printf '%s\n' "$out" | grep -i 'OCSP\|Cert Status\|staple\|refused\|alert\|error' | head -4 | tr '\n' ' ')"
      failed=1
    fi
  }
  if [ "$scope" != server ]; then
    staple_client "a good staple, TLS 1.3" "re:TLSv1\.3 group=[^ ]+ staple=good$" - "" -tls1_3 -cert "$O/good.pem" -key "$O/good.key" -status_file "$O/good.resp"
    staple_client "a good staple, TLS 1.2" "re:TLSv1\.2 group=[^ ]+ staple=good$" - "TLS_MIN_VERSION=1.2" -tls1_2 -cert "$O/good.pem" -key "$O/good.key" -status_file "$O/good.resp"
    staple_client "a delegated responder's staple" "staple=good" - "" -tls1_3 -cert "$O/good.pem" -key "$O/good.key" -status_file "$O/delegated.resp"
    staple_client "a revoked staple, TLS 1.3" "is revoked, its stapled OCSP response says: since" 44 "" -tls1_3 -cert "$O/revoked.pem" -key "$O/revoked.key" -status_file "$O/revoked.resp"
    staple_client "a revoked staple, TLS 1.2" "keyCompromise (certificate_revoked)" 44 "TLS_MIN_VERSION=1.2" -tls1_2 -cert "$O/revoked.pem" -key "$O/revoked.key" -status_file "$O/revoked.resp"
    staple_client "an unknown staple" "its status is unknown (bad_certificate_status_response)" 113 "" -tls1_3 -cert "$O/unknown.pem" -key "$O/unknown.key" -status_file "$O/unknown.resp"
    # OpenSSL 3.6.3's s_server, on darwin's runner, did not send a response
    # for another certificate, where 3.5.5's, 3.0.15's and 1.1.1w's did.
    staple_client "a staple for another certificate" "ocsp: no response here is for CN=revoked.staple.test" "113?" "" -tls1_3 -cert "$O/revoked.pem" -key "$O/revoked.key" -status_file "$O/good.resp"
    staple_client "a staple past its nextUpdate" "ocsp: a response past its nextUpdate" 113 "" -tls1_3 -cert "$O/good.pem" -key "$O/good.key" -status_file "$O/expired.resp"
    staple_client "a staple signed by another key under the CA's name" "ocsp: the OCSP response's signature is not CN=Staple Root's" 113 "TLS_MIN_VERSION=1.2" -tls1_2 -cert "$O/good.pem" -key "$O/good.key" -status_file "$O/forged.resp"
    staple_client "no staple, by default" "re:^HTTP/1\.0 200 .* TLSv1\.3 group=[^ ]+$" - "" -tls1_3 -cert "$O/good.pem" -key "$O/good.key"
    if printf '%s' "$got" | grep -q 'staple='; then echo "  FAIL no staple, by default: a status where none came: $got"; failed=1; fi
    staple_client "no staple, require_staple" "and require_staple asks for one (bad_certificate_status_response)" 113 "TLS_REQUIRE_STAPLE=1" -tls1_3 -cert "$O/good.pem" -key "$O/good.key"
    staple_client "a must-staple leaf without a staple, TLS 1.3" "(its TLS Feature extension, RFC 7633), and none came (bad_certificate_status_response)" 113 "" -tls1_3 -cert "$O/must.pem" -key "$O/must.key"
    staple_client "a must-staple leaf without a staple, TLS 1.2" "(its TLS Feature extension, RFC 7633), and none came (bad_certificate_status_response)" 113 "TLS_MIN_VERSION=1.2" -tls1_2 -cert "$O/must.pem" -key "$O/must.key"
    staple_client "a must-staple leaf with its staple" "staple=good" - "" -tls1_3 -cert "$O/must.pem" -key "$O/must.key" -status_file "$O/must.resp"
  fi
  if [ "$scope" != client ]; then
    staple_served "s_client -status, TLS 1.3" serve-good "Cert Status: good" - -status -tls1_3
    staple_served "s_client -status, TLS 1.2" serve-good "Cert Status: good" - -status -tls1_2
    staple_served "s_client without -status, sent none" serve-good "resumed=no" "stapled=" -tls1_3
    staple_served "the std/tls client and server" serve-good "staple=good" - iyi
    # The identity an identity_source answers (std/autocert's way) carries
    # its own staple, the config's identity none.
    staple_served "an identity_source's identity, its own staple, TLS 1.3" serve-sourced "Cert Status: good" - -status -tls1_3
    staple_served "an identity_source's identity, its own staple, TLS 1.2" serve-sourced "Cert Status: good" - -status -tls1_2
    staple_served "the std/tls client, a must-staple leaf served with its staple, require_staple" serve-must "staple=good" - iyi TLS_REQUIRE_STAPLE=1
    staple_served "a revoked staple served, the std/tls client refusing it" serve-revoked "(certificate_revoked)" - iyi
    staple_served "a revoked staple served, as s_client -status reads it" serve-revoked "Cert Status: revoked" - -status -tls1_3
    # s_client's sentence for no staple: "OCSP response: no response sent"
    # to OpenSSL 3.5 and earlier, "OCSP responses: no responses sent" to 3.6.
    staple_served "a staple past its nextUpdate is not sent" serve-expired "re:OCSP responses?: no responses? sent" "Cert Status" -status -tls1_3
    staple_served "a staple for another certificate refused by the config" serve-wrong "resumed=no" "stapled=" -tls1_3
    if grep -qF "staple refused: tls: the OCSP response has no SingleResponse for CN=good.staple.test" "$CW/serve-staple.log"; then
      echo "  ... and the server said: $(head -1 "$CW/serve-staple.log")"
    else
      echo "  FAIL a staple for another certificate refused by the config: $(head -1 "$CW/serve-staple.log")"
      failed=1
    fi
  fi
  return $failed
}
if [ "$stapling_ready" = yes ]; then
  echo "  $("$OPENSSL" version)"
  if ! stapling_round "$WORK/tls-release" >"$WORK/stapling.out" 2>&1; then
    status=1
  fi
  cat "$WORK/stapling.out"
fi

echo
echo "== a handshake's time, by the server's key (--release; measured, not checked)"
# Python's ssl makes full TLS 1.3 handshakes with the exercise's server,
# one after another over loopback, and closes each: the median wall time
# of one, its own side's work included. What changes from key to key is
# the CertificateVerify the server signs. Each is timed 100 handshakes at
# a time: in the group Python's OpenSSL offers first by default
# (X25519MLKEM768 from OpenSSL 3.5 on), pinned to X25519 by
# `set_ecdh_curve`, and for the P-384 key pinned to secp384r1 too. Then
# 100 in TLS 1.2, to the server told to speak it and Python held to it,
# in the group it offers first there - never X25519MLKEM768, which is
# 1.3's alone: what changes there is the ServerKeyExchange's signature.
# One connection before them asks the server which group it agreed.
if [ "$served" = yes ]; then
  for version in 1.3 1.2; do
    for pair in "ed25519:$SRV" "p256:$SRV/p256" "p384:$SRV/p384" "rsa2048:$SRV/rsa2048" "rsa4096:$SRV/rsa4096"; do
      kind="${pair%%:*}"
      dir="${pair#*:}"
      # The groups pinned after the default one, comma-separated.
      pinned=""
      [ "$version" = 1.3 ] && pinned="X25519"
      [ "$version" = 1.3 ] && [ "$kind" = p384 ] && pinned="X25519,secp384r1"
      count=$((1 + 100 * (1 + $(printf '%s' "$pinned" | tr ',' '\n' | grep -c .))))
      rm -f "$dir/port"
      TLS_MIN_VERSION="$version" "$WORK/tls-release" serve "$dir" "$count" >"$WORK/time-$kind.log" 2>&1 &
      pid=$!
      for _ in $(seq 1 100); do
        [ -s "$dir/port" ] && break
        sleep 0.1
      done
      "$PY" - "$(cat "$dir/port" 2>/dev/null || echo 1)" "$SRV/roots.pem" "$kind" "$version" "$pinned" <<'PY'
import socket, ssl, statistics, sys, time


def context(curve=None):
    ctx = ssl.create_default_context(cafile=sys.argv[2])
    if sys.argv[4] == "1.2":
        ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    if curve:
        ctx.set_ecdh_curve(curve)
    return ctx


# The group Python's OpenSSL takes by default, as the server names it.
with context().wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost") as s:
    version = s.version()
    s.sendall(b"GET / HTTP/1.0\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
default = data.decode().split("group=")[-1].split()[0]
said = []
for curve in [None] + [c for c in sys.argv[5].split(",") if c]:
    ctx = context(curve)
    took = []
    for _ in range(100):
        started = time.perf_counter()
        with ctx.wrap_socket(socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=10), server_hostname="localhost"):
            took.append(time.perf_counter() - started)
    said.append(f"{statistics.median(took) * 1000:.2f} ms in " + (curve or default))
print(f"  {sys.argv[3]}, {version}: " + ", ".join(said) + " (the median of 100 each)")
PY
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    done
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
# `server-p256`, `server-p384`, `server-rsa` on the 2048-bit RSA key, `server-mtls`,
# asking for a client's certificate, or `server-mtls-optional`, asking
# without requiring one; the client's report must name the scenario);
# judging the server's configurations (`config`); the TLS 1.2 client
# against OpenSSL, Python's ssl and the man in the middle (`client12`);
# the server told to speak TLS 1.2 too, before the scripted client
# (`server12`) or every client of its section (`server12-interop`); the
# client resuming by OpenSSL's tickets (`client-resume`); the client
# sending early data to OpenSSL's server (`client-early`); or
# X25519MLKEM768 against OpenSSL, the client before s_server
# (`client-hybrid`) or the server before s_client (`server-hybrid`); or
# OCSP stapling with OpenSSL, the client before s_server -status_file
# (`ocsp-client`) or the server before s_client -status (`ocsp-server`).
mutations=0
# A scenario's break is caught by the scenario failing, by name - "FAILED:
# <scenario>: " - whether the broken client then holds a connection or
# reads a refusal: once a break lets the client reach its Finished, which
# it sees first is a race with the scripted server's hang-up, and darwin's
# runners held connections where Linux read refusals (bad-finished,
# certreq-no-sigalgs, unsolicited-ext).
#
# The copies are patched one after another and each is built and run in a
# subshell of its own, MUT_JOBS at a time, as std_http's are. With its 236
# copies made one at a time this gate took 1537 seconds; four at a time,
# 511 (Linux, x86-64, 12 threads), every copy still caught. A copy's
# build took about 2 seconds and 0.7 GB. A copy keeps everything in
# $WORK/mut-<n> - its source, binary, servers and logs (CW, above) - and
# its own compiler cache: the cache is named by the exercise's path, which
# every copy shares, and two builds of different modules writing one cache
# at once would race; a build into a cache of its own took 1.95 seconds.
# Each answer goes to $WORK/mutres/<n>, and they are printed in order once
# all have ended. The running copies are counted by their own pids, not
# `jobs -rp`: the scripted server is a job of this shell too.
MUT_JOBS="${MUT_JOBS:-4}"
mutation_pids=""
mkdir -p "$WORK/mutres"
mutation_said() { # mutation_said <n> <line>...: the n-th proof's answer
  local n="$1"
  shift
  printf '%s\n' "$@" >"$WORK/mutres/$n"
}
mutation_failed() { # the same, and the gate does not hold
  mutation_said "$@"
  touch "$WORK/mutres/failed"
}
# prove_copy <n> <dir> <label> <phrase> <old> <new> [mode]: the n-th copy,
# patched into <dir>/patched, built and run; in a subshell of its own.
prove_copy() {
  local n="$1" W="$2" label="$3" phrase="$4" mode="${7:-trace}" rc
  CW="$W"
  export IYI_CACHE_DIR="$W/cache"
  if ! IYI_PATH="$W/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$W/tlsx" \
       "$REPO/bench/std_tls_exercise.iyi" >"$W/build.log" 2>&1; then
    mutation_failed "$n" "  the $label copy did not build:" "$(tail -3 "$W/build.log" | sed 's/^/    /')"
    return
  fi
  case "$mode" in
    trace)
      "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    scenarios)
      "$W/tlsx" scenarios "$SERVER_DIR" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    config)
      bash "$WORK/server-configs.sh" "$W/tlsx" "$SRV" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    client-alert)
      client_alert "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    client-export)
      client_export "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    client-sni)
      client_sni "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    client12)
      tls12_round "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    server12 | server12-interop)
      server12_round "$W/tlsx" "$([ "$mode" = server12 ] && echo scripted || echo all)" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    client-resume)
      client_resume "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    client-early)
      client_early "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    client-hybrid)
      client_hybrid "$W/tlsx" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    ocsp-client | ocsp-server)
      stapling_round "$W/tlsx" "${mode#ocsp-}" >"$W/mut.out" 2>&1
      rc=$?
      ;;
    *)
      mkdir -p "$W/srv"
      local keys="$SRV" flag=() pid
      [ "$mode" = server-p256 ] && keys="$SRV/p256" && flag=(--p256)
      [ "$mode" = server-p384 ] && keys="$SRV/p384" && flag=(--p384)
      [ "$mode" = server-rsa ] && keys="$SRV/rsa2048" && flag=(--rsa ok pss-sha384 pss-sha512 no-rsa-pss no-ed25519 no-p256)
      [ "$mode" = server-mtls ] && keys="$SRV/mtls" && flag=(--mtls "$SRV/mtls")
      [ "$mode" = server-mtls-optional ] && keys="$SRV/mtls" && flag=(--mtls "$SRV/mtls" mtls-optional-none mtls-ok mtls-bad-cv)
      cp "$keys/chain.pem" "$keys/key.pem" "$W/srv/"
      # The second identity too, for other.test, where there is one.
      cp "$keys"/other-chain.pem "$keys"/other-key.pem "$W/srv/" 2>/dev/null
      case "$mode" in server-mtls*) cp "$keys/client-roots.pem" "$keys/no-early" "$W/srv/" ;; esac
      [ "$mode" = server-mtls-optional ] && : >"$W/srv/client-optional"
      "$W/tlsx" serve "$W/srv" 1000 >"$W/serve.log" 2>&1 &
      pid=$!
      for _ in $(seq 1 100); do
        [ -s "$W/srv/port" ] && break
        sleep 0.1
      done
      if [ "$mode" = server-hybrid ]; then
        hybrid_served "$(cat "$W/srv/port" 2>/dev/null || echo 1)" ed25519 >"$W/mut.out" 2>&1
      else
        "$PY" "$REPO/bench/std_tls_client.py" "$(cat "$W/srv/port" 2>/dev/null || echo 1)" "$SRV/roots.pem" ${flag[@]+"${flag[@]}"} >"$W/mut.out" 2>&1
      fi
      rc=$?
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    case "$mode" in
      trace | scenarios) mutation_failed "$n" "  the exercise PASSED on $label" ;;
      *) mutation_failed "$n" "  the server held on $label" ;;
    esac
    return
  elif ! grep -qF -e "$phrase" "$W/mut.out"; then
    # The panic's sentence, not the last frames of its backtrace.
    case "$mode" in
      trace | scenarios) mutation_failed "$n" "  $label failed, but not where it should have:" \
        "$({ grep -m1 -F 'panic' "$W/mut.out" || tail -2 "$W/mut.out"; } | sed 's/^/    /')" ;;
      *) mutation_failed "$n" "  $label failed, but not where it should have:" "$(grep -F "FAIL" "$W/mut.out" | head -2 | sed 's/^/    /')" ;;
    esac
    return
  fi
  mutation_said "$n" "  $label is caught"
  # A caught copy's directory goes: 236 binaries and caches would otherwise
  # pile up until the gate ends. One that was not caught is kept, to read.
  rm -rf "$W"
}
prove_broken() {
  mutations=$((mutations + 1))
  local n="$mutations" mode="${5:-trace}" W="$WORK/mut-$mutations"
  if [ -z "$PY" ] || { [ "$mode" = scenarios ] && [ "$scripted" = no ]; } ||
     { { [ "$mode" = server ] || [ "$mode" = server-p256 ] || [ "$mode" = server-p384 ] || [ "$mode" = server-rsa ] || [ "$mode" = server-mtls ] || [ "$mode" = server-mtls-optional ] || [ "$mode" = config ] || [ "$mode" = server12 ] || [ "$mode" = server12-interop ]; } && [ "$served" = no ]; } ||
     { { [ "$mode" = client-alert ] || [ "$mode" = client-export ] || [ "$mode" = client-sni ] || [ "$mode" = client12 ] || [ "$mode" = client-resume ] || [ "$mode" = client-early ] || [ "$mode" = client-hybrid ]; } && ! [ -s "${PKI:-/nonexistent}/p256.pem" ]; } ||
     { { [ "$mode" = client-hybrid ] || [ "$mode" = server-hybrid ]; } && [ "$hybrid_openssl" != yes ]; } ||
     { { [ "$mode" = ocsp-client ] || [ "$mode" = ocsp-server ]; } && [ "$stapling_ready" != yes ]; } ||
     { [ "$mode" = server-hybrid ] && [ "$served" = no ]; }; then
    mutation_said "$n" "  no scripted peer or python3 here, so the $1 proof is unmeasured"
    return
  fi
  mkdir -p "$W/patched/std"
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/tls.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$W/patched/std/tls.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8")
PY
  then
    mutation_failed "$n" "  the $1 patch did not apply"
    return
  fi
  prove_copy "$n" "$W" "$@" &
  mutation_pids="$mutation_pids $!"
  # `wait -n` where the shell has it (bash 4.3); darwin's 3.2 polls.
  local pid running
  while :; do
    running=""
    for pid in $mutation_pids; do
      kill -0 "$pid" 2>/dev/null && running="$running $pid"
    done
    mutation_pids="$running"
    [ "$(echo $mutation_pids | wc -w)" -lt "$MUT_JOBS" ] && break
    wait -n 2>/dev/null || sleep 0.2
  done
}
mutations_report() { # every answer, in the order the proofs were made
  local pid n=1
  for pid in $mutation_pids; do
    wait "$pid"
  done
  while [ "$n" -le "$mutations" ]; do
    cat "$WORK/mutres/$n"
    n=$((n + 1))
  done
  [ -e "$WORK/mutres/failed" ] && status=1
  return 0
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
# Taken, a Finished one bit off lets the client finish its handshake, and
# the scripted server, which hangs up after it, races the client's echo:
# the client holds a connection or reads the refusal first; on darwin it
# held. Either is the scenario failing, as for certreq-no-sigalgs below.
prove_broken "the server's Finished unchecked" "FAILED: bad-finished: " \
  '    unless Subtle.constant_time_compare(message[4, message.size - 4], expected)
      return TlsError.new("the server'"'"'s Finished' '    if false
      return TlsError.new("the server'"'"'s Finished' scenarios
prove_broken "CertificateVerify unchecked" "FAILED: bad-cv: " \
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
prove_broken "a client's handshake bounded by each wait alone" "FAILED: slow-server: " \
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
  '      return TlsError.new("a certificate entry with extension #{type}, which nobody asked for", TlsAlert::UNSUPPORTED_EXTENSION) unless type == 5' '' scenarios
prove_broken "a CertificateStatus of another type taken" "staple-type:" \
  '    return TlsError.new("a CertificateStatus of type #{type}, where ocsp (1) was asked for", TlsAlert::ILLEGAL_PARAMETER) unless type == 1' '' scenarios
prove_broken "an empty CertificateStatus taken" "staple-empty:" \
  ' if field.short? || !field.done? || response.empty?' ' if field.short? || !field.done?' scenarios
prove_broken "a stapled response for another certificate taken" "staple-other-cert:" \
  '    return TlsError.new("the stapled OCSP response: #{verdict.message}", TlsAlert::BAD_CERTIFICATE_STATUS_RESPONSE) if verdict.is_a?(OcspError)' '    return nil if verdict.is_a?(OcspError)' scenarios
prove_broken "status_request twice in an entry taken" "staple-twice:" \
  '      return TlsError.new("extension #{type} twice in a certificate entry", TlsAlert::ILLEGAL_PARAMETER) if seen.includes?(type)' '' scenarios
prove_broken "a server_name acknowledgement with something in it taken" "sni-ack-data:" \
  '    return TlsError.new("a server_name acknowledgement that is not empty", TlsAlert::DECODE_ERROR) unless data.empty?' '' scenarios
prove_broken "user_canceled after the handshake taken as an end" "user-canceled:" \
  '        next if warning' '' scenarios
# Section 5.4's limit on the whole inner plaintext, padding in it, as it
# was before SECURITY_REVIEW_TLS.md's finding, and one byte short of it -
# which "big", 2^14 bytes of content a record, meets before "padded-max".
prove_broken "padding past 2^14 + 1 bytes of inner plaintext taken" "padded-over:" \
  '    if opened.bytesize > TlsRecords::MAX_PLAINTEXT + 1' '    if opened.bytesize > TlsRecords::MAX_PLAINTEXT + 256' scenarios
prove_broken "the inner plaintext's limit one byte short" "a record of 16385 bytes of inner plaintext" \
  '    if opened.bytesize > TlsRecords::MAX_PLAINTEXT + 1' '    if opened.bytesize > TlsRecords::MAX_PLAINTEXT' scenarios
# Section 5.1's rule that nothing comes between a handshake message's
# pieces, as it was before SECURITY_REVIEW_TLS.md's finding.
prove_broken "application data taken inside a split handshake message" "split-by-data:" \
  '        cut = cut_message(type)
        return fail(cut) if cut
        next if content.empty?' '        next if content.empty?' scenarios
prove_broken "close_notify taken inside a split handshake message" "split-by-close:" \
  '        cut = cut_message(type)
        return fail(cut) if cut
        next if warning' '        next if warning' scenarios
# The same two rules in TLS 1.2, against the scripted server's whole 1.2
# handshakes: the split-message rule waived for 1.2 alone, and the limit
# on a 1.2 record's plaintext (RFC 5246 section 6.2.1) dropped.
prove_broken "TLS 1.2 application data taken inside a split handshake message" "tls12-split-by-data: read" \
  '    return nil if handshake_left == 0
' '    return nil if handshake_left == 0 || @tls12
' scenarios
prove_broken "a TLS 1.2 record past 2^14 bytes of plaintext taken" "tls12-oversize: read" \
  ' if length > TlsRecords::MAX_PLAINTEXT
    {type, TlsBytes.of(opened)}' ' if false
    {type, TlsBytes.of(opened)}' scenarios
prove_broken "the session id's echo unchecked" "FAILED: no-echo: " \
  '    return TlsError.new("a ServerHello that does not echo the session id", TlsAlert::ILLEGAL_PARAMETER) unless echo == session' '' scenarios
prove_broken "the certificate checked for no host" "FAILED: wrong-host: " \
  'verified = X509.verify(chain[0], chain[1, chain.size - 1], roots, @name,' 'verified = X509.verify(chain[0], chain[1, chain.size - 1], roots, nil,' scenarios
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
# Passed over, the request is answered with no certificate, and the client
# either holds a connection (it is done at its Finished) or reads the
# server's refusal first, by the race; on darwin it held. Either is the
# scenario failing.
prove_broken "a CertificateRequest without signature_algorithms passed over" "FAILED: certreq-no-sigalgs: " \
  '    return TlsError.new("a CertificateRequest with no signature_algorithms", TlsAlert::MISSING_EXTENSION) unless schemes' '    return nil unless schemes' scenarios
prove_broken "handshake bytes after Finished passed over" "FAILED: trailing-after-finished: " \
  '    return TlsError.new("handshake bytes left after the server'"'"'s Finished", TlsAlert::UNEXPECTED_MESSAGE) unless handshake_left == 0' '' scenarios
prove_broken "ALPN answers taken whatever they are" "FAILED: alpn-unoffered: " \
  'return TlsError.new("the server chose #{chosen.inspect} by ALPN, which was not offered", TlsAlert::NO_APPLICATION_PROTOCOL) unless @config.alpn.includes?(chosen)' '' scenarios
prove_broken "an unknown extension in EncryptedExtensions passed over" "FAILED: unsolicited-ext: " \
  '        return TlsError.new("extension #{type} in EncryptedExtensions, which was not offered", TlsAlert::UNSUPPORTED_EXTENSION)' '' scenarios
# Past the refusal, any 32 bytes stand in for the secret: the handshake
# goes on to a server that has already hung up.
prove_broken "a share of small order taken" "zero-share:" \
  '      return TlsError.new("the server'"'"'s X25519 share gives no secret", TlsAlert::ILLEGAL_PARAMETER) if shared.is_a?(CurveError)' \
  '      shared = X25519.public_key(private_key) if shared.is_a?(CurveError)' scenarios
prove_broken "a HelloRetryRequest for secp256r1 answered with X25519 again" "hrr-p256: refused" \
  '      if reply.named_group == GROUP_SECP256R1 || reply.named_group == GROUP_SECP384R1' '      if reply.named_group == GROUP_SECP384R1' scenarios
prove_broken "a HelloRetryRequest for secp384r1 answered with X25519 again" "hrr-p384: refused" \
  '      if reply.named_group == GROUP_SECP256R1 || reply.named_group == GROUP_SECP384R1' '      if reply.named_group == GROUP_SECP256R1' scenarios
prove_broken "a HelloRetryRequest for secp384r1 refused as a group not offered" "hrr-p384: refused" \
  'unless group == GROUP_SECP256R1 || group == GROUP_SECP384R1' 'unless group == GROUP_SECP256R1' scenarios
prove_broken "the server's secp384r1 share taken off the curve" "FAILED: hrr-p384-bad: " \
  '      return TlsError.new("the server'"'"'s #{group_name(reply.named_group)} share: #{got.message}", TlsAlert::ILLEGAL_PARAMETER) if got.is_a?(EcdsaError)
      secret = got
    elsif' '      secret = got.is_a?(EcdsaError) ? Array(UInt8).new(48, 0_u8) : got
    elsif' scenarios
prove_broken "a ServerHello's share taken in a group its ClientHello did not send" "FAILED: sh-wrong-group: " \
  '    unless shares.any? { |s| s[0] == reply.named_group }' '    unless true' scenarios
# X25519MLKEM768 at the client: its ClientHello, the ServerHello's share,
# a HelloRetryRequest for it, and the secret's order against OpenSSL.
# Without the hybrid's share the first scenario to tell is sh-wrong-group,
# whose refusal names the shares sent: X25519's alone.
prove_broken "no X25519MLKEM768 share sent by default" "sh-wrong-group: refused with" \
  '    if @config.post_quantum
      pq' '    if false
      pq' scenarios
prove_broken "a ServerHello's X25519MLKEM768 share of any size taken" "hybrid-short-ct: refused with" \
  '          if group == GROUP_X25519MLKEM768 && share.size != HYBRID_SERVER_SHARE' '          if false' scenarios
prove_broken "a HelloRetryRequest for the X25519MLKEM768 share already sent taken as a group not offered" "hrr-hybrid: refused with" \
  '          if group == GROUP_X25519 || (group == GROUP_X25519MLKEM768 && @config.post_quantum)' '          if group == GROUP_X25519' scenarios
prove_broken "a hybrid secret whose X25519 half is taken however small its key" "hybrid-zero-x25519: refused with" \
  '      return TlsError.new("the server'"'"'s X25519MLKEM768 share: its X25519 key gives no secret", TlsAlert::ILLEGAL_PARAMETER) if shared.is_a?(CurveError)' \
  '      shared = X25519.public_key(private_key) if shared.is_a?(CurveError)' scenarios
prove_broken "the client's hybrid secret in the wrong order, X25519's first" "FAIL s_server -groups X25519MLKEM768" \
  '      secret = opened + TlsBytes.of(shared)' '      secret = TlsBytes.of(shared) + opened' client-hybrid
prove_broken "the client's hybrid share with its X25519 key first" "FAIL s_server -groups X25519MLKEM768" \
  '      shares << {GROUP_X25519MLKEM768, pq.encapsulation_key + public_key}' '      shares << {GROUP_X25519MLKEM768, public_key + pq.encapsulation_key}' client-hybrid
# TLS 1.2: opt-in, so the default must be 1.3 alone; then the ServerHello's
# rules against the scripted server's 1.2 ServerHellos, the rest against
# OpenSSL, Python and the man in the middle.
prove_broken "TLS 1.2 offered by default" "FAILED: tls12: " \
  'requires).
  property min_version : TlsVersion = TlsVersion::TLS13' 'requires).
  property min_version : TlsVersion = TlsVersion::TLS12' scenarios
prove_broken "a TLS 1.2 ServerHello taken from a client not asked for 1.2" "FAILED: tls12: " \
  '    if !seen.includes?(43) && @config.min_version == TlsVersion::TLS12' '    if !seen.includes?(43)' scenarios
prove_broken "a ClientHello offering TLS 1.2's suites unasked" "FAILED: tls12: " \
  '    TlsSuites::TLS12.each { |suite| suites = suites + TlsBytes.u16(suite) } if tls12' '    TlsSuites::TLS12.each { |suite| suites = suites + TlsBytes.u16(suite) }' scenarios
prove_broken "the downgrade sentinel unchecked" "FAILED: tls12-downgrade: " \
  '    if tail == DOWNGRADE_TLS12 || tail == DOWNGRADE_TLS11' '    if false' scenarios
prove_broken "the TLS 1.1 sentinel unchecked" "FAILED: tls12-downgrade11: " \
  'if tail == DOWNGRADE_TLS12 || tail == DOWNGRADE_TLS11' 'if tail == DOWNGRADE_TLS12' scenarios
prove_broken "the downgrade sentinel unchecked, before a real server" "FAIL the downgrade sentinel written into a TLS 1.2 ServerHello" \
  '    if tail == DOWNGRADE_TLS12 || tail == DOWNGRADE_TLS11' '    if false' client12
prove_broken "a server without the extended master secret taken" "FAILED: tls12-no-ems: " \
  '    unless extended
      return' '    if false
      return' scenarios
prove_broken "a TLS 1.2 ServerHello's echo of the session id taken" "FAILED: tls12-resume: " \
  ' if echo == session
' ' if false
' scenarios
prove_broken "a renegotiation_info with something in it taken" "FAILED: tls12-reneg: " \
  'TlsAlert::HANDSHAKE_FAILURE) unless data == [0_u8]' 'TlsAlert::HANDSHAKE_FAILURE) if false' scenarios
prove_broken "a TLS 1.3 suite taken for TLS 1.2" "FAILED: tls12-suite13: " \
  'unless TlsSuites::TLS12.includes?(suite)' 'if false' scenarios
prove_broken "the ClientHello's TLS 1.2 offer without the extended master secret" "FAILED: tls12-hello: " \
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
  '    return TlsError.new("the private key is not the certificate'"'"'s") unless public.x == key.public_key.x && public.y == key.public_key.y
    TlsIdentity.new(chain, leaf, [P256]' '    TlsIdentity.new(chain, leaf, [P256]' config
# A P-384 server: ecdsa_secp384r1_sha384 alone, SHA-384 under it, the key
# the certificate's, and its key read on the curve it names.
prove_broken "a client without ecdsa_secp384r1_sha384 answered anyway by a P-384 server" "FAIL no-p384 " \
  '    return @identity if @identity.scheme_for(schemes)' '    return @identity' server-p384
prove_broken "a P-384 CertificateVerify signed over SHA-256" "FAIL ok " \
  '      wide.sign(EcdsaHash::SHA384, content)' '      wide.sign(EcdsaHash::SHA256, content)' server-p384
prove_broken "a P-384 key that is not the certificate's taken" "FAIL another P-384 key" \
  '    return TlsError.new("the private key is not the certificate'"'"'s") unless public.x == key.public_key.x && public.y == key.public_key.y
    TlsIdentity.new(chain, leaf, [P384]' '    TlsIdentity.new(chain, leaf, [P384]' config
prove_broken "a SEC 1 key naming no curve read as P-256's" "FAIL a P-384 chain and its SEC 1 key naming no curve" \
  '    secret.is_a?(Array(UInt8)) && secret.size == 48 ? EcdsaCurve::P384.oid : p256' '    p256' config
prove_broken "a P-384 PKCS #8 key read as P-256's" "FAIL a P-384 chain and its PKCS #8 key" \
  '      named = algorithm[1].oid
      return named.is_a?(String) ? named : p256' '      return p256' config
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
  '[RSA_PSS_SHA256, RSA_PSS_SHA384, RSA_PSS_SHA512], nil, nil, nil, key)' '[0x0401, RSA_PSS_SHA256, RSA_PSS_SHA384, RSA_PSS_SHA512], nil, nil, nil, key)' server-rsa
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
  '    if (wanted = offered) && !@config.alpn.empty? && @alpn_protocol.nil?' '    if (wanted = offered) && @config.alpn.empty? && @alpn_protocol.nil?' server
prove_broken "no alert sent before hanging up" "FAIL dup-ext " \
  '    code = error.alert' '    code = nil.as(UInt8?)' server
prove_broken "an alert in the clear after the server's keys" "FAIL bad-finished " \
  '      sent = if @writer' '      sent = if false' server
prove_broken "a private key that is not the certificate's taken" "FAIL another key" \
  '    return TlsError.new("the private key is not the certificate'"'"'s") unless TlsBytes.of(Ed25519.public_key(seed)) == key.bytes' '' config
prove_broken "a secp256r1 share taken before an X25519 one" "FAIL both-shares " \
  '    TlsConnection::GROUPS12.find { |group| !share(group).nil? } || 0' '    @p256 ? TlsConnection::GROUP_SECP256R1 : (@x25519 ? TlsConnection::GROUP_X25519 : 0)' server
# X25519MLKEM768 at the server: preferred, its share's size, the modulus
# check's alert, and the secret's and the share's order against OpenSSL.
prove_broken "an X25519 share taken before X25519MLKEM768 is asked for" "FAIL OpenSSL, ed25519, an X25519 share, X25519MLKEM768 listed" \
  '    return TlsConnection::GROUP_X25519MLKEM768 if @groups.includes?(TlsConnection::GROUP_X25519MLKEM768)' \
  '    return TlsConnection::GROUP_X25519MLKEM768 if @hybrid' server-hybrid
prove_broken "X25519 taken before X25519MLKEM768 when both shares come" "FAIL OpenSSL, ed25519, its default groups" \
  '    return TlsConnection::GROUP_X25519MLKEM768 if @groups.includes?(TlsConnection::GROUP_X25519MLKEM768)
' '' server-hybrid
prove_broken "the server's hybrid secret in the wrong order, X25519's first" "FAIL OpenSSL, ed25519, X25519MLKEM768 alone" \
  '      secret = sent_kem[1] + TlsBytes.of(shared)' '      secret = TlsBytes.of(shared) + sent_kem[1]' server-hybrid
prove_broken "the server's hybrid share with its X25519 key first" "FAIL OpenSSL, ed25519, X25519MLKEM768 alone" \
  '      public = sent_kem[0] + TlsBytes.of(X25519.public_key(private_key))' '      public = TlsBytes.of(X25519.public_key(private_key)) + sent_kem[0]' server-hybrid
prove_broken "a client's X25519MLKEM768 share of any size taken" "FAIL hybrid-long-share " \
  '        return TlsError.new("an X25519MLKEM768 share of #{key.size} bytes, not #{HYBRID_CLIENT_SHARE}", TlsAlert::ILLEGAL_PARAMETER) unless key.size == HYBRID_CLIENT_SHARE' '' server
prove_broken "an encapsulation key that fails the modulus check answered with internal_error" "FAIL hybrid-modulus " \
  '      return TlsError.new("the client'"'"'s X25519MLKEM768 share: #{sent_kem.message}", TlsAlert::ILLEGAL_PARAMETER) if sent_kem.is_a?(MlKemError)' \
  '      return TlsError.new("the client'"'"'s X25519MLKEM768 share: #{sent_kem.message}", TlsAlert::INTERNAL_ERROR) if sent_kem.is_a?(MlKemError)' server
prove_broken "a HelloRetryRequest for secp256r1 whatever the groups" "FAIL hrr " \
  '    TlsConnection::GROUPS.find { |group| @groups.includes?(group) } || 0' '    TlsConnection::GROUP_SECP256R1' server
prove_broken "the server's secp256r1 share not its key's" "FAIL p256-share " \
  '      public = ephemeral.public_point' '      public = ec_ephemeral(group).public_point' server
prove_broken "a secp384r1 share passed over" "FAIL p384-share " \
  '      elsif group == GROUP_SECP384R1
        p384 = key' '' server
prove_broken "secp384r1 not among the server's groups" "FAIL p384-share " \
  '  GROUPS12 = [GROUP_X25519, GROUP_SECP256R1, GROUP_SECP384R1]' '  GROUPS12 = [GROUP_X25519, GROUP_SECP256R1]' server
prove_broken "a secp384r1 share taken before a secp256r1 one" "FAIL ec-shares " \
  '  GROUPS12 = [GROUP_X25519, GROUP_SECP256R1, GROUP_SECP384R1]' '  GROUPS12 = [GROUP_X25519, GROUP_SECP384R1, GROUP_SECP256R1]' server
prove_broken "the server's secp384r1 share made in secp256r1" "FAIL p384-share " \
  '      ephemeral = ec_ephemeral(group)
      got = ephemeral.shared_secret(peer)
      return TlsError.new("the client'"'"'s' '      ephemeral = ec_ephemeral(GROUP_SECP256R1)
      got = ephemeral.shared_secret(peer)
      return TlsError.new("the client'"'"'s' server
prove_broken "an exporter under another label" "FAIL the client exported" \
  '    @schedule.expand_label(secret, "exporter", @schedule.hash(context), length)' '    @schedule.expand_label(secret, "exported", @schedule.hash(context), length)' client-export
prove_broken "the exporter's secret over the transcript to the client's flight" "FAIL the client exported" \
  '    @exporter_secret = @schedule.derive_secret(master, "exp master", @transcript)

    # The client'"'"'s flight:' '    @exporter_secret = @schedule.derive_secret(master, "exp master", @transcript + @transcript)

    # The client'"'"'s flight:' client-export
prove_broken "server_name written as the host was given" "FAIL server_name for \"bücher.example.\"" \
  '      name = TlsBytes.of(@name)' '      name = TlsBytes.of(@host)' client-sni
prove_broken "a Unicode host's server_name not in A-labels" "FAIL server_name for \"bücher.example.\"" \
  '    return name if name.bytesize == name.size' '    return name' client-sni
prove_broken "a host's final dot kept in server_name" "FAIL server_name for \"localhost.\"" \
  '    name = host.ends_with?(".") ? host[0, host.bytesize - 1] : host' '    name = host' client-sni
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
  '      return TlsError.new("the client sent no certificate", @tls12 ? TlsAlert::HANDSHAKE_FAILURE : TlsAlert::CERTIFICATE_REQUIRED) if @config.client_required' '' server-mtls
prove_broken "a client Certificate's request context unchecked" "FAIL mtls-context " \
  '    return TlsError.new("a client Certificate whose request context is not the server'"'"'s", TlsAlert::ILLEGAL_PARAMETER) unless context.empty?' '' server-mtls
prove_broken "a certificate required where it is optional" "FAIL mtls-optional-none " \
  ' if @config.client_required
      return nil' '
      return nil' server-mtls-optional
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
# Resumption. The key schedule's PSK half against RFC 8448's resumed
# trace, the ticket keys and the session against a clock of the
# exercise's own; the client against the scripted server, which checks a
# ticket's binder and age, and OpenSSL's tickets; the server against the
# scripted client, each rule of section 4.2.11 broken once.
prove_broken "a ticket's PSK made without its nonce" "the ticket's PSK, from its nonce" \
  '    expand_label(secret, "resumption", nonce, @hash_size)' '    expand_label(secret, "resumption", [] of UInt8, @hash_size)'
prove_broken "a binder keyed as an external PSK's" "the PSK binder, over the ClientHello to its binders" \
  '"res binder"' '"ext binder"'
prove_broken "the handshake secret without the PSK" "the handshake secret, over the PSK's early secret and the share" \
  '    early = psk ? early_secret(psk) : early_secret' '    early = early_secret'
prove_broken "a ticket past its lifetime opened" "a ticket past its lifetime by this server's count does not open" \
  '    return nil if age < 0 || age > opened.lifetime * 1000_i64' ''
prove_broken "a ticket key never rotated" "a ticket under the key two before does not open" \
  '    return if age < period_ms' '    return if true'
prove_broken "a ticket offered to any host" "a ticket is for the host it came from" \
  '      if held.host == host' '      if true'
prove_broken "a ticket offered and kept" "the newest ticket for the host is taken out" \
  '        @tickets = kept' ''
prove_broken "a ticket past its lifetime offered" "a ticket past its lifetime is not offered" \
  'now_ms - held.received_ms < held.lifetime_ms && ' ''
# A client's ticket held to where and how it was taken (`TlsSession`):
# the port, the configuration and each part `TlsMadeUnder` compares, the
# server certificate's notAfter, seven days from the full handshake - and
# a resumption's tickets keeping that handshake's time - by the trace's
# own tickets and by its own client and server; a port the client never
# reads breaks only the second.
prove_broken "a ticket offered to another port" "a ticket is not offered to another port" \
  ' && held.port == port' ''
prove_broken "a client's port not read off its socket" "a ticket from one port is not offered to another" \
  '      @port = @socket.unix? ? 0 : (@socket.remote_port || 0)' '      @port = 0'
prove_broken "a ticket offered under another configuration" "a ticket is not offered under another configuration" \
  ' && held.under.same?(config)' ''
prove_broken "roots assigned in place not seen" "a ticket is not offered after roots is assigned in place" \
  '(!roots.nil? && held.object_id == roots.object_id)' '!roots.nil?'
prove_broken "an identity assigned in place not seen" "a ticket is not offered after identity is assigned in place" \
  '(!identity.nil? && mine.object_id == identity.object_id)' '!identity.nil?'
prove_broken "now assigned in place not seen" "a ticket is not offered after now is assigned in place" \
  '@now == config.now && ' ''
prove_broken "min_version assigned in place not seen" "a ticket is not offered after min_version is assigned in place" \
  '@min_version == config.min_version && ' ''
prove_broken "require_staple assigned in place not seen" "a ticket is not offered after require_staple is assigned in place" \
  ' && @require_staple == config.require_staple' ''
prove_broken "a ticket offered past its server certificate's notAfter" "a ticket whose server certificate has expired is not offered" \
  '        return held unless leaf && checked_at > leaf.not_after' '        return held'
prove_broken "a ticket offered past seven days from its full handshake" "a ticket seven days from its full handshake is not offered" \
  ' && now_ms - held.authenticated_ms < MAX_LIFETIME * 1000_i64' ''
prove_broken "a resumption's time of authentication not carried on" "a ticket a resumed connection receives keeps its full handshake's time" \
  '      @authenticated_ms = offered.authenticated_ms' ''
prove_broken "a ticket kept with the time it came" "a ticket a resumed connection receives keeps its full handshake's time" \
  '@peer_certificates, @authenticated_ms, early))' '@peer_certificates, TlsTime.now_ms, early))'
# The server's ticket state, each length its own size: a name and an
# identity's place past a byte, as version 1 cut them.
prove_broken "a ticket's name length cut to a byte" "a ticket's name past 255 bytes comes back whole" \
  '+ @psk + TlsBytes.u16(name.size) + name' '+ @psk + TlsBytes.u16(name.size & 0xFF) + name'
prove_broken "a ticket's identity cut to a byte" "a ticket's identity past 255 comes back whole" \
  'TlsBytes.u32(@identity.to_i64)' 'TlsBytes.u32((@identity & 0xFF).to_i64)'
# server_name held to a DNS name's 253 bytes, and no shorter.
prove_broken "a server_name of any length taken" "a server_name past 253 bytes is refused" \
  '          if name.size > MAX_HOST_NAME' '          if false'
prove_broken "a server_name of 253 bytes refused" "a server_name of 253 bytes is taken" \
  '          if name.size > MAX_HOST_NAME' '          if name.size >= MAX_HOST_NAME'
prove_broken "a binder over the whole ClientHello" "resume: refused" \
  '    binder = schedule.binder(offered.psk, prefix + hello[0, hello.size - binders.size])' '    binder = schedule.binder(offered.psk, prefix + hello)' scenarios
prove_broken "a ticket's age sent without its age_add" "resume: refused" \
  '    age = (TlsTime.now_ms - offered.received_ms + offered.age_add) & 0xFFFFFFFF_i64' '    age = (TlsTime.now_ms - offered.received_ms) & 0xFFFFFFFF_i64' scenarios
prove_broken "the PSK identity a ServerHello takes unchecked" "resume-identity:" \
  '      return TlsError.new("a ServerHello choosing PSK identity #{reply.psk_identity}, of one offered", TlsAlert::ILLEGAL_PARAMETER) unless reply.psk_identity == 0' '' scenarios
prove_broken "a resumption under another hash's suite taken" "resume-hash:" \
  '      unless TlsSuites.sha384?(offered.suite) == TlsSuites.sha384?(@suite)' '      if false' scenarios
prove_broken "a Certificate taken in a resumed handshake" "resume-cert:" \
  '    return server_finished(message, server_secret) if @resumed' '    return server_finished(message, server_secret) if @resumed && message[0] != 11_u8' scenarios
prove_broken "tickets kept past the session's limit" "ticket-many:" \
  '    while @tickets.size > @limit
      @tickets.shift
    end' '' scenarios
prove_broken "a ticket past 16 KiB kept" "ticket-huge:" \
  '    return nil if lifetime == 0_i64 || ticket.size > TlsSession::MAX_TICKET' '    return nil if lifetime == 0_i64' scenarios
prove_broken "a NewSessionTicket cut short taken" "ticket-bad:" \
  '    return TlsError.new("a NewSessionTicket cut short", TlsAlert::DECODE_ERROR) if reader.short? || !reader.done? || ticket.empty?' '' scenarios
prove_broken "the client's resumption master secret short of its Finished" "FAIL resumed by OpenSSL's tickets, the default suites" \
  '    @resumption_secret = @schedule.derive_secret(master, "res master", @transcript + finished)' '    @resumption_secret = @schedule.derive_secret(master, "res master", @transcript)' client-resume
prove_broken "a second ClientHello's binder without the HelloRetryRequest" "FAIL resumed by OpenSSL's tickets, secp256r1 alone" \
  '      hello = client_hello(random, session, shares, cookie, @transcript)' '      hello = client_hello(random, session, shares, cookie, [] of UInt8)' client-resume
prove_broken "a binder that does not match taken" "FAIL resume-bad-binder " \
  '      unless Subtle.constant_time_compare(offer.binders[index], @schedule.binder(ticket.psk, transcript))' '      if false' server
prove_broken "a ticket under another hash's suite taken" "FAIL resume-other-hash " \
  '      next unless TlsSuites.sha384?(ticket.suite) == TlsSuites.sha384?(@suite)' '' server
prove_broken "a ticket taken for another server_name" "FAIL resume-other-sni " \
  '      next unless ticket.server_name == offer.server_name' '' server
prove_broken "a ticket the client says is past its lifetime taken" "FAIL resume-expired " \
  '      next if ((entry[1] - ticket.age_add) & 0xFFFFFFFF_i64) > ticket.lifetime * 1000_i64' '' server
prove_broken "a ticket offered for psk_ke alone taken" "FAIL resume-psk-ke " \
  '    return nil unless offer.psk_modes.includes?(TlsSession::PSK_DHE_KE)' '' server
prove_broken "a pre_shared_key without psk_key_exchange_modes taken" "FAIL resume-no-modes " \
  '    return TlsError.new("a pre_shared_key without psk_key_exchange_modes", TlsAlert::MISSING_EXTENSION) if psk_modes.nil? && !identities.empty?' '' server
prove_broken "identities and binders of other counts taken" "FAIL resume-binders " \
  '        unless identities.size == binders.size' '        if false' server
prove_broken "a resumption's flight with the certificate in it" "FAIL resume " \
  '    flight = flight + certificate_flight unless @resumed' '    flight = flight + certificate_flight' server
prove_broken "the server's resumption master secret short of the client's Finished" "FAIL resume " \
  '    @transcript = @transcript + message
    @resumption_secret' '    @resumption_secret' server
prove_broken "a second ClientHello's binder checked without the HelloRetryRequest" "FAIL resume-hrr " \
  '      transcript = @transcript[0, @transcript.size - hello.size] + hello[0, hello.size - offer.binders_size]' '      transcript = hello[0, hello.size - offer.binders_size]' server
prove_broken "a client with no signature_algorithms refused though its ticket is taken" "FAIL resume-no-sigalgs " \
  '    return unshown if unshown && identities.empty?' '    return unshown if unshown' server
prove_broken "a client's certificate not carried by its ticket" "FAIL mtls-resume " \
  '      @peer_certificates = chain' '' server-mtls
# Early data (0-RTT). Its keys and records against RFC 8448's trace and the
# replay guard on a clock of the exercise's own; the server against the
# scripted client - a replay, too much, stale, another protocol or suite,
# the ticket second, EndOfEarlyData missing, a record that does not open -
# and the client against the scripted server and OpenSSL's.
prove_broken "early data under the handshake label" "client_early_traffic_secret" \
  '"c e traffic"' '"c hs traffic"'
prove_broken "a replay guard that forgets nothing" "a binder is dropped two windows after it came" \
  '    while @head < @binders.size && now_ms - @times[@head] > 2_i64 * WINDOW_MS' '    while false'
prove_broken "a replay of early data taken" "FAIL early-replay " \
  '    return false if @held.has_key?(key)' '' server
prove_broken "early data delivered as 1-RTT data" "FAIL early-ok " \
  '        return content unless content.empty?' '        @pending = content unless content.empty?' server
prove_broken "early data past the ticket's max_early_data_size taken" "FAIL early-too-much " \
  '        if @early_read > @early_limit' '        if false' server
prove_broken "early data held to the ticket's allowance alone" "early data is held to the server's lowered limit" \
  '@early_limit = ticket.max_early_data < @config.early_limit ? ticket.max_early_data : @config.early_limit' '@early_limit = ticket.max_early_data'
prove_broken "early data taken outside the freshness window" "FAIL early-stale " \
  '    return false unless TlsReplayGuard.fresh?((offer.identities[index][1] - ticket.age_add) & 0xFFFFFFFF_i64, now - ticket.issued_ms)' '' server
prove_broken "early data taken under another ALPN protocol" "FAIL early-alpn " \
  '    return false unless ticket.alpn == @alpn_protocol' '' server
prove_broken "early data taken under another suite" "FAIL early-suite " \
  '    return false unless ticket.suite == @suite' '' server
prove_broken "early data taken for an identity not the first" "FAIL early-second " \
  '    return false unless index == 0' '' server
prove_broken "early data taken where the server allows none" "FAIL mtls-early-unallowed " \
  '    return false unless @takes_early && @config.early_limit > 0 && ticket.max_early_data > 0' '    return false unless @takes_early' server-mtls
prove_broken "a client's Finished taken for EndOfEarlyData" "FAIL early-finished-early " \
  '        unless message[0] == 5_u8 && message.size == 4' '        if false' server
prove_broken "taken early records that do not open passed over" "FAIL early-bad-record " \
  '        @early_left = 0' '        @early_left = EARLY_ALLOWANCE' server
# Section 5.1 among the early records: half an EndOfEarlyData, then early
# data or a close_notify, which the early reader took before it was held
# to the rule (`cut_message`) as the reader after the handshake is.
prove_broken "early data taken inside a split EndOfEarlyData" "FAIL early-split-eoed " \
  '        cut = cut_message(type)
        return cut if cut
        @early_read = @early_read + content.size' '        @early_read = @early_read + content.size' server
prove_broken "close_notify taken inside a split EndOfEarlyData" "FAIL early-split-close " \
  '        return answer if answer
        cut = cut_message(type)
        return cut if cut' '        return answer if answer' server
# Section 5.4's limit at the server, by an early record: the early keys
# open records through the same TlsRecordCipher#open as every other, so
# the break is the client's "padding past 2^14 + 1 bytes" one above, made
# here where the scripted client's early record is what pads past it.
prove_broken "an early record padded past 2^14 + 1 bytes of inner plaintext taken" "FAIL early-padded-over " \
  '    if opened.bytesize > TlsRecords::MAX_PLAINTEXT + 1' '    if opened.bytesize > TlsRecords::MAX_PLAINTEXT + 256' server
prove_broken "the client's early data sent again under another protocol" "early-alpn:" \
  '      if @early_alpn != @alpn_protocol' '      if false' scenarios
prove_broken "the client's early data past the ticket's allowance" "early-small:" \
  'data.size <= offered.max_early_data' 'true' scenarios
prove_broken "an early_data acceptance of nothing sent taken" "early-unoffered:" \
  '        return TlsError.new("an early_data acceptance where none was sent", TlsAlert::UNSUPPORTED_EXTENSION) unless @early_sent && !@retried' '' scenarios
prove_broken "the client's EndOfEarlyData left out" "early: " \
  '    if @early_taken && (early = @early_writer)' '    if false && (early = @early_writer)' scenarios
prove_broken "the client's early data under keys of another transcript" "FAIL early data to OpenSSL's s_server, taken" \
  'schedule.early_traffic(offered.psk, hello))' 'schedule.early_traffic(offered.psk, hello + hello))' client-early

# TLS 1.2 at the server: opt-in, so a server not told answers 1.3 alone;
# then each rule of its 1.2 handshake before the scripted client, the
# client's report naming the scenario that breaks it - and the exporter,
# and the sentinel as the std/tls client's 1.2 copy reads it, before the
# other clients of the section.
prove_broken "TLS 1.2 answered by a server not told to" "FAIL tls12 " \
  '  # either way.
  property min_version : TlsVersion = TlsVersion::TLS13' '  # either way.
  property min_version : TlsVersion = TlsVersion::TLS12' server
prove_broken "TLS 1.2 chosen though the client offers 1.3" "FAIL both-versions " \
  '    tls12 = !tls13 && @config.min_version' '    tls12 = @config.min_version' server12
prove_broken "a client offering TLS 1.1 alone answered in 1.2" "FAIL 12-tls11 " \
  '((named = versions) ? named.includes?(0x0303) : legacy >= 0x0303)' 'true' server12
prove_broken "a client without the extended master secret answered" "FAIL 12-no-ems " \
  '    return TlsError.new("the client does not do the extended master secret (RFC 7627), which a TLS 1.2 handshake here requires", TlsAlert::HANDSHAKE_FAILURE) unless ems
    return TlsError.new("an extended_master_secret offer with a body", TlsAlert::DECODE_ERROR) unless ems.empty?' '' server12
prove_broken "the master secret over the randoms, not the session hash, at the server" "FAIL 12-ok " \
  '@schedule.prf(secret, "extended master secret", @schedule.hash(@transcript), 48)' '@schedule.prf(secret, "master secret", client_random + server_random, 48)' server12
prove_broken "the session hash short of the client's ClientKeyExchange" "FAIL 12-ok " \
  '    @transcript = @transcript + message
    master, client_keys, server_keys = keys12(secret, offer.random, random)' '    master, client_keys, server_keys = keys12(secret, offer.random, random)
    @transcript = @transcript + message' server12
prove_broken "the downgrade sentinel left out of a TLS 1.2 ServerHello" "FAIL 12-ok " \
  'random = Random::Secure.random_bytes(24) + TlsBytes.from_hex(DOWNGRADE_TLS12)' 'random = Random::Secure.random_bytes(32)' server12
if [ -x "$WORK/downgrade/tlsx" ]; then
  prove_broken "the downgrade sentinel left out, before the std/tls client's 1.2" "FAIL the std/tls client offering TLS 1.2 alone, ed25519: the sentinel" \
    'random = Random::Secure.random_bytes(24) + TlsBytes.from_hex(DOWNGRADE_TLS12)' 'random = Random::Secure.random_bytes(32)' server12-interop
else
  echo "  no copy of the client offering TLS 1.2 alone here, so the sentinel's proof before it is unmeasured"
fi
prove_broken "a session id given, for a resumption nothing offers" "FAIL 12-ok " \
  'random + [0_u8] + TlsBytes.u16(@suite)' 'random + [32_u8] + random + TlsBytes.u16(@suite)' server12
prove_broken "TLS 1.2's PRF over SHA-256 for an AES-256 suite" "FAIL 12-aes256 " \
  '    @schedule = TlsKeySchedule.new(TlsSuites.sha384?(@suite))
    @server_name = offer.server_name' '    @schedule = TlsKeySchedule.new(false)
    @server_name = offer.server_name' server12
prove_broken "the server's TLS 1.2 suite order put before the client's" "FAIL 12-client-order " \
  '    @suite = offer.suites.find { |s| TlsSuites::TLS12.includes?(s) && TlsSuites.rsa?(s) == chosen.rsa? } || 0' \
  '    @suite = TlsSuites::TLS12.find { |s| offer.suites.includes?(s) && TlsSuites.rsa?(s) == chosen.rsa? } || 0' server12
prove_broken "a TLS 1.2 record's read sequence number not advanced" "FAIL 12-ok " \
  '    @sequence = @sequence + 1
    return TlsError.new("a record of #{length} bytes, past the 2^14 allowed"' '    return TlsError.new("a record of #{length} bytes, past the 2^14 allowed"' server12
prove_broken "AES-GCM's explicit nonce the same for every record" "FAIL 12-ok " \
  '    explicit = sequence_bytes
    aad = explicit + [type, 3_u8, 3_u8] + TlsBytes.u16(content.size)' '    explicit = Array(UInt8).new(8, 0_u8)
    aad = sequence_bytes + [type, 3_u8, 3_u8] + TlsBytes.u16(content.size)' server12
prove_broken "the server's TLS 1.2 reads under its own write keys" "FAIL 12-ok " \
  '    @reader = client_keys' '    @reader = server_keys' server12
prove_broken "the server's TLS 1.2 Finished under the client's label" "FAIL 12-ok " \
  '"server finished"' '"client finished"' server12
prove_broken "the client's TLS 1.2 Finished unchecked" "FAIL 12-bad-finished " \
  '    unless Subtle.constant_time_compare(message[4, message.size - 4], finished12(master, true))' '    if false' server12
prove_broken "the ServerKeyExchange signed without the client's random" "FAIL 12-ok " \
  'signature = @identity.sign(scheme, offer.random + random + params)' 'signature = @identity.sign(scheme, random + params)' server12
prove_broken "a ClientKeyExchange point of small order taken" "FAIL 12-bad-point " \
  '      return TlsError.new("the client'"'"'s X25519 point gives no secret", TlsAlert::ILLEGAL_PARAMETER) if shared.is_a?(CurveError)' \
  '      shared = X25519.public_key(x25519_key) if shared.is_a?(CurveError)' server12
prove_broken "renegotiation_info left unanswered" "FAIL 12-ok " \
  '    answers = answers + TlsBytes.extension(0xff01, [0_u8]) if offer.renegotiation_info || offer.suites.includes?(0x00FF)' '' server12
prove_broken "TLS_EMPTY_RENEGOTIATION_INFO_SCSV not taken as the signal" "FAIL 12-scsv " \
  ' if offer.renegotiation_info || offer.suites.includes?(0x00FF)' ' if offer.renegotiation_info' server12
prove_broken "a client's renegotiation_info with something in it taken" "FAIL 12-reneg-data " \
  '      return TlsError.new("a renegotiation_info that is not empty, on a first handshake", TlsAlert::HANDSHAKE_FAILURE) unless connection.empty?' '' server12
prove_broken "a renegotiating ClientHello passed over" "FAIL 12-renegotiate " \
  '        return TlsError.new("a ClientHello after the TLS 1.2 handshake: a renegotiation, which this server refuses", TlsAlert::NO_RENEGOTIATION) if message[0] == 1_u8' \
  '        next if message[0] == 1_u8' server12
prove_broken "no_renegotiation sent as a fatal alert" "FAIL 12-renegotiate " \
  '      content = [code == TlsAlert::NO_RENEGOTIATION ? 1_u8 : 2_u8, code]' '      content = [2_u8, code]' server12
prove_broken "TLS_FALLBACK_SCSV unchecked" "FAIL 12-fallback " \
  '    if offer.suites.includes?(0x5600)' '    if false' server12
prove_broken "ec_point_formats without uncompressed points taken" "FAIL 12-formats " \
  '      return TlsError.new("ec_point_formats without uncompressed points", TlsAlert::ILLEGAL_PARAMETER) unless listed.includes?(0_u8)' '' server12
# named_group in TLS 1.2 too: the group the ServerKeyExchange named.
prove_broken "the TLS 1.2 server's group left unnamed" "FAIL 12-ok " \
  '    @named_group = group_name(group)
    @cipher_suite = TlsSuites.name(@suite)' '    @cipher_suite = TlsSuites.name(@suite)' server12
prove_broken "a P-256 certificate shown to a client whose groups leave its curve out" "FAIL 12-p256-no-curve " \
  '      unless groups.includes?(curve)
        return "the client'"'"'s supported_groups leave out' '      if false
        return "the client'"'"'s supported_groups leave out' server12
# The same check, caught where the client lists the other curve alone: a
# P-256 certificate for secp384r1, a P-384 one for secp256r1.
prove_broken "a P-256 certificate shown to a client offering secp384r1 alone" "FAIL 12-p384 " \
  '      unless groups.includes?(curve)
        return "the client'"'"'s supported_groups leave out' '      if false
        return "the client'"'"'s supported_groups leave out' server12
prove_broken "a P-384 certificate shown to a client offering secp256r1 alone" "FAIL 12-p256 " \
  '      unless groups.includes?(curve)
        return "the client'"'"'s supported_groups leave out' '      if false
        return "the client'"'"'s supported_groups leave out' server12
prove_broken "secp384r1 left out of TLS 1.2's groups" "FAIL 12-p384 " \
  '  GROUPS12 = [GROUP_X25519, GROUP_SECP256R1, GROUP_SECP384R1]' '  GROUPS12 = [GROUP_X25519, GROUP_SECP256R1]' server12
prove_broken "PKCS #1 v1.5 put before RSA-PSS" "FAIL 12-ok " \
  '    pss = scheme_for(offered)' '    pss = @rsa ? nil : scheme_for(offered)' server12
prove_broken "an RSA key that never signs under PKCS #1 v1.5" "FAIL 12-pkcs1 " \
  '    return pss if pss || @rsa.nil?' '    return pss' server12
prove_broken "PKCS #1 v1.5 signed as RSA-PSS" "FAIL 12-pkcs1 " \
  '      return rsa.sign_pkcs1v15([RsaHash::SHA256, RsaHash::SHA384, RsaHash::SHA512][pkcs1], content) if pkcs1' '' server12
prove_broken "handshake bytes across the client's ChangeCipherSpec" "FAIL 12-ccs-split " \
  '    return TlsError.new("handshake bytes before #{@peer}'"'"'s ChangeCipherSpec", TlsAlert::UNEXPECTED_MESSAGE) unless handshake_left == 0' '' server12
# And at the server, the scripted client's: half a renegotiating
# ClientHello then application data, and a record of 2^14 + 1 bytes.
prove_broken "the server's TLS 1.2 application data taken inside a split handshake message" "FAIL 12-split-by-data " \
  '    return nil if handshake_left == 0
' '    return nil if handshake_left == 0 || @tls12
' server12
prove_broken "a TLS 1.2 record past 2^14 bytes of plaintext taken by the server" "FAIL 12-oversize " \
  ' if length > TlsRecords::MAX_PLAINTEXT
    {type, TlsBytes.of(opened)}' ' if false
    {type, TlsBytes.of(opened)}' server12
prove_broken "no CertificateRequest in TLS 1.2" "FAIL 12-mtls-ok " \
  '    request = @config.client_roots ? request12 : [] of UInt8' '    request = [] of UInt8' server12
prove_broken "a TLS 1.2 client with no certificate let in" "FAIL 12-mtls-none " \
  '      return TlsError.new("the client sent no certificate", @tls12 ? TlsAlert::HANDSHAKE_FAILURE : TlsAlert::CERTIFICATE_REQUIRED) if @config.client_required' '' server12
prove_broken "a client's TLS 1.2 CertificateVerify unchecked" "FAIL 12-mtls-bad-cv " \
  '    return TlsError.new("the client'"'"'s TLS 1.2 CertificateVerify is not its key'"'"'s signature", TlsAlert::DECRYPT_ERROR) unless ok' '' server12
if [ "$windows" = no ] && command -v "$OPENSSL" >/dev/null 2>&1; then
  prove_broken "TLS 1.2's exporter over the randoms in the server's order, at the server" "FAIL OpenSSL, TLS 1.2, ed25519, exported keying material" \
    '    @randoms12 = client_random + server_random' '    @randoms12 = server_random + client_random' server12-interop
else
  echo "  no openssl here (or Windows), so the server's TLS 1.2 exporter proof is unmeasured"
fi
# OCSP stapling: the client's judgement against OpenSSL's s_server
# stapling, then the server's stapling against s_client -status.
prove_broken "a revoked staple taken" "FAIL a revoked staple, TLS 1.3" \
  '    if verdict.status == OcspCertStatus::Revoked' '    if false' ocsp-client
prove_broken "an unknown staple taken" "FAIL an unknown staple" \
  '    return TlsError.new("the stapled OCSP response does not know #{leaf.subject_name}: its status is unknown", TlsAlert::BAD_CERTIFICATE_STATUS_RESPONSE) if verdict.status == OcspCertStatus::Unknown' '' ocsp-client
prove_broken "an invalid staple taken" "FAIL a staple signed by another key under the CA's name" \
  '    return TlsError.new("the stapled OCSP response: #{verdict.message}", TlsAlert::BAD_CERTIFICATE_STATUS_RESPONSE) if verdict.is_a?(OcspError)' '    return nil if verdict.is_a?(OcspError)' ocsp-client
prove_broken "the TLS 1.3 staple never judged" "FAIL a revoked staple, TLS 1.3" \
  '    problem = judge_staple
    return problem if problem
    @transcript = @transcript + message' '    @transcript = @transcript + message' ocsp-client
prove_broken "the TLS 1.2 staple never judged" "FAIL a revoked staple, TLS 1.2" \
  '    problem = judge_staple
    return problem if problem
    return TlsError.new("#{TlsBytes.handshake_name(message[0])} where ServerKeyExchange belongs"' '    return TlsError.new("#{TlsBytes.handshake_name(message[0])} where ServerKeyExchange belongs"' ocsp-client
prove_broken "no staple taken under must-staple" "FAIL a must-staple leaf without a staple, TLS 1.3" \
  '      if leaf.must_staple?' '      if false' ocsp-client
prove_broken "require_staple passed over" "FAIL no staple, require_staple" \
  ' if @config.require_staple
      return nil' ' if false
      return nil' ocsp-client
prove_broken "status_request not asked for" "FAIL a good staple, TLS 1.3" \
  '    extensions = extensions + TlsBytes.extension(5, [1_u8, 0_u8, 0_u8, 0_u8, 0_u8])' '' ocsp-client
prove_broken "a TLS 1.2 ServerHello's status_request not heard" "FAIL a good staple, TLS 1.2" \
  '        @status_acked = true' '' ocsp-client
prove_broken "the server staples nothing in TLS 1.3" "FAIL s_client -status, TLS 1.3" \
  '      status = i == 0 && staple ?' '      status = i < 0 && staple ?' ocsp-server
prove_broken "the server's TLS 1.2 CertificateStatus left out" "FAIL s_client -status, TLS 1.2" \
  '    certificate = certificate + TlsBytes.message(22, [1_u8] + TlsBytes.u24(staple.size) + staple) if staple' '' ocsp-server
prove_broken "the server's TLS 1.2 status_request answer left out" "FAIL s_client -status, TLS 1.2" \
  '    answers = answers + TlsBytes.extension(5, [] of UInt8) if staple' '' ocsp-server
prove_broken "a staple sent to a client that did not ask" "FAIL s_client without -status, sent none" \
  '    return nil unless @status_requested' '' ocsp-server
prove_broken "a staple past its nextUpdate sent" "FAIL a staple past its nextUpdate is not sent" \
  '    return nil if next_update && next_update < now' '' ocsp-server
prove_broken "a staple for another certificate kept by the config" "FAIL a staple for another certificate refused by the config" \
  '    return TlsError.new("the OCSP response has no SingleResponse for #{@leaf.subject_name}") unless single' '' ocsp-server
prove_broken "the config's identity's staple sent for an identity_source's" "FAIL an identity_source's identity, its own staple, TLS 1.3" \
  '    held = @identity.staple_at(@config.now || Time.utc)' '    held = @config.identity.staple_at(@config.now || Time.utc)' ocsp-server
# The close (RFC 8446 section 6.1, RFC 5246 section 7.2.1), against the
# scripted client's close-half, peer-close and 12-peer-close.
prove_broken "the server's close without its drain: closed at its close_notify" "FAIL close-half " \
  '    drain unless @eof
' '' server
prove_broken "close_write's half-close skipped: the socket's sending half left open" "FAIL close-half " \
  '    shut = @socket.close_write
' '    shut = nil.as(SocketError?)
' server
prove_broken "close_write without its close_notify" "FAIL close-half " \
  '    sent = send_protected(TlsRecords::ALERT, [1_u8, 0_u8])
    return sent if sent
    return TlsError.new("the socket under' '    return TlsError.new("the socket under' server
prove_broken "TLS 1.3's writing refused after the peer's close_notify" "FAIL peer-close " \
  ') if @tls12 && @eof' ') if @eof' server
prove_broken "TLS 1.2's writing let on after the peer's close_notify" "FAIL 12-peer-close " \
  ') if @tls12 && @eof' ') if false' server12
mutations_report
echo
if [ "$status" -eq 0 ]; then
  echo "the std/tls exercise holds ($mutations breaks caught)"
else
  echo "the std/tls exercise did not hold"
fi
exit $status
