#!/usr/bin/env bash
# A union stored through a smaller arm, and every padded value, writes
# its whole slot: bench/union_holes.iyi reads the raw words of an
# `Array(Val)` buffer and of a `Val` field and counts the stale ones.
#
#     bash bench/union_holes.sh
#
#   1. Plain and --release builds: 0 stale words, three seeds each.
#   2. The broken copy, the compiler with `IYI_SPAWN_BROKEN=holes` (no hole
#      written as zero, as before the fix): stale words in the plain build
#      and the --release build, every seed (Linux: 63 and 78).
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

for copy in fixed broken; do
  for build in plain release; do
    flag=""
    [ "$build" = release ] && flag="--release"
    broken=""
    [ "$copy" = broken ] && broken="holes"
    echo "== $copy compiler, $build build"
    if ! IYI_SPAWN_BROKEN="$broken" "$IYI" build $flag "$REPO/bench/union_holes.iyi" -o "holes-$copy-$build" > "build-$copy-$build.log" 2>&1; then
      echo "build failed:"; tail -20 "build-$copy-$build.log"; exit 1
    fi
    for seed in s1 s2 s3; do
      timeout -k 5 60 "./holes-$copy-$build" "$seed" > "ran.txt" 2>&1
      code=$?
      count="$(sed -n 's/^stale words: //p' ran.txt)"
      if [ "$copy" = fixed ] && { [ "$code" -ne 0 ] || [ "$count" != 0 ]; }; then
        echo "stale words left (exit $code, seed $seed):"; cat ran.txt; exit 1
      fi
      if [ "$copy" = broken ] && { [ "$code" -ne 1 ] || [ -z "$count" ] || [ "$count" = 0 ]; }; then
        echo "the broken copy was not caught (exit $code, seed $seed):"; cat ran.txt; exit 1
      fi
      echo "  seed $seed: $count stale words"
    done
  done
done
echo "every hole written as zero; the broken copy left stale words in every run"
