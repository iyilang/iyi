#!/usr/bin/env bash
# Exercises `std/dns` and the resolver `std/socket` builds on it.
#
#     bash bench/std_dns_exercise.sh
#
# Runs bench/std_dns_exercise.iyi plain and --release - a name server in
# the program itself, on 127.0.0.1, so nothing leaves the machine - checks
# every section reported, holds the HTTPS records it reads (RFC 9460) to
# BIND's reading of the same - nsupdate's of their presentation format,
# dig's printing of their bytes - where dig and nsupdate are installed,
# and proves the checks can fail: each proof builds the exercise against
# a copy of the library with one rule of the resolver, of the records'
# format, or of the race `connect` runs over a name's addresses (Happy
# Eyeballs, RFC 8305), taken out, and the exercise must stop at the
# section that rule holds.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The exercise writes its resolv.conf and hosts file under TMPDIR, so they
# land where the trap above removes them.
export TMPDIR="$WORK"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) export TEMP="$(cygpath -w "$WORK")" ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_dns_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  timeout -k 5 120 "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  # A task that panics after its group has joined prints and is not
  # propagated: the exit status alone does not see it.
  if grep -q "iyi: panic" "$WORK/$name.out"; then
    echo "$label: a panic the program outlived"
    status=1
    return 1
  fi
  return 0
}

# A section that needs what this machine lacks - IPv6, a listener whose
# backlog fills - reports itself skipped, with the reason.
SECTIONS="query_bytes compression codec edns svcb_wire svcb_malformed a_record aaaa_record cname_chain cname_dangling cname_loop nxdomain servfail nodata mismatched_id forged_source truncated_tcp pointer_loop retry timeout hosts_override search_list literals from_files connect_by_name connect_fallback unresolved_connect https_records https_alias https_alias_bound he_order he_refused he_blackhole he_family he_fds he_deadline he_cancel"

for mode in plain release; do
  if [ "$mode" = plain ]; then
    echo "== the std/dns exercise, plain build"
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
    grep -Eq "^$section: (ok|skipped)" "$WORK/dns-$mode.out" 2>/dev/null || missing="$missing $section"
  done
  if [ -n "$missing" ]; then
    echo "  $mode: nothing reported for:$missing"
    status=1
  else
    echo "  $mode: all $(echo $SECTIONS | wc -w | tr -d ' ') sections reported"
    grep -E "^he_[a-z]+: skipped" "$WORK/dns-$mode.out" 2>/dev/null | sed 's/^/  /'
  fi
done

