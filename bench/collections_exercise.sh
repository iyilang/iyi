#!/usr/bin/env bash
# The prelude's collections at their edges: `Array`, `Hash` and `Set`.
#
#     bash bench/collections_exercise.sh
#
# `bench/collections_exercise.iyi` is the program, run plain and optimised.
# Then the panics an empty receiver answers with are driven here - a
# panicking program has no next line to assert on - and then each check is
# proved capable of failing by patching a *copy of the prelude* and building
# against it through `IYI_PATH`. A check that cannot fail is not a check.
#
# The defect this gate was written for: `a.concat(a)`. `each` walked
# *other*'s size while `<<` grew it, so appending an array to itself never
# reached the end; it grew the buffer until the capacity arithmetic
# overflowed, and `[1, 2].concat(itself)` died of "arithmetic overflow".
#
# Exits non-zero if any check fails or if any patch leaves the exercise green.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrapper in bin is a posix shell script, so a caller that already has a
# compiler of its own names it through the environment.
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

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

trap 'rm -rf "$WORK"' EXIT

status=0

run_case() { # run_case <label> <name> [build flags...]
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/collections_exercise.iyi" \
       > "$WORK/$name.build" 2>&1; then
    echo "  $label: the exercise did not build"
    sed -n '1,12p' "$WORK/$name.build"
    status=1
    return
  fi
  if ! "$WORK/$name" > "$WORK/$name.out" 2>&1; then
    echo "  $label: the exercise panicked"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  if ! grep -q "all collection checks passed" "$WORK/$name.out"; then
    echo "  $label: the exercise ended without passing"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  echo "  $label: every check held"
}

echo "== the collections, plain"
run_case "plain" plain

echo
echo "== and with optimisation on (--release)"
run_case "release" release --release

echo
echo "== an empty receiver, which is a panic with a name on it"

panics_with() { # panics_with <label> <name> <phrase> <expression>
  local label="$1" name="$2" phrase="$3" expression="$4"
  printf 'module main\n\nputs (%s).to_s\n' "$expression" > "$WORK/$name.iyi"
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
  if [ "$code" -ne 1 ]; then
    echo "  $label: died with exit $code rather than a panic"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$name.out"; then
    echo "  $label: panicked, but not with '$phrase'"
    tail -2 "$WORK/$name.out"
    status=1
    return
  fi
  printf '  %s: exits 1 at "%s"\n' "$label" "$(grep -m1 -o "$phrase.*" "$WORK/$name.out")"
}

panics_with "pop of an empty array" pop_empty "pop of an empty array" "([] of Int32).pop"
panics_with "shift of an empty array" shift_empty "shift of an empty array" "([] of Int32).shift"
panics_with "first of an empty array" first_empty "first of an empty array" "([] of Int32).first"
panics_with "last of an empty array" last_empty "last of an empty array" "([] of Int32).last"
panics_with "an index past the end" index_past "out of range for 2 elements" "[1, 2][5]"
panics_with "an index before the start" index_before "out of range for 2 elements" "[1, 2][-5]"
panics_with "a key nobody put in" missing_key "no such key" "({} of Int32 => Int32)[5]"
panics_with "a negative count" negative_count "negative count" "[1, 2].first(-1).size"
# A zip with a shorter array is refused, as the other library refuses it:
# the pairs stopped at the shorter, and the third element went unsaid.
panics_with "a zip with a shorter array" zip_shorter "index 2 out of range for 2 elements" "[1, 2, 3].zip([4, 5]).size"
panics_with "a block zip with a shorter array" zip_block_shorter "index 2 out of range for 2 elements" "[1, 2, 3].zip([4, 5]) { |a, b| a + b }"

echo
echo "== proving the checks can fail, one broken method at a time"

