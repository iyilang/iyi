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
# 0.18 added what a program asks of the two beyond that: an array's spans by
# start and count and by range (either end negative, endless, beginless,
# past the end), setting and truncating them, `push`, `unshift`, `pop?`,
# `first?`, `last(n)`, `flatten`, `transpose`, `-`, `&`, `|`, `*` and `uniq`
# by a key; a table's `fetch`, `dig`, `merge`, `update`, transforms,
# `select`/`reject` and their in-place forms, `shift`, `put_if_absent`,
# `clear`, `dup`, the block questions, and `==` and `hash` over its pairs in
# any order. Each section has its refusal driven below and a patch that
# breaks it.
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
# The spans and the 0.18 tables refuse what has no answer, each with a
# sentence that names what was asked.
panics_with "a span starting past the end" span_past "index 4 out of range for 3 elements" "[1, 2, 3][4, 1]"
panics_with "a range starting past the end" range_past "range 4.. out of range for 3 elements" "[1, 2, 3][4..]"
panics_with "a range starting before the start" range_before "range -4..-1 out of range for 3 elements" "[1, 2, 3][-4..-1]"
panics_with "a span with a negative count" span_negative "negative count: -1" "[1, 2, 3][0, -1]?"
panics_with "a span set past the end" set_past "index 5 out of range for 3 elements" "[1, 2, 3][5, 0] = 9"
panics_with "a repeat a negative number of times" repeat_negative "negative count: -2" "[1] * -2"
panics_with "the last of a negative count" last_negative "negative count: -1" "[1].last(-1)"
panics_with "rows of unequal size" ragged "transpose of rows of unequal size: row 1 has 1 elements, row 0 has 2" "[[1, 2], [3]].transpose"
panics_with "a value no key has" no_key_for "no key for the value 2" "{\"a\" => 1}.key_for(2)"
panics_with "a shift of an empty table" hash_shift_empty "shift of an empty hash" "({} of String => Int32).shift"
panics_with "the first key of an empty table" first_key_empty "first_key of an empty hash" "({} of String => Int32).first_key"
panics_with "an update of a missing key" update_missing "no such key \"b\"" "{\"a\" => 1}.update(\"b\") { |v| v }"
panics_with "a dig past a value" dig_past "the value at \"a\" is not a table to dig into" "{\"a\" => 1}.dig(\"a\", \"b\")"
panics_with "a dig of a missing key" dig_missing "no such key \"q\"" "{\"a\" => {\"b\" => 1}}.dig(\"q\", \"b\")"
panics_with "values_at of a missing key" values_at_missing "no such key \"z\"" "{\"a\" => 1}.values_at(\"a\", \"z\")"

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

# 13. The spans: an inclusive end treated as exclusive, a start at `size`
#     refused where it is the empty tail, a span set from itself read after
#     it moved, a gap not closed, and truncate keeping the front.
prove_fails "an inclusive range drops its end" inclusive_end array.iyi \
  "array: an inclusive range keeps its end" \
  's/^      stop = stop + 1$/      stop = stop + 0/'

prove_fails "a start at the end is refused" start_at_end array.iyi \
  "array: a start at the end is the empty tail, for \[\]? too" \
  's/^    return nil if index < 0 || index > @size$/    return nil if index < 0 || index >= @size/'

prove_fails "a range start at the end is refused" range_at_end array.iyi \
  "array: a range starting at the end is empty" \
  's/^    return nil if start < 0 || start > @size$/    return nil if start < 0 || start >= @size/'

prove_fails "a span set from itself is read as it moves" self_splice array.iyi \
  "array: a span set from itself reads a copy" \
  's/^    source = values.object_id == object_id ? values.dup : values$/    source = values/'

prove_fails "a shorter span leaves the gap" open_gap array.iyi \
  "array: a span set to one value" \
  's/^        @buffer\[at - count + length\] = @buffer\[at\]$/        @buffer[at - count + length] = @buffer[at - count + length]/'

prove_fails "truncate keeps the front" truncate_front array.iyi \
  "array: truncate keeps the span" \
  's/^    @buffer = @buffer + start$//'

