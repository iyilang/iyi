#!/usr/bin/env bash
# Exercises `std/udp`.
#
#     bash bench/std_udp_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken address
# resolution is caught, and what address parsing refuses: an invalid IPv4
# host, an out of range octet, an incomplete IPv4 address, and an invalid
# hex character in an IPv6 address.
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
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_udp_exercise.iyi" \
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

echo "== the std/udp exercise, plain build"
build_and_run "plain" udp-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/udp-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every udp section reported"
for phrase in "== address parsing" "== bind to port 0 and loopback exchange" "== connected sockets" "== maximum datagram size" "== nothing queued: the ? variants answer nil, and a bounded wait ends" "== socket lifecycle and close"; do
  if ! grep -q "$phrase" "$WORK/udp-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" udp-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/udp-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
# The parser is std/socket's now, so the module broken is that one.
src = Path("$REPO/src/std/socket.iyi").read_text()
old = 'return IPv4Address.new(127_u8, 0_u8, 0_u8, 1_u8) if host == "localhost"'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/socket.iyi").write_text(src.replace(old, 'return IPv4Address.new(127_u8, 0_u8, 0_u8, 2_u8) if host == "localhost"', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_udp_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken udp is caught"
  fi
fi

echo
echo "== what address parsing refuses"
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/udp\nimport std/socket\nusing std/udp::{UdpSocket}\nusing std/socket::{IyiSocket}\n\nputs (%s).to_s\n' \
    "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

refuses "an invalid host string" bad_host "cannot resolve address: \"invalid.ip\"" \
  'IyiSocket.parse_ip("invalid.ip")'
refuses "an out-of-range octet" octet_range "cannot resolve address: \"999.1.1.1\"" \
  'IyiSocket.parse_ip("999.1.1.1")'
refuses "an incomplete IPv4 address" incomplete_ip "cannot resolve address: \"1.2.3\"" \
  'IyiSocket.parse_ip("1.2.3")'
refuses "an invalid hex character in IPv6" bad_hex "cannot resolve address: \"2001:xyz::1\": 'x' is not a hex digit" \
  'IyiSocket.parse_ipv6("2001:xyz::1")'
refuses "a leading-zero octet" leading_zero "an octet with a leading zero is not decimal" \
  'IyiSocket.parse_ip("010.1.1.1")'
refuses "an overflowing octet" overflow_octet "cannot resolve address: \"2147483648.1.1.1\"" \
  'IyiSocket.parse_ip("2147483648.1.1.1")'
refuses "a second IPv6 compression" two_compressions "cannot resolve address: \"1::2::3\": a second \`::\`" \
  'IyiSocket.parse_ipv6("1::2::3")'
refuses "a five-digit IPv6 group" long_group "a group of more than four hex digits" \
  'IyiSocket.parse_ipv6("00000::1")'
refuses "a leading single colon" lead_colon "a single leading colon" \
  'IyiSocket.parse_ipv6(":1:2:3:4:5:6:7")'

