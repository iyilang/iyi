#!/usr/bin/env bash
# What the commands that read an import *without building* answer:
# `iyi mod context`, `iyi check` and `iyi doc`.
#
#     bash bench/mod_context.sh
#
# `mod context` prints the exact exported surface of every module a file
# imports, without the repository that produced it. That is the grounding
# AI_FIRST.md §2 offers a model, and the way it fails is quiet: an import it
# cannot resolve is one line saying so, in an answer that otherwise looks
# complete. A model reading it concludes the module does not exist.
#
# The check is the one comparison that matters: a file that *builds* must
# ground. Nine imports in `samples/iyi` did not, every one of them a
# `std/…` — `mod context` resolved the requirement table and the entry
# file's directory and never looked at `IYI_PATH`, which is where the
# library is.
#
# Exits non-zero if any import of a building file is not grounded.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) PSEP=';' ;;
  *) PSEP=':' ;;
esac

IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac
trap 'rm -rf "$WORK"' EXIT

export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
status=0
grounded=0
ungrounded=""

# The samples are the corpus: every one of them builds, they are written to
# document the language rather than to exercise this, and between them they
# import a local module, a package-shaped path and the library.
for source in "$REPO"/samples/iyi/*.iyi; do
  name="$(basename "$source" .iyi)"
  if ! "$IYI" mod context "$source" > "$WORK/$name.txt" 2>&1; then
    echo "  $name: mod context failed"
    sed -n '1,6p' "$WORK/$name.txt" | sed 's/^/    /'
    status=1
    continue
  fi
  # Three ways the answer can be a hole rather than a surface. Each is a
  # line `mod context` prints in place of the module's declarations.
  if grep -qE "does not resolve|does not compile alone|no artifact carries" "$WORK/$name.txt"; then
    ungrounded="$ungrounded $name"
    grep -E "does not resolve|does not compile alone|no artifact carries" "$WORK/$name.txt" |
      sed "s/^/  $name: /" | head -3
    status=1
    continue
  fi
  grounded=$((grounded + $(grep -c '^── import ' "$WORK/$name.txt")))
done

echo
if [ -n "$ungrounded" ]; then
  echo "FAIL: imports left ungrounded:$ungrounded"
else
  echo "every import in samples/iyi is grounded: $grounded of them, across $(ls "$REPO"/samples/iyi/*.iyi | wc -l | tr -d ' ') files"
fi

# The same resolution, asked by the other command that uses it. `check
# --affected FILE` names the files a change reaches and compiles each one,
# which is what a CI job branches on — and reading an import without the
# search path it answered `{"checked":[]}` for a library module with a
# consumer sitting beside it: nothing affected, all compile, about a change
# that breaks the next build.
mkdir -p "$WORK/affected"
cat > "$WORK/affected/consumer.iyi" <<'EOF'
module consumer

import std/text

puts "x"
EOF
cat > "$WORK/affected/stranger.iyi" <<'EOF'
module stranger

puts "y"
EOF
answer="$(cd "$WORK/affected" && "$IYI" check --affected "$REPO/src/std/text.iyi" --json 2>&1)"
case "$answer" in
  *'"consumer.iyi"'*)
    case "$answer" in
      *'"stranger.iyi"'*)
        echo "FAIL: check --affected named a file that does not import the change"
        echo "  $answer"
        status=1
        ;;
      *)
        echo "check --affected names the consumer of a library module and nobody else"
        ;;
    esac
    ;;
  *)
    echo "FAIL: check --affected did not name the consumer of src/std/text.iyi"
    echo "  $answer"
    status=1
    ;;
esac

# And the workspace R-1 exists for: the dependency is a `.iyimod` and its
# source is gone (III.7). A build reads it because it was told to with a
# flag; these verbs have no flag and read `mods` beside the root, for a
# module whose source is not there. Before that they answered `can't find
# module` about a module `build --use-iyimod` compiles fine against — the
# agent loop's first two steps, broken in the one workspace the boundary
# is for.
mkdir -p "$WORK/artifact-only/app"
cd "$WORK/artifact-only" || exit 1
cat > app/base.iyi <<'EOF'
module app/base

pub def value : Int32
  42
end
EOF
cat > main.iyi <<'EOF'
module main

import app/base::{value}

def run : Int32
  n = value
  n
end

puts run
EOF
export IYI_PATH="$REPO/src${PSEP}$WORK/artifact-only"
if ! "$IYI" build --emit-iyimod mods -o out main.iyi > emit.log 2>&1; then
  echo "FAIL: the artifact-only workspace does not build from source"
  sed -n '1,6p' emit.log | sed 's/^/  /'
  status=1
else
  rm -f app/base.iyi
  if ! "$IYI" build --use-iyimod mods -o out2 main.iyi > use.log 2>&1; then
    echo "FAIL: the build cannot read the artifacts it just wrote"
    sed -n '1,6p' use.log | sed 's/^/  /'
    status=1
  else
    if "$IYI" check main.iyi > check.log 2>&1; then
      echo "check types a file whose dependency is only an artifact"
    else
      echo "FAIL: check refuses a file the build compiles"
      sed -n '1,6p' check.log | sed 's/^/  /'
      status=1
    fi
    if "$IYI" doc main.iyi > doc.log 2>&1 && grep -q "^module main" doc.log; then
      echo "doc reads a module whose dependency is only an artifact"
    else
      echo "FAIL: doc refuses a file the build compiles"
      sed -n '1,6p' doc.log | sed 's/^/  /'
      status=1
    fi
  fi
fi

# The other verb that branches on the same closure: `test --affected` says
# which tests re-run, and a CI job that trusts it runs exactly those. A
# test importing a library module has to be among them.
mkdir -p "$WORK/selection"
cd "$WORK/selection" || exit 1
cat > uses_library_test.iyi <<'EOF'
module uses_library_test

import std/text

def test_join : Nil
  raise "wrong" unless [1, 2].join('-') == "1-2"
end

test_join
EOF
cat > stranger_test.iyi <<'EOF'
module stranger_test

puts "nothing to do with it"
EOF
export IYI_PATH="$REPO/src"
selected="$("$IYI" test --affected "$REPO/src/std/text.iyi" 2>&1 | tail -1)"
case "$selected" in
  "1 passed, 0 failed, 1 skipped"*)
    echo "test --affected runs the test that imports a library module, and only it"
    ;;
  *)
    echo "FAIL: test --affected answered '$selected'"
    status=1
    ;;
esac
cd "$WORK" || exit 1

# And the mixed workspace, which is the shape a project has: its own
# modules are source, its library is an artifact. `mod context` compiles
# an import alone to read its surface, and that compile has the same
# imports the module has — so grounding `app/mid` meant compiling it
# against an `app/base` that is only a `.iyimod`.
mkdir -p "$WORK/mixed/app"
cd "$WORK/mixed" || exit 1
cat > app/base.iyi <<'EOF'
module app/base

pub def value : Int32
  42
end
EOF
cat > app/mid.iyi <<'EOF'
module app/mid

import app/base::{value}

pub def doubled : Int32
  value * 2
end
EOF
cat > main.iyi <<'EOF'
module main

import app/mid::{doubled}

puts doubled
EOF
export IYI_PATH="$REPO/src${PSEP}$WORK/mixed"
if ! "$IYI" build --emit-iyimod mods -o out main.iyi > emit.log 2>&1; then
  echo "FAIL: the mixed workspace does not build from source"
  sed -n '1,6p' emit.log | sed 's/^/  /'
  status=1
else
  rm -f app/base.iyi
  answer="$("$IYI" run main.iyi 2>&1 | tail -1)"
  if [ "$answer" = "84" ]; then
    echo "run answers through a source module whose own import is an artifact"
  else
    echo "FAIL: run answered '$answer', expected 84"
    status=1
  fi
  if "$IYI" mod context main.iyi > ctx.log 2>&1 && ! grep -q "does not" ctx.log; then
    echo "mod context grounds a source module whose own import is an artifact"
  else
    echo "FAIL: mod context left the mixed workspace ungrounded"
    grep -m2 "does not" ctx.log | sed 's/^/  /'
    status=1
  fi
fi
cd "$WORK" || exit 1

# And the shape a developer is in most of the time: artifacts left over
# from an earlier `--emit-iyimod` run, and a source they have since
# edited. The source wins — which is the whole of why these verbs read
# artifacts *after* sources. Read the other way round the artifact no
# longer describes its module, and a plain build would refuse (IV.3)
# about a file the developer is looking at.
mkdir -p "$WORK/stale/app"
cd "$WORK/stale" || exit 1
cat > app/base.iyi <<'EOF'
module app/base

pub def value : Int32
  1
end
EOF
cat > main.iyi <<'EOF'
module main

import app/base::{value}

puts value
EOF
export IYI_PATH="$REPO/src${PSEP}$WORK/stale"
if ! "$IYI" build --emit-iyimod mods -o seed main.iyi > emit.log 2>&1; then
  echo "FAIL: the stale-artifact workspace does not build from source"
  sed -n '1,6p' emit.log | sed 's/^/  /'
  status=1
else
  # The edit the artifacts do not know about.
  cat > app/base.iyi <<'EOF'
module app/base

pub def value : Int32
  2
end
EOF
  answer="$("$IYI" run main.iyi 2>&1 | tail -1)"
  if [ "$answer" = "2" ]; then
    echo "a left-over artifact loses to the source beside it"
  else
    echo "FAIL: run answered '$answer', expected 2 — the artifact won"
    status=1
  fi
fi
cd "$WORK" || exit 1

# And the third command that reads imports without building: `iyi tool
# dependencies`, which draws the tree an editor, a build cache or a person
# asks "what does this file depend on".
#
# It answered *nothing*: exit 0 and an empty tree, for files with imports
# in them. The printer is fed from `require`'s path, and iyi's dependency
# edge is `import` — so the answer was not wrong in a way anyone could
# see, it was empty in a way that reads as "depends on nothing".
#
# The corpus is the samples again, and the comparison is the file's own
# `import` lines: every one that names a module living under `samples/`
# has to appear in the tree. `-i` because the samples are reached through
# `IYI_PATH`, and everything on the search path is library code to this
# tool — that part is Crystal's rule and stays.
cd "$REPO" || exit 1
export IYI_PATH="$REPO/src${PSEP}$REPO/samples/iyi"
edges=0
missing=""
for source in "$REPO"/samples/iyi/*.iyi; do
  name="$(basename "$source" .iyi)"
  tree="$WORK/$name.deps"
  if ! "$IYI" tool dependencies -i "$REPO/samples" -f flat "$source" > "$tree" 2>&1; then
    echo "FAIL: tool dependencies failed on $name"
    sed -n '1,4p' "$tree" | sed 's/^/  /'
    status=1
    continue
  fi
  # The tool prints paths the way the platform spells them, which on
  # Windows is with `\`; the module paths compared against them are
  # posix by grammar (R-1). One spelling before the comparison.
  tr '\\' '/' < "$tree" > "$tree.posix" && mv "$tree.posix" "$tree"
  while read -r module; do
    [ -f "$REPO/samples/iyi/$module.iyi" ] || continue
    if grep -qF "samples/iyi/$module.iyi" "$tree"; then
      edges=$((edges + 1))
    else
      missing="$missing $name->$module"
      status=1
    fi
  done <<EOF
$(sed -n 's/^import  *\([^ ]*\).*/\1/p' "$source")
EOF
done

