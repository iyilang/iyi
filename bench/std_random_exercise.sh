#!/usr/bin/env bash
# Exercises `std/random`.
#
#     bash bench/std_random_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_random_exercise.iyi" \
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

echo "== the std/random exercise, plain build"
build_and_run "plain" random-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/random-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every random section reported"
for phrase in "== seed" "== array" "== static array" "== secure" "== bounds" "== seeded draws"; do
  if ! grep -q "$phrase" "$WORK/random-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" random-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/random-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what rand refuses"
# A bound or range that holds no value is a panic that says so, never a
# zero or an end of the range made up. One probe program, the case named
# by its argument.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/random::{Random}

r = Random.new(1)
case Program.args[0]
when "exclusive" then puts r.rand(5...5)
when "reversed"  then puts r.rand(3_i64..2_i64)
when "zero"      then puts r.rand(0_u64)
when "negative"  then puts r.rand(-4_i64)
when "float"     then puts r.rand(0.0)
when "floats"    then puts r.rand(2.0..1.0)
when "bytes"     then puts Random::Secure.random_bytes(-1).size
end
IYI
if ! "$IYI" build -o "$WORK/refuse" "$WORK/refuse.iyi" >"$WORK/refuse.build" 2>&1; then
  echo "  the probe did not build"
  sed -n '1,10p' "$WORK/refuse.build"
  status=1
else
  for case_name in exclusive reversed zero negative float floats bytes; do
    if "$WORK/refuse" "$case_name" >"$WORK/refuse.out" 2>&1; then
      echo "  $case_name: answered $(cat "$WORK/refuse.out") instead of refusing"
      status=1
    elif ! grep -qE "empty range|negative size" "$WORK/refuse.out"; then
      echo "  $case_name: refused without saying why: $(sed -n '1p' "$WORK/refuse.out")"
      status=1
    else
      echo "  $case_name: $(sed -n '1p' "$WORK/refuse.out" | sed 's/^iyi: panic: //')"
    fi
  done
fi

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  # A bounded draw that answers zero, and the stream taken from the seed
  # rather than from the sequence - which is what this module did, and
  # why a seeded program printed other numbers than the other library's.
  # And any integer's sequence dropped on the way to the generator's own.
  # Then the secure source that answers nothing (every draw the zero the
  # word started as), its bulk path alone doing the same, a draw taken mod
  # the bound with nothing thrown away at 32 and at 64 bits, and an
  # inclusive range that leaves its end out: each must be caught by the
  # check written for it, named by the phrase after the patch.
  for label in bounded stream static any secure bulk bias32 bias64 inclusive; do
    rm -rf "$WORK/patched" && mkdir -p "$WORK/patched/std"
    phrase="$(PROOF="$label" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/random.iyi").read_text()
proofs = {
    "bounded": ("result.unsafe_mod(bound).to_i32", "0", ""),
    "stream": ("@inc = (sequence << 1) | 1_u64", "@inc = (seed << 1) | 1_u64", ""),
    "static": ("    i = N - 1\n", "    i = N - 2\n", ""),
    "any": ("new(seed.to_u64, sequence.to_u64)", "new(seed.to_u64, 0_u64)", ""),
    "secure": ("    return if count == 0\n", "    return\n", "10,000 secure draws hold only"),
    "bulk": ("    Secure.fill(buffer.to_unsafe, buffer.size)\n", "    buffer.size\n", "secure 128-bit tokens repeat"),
    "bias32": ("return result32.unsafe_mod(bound).to_u64 if result32 < limit32 || limit32 == 0_u32",
               "return result32.unsafe_mod(bound).to_u64", "rand(3 * 2^30) is unbiased"),
    "bias64": ("return result.unsafe_mod(n) if result < limit || limit == 0_u64",
               "return result.unsafe_mod(n)", "rand(3 * 2^62) is unbiased"),
    "inclusive": ("      span = span + 1_u64\n    end\n    first &+ below(span).to_u32",
                  "    end\n    first &+ below(span).to_u32", "rand(-3..3) draws each"),
}
old, new, phrase = proofs[os.environ["PROOF"]]
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/random.iyi").write_text(src.replace(old, new, 1))
print(phrase)
PY
)"
    if [ $? -ne 0 ]; then
      echo "  $label: the patch did not apply"
      status=1
    elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_random_exercise.iyi" >"$WORK/mut.out" 2>&1; then
      echo "  $label: the exercise PASSED on a broken module"
      status=1
    elif [ -n "$phrase" ] && ! grep -qF -- "$phrase" "$WORK/mut.out"; then
      echo "  $label: failed, but not at the check written for it ($phrase):"
      sed -n '1,3p' "$WORK/mut.out" | sed 's/^/    /'
      status=1
    else
      echo "  $label: caught - $(grep -m1 'panic' "$WORK/mut.out" | sed 's/^iyi: panic: //')"
    fi
  done
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/random exercise holds"
else
  echo "the std/random exercise did not hold"
fi
exit $status