refuses_body() { # refuses_body <label> <name> <phrase>
  local label="$1" name="$2" phrase="$3"
  cat > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,8p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

refuses_body "a negative port" neg_port "port -1 is not a port: 0 to 65535" <<'IYI'
module main
import std/udp
using std/udp::{UdpSocket}
s = UdpSocket.bind("127.0.0.1", -1)
puts s.local_port
IYI

refuses_body "a port above 65535" high_port "port 70000 is not a port: 0 to 65535" <<'IYI'
module main
import std/udp
using std/udp::{UdpSocket}
s = UdpSocket.bind("127.0.0.1", 70000)
puts s.local_port
IYI

refuses_body "a Datagram index that is not 0, 1, or 2" dg_index "Datagram index -1 is not 0, 1, or 2" <<'IYI'
module main
import std/udp
using std/udp::{Datagram, Bytes}
buf = Bytes.new(1)
buf[0] = 120_u8
dg = Datagram.new(buf, "h", 7)
puts dg[-1]
IYI

refuses_body "a negative receive count" neg_recv "negative count: -1" <<'IYI'
module main
import std/udp
using std/udp::{UdpSocket}
s = UdpSocket.bind("127.0.0.1", 0)
s.receive_from(-1)
IYI

refuses_body "local_port after close" closed_port "socket is closed" <<'IYI'
module main
import std/udp
using std/udp::{UdpSocket}
s = UdpSocket.bind("127.0.0.1", 0)
s.close
puts s.local_port
IYI

refuses_body "a negative poll timeout" neg_poll "negative timeout: -1" <<'IYI'
module main
import std/udp
using std/udp::{UdpSocket}
s = UdpSocket.bind("127.0.0.1", 0)
puts s.poll_read(-1)
IYI

echo
echo "== a receive parks rather than blocking the thread (SPEC.md III.4.2)"
# Two tasks on one thread: one parked in `receive_datagram` on a socket
# nobody has written to, the other sleeps and then sends. A receive that
# blocked the worker would never let the sender run, and the program would
# hang; it is given ten seconds. Then the same shape with a `close` instead
# of a send: the parked receive answers `Cancelled`.
cat > "$WORK/park.iyi" <<'IYI'
module park

import std/udp
using std/udp::{UdpSocket, Datagram}

server = UdpSocket.bind("127.0.0.1", 0)
port = server.local_port
client = UdpSocket.client

answered = ""
group do |g|
  g.spawn do
    case dg = server.receive_datagram
    in Cancelled
      answered = "cancelled"
    in Datagram
      answered = dg.text
    end
    nil
  end
  g.spawn do
    sleep(50)
    client.send_to("after a wait", "127.0.0.1", port)
    nil
  end
end
puts "parked receive answered: #{answered}"

other = UdpSocket.bind("127.0.0.1", 0)
closed_answer = ""
group do |g|
  g.spawn do
    case other.receive_datagram
    in Cancelled
      closed_answer = "cancelled"
    in Datagram
      closed_answer = "datagram"
    end
    nil
  end
  g.spawn do
    sleep(50)
    other.close
    nil
  end
end
puts "closed under a parked receive: #{closed_answer}"

# A group cancelled by a sibling's error releases the parked receive too,
# and the ? variant asked beside a parked sibling answers nil at once.
struct Boom
end

impl Error for Boom
  def message : String
    "boom"
  end
end

third = UdpSocket.bind("127.0.0.1", 0)
third_port = third.local_port
cancel_answer = ""
probe_answer = ""
group do |g|
  g.spawn do
    r = third.receive_datagram
    cancel_answer = r.is_a?(Cancelled) ? "cancelled" : "datagram"
    0
  end
  g.spawn do
    sleep(10)
    probe_answer = third.receive_datagram?.nil? ? "nil" : "datagram"
    Boom.new
  end
end
puts "sibling error under a parked receive: #{cancel_answer}, probe beside it: #{probe_answer}"
IYI
if ! "$IYI" build -o "$WORK/park" "$WORK/park.iyi" > "$WORK/park.build" 2>&1; then
  echo "  the parking program did not build:"
  sed -n '1,8p' "$WORK/park.build"
  status=1
elif timeout 10 "$WORK/park" > "$WORK/park.out" 2>&1; then
  if grep -q "parked receive answered: after a wait" "$WORK/park.out" &&
     grep -q "closed under a parked receive: cancelled" "$WORK/park.out" &&
     grep -q "sibling error under a parked receive: cancelled, probe beside it: nil" "$WORK/park.out"; then
    echo "  the sibling ran under a parked receive, and close woke it with Cancelled"
  else
    echo "  the parking program answered otherwise:"
    sed 's/^/    /' "$WORK/park.out"
    status=1
  fi
else
  echo "  the parking program hung or died: the receive blocked the thread"
  sed 's/^/    /' "$WORK/park.out" | head -5
  status=1
fi

# And the proof that this arm tests parking: a copy whose first receive is
# a blocking `recvfrom` (no MSG_DONTWAIT) pins the one thread, the sender
# never runs, and the program is killed at the bound. On Windows the flag
# is not where blocking lives: Winsock has no MSG_DONTWAIT, the module's
# win32 arm defines it as 0 and makes the socket itself non-blocking with
# FIONBIO, so the flag edit left that copy exactly the program it copied -
# measured: its sender ran and it exited inside the bound. There the copy
# leaves the socket blocking instead, which is what makes its first
# `recvfrom` block.
#
# The copy is killed on every run, and Git Bash loses a SIGTERM that lands
# while it is still starting a native program: measured, a TERM sent 50 ms
# into a fresh build's start left it pinned until something else ended
# it, and one first start under load took nine seconds, so the gate hung
# past its bound. A SIGKILL is not lost, and it takes the program with it,
# so it follows the TERM; elsewhere the TERM ends the copy and the KILL
# never goes.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) BLOCKING_SITE=win32 ;;
  *) BLOCKING_SITE=posix ;;
esac
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/blocking/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/udp.iyi").read_text()
if "$BLOCKING_SITE" == "win32":
    old = "on = 1\n      LibWs2_32.ioctlsocket(s, FIONBIO, pointerof(on))"
    new = "on = 0\n      LibWs2_32.ioctlsocket(s, FIONBIO, pointerof(on))"
else:
    old = "count = UdpSocket.__sys_recvfrom(@fd, buffer, capacity.to_u64, MSG_DONTWAIT, addr, pointerof(len))"
    new = "count = UdpSocket.__sys_recvfrom(@fd, buffer, capacity.to_u64, 0, addr, pointerof(len))"
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/blocking/std/udp.iyi").write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the blocking patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/blocking${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/park_blocking" "$WORK/park.iyi" > "$WORK/park_blocking.build" 2>&1; then
    echo "  the blocking copy did not build:"
    sed -n '1,8p' "$WORK/park_blocking.build"
    status=1
  elif timeout -k 5 5 "$WORK/park_blocking" > "$WORK/park_blocking.out" 2>&1; then
    echo "  a blocking receive still let the sibling run, so this arm does not test parking"
    status=1
  else
    echo "  a blocking receive pins the thread and is killed at the bound, so the arm has teeth"
  fi
fi

echo
echo "== proving a Datagram index check can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_dg/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/udp.iyi").read_text()
old = '''    elsif i == 2
      @port
    else
      raise "Datagram index #{i} is not 0, 1, or 2"'''
if old not in src:
    raise SystemExit("datagram patch site missing")
new = '''    else
      @port'''
Path("$WORK/patched_dg/std/udp.iyi").write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the datagram patch did not apply"
    status=1
  else
    cat > "$WORK/dg_idx.iyi" <<'IYI'
module main
import std/udp
using std/udp::{Datagram, Bytes}
buf = Bytes.new(1)
buf[0] = 120_u8
dg = Datagram.new(buf, "h", 7)
puts dg[-1]
IYI
    if IYI_PATH="$WORK/patched_dg${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$WORK/dg_idx.iyi" >"$WORK/dg_mut.out" 2>&1; then
      echo "  a broken Datagram index is caught"
    else
      echo "  the index program refused on a broken module (cannot prove the check)"
      sed -n '1,3p' "$WORK/dg_mut.out"
      status=1
    fi
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/udp exercise holds"
else
  echo "the std/udp exercise did not hold"
fi
exit $status
