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
# for a client certificate and ALPN, shows an error value's sentence
# through `.or_panic`, and proves on broken copies of the module that the
# checks fail where they say, the handshake's own against the scripted
# server.
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
    for kind in p256 p384 rsa; do
      case $kind in
        p256) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-256" ;;
        p384) opt="-newkey ec -pkeyopt ec_paramgen_curve:P-384" ;;
        rsa) opt="-newkey rsa:2048" ;;
      esac
      # shellcheck disable=SC2086
      "$OPENSSL" req -new -config leaf.cnf $opt -nodes -keyout $kind.key -out $kind.csr &&
        "$OPENSSL" x509 -req -in $kind.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out $kind.pem -days 20 -extfile leaf.ext
    done
  ) >"$WORK/pki.log" 2>&1
  interop=0
  # interop <label> <expected phrase> <host> <alpn or -> <s_server args...>
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
    if [ "$alpn" = - ]; then
      got="$("$WORK/tls-release" get "$port" "$PKI/ca.pem" "$host" 2>&1)"
    else
      got="$("$WORK/tls-release" get "$port" "$PKI/ca.pem" "$host" "$alpn" 2>&1)"
    fi
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
  interop "AES-256-GCM alone" "HTTP/1.0 200 ok TLS_AES_256_GCM_SHA384" localhost - -tls1_3 -cert p256.pem -key p256.key -ciphersuites TLS_AES_256_GCM_SHA384
  interop "ChaCha20-Poly1305 alone" "HTTP/1.0 200 ok TLS_CHACHA20_POLY1305_SHA256" localhost - -tls1_3 -cert p256.pem -key p256.key -ciphersuites TLS_CHACHA20_POLY1305_SHA256
  interop "stateless, so a HelloRetryRequest with a cookie" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert p256.pem -key p256.key -stateless
  interop "a client certificate asked for" "HTTP/1.0 200 ok" localhost - -tls1_3 -cert p256.pem -key p256.key -verify 1
  interop "ALPN" "alpn=http/1.1" localhost http/1.1 -tls1_3 -cert p256.pem -key p256.key -alpn http/1.1
  interop "a host the certificate does not name" "is not valid for example.com" example.com - -tls1_3 -cert p256.pem -key p256.key
  interop "TLS 1.2 alone" "alert protocol_version (70)" localhost - -tls1_2 -cert p256.pem -key p256.key
  interop "groups without X25519" "alert handshake_failure (40)" localhost - -tls1_3 -cert p256.pem -key p256.key -groups P-256
  cd "$REPO" || exit 1
  echo "  $interop answers from OpenSSL as they should be"
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
# prove_broken <label> <phrase> <old> <new> [scenarios]: the exercise must
# fail on a copy of the module with <old> replaced, at the check that names
# <phrase> - over the trace, or against the scripted server.
mutations=0
prove_broken() {
  mutations=$((mutations + 1))
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  local mode="${5:-trace}"
  if [ -z "$PY" ] || { [ "$mode" = scenarios ] && [ "$scripted" = no ]; }; then
    echo "  no scripted server or python3 here, so the $1 proof is unmeasured"
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
  '    unless Subtle.constant_time_compare(message[4, message.size - 4], expected)' '    if false' scenarios
prove_broken "CertificateVerify unchecked" "bad-cv: refused with" \
  '    return TlsError.new("the server'"'"'s CertificateVerify is not its key'"'"'s signature (decrypt_error)") unless ok' '' scenarios
prove_broken "CertificateVerify over the client's context string" "ok: refused" \
  '"TLS 1.3, server CertificateVerify"' '"TLS 1.3, client CertificateVerify"' scenarios
prove_broken "an ECDSA scheme taken for any curve" "cv-wrong-curve: refused with" \
  'unless key.is_a?(EcdsaPublicKey) && key.curve == curve' 'unless key.is_a?(EcdsaPublicKey)' scenarios
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

echo
if [ "$status" -eq 0 ]; then
  echo "the std/tls exercise holds ($mutations breaks caught)"
else
  echo "the std/tls exercise did not hold"
fi
exit $status