if [ -n "$missing" ]; then
  echo "FAIL: tool dependencies left these edges out of its tree:$missing"
else
  echo "tool dependencies draws every local import in samples/iyi: $edges edges"
fi
cd "$WORK" || exit 1

# And what those commands *call* the things they name. `iyi tool types`
# prints the type of every variable at a file's top level, and the
# compiler keeps variables there too: definition typing writes
# `__iyi_dt_*` probes — an `uninitialized` receiver and return value in an
# `if false` — to check a def against its own declaration. They were
# printed as the author's: `tool types samples/iyi/calc.iyi` answered with
# twenty-three of them and one real variable, and `samples/iyi/modules.iyi`
# was twenty-three out of twenty-three. The language server's own list is
# step 12b of `bench/lsp_session.py`; this is the other path to the same
# names.
mkdir -p "$WORK/names"
cd "$WORK/names" || exit 1
cat > shape.iyi <<'EOF'
struct Point
  getter x : Int32

  def initialize(@x : Int32)
  end

  def double : Int32
    x * 2
  end
end

spot = Point.new(2)
puts spot.double
EOF
export IYI_PATH="$REPO/src"
"$IYI" tool types shape.iyi > types.txt 2>&1
invented="$(grep -c '^__' types.txt || true)"
if ! grep -q '^spot : Point' types.txt; then
  echo "FAIL: tool types did not name the variable the file writes"
  sed -n '1,4p' types.txt | sed 's/^/  /'
  status=1
