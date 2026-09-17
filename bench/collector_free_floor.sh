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
echo "== every string constructor leaves room for its terminator"
# The samples above are the symptom and this is the property. A sample sweep
# only catches a missing terminator when some name happens to land on a size
# class, which is why the bug reached a 116-byte name and nothing smaller.
# This asks the question directly, at 3,000 lengths per constructor.
if IYI_CACHE_DIR="$WORK/probe-cache" \
     ./bin/crystal run --no-color -Dgc_none "$REPO/bench/terminator_room.cr" \
     > "$WORK/room.log" 2>&1; then
  grep -a "leaves room" "$WORK/room.log" | sed 's/^/  /'
else
  echo "  FAIL: a constructor allocates no room for the terminator"
  grep -aE "NO ROOM|Error" "$WORK/room.log" | head -6 | cut -c1-150 | sed 's/^/    /'
  status=1
fi

echo
echo "== the 30-module project compiles with it"
# 7,207 lines against 27 small samples: the size where a build allocates
# enough for a rare reuse to become a common one. Both failures that survived
# the first fix appeared here and nowhere else.
if python3 "$REPO/bench/incremental/generate_project.py" "$WORK/gen" \
     > "$WORK/gen.log" 2>&1 && [ -f "$WORK/gen/iyi/main.iyi" ]; then
  big_failed=0
  run=1
  while [ "$run" -le "$RUNS" ]; do
    IYI_CACHE_DIR="$WORK/bigcache.$run" \
      ./bin/iyi build -o "$WORK/big.$run" "$WORK/gen/iyi/main.iyi" \
      > "$WORK/big.$run.log" 2>&1
    if [ $? -ne 0 ]; then
      big_failed=$((big_failed + 1))
      echo "  FAIL: the 30-module project, run $run"
      grep -aoE "Trace/BPT trap|Undefined symbols|read before assignment[^']*'[^']*'|Error[^,]{0,60}" \
        "$WORK/big.$run.log" | head -2 | sed 's/^/    /'
    fi
    run=$((run + 1))
  done
  if [ "$big_failed" -gt 0 ]; then
    echo "  FAIL: $big_failed of $RUNS builds of the project failed"
    status=1
  else
    echo "  $RUNS builds, none failed"
  fi
else
  echo "  FAIL: could not generate the project to build"
  status=1
fi

echo
echo "== and they build with bdw-gc unreachable, not merely absent from the link line"
# A library the binaries do not link can still be a library the build needs,
# and two obvious ways of checking that are worthless. Unsetting LIBRARY_PATH
# proves nothing, because brew symlinks libgc into a directory already on the
# search path. Emptying CRYSTAL_LIBRARY_PATH proves nothing either, because
# `@[Link("gc", pkg_config: "bdw-gc")]` emits its own -L from pkg-config. Both
# were tried here and both passed while the dependency was still required.
#
# Blanking pkg-config as well is what makes it genuinely unreachable, and
# `pkg-config --libs bdw-gc` failing first is the control: without it this
# section would pass on a machine where the isolation silently did nothing.
EMPTY="$WORK/no-libs"
mkdir -p "$EMPTY"
if env PKG_CONFIG_LIBDIR="$EMPTY" PKG_CONFIG_PATH="$EMPTY" \
     pkg-config --libs bdw-gc > "$WORK/pc.log" 2>&1; then
  echo "  FAIL: the isolation does not isolate, pkg-config still finds bdw-gc"
  status=1
else
  echo "  pkg-config cannot find bdw-gc, so the isolation holds"
  rm -f .build/iyi .build/crystal
  if env -u LIBRARY_PATH PKG_CONFIG_LIBDIR="$EMPTY" PKG_CONFIG_PATH="$EMPTY" \
       CRYSTAL_LIBRARY_PATH="$EMPTY" make -j8 > "$WORK/isolated.log" 2>&1; then
    echo "  the binaries build with no bdw-gc reachable"
  else
    echo "  FAIL: the build needs bdw-gc installed"
    grep -aoE "library not found for -l[a-z0-9+_]+|ld: .{0,60}" "$WORK/isolated.log" \
      | sort -u | head -3 | sed 's/^/    /'
    status=1
  fi
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
