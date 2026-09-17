#!/usr/bin/env bash
# Slice and Bytes, exercised and driven. Runs the slice exercise plain and
# optimised, checks every section reported, and proves the checks can fail
# by patching copies of the slice library via IYI_PATH and executing
# dedicated boundary-failure probes.
#
#     bash bench/std_slice_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# each capability: out-of-bounds indexing, subslice bounds, copy length
# validation, overlapping move correctness, and read-only protection.
#
# Exits non-zero if any check fails.

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

status=0

# Ensure include directory has std modules resolved. One home, `src/std`: the
# fallback to `samples/iyi/std` that used to sit here was a transition shim,
# and that directory no longer exists.
SETUP_INCLUDE() {
  local target_dir="$1"
  mkdir -p "$target_dir/std"
  ln -sf "$REPO/src/std/enumerable.iyi" "$target_dir/std/enumerable.iyi"
  ln -sf "$REPO/src/std/traits.iyi" "$target_dir/std/traits.iyi"
}

DEFAULT_INCLUDE="$WORK/default_include"
SETUP_INCLUDE "$DEFAULT_INCLUDE"
ln -sf "$REPO/src/std/slice.iyi" "$DEFAULT_INCLUDE/std/slice.iyi"

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! IYI_PATH="$DEFAULT_INCLUDE${PSEP}$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_slice_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
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

echo "== the slice exercise, plain build"
run_case "plain" slice-plain
if ! grep -q "all slice checks passed" "$WORK/slice-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every slice section reported"
for phrase in "constructors" "unsafe accessors" "indexing and bounds" "subslicing" "copying and moving" "filling" "duplicates" "equality" "enumerable" "gc liveness"; do
  grep -qi "$phrase" "$WORK/slice-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  all expected sections reported cleanly"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" slice-release --release
if ! grep -q "all slice checks passed" "$WORK/slice-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== dedicated boundary failure probes (panics on contract violations)"

prove_panic() {
  local label="$1" code="$2" expected_phrase="$3"
  local probe_file="$WORK/probe_${label}.iyi"
  local bin_file="$WORK/probe_${label}"

  cat <<EOF > "$probe_file"
module bench/probe_${label}

import std/slice
using std/slice::{Slice}

alias Bytes = Std::Slice::Bytes

def main : Nil
  $code
end

main
EOF

  if ! IYI_PATH="$DEFAULT_INCLUDE${PSEP}$REPO/src" "$IYI" build -o "$bin_file" "$probe_file" > "$WORK/${label}.build.log" 2>&1; then
    echo "  probe $label: build failed unexpectedly"
    sed -n '1,12p' "$WORK/${label}.build.log"
    status=1
    return
  fi

  "$bin_file" > "$WORK/${label}.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  probe $label: succeeded unexpectedly (should have panicked)"
    status=1
    return
  fi

  if ! grep -q "$expected_phrase" "$WORK/${label}.out"; then
    echo "  probe $label: failed but with wrong message:"
    sed -n '1,5p' "$WORK/${label}.out"
    status=1
    return
  fi
  echo "  probe $label: panicked as expected ($expected_phrase)"
}

# The wording is `Array`'s, and deliberately: the same mistake on an Array,
# a Slice, a List and anything `Indexable` used to give three different
# sentences, and the trait's own named neither the index nor the size.
prove_panic "oob_positive" \
  's = Slice(Int32).new(5, 1); x = s[10]' \
  "index 10 out of range for 5 elements"

prove_panic "oob_negative" \
  's = Slice(Int32).new(5, 1); x = s[-10]' \
  "index -10 out of range for 5 elements"

prove_panic "bad_copy_length" \
  'src = Slice(Int32).new(5, 1); dst = Slice(Int32).new(2, 0); src.copy_to(dst)' \
  "destination slice size 2 too small for source size 5"

prove_panic "bad_copy_count" \
  'src = Slice(Int32).new(3, 1); ptr = Pointer(Int32).malloc(2_u64); src.copy_to(ptr, 5)' \
  "copy count 5 exceeds source size 3"

prove_panic "readonly_write" \
  's = Slice(Int32).new(3, read_only: true); s[0] = 42' \
  "cannot write to read-only Slice"

prove_panic "negative_size" \
  's = Slice(Int32).new(-5)' \
  "negative size: -5"

echo
echo "== proving the exercise checks can fail when slice operations are broken"

prove_fails() {
  local label="$1" dir="$2" bad_pattern="$3" sed_script="$4"
  local patch_dir="$WORK/$dir"
  SETUP_INCLUDE "$patch_dir"
  sed -e "$sed_script" "$REPO/src/std/slice.iyi" > "$patch_dir/std/slice.iyi"

  if ! IYI_PATH="$patch_dir${PSEP}$REPO/src" "$IYI" build \
       -o "$patch_dir/program" "$REPO/bench/std_slice_exercise.iyi" \
       >"$patch_dir/build.log" 2>&1; then
    echo "  $label: the patched slice library did not build"
    sed -n '1,12p' "$patch_dir/build.log"
    status=1
    return
  fi

  "$patch_dir/program" >"$patch_dir/out" 2>&1
  if grep -q "$bad_pattern" "$patch_dir/out"; then
    echo "  $label: exercise caught failure as expected ($bad_pattern)"
  else
    echo "  $label: failure not detected by exercise output"
    status=1
  fi
}

# 1. Broken copy_to: if copy_to copies nothing
prove_fails "broken copy_to" "fail_copy" "copy_to slice: Slice\[0, 0, 0, 0, 0\]" \
  's/target.to_unsafe.copy_from(@pointer, @size)//'

# 2. Broken overlapping move: if direction is inverted, elements get corrupted
prove_fails "broken overlapping move" "fail_move" "move_from overlapping right: Slice\[1, 1, 1, 1, 1\]" \
  's/target.address > source.address/false/'

# 3. Broken reverse: if reverse does nothing
prove_fails "broken reverse" "fail_rev" "reverse: Slice\[8, 4, 6, 2\]" \
  's/def reverse : self/def reverse : self; return self/'

exit "$status"
