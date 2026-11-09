#!/usr/bin/env bash
# Exercises `std/observe`.
#
#     bash bench/std_observe_exercise.sh
#
# Proves:
#   * The exercise holds plain and --release.
#   * With IYI_OBSERVE set, direct observer calls write expected bytes (hexdump
#     assertion; on Windows, which records its paths in its own form and whose
#     observation runtime nothing else here measures, the trace is only
#     required to end with END(0)).
#   * Normal end writes END(0).
#   * A panic writes END(1) and nothing else.
#   * Observation boundaries: raw thread callback, panic defer drain, and
#     thread/fiber depth transfer are observed and discriminate under mutation.
#   * std/observe builds, observed, beside every std module.
#   * A missing relative name with no separator is recorded under the real current directory.
#   * A single-path write records no second endpoint: a mode is not a path.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

SUCCESS=0
cleanup() {
  if [ "$SUCCESS" -eq 1 ]; then
    rm -rf "$WORK"
  else
    echo "Harness failed; preserving WORK=$WORK"
  fi
}
trap cleanup EXIT

WINDOWS=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    PSEP=';'
    WINDOWS=1
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
  *) PSEP=':' ;;
esac

export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

u32_le_hex() {
  local val=$1
  printf '%02x%02x%02x%02x' $(( val & 0xff )) $(( (val >> 8) & 0xff )) $(( (val >> 16) & 0xff )) $(( (val >> 24) & 0xff ))
}
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done


echo "== plain build and run"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/std_observe_exercise.iyi"
"$WORK/exercise"

echo "== release build and run"
"$IYI" build --release -o "$WORK/exercise_rel" "$REPO/bench/std_observe_exercise.iyi"
"$WORK/exercise_rel"

echo "== observation build with IYI_OBSERVE and hexdump assertion"
TRACE_FILE="$WORK/trace.bin"
rm -f "$TRACE_FILE"
# From `/`, so the cwd record (the real current directory) is the same in
# every checkout.
SCRATCH_DIR="$WORK/scratch"
mkdir -p "$SCRATCH_DIR"
SCRATCH_REAL="$(cd "$SCRATCH_DIR" && pwd -P)"
WRITE_PATH="${SCRATCH_REAL}/out.txt"
(cd / && TMPDIR="$SCRATCH_REAL" IYI_OBSERVE="$TRACE_FILE" "$IYI" run -Diyi_observe "$REPO/bench/std_observe_exercise.iyi")

if [ ! -f "$TRACE_FILE" ]; then
  echo "FAIL: trace file was not created"
  exit 1
fi

if [ "$WINDOWS" = 1 ]; then
  echo "  hexdump assertion skipped on Windows; the trace ends with END(0) below"
else
  ACTUAL_HEX="$(od -An -v -tx1 "$TRACE_FILE" | tr -d ' \n')"
  EXPECTED_HEX="1900000003000000000000000003000000464f4f01030000006261720009000000040000000000000000"
  EXPECTED_HEX="${EXPECTED_HEX}0e00000005000000000000000001000000"'2f'"1600000006000000000000000009000000746573742d686f7374"
  # Program.env("TMPDIR") reads TMPDIR from environment; observe runtime records value as "scratch"
  EXPECTED_HEX="${EXPECTED_HEX}2000000003000000000000000006000000544d5044495201070000007363726174636800"
  # Dynamic file_write record for WRITE_PATH under scratch
  WRITE_PATH_HEX="$(printf '%s' "$WRITE_PATH" | od -An -v -tx1 | tr -d ' \n')"
  WRITE_PATH_LEN=${#WRITE_PATH}
  WRITE_REC_LEN=$(( 19 + WRITE_PATH_LEN ))
  WRITE_REC_LEN_HEX="$(u32_le_hex $WRITE_REC_LEN)"
  WRITE_PATH_LEN_HEX="$(u32_le_hex $WRITE_PATH_LEN)"
  EXPECTED_HEX="${EXPECTED_HEX}${WRITE_REC_LEN_HEX}07000000000000000001${WRITE_PATH_LEN_HEX}${WRITE_PATH_HEX}0000000001"
  # The first clock taint:
  EXPECTED_HEX="${EXPECTED_HEX}1d000000080000000000000000200f0000007372633a746573742e6979693a3130"
  # The second clock taint is dropped; the entropy taint is its kind's first.
  EXPECTED_HEX="${EXPECTED_HEX}1d000000080000000000000000210f0000007372633a746573742e6979693a3132"
  EXPECTED_HEX="${EXPECTED_HEX}0d0000007f000000000000000000000000"

  if [ "$ACTUAL_HEX" != "$EXPECTED_HEX" ]; then
    echo "FAIL: trace hex mismatch"
    echo "  expected: $EXPECTED_HEX"
    echo "  actual:   $ACTUAL_HEX"
    exit 1
  fi
  echo "  hexdump assertion passed ($(( ${#EXPECTED_HEX} / 2 )) bytes matched exactly)"
fi

echo "== normal end writes END(0)"
# Last 17 bytes must be: 0d 00 00 00 7f 00 00 00 00 00 00 00 00 00 00 00 00
TAIL_HEX="$(tail -c 17 "$TRACE_FILE" | od -An -v -tx1 | tr -d ' \n')"
EXPECTED_TAIL="0d0000007f000000000000000000000000"
if [ "$TAIL_HEX" != "$EXPECTED_TAIL" ]; then
  echo "FAIL: expected END(0) at end of trace, got $TAIL_HEX"
  exit 1
fi
echo "  END(0) verified"

echo "== direct cwd observation gives exactly one CWD record"
CWD_SRC="$WORK/direct_cwd.iyi"
cat << 'EOF' > "$CWD_SRC"
module test/direct_cwd
import std/observe

Std::Observe.cwd("/test/dir")
EOF

CWD_TRACE="$WORK/cwd_trace.bin"
rm -f "$CWD_TRACE"
IYI_OBSERVE="$CWD_TRACE" "$IYI" run -Diyi_observe "$CWD_SRC"

if [ ! -f "$CWD_TRACE" ]; then
  echo "FAIL: direct cwd trace was not created"
  exit 1
fi

CWD_TAIL="$(tail -c 17 "$CWD_TRACE" | od -An -v -tx1 | tr -d ' \n')"
if [ "$CWD_TAIL" != "0d0000007f000000000000000000000000" ]; then
  echo "FAIL: expected END(0) at end of direct cwd trace, got $CWD_TAIL"
  exit 1
fi

if [ -n "$PY" ]; then
  "$PY" -c '
import struct, sys
with open(sys.argv[1], "rb") as f:
    data = f.read()
pos = 0
kinds = []
while pos < len(data):
    if pos + 4 > len(data):
        sys.exit(f"FAIL: truncated header at {pos}")
    payload_len, = struct.unpack_from("<I", data, pos)
    pos += 4
    if pos + payload_len > len(data):
        sys.exit(f"FAIL: truncated payload at {pos}")
    kinds.append(data[pos])
    pos += payload_len
cwd_count = kinds.count(0x05)
if cwd_count != 1:
    sys.exit(f"FAIL: expected exactly 1 CWD record (0x05), got {cwd_count} (kinds: {[hex(k) for k in kinds]})")
if kinds != [0x05, 0x7F]:
    sys.exit(f"FAIL: expected records [0x05, 0x7f], got {[hex(k) for k in kinds]}")
' "$CWD_TRACE"
fi
echo "  direct cwd observation wrote exactly one CWD record and END(0)"

echo "== relative file observation does not mark recording failed or omit END"
REL_SRC="$WORK/rel_file.iyi"
cat << 'EOF' > "$REL_SRC"
module test/rel_file
import std/observe

# Direct relative file observation exercises lookup_path and current_cwd
# without triggering recursive cwd observation or @@failed.
Std::Observe.file(1_u8, "relative_exercise_target.txt")
EOF

REL_TRACE="$WORK/rel_trace.bin"
rm -f "$REL_TRACE"
REL_DIR="$WORK/rel_cwd"
mkdir -p "$REL_DIR"
REL_TARGET="$REL_DIR/relative_exercise_target.txt"
rm -f "$REL_TARGET"

(cd "$REL_DIR" && TMPDIR="$SCRATCH_REAL" IYI_OBSERVE="$REL_TRACE" "$IYI" run -Diyi_observe "$REL_SRC")

rm -f "$REL_TARGET"
if [ ! -f "$REL_TRACE" ]; then
  echo "FAIL: relative file trace was not created"
  exit 1
fi

REL_TAIL="$(tail -c 17 "$REL_TRACE" | od -An -v -tx1 | tr -d ' \n')"
if [ "$REL_TAIL" != "0d0000007f000000000000000000000000" ]; then
  echo "FAIL: expected END(0) at end of relative file trace (recording failed or omitted END), got $REL_TAIL"
  exit 1
fi

REL_HEX="$(od -An -v -tx1 "$REL_TRACE" | tr -d ' \n')"
case "$REL_HEX" in
  *72656c61746976655f65786572636973655f7461726765742e747874*) ;;
  *)
    echo "FAIL: expected relative file target in trace, got $REL_HEX"
    exit 1
    ;;