elif [ "$invented" != "0" ]; then
  echo "FAIL: tool types answered with $invented name(s) the compiler wrote"
  grep '^__' types.txt | sed 's/^/  /' | head -3
  status=1
else
  echo "tool types names the author's variables and none of the compiler's"
fi
cd "$WORK" || exit 1

# And the methods an `impl` puts on a type, which are the caller's whether
# the trait is the caller's or not. The surface printed `impl T for X` and
# stopped: the type's own block carries its `initialize` and its getters,
# the trait's block carries an `abstract def`, and the method that exists
# on the type — the one a caller writes `x.area` for — was in neither. The
# artifact carried it the whole time; `mod dump` printed it.
#
# The line also read `impl Geo::Shape::Shape for Geo::Shape::Box`, which
# is the other language's spelling of names this very answer tells the
# reader to reach with `import geo/shape::{…}`.
mkdir -p "$WORK/impls/geo"
cd "$WORK/impls" || exit 1
cat > geo/shape.iyi <<'EOF'
module geo/shape

pub trait Shape
  abstract def area : Int32
end

pub struct Box
  getter side : Int32

  def initialize(@side : Int32)
  end
end

impl Shape for Box
  # The area of a box.
  def area : Int32
    side * side
  end
end
EOF
cat > main.iyi <<'EOF'
import geo/shape::{Box}

