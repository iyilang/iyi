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
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

trap 'rm -rf "$WORK"' EXIT

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
(cd / && IYI_OBSERVE="$TRACE_FILE" "$IYI" run -Diyi_observe "$REPO/bench/std_observe_exercise.iyi")

if [ ! -f "$TRACE_FILE" ]; then
  echo "FAIL: trace file was not created"
  exit 1
fi

if [ "$WINDOWS" = 1 ]; then
  echo "  hexdump assertion skipped on Windows; the trace ends with END(0) below"
else
  ACTUAL_HEX="$(od -An -v -tx1 "$TRACE_FILE" | tr -d ' \n')"
  EXPECTED_HEX="1900000003000000000000000003000000464f4f01030000006261720009000000040000000000000000"
  EXPECTED_HEX="${EXPECTED_HEX}0e00000005000000000000000001000000"'2f'"1600000006000000000000000009000000746573742d686f737420000000070000000000000000010d0000002f746573742f6f75742e74787400000000001d000000080000000000000000200f0000007372633a746573742e6979693a3130"
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

echo "OK: bench/std_observe_exercise.sh passed all checks"
