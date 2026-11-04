#!/usr/bin/env bash
# Exercises `std/parallel`: `each_parallel`, `map_parallel`, `sum_parallel`
# and `reduce_parallel` (SPEC.md III.4.14).
#
#     bash bench/std_parallel_exercise.sh
#
# Proves:
#   * bench/std_parallel_exercise.iyi passes plain and --release on four
#     workers: every verb over a `List`, an `Array` and two ranges answers
#     what its one-thread twin answers, `map_parallel` in the elements'
#     order, every element run exactly once; chunks run on more than one
#     worker, never the caller's thread, two of them overlapping in time;
#     the lowest failing index's error, a panic in one chunk and a
#     cancelled caller each reach the caller as SPEC.md says; nested calls.
#   * The same program with one worker (`IYI_WORKERS=1`) and built under
#     `-Dgc_none` (and `-Dgc_boehm` where libgc links) runs every chunk on
#     the caller, starts no pool, and answers the same.
#   * What the compiler refuses, in its own sentences: an element that is
#     not Share, at the call; a captured value that is not Share, naming
#     the lock and the one-thread twin; a captured local the block assigns.
#   * The speedup on a CPU-bound sum, release build, best of three: four
#     workers (or as many as there are cores) at least 0.5 times as many
#     times faster than one, counting the cores that compute, not their
#     SMT threads.
#   * Negative proofs: copies of std/parallel that drop the last chunk,
#     that put the chunks back in the wrong order, that start one task,
#     that go on past a known failure, and that say nothing of the
#     elements, each fail at the named check.
#
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

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
EXERCISE="$REPO/bench/std_parallel_exercise.iyi"

# A run that hangs is a failure with a name, not a job that never ends.
bounded=""
command -v timeout >/dev/null 2>&1 && bounded="timeout -k 5 300"

# The cores this process may run on, as the pool counts them.
case "$(uname -s)" in
  Darwin) CORES="$(sysctl -n hw.ncpu)" ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT) CORES="${NUMBER_OF_PROCESSORS:-1}" ;;
  *) CORES="$(nproc)" ;;
esac

# The cores that compute it: the sum keeps a core's arithmetic busy, and
# the second SMT thread on a core adds none of its own. On ubuntu-24.04's
# runner, an AMD EPYC 9V45 with 2 cores of 2 threads (4 CPUs), the release
# build's sum took 50.8 to 51.1 ms on one worker and 25.0 to 25.9 ms on
# two, three and four alike, three fresh runs each (CI job 126403714590),
# where `bench/parallel_exercise.sh`'s tasks, whose loop leaves a core room
# for its sibling, scaled 3.85x on four; the floor of 0.5 x 4 had failed
# at 1.93x (run 41767883229). Never more than the CPUs this process may
# run on, which is what `nproc` and the pool count.
case "$(uname -s)" in
  Darwin) PHYS="$(sysctl -n hw.physicalcpu)" ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    PHYS="$(powershell -NoProfile -Command '(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum' 2>/dev/null | tr -d '\r')" ;;
  *) PHYS="$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | grep -c .)" ;;
esac
case "$PHYS" in
  '' | *[!0-9]* | 0) PHYS="$CORES" ;;
esac
[ "$PHYS" -gt "$CORES" ] && PHYS="$CORES"