b = Box.new(3)
puts b.area
EOF
export IYI_PATH="$REPO/src${PSEP}$WORK/impls"
"$IYI" mod context main.iyi > surface.txt 2>&1
if ! grep -q '^impl Shape for Box$' surface.txt; then
  echo "FAIL: the caller's view does not write the impl in iyi's own names"
  grep -n 'impl ' surface.txt | sed 's/^/  /' | head -3
  status=1
elif ! grep -q '^  def area : Int32$' surface.txt; then
  echo "FAIL: the caller's view names no method for an impl the caller calls"
  sed -n '/^impl /,$p' surface.txt | sed 's/^/  /' | head -4
  status=1
else
  echo "the caller's view carries the methods an impl adds, in iyi's names"
fi
cd "$WORK" || exit 1

# And what it says when the module does *not* compile. The answer is one
# line in place of the surface, so that line is the whole diagnosis — and
# it was the wrapper `while importing "X"`, which names the file the
# reader already typed. `iyi doc` has unwrapped that since the verbs gate
# was written; this command had its own copy of the same rescue without
# the unwrapping, so the grounding answer for a module with a bad line in
# it was "does not compile alone: while importing "kit/all"" where `iyi
# check` said what was wrong and where.
mkdir -p "$WORK/broken/kit"
cd "$WORK/broken" || exit 1
cat > kit/all.iyi <<'EOF'
module kit/all

pub def make : Int32
  nonesuch_helper(1)
end
EOF
cat > main.iyi <<'EOF'
import kit/all::{make}

puts make
EOF
export IYI_PATH="$REPO/src${PSEP}$WORK/broken"
"$IYI" mod context main.iyi > broken.txt 2>&1
if grep -q 'while importing' broken.txt; then
  echo "FAIL: mod context answered with the wrapper instead of the diagnostic"
  grep 'does not compile' broken.txt | sed 's/^/  /' | head -2
  status=1
elif ! grep -q "undefined method 'nonesuch_helper'" broken.txt; then
  echo "FAIL: mod context did not name why the module does not compile"
  sed -n '1,4p' broken.txt | sed 's/^/  /'
  status=1