echo
echo "== BIND reads the same HTTPS records: nsupdate parses them, dig prints them"
# The zone below is RFC 9460 appendix D's records as the RFC writes them
# in presentation format - an SVCB example there is an HTTPS record here,
# whose data is the same - and four of this gate's: all seven keys, and
# the bytes alpn and a generic key escape. After each, the bytes the RFC
# gives for it (this gate's worked out by hand from appendix A and
# section 7). nsupdate, BIND's own reader of presentation format, sends
# each record in an UPDATE to the exercise run as `zone DIR`; the bytes
# it sent must be those; dig asks for each record back and prints it, and
# `SvcbRecord#to_s` must print the same. Appendix D.3's failure cases go
# to nsupdate too, which must refuse each, as the exercise refuses their
# bytes (svcb_malformed).
ZONE_RECORDS=$(cat <<'ZONE'
d1.test. 0 foo.example.com.|0000 03666f6f076578616d706c6503636f6d00
d2.test. 1 .|0001 00
d3.test. 16 foo.example.com. port=53|0010 03666f6f076578616d706c6503636f6d00 0003 0002 0035
d4.test. 1 foo.example.com. key667=hello|0001 03666f6f076578616d706c6503636f6d00 029b 0005 68656c6c6f
d5.test. 1 foo.example.com. key667="hello\210qoo"|0001 03666f6f076578616d706c6503636f6d00 029b 0009 68656c6c6fd2716f6f
d6.test. 1 foo.example.com. ipv6hint="2001:db8::1,2001:db8::53:1"|0001 03666f6f076578616d706c6503636f6d00 0006 0020 20010db8000000000000000000000001 20010db8000000000000000000530001
d7.test. 1 example.com. ipv6hint="2001:db8:122:344::192.0.2.33"|0001 076578616d706c6503636f6d00 0006 0010 20010db80122034400000000c0000221
d8.test. 16 foo.example.org. alpn=h2,h3-19 mandatory=ipv4hint,alpn ipv4hint=192.0.2.1|0010 03666f6f076578616d706c65036f726700 0000 0004 0001 0004 0001 0009 02 6832 05 68332d3139 0004 0004 c0000201
d9.test. 16 foo.example.org. alpn="f\\\\oo\\,bar,h2"|0010 03666f6f076578616d706c65036f726700 0001 000c 08 665c6f6f2c626172 02 6832
d10.test. 16 foo.example.org. alpn=f\\\092oo\092,bar,h2|0010 03666f6f076578616d706c65036f726700 0001 000c 08 665c6f6f2c626172 02 6832
all.test. 1 . mandatory=port alpn=h2,http/1.1 no-default-alpn port=443 ipv4hint=192.0.2.1 ech=AEj+DQBEAQAgACAdd+scUi0IYFsXnUIU7ko2Nd9+F8M26pAGZVpz/KrWPgAEAAEAAWQVZWNoLXNpdGVzLmV4YW1wbGUubmV0AAA= ipv6hint=2001:db8::1|0001 00 0000 0002 0003 0001 000c 02 6832 08 687474702f312e31 0002 0000 0003 0002 01bb 0004 0004 c0000201 0005 004a 0048fe0d004401002000201d77eb1c522d08605b179d4214ee4a3635df7e17c336ea9006655a73fcaad63e00040001000164156563682d73697465732e6578616d706c652e6e65740000 0006 0010 20010db8000000000000000000000001
alpn.test. 1 . alpn="a\032b,c\\,d,e\\\\f,\"g"|0001 00 0001 000f 03 612062 03 632c64 03 655c66 02 2267
generic.test. 1 . key9 key65280="a\"b\\c;d e\000\127"|0001 00 0009 0000 ff00 000b 6122625c633b642065007f
case.test. 2 Hello.Example. port=0 ipv6hint=::1,::,::1.2.3.4,::ffff:0.0.0.1,1:0:0:1:0:0:1:1|0002 0548656c6c6f074578616d706c6500 0003 0002 0000 0006 0050 00000000000000000000000000000001 00000000000000000000000000000000 00000000000000000000000001020304 00000000000000000000ffff00000001 00010000000000010000000000010001
ZONE
)
ZONE_REFUSED=$(cat <<'ZONE'
key123=abc key123=def
mandatory
alpn
port
ipv4hint
ipv6hint
no-default-alpn=abc
mandatory=key123
mandatory=mandatory
mandatory=key123,key123 key123=abc
ZONE
)
if ! command -v dig >/dev/null 2>&1 || ! command -v nsupdate >/dev/null 2>&1; then
  echo "  skipped: no dig and nsupdate here (BIND's dnsutils), so nothing but this module reads the records"
elif [ ! -x "$WORK/dns-plain" ]; then
  echo "  the exercise did not build, so there is no name server to ask"
  status=1