build_and_run() { # build_and_run <label> <name> <build flags...>; runs with the environment given
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$EXERCISE" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  $bounded "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

reported() { # reported <out file> <sentence>...
  local out="$1" sentence
  shift
  for sentence in "$@"; do
    if ! grep -qF "$sentence" "$out" 2>/dev/null; then
      echo "  MISSING: $sentence"
      status=1
    fi
  done
}

echo "== the std/parallel exercise, plain build, four workers"
build_and_run "std_parallel" plain
reported "$WORK/plain.out" \
  "answer as one thread does" \
  "keeps the elements' order, chunk by chunk" \
  "exactly once" \
  "never on the caller's thread, on more than one" \
  "overlapped in time" \
  "the lowest index that failed" \
  "starts no element past a failure it knows of" \
  "a panic in one chunk reached the caller" \
  "its chunks not yet started skipped" \
  "inside a parallel task" \
  "ALL CHECKS PASSED"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_parallel --release" release --release >/dev/null
reported "$WORK/release.out" "overlapped in time" "ALL CHECKS PASSED"
[ "$status" -eq 0 ] && echo "  every check holds under --release"

echo
echo "== one worker: IYI_WORKERS=1"
IYI_WORKERS=1 $bounded "$WORK/plain" >"$WORK/one.out" 2>&1 || { echo "  IYI_WORKERS=1: exited $?"; status=1; }
sed 's/^/  /' "$WORK/one.out" | grep -v "^  ==" | grep -v "^  $"
reported "$WORK/one.out" "one worker: every chunk ran on the caller's thread, and no pool started" "ALL CHECKS PASSED"

echo
echo "== no threads: -Dgc_none, and -Dgc_boehm where libgc links"
build_and_run "std_parallel -Dgc_none" none -Dgc_none >/dev/null
reported "$WORK/none.out" "one worker: every chunk ran on the caller's thread, and no pool started" "ALL CHECKS PASSED"
[ "$status" -eq 0 ] && echo "  -Dgc_none: every chunk on the caller, every answer the same"
if ! "$IYI" build -Dgc_boehm -o "$WORK/boehm" "$EXERCISE" >"$WORK/boehm.build.log" 2>&1; then
  if grep -qi "cannot find -lgc\|library 'gc' not found\|lgc.*not found\|gc.lib\|bdw-gc" "$WORK/boehm.build.log"; then
    echo "  -Dgc_boehm: no libgc to link on this machine"
  else
    tail -8 "$WORK/boehm.build.log"
    echo "  -Dgc_boehm: build failed"
    status=1
  fi
else
  $bounded "$WORK/boehm" >"$WORK/boehm.out" 2>&1 || { echo "  -Dgc_boehm: exited $?"; status=1; }
  reported "$WORK/boehm.out" "one worker: every chunk ran on the caller's thread, and no pool started" "ALL CHECKS PASSED"
  [ "$status" -eq 0 ] && echo "  -Dgc_boehm: every chunk on the caller, every answer the same"
fi

# ---------------------------------------------------------------------------
# What the compiler refuses
# ---------------------------------------------------------------------------

echo
echo "== what the compiler refuses, in its own sentences"
refused() { # refused <label> <sentence> <program text>
  local label="$1" sentence="$2" text="$3" dir="$WORK/refuse-$1"
  mkdir -p "$dir"
  printf '%s\n' "$text" >"$dir/main.iyi"
  if "$IYI" build --no-codegen -o "$dir/main" "$dir/main.iyi" >"$dir/build.log" 2>&1; then
    echo "  $label: compiled (it should have been refused)"
    status=1
  elif ! grep -qF "$sentence" "$dir/build.log"; then
    echo "  $label: refused, but not with '$sentence':"
    grep -m1 "^Error" "$dir/build.log" | sed 's/^/    /'
    status=1
  else
    echo "  $label: $(grep -m1 "^Error" "$dir/build.log" | cut -c8-200)..."
  fi
}
COUNTER='import std/parallel::{Parallel}

class Counter
  property count : Int32 = 0
end
'
refused element "Array#map_parallel hands its block \`Counter\` on other threads, several at once, and it is not Share: Counter's field @count is given a setter \`count=\`. Make the elements Share" \
  "$COUNTER
puts [Counter.new].map_parallel { |c| 1 }"
refused capture "the block Range#map_parallel keeps, which may run on other threads captures \`counter : Counter\`, which is not Share: Counter's field @count is given a setter \`count=\`. Put it behind a lock, a \`Mutex(Counter)\` (std/mutex), or use \`map\`, which stays on one thread" \
  "$COUNTER
counter = Counter.new
puts (0...10).map_parallel { |i| counter.count = i; i }"
refused assigned "the block Range#each_parallel keeps, which may run on other threads assigns \`total\`" \
  "$COUNTER
total = 0
(0...10).each_parallel { |i| total = total + i }
puts total"

# ---------------------------------------------------------------------------
# The speedup
# ---------------------------------------------------------------------------

echo
best_us() { # best_us <workers> <binary> <workload> <n>: the best of three runs' parallel time
  local best="" run us
  for run in 1 2 3; do
    us="$(IYI_WORKERS="$1" $bounded "$2" speed "$3" "$4" 1 | sed -n 's/.*: parallel \([0-9]*\) us.*/\1/p')"
    [ -n "$us" ] || { echo "the speed run at $1 workers printed no time" >&2; return 1; }
    if [ -z "$best" ] || [ "$us" -lt "$best" ]; then best="$us"; fi
  done
  echo "$best"
}
K=4
[ "$CORES" -lt "$K" ] && K="$CORES"
# The floor is half of what the cores that compute could give.
F="$K"
[ "$PHYS" -lt "$F" ] && F="$PHYS"
echo "== the speedup: a CPU-bound sum of 4,000,000 elements, release build, best of three, $CORES cores here, $PHYS of them whole cores"
if [ "$F" -lt 2 ]; then
  echo "  one core here: nothing to scale onto, so the ratio is not held"
elif [ "$status" -eq 0 ]; then
  ONE="$(best_us 1 "$WORK/release" sum 4000000)" || status=1
  MANY="$(best_us "$K" "$WORK/release" sum 4000000)" || status=1
  if [ "$status" -eq 0 ]; then
    ratio="$(awk -v a="$ONE" -v b="$MANY" 'BEGIN { printf "%.2f", a / b }')"
    if awk -v one="$ONE" -v many="$MANY" -v f="$F" 'BEGIN { exit !(many > 0 && one / many >= 0.5 * f) }'; then
      echo "  $K workers: $MANY us against one worker's $ONE us, ${ratio}x, over the floor of $(awk -v f="$F" 'BEGIN { printf "%.1f", 0.5 * f }')x"
    else
      echo "  $K workers took $MANY us against one worker's $ONE us, ${ratio}x: under 0.5 x $F, which is not parallel"
      status=1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== proving the checks can fail when the module is broken"
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$script" "$REPO/src/std/parallel.iyi" > "$WORK/$dir/std/parallel.iyi"
  if cmp -s "$REPO/src/std/parallel.iyi" "$WORK/$dir/std/parallel.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build -o "$WORK/$dir/program" "$EXERCISE" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  $bounded "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check ('$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //' | cut -c1-160)"
}