esac

if [ -n "$PY" ]; then
  "$PY" -c '
import struct, sys
with open(sys.argv[1], "rb") as f:
    data = f.read()
pos = 0
kinds = []
while pos < len(data):
    if pos + 4 > len(data):
        sys.exit(f"FAIL: truncated header at {pos}")
    payload_len, = struct.unpack_from("<I", data, pos)
    pos += 4
    if pos + payload_len > len(data):
        sys.exit(f"FAIL: truncated payload at {pos}")
    kinds.append(data[pos])
    pos += payload_len
if 0x05 in kinds:
    sys.exit("FAIL: unexpected CWD record (0x05) emitted during relative file observation")
if kinds != [0x01, 0x7F]:
    sys.exit(f"FAIL: expected records [0x01, 0x7f], got {[hex(k) for k in kinds]}")
' "$REL_TRACE"
fi
echo "  relative file observation wrote valid record and END(0)"

echo "== panic writes END(1)"
# A panic leaves through __iyi_exit(1), so the trace ends with END(1); only a
# signal death or a timeout kill leaves no END.
PANIC_TRACE="$WORK/panic_trace.bin"
cat << 'EOF' > "$WORK/panic_prog.iyi"
raise "intentional panic for observation test"
EOF

rm -f "$PANIC_TRACE"
if IYI_OBSERVE="$PANIC_TRACE" "$IYI" run -Diyi_observe "$WORK/panic_prog.iyi" >/dev/null 2>&1; then
  echo "FAIL: panic program was expected to exit nonzero"
  exit 1
fi

PANIC_HEX="$(od -An -v -tx1 "$PANIC_TRACE" | tr -d ' \n')"
if [ "$PANIC_HEX" != "0d0000007f000000000000000001000000" ]; then
  echo "FAIL: expected only END(1) in panic trace, got $PANIC_HEX"
  exit 1
fi
echo "  panic wrote END(1)"

echo "== deterministic rendezvous regression: thread depth isolation"
PROBE_SRC="$WORK/frame_threads.iyi"
cat << 'EOF' > "$PROBE_SRC"
module test/frame_threads
import std/observe
import std/env::{ENV}

class FrameHold
  getter go : Atomic(Int64)
  getter open : Atomic(Int64)
  getter done : Atomic(Int64)
  def initialize
    @go = Atomic(Int64).new(0_i64)
    @open = Atomic(Int64).new(0_i64)
    @done = Atomic(Int64).new(0_i64)
  end
end

hold = FrameHold.new
holder = IyiThread.start do
  while hold.go.get == 0_i64
  end
  Std::Observe.enter_frame
  hold.open.set(1_i64)
  while hold.done.get == 0_i64
  end
  Std::Observe.leave_frame
  nil
end
hold.go.set(1_i64)
while hold.open.get == 0_i64
end
ENV["IYI_FRAME_PROBE"]?
hold.done.set(1_i64)
holder.join
EOF

PROBE_TRACE="$WORK/probe_trace.bin"
rm -f "$PROBE_TRACE"
IYI_OBSERVE="$PROBE_TRACE" "$IYI" run -Diyi_observe "$PROBE_SRC"

if [ ! -f "$PROBE_TRACE" ]; then
  echo "FAIL: probe trace was not created"
  exit 1
fi

PROBE_HEX="$(od -An -v -tx1 "$PROBE_TRACE" | tr -d ' \n')"
# 4959495f4652414d455f50524f4245 is "IYI_FRAME_PROBE"
case "$PROBE_HEX" in
  *4959495f4652414d455f50524f4245*) ;;
  *)
    echo "FAIL: expected IYI_FRAME_PROBE in probe trace, got $PROBE_HEX"
    exit 1
    ;;
esac

PROBE_TAIL="$(tail -c 17 "$PROBE_TRACE" | od -An -v -tx1 | tr -d ' \n')"
if [ "$PROBE_TAIL" != "0d0000007f000000000000000000000000" ]; then
  echo "FAIL: expected END(0) at end of probe trace, got $PROBE_TAIL"
  exit 1
fi
echo "  thread depth isolation observed: IYI_FRAME_PROBE recorded while helper held open frame"

echo "== deterministic rendezvous regression: mutation proof (probe can fail)"
PATCH_DIR="$WORK/patched"
mkdir -p "$PATCH_DIR/src"
cp -R "$REPO/src/iyi" "$REPO/src/std" "$PATCH_DIR/src/"
OBSERVE_PATH="$PATCH_DIR/src/std/observe.iyi"

# Delete the @[ThreadLocal] line directly above @@thread_depth
MUTATED=0
awk '
  /^[[:space:]]*@\[ThreadLocal\][[:space:]]*$/ {
    getline next_line
    if (next_line ~ /@@thread_depth/) {
      print next_line
      print "MUTATED" > "/dev/stderr"
      next
    } else {
      print
      print next_line
      next
    }
  }
  { print }
' "$OBSERVE_PATH" > "$OBSERVE_PATH.tmp" 2>"$WORK/awk_err"
mv "$OBSERVE_PATH.tmp" "$OBSERVE_PATH"

if ! grep -q "MUTATED" "$WORK/awk_err"; then
  echo "FAIL: could not apply mutation: @[ThreadLocal] line above @@thread_depth not found"
  exit 1
fi

MUT_TRACE="$WORK/mut_trace.bin"
rm -f "$MUT_TRACE"
IYI_PATH="$PATCH_DIR/src${PSEP}$REPO/samples/iyi" IYI_OBSERVE="$MUT_TRACE" "$IYI" run -Diyi_observe "$PROBE_SRC"

MUT_HEX="$(od -An -v -tx1 "$MUT_TRACE" | tr -d ' \n')"
case "$MUT_HEX" in
  *4959495f4652414d455f50524f4245*)
    echo "FAIL: probe does not discriminate: IYI_FRAME_PROBE appeared even without @[ThreadLocal]"
    exit 1
    ;;
  *)
    echo "  mutation proof passed: without @[ThreadLocal], helper frame suppressed main thread observation"
    ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "FAIL: python3 or python interpreter required for trace validation"
  exit 1
fi

echo "== concurrent recorder: 8 raw threads race, deduplication, taints, and post-taint drop"
RACE_SRC="$WORK/recorder_race.iyi"
RACE_ROOT="$WORK/recorder_race"
for thread in 0 1 2 3 4 5 6 7; do mkdir -p "$RACE_ROOT/$thread"; done
cat << 'EOF' > "$RACE_SRC"
module test/recorder_race
import std/observe
root = Program.args[0]

ready = Atomic(Int32).new(0_i32)
go = Atomic(Int32).new(0_i32)
done1 = Atomic(Int32).new(0_i32)
go2 = Atomic(Int32).new(0_i32)

