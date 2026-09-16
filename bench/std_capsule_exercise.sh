#!/usr/bin/env bash
# Exercises `std/capsule`: RFC 9297 Capsule Protocol, RFC 9000 VarInt,
# HTTP Datagrams, and Extended CONNECT.
#
#     bash bench/std_capsule_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken datagram
# mapping is caught, and what `capsule` refuses: 62-bit integer overflow,
# explicit length mismatch, overlong varints in strict mode, and truncated
# buffers or length overruns in datagram and capsule framing.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src:$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_capsule_exercise.iyi" \
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

echo "== the std/capsule exercise, plain build"
build_and_run "plain" capsule-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/capsule-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every capsule section reported"
for phrase in "== varint" "== datagram" "== capsule" "== reader" "== connect"; do
  if ! grep -q "$phrase" "$WORK/capsule-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" capsule-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/capsule-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
python3 - <<PY
from pathlib import Path
src = Path("$REPO/src/std/capsule.iyi").read_text()
old = '@quarter_stream_id * 4_u64'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/capsule.iyi").write_text(src.replace(old, '@quarter_stream_id * 2_u64', 1))
PY
if [ $? -ne 0 ]; then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched:$REPO/src:$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_capsule_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken capsule is caught"
  sed 's/^/    /' "$WORK/mut.out" | tail -4
fi

echo
echo "== what capsule refuses"
refuses() { # refuses <label> <name> <phrase> <code>
  local label="$1" name="$2" phrase="$3" code="$4"
  cat <<IYI > "$WORK/$name.iyi"
module main

import std/slice
using std/slice::{Bytes}
import std/capsule
using std/capsule::{VarInt, HttpDatagram, Capsule, CapsuleType}

$code
IYI
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code_exit=$?
  if [ "$code_exit" -eq 0 ]; then
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
  printf '  %s: exits %s at "%s"\n' "$label" "$code_exit" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

refuses "varint value exceeding 62-bit MAX" varint_overflow "varint value exceeds maximum 62-bit integer" 'VarInt.encode(4611686018427387904_u64)'
refuses "value too large for 1-byte varint" varint_byte_overflow "does not fit in 1-byte varint" 'VarInt.encode(64_u64, 1)'
refuses "overlong varint in strict mode" varint_overlong "overlong varint encoding" 'VarInt.decode_strict(VarInt.encode(37_u64, 2))'
refuses "truncated varint on empty buffer" varint_trunc "varint truncated: buffer empty or offset beyond end" 'VarInt.decode(Bytes.new(0))'
refuses "truncated datagram on empty buffer" datagram_trunc "http datagram truncated: buffer empty or ends before payload" 'HttpDatagram.decode(Bytes.new(0))'
refuses "truncated capsule on empty buffer" capsule_trunc "truncated capsule: buffer empty or offset beyond end" 'Capsule.decode(Bytes.new(0))'
refuses "capsule truncated before length" capsule_len_trunc "truncated capsule: buffer ends before capsule length" 'b = Bytes.new(1); b[0] = 0x00_u8; Capsule.decode(b)'
refuses "capsule length overrunning buffer" capsule_overrun "capsule length overruns buffer" 'b = Bytes.new(3); b[0] = 0x00_u8; b[1] = 0x10_u8; b[2] = 0xAA_u8; Capsule.decode(b)'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/capsule exercise holds"
else
  echo "the std/capsule exercise did not hold"
fi
exit $status
