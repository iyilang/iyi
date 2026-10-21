#!/usr/bin/env bash
# Exercises `std/autocert`: certificates got from an ACME CA as handshakes
# ask for them, kept, and renewed.
#
#     bash bench/std_autocert_exercise.sh
#
# The exercise holds the directory cache, the host policy refusing a name
# before a listener standing for the CA is reached, a failure remembered,
# when a certificate is due, and tls-alpn-01's certificate shown under
# acme-tls/1 alone; it runs plain and --release. Python then reads the
# cache it wrote (os.stat's modes, cryptography's keys) and makes
# handshakes with the challenge certificate up (bench/std_autocert_client.py).
# Where Go is here to build Let's Encrypt's Pebble, an HTTPS server in the
# exercise gets its certificates from it while Python's ssl connects: a
# chain verified to Pebble's root, TLS 1.2 too; a name the policy refuses
# with no order in Pebble's log; ten first handshakes at once making one
# order; a name Pebble refuses asked for once in three handshakes; a
# second process taking the first's certificates from the cache with no
# order; http-01 answered on port 80; the cache's modes; and from a second
# Pebble that issues certificates for 24 seconds, a renewal seen as a new
# serial before the first certificate ends. Then `iyi doc`, the
# formatting, five targets, the artifacts, and broken copies of
# std/autocert and of std/tls's identity source, each caught at the
# check that names it.
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
ORACLE=""
[ -n "$PY" ] && "$PY" -c 'from cryptography import x509; import ssl' >/dev/null 2>&1 && ORACLE=yes

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
CLIENT="$REPO/bench/std_autocert_client.py"

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

build() {
  local name="$1"
  shift
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_autocert_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $name: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
}

# local_run <binary> <cache dir> <out>: the exercise's own checks.
local_run() {
  rm -rf "$2"
  "$1" "$2" >"$3" 2>&1
}

echo "== the std/autocert exercise, plain build"
if build autocert-plain; then
  local_run "$WORK/autocert-plain" "$WORK/local-cache" "$WORK/plain.out"
  code=$?
  sed 's/^/  /' "$WORK/plain.out"
  if [ "$code" -ne 0 ] || ! grep -q "ALL CHECKS PASSED" "$WORK/plain.out"; then
    echo "  FAIL: the plain build exited $code"
    status=1
  fi
fi

echo
echo "== every section reported"
for phrase in "== the directory cache" "== the host policy, before the CA" "== a failure remembered" \
  "== when a certificate is due" "== tls-alpn-01 beside the certificates"; do
  if ! grep -qF "$phrase" "$WORK/plain.out" 2>/dev/null; then
    echo "  MISSING: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
if build autocert-release --release; then
  local_run "$WORK/autocert-release" "$WORK/release-cache" "$WORK/release.out"
  if grep -q "ALL CHECKS PASSED" "$WORK/release.out"; then
    echo "  ALL CHECKS PASSED"
  else
    echo "  FAIL: --release: $(tail -2 "$WORK/release.out")"
    status=1
  fi
fi

echo
echo "== the cache the exercise wrote, by Python's os.stat and cryptography"
if [ -z "$ORACLE" ]; then
  echo "  no python with ssl and cryptography here, so the cache's files go unread by it"
elif ! "$PY" "$CLIENT" modes "$WORK/local-cache"; then
  status=1
fi

echo
echo "== tls-alpn-01 on the HTTPS listener, Python's ssl"
if [ -z "$ORACLE" ]; then
  echo "  no python with ssl and cryptography here, so no handshake is made"
elif ! "$PY" "$CLIENT" alpn "$WORK/autocert-release" "$WORK/alpn"; then
  status=1
fi

echo
echo "== certificates from Let's Encrypt's Pebble"
# Pebble is Let's Encrypt's test ACME server (github.com/letsencrypt/pebble)
# and pebble-challtestsrv its DNS for the challenges: every name resolves
# to 127.0.0.1. Built from source with `go install ...@latest`, as
# std/acme's gate builds them. Two Pebbles: A issues for Pebble's default
# 90 days; B for 24 seconds (a profile's validityPeriod), so that the
# manager's thirty days before expiry is longer than the certificate's
# life and it renews two thirds in, 16 seconds after issue. Both validate
# on the same ports, where one exercise server at a time listens.
# PEBBLE_VA_NOSLEEP takes out the validation's random sleep;
# PEBBLE_AUTHZREUSE=0 makes every order prove its name afresh; and
# PEBBLE_WFE_NONCEREJECT=0 refuses no nonce, so that every newOrder
# request in Pebble's log is one the manager made - std/acme's gate holds
# the badNonce retries.
GO="${GO:-go}"
PEBBLE=""
if [ -z "$ORACLE" ] || ! command -v "$GO" >/dev/null 2>&1; then
  echo "  no Go here (or no python with cryptography to drive it), so Pebble is not built and nothing is ordered"
