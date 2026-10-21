#!/usr/bin/env bash
# Exercises `std/dns` and the resolver `std/socket` builds on it.
#
#     bash bench/std_dns_exercise.sh
#
# Runs bench/std_dns_exercise.iyi plain and --release - a name server in
# the program itself, on 127.0.0.1, so nothing leaves the machine - checks
# every section reported, and proves the checks can fail: each proof
# builds the exercise against a copy of the library with one rule of the
# resolver, or of the race `connect` runs over a name's addresses (Happy
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
SECTIONS="query_bytes compression codec a_record aaaa_record cname_chain cname_dangling cname_loop nxdomain servfail nodata mismatched_id forged_source truncated_tcp pointer_loop retry timeout hosts_override search_list literals from_files connect_by_name connect_fallback unresolved_connect he_order he_refused he_blackhole he_family he_fds he_deadline he_cancel"

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
    'return DnsError.new(DnsError::NOT_FOUND, name, server.label)' \
    'return DnsError.new(DnsError::SERVER_FAILURE, name, server.label)'
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
