#!/usr/bin/env bash
# The prelude's value types - a tuple and a range: their equality, their
# hash, and every collection that asks one of those two questions.
#
#     bash bench/value_exercise.sh
#
# `bench/value_exercise.iyi` is the program. It runs plain and optimised, and
# then each check is proved capable of failing by patching a *copy of the
# prelude* - `src/iyi/object.iyi` with one method broken - and building
# against it through `IYI_PATH`. A check that cannot fail is not a check.
#
# What is being protected is the agreement, not the two methods. `==` and
# `hash` were the ones the prelude never wrote for either type, so `Object`'s
# answered - identity, on a value type - and `{1, 2} == {1, 2}` and
# `(1..3) == (1..3)` were both false. Everything
# that asks a value whether it is equal was wrong with it: a tuple key was
# never found in a `Hash`, a `Set` of them was a list, `includes?`, `index`
# and `uniq` over `zip`'s own result answered no, and a `case` over a tuple
# matched nothing, because a `when` is `===` and `===` is `==`.
#
# Exits non-zero if any check fails or if any patch leaves the exercise green.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The compiler, overridable: `bin/iyi` is a POSIX shell wrapper, and on
# Windows the caller is the only one who knows where the real binary is.
IYI="${IYI:-$REPO/bin/iyi}"
# The search path is a list, and the byte between its entries is the
# platform's: `;` where a drive letter already owns the colon.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and a scratch
# directory named `/tmp/tmp.X` is silently ignored on the search path, so
# the patched copy is never read and the proof that a check can fail
# quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() { # run_case <label> <name> [build flags...]
  local label="$1" name="$2"
  shift 2
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/value_exercise.iyi" \
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
  if ! grep -q "all value checks passed" "$WORK/$name.out"; then
    echo "  $label: the exercise ended without passing"
    tail -3 "$WORK/$name.out"
    status=1
    return
  fi
  echo "  $label: every check held"
}

echo "== the surface, plain"
run_case "plain" plain

echo
echo "== and with optimisation on (--release)"
run_case "release" release --release

echo
echo "== the sample that reaches it, because zip answers tuples"
if "$IYI" run "$REPO/samples/iyi/collections.iyi" > "$WORK/sample.out" 2>&1; then
  if grep -qE "^zip +[0-9][a-z]+ [0-9][a-z]+ [0-9][a-z]+ [0-9][a-z]+$" "$WORK/sample.out"; then
    echo "  samples/iyi/collections.iyi: zip still answers its pairs"
  else
    echo "  samples/iyi/collections.iyi: ran, but not printing its zip"
    grep -n "zip" "$WORK/sample.out" | sed -n '1,3p'
    status=1
  fi
else
  echo "  samples/iyi/collections.iyi: did not run"
  tail -3 "$WORK/sample.out"
  status=1
fi

echo
echo "== proving the checks can fail, one broken method at a time"

