#!/usr/bin/env bash
# What `iyi mod diff` answers, checked against what a rebuild would show.
#
#     bash bench/mod_diff.sh
#
# The command exists so a build system can branch on one question: does this
# change reach the modules that import me? Four kinds of edit answer it
# differently, and the interesting one is the third:
#
#   * a doc comment           — nothing moves, nobody rebuilds
#   * an ordinary body        — the machine code moves and travels as machine
#                               code, so a consumer relinks and compiles
#                               nothing; the answer is still "no rebuild", and
#                               the check below proves the new answer reaches a
#                               consumer that was not recompiled
#   * a *travelling* body     — a block-taking def is instantiated at the call
#                               site, so the consumer compiles it; the answer
#                               has to be "rebuild", and it was "no" until this
#                               file was written
#   * a signature             — the interface moved, which it always caught
#
# Each case is checked twice over: the verdict `mod diff` prints and the
# `--exit-code` a script branches on, against what the consumer's own output
# does when it is *not* rebuilt. A verdict that disagrees with the program is
# the failure this exists to catch — a build system trusting it would ship a
# binary running code its source no longer says.
#
# Exits non-zero if any check fails.

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

status=0
cd "$WORK" || exit 1
mkdir -p app
export IYI_PATH="$REPO/src${PSEP}$WORK"

cat > main.iyi <<'EOF'
module main

import app/twice

App::Twice.with_each { |n| puts n }
puts App::Twice.plain
EOF

# The module, written with three things a build can move independently: the
# doc comment, the constant inside the block-taking def (which travels), and
# the constant inside the ordinary one (which does not).
write_module() {
  cat > app/twice.iyi <<EOF
module app/twice

import app/base::{each_base}

# $1
pub def with_each(&block : Int32 -> Nil) : Nil
  block.call(1)
  block.call($2)
end

pub def plain : Int32
  total = 0
  each_base { |n| total = total + n }
  $3 + total
end
EOF
}

# The module under this one. Nothing in `app/twice` mentions its value, so
# changing it moves none of that module's own three hashes — only the edge
# it was compiled against.
write_base() {
  cat > app/base.iyi <<EOF
module app/base

pub def each_base(&block : Int32 -> Nil) : Nil
  block.call($1)
end
EOF
}

emit() {
  local into="$1"
  rm -rf "$into"
  mkdir -p "$into"
  if ! "$IYI" build --emit-iyimod "$into" -o "bin_$into" main.iyi > "emit_$into.log" 2>&1; then
    echo "FAIL: cannot write artifacts for $into"
    sed -n '1,8p' "emit_$into.log"
    status=1
    return 1
  fi
}

# What the *program* does with a given set of artifacts and no recompilation
# of the module: the ground truth each verdict is checked against.
answer_from() {
  local mods="$1" out="$2"
  if ! "$IYI" build --use-iyimod "$mods" -o "$out" main.iyi > "use_$out.log" 2>&1; then
    echo "FAIL: cannot build against $mods"
    sed -n '1,8p' "use_$out.log"
    status=1
    return 1
  fi
  "./$out" | tr '\n' ' '
}

check() {
  local label="$1" mods="$2" want_exit="$3" want_answer="$4"
  local got_exit answer verdict
  "$IYI" mod diff --exit-code base/app/twice.iyimod "$mods/app/twice.iyimod" > "diff_$mods.txt" 2>&1
  got_exit=$?
  verdict="$(tail -1 "diff_$mods.txt")"
  answer="$(answer_from "$mods" "bin_answer_$mods")"

  printf '%-24s ' "$label"
  if [ "$got_exit" -ne "$want_exit" ]; then
    echo "FAIL: mod diff exited $got_exit, expected $want_exit"
    sed -n '1,8p' "diff_$mods.txt"
    status=1
    return
  fi
  if [ "$answer" != "$want_answer" ]; then
    echo "FAIL: the program answers '$answer', expected '$want_answer'"
    status=1
    return
  fi
  echo "exit $got_exit, program says '$answer'"
  echo "    $verdict"
}

write_base 0
write_module "first note" 2 40
emit base || exit 1
baseline="$(answer_from base bin_baseline)"
if [ "$baseline" != "1 2 40 " ]; then
  echo "FAIL: the baseline program answers '$baseline'"
  exit 1
fi
echo "baseline                 program says '$baseline'"
echo

# A comment above a def. The interface is encoded without docs and a comment
# is not part of a body, so neither hash moves.
write_module "a second note, same code" 2 40
emit docs && check "a doc comment" docs 0 "1 2 40 "

# A body that stays behind. Its machine code is in the artifact, so a
# consumer that is *not* rebuilt still answers the new number — which is what
# makes "no rebuild" the right answer rather than a convenient one.
write_module "first note" 2 41
emit plain && check "an ordinary body" plain 0 "1 2 41 "

# A body that travels. The consumer compiles it, so the verdict has to be
# "rebuild" even though nothing it type-checks against moved.
write_module "first note" 9 40
emit travels && check "a travelling body" travels 1 "1 9 40 "

# A module under this one, changed. `app/twice` is byte for byte the same
# file, so its own interface, implementation and source hashes all agree —
# and it is a different artifact, because it was compiled against a `base`
# that moved. The three lines read "unchanged" and the verdict was
# "consumers do not have to be rebuilt", about a program that prints
# something else: what an artifact records includes what it was built
# against (IV.3), and the diff had never read those edges.
write_module "first note" 2 40
write_base 5
emit dependency && check "a module underneath" dependency 1 "1 2 45 "
# The ground truth under that verdict: the old `twice.iyimod` beside the new
# `base.iyimod` is what a build system that believed "nothing to do" would
# link — and the compiler refuses that set outright (IV.3). A verdict of
# "no rebuild" would have been advice its own compiler will not take.
rm -rf mixed && cp -r base mixed && cp dependency/app/base.iyimod mixed/app/base.iyimod
if "$IYI" build --use-iyimod mixed -o bin_mixed main.iyi > mixed.log 2>&1; then
  echo "FAIL: the old artifact linked against the new one, so nothing forced the rebuild"
  status=1
else
  echo "    and the compiler refuses the unrebuilt artifact beside the new one"
fi

# And the case that always worked, kept here so the four are read together.
cat > app/twice.iyi <<'EOF'
module app/twice

# first note
pub def with_each(&block : Int32 -> Nil) : Nil
  block.call(1)
  block.call(2)
end

pub def plain(offset : Int32) : Int32
  40 + offset
end
EOF
cat > main.iyi <<'EOF'
module main

import app/twice

App::Twice.with_each { |n| puts n }
puts App::Twice.plain(0)
EOF
emit signature && check "a signature" signature 1 "1 2 40 "

echo
if [ "$status" -eq 0 ]; then
  echo "mod diff answers what a rebuild would show, for all five kinds of edit."
else
  echo "mod diff: something above failed."
fi
exit "$status"