threads = Array(IyiThread).new(8)
8.times do |t|
  threads << IyiThread.start do
    ready.add(1_i32)
    while go.get == 0_i32
    end

    2000.times do |i|
      path = "#{root}/#{t}/#{i}"
      Std::Observe.file_write(1_u8, path)
      Std::Observe.file(1_u8, path)
      env_name = "IYI_RACE_#{t}_#{i}"
      Std::Observe.env_write(env_name)
      Std::Observe.env_get(env_name, "v")
    end

    done1.add(1_i32)
    while go2.get == 0_i32
    end

    # Barrier then kind33/34 reverseorder odds/evens
    if t % 2 == 0
      Std::Observe.not_reusable(33_u8, "entropy_site_#{t}")
      Std::Observe.not_reusable(34_u8, "timer_site_#{t}")
    else
      Std::Observe.not_reusable(34_u8, "timer_site_#{t}")
      Std::Observe.not_reusable(33_u8, "entropy_site_#{t}")
    end

    # After-taint envget + filewrite (must be dropped by recorder)
    Std::Observe.env_get("AFTER_TAINT_#{t}", "v")
    Std::Observe.file_write(1_u8, "#{root}/AFTER_TAINT/#{t}")
    nil
  end
end

while ready.get < 8_i32
end
go.set(1_i32)

while done1.get < 8_i32
end
go2.set(1_i32)

threads.each do |th|
  th.join
end
EOF

cat << 'EOF' > "$WORK/validate_race_trace.py"
import struct, sys

trace_file = sys.argv[1]
with open(trace_file, "rb") as f:
    data = f.read()

pos = 0
records = []
while pos < len(data):
    if pos + 4 > len(data):
        sys.exit("FAIL: incomplete length header at pos %d of %d" % (pos, len(data)))
    payload_len, = struct.unpack_from("<I", data, pos)
    pos += 4
    if pos + payload_len > len(data):
        sys.exit("FAIL: incomplete payload: need %d bytes, got %d" % (payload_len, len(data) - pos))
    payload = data[pos : pos + payload_len]
    pos += payload_len
    rec_type = payload[0]
    task_id, = struct.unpack_from("<Q", payload, 1)
    body = payload[9:]
    records.append((rec_type, task_id, body))

if not records:
    sys.exit("FAIL: trace contains no records")

if records[-1][0] != 0x7F:
    sys.exit("FAIL: last record is type 0x%02x, expected 0x7f (END)" % records[-1][0])
if len(records[-1][2]) < 4:
    sys.exit("FAIL: END record payload too short")
end_status, = struct.unpack_from("<i", records[-1][2], 0)
if end_status != 0:
    sys.exit("FAIL: END status is %d, expected 0" % end_status)

type_counts = {}
type07_paths = set()
type03_written_first = 0
taint_kinds = []
first_taint_idx = None

for idx, (rec_type, task_id, body) in enumerate(records[:-1]):
    type_counts[rec_type] = type_counts.get(rec_type, 0) + 1
    if rec_type == 0x07: # file_write: op(u8), real(str), target(str), scratch(u8)
        op_code = body[0]
        real_len, = struct.unpack_from("<I", body, 1)
        real = body[5 : 5 + real_len].decode("utf-8", "replace")
        type07_paths.add(real)
    elif rec_type == 0x03: # env_get: name(str), present(u8), val(str), written_first(u8)
        if body and body[-1] == 1:
            type03_written_first += 1
    elif rec_type == 0x08: # taint: kind_code(u8), site(str)
        if first_taint_idx is None:
            first_taint_idx = idx
        kind_code = body[0]
        taint_kinds.append(kind_code)

if type_counts.get(0x07, 0) != 16000:
    sys.exit("FAIL: expected 16000 type07 records, got %d" % type_counts.get(0x07, 0))
if len(type07_paths) != 16000:
    sys.exit("FAIL: expected 16000 unique type07 paths, got %d" % len(type07_paths))
if type_counts.get(0x01, 0) != 0:
    sys.exit("FAIL: expected 0 type01 records (all skipped by written_paths), got %d" % type_counts.get(0x01, 0))
if type_counts.get(0x03, 0) != 16000:
    sys.exit("FAIL: expected 16000 type03 records, got %d" % type_counts.get(0x03, 0))
if type03_written_first != 16000:
    sys.exit("FAIL: expected 16000 type03 with written_first=1, got %d" % type03_written_first)
if type_counts.get(0x04, 0) != 16000:
    sys.exit("FAIL: expected 16000 type04 records, got %d" % type_counts.get(0x04, 0))

if taint_kinds.count(0x21) != 1 or taint_kinds.count(0x22) != 1 or len(taint_kinds) != 2:
    sys.exit("FAIL: expected exactly 1 kind 0x21 and 1 kind 0x22, got %s" % taint_kinds)

for idx, (rec_type, task_id, body) in enumerate(records[:-1]):
    if rec_type != 0x08 and first_taint_idx is not None and idx > first_taint_idx:
        sys.exit("FAIL: non-taint record type 0x%02x at index %d appeared after first taint at index %d" % (rec_type, idx, first_taint_idx))

if b"AFTER_TAINT" in data or b"/iyi-recorder-race/after" in data:
    sys.exit("FAIL: after-taint names appeared in trace")

print("OK: 8-thread race trace valid")
EOF

RACE_TRACE="$WORK/race_trace.bin"
rm -f "$RACE_TRACE"
TMPDIR="$SCRATCH_DIR" IYI_OBSERVE="$RACE_TRACE" "$IYI" run -Diyi_observe "$RACE_SRC" -- "$RACE_ROOT"
"$PY" "$WORK/validate_race_trace.py" "$RACE_TRACE"
echo "  8-thread race verified: exact counts, written_first=1, 0 self-reads, taints 33/34 deduplicated, post-taints dropped, END last"

echo "== recorder mutation proof: written-path suppression is load bearing"
MUT_WRITTEN_DIR="$WORK/mut_written"
mkdir -p "$MUT_WRITTEN_DIR/src"
cp -R "$REPO/src/iyi" "$REPO/src/std" "$MUT_WRITTEN_DIR/src/"
"$PY" - "$MUT_WRITTEN_DIR/src/std/observe.iyi" << 'EOF'
import sys
path = sys.argv[1]
with open(path) as f:
    source = f.read()
old = "if !@@enabled || @@tainted || @@failed || @@written_paths.includes?(real)"
if source.count(old) != 2:
    raise SystemExit("FAIL: expected file and directory written-path guards")
with open(path, "w") as f:
    f.write(source.replace(old, "if !@@enabled || @@tainted || @@failed", 1))
EOF
MUT_WRITTEN_TRACE="$WORK/mut_written_trace.bin"
TMPDIR="$SCRATCH_DIR" IYI_PATH="$MUT_WRITTEN_DIR/src${PSEP}$REPO/samples/iyi" IYI_OBSERVE="$MUT_WRITTEN_TRACE" "$IYI" run -Diyi_observe "$RACE_SRC" -- "$RACE_ROOT"
if "$PY" "$WORK/validate_race_trace.py" "$MUT_WRITTEN_TRACE" >"$WORK/mut_written.out" 2>&1; then
  echo "FAIL: removing written-path suppression passed the race validator"
  exit 1
fi
if ! grep -q "expected 0 type01 records" "$WORK/mut_written.out"; then
  cat "$WORK/mut_written.out"
  echo "FAIL: mutation failed for a reason other than missing written-path suppression"
  exit 1
fi
echo "  removing written-path suppression is caught by the FILE-record assertion"

echo "== concurrent recorder: mutation proof (nolock discriminates <= 5 attempts)"
MUT_NOLOCK_DIR="$WORK/mut_nolock"
mkdir -p "$MUT_NOLOCK_DIR/src"
cp -R "$REPO/src/iyi" "$REPO/src/std" "$MUT_NOLOCK_DIR/src/"
MUT_OBSERVE="$MUT_NOLOCK_DIR/src/std/observe.iyi"

"$PY" -c "
with open('$MUT_OBSERVE', 'r') as f:
    content = f.read()

start_tag = '# RECORD_LOCK_START'
end_tag = '# RECORD_LOCK_END'
s_idx = content.find(start_tag)
e_idx = content.find(end_tag)
if s_idx < 0 or e_idx < 0:
    raise Exception('lock tags not found in ' + '$MUT_OBSERVE')
content = content[:s_idx] + '# MUTATED NO-OP LOCK\n' + content[e_idx + len(end_tag):]

start_tag = '# RECORD_UNLOCK_START'
end_tag = '# RECORD_UNLOCK_END'
s_idx = content.find(start_tag)
e_idx = content.find(end_tag)
if s_idx < 0 or e_idx < 0:
    raise Exception('unlock tags not found in ' + '$MUT_OBSERVE')
