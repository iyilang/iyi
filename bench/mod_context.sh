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

import app/base
using app/base::{value}

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

import app/base
using app/base::{value}

pub def doubled : Int32
  value * 2
end
EOF
cat > main.iyi <<'EOF'
module main

import app/mid
using app/mid::{doubled}

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

import app/base
using app/base::{value}

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

exit "$status"
