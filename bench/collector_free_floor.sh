#!/usr/bin/env bash
#
# The compiler built without a collector, compiling every sample.
#
# `-Dgc_none` swaps bdw-gc for plain `malloc` and `free`, and that turns a
# class of latent bug into a visible one: bdw-gc rounds a block up and never
# hands the same address out twice while something still points at it, so a
# write one byte past an allocation lands in padding nobody reads. Plain
# `malloc` hands back exactly the size asked for, and the next allocation
# overwrites the byte.
#
# That is what this measures, and it is not a hypothetical. `String::Builder`
# grew its buffer to `real_bytesize + count` while `to_s` writes the string's
# terminator at `@buffer[real_bytesize]`, so any string whose final size
# landed exactly on its capacity had its terminator outside its block. Under
# bdw-gc every program was fine. Under `-Dgc_none` a 116-byte mangled function
# name lost its terminator, LLVM's `strlen` read the next allocation, and
# `samples/iyi/collections.iyi` failed to link 10 times out of 10.
#
# So this is a floor, not a benchmark: a collector is a permitted dependency
# for the compiler, and a memory bug the collector is hiding is not permitted.
# Run it with the fix reverted and it fails; that is the point of it.
#
#   bash bench/collector_free_floor.sh
#
# Exits non-zero if the collector-free compiler cannot be built, if its link
# line still carries a collector, or if any sample fails to compile with it.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
status=0
RUNS="${COLLECTOR_FREE_RUNS:-3}"

cd "$REPO" || exit 1
export IYI_PATH="$REPO/src"

echo "== the compiler, built without a collector"
rm -f .build/iyi .build/crystal
if ! make -j8 FLAGS="-Dgc_none" > "$WORK/build.log" 2>&1; then
  echo "  FAIL: the compiler does not build with -Dgc_none"
  grep -aE "^Error|error:" "$WORK/build.log" | head -5 | sed 's/^/    /'
  rm -rf "$WORK"
  exit 1
fi
echo "  built"

echo
echo "== and its link line carries no collector"
# Named, because "no collector" is the claim and `gc_none` is only the flag
# that was passed: what settles it is what the binary actually links.
libs="$(otool -L .build/iyi 2>/dev/null || ldd .build/iyi 2>/dev/null)"
if printf '%s' "$libs" | grep -qE 'libgc'; then
  echo "  FAIL: a collector is still linked"
  printf '%s\n' "$libs" | grep -E 'libgc' | sed 's/^/    /'
  status=1
else
  echo "  no libgc"
fi

echo
echo "== every sample compiles with it, on a fresh cache each run"
# Fresh cache per run, because cache warmth decides which allocations happen
# in which order, and a reused cache made a real 9-of-10 failure look like a
# clean pass once.
failed=0
total=0
for source in "$REPO"/samples/iyi/*.iyi; do
  name="$(basename "$source" .iyi)"
  run=1
  while [ "$run" -le "$RUNS" ]; do
    total=$((total + 1))
    IYI_CACHE_DIR="$WORK/cache.$name.$run" \
      ./bin/iyi build -o "$WORK/out.$name" "$source" > "$WORK/$name.$run.log" 2>&1
    if [ $? -ne 0 ]; then
      failed=$((failed + 1))
      echo "  FAIL: samples/iyi/$name.iyi, run $run"
      grep -aE "Undefined symbols|Error|error:" "$WORK/$name.$run.log" \
        | head -3 | cut -c1-140 | sed 's/^/    /'
    fi
    run=$((run + 1))
  done
done
if [ "$failed" -gt 0 ]; then
  echo "  FAIL: $failed of $total builds failed without a collector"
  status=1
else
  echo "  $total builds, none failed"
fi

echo
echo "== the default build is unchanged"
rm -f .build/iyi .build/crystal
if make -j8 > "$WORK/default.log" 2>&1; then
  echo "  default build restored"
else
  echo "  FAIL: the default build broke"
  status=1
fi

rm -rf "$WORK"
exit $status
