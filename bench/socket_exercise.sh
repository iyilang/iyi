#!/usr/bin/env bash
# Sockets, driven. Runs the socket exercise plain and optimised,
# checks each phase reached its expected output, tests connection refusal,
# and proves each check can fail via patched copies of the prelude.
#
#   bash bench/socket_exercise.sh
#
# Needs `make` first. Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/socket_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
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

echo "== the socket exercise, plain build"
run_case "plain" socket-exercise
if ! grep -q "all checks passed" "$WORK/socket-exercise.out" 2>/dev/null; then
  echo "  MISSING: the run did not reach the end"
  status=1
fi

echo
echo "== every socket check reported"
for phrase in connect_accept message_exchange short_read closed_peer; do
  grep -q "$phrase: ok" "$WORK/socket-exercise.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  connect_accept, message_exchange, short_read and closed_peer all reported ok"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" socket-exercise-release --release
if ! grep -q "all checks passed" "$WORK/socket-exercise-release.out" 2>/dev/null; then
  echo "  MISSING: the optimised build did not reach the end"
  status=1
fi

echo
echo "== refused connection exits non-zero with diagnostic"
"$WORK/socket-exercise" refused >"$WORK/refused.out" 2>&1
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
  echo "  refused connection unexpectedly succeeded"
  status=1
elif ! grep -q "cannot connect to 127.0.0.1:" "$WORK/refused.out"; then
  echo "  refused connection failed with unexpected message:"
  sed 's/^/    /' "$WORK/refused.out"
  status=1
else
  printf '  refused connection: exits %s at "%s"\n' "$exit_code" \
    "$(grep -m1 "cannot connect to 127.0.0.1:" "$WORK/refused.out" | sed 's/^iyi: panic: //')"
fi

echo "== a negative count is refused by name"
# `recv(-1)` died of "arithmetic overflow" on a `to_u64`, a sentence about
# neither the count nor the call.
printf 'module main\n\nimport std/socket\nusing std/socket::{IyiSocket}\n\nl = IyiSocket.listen(0)\nc = IyiSocket.connect("127.0.0.1", l.local_port).or_panic\nputs l.accept.or_panic.recv(-1).inspect\n' > "$WORK/negative.iyi"
if "$IYI" run "$WORK/negative.iyi" > "$WORK/negative.out" 2>&1; then
  echo "  a negative count was taken"; status=1
elif ! grep -q "negative count: -1" "$WORK/negative.out"; then
  echo "  a negative count was refused, but not by name:"; sed 's/^/    /' "$WORK/negative.out"; status=1
else
  echo "  recv(-1): exits 1 at \"$(grep -m1 'negative count' "$WORK/negative.out" | sed 's/^iyi: panic: //')\""
fi

echo
echo "== the checks fail when the socket mechanism is broken"
prove_fails() {
  local label="$1" dir="$2" phrase="$3" script="$4"
  # The library the program imports, not the prelude: `std/socket` is a
  # module now, so the patched copy is `std/` beside an untouched `iyi/`
  # and `IYI_PATH` finds this one first.
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  awk "$script" "$REPO/src/std/socket.iyi" > "$WORK/$dir/std/socket.iyi"
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/socket_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. Broken payload reception
prove_fails "message payload mismatch" badpayload "message_exchange:" \
  '{ sub(/target\.copy_from\(buffer, count\)/, "target[0] = 63_u8"); print }'

# 2. Broken short read (clamping buffer size below 16 bytes alters chunk size)
prove_fails "short read size mismatch" badshort "short_read:" \
  '{ sub(/buffer = Pointer\(UInt8\)\.malloc\(max_bytes\.to_u64\)/, "if max_bytes < 16; max_bytes = 1; end; buffer = Pointer(UInt8).malloc(max_bytes.to_u64)"); print }'
# 3. Broken closed peer detection (does not answer empty string on EOF)
prove_fails "closed peer EOF missed" badoff "closed_peer:" \
  '{ sub(/return "" if count == 0$/, "return \"eof_missed\" if count == 0"); print }'

# 4. Broken local port (answers 0 instead of assigned ephemeral port)
prove_fails "local port returns 0" badport "local_port failed:" \
  '{ sub(/\(high << 8\) \| low/, "0"); print }'

echo
echo "== what is not a port, and what is not an address"

# A panicking program has no next line to assert on, so these are driven
# here. `listen(70000)` used to pack the port into sixteen bits without
# asking and bind 4464; `-1` bound 65535. The address parser accumulated
# digits unbounded, so a long run of them left `Int32` and panicked about
# arithmetic rather than naming the address it could not resolve; it read
# `"010.1.1.1"` as 10.1.1.1 where glibc reads 8.1.1.1 (octal); and its
# sentence did not inspect the host, so `" 1.2.3.4"` looked valid.
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/socket\n\nusing std/socket::{IyiSocket}\n\nputs (%s).to_s\n' \
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
    echo "  $label: it answered instead of refusing"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 -o "$phrase.*" "$WORK/$name.out")"
}

