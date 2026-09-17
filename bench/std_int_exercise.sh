#!/usr/bin/env bash
# Exercises `std/int`: the rest of the integer tower: UInt16, Int8, and
# the tower's exact comparison with a double and conversion from one.
#
#     bash bench/std_int_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_int_exercise.iyi" \
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

echo "== the std/int exercise, plain build"
build_and_run "plain" int-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/int-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every int section reported"
for phrase in "== add" "== bits" "== comparison with doubles" "== conversion from doubles" "== traits"; do
  if ! grep -q "$phrase" "$WORK/int-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" int-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/int-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what the conversions from a double refuse"
# A panicking program has no next line to assert on, so each refusal is
# its own program. The conversion truncates first: what is refused is a
# truncation the integer does not hold, NaN, and the infinities.
refuses() { # refuses <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nimport std/int\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
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
refuses "128.0 to_i8" f64_i8_128 "arithmetic overflow" '128.0.to_i8'
refuses "-129.0 to_i8" f64_i8_neg "arithmetic overflow" '(-129.0).to_i8'
refuses "-1.0 to_u16" f64_u16_neg "arithmetic overflow" '(-1.0).to_u16'
refuses "65536.0 to_u16" f64_u16_big "arithmetic overflow" '65536.0.to_u16'
refuses "2^32 to_u" f64_u_2p32 "arithmetic overflow" '4294967296.0.to_u'
refuses "2^127 to_i128" f64_i128_2p127 "arithmetic overflow" '170141183460469231731687303715884105728.0.to_i128'
refuses "2^128 to_u128" f64_u128_2p128 "arithmetic overflow" '340282366920938463463374607431768211456.0.to_u128'
refuses "NaN to_i128" f64_nan "arithmetic overflow" '(0.0 / 0.0).to_i128'
refuses "Infinity to_u128" f64_inf "arithmetic overflow" '(1.0 / 0.0).to_u128'
refuses "-Infinity to_i16" f64_ninf "arithmetic overflow" '(-1.0 / 0.0).to_i16'

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/int.iyi").read_text()
old = 'count = count + 1 if (unsafe_shr(i) & 1) != 0'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/int.iyi").write_text(src.replace(old, 'count = count', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_int_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken int is caught"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/int exercise holds"
else
  echo "the std/int exercise did not hold"
fi
exit $status
