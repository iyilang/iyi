#!/usr/bin/env bash
# Exercises `std/named_tuple`.
#
#     bash bench/std_named_tuple_exercise.sh
#
# Proves the exercise holds plain and --release, that a broken reverse_merge
# is caught by mutation, and what named tuple key access refuses: a missing
# literal symbol key at compile time, and a missing dynamic string or symbol
# key at runtime.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_named_tuple_exercise.iyi" \
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

echo "== the std/named_tuple exercise, plain build"
build_and_run "plain" named_tuple-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/named_tuple-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every named_tuple section reported"
for phrase in "== construction" "== access" "== iteration" "== equality" "== merge and transformation" "== edges"; do
  if ! grep -q "$phrase" "$WORK/named_tuple-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" named_tuple-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/named_tuple-release.out" 2>/dev/null; then
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
src = Path("$REPO/src/std/named_tuple.iyi").read_text()
old = '    other.merge(self)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/named_tuple.iyi").write_text(src.replace(old, '    self.merge(other)', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_named_tuple_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken named_tuple is caught"
  fi
fi

echo
echo "== proving hetero to_a fails when the module types only the first value"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_toa/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/named_tuple.iyi").read_text()
old = """    {% if T.keys.size == 0 %}
      [] of {Symbol, NoReturn}
    {% else %}
      [
        {% for k in T.keys %}
          { {{k.symbolize}}, self[{{k.symbolize}}] },
        {% end %}
      ]
    {% end %}"""
if old not in src:
    raise SystemExit("to_a patch site missing")
new = """    arr = [] of {Symbol, typeof(values[0])}
    {% for k in T.keys %}
      arr << {:{{k.id}}, self[:{{k.id}}]}
    {% end %}
    arr"""
Path("$WORK/patched_toa/std/named_tuple.iyi").write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the to_a patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_toa${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_named_tuple_exercise.iyi" >"$WORK/mut_toa.out" 2>&1; then
    echo "  the exercise PASSED on a broken to_a"
    status=1
  else
    echo "  a broken to_a is caught"
  fi
fi

echo
echo "== compile-time and runtime refusals for missing keys"
refuses_compile() {
  local label="$1" name="$2" phrase="$3" code="$4"
  cat <<IYI >"$WORK/$name.iyi"
module bench/refusal_$name
import std/named_tuple
$code
IYI
  if "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: COMPILED invalid code"
    status=1
  elif grep -Fq "$phrase" "$WORK/$name.build.log"; then
    echo "  $label: refused at compile time ($phrase)"
  else
    echo "  $label: failed with wrong phrase"
    cat "$WORK/$name.build.log"
    status=1
  fi
}

refuses_runtime() {
  local label="$1" name="$2" phrase="$3" code="$4"
  cat <<IYI >"$WORK/$name.iyi"
module bench/refusal_$name
import std/named_tuple
$code
IYI
  if "$IYI" run "$WORK/$name.iyi" >"$WORK/$name.out" 2>&1; then
    echo "  $label: ACCEPTED invalid key"
    status=1
  elif grep -Fq "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused at runtime ($phrase)"
  else
    echo "  $label: failed with wrong phrase"
    cat "$WORK/$name.out"
    status=1
  fi
}

refuses_compile "missing literal symbol key" missing_literal_sym \
  "missing key 'missing_key' for named tuple" \
  'nt = {a: 1, b: 2}; puts nt[:missing_key]'

refuses_runtime "missing dynamic string key" missing_dynamic_str \
  'Missing named tuple key: "missing_key"' \
  'nt = {a: 1, b: 2}; k = ["missing_key"][0]; puts nt[k]'

refuses_runtime "missing dynamic symbol key" missing_dynamic_sym \
  'Missing named tuple key: missing_key' \
  'nt = {a: 1, b: 2}; k = [:missing_key][0]; puts nt[k]'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/named_tuple exercise holds"
else
  echo "the std/named_tuple exercise did not hold"
fi
exit $status
