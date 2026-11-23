#!/usr/bin/env bash
# Early cutoff in the artifact loop (SPEC.md IV.3): a module compiled from its
# changed source leaves the artifacts of the modules that import it standing
# when it hashes as before, and makes them rebuild when it does not.
#
# Every case is a project of `app/core`, `app/user` (which imports core) and
# `main.iyi` (which imports user), built with `--emit-iyimod mods
# --use-iyimod mods`, then built again after an edit to core:
#
# - a body-only edit: user's artifact is read, not rewritten, and the program
#   prints the new answer;
# - an edit to what user was compiled against - a signature, a type's layout,
#   a constant user's code was compiled with, a macro it expanded, the body of
#   a generic it instantiated, a block-taking method it compiled its block
#   into, and, one module further, a generic whose instance reaches user only
#   through a middle module whose own body moved: user's artifact is rewritten
#   and the program prints the new answer.
#
# A reused artifact that should not have been is a program that is silently
# wrong, so each of the second kind is also built with `IYI_CUTOFF_BROKEN=1`,
# which reads user's artifact without checking the condition it was read on,
# and that build has to fail or print something else. A case that passes
# both ways is a case that does not test the check, and fails this gate.
#
# A body-only edit has a check of its own to prove. User's machine code
# calls core's functions, and the build that compiles core makes those calls
# itself so that core's unit defines them; `IYI_CUTOFF_BROKEN=keeps` makes
# none, and the build has to notice the missing symbol and rebuild user,
# while `keeps,1`, which also skips the checks, has to fail to link.
#
#     bash bench/iyimod_cutoff.sh
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
status=0

fail() {
  echo "FAIL  $*"
  status=1
}

# build DIR [ENV...]: the artifact loop's build, in DIR, with DIR's own cache.
build() {
  local dir="$1"
  shift
  (cd "$dir" && env IYI_CACHE_DIR="$dir/.cache" "$@" "$IYI" build \
    --emit-iyimod mods --use-iyimod mods -o out main.iyi) > "$dir/build.log" 2>&1
}

# rewritten DIR MODULE: whether the build after `age` wrote MODULE's artifact.
rewritten() {
  [ -n "$(find "$1/mods/app/$2.iyimod" -newer "$1/marker" 2>/dev/null)" ]
}

# age DIR: dates every artifact in 2001 and leaves a marker after them, so
# the next build's writes are the files newer than the marker.
age() {
  find "$1/mods" -name '*.iyimod' -exec touch -t 200101010000 {} +
  touch -t 200101010001 "$1/marker"
}

