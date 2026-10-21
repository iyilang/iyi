#!/usr/bin/env bash
# Exercises std/secure_dns: a `Resolver` asking DNS over TLS and DNS over
# HTTPS upstreams instead of plaintext servers.
#
#     bash bench/std_secure_dns_exercise.sh
#
# The servers are bench/std_secure_dns_server.py, Python's ssl and
# http.server answering a fixed zone under a test root they make (and
# HTTP/2 through the `h2` package where it imports). The gate runs
# bench/std_secure_dns_exercise.iyi against them, plain and --release;
# asks dig the same questions over the same servers (`+tls`, `+https`,
# `+https-get`) and holds the two to the same answers, which is what shows
# the scripted servers speak the protocols and not merely what the iyi
# client expects; and proves the checks can fail - each proof builds the
# exercise against a copy of the library with one rule taken out, and the
# exercise must stop at the check about that rule.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# A native compiler and a native Python read Windows paths, not this
# shell's mapping of them; see bench/std_dns_exercise.sh.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

if [ -z "$PY" ] || ! "$PY" -c 'import ssl; from cryptography import x509' >/dev/null 2>&1; then
  echo "skipped: no python3 with ssl and cryptography here, so there is no scripted server to ask"
  exit 0
fi

status=0
export IYI_PATH="$REPO/src"
SRV="$WORK/servers"
mkdir -p "$SRV"
"$PY" "$REPO/bench/std_secure_dns_server.py" "$SRV" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 200); do
  [ -f "$SRV/ready" ] && break
  sleep 0.1
done
if [ ! -f "$SRV/ready" ]; then
  echo "the scripted servers did not start"
  cat "$WORK/server.log"
  exit 1
fi
if [ -f "$SRV/h2.missing" ]; then
  echo "== $(cat "$SRV/h2.missing"): DNS over HTTPS is asked over HTTP/1.1 alone"
fi

# build_and_run <label> <name> [build flags]: the exercise, built and run
# against the servers.
build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_secure_dns_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  timeout -k 5 180 "$WORK/$name" "$SRV" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -v '^answer ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  if grep -q "iyi: panic" "$WORK/$name.out"; then
    echo "$label: a panic the program outlived"
    status=1
    return 1
  fi
  return 0
}

SECTIONS="wire dot_answers dot_reuse dot_pipelined dot_idle dot_wrong_name dot_id_mismatch dot_truncated dot_oversized dot_recovers doh_post doh_get doh_zero_id doh_reuse doh_status doh_content_type doh_oversized doh_truncated doh_wrong_name no_plaintext_fallback plaintext_fallback connect_by_name"
if [ -f "$SRV/h2.port" ]; then
  SECTIONS="$SECTIONS doh_h2"
fi

for mode in plain release; do
  if [ "$mode" = plain ]; then
    echo "== the std/secure_dns exercise, plain build"
    build_and_run "plain" dns-plain
  else
    echo
    echo "== the same program with optimisation on (--release)"
    build_and_run "release" dns-release --release
  fi
  if ! grep -q "^all checks passed" "$WORK/dns-$mode.out" 2>/dev/null; then
    echo "  $mode: the run did not reach the end"
    status=1
  fi
  missing=""
  for section in $SECTIONS; do
    grep -q "^$section: ok" "$WORK/dns-$mode.out" 2>/dev/null || missing="$missing $section"
  done
  if [ -n "$missing" ]; then
    echo "  $mode: nothing reported for:$missing"
    status=1
  else
    echo "  $mode: all $(echo $SECTIONS | wc -w | tr -d ' ') sections reported ok"
  fi
done

echo
echo "== dig asks the same servers the same questions"
# dig's DNS over HTTPS is HTTP/2's alone: against the HTTP/1.1 server it
# answers "ALPN for HTTP/2 failed" (dig 9.20.24, measured), so the
# HTTP/1.1 answers are held to dig through the HTTP/2 server, which answers
# from the same zone by the same code.
HAS_TLS=no
HAS_HTTPS=no
if command -v dig >/dev/null 2>&1; then
  dig -h 2>&1 | grep -q '+\[no\]tls ' && HAS_TLS=yes
  dig -h 2>&1 | grep -q '+\[no\]https\[=' && HAS_HTTPS=yes
fi
if ! command -v dig >/dev/null 2>&1; then
  echo "  skipped: no dig here, so nothing but the iyi client asks the scripted servers"
elif [ "$HAS_TLS" = no ] && [ "$HAS_HTTPS" = no ]; then
  echo "  skipped: this dig has neither +tls nor +https ($(dig -v 2>&1 | head -1))"
