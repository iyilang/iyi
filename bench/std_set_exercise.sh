#!/usr/bin/env bash
# Exercises `std/set`: the algebra added to the prelude's `Set(T)`.
#
#     bash bench/std_set_exercise.sh
#
# Proves:
#   * Union, intersection, difference, symmetric difference, the subset and
#     superset relations, `disjoint?`, `intersects?`, `==` and `hash` on sets a
#     person can read.
#   * The same algebra on 200 generated pairs, diffed line by line against
#     python3 computing the pairs with its own `set`.
#   * The prelude's `Set` is the one the algebra lands on: `[..].to_set | s`.
#   * Enumerable on a set, through the impl in std/enumerable.
#   * Negative proofs: an intersection that unions, a subset test that ignores
#     size, and an equality that ignores membership are each caught.
#
# Exits non-zero if any check fails.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The gate runs the compiler the caller names; bin/iyi is a POSIX shell
# wrapper a Windows build cannot run.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on that path, so the
# patched copy is never read and the proof that a check can fail quietly
# stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

# The negative proofs are patched by python, and a machine can answer
# `python3` with a store stub that prints a refusal instead of running, so
# the interpreter is resolved once and proven to run before it is trusted.
PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PY="$candidate"
    break
  fi
done

status=0
# A proof that did not run is counted, so the closing line cannot claim more
# than was measured.
unmeasured=0
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
  grep -v '^pair \|^  ' "$WORK/$name.out" | sed 's/^/  /'
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

# python3 draws the same 200 pairs with the same generator and prints the
# same lines; the diff is the check. Python's text-mode stdout on windows
# ends every line with "\r\n" while the iyi program writes "\n", so all 1,400
# lines differed there with identical text; the oracle is told to write "\n"
# like the program it is diffed against, which is what it already did on
# linux and darwin.
oracle() {
  "$PY" - <<'PY'
import sys
sys.stdout.reconfigure(newline="\n")
seed = 42
def draw(bound):
    global seed
    seed = (seed * 1103515245 + 12345) % 2147483648
    return (seed >> 8) % bound
def show(s):
    return "[" + ", ".join(str(v) for v in sorted(s)) + "]"
def b(v):
    return "true" if v else "false"
for pair in range(200):
    x, y = set(), set()
    nx = draw(10)
    ny = draw(10)
    for _ in range(nx): x.add(draw(16))
    for _ in range(ny): y.add(draw(16))
    print(f"pair {pair}: {show(x)} {show(y)}")
    print(f"  | {show(x | y)}")
    print(f"  & {show(x & y)}")
    print(f"  - {show(x - y)}")
    print(f"  ^ {show(x ^ y)}")
    print(f"  <= {b(x <= y)} < {b(x < y)} >= {b(x >= y)} > {b(x > y)}")
    print(f"  disjoint {b(x.isdisjoint(y))} == {b(x == y)}")
PY
}

echo "== the std/set exercise"
build_and_run "std_set" exercise-set "$REPO/bench/std_set_exercise.iyi"

echo
echo "== every set section reported"
for check in "set: operators" "set: relations" "set: equality and hashing" "set: building" "set: enumerable" "set: algebra vs python3" "all set checks passed"; do
  if ! grep -q "$check" "$WORK/exercise-set.out" 2>/dev/null; then
    echo "  MISSING: $check"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  operators, relations, equality, building, enumerable and the python3 comparison all reported"

echo
echo "== the algebra against python3, 200 generated pairs"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the 200-pair oracle was not drawn or compared"
  unmeasured=$((unmeasured + 1))
else
  oracle > "$WORK/oracle.out"
  grep '^pair \|^  ' "$WORK/exercise-set.out" > "$WORK/iyi-pairs.out"
  if [ "$(grep -c '^pair ' "$WORK/oracle.out")" -ne 200 ]; then
    echo "  the oracle did not produce 200 pairs"
    status=1
  elif diff "$WORK/oracle.out" "$WORK/iyi-pairs.out" > "$WORK/pairs.diff"; then
    echo "  every operator and relation agrees with python3 on all 200 pairs"
  else
    echo "  FAIL: iyi and python3 disagree"
    sed -n '1,12p' "$WORK/pairs.diff"
    status=1
  fi
fi

echo
echo "== the same program with optimisation on (--release)"
build_and_run "std_set release" exercise-set-release "$REPO/bench/std_set_exercise.iyi" --release >/dev/null
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the optimised build was not compared with the oracle"
  unmeasured=$((unmeasured + 1))
elif grep '^pair \|^  ' "$WORK/exercise-set-release.out" | diff -q "$WORK/oracle.out" - >/dev/null; then
  echo "  the optimised build agrees with python3 too"
else
  echo "  FAIL: the optimised build disagrees with python3"
  status=1
fi

echo
echo "== proving the checks can fail when the algebra is broken"
prove_fails() { # prove_fails <label> <name> <phrase> <python replace-expression>
  local label="$1" name="$2" phrase="$3" replace="$4"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3 to make the broken copy with"
    unmeasured=$((unmeasured + 1))
    return 0
  fi
  mkdir -p "$WORK/$name/std"
  "$PY" -c "
import sys
src = open('$REPO/src/std/set.iyi').read()
broken = $replace
if broken == src:
    sys.exit('patch did not apply')
open('$WORK/$name/std/set.iyi', 'w').write(broken)
" || { echo "  $label: the patch did not apply"; status=1; return; }
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$name/program" "$REPO/bench/std_set_exercise.iyi" >"$WORK/$name/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
    sed -n '1,10p' "$WORK/$name/build.log"
    status=1
    return
  fi
  "$WORK/$name/program" >"$WORK/$name/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    if grep '^pair \|^  ' "$WORK/$name/out" | diff -q "$WORK/oracle.out" - >/dev/null; then
      echo "  $label: the exercise still passed and python3 still agreed, so nothing tests this"
      status=1
    else
      echo "  $label: the by-hand checks missed it, but python3 caught it"
    fi
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name/out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '$p' "$WORK/$name/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(grep -m1 -F -- "$phrase" "$WORK/$name/out" | sed 's/^iyi: panic: //')"
}

prove_fails "intersection that unions" broken_and "assertion failed for intersection" \
  "src.replace('result.add(v) if other.includes?(v)', 'result.add(v)')"
prove_fails "subset test that ignores membership" broken_subset "assertion failed for subset_of? same size" \
  "src.replace('each { |v| return false unless other.includes?(v) }', '')"
prove_fails "equality that ignores membership" broken_eq "assertion failed for == sees a different member" \
  "src.replace('size == other.size && subset_of?(other)', 'size == other.size')"
prove_fails "symmetric difference missing one side" broken_xor "assertion failed for symmetric difference" \
  "src.replace('other.each { |v| result.add(v) unless includes?(v) }', '')"

echo
if [ "$status" -ne 0 ]; then
  echo "Set: something above failed."
elif [ "$unmeasured" -eq 0 ]; then
  echo "Set: the algebra agrees with python3 on 200 pairs, the relations, equality"
  echo "and hashing hold, and each check is proven to fail when broken."
else
  echo "Set: the relations, equality and hashing hold, and $unmeasured checks were"
  echo "not measured here: no working python3 for the oracle or the broken copies."
fi
exit $status
