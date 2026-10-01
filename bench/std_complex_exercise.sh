#!/usr/bin/env bash
# Exercises `std/complex`: Complex abs, arithmetic, exp and roots at the
# top of the range, a zero's sign, division and inverses at the ends of
# the range, sign, hashing and equality.
#
#     bash bench/std_complex_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_complex_exercise.iyi" \
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

echo "== the std/complex exercise, plain build"
build_and_run "plain" complex-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/complex-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every complex section reported"
for phrase in "== abs" "== arithmetic" "== a zero's sign" "== division" "== sign" "== hash and equality"; do
  if ! grep -q "$phrase" "$WORK/complex-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" complex-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/complex-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what the exercise cannot ask: a caller's cis, a zero divisor"
# A module whose `cis` names a `Math` the caller never imported fails to
# compile the caller, and a quotient that panics ends a program before any
# check: neither can be a line of the exercise, so a small program asks,
# and the answer names what broke.
cat >"$WORK/edge.iyi" <<'IYI'
import std/complex::{Complex}

puts 0.5.cis.to_s
puts (Complex.new(1.0, 1.0) / 0.0).to_s
IYI
edge_check() {
  if ! IYI_PATH="$1" "$IYI" build -o "$WORK/edge" "$WORK/edge.iyi" >"$WORK/edge.build.log" 2>&1; then
    echo "a number's cis did not compile without the caller importing Math"
    return
  fi
  "$WORK/edge" 2>&1 | tr -d '\r' >"$WORK/edge.out"
  if [ "$(sed -n 1p "$WORK/edge.out")" != "0.8775825618903728 + 0.479425538604203i" ]; then
    echo "a number's cis is not cos + i sin: $(sed -n 1p "$WORK/edge.out")"
  elif [ "$(sed -n 2p "$WORK/edge.out")" != "Infinity + Infinityi" ]; then
    echo "a complex over a zero float is not infinite, as a float's quotient is: $(sed -n 2p "$WORK/edge.out")"
  fi
}
why="$(edge_check "$REPO/src${PSEP}$REPO/samples/iyi")"
if [ -n "$why" ]; then
  echo "  $why"
  status=1
else
  echo "  cis compiles without Math in scope, and x / 0.0 is Infinity + Infinityi"
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
else
  # `abs` breaks the first check; every other label puts back one thing
  # this module got wrong, and the check written for it has to be the one
  # that fails - a copy caught somewhere else proves nothing about it.
  for label in abs to_s conj negate minus root divide over inv exp bigroot sign hash equal cis zero; do
    rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
    if ! PROOF="$label" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/complex.iyi").read_text()
proofs = {
    "abs": ("Math.hypot(@real, @imag)", "@real + @imag"),
    "to_s": ('    joiner = @imag.nan? || Math.copysign(1.0, @imag) > 0.0 ? " + " : " - "\n'
             '    @real.to_s + joiner + @imag.abs.to_s + "i"\n',
             '    sign_str = @imag >= 0.0 ? " + " : " - "\n'
             '    im = @imag >= 0.0 ? @imag.to_s : (0.0 - @imag).to_s\n'
             '    @real.to_s + sign_str + im + "i"\n'),
    "conj": ("Complex.new(@real, -@imag)", "Complex.new(@real, 0.0 - @imag)"),
    "negate": ("Complex.new(-@real, -@imag)", "Complex.new(0.0 - @real, 0.0 - @imag)"),
    "minus": ("to_f64 - other.real, -other.imag", "to_f64 - other.real, 0.0 - other.imag"),
    "root": ("y >= 0.0 ? im : -im", "y >= 0.0 ? im : 0.0 - im"),
    "divide": ("  def /(other : Complex) : Complex\n",
               "  def /(other : Complex) : Complex\n"
               "    d = other.abs2\n"
               '    raise "Division by zero" if d == 0.0\n'
               "    return Complex.new((@real * other.real + @imag * other.imag) / d, (@imag * other.real - @real * other.imag) / d)\n"),
    "over": ("self * other.inv", "Std::Complex::Complex.new(self, 0) / other"),
    "inv": ("return conj / d if zero? || d.nan? || (d >= Float64::MIN_POSITIVE && d <= Float64::MAX)", "return conj / d"),
    "exp": ("    return Complex.new(r, @imag) if @imag == 0.0\n", ""),
    "bigroot": ("    if x.abs > big || y.abs > big\n", "    if false\n"),
    "sign": ("    return self if zero?\n",
             "    return self if zero?\n    mag = abs\n    return Complex.new(@real / mag, @imag / mag)\n"),
    "hash": ("    h = @real.hash\n    return h if @imag == 0.0\n"
             "    (h.to_i64.unsafe_to_u64 &* 0x100000001B3_u64 ^ @imag.hash.to_i64.unsafe_to_u64).hash\n",
             "    @real.to_i64.to_i32 ^ @imag.to_i64.to_i32\n"),
    "equal": ("  def ==(other : Std::Complex::Complex) : ::Bool\n    other == self\n  end\n", ""),
    "cis": ("Std::Math::Math.cos(val), Std::Math::Math.sin(val)", "Math.cos(val), Math.sin(val)"),
    "zero": ("    n = other.to_f64\n    Complex.new(@real / n, @imag / n)\n",
             '    n = other.to_f64\n    raise "Division by zero" if n == 0.0\n    Complex.new(@real / n, @imag / n)\n'),
}
old, new = proofs[os.environ["PROOF"]]
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/complex.iyi").write_text(src.replace(old, new, 1))
PY
    then
      echo "  $label: the patch did not apply"
      status=1
      continue
    fi
    case "$label" in
      abs) want="3-4-5" ;;
      to_s) want="a negative zero prints as a minus" ;;
      conj) want="the conjugate of -1 is below the branch cut" ;;
      negate) want="negation flips a zero" ;;
      minus) want="a number minus a complex negates its imaginary zero" ;;
      root) want="a root's underflowed imaginary part keeps its sign" ;;
      divide) want="a divisor whose abs2 overflows" ;;
      over) want="a number over a complex is times its inverse" ;;
      inv) want="the inverse of a value whose abs2 underflows" ;;
      exp) want="e to a real power past the range keeps its imaginary zero" ;;
      bigroot) want="the root of a value near the top of the range" ;;
      sign) want="an infinite part's sign is its axis" ;;
      hash) want="a real complex hashes as its real part" ;;
      equal) want="a number equals its complex" ;;
      cis) want="a number's cis did not compile without the caller importing Math" ;;
      zero) want="a complex over a zero float is not infinite" ;;
    esac
    path="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi"
    case "$label" in
      cis | zero) got="$(edge_check "$path")" ;;
      *)
        if IYI_PATH="$path" "$IYI" run "$REPO/bench/std_complex_exercise.iyi" >"$WORK/mut.out" 2>&1; then
          got=""
        else
          got="$(grep -m1 'panic\|Error' "$WORK/mut.out" | sed 's/^iyi: panic: //')"
          [ -n "$got" ] || got="failed without a message"
        fi
        ;;
    esac
    case "$got" in
      *"$want"*) echo "  $label: caught - $got" ;;
      "") echo "  $label: the exercise PASSED on a broken module"; status=1 ;;
      *) echo "  $label: caught, but not by its own check - $got"; status=1 ;;
    esac
  done
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/complex exercise holds"
else
  echo "the std/complex exercise did not hold"
fi
exit $status