# project DIR CORE USER [MID]: writes the three (or four) files.
project() {
  local dir="$1"
  mkdir -p "$dir/app"
  printf 'module app/core\n\n%s\n' "$2" > "$dir/app/core.iyi"
  if [ $# -ge 4 ]; then
    printf 'module app/mid\n\nimport app/core\n\n%s\n' "$4" > "$dir/app/mid.iyi"
    printf 'module app/user\n\nimport app/mid\n\n%s\n' "$3" > "$dir/app/user.iyi"
  else
    printf 'module app/user\n\nimport app/core\n\n%s\n' "$3" > "$dir/app/user.iyi"
  fi
  printf 'module main\n\nimport app/user\n\nputs App::User.run\n' > "$dir/main.iyi"
}

# check NAME CORE1 CORE2 USER BEFORE AFTER KIND [MID1 MID2]
#
# KIND is `body` (user's artifact stays) or `interface` (it is rewritten, and
# the broken build fails or prints something other than AFTER).
check() {
  local name="$1" core1="$2" core2="$3" user="$4" before="$5" after="$6" kind="$7"
  local mid1="${8:-}" mid2="${9:-}"
  local dir="$WORK/$name" d printed
  echo "== $name"
  # Two projects built the same way, one for the build that checks and one
  # for the build that does not. Not a copy of one: an artifact records the
  # path it was written from, and a copy's moved path rebuilds everything
  # for a reason of its own.
  local copies="$dir $dir-broken"
  [ "$kind" = body ] && copies="$copies $dir-keeps"
  for d in $copies; do
    if [ -n "$mid1" ]; then project "$d" "$core1" "$user" "$mid1"; else project "$d" "$core1" "$user"; fi
    if ! build "$d"; then
      fail "$name: the first build failed"; cat "$d/build.log"; return
    fi
    printed="$("$d/out")"
    if [ "$printed" != "$before" ]; then
      fail "$name: the first build printed '$printed', expected '$before'"; return
    fi
    age "$d"
    printf 'module app/core\n\n%s\n' "$core2" > "$d/app/core.iyi"
    [ -n "$mid2" ] && printf 'module app/mid\n\nimport app/core\n\n%s\n' "$mid2" > "$d/app/mid.iyi"
  done

  if ! build "$dir"; then
    fail "$name: the build after the edit failed"; cat "$dir/build.log"; return
  fi
  printed="$("$dir/out")"
  if [ "$printed" != "$after" ]; then
    fail "$name: the build after the edit printed '$printed', expected '$after'"; return
  fi
  rewritten "$dir" core || fail "$name: core's artifact was not rewritten"

  if [ "$kind" = body ]; then
    if rewritten "$dir" user; then
      fail "$name: user's artifact was rewritten after a body-only edit to core"
    else
      echo "  ok  user's artifact read as it was, and the program prints $after"
    fi
    if ! build "$dir-keeps" IYI_CUTOFF_BROKEN=keeps; then
      fail "$name: without the calls that compile core's demanded symbols, the build failed"
      cat "$dir-keeps/build.log"
    elif [ "$("$dir-keeps/out")" != "$after" ]; then
      fail "$name: without the calls, the program printed '$("$dir-keeps/out")', expected '$after'"
    elif ! rewritten "$dir-keeps" user; then
      fail "$name: without the calls, user's artifact was still read"
    else
      echo "  ok  without the calls the symbol is missed, and user is rebuilt"
    fi
    if build "$dir-broken" IYI_CUTOFF_BROKEN=keeps,1; then
      fail "$name: without the calls and without the check the program still builds, so this case does not test them"
    else
      echo "  ok  without the calls and the check it does not build: $(grep -m1 -i 'undefined' "$dir-broken/build.log")"
    fi
    return
  fi

  if rewritten "$dir" user; then
    echo "  ok  user's artifact rewritten, and the program prints $after"
  else
    fail "$name: user's artifact was read after core's interface moved"
  fi

  if build "$dir-broken" IYI_CUTOFF_BROKEN=1; then
    printed="$("$dir-broken/out" 2>&1)"
    if [ "$printed" = "$after" ]; then
      fail "$name: without the check the program still prints '$after', so this case does not test it"
    else
      echo "  ok  without the check it prints '$printed'"
    fi
  else
    echo "  ok  without the check it does not build: $(grep -m1 -i -E 'error|undefined' "$dir-broken/build.log")"
  fi
}

check body \
  $'pub def base : Int32\n  40\nend' \
  $'pub def base : Int32\n  41\nend' \
  $'pub def run : Int32\n  App::Core.base + 2\nend' \
  42 43 body

check signature \
  $'pub def scale(x : Int32) : Int32\n  x * 2\nend' \
  $'pub def scale(x : Int32) : Int64\n  x.to_i64 * 3\nend' \
  $'pub def run : String\n  App::Core.scale(5).to_s\nend' \
  10 15 interface

check layout \
  $'pub struct Pair\n  @a : Int32\n  @b : Int32\n\n  def initialize(@a : Int32, @b : Int32)\n  end\n\n  def sum : Int32\n    @a + @b\n  end\nend' \
  $'pub struct Pair\n  @pad : Int64\n  @a : Int32\n  @b : Int32\n\n  def initialize(@a : Int32, @b : Int32)\n    @pad = 1000_i64\n  end\n\n  def sum : Int32\n    @a + @b + @pad.to_i32\n  end\nend' \
  $'pub def run : Int32\n  pairs = [App::Core::Pair.new(1, 2), App::Core::Pair.new(3, 4)]\n  pairs[1].sum\nend' \
  7 1007 interface

check constant \
  $'pub SIZE = 3' \
  $'pub SIZE = 4' \
  $'import std/static_array\n\npub def run : Int32\n  StaticArray(Int32, App::Core::SIZE).new.size\nend' \
  3 4 interface

check macro \
  $'pub macro twice(x)\n  {{x}} * 2\nend' \
  $'pub macro twice(x)\n  {{x}} * 3\nend' \
  $'pub def run : Int32\n  App::Core.twice(7)\nend' \
  14 21 interface

check generic \
  $'pub class Box(T)\n  def initialize(@value : T)\n  end\n\n  def tag : Int32\n    1\n  end\nend' \
  $'pub class Box(T)\n  def initialize(@value : T)\n  end\n\n  def tag : Int32\n    2\n  end\nend' \
  $'pub def run : Int32\n  App::Core::Box(Int32).new(5).tag + 100\nend' \
  101 102 interface

check block \
  $'pub def each_twice(& : Int32 -> Nil) : Nil\n  yield 1\n  yield 2\nend' \
  $'pub def each_twice(& : Int32 -> Nil) : Nil\n  yield 1\n  yield 2\n  yield 3\nend' \
  $'pub def run : Int32\n  sum = 0\n  App::Core.each_twice { |i| sum += i }\n  sum\nend' \
  3 6 interface

# A body-only edit again, through a splat: the symbol user calls is the
# splat's instantiation at the three arguments it passed, and the call the
# build makes for it has to name the same one.
check splat \
  $'pub def total(*xs : Int32) : Int32\n  xs.size\nend' \
  $'pub def total(*xs : Int32) : Int32\n  xs.size + 1\nend' \
  $'pub def run : Int32\n  App::Core.total(1, 2, 3)\nend' \
  3 4 body

# One module further: user imports only mid, and reaches core's generic
# through mid's signature. Mid's own body moves too, so mid is compiled from
# its source and still hashes as before; what user was compiled against
# moved in core, which user has no edge to.
check chain \
  $'pub class Box(T)\n  def initialize(@value : T)\n  end\n\n  def tag : Int32\n    1\n  end\nend' \
  $'pub class Box(T)\n  def initialize(@value : T)\n  end\n\n  def tag : Int32\n    2\n  end\nend' \
  $'pub def run : Int32\n  App::Mid.make.tag + 100 + App::Mid.note\nend' \
  111 122 interface \
  $'pub def make : App::Core::Box(Int32)\n  App::Core::Box(Int32).new(5)\nend\n\npub def note : Int32\n  10\nend' \
  $'pub def make : App::Core::Box(Int32)\n  App::Core::Box(Int32).new(5)\nend\n\npub def note : Int32\n  20\nend'

if [ $status -eq 0 ]; then
  echo "early cutoff: a body-only edit leaves its dependents' artifacts standing, and every interface edit rebuilds them"
fi
exit $status