else
  echo "a module that does not compile is answered with the reason it does not"
fi
cd "$WORK" || exit 1

# And what a facade hands on. `pub import` is a promise to the consumer:
# a file that imports the facade may name the module the facade
# re-exported, with no import of its own (R-2b). The pack listed only the
# file's own import lines, so the module a consumer is allowed to name
# was missing from the one answer written to be named from — and the
# consumer line it did print told the reader to import the facade, which
# is right, about a surface it never showed.
mkdir -p "$WORK/facade/deep"
cd "$WORK/facade" || exit 1
cat > deep/core.iyi <<'EOF'
module deep/core

pub def core_value : Int32
  7
end
EOF
cat > facade.iyi <<'EOF'
module facade

pub import deep/core

pub def facade_value : Int32
  1
end
EOF
# deep/core is reached through the facade's `pub import` and nothing of
# main's own: an `import deep/core::*` would import it here, and then it would be
# main's dependency and no re-export at all.
cat > main.iyi <<'EOF'
import facade::{facade_value}

puts Deep::Core.core_value + facade_value
EOF
export IYI_PATH="$REPO/src${PSEP}$WORK/facade"
if ! "$IYI" run main.iyi > facade_run.txt 2>&1 || [ "$(tail -1 facade_run.txt)" != "8" ]; then
  echo "FAIL: the facade fixture does not run"
  sed -n '1,4p' facade_run.txt | sed 's/^/  /'
  status=1
else
  "$IYI" mod context main.iyi > facade_pack.txt 2>&1
  if ! grep -q 'pub def core_value : Int32' facade_pack.txt; then
    echo "FAIL: the pack does not carry what the facade re-exports"
    grep '^── import' facade_pack.txt | sed 's/^/  /'
    status=1
  elif ! grep -q '^#   import deep/core::{core_value}' facade_pack.txt ||
       ! grep -q '^── import facade → deep/core (re-exported) ──' facade_pack.txt; then
    echo "FAIL: the pack does not say how the re-export is reached"
    grep -E '^── import|^#   ' facade_pack.txt | sed 's/^/  /' | head -6
    status=1
  else
    echo "the pack carries what a facade re-exports, and the import that hands it on"
  fi
fi
cd "$WORK" || exit 1

# And what an artifact says its object code links against. `Libs` names
# each `lib` a unit calls into, so a consumer that links the unit — and
# compiles none of it — passes the library to the linker. It was empty for
# every module whose `lib` is its own: the lib's funs are declared in the
# main module and copied into the calling unit past the line that recorded
# them. On Windows every program built from `std/socket`'s artifact failed
# to link on sixteen Winsock symbols; on Linux a `lib` whose library is
# linked anyway hid it. A class-nested `lib` over the C library's `abs`,
# which every platform links, asked of the dump.
mkdir -p "$WORK/libs/m"
cd "$WORK/libs" || exit 1
cat > m/netty.iyi <<'EOF'
module m/netty

pub class Box
  lib LibMathy
    fun abs(x : Int32) : Int32
  end

  def self.c(x : Int32) : Int32
    LibMathy.abs(x)
  end
end
EOF
printf 'import m/netty::{Box}\n\nputs Box.c(-3)\n' > main.iyi
export IYI_PATH="$REPO/src${PSEP}$WORK/libs"
if ! "$IYI" build --emit-iyimod mods -o libs_main main.iyi > libs_build.txt 2>&1; then
  echo "FAIL: the lib fixture does not build"
  sed -n '1,4p' libs_build.txt | sed 's/^/  /'
  status=1
elif "$IYI" mod dump mods/m/netty.iyimod | sed -n '/^libs/,/^[a-z]/p' | grep -q 'M::Netty::Box::LibMathy'; then
  echo "an artifact names the lib its object code calls"
else
  echo "FAIL: the artifact's object code calls LibMathy and its libs do not say so"
  "$IYI" mod dump mods/m/netty.iyimod | grep -n '^libs\|^object code' | sed 's/^/  /'
  status=1
fi
cd "$WORK" || exit 1

exit "$status"