else
  GOBIN="$WORK/gobin"
  mkdir -p "$GOBIN"
  if ! GOBIN="$GOBIN" "$GO" install github.com/letsencrypt/pebble/v2/cmd/pebble@latest \
      github.com/letsencrypt/pebble/v2/cmd/pebble-challtestsrv@latest >"$WORK/go-install.log" 2>&1; then
    echo "  Pebble could not be fetched or built here (no network?), so nothing is ordered: $(tail -1 "$WORK/go-install.log")"
  else
    binary="$GOBIN/pebble"
    [ -f "$binary.exe" ] && binary="$binary.exe"
    version="$("$GO" version -m "$binary" 2>/dev/null | awk '$1 == "mod" && $2 == "github.com/letsencrypt/pebble/v2" { print $3 }')"
    certs="$("$GO" env GOMODCACHE)/github.com/letsencrypt/pebble/v2@$version/test/certs"
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN* | Windows_NT) certs="$(cygpath -m "$certs")" ;;
    esac
    mkdir -p "$WORK/pebble"
    # Seven free ports, each held open until all are drawn so none is
    # drawn twice; the Pebbles' configs and the client's setup from them.
    if ! "$PY" - "$WORK/pebble" "$certs" <<'PY'
import json, socket, sys
out, certs = sys.argv[1], sys.argv[2]
held = []
for _ in range(7):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    held.append(s)
ports = [s.getsockname()[1] for s in held]
for s in held:
    s.close()
acme_a, mgmt_a, acme_b, mgmt_b, http01, tlsalpn, dns = ports
for which, acme, mgmt, validity in (("a", acme_a, mgmt_a, 0), ("b", acme_b, mgmt_b, 24)):
    profile = {"description": "the default"}
    if validity:
        profile["validityPeriod"] = validity
    json.dump({"pebble": {"listenAddress": f"127.0.0.1:{acme}", "managementListenAddress": f"127.0.0.1:{mgmt}",
        "certificate": f"{certs}/localhost/cert.pem", "privateKey": f"{certs}/localhost/key.pem",
        "httpPort": http01, "tlsPort": tlsalpn, "ocspResponderURL": "", "externalAccountBindingRequired": False,
        "domainBlocklist": ["blocked.example"], "retryAfter": {"authz": 1, "order": 1}, "keyAlgorithm": "ecdsa",
        "profiles": {"default": profile}}}, open(f"{out}/{which}.json", "w", newline="\n"))
setup = {"work": out, "minica": f"{certs}/pebble.minica.pem", "tls_port": tlsalpn, "http_port": http01}
for which, acme, mgmt in (("a", acme_a, mgmt_a), ("b", acme_b, mgmt_b)):
    setup[which] = {"directory": f"https://localhost:{acme}/dir", "management": f"https://localhost:{mgmt}",
                    "log": f"{out}/pebble-{which}.log", "root": f"{out}/root-{which}.pem"}
json.dump(setup, open(f"{out}/setup.json", "w", newline="\n"))
open(f"{out}/ports", "w", newline="\n").write(f"{acme_a} {acme_b} {dns}\n")
PY
    then
      echo "  FAIL: no ports for Pebble"
      status=1
    else
      read -r P_A P_B P_DNS <"$WORK/pebble/ports"
      "$GOBIN/pebble-challtestsrv" -defaultIPv4 127.0.0.1 -defaultIPv6 "" -dnsserver "127.0.0.1:$P_DNS" \
        -management "127.0.0.1:0" -http01 "" -https01 "" -tlsalpn01 "" -doh "" >"$WORK/pebble/challtestsrv.log" 2>&1 &
      PIDS="$PIDS $!"
      for which in a b; do
        PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 PEBBLE_AUTHZREUSE=0 "$GOBIN/pebble" -config "$WORK/pebble/$which.json" \
          -dnsserver "127.0.0.1:$P_DNS" >"$WORK/pebble/pebble-$which.log" 2>&1 &
        PIDS="$PIDS $!"
      done
      if ! "$PY" - "$P_A" "$P_B" "$certs/pebble.minica.pem" <<'PY'
import ssl, sys, time, urllib.request
ctx = ssl.create_default_context(cafile=sys.argv[3])
deadline = time.time() + 30
for port in sys.argv[1:3]:
    while True:
        try:
            urllib.request.urlopen(f"https://localhost:{port}/dir", context=ctx, timeout=2).read()
            break
        except OSError:
            if time.time() > deadline:
                sys.exit(1)
            time.sleep(0.2)
