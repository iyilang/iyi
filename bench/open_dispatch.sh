#!/usr/bin/env bash
# A module used as a type, across a boundary: the consumer's includer is in the
# set (SPEC.md III.6).
#
#     bash bench/open_dispatch.sh
#
# `bench/open_dispatch_fixture/` is forty lines and no shard. `Chainy::Link` is
# a module held as a type — `@next : Link | Nil`, the shape every kemal
# middleware chain has — so a call on it is compiled as one type-id test per
# *including* type, and the includers are whichever ones the build that
# compiled the test happened to have. The consumer writes `Mine`, joins that
# set, and the producer's compiled dispatch matches none of its cases.
#
# From source the two files print `first mine end`. Through the boundary they
# printed `first ` and stopped, and a kemal application did the same thing one
# request in: `codegen_dispatch` ends in `unreachable`, so what happens after
# the last case is whatever the optimiser left there.
#
# The rule that fixes it makes such a body travel, and the closure reaches the
# bodies that *call* one. Both arms are run here: with the rule, and with
# `IYI_OPEN_TRAVEL=off`, which writes the boundary the way it was written
# before it. A gate that cannot fail is not a gate.
#
# Needs `make` only — no shard, no network. Exits non-zero if either bind or
# fill fails, if the boundary arm does not answer what the source arm answers,
# or if the rule turned off still answers it.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# A native compiler cannot resolve this shell's own path mapping: the
# fixture and the tree's own sources are named to the compiler as paths,
# and ones built from the shell's `pwd` are not directories it can open.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) REPO="$(cygpath -m "$REPO")" ;;
esac
# The gate runs whatever compiler the caller names; `bin/iyi` is a shell
# wrapper, and on Windows the caller has to point at the built exe itself.
IYI="${IYI:-$REPO/bin/iyi}"
FIXTURE="$REPO/bench/open_dispatch_fixture"
WORK="$(mktemp -d)"
# A native compiler cannot resolve this shell's own path mapping: a
# scratch directory named `/tmp/tmp.X` is silently ignored on the search
# path, so the patched copy is never read and the proof that a check can
# fail quietly stops proving it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) WORK="$(cygpath -m "$WORK")" ;;
esac
trap 'rm -rf "$WORK"' EXIT

status=0

fail() {
  echo "  FAIL: $*"
  status=1
}

# One arm: bind the shard, fill the object code, run the consumer against the
# boundary. Prints what the program printed, or the step that refused.
arm() { # arm <dir> [env assignment...]
  dir="$WORK/$1"
  shift
  mkdir -p "$dir"
  cp "$FIXTURE/shard.cr" "$FIXTURE/app.iyi" "$dir/"
  (
    cd "$dir" || exit 1
    export "$@" 2>/dev/null || true
    "$IYI" tool bind --crystal -e Chainy --emit-bind mods shard.cr > bind.log 2>&1 || {
      echo "bind refused it"
      exit 0
    }
    "$IYI" build --crystal --iyi-keep Chainy --emit-bind mods --use-iyimod mods \
      -o keep mods/chainy_keep.cr > fill.log 2>&1 || {
      echo "the fill build refused it"
      exit 0
    }
    "$IYI" run --crystal --use-iyimod mods app.iyi 2> run.log | tail -1
  )
}

echo "== the two files, built from source"
(
  cd "$WORK" || exit 1
  mkdir -p source && cp "$FIXTURE/shard.cr" "$FIXTURE/app.iyi" source/
  cd source || exit 1
  printf 'require "./shard.cr"\n' > entry.cr
  # The consumer as one program: the shard's source beside it, which is what
  # the boundary has to answer for.
  sed 's|^import chainy$|require "./shard.cr"|' app.iyi > whole.iyi
  "$IYI" run --crystal whole.iyi 2> source.log | tail -1
) > "$WORK/source.out" 2>&1
source_answer="$(tail -1 "$WORK/source.out")"
echo "  $source_answer"
if [ "$source_answer" != "first mine end" ]; then
  fail "the source arm answered '$source_answer', so the fixture itself has moved"
fi

echo
echo "== and through four commands and a boundary"
boundary_answer="$(arm boundary IYI_OPEN_TRAVEL=)"
echo "  $boundary_answer"
if [ "$boundary_answer" != "$source_answer" ]; then
  fail "the boundary answered '$boundary_answer' where the source answered '$source_answer'"
else
  echo "  the consumer's own includer is in the dispatch"
fi

echo
echo "== with the rule turned off, which is what it was before"
without="$(arm without IYI_OPEN_TRAVEL=off)"
echo "  $without"
if [ "$without" = "$source_answer" ]; then
  fail "the boundary answered '$without' with IYI_OPEN_TRAVEL=off, so this gate is checking nothing"
else
  echo "  '$without' — the defect, and the reason the bodies travel"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "an open type's members are the program's answer, and the boundary asks the program"
else
  echo "a module held as a type does not survive the boundary"
fi
exit "$status"
