#!/usr/bin/env bash
# Exercises `std/observe`.
#
#     bash bench/std_observe_exercise.sh
#
# Proves:
#   * The exercise holds plain and --release.
#   * With IYI_OBSERVE set, direct observer calls write expected bytes (hexdump assertion).
#   * Normal end writes END(0).
#   * Panic writes no END record (file is empty / truncated before END).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK"' EXIT

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

echo "== plain build and run"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/std_observe_exercise.iyi"
"$WORK/exercise"

echo "== release build and run"
"$IYI" build --release -o "$WORK/exercise_rel" "$REPO/bench/std_observe_exercise.iyi"
"$WORK/exercise_rel"

echo "== observation build with IYI_OBSERVE and hexdump assertion"
TRACE_FILE="$WORK/trace.bin"
rm -f "$TRACE_FILE"
IYI_OBSERVE="$TRACE_FILE" "$IYI" run -Diyi_observe "$REPO/bench/std_observe_exercise.iyi"

if [ ! -f "$TRACE_FILE" ]; then
  echo "FAIL: trace file was not created"
  exit 1
fi

ACTUAL_HEX="$(od -An -v -tx1 "$TRACE_FILE" | tr -d ' \n')"
EXPECTED_HEX="1900000003000000000000000003000000464f4f0103000000626172000900000004000000000000000016000000050000000000000000090000002f746573742f6469721600000006000000000000000009000000746573742d686f737420000000070000000000000000010d0000002f746573742f6f75742e74787400000000001d000000080000000000000000200f0000007372633a746573742e6979693a31300d0000007f000000000000000000000000"

if [ "$ACTUAL_HEX" != "$EXPECTED_HEX" ]; then
  echo "FAIL: trace hex mismatch"
  echo "  expected: $EXPECTED_HEX"
  echo "  actual:   $ACTUAL_HEX"
  exit 1
fi
echo "  hexdump assertion passed (172 bytes matched exactly)"

echo "== normal end writes END(0)"
# Last 17 bytes must be: 0d 00 00 00 7f 00 00 00 00 00 00 00 00 00 00 00 00
TAIL_HEX="$(tail -c 17 "$TRACE_FILE" | od -An -v -tx1 | tr -d ' \n')"
EXPECTED_TAIL="0d0000007f000000000000000000000000"
if [ "$TAIL_HEX" != "$EXPECTED_TAIL" ]; then
  echo "FAIL: expected END(0) at end of trace, got $TAIL_HEX"
  exit 1
fi
echo "  END(0) verified"

echo "== panic writes none"
PANIC_TRACE="$WORK/panic_trace.bin"
cat << 'EOF' > "$WORK/panic_prog.iyi"
raise "intentional panic for observation test"
EOF

rm -f "$PANIC_TRACE"
if IYI_OBSERVE="$PANIC_TRACE" "$IYI" run -Diyi_observe "$WORK/panic_prog.iyi" >/dev/null 2>&1; then
  echo "FAIL: panic program was expected to exit nonzero"
  exit 1
fi

PANIC_SIZE="$(wc -c < "$PANIC_TRACE" | tr -d ' ')"
if [ "$PANIC_SIZE" -ne 0 ]; then
  echo "FAIL: expected 0 bytes for panic trace, got $PANIC_SIZE bytes"
  exit 1
fi
echo "  panic wrote no END record (trace file size is 0)"

echo "OK: bench/std_observe_exercise.sh passed all checks"