else
  DOT_PORT="$(cat "$SRV/dot.port")"
  # dig checks the certificate when it can read the test root and has the
  # options for it. Ubuntu's AppArmor profile for dig lets it read files
  # under $HOME outside dot directories and nothing else, so a root in a
  # scratch directory answers "TLS context cannot be created" (measured,
  # dig 9.20.24), and an older dig may not know +tls-ca. Either way dig
  # then asks without checking, the sentence says why, and the name is
  # the iyi client's to check (dot_wrong_name, doh_wrong_name).
  VERIFY=(+tls-ca="$SRV/ca.pem" +tls-hostname=dns.test)
  probe=(+tls -p "$DOT_PORT")
  [ "$HAS_TLS" = no ] && probe=(+https -p "$(cat "$SRV/h2.port" 2>/dev/null || echo 1)")
  checked="$(dig "${probe[@]}" "${VERIFY[@]}" @127.0.0.1 a.zone.test A +short +tries=1 +timeout=5 2>&1)"
  if [ "$checked" != "192.0.2.1" ]; then
    echo "  dig asks without checking the certificate: with +tls-ca it said \"$(printf '%s\n' "$checked" | head -1)\""
    VERIFY=()
  else
    echo "  dig checks the certificate for dns.test against the test root"
    # The refusal the iyi client gives wrong.test, dig's too: the server's
    # certificate names dns.test and 127.0.0.1 and nothing else.
    if dig "${probe[@]}" +tls-ca="$SRV/ca.pem" +tls-hostname=wrong.test @127.0.0.1 a.zone.test A +short +tries=1 +timeout=5 2>&1 | grep -q "192.0.2.1"; then
      echo "  dig took the certificate for wrong.test, which it does not name"
      status=1
    else
      echo "  dig refuses it for wrong.test, as the iyi client does"
    fi
  fi
  asked=0
  differs=0
  over=""
  while read -r _ via type name values; do
    case "$via" in
      dot) [ "$HAS_TLS" = yes ] || continue; flags=(+tls) port="$DOT_PORT" ;;
      h2) [ "$HAS_HTTPS" = yes ] || continue; flags=(+https) port="$(cat "$SRV/h2.port")" ;;
      h2-get) [ "$HAS_HTTPS" = yes ] || continue; flags=(+https-get) port="$(cat "$SRV/h2.port")" ;;
      *) continue ;;
    esac
    case " $over " in *" ${flags[0]} "*) ;; *) over="$over ${flags[0]}" ;; esac
    got="$(dig "${flags[@]}" ${VERIFY[@]+"${VERIFY[@]}"} @127.0.0.1 -p "$port" "$name" "$type" +short +tries=1 +timeout=5 2>&1)"
    # +short: an address a line, a CNAME's target ending in a dot, a TXT
    # record's strings each quoted. The iyi line joins a record's strings
    # and separates records with " | ".
    if [ "$type" = TXT ]; then
      said="$(printf '%s\n' "$got" | "$PY" -c 'import sys, shlex; print(" | ".join("".join(shlex.split(line)) for line in sys.stdin.read().splitlines() if line))')"
    else
      said="$(printf '%s\n' "$got" | grep -v '\.$' | tr '\n' ' ' | sed 's/ *$//')"
    fi
    asked=$((asked + 1))
    if [ "$said" != "$values" ]; then
      echo "  $via $type $name: iyi read \"$values\", dig \"$said\""
      differs=1
    fi
  done < <(grep '^answer ' "$WORK/dns-plain.out" 2>/dev/null)
  if [ "$asked" -eq 0 ] && { [ "$HAS_TLS" = yes ] || [ -f "$SRV/h2.port" ]; }; then
    echo "  nothing to ask: the exercise printed no answers dig can be asked for"
    status=1
  elif [ "$asked" -eq 0 ]; then
    :
  elif [ "$differs" -ne 0 ]; then
    status=1
  else
    echo "  dig and the iyi resolver agree on $asked answers, over$over"
  fi
  [ "$HAS_TLS" = yes ] || echo "  +tls skipped: this dig has no DNS over TLS ($(dig -v 2>&1 | head -1))"
  if [ "$HAS_HTTPS" = no ]; then
    echo "  +https skipped: this dig has no DNS over HTTPS ($(dig -v 2>&1 | head -1))"
  elif [ ! -f "$SRV/h2.port" ]; then
    echo "  +https skipped: there is no HTTP/2 server without the h2 package, and dig speaks DNS over HTTPS over HTTP/2 alone"
  fi
fi