refuses "a port past sixteen bits" port_big "is not a port" \
  "IyiSocket.listen(70000, 1).local_port"
refuses "a negative port" port_neg "is not a port" \
  "IyiSocket.listen(-1, 1).local_port"
refuses "an address with too many digits" addr_long "cannot resolve address" \
  "IyiSocket.connect(\"999999999999.1.1.1\", 80).or_panic.to_unsafe"
refuses "an octet past 255" addr_octet "cannot resolve address" \
  "IyiSocket.connect(\"256.1.1.1\", 80).or_panic.to_unsafe"
refuses "an octet with a leading zero" addr_octal "cannot resolve address: \"010.1.1.1\": an octet with a leading zero" \
  "IyiSocket.connect(\"010.1.1.1\", 80).or_panic.to_unsafe"
refuses "a one-digit leading zero" addr_octal_short "cannot resolve address: \"01.2.3.4\"" \
  "IyiSocket.connect(\"01.2.3.4\", 80).or_panic.to_unsafe"
refuses "a host with a leading space, shown inspected" addr_space "cannot resolve address: \" 1.2.3.4\"" \
  "IyiSocket.parse_ip(\" 1.2.3.4\").b0"
refuses "a host with a trailing space, shown inspected" addr_tspace "cannot resolve address: \"1.2.3.4 \"" \
  "IyiSocket.parse_ip(\"1.2.3.4 \").b0"
refuses "an IPv6 address, named as such" addr_v6 "cannot resolve address: \"::1\": IPv6 is not supported" \
  "IyiSocket.parse_ip(\"::1\").b0"

echo
echo "== a closed socket says so"

# `close` sets the descriptor to -1 and `closed?` knows it, but each call on
# a closed socket blamed the syscall ("cannot read from socket"), and
# `write("")` had nothing to send and answered 0.
refuses_after_close() { # refuses_after_close <label> <name> <statements on a closed connection c and listener l>
  local label="$1" name="$2" body="$3"
  printf 'module main\n\nimport std/socket\n\nusing std/socket::{IyiSocket}\n\nl = IyiSocket.listen(0)\nc = IyiSocket.connect("127.0.0.1", l.local_port).or_panic\nc.close\nl.close\n%s\n' \
    "$body" > "$WORK/$name.iyi"
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
  if ! grep -q "socket is closed" "$WORK/$name.out"; then
    echo "  $label: refused, but not with 'socket is closed'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "socket is closed"\n' "$label" "$code"
}
refuses_after_close "a read after close" closed_read 'puts c.read(10).or_panic.inspect'
refuses_after_close "a write after close" closed_write 'puts c.write("x").or_panic'
refuses_after_close "an empty write after close" closed_write_empty 'puts c.write("").or_panic'
refuses_after_close "local_port after close" closed_port 'puts c.local_port'
refuses_after_close "accept after close" closed_accept 'puts l.accept.or_panic.closed?'

echo
if [ "$status" -eq 0 ]; then
  echo "Sockets: connect, accept, message exchange, short reads, closed peer, and"
  echo "refused connections all verified, a port and an address are checked before"
  echo "they are packed, a closed socket says so, and every check is proved to fail"
  echo "when broken."
else
  echo "Sockets: something above failed."
fi
exit "$status"
