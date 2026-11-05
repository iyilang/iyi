#!/usr/bin/env bash
# Where a plain spawn runs, from source and from artifacts, compared over
# generated programs (SPEC.md III.4.15, III.4.4).
#
#     bash bench/spawn_fuzz.sh
#
# `bench/spawn_fuzz.py` generates, by seed, small programs of two and three
# levels of modules - module state of Share types and of others, under
# `@[SafeReach]` and `@[UnsafeReach]` or none, written at module init,
# behind a lock, after a module's own spawn; reached directly, through
# calls, generics, blocks, procs, overloads, virtual and generic methods, a
# `pub macro`, a constant's initializer, a mid module and a `pub import`,
# and what std calls back - and a main program of plain spawns into them.
# Each is built from source, its refused claims taken out, and from the
# dependencies' artifacts with the sources gone, and:
#
#   1. Fixed seeds, in bounded time: no spawn the artifact build runs in
#      parallel that the source build keeps in its unit, the main
#      program's by `--explain-spawn` and each module's own by what its
#      artifact recorded; and both builds print on four workers, three
#      runs each, what the source build prints on one.
#   2. Failure proofs: a broken copy of the compiler on the artifact side
#      alone (`IYI_SPAWN_BROKEN`), each caught as a VIOLATION on a seed
#      that is clean without it: a walk that stops at std (`callbacks`,
#      seed 10), a function read from an artifact taken to reach nothing
#      (`headers`, seed 1), an artifact that takes every proven claim to
#      hold for every importer (`robust`, seed 66), and a module's own
#      spawn compiled into its artifact in parallel on a claim its
#      producer alone proved (`claimed`, seed 109).
#
# Seeds and minutes are `SPAWN_FUZZ_SEEDS` and `SPAWN_FUZZ_MINUTES`.
# 1,330 seeds were run by hand on Linux across the generator's versions,
# and seeds 3000-5999 with the fix for seeds 75 and 2046 found nothing
# (7,867 s, in chunks under 20 minutes). On Linux (12 vCPU) seeds 0-59
# took 148 s and the whole gate 170 s; CI's samples job ran this gate's
# neighbour `parallel_exercise.sh` in 1.02 to 1.45 times its 191 s there
# (runs 41921220664, 41831854057, 41868801917), so the gate adds about 3
# to 4 minutes to a job that took 46 to 78 of its 90.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
SEEDS="${SPAWN_FUZZ_SEEDS:-0-59}"
MINUTES="${SPAWN_FUZZ_MINUTES:-4}"
FUZZ=(python3 "$REPO/bench/spawn_fuzz.py" --iyi "$IYI")

echo "== seeds $SEEDS, at most $MINUTES minutes"
if ! "${FUZZ[@]}" "$SEEDS" --minutes "$MINUTES"; then
  echo "the artifact build ran a spawn in parallel that the source build keeps in its unit, or a build lost an update"; exit 1
fi

# Each seed is clean without the copy and caught with it: the first of
# seeds 0-300 that caught it.
proof() { # broken copy, seed, what it breaks
  echo "== failure proof: $3 (IYI_SPAWN_BROKEN=$1, seed $2)"
  if ! "${FUZZ[@]}" "$2" > "clean-$1.log" 2>&1; then
    echo "seed $2 is not clean without the broken copy:"; cat "clean-$1.log"; exit 1
  fi
  if ! "${FUZZ[@]}" "$2" --broken-artifact "$1" --expect VIOLATION > "proof-$1.log" 2>&1; then
    echo "the broken copy was not caught:"; cat "proof-$1.log"; exit 1
  fi
  echo "  caught: $(grep -m1 ': VIOLATION: ' "proof-$1.log" | sed 's/^[^:]*: VIOLATION: //' | cut -c1-160)"
}
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1
proof callbacks 10 "a walk that stops at std"
proof headers 1 "a function read from an artifact taken to reach nothing"
proof robust 66 "an artifact that takes every proven claim to hold for every importer"
proof claimed 109 "a module's own spawn compiled in parallel on a claim its producer alone proved"

echo "== spawn placement from artifacts: never more parallel than from source"