echo
echo "== the checks fail when the module is broken"
# breaks <label> <dir> <phrase> <file> <old> <new> [<file> <old> <new>]:
# the exercise built against a copy of src/std with *old* in std/<file>
# replaced by *new* must fail, and say *phrase*.
breaks() {
  local label="$1" dir="$2" phrase="$3"
  mkdir -p "$WORK/$dir/std"
  FILE1="$4" OLD1="$5" NEW1="$6" FILE2="${7:-}" OLD2="${8:-}" NEW2="${9:-}" "$PY" - <<PY
import os
from pathlib import Path
for n in ("1", "2"):
    name = os.environ["FILE" + n]
    if not name:
        continue
    target = Path("$WORK/$dir/std") / name
    src = (target if target.exists() else Path("$REPO/src/std") / name).read_text()
    old, new = os.environ["OLD" + n], os.environ["NEW" + n]
    if old not in src:
        raise SystemExit("patch site missing in " + name)
    with open(target, "w", newline="\n") as handle:
        handle.write(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" \
       "$REPO/bench/std_secure_dns_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the broken copy did not build"
    sed -n '1,8p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  timeout -k 5 120 "$WORK/$dir/program" "$SRV" >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '$p' "$WORK/$dir/out"
    status=1
  else
    echo "  $label: caught at \"$(grep -m1 -F -- "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //' | cut -c1-110)\""
  fi
}

breaks "the server's name not verified" noname "a server whose certificate does not name wrong.test" secure_dns.iyi \
  'tls = TlsClient.over(socket, @name, @config, timeout_ms, @session)' \
  'tls = TlsClient.over(socket, @address, @config, timeout_ms, @session)'
breaks "the length prefix dropped" noprefix "the encrypted resolver asks over TLS" secure_dns.iyi \
  '      framed << (query.size >> 8).to_u8
      framed << (query.size & 255).to_u8
' ''
breaks "the dns parameter sent with its padding" padded "the dns parameter is base64url without padding" secure_dns.iyi \
  '    while size > 0 && text.to_unsafe[size - 1] == 61_u8
      size = size - 1
    end
' ''
# Not the slot matching: the server answers a pipelined pair last first,
# so a client that took answers in arrival order is caught at the first
# lookup of both families. This takes out the refusal alone.
breaks "an answer's ID not checked over TLS" noid "an answer with an ID no query has is refused over TLS" secure_dns.iyi \
  '        return DnsError.new(DnsError::MALFORMED, "", label, "an answer with the ID #{id}, which no query waiting on the connection has")' \
  '        slot = 0'
breaks "the plaintext servers asked unasked" silentplain "a dead upstream, no fallback asked for" socket.iyi \
  'if @plaintext_fallback && !@servers.empty?' \
  'if !@servers.empty?'
# A TC answer's records are not read (std/dns), so taken over a stream it
# reads as a name without the address: refused, but not as truncated.
breaks "TC taken over a stream" tcstream "TC over a stream is refused" socket.iyi \
  'return DnsMessage.malformed("the answer is truncated (TC), which an answer over a stream never is").about(name, label) if message.truncated?' ''
breaks "bytes past the message taken" pastend "a frame longer than its message" socket.iyi \
  'return DnsMessage.malformed("oversized: #{bytes.size - ends} bytes past the end of the message").about(name, label) if ends < bytes.size' ''
breaks "a connection per exchange" noreuse "every query over one TLS connection" secure_dns.iyi \
  '    if kept = live
      got = over(kept, queries, timeout_ms, true)
    end
' '    close
'
breaks "an idle connection kept past its timeout" noidle "a connection idle past its timeout is closed" secure_dns.iyi \
  'if Resolver.now_ms - @used_ms > @idle_ms.to_i64' \
  'if false'
breaks "a DoH status not read" nostatus "a 500" secure_dns.iyi \
  'return DnsError.new(DnsError::REFUSED, "", label, "HTTP #{response.status} #{response.reason}") unless response.status == 200' ''
breaks "a DoH Content-Type not read" notype "an answer as text/plain" secure_dns.iyi \
  'return DnsError.new(DnsError::MALFORMED, "", label, "an answer of #{said.inspect}, not #{MEDIA}") unless media == MEDIA' ''
breaks "a DoH query with a random ID" doh_id "a POST's query has the ID 0" secure_dns.iyi \
  '  def zero_id? : Bool
    true' '  def zero_id? : Bool
    false'
breaks "an HTTPClient's own TLS configuration ignored" clienttls "over HTTPS from a server without h2" http.iyi \
  'under = keeping.tls || under' ''
breaks "an HTTPClient's own resolver ignored" clientresolver "a URL's host pinned to an address" http.iyi \
  'through = keeping.resolver' ''

echo
if [ "$status" -eq 0 ]; then
  echo "the std/secure_dns exercise holds"
else
  echo "the std/secure_dns exercise did not hold"
fi
exit $status