# 14. push, unshift, pop?, first?, last(n).
prove_fails "push of several keeps the last" push_last array.iyi \
  "array: push one and several" \
  's/^    splice(@size, 0, values.size) { |at| values\[at\] }$/    self << values[values.size - 1]/'

prove_fails "unshift appends" unshift_back array.iyi \
  "array: unshift one and several" \
  's/^    splice(0, 0, 1) { |_| value }$/    self << value/'

prove_fails "pop? answers nothing" pop_nothing array.iyi \
  "array: pop? answers the last" \
  's/^    empty? ? nil : pop$/    nil/'

prove_fails "first? answers nothing" first_nothing array.iyi \
  "array: first? answers the first" \
  's/^    empty? ? nil : @buffer\[0\]$/    nil/'

prove_fails "last n is the first n" last_first array.iyi \
  "array: last n" \
  's/^    copy_span(@size - count, count)$/    copy_span(0, count)/'

# 15. flatten one level deep, transpose that copies the first column.
prove_fails "flatten stops a level down" shallow_flatten array.iyi \
  "array: flatten goes all the way down" \
  's/^      value.each { |inner| flatten_into(result, inner) }$/      value.each { |inner| flatten_into(result, inner) unless inner.is_a?(Array) }/'

prove_fails "transpose repeats the first column" first_column array.iyi \
  "array: transpose" \
  's/^      each { |row| line << row\[column\] }$/      each { |row| line << row[0] }/'

# 16. The array algebra and `uniq` by a key.
prove_fails "- removes nothing" minus_short array.iyi \
  "array: - keeps duplicates and order" \
  's/^      each { |value| result << value unless other.includes?(value) }$/      each { |value| result << value }/'

prove_fails "- against a long array removes nothing" minus_long array.iyi \
  "array: - against a long array" \
  's/^      each { |value| result << value unless present.has_key?(value) }$/      each { |value| result << value }/'

prove_fails "& keeps duplicates" and_twice array.iyi \
  "array: & keeps each once" \
  '/^      present.delete(value)$/d'

prove_fails "| keeps duplicates" or_twice array.iyi \
  "array: | keeps each once" \
  '/^  def |(other : Array(U)) : Array(T | U) forall U$/,/^  end$/{/^      next if seen.has_key?(value)$/d;}'

prove_fails "* repeats once" repeat_once array.iyi \
  "array: \* repeats" \
  's/^    while round < times$/    while round < 1/'

prove_fails "uniq by a key keeps everything" uniq_key array.iyi \
  "array: uniq by a key keeps the first of each" \
  '/^  def uniq(& : T -> U) : Array(T) forall U$/,/^  end$/{/^      next if seen.has_key?(key)$/d;}'

# 17. The table's lookups: fetch that answers its default for a key that is
#     there, dig? that stops at the first level.
prove_fails "fetch answers the default" fetch_default hash.iyi \
  "hash: fetch answers the value" \
  's/^    entry < 0 ? default : @values\[entry\]$/    default/'

prove_fails "dig? stops at the first level" dig_shallow hash.iyi \
  "hash: dig? goes down" \
  's/^    value.responds_to?(:dig?) ? value.dig?(\*subkeys) : nil$/    nil/'

# 18. merge where the first value wins, merge's block ignored, update that
#     answers the new value, transforms in place that skip the oldest.
prove_fails "merge keeps the first value" merge_first hash.iyi \
  "hash: merge, the second value wins" \
  's/^    other.each { |key, value| self\[key\] = value }$/    other.each { |key, value| self[key] = value unless has_key?(key) }/'

prove_fails "merge's block is not asked" merge_block hash.iyi \
  "hash: merge with a block" \
  's/^        @values\[entry\] = yield key, @values\[entry\], value$/        @values[entry] = value/'

prove_fails "update answers the new value" update_new hash.iyi \
  "hash: update answers the old value" \
  's/^      return old$/      return @values[entry]/'

prove_fails "the entry walk skips the oldest" entry_walk hash.iyi \
  "hash: transform_values_in_place" \
  's/^    at = @first$/    at = @first + 1/'