# A copy of the whole prelude with one method patched, on `IYI_PATH` ahead of
# the real one. The patch has to change the file - a sed that matched nothing
# would otherwise read as a pass - and the exercise then has to exit non-zero
# at the check that names the method.
prove_fails() { # prove_fails <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/object.iyi" > "$WORK/$dir/iyi/object.iyi"
  if cmp -s "$REPO/src/iyi/object.iyi" "$WORK/$dir/iyi/object.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/value_exercise.iyi" \
       > "$WORK/$dir/build" 2>&1; then
    if grep -q "$phrase" "$WORK/$dir/build"; then
      printf '  %s: refused at compile time\n' "$label"
    else
      echo "  $label: the patched prelude did not build, and not for this check"
      sed -n '1,10p' "$WORK/$dir/build"
      status=1
    fi
    return
  fi

  "$WORK/$dir/program" > "$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
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

# The same, for the file the other value type lives in.
prove_fails_range() { # prove_fails_range <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/range.iyi" > "$WORK/$dir/iyi/range.iyi"
  if cmp -s "$REPO/src/iyi/range.iyi" "$WORK/$dir/iyi/range.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/value_exercise.iyi" \
       > "$WORK/$dir/build" 2>&1; then
    echo "  $label: the patched prelude did not build"
    sed -n '1,10p' "$WORK/$dir/build"
    status=1
    return
  fi
  "$WORK/$dir/program" > "$WORK/$dir/out" 2>&1
  local code=$?
  if [ "$code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
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

# 1. Equality by identity again, which is what `Object#==` gave it.
prove_fails "== by identity" no_eq "tuple: == same members" \
  's/^      return false unless self\[{{i}}\] == other\[{{i}}\]$/      return false/'

# 2. Equality that ignores the members, the other direction: everything equal.
prove_fails "== always true" all_eq "tuple: == different members" \
  's/^      return false unless self\[{{i}}\] == other\[{{i}}\]$/      # broken/'

# 3. One slot for every tuple, which is `Object#hash`. Equality still holds,
#    so this is the check that a key is found rather than merely compared.
prove_fails "hash collapsed" no_hash "tuple: order changes the hash" \
  's/^      value = (value &\* 31) &+ self\[{{i}}\].hash$/      value = 17/'

# 4. A hash that reads only the first member, so `{1, 2}` and `{1, 3}` share
#    a slot. The table still answers - this is why the hash's own check is
#    about which tuples differ rather than about lookups.
prove_fails "hash ignores the tail" head_hash "tuple: a member changes the hash" \
  's/^      value = (value &\* 31) &+ self\[{{i}}\].hash$/      value = value \&+ self[0].hash/'

# 5. `size`, which the walk and every macro loop above read.
prove_fails "size wrong" bad_size "tuple: size of a pair" \
  's/^    {{ T.size }}$/    0/'

# 6. Indexing by a value, which is how a tuple is walked at runtime.
prove_fails "index by value" bad_index "tuple: index by value" \
  's/^      return self\[{{i}}\] if index == {{i}}$/      return self[0] if index == {{i}}/'

# 7. `to_s`, which prints a tuple as its members written down.
prove_fails "to_s without members" bad_to_s "tuple: to_s" \
  's/^      result = result + self\[{{i}}\].inspect$/      result = result + "?"/'

# 8. And the range's own pair, in the file it lives in.
# The macro file, for `record`: a block it drops is a method the program
# names and the compiler cannot find, so this one is refused at compile time.
prove_fails_macro() { # prove_fails_macro <label> <dir> <phrase> <sed script>
  local label="$1" dir="$2" phrase="$3" script="$4"
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  sed -e "$script" "$REPO/src/iyi/macros.iyi" > "$WORK/$dir/iyi/macros.iyi"
  if cmp -s "$REPO/src/iyi/macros.iyi" "$WORK/$dir/iyi/macros.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if IYI_PATH="$WORK/$dir${PSEP}$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/value_exercise.iyi" \
       > "$WORK/$dir/build" 2>&1; then
    echo "  $label: the patched prelude still built, so this proves nothing"
    status=1
    return
  fi
  if grep -q "$phrase" "$WORK/$dir/build"; then
    printf '  %s: refused at compile time, at %s\n' "$label" "$phrase"
  else
    echo "  $label: the patched prelude did not build, and not for this check"
    sed -n '1,10p' "$WORK/$dir/build"
    status=1
  fi
}

prove_fails_macro "record drops its block" record_block "undefined method 'record_width'" \
  's/^      {{ yield }}$//'

prove_fails_range "range == ignores its bounds" range_eq "range: == different end" \
  's/^    @begin == other.begin \&\& @end == other.end \&\& @exclusive == other.exclusive?$/    true/'

# 9. The flag dropped, so `1..3` and `1...3` become the same range.
prove_fails_range "range == ignores exclusive" range_flag "range: inclusive is not exclusive" \
  's/ \&\& @exclusive == other.exclusive?$//'

# 10. And its hash, which is what puts an equal range in the same slot.
prove_fails_range "range hash collapsed" range_hash "range: the flag changes the hash" \
  's/^    @exclusive ? (value &\* 31) &+ 1 : value &\* 31$/    0/'

echo
if [ "$status" -eq 0 ]; then
  echo "Values: a tuple's and a range's equality and hash agree, and the Hash,"
  echo "the Set, includes?, index, uniq, zip and case that ask them all get one"
  echo "answer."
else
  echo "the value surface does not hold"
fi
exit "$status"