else
  ZONE_DIR="$WORK/zone"
  mkdir -p "$ZONE_DIR"
  timeout -k 5 60 "$WORK/dns-plain" zone "$ZONE_DIR" >"$WORK/zone.out" 2>&1 &
  zone_pid=$!
  for _ in $(seq 100); do
    [ -s "$ZONE_DIR/port" ] && break
    sleep 0.1
  done
  zone_port="$(cat "$ZONE_DIR/port" 2>/dev/null)"
  # An UPDATE a record: the exercise answers over UDP alone, and nsupdate
  # sends one past 512 bytes over TCP.
  {
    echo "server 127.0.0.1 $zone_port"
    echo "zone test."
    printf '%s\n' "$ZONE_RECORDS" | while IFS='|' read -r record _; do
      owner="${record%% *}"
      echo "update add $owner 60 IN HTTPS ${record#* }"
      echo "send"
    done
  } >"$WORK/zone.nsupdate"
  # A BIND that predates the HTTPS type does not know it: darwin's nsupdate refused
  # the zone with "'HTTPS' is not a valid type: unknown class/type" (CI,
  # measured), and an old dig says ";; Warning, ignoring invalid type
  # HTTPS" to `-t HTTPS` - both BIND's sentences for a type it does not
  # know, measured here with an unknown type's name. One record goes to
  # each first, and only those sentences skip; any other refusal of the
  # probe, or a probe read back otherwise than "1 .", is a failure.
  bind_versions="$(nsupdate -V 2>&1 | head -1); $(dig -v 2>&1 | head -1)"
  probe_said=""
  probe_dig=""
  probe_status=0
  if [ -n "$zone_port" ]; then
    printf 'server 127.0.0.1 %s\nzone test.\nupdate add probe.test. 60 IN HTTPS 1 .\nsend\n' "$zone_port" >"$WORK/zone.probe"
    probe_said="$(timeout 20 nsupdate "$WORK/zone.probe" 2>&1)"
    probe_status=$?
    probe_dig="$(dig -t HTTPS +noall +answer +tries=1 +timeout=5 @127.0.0.1 -p "$zone_port" probe.test 2>&1)"
  fi
  if [ -z "$zone_port" ]; then
    echo "  the exercise's name server did not start: $(head -3 "$WORK/zone.out")"
    status=1
  elif printf '%s' "$probe_said" | grep -qF "'HTTPS' is not a valid type"; then
    echo "  skipped: this nsupdate does not know the HTTPS type ($bind_versions): it said \"$(printf '%s' "$probe_said" | head -1)\""
  elif [ "$probe_status" -ne 0 ]; then
    echo "  nsupdate knows the HTTPS type and refused a one-record update: $(printf '%s' "$probe_said" | head -2 | tr '\n' ' ')"
    status=1
  elif printf '%s' "$probe_dig" | grep -qF 'ignoring invalid type HTTPS'; then
    echo "  skipped: this dig does not know the HTTPS type ($bind_versions): it said \"$(printf '%s' "$probe_dig" | head -1)\""
  elif [ "$(printf '%s' "$probe_dig" | sed -E 's/^[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+HTTPS[[:space:]]+//')" != "1 ." ]; then
    echo "  dig read the probe record back as \"$probe_dig\", not \"1 .\""
    status=1
  elif ! timeout 20 nsupdate "$WORK/zone.nsupdate" >"$WORK/zone.nsupdate.out" 2>&1; then
    echo "  nsupdate did not send the zone: $(head -3 "$WORK/zone.nsupdate.out")"
    status=1
  else
    agreed=0
    while IFS='|' read -r record wire; do
      owner="${record%% *}"
      name="${owner%.}"
      want="$(printf '%s' "$wire" | tr -d ' ')"
      seen="$(grep "^$name	" "$ZONE_DIR/seen" 2>/dev/null)"
      sent="$(printf '%s' "$seen" | cut -f2)"
      read_here="$(printf '%s' "$seen" | cut -f3)"
      said="$(dig +noall +answer +tries=1 +timeout=5 @127.0.0.1 -p "$zone_port" "$name" HTTPS 2>&1 |
        sed -E 's/^[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]+IN[[:space:]]+HTTPS[[:space:]]+//')"
      if [ "$sent" != "$want" ]; then
        echo "  $owner: nsupdate sent $sent, where the bytes are $want"
        status=1
      elif [ "$read_here" != "$said" ]; then
        echo "  $owner: SvcbRecord printed \"$read_here\", dig \"$said\""
        status=1
      else
        agreed=$((agreed + 1))
      fi
    done < <(printf '%s\n' "$ZONE_RECORDS")
    echo "  $agreed of $(printf '%s\n' "$ZONE_RECORDS" | wc -l | tr -d ' ') records: the bytes nsupdate sent are the RFC's, and SvcbRecord prints each as dig does"
    refused=0
    while read -r params; do
      printf 'server 127.0.0.1 %s\nzone test.\nupdate add refused.test. 60 IN HTTPS 1 foo.example.com. %s\nsend\n' "$zone_port" "$params" >"$WORK/zone.refused"
      if timeout 20 nsupdate "$WORK/zone.refused" >/dev/null 2>&1 || grep -q '^refused.test	' "$ZONE_DIR/seen"; then
        echo "  nsupdate took appendix D.3's \"$params\", which it should refuse"
        status=1
      else
        refused=$((refused + 1))
      fi
    done < <(printf '%s\n' "$ZONE_REFUSED")
    echo "  nsupdate refuses $refused of appendix D.3's $(printf '%s\n' "$ZONE_REFUSED" | wc -l | tr -d ' ') failure cases, whose bytes the exercise refuses"
  fi
  dig +tries=1 +timeout=2 @127.0.0.1 -p "${zone_port:-1}" stop.test HTTPS >/dev/null 2>&1
  wait "$zone_pid" 2>/dev/null
