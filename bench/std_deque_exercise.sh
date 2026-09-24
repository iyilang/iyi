#!/usr/bin/env bash
# Exercises `std/deque`: the ring buffer.
#
#     bash bench/std_deque_exercise.sh
#
# Proves:
#   * Both ends, indices, wraparound, growth while wrapped (both runs), rotation
#     both ways, insertion and deletion on both sides of the middle, the
#     Indexable/IndexableMutable/Enumerable surface, and zeroed vacated slots.
#   * 3,000 generated operations, the deque printed every hundred and diffed
#     against python3 driving `collections.deque` with the same choices.
#   * What is refused: pop/shift/first/last of an empty deque, an index past
#     the end, a negative count, each with the prelude's sentence.
#   * Negative proofs: a growth that drops the wrapped run, a rotation that
#     goes the wrong way, and an insert that overwrites are each caught.
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
  local label="$1" name="$2" source="$3"
  shift 3
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  grep -v '^step ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

# python3 makes the same 3,000 choices on its own deque. Its `rotate(n)`
# turns the other way, so it is handed `-n`; its `insert` and `del` take
# the same non-negative indices the exercise draws. Python's text-mode stdout
# on windows ends every line with "\r\n" while the iyi program writes "\n", so
# all 30 snapshots differed there with identical text; the oracle is told to
# write "\n" like the program it is diffed against, which is what it already
# did on linux and darwin.
oracle() {
  "$PY" - <<'PY'
import sys
sys.stdout.reconfigure(newline="\n")
from collections import deque
seed = 7
def draw(bound):
    global seed
    seed = (seed * 1103515245 + 12345) % 2147483648
    return (seed >> 8) % bound
q = deque()
for step in range(3000):
    op = draw(10)
    if op <= 2:
        q.append(step)
    elif op == 3:
        q.appendleft(step)
    elif op <= 5:
        if q: q.pop()
    elif op == 6:
        if q: q.popleft()
    elif op == 7:
        if q: q.rotate(-(draw(7) - 3))
    elif op == 8:
        q.insert(draw(len(q) + 1), step)
    else:
        if q: del q[draw(len(q))]
    if step % 100 == 99:
        print(f"step {step}: size {len(q)} [{', '.join(str(v) for v in q)}]")
PY
}

echo "== the std/deque exercise"
build_and_run "std_deque" exercise-deque "$REPO/bench/std_deque_exercise.iyi"

echo
echo "== every deque section reported"
for check in "deque: ends" "deque: indices" "deque: wraparound and growth" "deque: rotation" "deque: insert and delete" "deque: traits and copies" "deque: vacated slots" "deque: churn vs python3" "all deque checks passed"; do
  if ! grep -q "$check" "$WORK/exercise-deque.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  ends, indices, wraparound, rotation, insert/delete, traits, vacated slots and the churn all reported"

echo
echo "== the churn against python3, 3,000 operations"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the churn against python's own deque is unmeasured"
else
  oracle > "$WORK/oracle.out"
  grep '^step ' "$WORK/exercise-deque.out" > "$WORK/iyi-steps.out"
  if [ "$(grep -c '^step ' "$WORK/oracle.out")" -ne 30 ]; then
    echo "  the oracle did not produce 30 snapshots"
    status=1
  elif diff "$WORK/oracle.out" "$WORK/iyi-steps.out" > "$WORK/steps.diff"; then
    echo "  every snapshot agrees with python3's deque"
  else
    echo "  FAIL: iyi and python3 disagree"
    sed -n '1,6p' "$WORK/steps.diff" | cut -c1-160
    status=1
  fi
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_deque release" exercise-deque-release "$REPO/bench/std_deque_exercise.iyi" --release >/dev/null
if [ -z "$PY" ]; then
  echo "  and with no oracle the optimised build has nothing to be compared against"
elif grep '^step ' "$WORK/exercise-deque-release.out" | diff -q "$WORK/oracle.out" - >/dev/null; then
  echo "  the optimised build agrees with python3 too"
else
  echo "  FAIL: the optimised build disagrees with python3"
  status=1
fi

