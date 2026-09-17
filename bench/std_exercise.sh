#!/usr/bin/env bash
# Standard library foundation, exercised and driven. Runs the std exercise
# plain and optimised (--release), checks every section reported, proves the
# checks can fail by patching copies of std via IYI_PATH, and discovers any
# sibling std exercises.
#
#     bash bench/std_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# each foundation capability: comparison operators, clamping, Enumerable
# presence, minmax, each_cons_pair, and to_h collection conversion.
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

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_exercise.iyi" \
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

echo "== the std exercise, plain build"
run_case "plain" std-plain
if ! grep -q "all std checks passed" "$WORK/std-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every std section reported"
for phrase in "std/traits:" "std/enumerable:" "std/list:" "std/derives:"; do
  grep -q "$phrase" "$WORK/std-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  traits, cmp, enumerable, list, and derives all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" std-release --release
if ! grep -q "all std checks passed" "$WORK/std-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when foundation is broken"

prove_fails() {
  local label="$1" dir="$2" file="$3" phrase="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  cp -R "$REPO/src/std/." "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/$file" > "$WORK/$dir/std/$file"
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched std library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at expected check (expected '$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. Comparable operator < inverted
prove_fails "Comparable < inverted" no_lt "traits.iyi" "Comparable: <" \
  's/(self <=> other) < 0/(self <=> other) > 0/'

# 2. Comparable clamp broken (returns max instead of min when low)
prove_fails "Comparable clamp broken" no_clamp "traits.iyi" "Comparable: clamp min" \
  's/return min if self < min/return max if self < min/'

# 3. Enumerable present? inverted
prove_fails "Enumerable present? inverted" no_present "enumerable.iyi" "enum: present? true" \
  's/!empty?/empty?/'

# 4. Enumerable minmax inverted
prove_fails "Enumerable minmax inverted" no_minmax "enumerable.iyi" "enum: minmax? min" \
  's/{low, high}/{high, low}/'

# 5. Enumerable each_cons_pair skips yields
prove_fails "Enumerable each_cons_pair broken" no_cons_pair "enumerable.iyi" "enum: each_cons_pair" \
  's/yield last, e unless last\.nil?/previous = nil/'

# 6. Enumerable to_h corrupted
prove_fails "Enumerable to_h corrupted" no_to_h "enumerable.iyi" "enum: to_h" \
  's/result\[pair\[0\]\] = pair\[1\]/result[pair[0]] = 0/'

# 7. String hash_key is the length
prove_fails "Hashable String hash_key is length" no_strhash "traits.iyi" "Hashable: String hash_key is the string" \
  's/hash # FNV, not the length/size/'

# 8. The rest of the tower's `hash`, which `impl Hashable` promised and did
#    not have: it lives in `std/int`, which `std/traits` did not import, so
#    `Int8#hash` was `Object#hash` — the type's id, one slot for every value
#    of the type. Renaming the definition puts the program back where it was,
#    and `Int8` is the first of the six the exercise asks.
prove_fails "the tower's hash falls back to the type id" no_inthash "int.iyi" "hash: Int8 values differ" \
  's/def hash : Int32/def hash_elsewhere : Int32/'

# 9. The same for both floats, whose `hash` lives in `std/float`.
prove_fails "Float64 hash falls back to the type id" no_floathash "float.iyi" "hash: Float64 values differ" \
  's/def hash : Int32/def hash_elsewhere : Int32/'

# 10. And the import itself is load-bearing, not decoration: `std/traits` is
#     the only module this exercise imports for the scalars, so taking the
#     `std/float` line out of it leaves both floats hashing to their type id
#     however complete `std/float` is.
prove_fails "traits without its std/float import" no_floatimport "traits.iyi" "hash: Float64 values differ" \
  's|^import std/float$||'

echo
echo "== one mistake, one sentence, whichever tower answers"
# `first` of an empty receiver, a negative count and a zero step used to be
# answered by a bare `empty`, by `[]`, and by two different sentences from
# two towers. A panicking program has no next line to assert on, so these
# are driven here rather than written into the exercise.
panics_with() { # panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  {
    printf 'module main\n\n'
    printf 'import std/list\nusing std/list::{List}\n'
    printf 'import std/enumerable\nusing std/enumerable::{Enumerable}\n'
    printf 'import std/iterator\nusing std/iterator::{Iterator, ArrayIterator}\n\n'
    printf 'puts (%s).to_s\n' "$expression"
  } > "$WORK/$name.iyi"
  if ! "$IYI" build -o "$WORK/$name" "$WORK/$name.iyi" > "$WORK/$name.build" 2>&1; then
    echo "  $label: the program did not build"
    sed -n '1,10p' "$WORK/$name.build"
    status=1
    return
  fi
  "$WORK/$name" > "$WORK/$name.out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: it answered instead of panicking"
    status=1
    return
  fi
  if ! grep -qF -- "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    sed -n '1,3p' "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" \
    "$(sed -n '1p' "$WORK/$name.out" | sed 's/^iyi: panic: //')"
}

panics_with "first of an empty list" first_empty "first of an empty collection" \
  'List(Int32).new([] of Int32).first'
panics_with "a negative count taken" take_negative "negative count: -1" \
  'List(Int32).new([1, 2, 3]).take(-1)'
panics_with "a negative count skipped" skip_negative "negative count: -1" \
  'List(Int32).new([1, 2, 3]).skip(-1)'
panics_with "a negative count, lazily" iter_take_negative "negative count: -1" \
  'ArrayIterator(Int32).new([1, 2, 3]).take(-1).to_a'
panics_with "a step of nothing" step_zero "step size must be positive" \
  'ArrayIterator(Int32).new([1, 2, 3]).step(0).to_a'
panics_with "a step of nothing, eagerly" each_step_zero "step size must be positive" \
  'List(Int32).new([1, 2, 3]).each_step(0) { |x| x }'
panics_with "an index past a list" list_index "index 7 out of range for 3 elements" \
  'List(Int32).new([1, 2, 3])[7]'

echo
echo "== the library is iyi all the way down"
# Three modules reach the platform themselves. Two were written before the
# rule: `socket` (raw syscalls on Linux, libSystem on darwin, SPEC.md III.9)
# and `time` (the clocks). `math` may name the three LLVM hardware intrinsics
# `llvm.sqrt`, `llvm.copysign` and `llvm.fma` (the instruction, not libm).
#
# `debug` is the third, and it is a deliberate exception rather than an
# oversight. It resolves a panic's frames to `file:line:column` by reading the
# program's own DWARF, and finding those bytes is not something the prelude's
# intrinsics can do: it needs the image's load address and ASLR slide
# (`_dyld_get_image_vmaddr_slide`), the executable's path
# (`_NSGetExecutablePath`, `dladdr`), and the file mapped to read it
# (`open`, `mmap`, `munmap`, `lseek`, `close`). Every one of those is in
# libSystem, the platform libc `bench/dependency_floor.sh` already permits, so
# this costs no library: a program importing `std/debug` still links
# libSystem and nothing else, which the floor checks separately.
#
# `file`, `dir` and `udp` are platform modules of `socket`'s shape: raw
# syscalls on Linux, libSystem on darwin, and the floor names every symbol
# they add there.
#
# `random` joined them for Windows alone: `/dev/urandom` is a file on the
# POSIX targets and there is no such path there, so its win32 arm asks the
# OS for the bytes. Before that arm, `Random.new` panicked on Windows and
# took `std/uuid`, `Array#sample` and `#shuffle` with it.
#
# Every other module is iyi over the prelude's own intrinsics: no `lib`,
# no `fun`, no inline `asm`, no `@[Link]`. A binding that appears anywhere
# else is a dependency being taken on without a word.
# An exemption is permission to reach the *platform*, not permission to reach
# anything. The exempt modules used to be skipped outright, so `@[Link("yaml")]`
# added to `std/socket` was seen by nothing here: the library floor catches it
# only once a program reaches it and links libyaml, and a declaration nothing
# reaches yet is exactly what this loop exists to name. So they are checked
# too, against the libraries the platform supplies.
PLATFORM_LIBS='LibC|LibSystem|LibKernel32|LibWasi|LibLLVMMath|LibAdvapi32|LibWs2_32'
# The `@[Link]`s an exempt module may carry: the DLLs Windows itself ships,
# named in SPEC.md III.10's inventory. `std/random` is here for `advapi32` —
# the OS entropy `Random.new` seeds from is `RtlGenRandom`, and Windows has
# no kernel32 name for it — and `std/socket` and `std/udp` for `ws2_32`,
# because Winsock is the whole of Windows' network interface and a socket
# call has nowhere else to come from. Everything else in this list reaches
# the platform through a `lib` block alone.
PLATFORM_LINKS='@\[Link\("(kernel32|advapi32|ws2_32)"\)\]'
reaching=""
foreign=""
for source in "$REPO"/src/std/*.iyi; do
  name="$(basename "$source" .iyi)"
  case "$name" in
    socket|time|debug|file|dir|udp|random)
      # Named libraries only: a `lib` block of platform bindings is the
      # exemption, an `@[Link]` to something the platform does not supply is
      # not covered by it.
      grep -nE '^\s*(lib [A-Z]|@\[Link)' "$source" \
        | grep -vE "lib ($PLATFORM_LIBS)\b" \
        | grep -vE "$PLATFORM_LINKS" > "$WORK/foreign.$name" || true
      if [ -s "$WORK/foreign.$name" ]; then
        foreign="$foreign $name"
        echo "  std/$name is exempt for the platform, and this is not the platform:"
        sed 's/^/    /' "$WORK/foreign.$name"
      fi
      continue
      ;;
  esac
  if [ "$name" = math ]; then
    grep -nE '^\s*(lib [A-Z]|fun [a-z_]|asm\(|@\[Link)' "$source" \
      | grep -vE 'llvm\.(sqrt|copysign|fma)\.' > "$WORK/reach.$name" || true
  else
    grep -nE '^\s*(lib [A-Z]|fun [a-z_]|asm\(|@\[Link)' "$source" > "$WORK/reach.$name" || true
  fi
  if [ -s "$WORK/reach.$name" ]; then
    reaching="$reaching $name"
    echo "  std/$name reaches past the prelude:"
    sed 's/^/    /' "$WORK/reach.$name"
  fi
done
if [ -n "$reaching" ]; then
  echo "  FAIL: a std module other than socket and time binds something"
  status=1
elif [ -n "$foreign" ]; then
  echo "  FAIL: an exempt std module binds something the platform does not supply"
  status=1
else
  echo "  every module but socket and time is iyi over the prelude's intrinsics,"
  echo "  and those reach the platform and nothing else"
fi

echo
echo "== every module has its own exercise"
# A module `iyi check` accepts is not a module that works: a generic body
# nobody instantiates is never typed. The exercise is what instantiates it.
ungated=""
for source in "$REPO"/src/std/*.iyi; do
  name="$(basename "$source" .iyi)"
  case "$name" in traits|cmp|enumerable|list|derives) continue ;; esac # this file's own
  gate="$REPO/bench/std_${name}_exercise.sh"
  case "$name" in format|socket) gate="$REPO/bench/${name}_exercise.sh" ;; esac # named before the prefix
  [ -f "$gate" ] || ungated="$ungated $name"
done
if [ -n "$ungated" ]; then
  echo "  FAIL: no bench/std_<name>_exercise.sh for:$ungated"
  status=1
else
  echo "  each module under src/std has a bench/std_<name>_exercise.sh"
fi

echo
echo "== discovering and running sibling std exercises"
found_siblings=0
for sibling in "$REPO"/bench/std_*_exercise.sh; do
  [ -f "$sibling" ] || continue
  [ "$(basename "$sibling")" = "std_exercise.sh" ] && continue
  found_siblings=$((found_siblings + 1))
  echo "-- running sibling: $(basename "$sibling")"
  if ! bash "$sibling"; then
    echo "FAIL: sibling $(basename "$sibling") failed"
    status=1
  fi
done
if [ "$found_siblings" -eq 0 ]; then
  echo "  (no sibling exercises found yet)"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "Standard library foundation: traits, cmp, enumerable (71 methods), list,"
  echo "and derives all pass plain and optimised, and each check is proven"
  echo "to fail when its mechanism is broken."
else
  echo "Standard library foundation: something above failed."
fi
exit "$status"
