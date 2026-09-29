#!/usr/bin/env bash
# Builds crystal-metric's port (`bench/metric/metric.iyi`) with --release and
# requires all twenty-six answers.
#
# Each benchmark checks its result against the one the Crystal program
# prints: a checksum of what it wrote, or the numbers themselves. So the
# port is a whole-library correctness check as much as a benchmark - the
# shortest float text, PCG32 `Random`, `Array#sample`, `Float#round`,
# BigInt, regex literals, JSON reading and writing with `derive
# serializable`, `Complex`, channels - over one program that uses them
# together, the way a user's does. crystal-metric's review
# (0.15.4) asked for it to be a gate: code written one week stopped
# compiling the next, and a gate catches that before a user does.
#
# Timings are printed and not judged: the machine a gate runs on is not one
# a ratio can be quoted from. The answers are judged, every one.
#
# Then four broken copies of std, one module each, and the benchmark that
# reads that module has to fail: the gate has to be able to.
#
#     bash bench/metric_port.sh
#
# Needs `make iyi`. Exits non-zero if the port does not build, if any
# benchmark answers wrongly, or if a broken module goes unnoticed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
export IYI_PATH="$REPO/src"

# In a directory of its own: a full --release run writes `results.js`
# beside its source, which is where the port keeps the times the other
# modes are scored against.
mkdir -p "$WORK/port"
cp "$REPO/bench/metric/metric.iyi" "$WORK/port/metric.iyi"

echo "== the port, --release"
if ! (cd "$WORK/port" && "$IYI" build --release -o metric metric.iyi) > "$WORK/build.log" 2>&1; then
  echo "  the port did not build:"
  sed -n '1,20p' "$WORK/build.log" | sed 's/^/    /'
  exit 1
fi
(cd "$WORK/port" && timeout 900 ./metric) > "$WORK/run.out" 2>&1
code=$?
sed 's/^/  /' "$WORK/run.out"
if [ "$code" -ne 0 ]; then
  echo "  the port exited $code"
  status=1
fi
answered="$(grep -c ': ok in ' "$WORK/run.out")"
if [ "$answered" -ne 26 ]; then
  echo "  $answered of 26 benchmarks answered as Crystal does"
  status=1
fi

echo
echo "== proving the port fails when a module it reads is broken"
broken() { # broken <label> <module> <benchmark> <old> <new>
  local label="$1" module="$2" bench="$3" old="$4" new="$5"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    return 0
  fi
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  OLD="$old" NEW="$new" "$PY" - "$REPO/src/std/$module.iyi" "$WORK/patched/std/$module.iyi" <<'PY'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
old = os.environ["OLD"]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique: " + old)
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, os.environ["NEW"], 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if ! (cd "$WORK/port" && IYI_PATH="$WORK/patched${PSEP}$REPO/src" "$IYI" build --release -o broken metric.iyi) \
       > "$WORK/broken.log" 2>&1; then
    echo "  $label: the broken copy did not build"
    sed -n '1,8p' "$WORK/broken.log" | sed 's/^/    /'
    status=1
    return
  fi
  if (cd "$WORK/port" && timeout 300 ./broken "$bench") > "$WORK/broken.out" 2>&1; then
    echo "  $label: $bench PASSED on a broken module"
    status=1
  elif grep -q "^$bench: ok " "$WORK/broken.out"; then
    echo "  $label: the port failed, but $bench answered"
    status=1
  else
    echo "  $label: caught by $bench"
  fi
}
broken "a BigInt sum that drops its carry" big Pidigits \
  'sum = x[i] &+ y[i] &+ carry' 'sum = x[i] &+ y[i]'
broken "a base64 pair written backwards" base64 Base64Encode \
  'chars[k.unsafe_shr(6)].to_i32 | chars[k & 63].to_i32.unsafe_shl(8)' 'chars[k & 63].to_i32 | chars[k.unsafe_shr(6)].to_i32.unsafe_shl(8)'
broken "a regex automaton that keeps every bit" regex RegexDna \
  'state = (state.unsafe_shl(1_u64) | heads) & masks[src[i].to_i32]' 'state = state.unsafe_shl(1_u64) | heads'
broken "a derive that reads no field's key" json JsonParseSerializable \
  '        when {{ field[:name][1..] }}
' '        when {{ field[:name][1..] }} + "?"
'

echo
if [ "$status" -eq 0 ]; then
  echo "crystal-metric's port holds"
else
  echo "crystal-metric's port did not hold"
fi
exit $status
