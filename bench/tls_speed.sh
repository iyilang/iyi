#!/usr/bin/env bash
# std/tls's throughput, measured against its own cipher's on this machine.
#
# A TLS read or write is the cipher's work and the record layer's around
# it: framing, copies, the socket. That second part was most of it - the
# prelude's arrays joined and sliced a byte at a time, and the inbox took
# the socket's bytes one `<<` each - and ChaCha20-Poly1305 moved 98 MB/s
# read and 140 written over loopback where the cipher alone did some
# 900. Megabytes a second differ from machine to machine; what the record
# layer costs beside the cipher does not as much. So each rate is set
# against the cipher's own, one way, on the same machine, and a rate under
# FLOOR percent of it fails: a byte-at-a-time copy back in the path puts
# ChaCha20-Poly1305 near 15.
#
# The peer is OpenSSL's s_server (-WWW, serving a file) for reads and its
# s_client for writes, so its side costs little. Best of three runs each.
#   bash bench/tls_speed.sh            needs openssl and python3
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
FLOOR="${FLOOR:-25}"
MIB=32
WORK="$(mktemp -d)"
SERVER=""
trap '[ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$WORK"' EXIT

command -v openssl >/dev/null || { echo "tls_speed: no openssl"; exit 1; }
command -v python3 >/dev/null || { echo "tls_speed: no python3"; exit 1; }

"$IYI" build --release -o "$WORK/tls_speed" "$REPO/bench/tls_speed.iyi" || exit 1

# A root and a P-256 leaf for localhost under it; a file to read.
cd "$WORK" || exit 1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.pem \
  -days 2 -subj /CN=tls-speed-root >/dev/null 2>&1
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout leaf.key -out leaf.csr \
  -subj /CN=localhost >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' >leaf.ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 1 -extfile leaf.ext \
  -out leaf.pem >/dev/null 2>&1
cat leaf.pem ca.pem >chain.pem
mkdir -p www
python3 -c "import os, sys; sys.stdout.buffer.write(os.urandom($MIB * 1048576))" >www/data

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# pull <suite>: one run's MB/s reading the file from s_server.
pull() {
  local port answer
  port="$(free_port)"
  (cd www && exec openssl s_server -accept "127.0.0.1:$port" -WWW -tls1_3 -ciphersuites "$1" \
    -cert ../chain.pem -key ../leaf.key >/dev/null 2>&1 </dev/null) &
  SERVER=$!
  for _ in $(seq 1 50); do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null && break
    sleep 0.1
  done
  answer="$("$WORK/tls_speed" pull "$port" ca.pem data 2>&1)"
  kill "$SERVER" 2>/dev/null
  wait "$SERVER" 2>/dev/null
  SERVER=""
  printf '%s\n' "$answer" | awk -v s="$1" '$1 == "pull" && $2 == s { print $3 }'
}

# push <suite>: one run's MB/s writing to s_client.
push() {
  local port answer client
  port="$(free_port)"
  rm -f ready
  "$WORK/tls_speed" push "$port" chain.pem leaf.key ready "$MIB" >push.out 2>&1 &
  SERVER=$!
  for _ in $(seq 1 100); do
    [ -f ready ] && break
    sleep 0.1
  done
  openssl s_client -connect "127.0.0.1:$port" -tls1_3 -ciphersuites "$1" -quiet \
    >/dev/null 2>&1 </dev/null &
  client=$!
  wait "$SERVER" 2>/dev/null
  SERVER=""
  kill "$client" 2>/dev/null
  wait "$client" 2>/dev/null
  awk -v s="$1" '$1 == "push" && $2 == s { print $3 }' push.out
}

best() {
  printf '%s\n' "$@" | awk 'NF { if ($1 > m) m = $1 } END { print m + 0 }'
}

"$WORK/tls_speed" cipher >cipher.out || exit 1
status=0
printf '%-30s %5s %10s %10s %7s\n' suite way "TLS MB/s" "AEAD MB/s" share
for suite in TLS_AES_128_GCM_SHA256 TLS_CHACHA20_POLY1305_SHA256; do
  for way in pull push; do
    runs=()
    for _ in 1 2 3; do
      runs+=("$("$way" "$suite")")
    done
    tls="$(best "${runs[@]}")"
    op=open
    [ "$way" = push ] && op=seal
    aead="$(awk -v s="$suite" -v o="$op" '$1 == o && $2 == s { print $3 }' cipher.out)"
    share="$(awk -v t="$tls" -v a="$aead" 'BEGIN { printf "%d", (a > 0 ? 100 * t / a : 0) }')"
    printf '%-30s %5s %10s %10s %6s%%\n' "$suite" "$way" "$tls" "$aead" "$share"
    if [ "$share" -lt "$FLOOR" ]; then
      echo "  under $FLOOR% of the cipher's own rate: the record layer costs more than it should"
      status=1
    fi
  done
done
[ "$status" = 0 ] && echo "std/tls moves records at no less than $FLOOR% of its cipher's rate" \
  || echo "std/tls's throughput is under its floor"
exit "$status"
