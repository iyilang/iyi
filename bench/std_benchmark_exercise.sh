#!/usr/bin/env bash
# Exercises `std/benchmark`: wall-clock measure of a block, and that bm
# and ips print only what they measured.
#
#     bash bench/std_benchmark_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_benchmark_exercise.iyi" \
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

echo "== the std/benchmark exercise, plain build"
build_and_run "plain" benchmark-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/benchmark-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every benchmark section reported"
for phrase in "== measure" "== integer seconds, and only what is measured"; do
  if ! grep -q "$phrase" "$WORK/benchmark-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

# bm and ips print to the program's output, which the program cannot read
# back: the user, system and total columns and ips's B/op printed zeros
# whatever the block did, and neither is measured, so neither is printed.
# The program prints them when asked (`print`): a time is not the same
# twice, and its plain output is compared run for run elsewhere.
unmeasured_columns() { # unmeasured_columns <output>: 0 when one printed
  grep -q "B/op\|user  *system" "$1"
}
echo
echo "== bm and ips print a real time and no unmeasured column"
"$WORK/benchmark-plain" print >"$WORK/printed.out" 2>&1
sed 's/^/  /' "$WORK/printed.out" | grep -v "^  ==\|^    \|^  $\|ALL CHECKS"
if unmeasured_columns "$WORK/printed.out"; then
  echo "  a column this module does not measure was printed:"
  grep "B/op\|user  *system" "$WORK/printed.out" | sed 's/^/    /'
  status=1
elif ! grep -q "^ *real$" "$WORK/printed.out" || ! grep -q "^a block  *(  [0-9.]*)$" "$WORK/printed.out" || ! grep -q "^an array .*fastest$" "$WORK/printed.out"; then
  echo "  bm's or ips's line is missing"
  status=1
else
  echo "  bm's real time and ips's rate, nothing else"
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" benchmark-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/benchmark-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
# prove <label> <old> <new> [output]: the exercise, run on a copy with
# <old> made <new>, has to fail - or, given `output`, print a column this
# module does not measure, which only this script can see.
prove() {
  local label="$1" old="$2" new="$3" how="${4:-exit}"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the proof is unmeasured"
    return 0
  fi
  rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
  if ! OLD="$old" NEW="$new" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/benchmark.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/benchmark.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_benchmark_exercise.iyi" -- print >"$WORK/mut.out" 2>&1; then
    if [ "$how" = output ] && unmeasured_columns "$WORK/mut.out"; then
      echo "  $label: caught"
    else
      echo "  $label: the exercise PASSED on a broken module"
      status=1
    fi
  else
    echo "  $label: caught"
  fi
}
prove "a measure without its label" 'BM::Tms.new(real, label)' 'BM::Tms.new(real, "")'
prove "integer seconds asked of Time" 'return Std::Time::Span.seconds(seconds.to_i64)' 'return Time.seconds(seconds.to_i64)'
prove "a fraction of a second dropped" 'return Std::Time::Span.seconds(seconds.to_i64) if seconds.is_a?(Int)' 'return Std::Time::Span.seconds(seconds.to_i64)'
prove "zeros for the CPU time" 'Std::Format.sprintf("(  %.6f)", real)' 'Std::Format.sprintf("  0.000000   0.000000   0.000000 (  %.6f)", real)'
prove "zeros for the bytes per call" '            item.human_compare)' '            "0B/op  " + item.human_compare)' output

echo
if [ "$status" -eq 0 ]; then
  echo "the std/benchmark exercise holds"
else
  echo "the std/benchmark exercise did not hold"
fi
exit $status