# A copy of the whole prelude with one method patched, on `IYI_PATH` ahead of
# the real one. The patch has to change the file - a sed that matched nothing
# would otherwise read as a pass - and the exercise then has to exit non-zero
# at the check that names the method.
prove_fails() { # prove_fails <label> <dir> <file> <phrase> <sed script>
  local label="$1" dir="$2" file="$3" phrase="$4" script="$5"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/$file" > "$WORK/$dir/iyi/$file"
  if cmp -s "$REPO/src/iyi/$file" "$WORK/$dir/iyi/$file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/collections_exercise.iyi" \
       > "$WORK/$dir/build" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,10p' "$WORK/$dir/build"
    status=1
    return
  fi

  # A patch can also hang the exercise - the defect this gate was written
  # for did exactly that until the arithmetic caught it - so the run is
  # given a bound.
  timeout 20 "$WORK/$dir/program" > "$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if [ "$code" -eq 124 ]; then
    printf '  %s: the exercise stopped answering (timed out)\n' "$label"
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at the expected check (wanted '$phrase')"
    tail -2 "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$code" \
    "$(grep -m1 -o "$phrase.*" "$WORK/$dir/out" | sed 's/^assert failed: //')"
}

# 1. `concat` reading the other array's size as it grows, which is the defect.
prove_fails "a default is ignored" no_default hash.iyi \
  'no such key "z"' \
  's/^      if default = @default$/      if default = nil/'

prove_fails "the fill form fills nothing" no_fill array.iyi \
  "array: filled has the size asked" \
  's/^    new(size) { |index| value }$/    Array(T).new(0)/'

prove_fails "concat reads a growing size" grow_concat array.iyi \
  "array: concat with itself doubles" \
  's/^    taking = other.size$/    taking = 1/'

prove_fails "a sort that compares every pair" quadratic_sort array.iyi \
  "array: a sort of 100,000 made" \
  's/^  SORT_RUN = 16$/  SORT_RUN = 1073741824/'

prove_fails "a merge that takes the right run on a tie" unstable_sort array.iyi \
  "array: a sort is ascending and keeps equal elements in order" \
  's/(yield from\[left\], from\[right\]) <= 0/(yield from[left], from[right]) < 0/'

prove_fails "a sort that asks == after <" two_question_sort array.iyi \
  "array: sorted asks one question a step" \
  's/^    sorted { |a, b| b < a ? 1 : 0 }$/    sorted { |a, b| a < b ? -1 : (a == b ? 0 : 1) }/'

prove_fails "a key sort that asks < both ways" two_way_key_sort array.iyi \
  "array: sorted_by asks < as often as sorted" \
  's/^    keyed.sort_in_place { |a, b| b\[0\] < a\[0\] ? 1 : 0 }$/    keyed.sort_in_place { |a, b| a[0] < b[0] ? -1 : (b[0] < a[0] ? 1 : 0) }/'

prove_fails "an Int64 hashed by its type" int64_type_hash number.iyi \
  "hash: Int64 keys spread" \
  '/^struct Int64$/,/^end$/{/^  def hash : Int32$/,/^  end$/d;}'

prove_fails "an instance that is not itself" no_identity primitives.iyi \
  "reference: an instance equals itself" \
  '/^class Reference$/,/^end$/{/^  def ==(other : Reference) : Bool$/,/^  end$/d;}'

prove_fails "instances hashed by their type" type_hash primitives.iyi \
  "reference: instances hash apart" \
  's/^      (object_id.unsafe_shr(4_u64) ^ object_id.unsafe_shr(36_u64)).unsafe_to_i32$/      crystal_type_id/'

# 2. A key written twice making two entries, which is what a `[]=` that does
#    not look first would do.
prove_fails "a rewritten key appends" double_write hash.iyi \
  "hash: a key written twice is one entry" \
  's/^    slot = slot_for(key)$/    slot = slot_for(key); @index[slot] = -1/'

# 3. A delete that frees its index slot rather than leaving a tombstone: a
#    key that probed past the deleted one is no longer found.
prove_fails "a delete frees its slot" freed_slot hash.iyi \
  "hash: the rest are findable" \
  's/^    @index\[slot\] = -2$/    @index[slot] = -1/'