prove_fails "a chunk dropped" dropped "answers what map answers" \
  's/break if at >= chunks$/break if at >= chunks - 1_i64/'
prove_fails "order lost" reversed "answers what map answers" \
  's/parts\[piece\[0\]\.to_i32\] = piece\[1\]/parts[(cut[1] - 1_i64 - piece[0]).to_i32] = piece[1]/'
prove_fails "a run that never leaves one worker" one_task "chunks run on more than one worker" \
  's/while count < tasks$/while count < 1/'
prove_fails "a failure that stops nothing" unstopped "starts no element past a failure" \
  's/while index < span\[1\] \&\& index < failed_at.get$/while index < span[1]/'

echo
echo "== proving the element check can fail: a copy that says nothing of the elements"
mkdir -p "$WORK/silent/std"
sed -e 's/@\[Share(elements: .*)\]$/@[Share]/' "$REPO/src/std/parallel.iyi" > "$WORK/silent/std/parallel.iyi"
printf '%s\n' "$COUNTER" 'puts [Counter.new].map_parallel { |c| 1 }' >"$WORK/silent/main.iyi"
if cmp -s "$REPO/src/std/parallel.iyi" "$WORK/silent/std/parallel.iyi"; then
  echo "  the patch changed nothing, so this proves nothing"
  status=1
elif IYI_PATH="$WORK/silent${PSEP}$REPO/src" "$IYI" build --no-codegen -o "$WORK/silent/main" "$WORK/silent/main.iyi" >"$WORK/silent/build.log" 2>&1; then
  echo "  the copy compiled a non-Share element, where its own capture check should still refuse it inside std"
  status=1
elif grep -qF "Array#map_parallel hands its block" "$WORK/silent/build.log"; then
  echo "  the copy still refused at the call, so the element check is not what the sentence comes from"
  status=1
elif ! grep -qF "the block spawn(parallel: true) runs on another thread captures \`source : Std::List::List(Counter)\`" "$WORK/silent/build.log"; then
  echo "  the copy was refused, but not by the capture check inside std/parallel:"
  grep -m1 "^Error" "$WORK/silent/build.log" | sed 's/^/    /'
  status=1
else
  echo "  refused only inside std/parallel, not at the call: $(grep -m1 "^Error" "$WORK/silent/build.log" | cut -c8-140)..."
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/parallel exercise holds"
else
  echo "the std/parallel exercise did not hold"
fi
exit $status