# 19. select_in_place that rejects, key_for that answers the first other,
#     compact that keeps nothing, count that counts everything.
prove_fails "select_in_place rejects" select_rejects hash.iyi \
  "hash: select_in_place keeps" \
  's/^    reject_in_place { |key, value| !(yield key, value) }$/    reject_in_place { |key, value| yield key, value }/'

prove_fails "key_for answers another key" key_for_other hash.iyi \
  "hash: key_for" \
  's/^    each { |key, stored| return key if stored == value }$/    each { |key, stored| return key if stored != value }/'

prove_fails "compact keeps nothing" compact_nothing hash.iyi \
  "hash: compact keeps the values" \
  's/^      result\[key\] = value unless value.nil?$/      result[key] = value if false \&\& !value.nil?/'

prove_fails "count counts every pair" count_all hash.iyi \
  "hash: count" \
  's/^    each { |key, value| total = total + 1 if yield key, value }$/    each { |key, value| total = total + 1 }/'

# 20. first_key? from the start of the dense arrays, past a deleted entry;
#     shift that answers without taking out; values_at that repeats the
#     first; put_if_absent that overwrites; delete's block always asked.
prove_fails "first_key? reads a deleted entry" first_key_gone hash.iyi \
  "hash: first_key? after a delete" \
  's/^    @size == 0 ? nil : @keys\[@first\]$/    @size == 0 ? nil : @keys[0]/'

prove_fails "shift leaves the pair in" shift_keeps hash.iyi \
  "hash: shift takes the oldest out" \
  '/^  def shift : Tuple(K, V)$/,/^  end$/{/^    delete(key)$/d;}'

prove_fails "values_at repeats the first" values_at_first hash.iyi \
  "hash: values_at in the order asked" \
  's/^      result << self\[keys\[at\]\]$/      result << self[keys[0]]/'

prove_fails "put_if_absent overwrites" put_overwrites hash.iyi \
  "hash: put_if_absent keeps what is there" \
  's/^    return @values\[entry\] if entry >= 0$/    return @values[entry] if false/'

prove_fails "delete's block is always asked" delete_block hash.iyi \
  "hash: delete with a block answers the value" \
  's/^    return yield key if entry_of(key) < 0$/    return yield key/'

# 21. clear that keeps its count, dup without the default.
prove_fails "clear keeps its count" clear_count hash.iyi \
  "hash: clear empties" \
  '/^  def clear : Hash(K, V)$/,/^  end$/{/^    @size = 0$/d;}'

# A table without its default refuses the missing key the check asks for,
# so the panic's sentence is where it fails.
prove_fails "dup drops the default" dup_default hash.iyi \
  'no such key "missing"' \
  '/^    copy.adopt_default(@default)$/d'

# 22. Equality that reads only the keys, and a hash that counts the order.
prove_fails "== reads only the keys" keys_only hash.iyi \
  "hash: a different value is unequal" \
  's/^      return false unless entry >= 0 \&\& other.@values\[entry\] == value$/      return false unless entry >= 0/'

prove_fails "a table hash that counts the order" ordered_hash hash.iyi \
  "hash: equal tables hash alike" \
  's/^      total = total \&+ (pair ^ pair.unsafe_shr(29_u64))$/      total = (total \&* 31_u64) \&+ (pair ^ pair.unsafe_shr(29_u64))/'

prove_fails "== is identity again" identity_eq hash.iyi \
  "hash: equal pairs in another order are equal" \
  '/^  def ==(other : Hash(K, V)) : Bool$/,/^  end$/d'

echo
echo "== and what an empty receiver says when it is asked for a size"
panics_with "a negative capacity" neg_cap "negative capacity" "Array(Int32).new(-1).size"

echo
if [ "$status" -eq 0 ]; then
  echo "Collections: a key is one entry however often it is written, a delete"
  echo "leaves the rest findable, a crowded slot is still searched, an array"
  echo "appended to itself doubles, spans and table questions answer at their"
  echo "edges, equal tables are equal in any order, and an empty receiver"
  echo "panics with a name."
else
  echo "the collection surface does not hold"
fi
exit "$status"