content = content[:s_idx] + '# MUTATED NO-OP UNLOCK\n' + content[e_idx + len(end_tag):]

with open('$MUT_OBSERVE', 'w') as f:
    f.write(content)
"

MUTATION_FAILED=0
for attempt in 1 2 3 4 5; do
  MUT_RACE_TRACE="$WORK/mut_race_trace_$attempt.bin"
  rm -f "$MUT_RACE_TRACE"
  if ! IYI_PATH="$MUT_NOLOCK_DIR/src${PSEP}$REPO/samples/iyi" TMPDIR="$SCRATCH_DIR" IYI_OBSERVE="$MUT_RACE_TRACE" "$IYI" run -Diyi_observe "$RACE_SRC" -- "$RACE_ROOT" >/dev/null 2>&1; then
    MUTATION_FAILED=1
    break
  fi
  if ! "$PY" "$WORK/validate_race_trace.py" "$MUT_RACE_TRACE" >/dev/null 2>&1; then
    MUTATION_FAILED=1
    break
  fi
done

if [ "$MUTATION_FAILED" -eq 1 ]; then
  echo "  mutation proof passed: without lock, race caused failure (attempt $attempt)"
else
  echo "FAIL: mutation proof failed: 5 attempts unexpectedly passed without lock"
  exit 1
fi

echo "== concurrent recorder: pool variant (8 g.spawn(unit: :new) tasks)"
POOL_SRC="$WORK/pool_race.iyi"
cat << 'EOF' > "$POOL_SRC"
module test/pool_race
import std/observe

group do |g|
  8.times do |t|
    g.spawn(unit: :new) do
      2000.times do |i|
        path = "/iyi-recorder-pool/#{t}/#{i}"
        Std::Observe.file_write(1_u8, path)
        Std::Observe.file(1_u8, path)
        env_name = "IYI_POOL_#{t}_#{i}"
        Std::Observe.env_write(env_name)
        Std::Observe.env_get(env_name, "v")

        if (i + t) % 2 == 0
          Std::Observe.not_reusable(33_u8, "pool_site_#{t}")
        else
          Std::Observe.not_reusable(34_u8, "pool_site_#{t}")
        end
      end
    end
  end
end
EOF

cat << 'EOF' > "$WORK/validate_pool_trace.py"
import struct, sys

trace_file = sys.argv[1]
with open(trace_file, "rb") as f:
    data = f.read()

pos = 0
records = []
while pos < len(data):
    if pos + 4 > len(data):
        sys.exit("FAIL: incomplete length header")
    payload_len, = struct.unpack_from("<I", data, pos)
    pos += 4
    if pos + payload_len > len(data):
        sys.exit("FAIL: incomplete payload")
    payload = data[pos : pos + payload_len]
    pos += payload_len
    rec_type = payload[0]
    task_id, = struct.unpack_from("<Q", payload, 1)
    body = payload[9:]
    records.append((rec_type, task_id, body))

if not records or records[-1][0] != 0x7F:
    sys.exit("FAIL: expected END(0) last")
end_status, = struct.unpack_from("<i", records[-1][2], 0)
if end_status != 0:
    sys.exit("FAIL: expected END status 0")

first_rec = records[0]
if first_rec[0] != 0x08:
    sys.exit("FAIL: expected first record to be taint 0x08, got 0x%02x" % first_rec[0])
first_kind = first_rec[2][0]
if first_kind != 0x24:
    sys.exit("FAIL: expected first record to be process taint 0x24, got 0x%02x" % first_kind)
first_site_len, = struct.unpack_from("<I", first_rec[2], 1)
first_site = first_rec[2][5 : 5 + first_site_len].decode("utf-8", "replace")
if "concurrency.iyi" not in first_site:
    sys.exit("FAIL: expected concurrency.iyi in first taint site, got '%s'" % first_site)

type_counts = {}
taint_kinds = []

for rec_type, task_id, body in records[:-1]:
    type_counts[rec_type] = type_counts.get(rec_type, 0) + 1
    if rec_type == 0x08:
        kind_code = body[0]
        taint_kinds.append(kind_code)

for t in range(1, 8):
    if type_counts.get(t, 0) != 0:
        sys.exit("FAIL: expected 0 non-taint records of type 0x%02x, got %d" % (t, type_counts.get(t, 0)))

if taint_kinds.count(0x21) != 1 or taint_kinds.count(0x22) != 1 or taint_kinds.count(0x24) != 1 or len(taint_kinds) != 3:
    sys.exit("FAIL: expected taints [0x24, 0x21, 0x22], got %s" % taint_kinds)

print("OK: pool variant trace valid")
EOF

POOL_TRACE="$WORK/pool_trace.bin"
rm -f "$POOL_TRACE"
IYI_OBSERVE="$POOL_TRACE" "$IYI" run -Diyi_observe "$POOL_SRC"
"$PY" "$WORK/validate_pool_trace.py" "$POOL_TRACE"
echo "  pool variant verified: finished without deadlock/hang, exact counts written"

echo "== concurrent recorder: END race (host late + main returns after 200)"
END_RACE_SRC="$WORK/end_race.iyi"
cat << 'EOF' > "$END_RACE_SRC"
module test/end_race
import std/observe

count = Atomic(Int64).new(0_i64)
stop = Atomic(Int32).new(0_i32)

th = IyiThread.start do
  while stop.get == 0_i32
    Std::Observe.host("late-host")
    count.add(1_i64)
  end
  nil
end

while count.get < 200_i64
end
EOF

cat << 'EOF' > "$WORK/validate_end_race.py"
import struct, sys

trace_file = sys.argv[1]
with open(trace_file, "rb") as f:
    data = f.read()

pos = 0
records = []
while pos < len(data):
    if pos + 4 > len(data):
        sys.exit("FAIL: incomplete length header")
    payload_len, = struct.unpack_from("<I", data, pos)
    pos += 4
    if pos + payload_len > len(data):
        sys.exit("FAIL: incomplete payload")
    payload = data[pos : pos + payload_len]
    pos += payload_len
    rec_type = payload[0]
    task_id, = struct.unpack_from("<Q", payload, 1)
    body = payload[9:]
    records.append((rec_type, task_id, body))

if not records:
    sys.exit("FAIL: empty trace in end race")
if records[-1][0] != 0x7F:
    sys.exit("FAIL: expected END(0) as last record, got 0x%02x" % records[-1][0])
end_status, = struct.unpack_from("<i", records[-1][2], 0)
if end_status != 0:
    sys.exit("FAIL: expected END status 0")

host_count = sum(1 for r in records[:-1] if r[0] == 0x06)
if host_count < 200:
    sys.exit("FAIL: expected at least 200 host records, got %d" % host_count)

print("OK: END race trace valid")
EOF

END_RACE_TRACE="$WORK/end_race_trace.bin"
rm -f "$END_RACE_TRACE"
IYI_OBSERVE="$END_RACE_TRACE" "$IYI" run -Diyi_observe "$END_RACE_SRC"
"$PY" "$WORK/validate_end_race.py" "$END_RACE_TRACE"
echo "  END race verified: END(0) is last record with no trailing records after main returned"

echo "== concurrent recorder: allocation measurement (shared writer < 256 bytes/record)"
ALLOC_SRC="$WORK/alloc_measure.iyi"
cat << 'EOF' > "$ALLOC_SRC"
module test/alloc_measure
import std/observe
import std/gc::{GC}

names = Array(String).new(10000)
10000.times do |i|
  names << "PREBUILT_ENV_VAR_#{i}"
end

GC.disable
before = IyiHeap.allocated_word.value.get

10000.times do |i|
  Std::Observe.env_get(names[i], "v")
end

after = IyiHeap.allocated_word.value.get
GC.enable

delta = after - before
per_record = delta.to_f / 10000.0
puts "ALLOC_DELTA=#{delta}"
puts "ALLOC_PER_RECORD=#{per_record}"
if per_record >= 256.0
  raise "FAIL: allocation per record too high: #{per_record} bytes/record >= 256"
end
puts "OK: allocation per record < 256 bytes verified"
EOF

