#!/usr/bin/env bash
# Exercises `std/reference_storage`: manual memory storage for reference types.
#
#     bash bench/std_reference_storage_exercise.sh
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_reference_storage_exercise.iyi" \
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

echo "== the std/reference_storage exercise, plain build"
build_and_run "plain" reference_storage-plain
if ! grep -q "ALL CHECKS PASSED" "$WORK/reference_storage-plain.out" 2>/dev/null; then
  echo "plain: missing pass sentinel"
  status=1
fi

echo
echo "== every reference_storage section reported"
for phrase in \
  "== size and alignment" \
  "== stack allocation and unsafe_construct" \
  "== manual pre_initialize and initialize" \
  "== heap allocation and custom storage" \
  "== equality and hash" \
  "== uninitialized storage with a reference field" \
  "== string representation"; do
  if ! grep -q "$phrase" "$WORK/reference_storage-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  sections reported"

echo
echo "== the same program with optimisation on (--release)"
build_and_run "release" reference_storage-release --release >/dev/null
if ! grep -q "ALL CHECKS PASSED" "$WORK/reference_storage-release.out" 2>/dev/null; then
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
src = Path("$REPO/src/std/reference_storage.iyi").read_text()
old = 'obj.initialize(*args, **opts)'
if old not in src:
    raise SystemExit("patch site missing")
Path("$WORK/patched/std/reference_storage.iyi").write_text(src.replace(old, '# skipped init', 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_reference_storage_exercise.iyi" >"$WORK/mut.out" 2>&1; then
    echo "  the exercise PASSED on a broken module"
    status=1
  else
    echo "  a broken reference_storage is caught"
  fi
fi

echo
echo "== proving wrapping hash is required"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  mkdir -p "$WORK/patched_hash/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/reference_storage.iyi").read_text()
old = "h = (h &* 31) ^ to_reference.@{{ivar.id}}.hash"
if old not in src:
    raise SystemExit("hash patch site missing")
Path("$WORK/patched_hash/std/reference_storage.iyi").write_text(src.replace(old, "h = (h * 31) ^ to_reference.@{{ivar.id}}.hash", 1))
PY
  if [ $? -ne 0 ]; then
    echo "  the hash patch did not apply"
    status=1
  elif IYI_PATH="$WORK/patched_hash${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" run "$REPO/bench/std_reference_storage_exercise.iyi" >"$WORK/mut_hash.out" 2>&1; then
    echo "  the exercise PASSED on overflow-checked hash"
    status=1
  else
    echo "  overflow-checked hash is caught"
  fi
fi

echo
echo "== proving hash follows == field by field"
if [ -z "$PY" ]; then
  echo "  skipped: no working python3, so the broken copy could not be made"
else
  # The hash as it was: every byte of the instance, which is the sign bit of
  # a -0.0 and the address a String? holds, where == reads neither.
  mkdir -p "$WORK/patched_bytes/std"
  "$PY" - <<PY
from pathlib import Path
src = Path("$REPO/src/std/reference_storage.iyi").read_text()
start = src.find("  def hash : Int32\n")
stop = src.find("  def to_s : String")
if start < 0 or stop < start:
    raise SystemExit("hash patch site missing")
old_hash = "  def hash : Int32\n    h = 0\n    ptr = pointerof(@type_id).as(Pointer(UInt8))\n    i = 0\n    sz = instance_sizeof(T)\n    while i < sz\n      h = (h &* 31) ^ ptr[i].to_i32\n      i = i + 1\n    end\n    h\n  end\n\n"
Path("$WORK/patched_bytes/std/reference_storage.iyi").write_text(src[:start] + old_hash + src[stop:])
PY
  if [ $? -ne 0 ]; then
    echo "  the hash patch did not apply"
    status=1
  elif ! IYI_PATH="$WORK/patched_bytes${PSEP}$REPO/src${PSEP}$REPO/samples/iyi" "$IYI" build -o "$WORK/patched_bytes/program" "$REPO/bench/std_reference_storage_exercise.iyi" >"$WORK/patched_bytes/build.log" 2>&1; then
    echo "  the byte-hash copy did not compile"
    sed -n '1,6p' "$WORK/patched_bytes/build.log"
    status=1
  elif "$WORK/patched_bytes/program" >"$WORK/mut_bytes.out" 2>&1; then
    echo "  the exercise PASSED on a hash of the raw bytes"
    status=1
  elif ! grep -q "ASSERTION FAILED: 0.0 and -0.0 fields hash alike" "$WORK/mut_bytes.out"; then
    echo "  the byte hash failed, but not at '0.0 and -0.0 fields hash alike'"
    sed -n '$p' "$WORK/mut_bytes.out"
    status=1
  else
    echo "  a hash of the raw bytes is caught: 0.0 and -0.0 fields hash apart"
  fi
fi

echo
if [ "$status" -eq 0 ]; then
  echo "the std/reference_storage exercise holds"
else
  echo "the std/reference_storage exercise did not hold"
fi
exit $status
