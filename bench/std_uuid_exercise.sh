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
for phrase in "== parse" "== hash" "== v4" "== v7"; do
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
echo "== proving the value check can fail when the bytes are shared again"
# Held as the caller's array, a UUID changed with the buffer it was made from.
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/uuid.iyi").read_text()
old = '@bytes = bytes.dup'
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/uuid.iyi").write_text(src.replace(old, '@bytes = bytes', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_uuid_exercise.iyi" >"$WORK/mut-value.out" 2>&1; then
    echo "  the exercise PASSED with the caller's array kept"
    status=1
  elif grep -qF "a UUID keeps its bytes when the buffer it was made from is reused" "$WORK/mut-value.out"; then
    echo "  a UUID sharing its caller's array is caught"
  else
    echo "  the broken copy failed somewhere other than the value check"
    sed -n '1,5p' "$WORK/mut-value.out"
    status=1
  fi
fi

echo
echo "== what parse refuses"
# A hyphen anywhere but 8, 13, 18 and 23 of the 36: every `-` was taken
# out wherever it stood, and these were read as UUIDs. A probe program per
# text, built against SEARCH - the module under test, unless the proof
# below points it at a broken copy.
SEARCH="$IYI_PATH"
refuses() { # refuses <label> <name> <phrase> <text>
  local label="$1" name="$2" phrase="$3" text="$4"
  printf 'module main\n\nimport std/uuid::{UUID}\n\nputs UUID.parse(%s).to_s\n' "$text" > "$WORK/$name.iyi"
  if ! IYI_PATH="$SEARCH" "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of refusing: $(cat "$WORK/$name.out")"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: refused, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}
refuses "a hyphen past the end" trailing "UUID: not 32 hex digits" '"550e8400-e29b-41d4-a716-446655440000-"'
refuses "a hyphen one place early" early "UUID: not 32 hex digits" '"550e840-0e29b-41d4-a716-446655440000"'
refuses "a hyphen inside the first group" inside "UUID: not 32 hex digits" '"5-50e8400e29b41d4a716446655440000"'

echo
echo "== proving the refusals can fail when the module is broken"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  rm -rf "$WORK/patched"
  mkdir -p "$WORK/patched/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/uuid.iyi").read_text()
old = 'out << ch unless hyphenated && (k == 8 || k == 13 || k == 18 || k == 23)'
if src.count(old) != 1:
    raise SystemExit("patch site missing or not unique")
Path("$WORK/patched/std/uuid.iyi").write_text(src.replace(old, "out << ch unless ch == '-'", 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  else
    # The same check, run on the copy that takes every hyphen out again: it
    # must report the answer, which a copy that did not compile cannot give.
    said="$(SEARCH="$WORK/patched${PSEP}$IYI_PATH"; refuses "every hyphen taken out" loose "UUID: not 32 hex digits" '"550e8400-e29b-41d4-a716-446655440000-"')"
    if printf '%s\n' "$said" | grep -qF "it answered instead of refusing"; then
      echo "  every hyphen taken out again: caught"
    else
      echo "  every hyphen taken out again: the refusal check held on a broken module"
      printf '%s\n' "$said" | sed 's/^/  /'
      status=1
    fi
  fi
fi

echo
echo "== proving the random bits come from Random::Secure"
# Each case writes a patched std/random and/or std/uuid and names what the
# exercise must then do: pass, or fail at the check written for it. The
# control case seeds every `Random.new` with one constant and must still
# pass, which only a v4 that does not draw from `Random.new` can; the same
# constant with v4 drawing from a PCG generator again, as it did, must be
# caught by its repeats. A secure source that answers nothing, a v7 whose
# counter stands still and a v7 stamped with the wrong version must each
# be caught as well.
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  for label in control pcg constant counter version7; do
    rm -rf "$WORK/patched"
    mkdir -p "$WORK/patched/std"
    expect="$(PROOF="$label" "$PY" - <<PY
import os
from pathlib import Path
random_src = Path("$REPO/src/std/random.iyi").read_text()
uuid_src = Path("$REPO/src/std/uuid.iyi").read_text()
constant_seed = ("new(entropy, entropy)", "new(1_u64, 1_u64)")
pcg_v4 = ("    bytes = Random::Secure.random_bytes(16)\n    bytes[6] = (bytes[6] & 0x0f_u8) | 0x40_u8",
          "    rng = Random.new\n    bytes = Array(UInt8).new(16) { (rng.next_u & 255_u32).to_u8 }\n"
          "    bytes[6] = (bytes[6] & 0x0f_u8) | 0x40_u8")
silent = ("    return if count == 0\n", "    return\n")
cases = {
    "control": ([constant_seed], [], "PASS"),
    "pcg": ([constant_seed], [pcg_v4], "v4 UUIDs repeat"),
    "constant": ([silent], [], "v4 UUIDs repeat"),
    "counter": ([], [("@@v7_counter = @@v7_counter + 1", "@@v7_counter = @@v7_counter + 0")], "v7 sorts after the one before it"),
    "version7": ([], [("bytes[6] = (0x70 | ", "bytes[6] = (0x40 | ")], "v7 version"),
}
random_patches, uuid_patches, expect = cases[os.environ["PROOF"]]
for patches, src, name in ((random_patches, random_src, "random"), (uuid_patches, uuid_src, "uuid")):
    if not patches:
        continue
    for old, new in patches:
        if src.count(old) != 1:
            raise SystemExit(f"patch site missing or not unique in {name}: {old!r}")
        src = src.replace(old, new, 1)
    Path(f"$WORK/patched/std/{name}.iyi").write_text(src)
print(expect)
PY
)"
    if [ $? -ne 0 ]; then
      echo "  $label: the patch did not apply"
      status=1
      continue
    fi
    IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_uuid_exercise.iyi" >"$WORK/mut-source.out" 2>&1
    code=$?
    if [ "$expect" = "PASS" ]; then
      if [ "$code" -eq 0 ] && grep -q "ALL CHECKS PASSED" "$WORK/mut-source.out"; then
        echo "  $label: every Random.new seeded alike, and v4 is still unique - it does not draw from Random.new"
      else
        echo "  $label: the exercise failed with every Random.new seeded alike, so v4 still draws from it"
        sed -n '1,3p' "$WORK/mut-source.out" | sed 's/^/    /'
        status=1
      fi
    elif [ "$code" -eq 0 ]; then
      echo "  $label: the exercise PASSED on a broken module"
      status=1
    elif ! grep -qF -- "$expect" "$WORK/mut-source.out"; then
      echo "  $label: failed, but not at the check written for it ($expect):"
      sed -n '1,3p' "$WORK/mut-source.out" | sed 's/^/    /'
      status=1
    else
      echo "  $label: caught - $(grep -m1 'panic' "$WORK/mut-source.out" | sed 's/^iyi: panic: //' | cut -c1-110)"
    fi
  done
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/uuid exercise holds"
else
  echo "the std/uuid exercise did not hold"
fi
exit $status