ALLOC_TRACE="$WORK/alloc_trace.bin"
rm -f "$ALLOC_TRACE"
IYI_OBSERVE="$ALLOC_TRACE" "$IYI" run -Diyi_observe "$ALLOC_SRC"
echo "  allocation measurement verified: shared resettable RecordWriter allocates < 256 bytes/record"

echo "== boundary B-a: raw thread body observation and mutation proof"
BOUNDARY_THREAD_SRC="$WORK/boundary_thread.iyi"
cat << 'EOF' > "$BOUNDARY_THREAD_SRC"
module test/boundary_thread
import std/env::{ENV}

t = IyiThread.start do
  ENV["IYI_THREAD_BODY_PROBE"]?
  nil
end
t.join
EOF

BOUNDARY_THREAD_TRACE="$WORK/boundary_thread_trace.bin"
rm -f "$BOUNDARY_THREAD_TRACE"
IYI_OBSERVE="$BOUNDARY_THREAD_TRACE" "$IYI" run -Diyi_observe "$BOUNDARY_THREAD_SRC"

if [ ! -f "$BOUNDARY_THREAD_TRACE" ]; then
  echo "FAIL: boundary thread trace was not created"
  exit 1
fi

B_A_HEX="$(od -An -v -tx1 "$BOUNDARY_THREAD_TRACE" | tr -d ' \n')"
# 4959495f5448524541445f424f44595f50524f4245 is "IYI_THREAD_BODY_PROBE"
case "$B_A_HEX" in
  *4959495f5448524541445f424f44595f50524f4245*) ;;
  *)
    echo "FAIL: expected IYI_THREAD_BODY_PROBE in boundary thread trace, got $B_A_HEX"
    exit 1
    ;;
esac

B_A_TAIL="$(tail -c 17 "$BOUNDARY_THREAD_TRACE" | od -An -v -tx1 | tr -d ' \n')"
if [ "$B_A_TAIL" != "0d0000007f000000000000000000000000" ]; then
  echo "FAIL: expected END(0) at end of boundary thread trace, got $B_A_TAIL"
  exit 1
fi
echo "  boundary B-a observed: raw thread body ENV read recorded with END(0)"

PATCH_DIR_BA="$WORK/patched_ba"
mkdir -p "$PATCH_DIR_BA/src"
cp -R "$REPO/src/iyi" "$REPO/src/std" "$PATCH_DIR_BA/src/"
THREAD_PATH="$PATCH_DIR_BA/src/iyi/thread.iyi"

awk '
  /Std::Observe\.suspend_frames/ {
    print "        0_i32 # MUTATED_BA"
    print "MUTATED" > "/dev/stderr"
    next
  }
  /Std::Observe\.resume_frames/ {
    print "        # MUTATED_BA"
    next
  }
  { print }
' "$THREAD_PATH" > "$THREAD_PATH.tmp" 2>"$WORK/awk_err_ba"
mv "$THREAD_PATH.tmp" "$THREAD_PATH"

if ! grep -q "MUTATED" "$WORK/awk_err_ba"; then
  echo "FAIL: could not apply mutation: suspend_frames in thread.iyi not found"
  exit 1
fi

MUT_BA_TRACE="$WORK/mut_ba_trace.bin"
rm -f "$MUT_BA_TRACE"
IYI_PATH="$PATCH_DIR_BA/src${PSEP}$REPO/samples/iyi" IYI_OBSERVE="$MUT_BA_TRACE" "$IYI" run -Diyi_observe "$BOUNDARY_THREAD_SRC"

MUT_BA_HEX="$(od -An -v -tx1 "$MUT_BA_TRACE" | tr -d ' \n')"
case "$MUT_BA_HEX" in
  *4959495f5448524541445f424f44595f50524f4245*)
    echo "FAIL: boundary B-a does not discriminate: IYI_THREAD_BODY_PROBE appeared without callback boundary"
    exit 1
    ;;
  *)
    echo "  mutation proof B-a passed: removing callback boundary hides raw thread observation"
    ;;
esac

echo "== boundary B-b: panic defer drain observation and mutation proof"
BOUNDARY_PANIC_SRC="$WORK/boundary_panic.iyi"
cat << 'EOF' > "$BOUNDARY_PANIC_SRC"
module test/boundary_panic
import std/env::{ENV}

assert_panics do
  defer ENV["IYI_DEFER_PROBE"]?
  raise "planned"
end
EOF

BOUNDARY_PANIC_TRACE="$WORK/boundary_panic_trace.bin"
rm -f "$BOUNDARY_PANIC_TRACE"
IYI_OBSERVE="$BOUNDARY_PANIC_TRACE" "$IYI" run -Diyi_observe "$BOUNDARY_PANIC_SRC"

if [ ! -f "$BOUNDARY_PANIC_TRACE" ]; then
  echo "FAIL: boundary panic trace was not created"
  exit 1
fi

B_B_HEX="$(od -An -v -tx1 "$BOUNDARY_PANIC_TRACE" | tr -d ' \n')"
# 4959495f44454645525f50524f4245 is "IYI_DEFER_PROBE"
case "$B_B_HEX" in
  *4959495f44454645525f50524f4245*) ;;
  *)
    echo "FAIL: expected IYI_DEFER_PROBE in boundary panic trace, got $B_B_HEX"
    exit 1
    ;;
esac

B_B_TAIL="$(tail -c 17 "$BOUNDARY_PANIC_TRACE" | od -An -v -tx1 | tr -d ' \n')"
if [ "$B_B_TAIL" != "0d0000007f000000000000000000000000" ]; then
  echo "FAIL: expected END(0) at end of boundary panic trace, got $B_B_TAIL"
  exit 1
fi
echo "  boundary B-b observed: panic defer ENV read recorded with END(0)"

PATCH_DIR_BB="$WORK/patched_bb"
mkdir -p "$PATCH_DIR_BB/src"
cp -R "$REPO/src/iyi" "$REPO/src/std" "$PATCH_DIR_BB/src/"
CONC_PATH_BB="$PATCH_DIR_BB/src/iyi/concurrency.iyi"

awk '
  /def self\.panic_current/ {
    in_panic = 1
    print
    next
  }
  in_panic && /Std::Observe\.abandon_frames/ {
    print "      # MUTATED_BB"
    print "MUTATED" > "/dev/stderr"
    in_panic = 0
    next
  }
  { print }
' "$CONC_PATH_BB" > "$CONC_PATH_BB.tmp" 2>"$WORK/awk_err_bb"
mv "$CONC_PATH_BB.tmp" "$CONC_PATH_BB"

if ! grep -q "MUTATED" "$WORK/awk_err_bb"; then
  echo "FAIL: could not apply mutation: abandon_frames in panic_current not found"
  exit 1
fi

MUT_BB_TRACE="$WORK/mut_bb_trace.bin"
rm -f "$MUT_BB_TRACE"
IYI_PATH="$PATCH_DIR_BB/src${PSEP}$REPO/samples/iyi" IYI_OBSERVE="$MUT_BB_TRACE" "$IYI" run -Diyi_observe "$BOUNDARY_PANIC_SRC"

MUT_BB_HEX="$(od -An -v -tx1 "$MUT_BB_TRACE" | tr -d ' \n')"
case "$MUT_BB_HEX" in
  *4959495f44454645525f50524f4245*)
    echo "FAIL: boundary B-b does not discriminate: IYI_DEFER_PROBE appeared without panic abandon_frames"
    exit 1
    ;;
  *)
    echo "  mutation proof B-b passed: removing panic abandon hides defer observation"
    ;;
esac

MUT_PANIC_TRACE="$WORK/mut_panic_trace.bin"
rm -f "$MUT_PANIC_TRACE"
if IYI_PATH="$PATCH_DIR_BB/src${PSEP}$REPO/samples/iyi" IYI_OBSERVE="$MUT_PANIC_TRACE" "$IYI" run -Diyi_observe "$WORK/panic_prog.iyi" >/dev/null 2>&1; then
  :
fi
MUT_PANIC_HEX="$(od -An -v -tx1 "$MUT_PANIC_TRACE" 2>/dev/null | tr -d ' \n' || true)"
if [ "$MUT_PANIC_HEX" = "0d0000007f000000000000000001000000" ]; then
  echo "FAIL: transfer without abandon unexpectedly produced valid END(1)"
  exit 1
