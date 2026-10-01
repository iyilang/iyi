#!/usr/bin/env bash
# Exercises `std/static_array`: fixed-size stack array new, size, index.
#
#     bash bench/std_static_array_exercise.sh
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
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"

build_and_run() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_static_array_exercise.iyi" \
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

echo "== the std/static_array exercise, plain build"
build_and_run "plain" static_array-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/static_array-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every static_array section reported"
for phrase in "== new" "== index" "== compare" "== fill"; do
  if ! grep -q "$phrase" "$WORK/static_array-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" static_array-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/static_array-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/static_array.iyi").read_text()
old = '  def size : Int32\n    N\n  end'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/static_array.iyi").write_text(src.replace(old, '  def size : Int32\n    0\n  end', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_static_array_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken static_array is caught"
  fi
fi

# Each further break is built before it is run: a broken copy that does not
# compile also "fails", and proves nothing about the check.
prove_fails() { # prove_fails <label> <name> <phrase> <old> <new>
  local label="$1" name="$2" phrase="$3" old="$4" new="$5"
  if [ -z "$PY" ]; then
    echo "  $label: skipped, no working python3"
    return
  fi
  mkdir -p "$WORK/$name/std"
  if ! "$PY" - "$old" "$new" <<PY
import sys
from pathlib import Path
src = Path("$REPO/src/std/static_array.iyi").read_text()
old, new = sys.argv[1], sys.argv[2]
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/$name/std/static_array.iyi").write_text(src.replace(old, new, 1))
PY
  then
    echo "  $label: the patch did not apply"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$name${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$name/program" "$REPO/bench/std_static_array_exercise.iyi" >"$WORK/$name/build.log" 2>&1; then
    echo "  $label: the broken copy did not compile"
    sed -n '1,6p' "$WORK/$name/build.log"
    status=1
  elif "$WORK/$name/program" >"$WORK/$name/out" 2>&1; then
    echo "  $label: the exercise PASSED on a broken module"
    status=1
  elif ! grep -qF -- "$phrase" "$WORK/$name/out"; then
    echo "  $label: failed, but not at '$phrase'"
    sed -n '$p' "$WORK/$name/out"
    status=1
  else
    printf '  %s: caught at "%s"\n' "$label" "$(grep -m1 -F -- "$phrase" "$WORK/$name/out" | sed 's/^iyi: panic: //')"
  fi
}

# The text grown by `+` a piece at a time again, as `to_s` was written: the
# bound beside `to_a.to_s` catches it.
prove_fails "to_s grown by + again" broken_to_s "ASSERTION FAILED: to_s: 10,000 elements took" \
  '    String.build do |io|
      io << "StaticArray["
      i = 0
      while i < N
        io << ", " if i > 0
        io << to_unsafe[i].inspect
        i += 1
      end
      io << "]"
    end' '    res = "StaticArray["
    i = 0
    while i < N
      res = res + ", " if i > 0
      res = res + to_unsafe[i].inspect
      i += 1
    end
    res + "]"'

prove_fails "<=> answering the other way" broken_cmp "ASSERTION FAILED: <=> is lexicographic" \
  '      return cmp if cmp != 0' '      return 0 - cmp if cmp != 0'
prove_fails "fill ending at s + c again" broken_fill_end "arithmetic overflow" \
  '    limit = c > N - i ? N : i + c.to_i' '    limit = i + c.to_i > N ? N : i + c.to_i'

# The method renamed out of the way is the module as it was: no `hash` of
# its own, so `Object#hash`, the type's id, for every value.
prove_fails "hash answering the type's id again" broken_hash "ASSERTION FAILED: hash spread" \
  '  def hash : Int32' '  def hash_unused : Int32'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/static_array exercise holds"
else
  echo "the std/static_array exercise did not hold"
fi
exit $status
