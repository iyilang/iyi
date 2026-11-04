#!/usr/bin/env bash
# A `--release` build optimises on every core, and what it builds is the
# program one module would have made (`src/compiler/iyi/release_partition.cr`).
#
#     bash bench/release_cores.sh
#
# Four checks, each with a broken copy it has to catch:
#
#   1. Cores. `samples/iyi/cores.iyi` (std/http and TLS) built `--release`:
#      the build's processor time over its wall time is above 1.5. The broken
#      copy is the same build kept to one module (`IYI_RELEASE_PARTITIONS=1`),
#      which is one core and must come out below 1.2. With fewer than four
#      cores the check says so and is skipped.
#   2. The same program. Every sample the roundtrip runs, built `--release`
#      and cut into four partitions, prints what its one-module build
#      prints. The broken copy is `calc` with one character of its output
#      changed, which has to be told apart.
#   3. The same objects on any machine. One build's partition objects on one
#      thread and on four are the same bytes: the cut is the program's and
#      not the machine's. The broken copy cuts by the thread count, as
#      `IYI_RELEASE_PARTITIONS` set to `--threads` does, and has to differ.
#   4. Inlined across the cut. In check 3's build, no partition object
#      calls `__iyi_new` - external, called by every `new` - or
#      `IyiHeap.cache` - a thread-local's reader, inline assembly on Linux:
#      every partition inlined its copy, as one module inlines every call
#      to them. Two broken copies: one copies nothing
#      (`IYI_RELEASE_IMPORT=0 IYI_RELEASE_INLINE=0`) and has to be caught
#      calling either; one has no `available_externally` copies
#      (`IYI_RELEASE_INLINE=0`), the only kind an external function gets,
#      and has to be caught calling `__iyi_new`.
#
# Exits non-zero if any check fails or any broken copy passes.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d)"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    # Windows keeps one module unless told (`Compiler#release_partitions`);
    # `0` is the size's count, which every check here holds.
    export IYI_RELEASE_PARTITIONS=0
    ;;
esac
status=0
cores="${NUMBER_OF_PROCESSORS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"

# The processor and wall seconds of a `-s` build, summed over its stages.
cpu_over_wall() { # log
  awk '/s cpu/ {
         if (match($0, /[0-9]+:[0-9]+:[0-9.]+ \(/)) {
           split(substr($0, RSTART, RLENGTH - 2), hms, ":");
           wall += hms[1] * 3600 + hms[2] * 60 + hms[3]
         }
         if (match($0, /[0-9.]+s cpu/)) cpu += substr($0, RSTART, RLENGTH - 5) + 0
       }
       END { if (wall > 0) printf "%.2f %.2f %.2f\n", cpu / wall, cpu, wall; else print "0 0 0" }' "$1"
}

build_cores() { # name, then environment assignments
  local name="$1"
  shift
  env IYI_CACHE_DIR="$WORK/cache-$name" "$@" "$IYI" build --release --force -s \
    -o "$WORK/$name" "$REPO/samples/iyi/cores.iyi" > "$WORK/$name.log" 2>&1
}

# ── 1. Cores ─────────────────────────────────────────────────────────────
if [ "$cores" -lt 4 ]; then
  echo "cores: skipped, this machine has $cores and the check needs 4"
elif ! build_cores cores-default; then
  echo "cores: the build failed"; tail -12 "$WORK/cores-default.log"; status=1
elif ! build_cores cores-one IYI_RELEASE_PARTITIONS=1; then
  echo "cores: the one-module build failed"; tail -12 "$WORK/cores-one.log"; status=1
else
  read -r ratio cpu wall <<< "$(cpu_over_wall "$WORK/cores-default.log")"
  read -r one_ratio one_cpu one_wall <<< "$(cpu_over_wall "$WORK/cores-one.log")"
  if awk -v r="$ratio" 'BEGIN { exit !(r > 1.5) }'; then
    echo "cores: ${cpu} s of processor in ${wall} s, ${ratio} cores busy on $cores"
  else
    echo "cores: ${cpu} s of processor in ${wall} s is ${ratio} cores, not above 1.5"; status=1
  fi
  if awk -v r="$one_ratio" 'BEGIN { exit !(r < 1.2) }'; then
    echo "  broken copy, one module: ${one_cpu} s in ${one_wall} s, ${one_ratio} - caught"
  else
    echo "  broken copy, one module: ${one_ratio} cores busy, and one module is one core - not caught"; status=1
  fi
fi

# ── 2. The same program ──────────────────────────────────────────────────
# The samples `bench/samples_roundtrip.sh` runs, which print and exit.
SAMPLES="hello generics errors modules immutable collections init_order webapp derive calc format std_iterator std_text std_time"
cp -r "$REPO/samples/iyi/." "$WORK/samples/"
# The broken copy: `calc` printing one character differently.
sed 's/stderr.puts "error: #{value.message}"/stderr.puts "error; #{value.message}"/' \
  "$WORK/samples/calc.iyi" > "$WORK/samples/calc_broken.iyi"

release_output() { # sample, partitions, output name
  (cd "$WORK/samples" &&
    IYI_CACHE_DIR="$WORK/cache-$3" IYI_RELEASE_PARTITIONS="$2" "$IYI" build --release --force \
      -o "$WORK/$3" "$1.iyi" > "$WORK/$3.log" 2>&1) || return 1
  printf '1 / 0\n2 + 3 * 4\n' | "$WORK/$3" > "$WORK/$3.txt" 2>&1
  return 0
}