fi
echo "  mutation proof panicEND passed: transfer without abandon fails to write END(1)"

echo "== boundary B-c: thread <-> fiber transfer observation and mutation proof"
BOUNDARY_TRANSFER_SRC="$WORK/boundary_transfer.iyi"
cat << 'EOF' > "$BOUNDARY_TRANSFER_SRC"
module test/boundary_transfer
import std/observe

Std::Observe.enter_frame
group do |g|
  ch = Channel(Int32).new(1)
  ch.send(1)
end
puts Std::Observe.frame_depth
Std::Observe.leave_frame
puts Std::Observe.frame_depth
EOF

BOUNDARY_TRANSFER_TRACE="$WORK/boundary_transfer_trace.bin"
rm -f "$BOUNDARY_TRANSFER_TRACE"
B_C_OUT="$(IYI_OBSERVE="$BOUNDARY_TRANSFER_TRACE" "$IYI" run -Diyi_observe "$BOUNDARY_TRANSFER_SRC")"
EXPECTED_B_C_OUT="$(printf '1\n0')"
if [ "$B_C_OUT" != "$EXPECTED_B_C_OUT" ]; then
  echo "FAIL: expected boundary transfer output '$EXPECTED_B_C_OUT', got '$B_C_OUT'"
  exit 1
fi

if [ ! -f "$BOUNDARY_TRANSFER_TRACE" ]; then
  echo "FAIL: boundary transfer trace was not created"
  exit 1
fi

B_C_TAIL="$(tail -c 17 "$BOUNDARY_TRANSFER_TRACE" | od -An -v -tx1 | tr -d ' \n')"
if [ "$B_C_TAIL" != "0d0000007f000000000000000000000000" ]; then
  echo "FAIL: expected END(0) at end of boundary transfer trace, got $B_C_TAIL"
  exit 1
fi
echo "  boundary B-c observed: depth 1->0 survived scheduler fiber transition"

PATCH_DIR_BC="$WORK/patched_bc"
mkdir -p "$PATCH_DIR_BC/src"
cp -R "$REPO/src/iyi" "$REPO/src/std" "$PATCH_DIR_BC/src/"
CONC_PATH_BC="$PATCH_DIR_BC/src/iyi/concurrency.iyi"

awk '
  /Std::Observe\.thread_became_fiber/ {
    print "      # MUTATED_BC"
    print "MUTATED" > "/dev/stderr"
    next
  }
  { print }
' "$CONC_PATH_BC" > "$CONC_PATH_BC.tmp" 2>"$WORK/awk_err_bc"
mv "$CONC_PATH_BC.tmp" "$CONC_PATH_BC"

if ! grep -q "MUTATED" "$WORK/awk_err_bc"; then
  echo "FAIL: could not apply mutation: thread_became_fiber in concurrency.iyi not found"
  exit 1
fi

MUT_BC_TRACE="$WORK/mut_bc_trace.bin"
rm -f "$MUT_BC_TRACE"
MUT_BC_OUT="$(IYI_PATH="$PATCH_DIR_BC/src${PSEP}$REPO/samples/iyi" IYI_OBSERVE="$MUT_BC_TRACE" "$IYI" run -Diyi_observe "$BOUNDARY_TRANSFER_SRC")"
FIRST_LINE="$(printf '%s\n' "$MUT_BC_OUT" | head -n 1)"
if [ "$FIRST_LINE" != "0" ]; then
  echo "FAIL: boundary B-c does not discriminate: expected 0 first without transfer, got '$FIRST_LINE'"
  exit 1
fi
echo "  mutation proof B-c passed: removing transfer gave 0 first"

if [ "$WINDOWS" = 1 ]; then
  echo "== Windows observation: existing and absent metadata"
  META_SRC="$WORK/observe_meta.iyi"
  cat << 'EOF' > "$META_SRC"
module test/observe_meta
import std/observe
Std::Observe.file(2_u8, Program.args[0])
Std::Observe.file(3_u8, Program.args[1])
EOF
  META_FILE="$WORK/observe_meta_input"
  META_ABSENT="$WORK/observe_meta_absent"
  "$PY" -c 'import os,sys; p=sys.argv[1]; open(p,"wb").write(b"observe"); os.utime(p, ns=(1700000000123456700,1700000000123456700))' "$META_FILE"
  rm -f "$META_ABSENT"
  META_TRACE="$WORK/observe_meta_trace"
  IYI_OBSERVE="$META_TRACE" TMPDIR="$SCRATCH_DIR" "$IYI" run -Diyi_observe "$META_SRC" -- "$META_FILE" "$META_ABSENT"
  "$PY" - "$META_TRACE" "$META_FILE" "$META_ABSENT" << 'EOF'
import os, struct, sys
data = open(sys.argv[1], "rb").read()
found = {}
pos = 0
ended = False
while pos < len(data):
    size, = struct.unpack_from("<I", data, pos)
    record = data[pos + 4:pos + 4 + size]
    if len(record) != size:
        raise SystemExit("FAIL: truncated observation record")
    pos += 4 + size
    if record[0] == 0x7f:
        ended = True
    if record[0] != 1:
        continue
    off = 10
    fields = []
    for _ in range(3):
        n, = struct.unpack_from("<I", record, off)
        off += 4
        fields.append(record[off:off+n].decode("utf-8"))
        off += n
    flags, present, kind, length, mtime = struct.unpack_from("<IBBQq", record, off)
    found[os.path.normcase(fields[0])] = (present, kind, length, mtime)
if not ended:
    raise SystemExit("FAIL: observation did not complete")
existing = found.get(os.path.normcase(os.path.abspath(sys.argv[2])))
missing = found.get(os.path.normcase(os.path.abspath(sys.argv[3])))
expected = (1, 1, 7, os.stat(sys.argv[2]).st_mtime_ns)
if existing != expected or missing != (0, 0, 0, 0):
    raise SystemExit(f"FAIL: Windows metadata existing={existing} expected={expected} missing={missing}")
print("  existing file size and subsecond mtime, and absent entry, recorded")
EOF
  FAIL_SRC="$WORK/observe_worker_failure.iyi"
  cat << 'EOF' > "$FAIL_SRC"
module test/observe_worker_failure
import std/observe
path = Program.args[0]
worker = IyiThread.start do
  Std::Observe.file(3_u8, path)
  nil
end
worker.join
puts "child completed"
EOF
  FAIL_TRACE="$WORK/observe_worker_failure_trace"
  FAIL_OUTPUT="$(IYI_OBSERVE="$FAIL_TRACE" TMPDIR="$SCRATCH_DIR" "$IYI" run -Diyi_observe "$FAIL_SRC" -- "$WORK/missing_parent/file")"
  if [ "$FAIL_OUTPUT" != "child completed" ]; then
    echo "FAIL: observer failure changed the child result"
    exit 1
  fi
  "$PY" - "$FAIL_TRACE" << 'EOF'
import struct, sys
data = open(sys.argv[1], "rb").read()
pos = 0
while pos < len(data):
    size, = struct.unpack_from("<I", data, pos)
    record = data[pos + 4:pos + 4 + size]
    if len(record) != size:
        raise SystemExit("FAIL: truncated observation record")
    if record[0] == 0x7f:
        raise SystemExit("FAIL: worker observation failure produced END")
    pos += 4 + size
print("  unresolved worker observation left no END and did not alter the child result")
EOF
fi

echo "== endpoint entry rule: behavioral fixtures (symlink, rename, hardlink)"
ARGV_OP_SRC="$WORK/argv_op.iyi"
cat << 'EOF' > "$ARGV_OP_SRC"
module test/argv_op
import std/file

op = Program.args[0]
path = Program.args[1]
target = Program.args.size > 2 ? Program.args[2] : ""

case op
when "symlink", "6"
  File.symlink(path, target)
when "rename", "3"
  File.rename(path, target)
when "link", "5"
  File.link(path, target)
else
  raise "unknown op: #{op}"
end
EOF


"$IYI" build -Diyi_observe -o "$WORK/argv_op" "$ARGV_OP_SRC"

