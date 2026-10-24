#!/usr/bin/env bash
# Exercises `std/capsule`: RFC 9297 Capsule Protocol, RFC 9000 VarInt,
# HTTP Datagrams, and Extended CONNECT.
#
#     bash bench/std_capsule_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken datagram
# mapping, an Int32 room check that overflows at the end of a 2^31 - 1 byte
# buffer, a Quarter Stream ID bound of 2^62 - 1 rather than 2^60 - 1, and a
# Capsule-Protocol value whose parameters are not parsed are each caught,
# and what `capsule` refuses: 62-bit integer overflow, explicit length
# mismatch, overlong varints in strict mode, Quarter Stream IDs past
# 2^60 - 1, a stream ID that is no client-initiated bidirectional stream,
# and truncated buffers or length overruns in datagram and capsule
# framing.
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

trap 'rm -rf "$WORK"' EXIT

status=0
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

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
# broken <label> <name> <old> <new>: the module with <old> made <new> still
# builds, and the exercise fails on it.
broken() {
  local label="$1" name="$2"
  mkdir -p "$WORK/$name/std"
  if ! OLD="$3" NEW="$4" "$PY" - "$REPO/src/std/capsule.iyi" "$WORK/$name/std/capsule.iyi" <<'PY'
import os, sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in src:
    raise SystemExit("patch site missing")
Path(sys.argv[2]).write_text(src.replace(old, new, 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$name/exercise" "$REPO/bench/std_capsule_exercise.iyi" >"$WORK/$name/build.log" 2>&1; then
    echo "  $label: the broken module did not build"
    sed 's/^/    /' "$WORK/$name/build.log" | tail -6
    status=1
  elif "$WORK/$name/exercise" >"$WORK/$name/run.out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  else
    echo "  $label is caught: $(grep -m1 -E 'ASSERTION FAILED|panic' "$WORK/$name/run.out")"
  fi
}
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
else
  broken "a broken datagram mapping" mut-mapping '@quarter_stream_id * 4_u64' '@quarter_stream_id * 2_u64'
  broken "a room check that overflows Int32" mut-room 'return nil if room < 8' 'return nil if offset + 8 > bytes.size'
  broken "a 2^62 - 1 Quarter Stream ID bound" mut-qid 'MAX_QUARTER_STREAM_ID = 1152921504606846975_u64' 'MAX_QUARTER_STREAM_ID = 4611686018427387903_u64'
  broken "Capsule-Protocol parameters left unparsed" mut-params 'while i < n && p[i] == 59_u8' 'while false && i < n && p[i] == 59_u8'
fi

echo
echo "== what capsule refuses"
refuses() { # refuses <label> <name> <phrase> <code>
  local label="$1" name="$2" phrase="$3" code="$4"
  cat <<IYI > "$WORK/$name.iyi"
module main

import std/slice::{Bytes}
import std/capsule::{VarInt, HttpDatagram, Capsule, CapsuleType}

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
refuses "negative varint encoding length" varint_neg_len "invalid varint encoding length" 'VarInt.encode(1_u64, -1)'
refuses "truncated datagram on empty buffer" datagram_trunc "http datagram truncated: buffer empty or ends before payload" 'HttpDatagram.decode(Bytes.new(0))'
refuses "overlong datagram qid in strict mode" datagram_overlong "overlong varint encoding" 'b = Bytes.new(3); b[0] = 0x40_u8; b[1] = 0x00_u8; b[2] = 0xaa_u8; HttpDatagram.decode(b, 0, true)'
refuses "datagram quarter stream id past 2^60 - 1" datagram_qid_overflow "http datagram quarter stream id exceeds maximum 2^60 - 1" 'HttpDatagram.new(1152921504606846976_u64, Bytes.new(0))'
refuses "decoded quarter stream id past 2^60 - 1" datagram_qid_decoded "http datagram quarter stream id exceeds maximum 2^60 - 1" 'HttpDatagram.decode(VarInt.encode(1152921504606846976_u64))'
refuses "stream id past 2^62 - 1" datagram_sid_overflow "http datagram quarter stream id exceeds maximum 2^60 - 1" 'HttpDatagram.from_stream_id(18446744073709551615_u64, Bytes.new(0))'
refuses "stream id that is no request stream" datagram_sid_unaligned "http datagram stream id 19 is not a client-initiated bidirectional stream" 'HttpDatagram.from_stream_id(19_u64, Bytes.new(0))'
refuses "server-initiated stream id" datagram_sid_server "http datagram stream id 1 is not a client-initiated bidirectional stream" 'HttpDatagram.from_stream_id(1_u64, Bytes.new(0))'
refuses "truncated capsule on empty buffer" capsule_trunc "truncated capsule: buffer empty or offset beyond end" 'Capsule.decode(Bytes.new(0))'
refuses "capsule truncated before length" capsule_len_trunc "truncated capsule: buffer ends before capsule length" 'b = Bytes.new(1); b[0] = 0x00_u8; Capsule.decode(b)'
refuses "capsule length overrunning buffer" capsule_overrun "capsule length overruns buffer" 'b = Bytes.new(3); b[0] = 0x00_u8; b[1] = 0x10_u8; b[2] = 0xAA_u8; Capsule.decode(b)'
refuses "varint truncated at the end of a 2^31 - 1 byte buffer" varint_edge_trunc "varint truncated: 2-byte varint requires 2 bytes, but only 1 available" 't = Bytes.new(8); t[7] = 0x40_u8; b = Bytes.new(Pointer(UInt8).new(t.to_unsafe.address &- 2147483639_u64), 2147483647); VarInt.decode(b, 2147483646)'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/capsule exercise holds"
else
  echo "the std/capsule exercise did not hold"
fi
exit $status