for sample in $SAMPLES; do
  if ! release_output "$sample" 1 "$sample-one"; then
    echo "$sample: the one-module build failed"; tail -8 "$WORK/$sample-one.log"; status=1; continue
  fi
  if ! release_output "$sample" 4 "$sample-four"; then
    echo "$sample: the build cut in four failed"; tail -8 "$WORK/$sample-four.log"; status=1; continue
  fi
  if cmp -s "$WORK/$sample-one.txt" "$WORK/$sample-four.txt"; then
    echo "$sample: cut in four, the same output as one module"
  else
    echo "$sample: OUTPUT DIFFERS between one module and four partitions"
    diff "$WORK/$sample-one.txt" "$WORK/$sample-four.txt" | head -8
    status=1
  fi
done
if ! release_output calc_broken 4 calc-broken; then
  echo "  broken copy, calc changed: the build failed"; tail -8 "$WORK/calc-broken.log"; status=1
elif cmp -s "$WORK/calc-one.txt" "$WORK/calc-broken.txt"; then
  echo "  broken copy, calc changed: the same output - not caught"; status=1
else
  echo "  broken copy, calc changed: told apart - caught"
fi

# ── 3. The same objects on any machine ───────────────────────────────────
objects() { # name, threads, then environment assignments
  local name="$1" threads="$2"
  shift 2
  env IYI_CACHE_DIR="$WORK/cache-$name" "$@" "$IYI" build --release --force --threads "$threads" \
    -o "$WORK/$name" "$REPO/samples/iyi/cores.iyi" > "$WORK/$name.log" 2>&1 || return 1
  (cd "$WORK/cache-$name" && find . -name '*.part*' | sort | while read -r file; do
    printf '%s %s\n' "$(basename "$file")" "$(cksum < "$file")"
  done) > "$WORK/$name.sums"
  [ -s "$WORK/$name.sums" ]
}

if ! objects one-thread 1 || ! objects four-threads 4; then
  echo "objects: a build failed or left no partitions"
  tail -8 "$WORK/one-thread.log" "$WORK/four-threads.log"; status=1
elif cmp -s "$WORK/one-thread.sums" "$WORK/four-threads.sums"; then
  echo "objects: $(wc -l < "$WORK/one-thread.sums" | tr -d ' ') partitions, the same bytes on one thread and on four"
else
  echo "objects: one thread and four made different partitions"
  diff "$WORK/one-thread.sums" "$WORK/four-threads.sums" | head -8; status=1
fi
if ! objects by-threads-2 2 IYI_RELEASE_PARTITIONS=2 || ! objects by-threads-4 4 IYI_RELEASE_PARTITIONS=4; then
  echo "  broken copy, cut by the thread count: a build failed"; status=1
elif cmp -s "$WORK/by-threads-2.sums" "$WORK/by-threads-4.sums"; then
  echo "  broken copy, cut by the thread count: the same objects - not caught"; status=1
else
  echo "  broken copy, cut by the thread count: different objects - caught"
fi

# ── 4. Inlined across the cut ────────────────────────────────────────────
# The symbols an object calls and does not define. Not its strings: debug
# information names every function inlined into it, and `__iyi_new` was
# in all 14 of `cores.iyi`'s partitions that way, called by none but its
# owner.
undefined_in() { # object
  if command -v nm > /dev/null 2>&1; then
    nm -u "$1"
  else
    dumpbin -nologo -symbols "$1" | awk '/ UNDEF / { print $NF }'
  fi
}
# How many partition objects of a build call a symbol matching *pattern*.
calling() { # name, pattern
  find "$WORK/cache-$1" -name '*.part*' | while read -r file; do
    if undefined_in "$file" | grep -q -E "$2"; then echo "$file"; fi
  done | wc -l | tr -d ' '
}
# `__iyi_new`, `___iyi_new` on darwin; `IyiHeap.cache` as each platform
# spells it, Windows' with its punctuation escaped.
NEW='(^|[[:space:]])_?__iyi_new$'
CACHE='IyiHeap(::|\.3A\.\.3A\.)cache(:|\.3A\.)Pointer'

if [ ! -s "$WORK/one-thread.sums" ]; then
  echo "inlined: no partitions to read, check 3's build failed"; status=1
else
  new=$(calling one-thread "$NEW") cache=$(calling one-thread "$CACHE")
  if [ "$new" -eq 0 ] && [ "$cache" -eq 0 ]; then
    echo "inlined: no partition calls __iyi_new or IyiHeap.cache across the cut"
  else
    echo "inlined: $new partitions call __iyi_new and $cache IyiHeap.cache across the cut"; status=1
  fi
  if ! objects no-import 4 IYI_RELEASE_IMPORT=0 IYI_RELEASE_INLINE=0; then
    echo "  broken copy, nothing copied: the build failed"; status=1
  else
    new=$(calling no-import "$NEW") cache=$(calling no-import "$CACHE")
    if [ "$new" -gt 0 ] || [ "$cache" -gt 0 ]; then
      echo "  broken copy, nothing copied: $new partitions call __iyi_new, $cache IyiHeap.cache - caught"
    else
      echo "  broken copy, nothing copied: no call across the cut - not caught"; status=1
    fi
  fi
  if ! objects no-inline 4 IYI_RELEASE_INLINE=0; then
    echo "  broken copy, no available_externally copy: the build failed"; status=1
  else
    new=$(calling no-inline "$NEW")
    if [ "$new" -gt 0 ]; then
      echo "  broken copy, no available_externally copy: $new partitions call __iyi_new - caught"
    else
      echo "  broken copy, no available_externally copy: no partition calls __iyi_new - not caught"; status=1
    fi
  fi
fi

rm -rf "$WORK"
exit $status