cat << 'EOF' > "$WORK/entry.py"
import os, sys
p = sys.argv[1]
p_abs = os.path.abspath(p)
dirname = os.path.dirname(p_abs)
basename = os.path.basename(p_abs)
print(os.path.normpath(os.path.join(os.path.realpath(dirname), basename)))
EOF

cat << 'EOF' > "$WORK/decode_07.py"
import struct, sys

trace_file = sys.argv[1]
expected_op = int(sys.argv[2])
expected_inside = int(sys.argv[3])
expected_real = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != "" else None
expected_target = sys.argv[5] if len(sys.argv) > 5 else None

with open(trace_file, "rb") as f:
    data = f.read()

pos = 0
found = []
while pos < len(data):
    if pos + 4 > len(data):
        break
    payload_len, = struct.unpack_from("<I", data, pos)
    pos += 4
    payload = data[pos : pos + payload_len]
    pos += payload_len
    if payload and payload[0] == 0x07:
        body = payload[9:]
        op_code = body[0]
        real_len, = struct.unpack_from("<I", body, 1)
        real = body[5 : 5 + real_len].decode("utf-8", "replace")
        target_len, = struct.unpack_from("<I", body, 5 + real_len)
        target_real = body[9 + real_len : 9 + real_len + target_len].decode("utf-8", "replace")
        inside_scratch = body[9 + real_len + target_len]
        found.append((op_code, inside_scratch, real, target_real))

if len(found) != 1:
    sys.exit("FAIL: expected exactly 1 type07 record, found %d" % len(found))

op_code, inside, real, target_real = found[0]
if op_code != expected_op:
    sys.exit("FAIL: expected op %d, got %d" % (expected_op, op_code))
if inside != expected_inside:
    sys.exit("FAIL: expected inside %d, got %d" % (expected_inside, inside))
if expected_real is not None and real != expected_real:
    sys.exit("FAIL: expected real '%s', got '%s'" % (expected_real, real))
if expected_target is not None and target_real != expected_target:
    sys.exit("FAIL: expected target '%s', got '%s'" % (expected_target, target_real))

print("OK: 0x07 op=%d inside=%d real=%s target=%s" % (op_code, inside, real, target_real))
EOF

SHARED_FIXTURE="$WORK/shared_fixture"
SCRATCH_FIXTURE="$WORK/scratch_fixture"
mkdir -p "$SHARED_FIXTURE" "$SCRATCH_FIXTURE"
DATA_FIXTURE="$SCRATCH_FIXTURE/data"
printf 'endpoint_data' > "$DATA_FIXTURE"

# a: shared/link -> scratch/data => 6, 0, entry(shared/link)
LINK_A="$SHARED_FIXTURE/link_a"
rm -f "$LINK_A"
ENTRY_A="$("$PY" "$WORK/entry.py" "$LINK_A")"
TRACE_A="$WORK/trace_a.bin"
rm -f "$TRACE_A"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_A" "$WORK/argv_op" symlink "$DATA_FIXTURE" "$LINK_A"
"$PY" "$WORK/decode_07.py" "$TRACE_A" 6 0 "$ENTRY_A"
echo "  case a passed: shared/link -> scratch/data => 6, 0, entry(shared/link)"

# A link entry outside scratch is external even when it points at scratch itself.
LINK_DIR="$SHARED_FIXTURE/link_to_scratch"
rm -f "$LINK_DIR"
ENTRY_DIR="$("$PY" "$WORK/entry.py" "$LINK_DIR")"
TRACE_DIR="$WORK/trace_link_to_scratch.bin"
rm -f "$TRACE_DIR"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_DIR" "$WORK/argv_op" symlink "$SCRATCH_FIXTURE" "$LINK_DIR"
"$PY" "$WORK/decode_07.py" "$TRACE_DIR" 6 0 "$ENTRY_DIR"
echo "  shared link to scratch directory stays external"


# b: scratch/l2 -> data => 6, 1
LINK_B="$SCRATCH_FIXTURE/l2"
rm -f "$LINK_B"
TRACE_B="$WORK/trace_b.bin"
rm -f "$TRACE_B"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_B" "$WORK/argv_op" symlink "$DATA_FIXTURE" "$LINK_B"
"$PY" "$WORK/decode_07.py" "$TRACE_B" 6 1
echo "  case b passed: scratch/l2 -> data => 6, 1"

# c: shared/l3 -> data => 6, 0
LINK_C="$SHARED_FIXTURE/l3"
rm -f "$LINK_C"
ENTRY_C="$("$PY" "$WORK/entry.py" "$LINK_C")"
TRACE_C="$WORK/trace_c.bin"
rm -f "$TRACE_C"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_C" "$WORK/argv_op" symlink "$DATA_FIXTURE" "$LINK_C"
"$PY" "$WORK/decode_07.py" "$TRACE_C" 6 0 "$ENTRY_C"
echo "  case c passed: shared/l3 -> data => 6, 0"

# d: rename scratch/l4(linkintoscratch) -> shared/moved => 3, 0, entry(shared/moved)
LINK_D="$SCRATCH_FIXTURE/l4"
MOVED_D="$SHARED_FIXTURE/moved"
rm -f "$LINK_D" "$MOVED_D"
"$WORK/argv_op" symlink "$DATA_FIXTURE" "$LINK_D"
"$PY" -c 'import os,sys; assert os.path.islink(sys.argv[1]) and os.path.samefile(sys.argv[1], sys.argv[2])' "$LINK_D" "$DATA_FIXTURE"
ENTRY_D="$("$PY" "$WORK/entry.py" "$MOVED_D")"
TRACE_D="$WORK/trace_d.bin"
rm -f "$TRACE_D"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_D" "$WORK/argv_op" rename "$LINK_D" "$MOVED_D"
"$PY" "$WORK/decode_07.py" "$TRACE_D" 3 0 "$ENTRY_D"
echo "  case d passed: rename scratch/l4 -> shared/moved => 3, 0, entry(shared/moved)"

# e: hardlink scratch/data -> shared/hard => 5, 0
HARD_E="$SHARED_FIXTURE/hard"
rm -f "$HARD_E"
ENTRY_E="$("$PY" "$WORK/entry.py" "$HARD_E")"
TRACE_E="$WORK/trace_e.bin"
rm -f "$TRACE_E"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_E" "$WORK/argv_op" link "$DATA_FIXTURE" "$HARD_E"
"$PY" "$WORK/decode_07.py" "$TRACE_E" 5 0 "$ENTRY_E"
echo "  case e passed: hardlink scratch/data -> shared/hard => 5, 0"

# f: hardlink scratch/s5(linkoutside) -> scratch/h5 => 5, 0
OUTSIDE_F="$SHARED_FIXTURE/outside_f"
printf 'outside' > "$OUTSIDE_F"
S5="$SCRATCH_FIXTURE/s5"
H5="$SCRATCH_FIXTURE/h5"
rm -f "$S5" "$H5"
"$WORK/argv_op" symlink "$OUTSIDE_F" "$S5"
"$PY" -c 'import os,sys; assert os.path.islink(sys.argv[1]) and os.path.samefile(sys.argv[1], sys.argv[2])' "$S5" "$OUTSIDE_F"
TRACE_F="$WORK/trace_f.bin"
rm -f "$TRACE_F"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_F" "$WORK/argv_op" link "$S5" "$H5"
"$PY" "$WORK/decode_07.py" "$TRACE_F" 5 0
echo "  case f passed: hardlink scratch/s5(linkoutside) -> scratch/h5 => 5, 0"

# g: rename scratch/a -> scratch/b => 3, 1
SRC_G="$SCRATCH_FIXTURE/a"
DEST_G="$SCRATCH_FIXTURE/b"
rm -f "$SRC_G" "$DEST_G"
printf 'a' > "$SRC_G"
TRACE_G="$WORK/trace_g.bin"
rm -f "$TRACE_G"
TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_G" "$WORK/argv_op" rename "$SRC_G" "$DEST_G"
"$PY" "$WORK/decode_07.py" "$TRACE_G" 3 1
echo "  case g passed: rename scratch/a -> scratch/b => 3, 1"

