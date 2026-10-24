#!/usr/bin/env bash
# Exercises `std/errno`.
#
#     bash bench/std_errno_exercise.sh
#
# Proves:
#   * bench/std_errno_exercise.iyi passes plain and --release:
#     - Named POSIX errno constants and their values
#     - Human-readable messages for known error codes
#     - Integer-to-Errno and round-trip conversions
#     - Unknown and negative error codes falling back to "Unknown error"
#   * Negative proofs: copies of the module with broken constants, corrupted
#     message tables or broken unknown fallbacks each
#     fail at the named assertion.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$source" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    tail -12 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  mkdir -p "$WORK/sandbox"
  "$WORK/$name" "$WORK/sandbox" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the std/errno exercise, plain build"
build_and_run "plain" errno-plain "$REPO/bench/std_errno_exercise.iyi"
if ! grep -q "ALL CHECKS PASSED" "$WORK/errno-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every errno section reported"
for phrase in \
  "== named constants and values" \
  "== messages for known error codes" \
  "== conversions and round trip" \
  "== unknown error codes"; do
  if ! grep -q "$phrase" "$WORK/errno-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" errno-release "$REPO/bench/std_errno_exercise.iyi" --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/errno-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
else
  echo "  release build passed"
fi

# ---------------------------------------------------------------------------
# Negative failure proofs
# ---------------------------------------------------------------------------

echo
echo "== proving the checks can fail when the module is broken"

prove_fails() { # prove_fails <label> <dir> <phrase> <old> <new>
  local label="$1" dir="$2" phrase="$3" old="$4" new="$5"
  mkdir -p "$WORK/$dir/std"
  if [ -z "$PY" ]; then
    echo "  $label: no python3 on this machine, so the broken-module proof is unmeasured"
    return
  fi
  OLD="$old" NEW="$new" REPO="$REPO" WORK="$WORK" DIR="$dir" "$PY" - << 'PY'
import os, sys
from pathlib import Path
src = Path(f"{os.environ['REPO']}/src/std/errno.iyi").read_text()
old = os.environ["OLD"]
new = os.environ["NEW"]
if old not in src:
    sys.exit(f"patch site missing: {old!r}")
out_path = Path(f"{os.environ['WORK']}/{os.environ['DIR']}/std/errno.iyi")
out_path.write_text(src.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  $label: the patch failed to apply"
    status=1
    return 1
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/$dir/program" "$REPO/bench/std_errno_exercise.iyi" >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return 1
  fi
  mkdir -p "$WORK/sandbox"
  "$WORK/$dir/program" "$WORK/sandbox" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return 1
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check ('$phrase')"
    tail -3 "$WORK/$dir/out"
    status=1
    return 1
  fi
  echo "  $label: caught broken module at '$phrase'"
  return 0
}

prove_fails "constant altered" enoent_val "ENOENT is 2" \
  '  ENOENT  =  2' \
  '  ENOENT  = 99'

prove_fails "known message altered" msg_altered "ENOENT message is 'No such file or directory'" \
  'when ENOENT          then "No such file or directory"' \
  'when ENOENT          then "File exists"'

prove_fails "unknown message fallback altered" unknown_msg "unknown code answers 'Unknown error'" \
  '    else                      "Unknown error"' \
  '    else                      "Something else"'

# The platform numbers, proved on the platform that compiles them. The
# module has two arms, `{% if flag?(:darwin) %}` and its `{% else %}`, so
# darwin builds the first and every other host — Linux, and Windows, which
# takes Linux's numbers — builds the second. A patch to the arm a host never
# enters builds the same program, the exercise passes, and the proof reports
# "does not test this" about a check it could not reach: the Linux patches
# did that on darwin, and the darwin patches did it on Windows, measured.
# Each host patches the block it builds: a collision with a neighbour, and
# the other platform's number leaking in, which are the two mistakes the
# numbers have had.
case "$(uname -s)" in
  Darwin)
    prove_fails "darwin ETIMEDOUT collides with ECONNREFUSED" etimedout_darwin "ETIMEDOUT is 60 on darwin" \
      '    ETIMEDOUT       =  60' \
      '    ETIMEDOUT       =  61'
    prove_fails "darwin ECONNREFUSED is Linux 111" econnrefused_darwin "ECONNREFUSED is 61 on darwin" \
      '    ECONNREFUSED    =  61' \
      '    ECONNREFUSED    = 111'
    ;;
  *)
    prove_fails "linux EREMOTE collides with EPROTO" eremote_linux "EREMOTE is 66 on linux" \
      '    EREMOTE         =  66' \
      '    EREMOTE         =  71'
    prove_fails "linux ESOCKTNOSUPPORT is Darwin 44" esock_linux "ESOCKTNOSUPPORT is 94 on linux" \
      '    ESOCKTNOSUPPORT =  94' \
      '    ESOCKTNOSUPPORT =  44'
    ;;
esac

echo
if [ "$status" -eq 0 ]; then
  echo "std/errno: all checks and negative proofs passed"
else
  echo "std/errno: some checks failed"
fi
exit $status
