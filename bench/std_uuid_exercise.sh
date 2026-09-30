#!/usr/bin/env bash
# Exercises `std/uuid`.
#
#     bash bench/std_uuid_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_uuid_exercise.iyi" \
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

echo "== the std/uuid exercise, plain build"
build_and_run "plain" uuid-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/uuid-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every uuid section reported"
for phrase in "== parse"; do
  if ! grep -q "$phrase" "$WORK/uuid-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" uuid-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/uuid-release.out" 2>/dev/null; then
  echo "release: missing pass sentinel"
  status=1
fi

echo
echo "== what parse refuses"
# A hyphen belongs at four places of the 36-character form and nowhere
# else: every hyphen was dropped wherever it stood, so a 37-character
# string with a hyphen run at its end read as a UUID.
cat >"$WORK/refuse.iyi" <<'IYI'
module refuse

import std/uuid::{UUID}

puts UUID.parse(Program.args[0]).to_s
IYI
for bad in "6ba7b8109dad11d180b4-00c04fd430c8----" "550e8400e29b-41d4-a716-446655440000-" "550e8400-e29b41d4-a716-4466-55440000" "550e8400-e29b-41d4-a716-44665544000"; do
  if "$IYI" run "$WORK/refuse.iyi" -- "$bad" >"$WORK/refuse.out" 2>&1; then
    echo "  $bad was read as $(cat "$WORK/refuse.out")"
    status=1
  elif ! grep -q "UUID:" "$WORK/refuse.out"; then
    echo "  $bad was refused without saying why: $(tail -1 "$WORK/refuse.out")"
    status=1
  else
    echo "  $bad: $(tr -d '\r' <"$WORK/refuse.out" | grep -o 'UUID:.*' | head -1)"
  fi
done

echo
echo "== proving the checks can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/uuid.iyi").read_text()
old = 'bytes[6] = (bytes[6] & 0x0f_u8) | 0x40_u8'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/uuid.iyi").write_text(src.replace(old, 'bytes[6] = bytes[6] & 0x0f_u8', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_uuid_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken uuid is caught"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/uuid exercise holds"
else
  echo "the std/uuid exercise did not hold"
fi
exit $status