echo "== endpoint entry rule: mutation proof (entry => safe_real_path makes a inside 1 and fails)"
MUT_ENTRY_DIR="$WORK/mut_entry"
mkdir -p "$MUT_ENTRY_DIR/src"
cp -R "$REPO/src/iyi" "$REPO/src/std" "$MUT_ENTRY_DIR/src/"
MUT_OBSERVE_FILE="$MUT_ENTRY_DIR/src/std/observe.iyi"

cat << 'EOF' > "$WORK/mutate_entry.py"
import sys

observe_file = sys.argv[1]
with open(observe_file, "r") as f:
    content = f.read()

header = "pub def safe_real_path_entry(path : String) : String\n"
start_tag = "# SAFE_REAL_PATH_ENTRY_START"
end_tag = "# SAFE_REAL_PATH_ENTRY_END"
replacement = "return safe_real_path(path)"

if content.count(header) != 1 or content.count(start_tag) != 1 or content.count(end_tag) != 1:
    sys.exit("FAIL: expected one safe_real_path_entry and one entry tag pair")
h_idx = content.find(header)
s_idx = content.find(start_tag)
e_idx = content.find(end_tag)
if not h_idx < s_idx < e_idx or content[h_idx + len(header):s_idx].strip():
    sys.exit("FAIL: the entry tags do not open the body of safe_real_path_entry")

content = content[:s_idx] + replacement + content[e_idx + len(end_tag):]
body_end = content.find("\nend\n", h_idx)
if body_end < 0 or content[h_idx + len(header):body_end].strip() != replacement:
    sys.exit("FAIL: safe_real_path_entry's body is not exactly: " + replacement)

with open(observe_file, "w") as f:
    f.write(content)
print("OK: safe_real_path_entry's body is exactly: " + replacement)
EOF
"$PY" "$WORK/mutate_entry.py" "$MUT_OBSERVE_FILE"
if cmp -s "$REPO/src/std/observe.iyi" "$MUT_OBSERVE_FILE"; then
  echo "FAIL: the mutated std/observe is identical to the one it mutates"
  exit 1
fi

# Built and run as case (a) is: only the std/observe on IYI_PATH differs.
MUT_ARGV_OP="$WORK/argv_op_mut_entry"
if ! IYI_PATH="$MUT_ENTRY_DIR/src${PSEP}$REPO/samples/iyi" "$IYI" build -Diyi_observe -o "$MUT_ARGV_OP" "$ARGV_OP_SRC"; then
  echo "FAIL: argv_op did not build against the mutated std/observe"
  exit 1
fi

# Resolved through the link, both endpoints are scratch/data, and the record names the pointee.
MUT_REAL_A="$("$PY" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$DATA_FIXTURE")"
if [ "$MUT_REAL_A" = "$ENTRY_A" ]; then
  echo "FAIL: the mutant's expected path is case (a)'s entry; nothing could discriminate"
  exit 1
fi

MUT_TRACE_A="$WORK/mut_trace_a.bin"
rm -f "$MUT_TRACE_A" "$LINK_A"
if ! TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$MUT_TRACE_A" "$MUT_ARGV_OP" symlink "$DATA_FIXTURE" "$LINK_A"; then
  echo "FAIL: argv_op built against the mutated std/observe exited nonzero"
  exit 1
fi

if "$PY" "$WORK/decode_07.py" "$MUT_TRACE_A" 6 0 "$ENTRY_A" >/dev/null 2>&1; then
  echo "FAIL: mutation did not discriminate: case (a) still had inside=0 despite entry=>safe_real_path"
  exit 1
else
  if "$PY" "$WORK/decode_07.py" "$MUT_TRACE_A" 6 1 "$MUT_REAL_A"; then
    echo "  mutation proof passed: entry=>safe_real_path made case (a) inside=1 and failed as required"
  else
    echo "FAIL: mutated case (a) produced unexpected result"
    exit 1
  fi
fi


echo "== std/observe beside every std module, observed"
# An observed build types std/observe beside whatever the program imports. A
# bare `Bool` or `Atomic` in it named `Std::Bool` or `Std::Atomic` once a
# program imported std/bool or std/atomic, and neither module's exercise
# built under -Diyi_observe. Every recorder entry point, beside every module,
# typed and not run.
if [ "$WINDOWS" = 1 ]; then
  echo "  skipped on Windows, whose observation runtime nothing else here measures"
else
  BESIDE_SRC="$WORK/beside_every_module.iyi"
  {
    for module in "$REPO"/src/std/*.iyi; do
      echo "import std/$(basename "$module" .iyi)"
    done
    cat << 'EOF'
Std::Observe.file(1_u8, "a")
Std::Observe.dir_list("a", [] of String)
Std::Observe.env_get("A", nil)
Std::Observe.env_all
Std::Observe.env_write("A")
Std::Observe.cwd("a")
Std::Observe.host("a")
Std::Observe.file_write(6_u8, "a", "b")
Std::Observe.not_reusable(32_u8, "a")
EOF
  } > "$BESIDE_SRC"
  if ! "$IYI" build --no-codegen -Diyi_observe -o "$WORK/beside_every_module" "$BESIDE_SRC" > "$WORK/beside_every_module.log" 2>&1; then
    echo "FAIL: std/observe does not build beside every std module: $(grep -E 'Error|BUG' "$WORK/beside_every_module.log" | tail -n 1 | cut -c1-200)"
    exit 1
  fi
  echo "  every recorder entry point builds beside all $(ls "$REPO"/src/std/*.iyi | wc -l | tr -d ' ') std modules"
fi

echo "== single-path writes: a missing relative name, and a second argument that is no path"
if [ "$WINDOWS" = 1 ]; then
  echo "  skipped on Windows, which records its paths in its own form"
else
  SINGLE_OP_SRC="$WORK/single_op.iyi"
  cat << 'EOF' > "$SINGLE_OP_SRC"
module test/single_op
import std/dir::{Dir}
import std/file::{File}

op = Program.args[0]
path = Program.args[1]

case op
when "delete"
  File.delete(path)
when "mkdir"
  Dir.mkdir(path)
else
  raise "unknown op: #{op}"
end
EOF
  "$IYI" build -Diyi_observe -o "$WORK/single_op" "$SINGLE_OP_SRC"

  REL_DIR="$WORK/relative_fixture"
  mkdir -p "$REL_DIR"
  REL_REAL="$(cd "$REL_DIR" && pwd -P)"
  # Longer than the directory's own path: a name cut at the wrong offset is
  # then recorded wrong, not refused, which is the side RG2 cannot see.
  REL_NAME="$("$PY" -c 'import sys; print("iyi-observe-relative-" + "n" * len(sys.argv[1]))' "$REL_REAL")"

  # h: a relative name with no separator, gone once deleted, resolves under
  # the real current directory => 2, 0, real(cwd)/name
  printf 'gone' > "$REL_DIR/$REL_NAME"
  TRACE_H="$WORK/trace_h.bin"
  rm -f "$TRACE_H"
  (cd "$REL_DIR" && TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_H" "$WORK/single_op" delete "$REL_NAME")
  "$PY" "$WORK/decode_07.py" "$TRACE_H" 2 0 "$REL_REAL/$REL_NAME"
  echo "  case h passed: delete of a missing relative name => 2, 0, real(cwd)/name"
  # i: Dir.mkdir's mode reaches the observer as the def's second argument and
  # is no path => 4, 1, real, empty target
  MADE_I="$SCRATCH_FIXTURE/made_by_mkdir"
  rm -rf "$MADE_I"
  MADE_I_REAL="$(cd "$SCRATCH_FIXTURE" && pwd -P)/made_by_mkdir"
  TRACE_I="$WORK/trace_i.bin"
  rm -f "$TRACE_I"
  (cd "$REL_DIR" && TMPDIR="$SCRATCH_FIXTURE" IYI_OBSERVE="$TRACE_I" "$WORK/single_op" mkdir "$MADE_I")
  "$PY" "$WORK/decode_07.py" "$TRACE_I" 4 1 "$MADE_I_REAL" ""
  echo "  case i passed: mkdir's mode is no path => 4, 1, real, empty target"
fi

SUCCESS=1
echo "OK: bench/std_observe_exercise.sh passed all checks"
