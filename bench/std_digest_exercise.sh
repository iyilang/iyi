#!/usr/bin/env bash
# Exercises `std/digest`.
#
#     bash bench/std_digest_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_digest_exercise.iyi" \
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

echo "== the std/digest exercise, plain build"
build_and_run "plain" digest-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/digest-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every digest section reported"
for phrase in "== md5" "== sha" "== checksum"; do
  if ! grep -q "$phrase" "$WORK/digest-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" digest-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/digest-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== proving the checks can fail when the module is broken"
mkdir -p "$WORK/patched/std"
if [ -z "$PY" ]; then
  echo "  no python3 on this machine, so the broken-module proof is unmeasured"
elif ! "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/digest.iyi").read_text()
old = 'a0 = 0x67452301_u32'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/digest.iyi").write_text(src.replace(old, 'a0 = 0_u32', 1))
PY
then
  echo "  the patch did not apply"
  status=1
elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_digest_exercise.iyi" >"$WORK/mut.out" 2>&1; then
  echo "  the exercise PASSED on a broken module"
  status=1
else
  echo "  a broken digest is caught"
fi

# The checksums' costs, against the shapes they had: CRC-32 a bit at a
# time, Adler-32 reduced every byte.
cost_proof() { # cost_proof <label> <phrase> <old> <new>
  rm -rf "$WORK/costly"
  mkdir -p "$WORK/costly/std"
  if [ -z "$PY" ]; then
    echo "  no python3 on this machine, so the $1 proof is unmeasured"
    return
  fi
  if ! OLD="$3" NEW="$4" "$PY" - <<PY
import os
from pathlib import Path
src = Path("$REPO/src/std/digest.iyi").read_text()
if os.environ["OLD"] not in src:
    raise SystemExit("patch site missing")
Path("$WORK/costly/std/digest.iyi").write_text(src.replace(os.environ["OLD"], os.environ["NEW"], 1))
PY
  then
    echo "  the $1 patch did not apply"
    status=1
  elif IYI_PATH="$WORK/costly${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_digest_exercise.iyi" >"$WORK/costly.out" 2>&1; then
    echo "  the exercise PASSED on $1"
    status=1
  elif grep -q "$2" "$WORK/costly.out"; then
    echo "  $1 is caught"
  else
    echo "  $1 failed, but not at the cost check:"
    tail -2 "$WORK/costly.out" | sed 's/^/    /'
    status=1
  fi
}
cost_proof "a CRC-32 a bit at a time" "crc cost" \
  '    while i + 8 <= n
      one' \
  '    while i < n
      crc = crc ^ p[i].to_u32
      b = 0
      while b < 8
        crc = (crc & 1_u32) == 1_u32 ? crc.unsafe_shr(1) ^ 0xedb88320_u32 : crc.unsafe_shr(1)
        b = b + 1
      end
      i = i + 1
    end
    while i + 8 <= n
      one'
cost_proof "an Adler-32 reduced every byte" "adler cost" \
  '        a = a + p[i].to_u32
        b = b + a' \
  '        a = (a + p[i].to_u32) % 65521_u32
        b = (b + a) % 65521_u32'

echo
if [ "$status" -eq 0 ]; then
  echo "the std/digest exercise holds"
else
  echo "the std/digest exercise did not hold"
fi
exit $status