PY
      then
        echo "  FAIL: the Pebbles did not come up in 30 s:"
        tail -3 "$WORK/pebble/pebble-a.log" "$WORK/pebble/pebble-b.log" | sed 's/^/    /'
        status=1
      else
        PEBBLE=yes
        grep -h "validity period" "$WORK/pebble/pebble-a.log" "$WORK/pebble/pebble-b.log" | sed 's/^.*Loaded/  Pebble loaded/'
        if ! "$PY" "$CLIENT" pebble "$WORK/autocert-release" "$WORK/pebble/setup.json" all; then
          status=1
          tail -5 "$WORK/pebble/pebble-a.log" | sed 's/^/    pebble: /'
        fi
      fi
    fi
  fi
fi

echo
echo "== doc, format, other platforms and artifacts"
if "$IYI" doc "$REPO/src/std/autocert.iyi" >"$WORK/doc.txt" 2>&1 && grep -q "identity_for" "$WORK/doc.txt"; then
  echo "  iyi doc reads std/autocert, AutocertManager's identity_for included"
else
  echo "  FAIL: iyi doc: $(grep -m1 -E 'Error|BUG' "$WORK/doc.txt")"
  status=1
fi
if "$IYI" fmt --check "$REPO/src/std/autocert.iyi" "$REPO/src/std/tls.iyi" "$REPO/bench/std_autocert_exercise.iyi" >"$WORK/format.log" 2>&1; then
  echo "  the module, std/tls and the exercise are formatted"
else
  echo "  FAIL: not formatted: $(grep -m1 produced "$WORK/format.log")"
  status=1
fi
apart=""
for target in x86_64-linux-gnu aarch64-darwin x86_64-windows-msvc aarch64-linux-gnu x86_64-linux-musl; do
  if ! "$IYI" build --no-codegen --target "$target" -o "$WORK/cross" "$REPO/bench/std_autocert_exercise.iyi" >"$WORK/cross.log" 2>&1; then
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
if (cd "$WORK/r1" && "$IYI" build --emit-iyimod mods -o from-source "$REPO/bench/std_autocert_exercise.iyi" &&
  "$IYI" build --use-iyimod mods -o from-artifact "$REPO/bench/std_autocert_exercise.iyi") >"$WORK/r1/build.log" 2>&1; then
  local_run "$WORK/r1/from-artifact" "$WORK/r1/cache" "$WORK/r1/artifact.out"
  # The ports the CA's stand-in listened on differ run to run.
  if grep -q "ALL CHECKS PASSED" "$WORK/r1/artifact.out" &&
    cmp -s <(sed 's/127\.0\.0\.1:[0-9]*/PORT/g' "$WORK/plain.out") <(sed 's/127\.0\.0\.1:[0-9]*/PORT/g' "$WORK/r1/artifact.out"); then
    echo "  built from its artifacts, the exercise prints what it prints from source"
  else
    echo "  FAIL: from its artifacts the exercise prints otherwise:"
    diff "$WORK/plain.out" "$WORK/r1/artifact.out" | sed -n '1,6p' | sed 's/^/    /'
    status=1
  fi
else
  echo "  FAIL: the artifacts did not build: $(grep -m1 -E 'Error|BUG' "$WORK/r1/build.log")"
  status=1
fi

echo
echo "== proving the checks can fail when the modules are broken"
# prove_broken <module> <label> <phrase> <part> <old> <new>: a copy of
# std/<module> with <old> replaced must fail at the check that names
# <phrase>. <part> is where that check is: `local`, the exercise's own
# checks; `cache`, those and then Python's reading of the cache they
# wrote, which needs cryptography and POSIX's modes; `alpn`, Python's
# handshakes with the challenge up; or Pebble's parts, by commas
# (bench/std_autocert_client.py), which run only where Pebble does.
mutations=0
caught=0
prove_broken() {
  local module="$1" label="$2" phrase="$3" part="$4"
  mutations=$((mutations + 1))
  if [ -z "$PY" ]; then
    echo "  no python here, so the $label proof is unmeasured"
    return
  fi
  if [ "$part" = cache ] && { [ -z "$ORACLE" ] || [ "$PSEP" = ';' ]; }; then
    echo "  $label: unmeasured here, as its check is POSIX's modes read by Python's cryptography"
    return
  fi
  if [ "$part" = alpn ] && [ -z "$ORACLE" ]; then
    echo "  $label: unmeasured here, as its check is Python's ssl and cryptography"
    return
  fi
  case "$part" in
    local | cache | alpn) ;;
    *)
      if [ -z "$PEBBLE" ]; then
        echo "  $label: unmeasured here, as its check orders from Pebble and Pebble is not running"
        return
      fi
      ;;
  esac
  rm -rf "$WORK/patched" "$WORK/mutant-cache" "$WORK/mutant-alpn" "$WORK/pebble/cache" "$WORK/pebble/renew-cache" "$WORK/pebble/root-"*.pem
  mkdir -p "$WORK/patched/std"
  if ! OLD="$5" NEW="$6" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/$module.iyi").read_text(encoding="utf-8")
