#!/usr/bin/env bash
# Every import in the tree is grounded by `iyi mod context`.
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
exit "$status"