echo
echo "== what the deque refuses"
deque_panics_with() { # deque_panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/deque::{Deque}\n\nd = Deque(Int32).new([1, 2, 3])\ne = Deque(Int32).new\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
deque_panics_with "pop of an empty deque" pop_empty "pop of an empty deque" 'e.pop'
deque_panics_with "shift of an empty deque" shift_empty "shift of an empty deque" 'e.shift'
deque_panics_with "first of an empty deque" first_empty "first of an empty collection" 'e.first'
deque_panics_with "last of an empty deque" last_empty "last of an empty collection" 'e.last'
deque_panics_with "an index past the end" index_past "index 3 out of range for 3 elements" 'd[3]'
deque_panics_with "a negative index past the front" index_neg "index -4 out of range for 3 elements" 'd[-4]'
deque_panics_with "an assignment past the end" assign_past "index 5 out of range for 3 elements" 'd[5] = 0'
deque_panics_with "an insert past the end" insert_past "index 4 out of range for 3 elements" 'd.insert(4, 0)'
deque_panics_with "a delete past the end" delete_past "index 3 out of range for 3 elements" 'd.delete_at(3)'
deque_panics_with "a negative count popped" pop_neg "negative count: -1" 'd.pop(-1)'
deque_panics_with "a negative count shifted" shift_neg "negative count: -2" 'd.shift(-2)'
deque_panics_with "a negative capacity" cap_neg "negative capacity" 'Deque(Int32).new(-1)'
deque_panics_with "a negative size" size_neg "negative size" 'Deque(Int32).new(-1, 0)'

echo
echo "== proving the checks can fail when the ring is broken"
prove_fails() { # prove_fails <label> <name> <phrase> <python replace-expression>
  local label="$1" name="$2" phrase="$3" replace="$4"
  mkdir -p "$WORK/$name/std"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the broken-ring proof is unmeasured"
    return
  fi
  "$PY" -c "
import sys
src = open('$REPO/src/std/deque.iyi').read()
broken = $replace
if broken == src:
    sys.exit('patch did not apply')
open('$WORK/$name/std/deque.iyi', 'w').write(broken)
" || { echo "  $label: the patch did not apply"; status=1; return; }
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$name/program" "$REPO/bench/std_deque_exercise.iyi" >"$WORK/$name/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
    sed -n '1,10p' "$WORK/$name/build.log"
    status=1
    return
  fi
  "$WORK/$name/program" >"$WORK/$name/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    if grep '^step ' "$WORK/$name/out" | diff -q "$WORK/oracle.out" - >/dev/null; then
      echo "  $label: the exercise still passed and python3 still agreed, so nothing tests this"
      status=1
    else
      echo "  $label: the by-hand checks missed it, but python3 caught it"
    fi
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name/out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '$p' "$WORK/$name/out" | cut -c1-160
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -F -- "$phrase" "$WORK/$name/out" | sed 's/^iyi: panic: //' | cut -c1-160)"
}

prove_fails "growth that drops the wrapped run" broken_growth "assertion failed for grown while wrapped" \
  "src.replace('return if finish <= old_cap', 'return')"
prove_fails "rotation the wrong way" broken_rotate "assertion failed for rotate with room" \
  "src.replace('push(shift)', 'unshift(pop)', 1)"
prove_fails "insert that overwrites instead of shifting" broken_insert "assertion failed for insert near the back" \
  "src.replace('@buffer[dst] = @buffer[src]\n        break if src == rindex\n        dst = src', 'break', 1)"
prove_fails "vacated slot left as it was" broken_clear "assertion failed for pop zeroes its slot" \
  "src.replace('    clear_slot(slot)\n    value', '    value')"
prove_fails "delete that closes the gap from the wrong side" broken_delete "assertion failed for delete_at near the front" \
  "src.replace('return pop if index == @size - 1\n', 'return pop if index == @size - 1\n    index = @size - 1 - index\n')"

echo
if [ "$status" -eq 0 ]; then
  echo "Deque: the ring wraps, grows and churns as python3's does over 3,000 operations,"
  echo "every refusal has its sentence, and each check is proven to fail when broken."
else
  echo "Deque: something above failed."
fi
exit $status
