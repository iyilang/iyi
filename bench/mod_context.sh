#!/usr/bin/env bash
# What the two commands that read an import *without building* answer:
# `iyi mod context` and `iyi check --affected`.
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
exit "$status"