if src.count(os.environ["OLD"]) != 1:
    raise SystemExit("patch site missing or not one")
Path("$WORK/patched/std/$module.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1), encoding="utf-8", newline="\n")
PY
  then
    echo "  the $label patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/mutant" \
      "$REPO/bench/std_autocert_exercise.iyi" >"$WORK/mutant.build.log" 2>&1; then
    echo "  the $label copy did not build: $(grep -m1 -E 'Error' "$WORK/mutant.build.log")"
    status=1
    return
  fi
  local passed=yes
  case "$part" in
    local | cache)
      local_run "$WORK/mutant" "$WORK/mutant-cache" "$WORK/mut.out" || passed=""
      if [ "$part" = cache ]; then
        "$PY" "$CLIENT" modes "$WORK/mutant-cache" >>"$WORK/mut.out" 2>&1 || passed=""
      fi
      ;;
    alpn) "$PY" "$CLIENT" alpn "$WORK/mutant" "$WORK/mutant-alpn" >"$WORK/mut.out" 2>&1 || passed="" ;;
    *) "$PY" "$CLIENT" pebble "$WORK/mutant" "$WORK/pebble/setup.json" "$part" >"$WORK/mut.out" 2>&1 || passed="" ;;
  esac
  if [ -n "$passed" ]; then
    echo "  the exercise PASSED on $label:"
    tail -3 "$WORK/mut.out" | sed 's/^/    /'
    status=1
  elif grep -F -e "ASSERTION FAILED: $phrase" -e "FAIL: $phrase" "$WORK/mut.out" >/dev/null; then
    echo "  $label is caught"
    caught=$((caught + 1))
  else
    echo "  $label failed, but not where it should have:"
    grep -m2 -E "FAIL|ASSERTION" "$WORK/mut.out" | sed 's/^/    /'
    status=1
  fi
}
prove_broken autocert "the host policy ignored" "a disallowed name is refused before the CA is asked" local \
  '    return AutocertError.new("#{name.inspect} is not a name this manager answers for") unless @host_policy.call(name)' \
  '    nil'
prove_broken autocert "the challenge certificate shown beside other protocols" "a challenge certificate is shown under acme-tls/1 alone" local \
  '    if alpn && alpn.size == 1 && alpn[0] == AcmeTlsAlpn01::PROTOCOL' \
  '    if @alpn_challenges.has_key?(name)'
prove_broken autocert "a private key written world-readable" "cache files are 0600" cache \
  'File.open(temporary, "w", perm: 0o600)' 'File.open(temporary, "w", perm: 0o644)'
prove_broken autocert "no single flight: each handshake its own order" "ten concurrent first connections create one order" ten \
  '    if flight = @flights[key]?' '    if flight = nil.as(AutocertFlight?)'
prove_broken autocert "the cache not read" "the cache survives a restart: no new order" restart \
  '    text = @cache.get(name)' '    text = nil.as(String?)'
prove_broken autocert "renewal never scheduled" "a renewal before expiry: new handshakes see a new serial" renewal \
  '          renew(name, held)' '          nil'
prove_broken tls "std/tls's identity source not asked in TLS 1.3" "under acme-tls/1 alone the challenge certificate is shown" alpn \
  '        given = source.call(server_name, alpn)' '        given = nil.as(TlsIdentity | TlsError | Nil)'
prove_broken tls "std/tls's identity source not asked in TLS 1.2" "a TLS 1.2 client is shown the same certificate" first \
  '      given = source.call(offer.server_name, offer.alpn)' '      given = nil.as(TlsIdentity | TlsError | Nil)'

echo
if [ "$status" -eq 0 ]; then
  if [ "$caught" -eq "$mutations" ]; then
    echo "the std/autocert exercise holds ($caught breaks caught)"
  else
    echo "the std/autocert exercise holds ($caught of $mutations breaks caught, the rest unmeasured here as said above)"
  fi
else
  echo "the std/autocert exercise did not hold"
fi
exit $status