fi

echo
echo "== the checks fail when the resolver is broken"
# breaks <label> <dir> <phrase> <file> <old> <new> [<file> <old> <new>]:
# the exercise built against a copy of src/std with *old* in std/<file>
# replaced by *new* - in each file given - must fail, and say *phrase* -
# or, when *phrase* is `HANG`, be killed at the bound, which is what a
# loop the rule kept out does.
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
    target.write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" \
       "$REPO/bench/std_dns_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the broken copy did not build"
    sed -n '1,8p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  local bound=60
  [ "$phrase" = HANG ] && bound=15
  timeout -k 5 "$bound" "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif [ "$phrase" = HANG ]; then
    if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
      echo "  $label: never finished, killed at the ${bound} s bound (exit $code)"
    else
      echo "  $label: exited $code instead of hanging"
      sed -n '$p' "$WORK/$dir/out"
      status=1
    fi
  elif ! grep -qF -- "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '$p' "$WORK/$dir/out"
    status=1
  else
    echo "  $label: caught at \"$(grep -m1 -F -- "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //' | cut -c1-110)\""
  fi
}

if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copies could not be made"
  status=1
else
  breaks "an answer read without its question" noquestion "a wrong ID and a wrong question are ignored" dns.iyi \
    'DnsName.same?(@question_name, name) && @question_type == type' \
    '@question_type == type'
  breaks "a truncated answer taken as it came" notcp "a truncated answer is asked again over TCP" socket.iyi \
    'return ask_tcp(server, query, id, name, type) if answer.is_a?(DnsMessage) && answer.truncated?' \
    ''
  # The ID is checked twice - before the bytes are parsed, and again by
  # `answers?` - so the proof takes out both.
  breaks "an answer read without its ID" noid "a wrong ID and a wrong question are ignored" dns.iyi \
    'return false unless response? && opcode == 0 && @id == id' \
    'return false unless response? && opcode == 0' \
    socket.iyi \
    'next unless DnsMessage.id_of(packet) == id.to_i32' \
    ''
  breaks "NXDOMAIN read as a server's failure" nxservfail "NXDOMAIN is not_found?" socket.iyi \
    'DnsError.new(DnsError::NOT_FOUND, name, label)' \
    'DnsError.new(DnsError::SERVER_FAILURE, name, label)'
  breaks "an OPT record's extended RCODE ignored" nobadvers "BADVERS (16), not NOERROR" dns.iyi \
    '(@extended_rcode << 4) | (@flags & 15)' \
    '@flags & 15'
  breaks "a CNAME not followed" nocname "a CNAME chain in one answer" dns.iyi \
    'next_name = record.target if record.type == DnsRecord::CNAME && next_name.empty?' \
    'next_name = "" if record.type == DnsRecord::CNAME'
  breaks "one attempt where two were asked for" noretry "the second attempt is answered" socket.iyi \
    'while attempt < @attempts' \
    'while attempt < 1'
  breaks "the hosts file skipped" nohosts "the hosts file answers" socket.iyi \
    'return listed unless listed.empty?' \
    'listed.clear'
  breaks "the search list tried after the name" searchorder "a short name tries the search list first" dns.iyi \
    'answer << name if dots >= ndots' \
    'answer << name if dots < ndots'
  breaks "a compression pointer allowed forward" pointerfloor HANG dns.iyi \
    'return nil unless pointer < floor' \
    'return nil unless pointer < size'
  breaks "a CNAME chain without a bound" cnamebound HANG dns.iyi \
    'return DnsMessage.malformed("a chain of more than #{budget} CNAMEs, or a loop of them") if links > budget' \
    ''
  breaks "a name read as an address, as it was" noname 'cannot resolve address: "web.test"' socket.iyi \
    '!localhost?(host) && DnsName.valid?(host)' \
    'false'
  # Service bindings: section 2.2's order and the mandatory keys
  # (`SvcbRecord.parse`), and SVCB resolution's bound, order and name
  # (`Resolver#https_records`). The chain the bound ends never ends, so
  # without it the lookup asks until it is killed.
  breaks "SvcParamKeys taken out of order" svcborder "keys out of order are refused" dns.iyi \
    'return DnsMessage.malformed("SvcParamKey #{key_name(key)} after #{key_name(last)}: the keys are not in increasing order") if key < last' \
    ''
  breaks "a SvcParamKey taken twice" svcbtwice "a key twice is refused" dns.iyi \
    'return DnsMessage.malformed("SvcParamKey #{key_name(key)} twice") if key == last' \
    ''
  breaks "mandatory keys not held to the record" svcbmandatory "a mandatory key the record does not carry is refused" dns.iyi \
    'return DnsMessage.malformed("mandatory lists #{key_name(listed)}, which the record does not carry") unless keys.includes?(listed)' \
    ''
  breaks "an AliasMode chain without a bound" aliasbound HANG socket.iyi \
    'if aliases > SvcbAnswer::MAX_ALIASES' \
    'if false'
  breaks "ServiceMode records in the order they came" svcbpriority "ServiceMode records by priority" socket.iyi \
    'Resolver.by_priority(parsed)' \
    'parsed'
  breaks "another port asked at the host's own name" svcbport "another port asks _port._https.host" socket.iyi \
    'asked = port == 443 ? relative : "_#{port}._https.#{relative}"' \
    'asked = relative'

  # The race. Each copy needs what its section had in the plain run - a
  # full listener to race past, the descriptors counted (Linux), IPv6 to
  # put first - and says it was skipped where the section was.
  ran="$WORK/dns-plain.out"
  if grep -q "^he_blackhole: ok" "$ran"; then
    breaks "one address after another, the attempt delay an hour" heserial "the second address does not wait for the first to fail" socket.iyi \
      'ATTEMPT_DELAY_MS = 250' \
      'ATTEMPT_DELAY_MS = 3600000'
    breaks "every address at once, the attempt delay ignored" heatonce "the second address waits the attempt delay" socket.iyi \
      'ATTEMPT_DELAY_MS = 250' \
      'ATTEMPT_DELAY_MS = 0'
  else
    echo "  the attempt delay's two copies: skipped, he_blackhole did not run on this machine"
  fi
  if grep -q "^he_fds: ok (.*descriptors before and after" "$ran"; then
    breaks "a losing attempt's socket left open" heleak "every losing attempt's socket is closed" socket.iyi \
      $'if waited.is_a?(Cancelled)\n        __sys_close(fd)\n' \
      $'if waited.is_a?(Cancelled)\n'
  else
    echo "  a losing attempt's socket left open: skipped, descriptors are counted on Linux alone"
  fi
  if grep -q "^he_refused: ok" "$ran"; then
    breaks "the error naming the last address alone" helast "one error naming every address, in the order tried" socket.iyi \
      'parts.join("; ")) if ran_out < 0' \
      'parts.last) if ran_out < 0'
  else
    echo "  the error naming the last address alone: skipped, he_refused did not run on this machine"
  fi
  if grep -q "^he_order: ok (IPv6 first" "$ran"; then
    breaks "IPv4 first whatever the routes say" hefour "IPv6 first when this machine has a route to it" socket.iyi \
      'if routed?(six[0].as(IPv6Address))' \
      'if false'
  else
    echo "  IPv4 first whatever the routes say: skipped, this machine has no route to ::1"
  fi
  # Windows refuses a connect after 2 s, so there the attempt delay starts
  # the next address first and `connect_fallback` does not time it.
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT) windows=1 ;;
    *) windows=0 ;;
  esac
  if [ "$windows" -eq 0 ] && grep -q "^he_order: ok (IPv6 first" "$ran"; then
    breaks "a failure that waits for the attempt delay" hewait "a refused first address starts the next at once" socket.iyi \
      $'# A failure starts the next attempt now, not when it was due.\n          next_at = 0_i64\n' \
      ''
  else
    echo "  a failure that waits for the attempt delay: skipped, it needs IPv6 to refuse first and a refusal that is not Windows' 2 s"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/dns exercise holds"
else
  echo "the std/dns exercise did not hold"
fi
exit $status