# 4. `each` walking the gone entries as well as the live ones.
prove_fails "each walks the gone entries" each_gone hash.iyi \
  "hash: each counts what size says" \
  's/^      yield @keys\[entry\], @values\[entry\] unless @gone.address != 0_u64 \&\& @gone\[entry\]$/      yield @keys[entry], @values[entry]/'

# 4b. `each` from entry 0 again, over every key deleted at the front.
prove_fails "each starts before the gone at the front" each_from_zero hash.iyi \
  "hash: 40,000 oldest keys taken in" \
  's/^    entry = @first$/    entry = 0/'

# 5. A set that keeps duplicates, which is the one thing a set is.
prove_fails "a set forgets its members" dup_set set.iyi \
  "set: the other one is still in" \
  's/^  def includes?(value : T) : Bool$/  def includes?(value : T) : Bool\n    return false/'

# 6. A negative index that does not wrap, so `a[-1]` is not the last.
prove_fails "a negative index does not wrap" no_wrap array.iyi \
  "out of range for 3 elements" \
  's/^    index = @size + index if index < 0$/    index = @size + index if false/'

# 7. `uniq` keeping everything, which the collection checks read.
prove_fails "uniq keeps everything" no_uniq array.iyi \
  "array: uniq" \
  '/^  def uniq : Array(T)$/,/^  end$/{/^      next if seen.has_key?(value)$/d;}'

# 7b. `shift` moving the rest down, as it did: draining a queue of 300,000
#     is then quadratic, and the exercise stops answering.
prove_fails "shift moves the rest down" moving_shift array.iyi \
  "array: a queue of 300,000 drains" \
  's/^    @buffer = @buffer + 1$/    index = 1; while index < @size; @buffer[index - 1] = @buffer[index]; index = index + 1; end/; /^    @capacity = @capacity - 1$/d'

# 8. `pop` that does not shrink, so the size and the elements disagree.
prove_fails "pop does not shrink" no_shrink array.iyi \
  "array: five hundred pops" \
  's/^    @size = @size - 1$/    @size = @size - 0/'

# 9. The inclusive walk stepping past its own end again, which is what
#    panicked at the type's maximum.
prove_fails "the range walk steps past its end" past_end range.iyi \
  "arithmetic overflow" \
  's/^    yield value if !@exclusive \&\& value == @end$/    yield value if !@exclusive \&\& value <= @end \&\& (value = value + 1) < 0/'

# 10. A tuple hashed as `a * 31 + b` again, members barely mixed.
prove_fails "a tuple hash that barely mixes" weak_tuple object.iyi \
  "hash: a 300 by 300 grid of tuples spreads" \
  's/^      value = (value ^ self\[{{i}}\].hash.to_i64.unsafe_to_u64) \&\* 0x100000001B3_u64$/      value = (value \&* 31_u64) \&+ self[{{i}}].hash.to_i64.unsafe_to_u64/; /^      value = value ^ value.unsafe_shr(29_u64)$/d'

# 11. An array without a hash of its own, so `Reference#hash` answers.
prove_fails "an array hashed by its type" type_hashed_array array.iyi \
  "hash: a 300 by 300 grid of arrays spreads" \
  's/^    value.hash$/    crystal_type_id/'

# 12. `max_by` reading its keys with `<` alone, so a NaN key never wins.
prove_fails "max_by passes over a NaN key" nan_max_by array.iyi \
  "array: max_by of a NaN key is the NaN" \
  's/^      if best_key < key || (key.is_a?(Float) \&\& key != key \&\& best_key == best_key)$/      if best_key < key/'

echo
echo "== and what an empty receiver says when it is asked for a size"
panics_with "a negative capacity" neg_cap "negative capacity" "Array(Int32).new(-1).size"

echo
if [ "$status" -eq 0 ]; then
  echo "Collections: a key is one entry however often it is written, a delete"
  echo "leaves the rest findable, a crowded slot is still searched, an array"
  echo "appended to itself doubles, and an empty receiver panics with a name."
else
  echo "the collection surface does not hold"
fi
exit "$status"
