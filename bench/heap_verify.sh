#!/usr/bin/env bash
# heap22 slice S4's gate: `-Dheap_verify` catches every broken copy of a
# crossing or of the local collector by name, and passes the sound tree.
#
#   bash bench/heap_verify.sh             # every part
#   bash bench/heap_verify.sh sound       # the sound tree: no report, false words change nothing
#   bash bench/heap_verify.sh simulated   # the sound tree on the one-thread schedule, over SIM_SEEDS
#   bash bench/heap_verify.sh crossings   # bench/heap_crossings.sh's copies
#   bash bench/heap_verify.sh local       # bench/heap_local.sh's copies
#   bash bench/heap_verify.sh own         # copies of the stress and the simulation themselves
#
# Every build is `-Dheap_partitions -Dheap_verify -Diyi_chaos`, run with a
# fixed chaos seed (`SEED`, default 1) and `IYI_HEAP_STRESS=1` (a local
# collection at every chaos point and every park), `RUNS` times (default
# 2). The broken copies are the ones bench/heap_crossings.sh and
# bench/heap_local.sh define - read from those files, so the two lists
# stay one - built and run here against the verifier instead of their own
# checks: each copy runs with `HEAP22_PRINT_ONLY=1`, so the program's own
# failed checks print their `FAIL:` line and the run goes on, and only
# the verifier ends it. A copy is caught when every run exits 86 with an
# `iyi: heap_verify:` report whose holder `bench/heap_verify_names.py`
# names (a type and its field, a data symbol, or a fiber's stack) and
# whose name is the same in every run. The table of catches is printed at
# the end: the copy, the verifier's check that caught it, the holder and
# the target named, and the program's own first `FAIL:` line, printed
# and passed over. Copies whose loss no heap word can show are listed
# apart with what catches them (`VALUE_COPIES`). `KEEP=DIR` keeps every
# build and run in DIR.
#
# `simulated` runs bench/heap_crossings.iyi and bench/heap_verify.iyi with
# `IYI_WORKERS=1` at each seed of `SIM_SEEDS` (default 1 to 5): every
# check holds and nothing reports. `own` breaks what this slice adds - a
# simulated unit's fibers kept on the simulation's thread, its crossing
# made as the pool's is, no chaos point inside a publication walk - each
# caught by the check named beside it, the same way in every run: a
# report, a `FAIL:` line, a deadlock named, or a hang ended at `HANG`
# seconds (default 60).
#
# Needs `make` first. `IYI` names the compiler. Exits non-zero if any copy
# is missed or the sound tree reports.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="${KEEP:-$(mktemp -d)}"
mkdir -p "$WORK"
PART="${1:-all}"
SEED="${SEED:-1}"
RUNS="${RUNS:-2}"
SIM_SEEDS="${SIM_SEEDS:-1 2 3 4 5}"
HANG="${HANG:-60}"
FLAGS="-Dheap_partitions -Dheap_verify -Diyi_chaos"
PY="${PYTHON:-python3}"
# The copies whose loss changes a value, not a heap word: a Share type's
# getter that lends its array is a mutation of the shared graph, which the
# program's own check sees (heap_crossings' `tls`).
VALUE_COPIES="TlsIdentity chain copy"

# heap_crossings.sh's copies, sourced below, skip what Windows lacks.
WINDOWS=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    WINDOWS=1
    ;;
  *) PSEP=':' ;;
esac

[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT

status=0
TABLE="$WORK/table"
: >"$TABLE"

# build DIR SOURCE [IYI_PATH]: the program and its type dump in DIR.
build() {
  local dir="$1" source="$2" path="${3:-}"
  mkdir -p "$dir"
  # shellcheck disable=SC2086
  if [ -n "$path" ]; then
    IYI_DUMP_TYPE_INFO="$dir/types.json" IYI_PATH="$path" "$IYI" build $FLAGS \
      -o "$dir/program" "$source" >"$dir/build.log" 2>&1
  else
    IYI_DUMP_TYPE_INFO="$dir/types.json" "$IYI" build $FLAGS \
      -o "$dir/program" "$source" >"$dir/build.log" 2>&1
  fi
}

# verified DIR TAG ARGS...: one stressed run; exit code in DIR/TAG.code.
# `WORKERS` sets IYI_WORKERS, `LIMIT` the seconds before a hang is ended,
# `PRINT=1` the program's print-only checks (HEAP22_PRINT_ONLY).
verified() {
  local dir="$1" tag="$2"
  shift 2
  env IYI_CHAOS="$SEED" IYI_HEAP_STRESS=1 ${WORKERS:+IYI_WORKERS=$WORKERS} ${PRINT:+HEAP22_PRINT_ONLY=1} \
    timeout "${LIMIT:-300}" "$dir/program" "$@" >"$dir/$tag.out" 2>"$dir/$tag.err"
  echo $? >"$dir/$tag.code"
}

# The verifier's check that reported in run TAG: the line under the
# report's `iyi: heap_verify: partition ...` header.
check_of() {
  awk '/^iyi: heap_verify: partition / && !/checked/ { getline; sub(/^ +/, ""); sub(/[:,]$/, ""); print; exit }' "$1/$2.err"
}

# The program's own first failed check in run TAG, printed and passed
# over, or `-`.
program_saw() {
  local line
  line="$(grep -m1 '^FAIL: ' "$1/$2.out" | sed 's/^FAIL: //')"
  echo "${line:--}"
}

# The report's holder and target, named, as one line: `holder | target`.
named() {
  local dir="$1" tag="$2"
  "$PY" "$REPO/bench/heap_verify_names.py" --types "$dir/types.json" --binary "$dir/program" \
    "$dir/$tag.err" >"$dir/$tag.named" 2>/dev/null
  awk '
    /^  holder: / { kind = substr($0, 11) }
    /^    holder / { what = $0; sub(/^    holder 0x[0-9a-f]+ /, "", what); sub(/, [0-9]+ bytes$/, "", what) }
    /^    field \+/ { field = $0; if (match(field, /\[[^]]*\]$/)) field = substr(field, RSTART + 1, RLENGTH - 2); else { sub(/ at 0x.*/, "", field); sub(/^ +/, "", field) } }
    /^    held by / && parent == "" { parent = $0; sub(/^    held by (0x[0-9a-f]+ )?/, "", parent); sub(/, [0-9]+ bytes$/, "", parent) }
    /^    held by / && /\[/ && parentfield == "" { }
    /^    word at / { word = $0; if (match(word, /\[[^]]*\]$/)) word = substr(word, RSTART + 1, RLENGTH - 2); else word = "" }
    /^  target: / { intarget = 1 }
    intarget && /^    chunk / && target == "" { target = $0; sub(/^    chunk 0x[0-9a-f]+ /, "", target); sub(/, [0-9]+ bytes$/, "", target) }
    intarget && /allocated at: / && site == "" { site = $0; if (match(site, /\[[^]]*\]$/)) site = substr(site, RSTART + 1, RLENGTH - 2); else { sub(/^ *allocated at: /, "", site) } ; sub(/ <- .*/, "", site) }
    /^  [a-z]/ && !/^  (holder|target):/ && first == "" { first = $0; sub(/^  /, "", first) }
    END {
      h = kind
      if (what != "") h = h ": " what
      if (field != "") h = h " / " field
      if (parent != "") h = h " (held by " parent ")"
      if (word != "") h = h " [" word "]"
      if (h == "") h = first
      t = target
      if (site != "") t = t " @ " site
      printf "%s | %s\n", h, t
    }' "$dir/$tag.named"
}

# caught LABEL DIR ARGS...: RUNS stressed runs of DIR's program with the
# program's checks print-only, each ended by a report, the same check and
# holder named in all; a row of the table.
caught() {
  local label="$1" dir="$2"
  shift 2
  local k=1 first="" row check
  while [ "$k" -le "$RUNS" ]; do
    PRINT=1 verified "$dir" "run$k" "$@"
    if [ "$(cat "$dir/run$k.code")" != 86 ] || ! grep -q "^iyi: heap_verify: " "$dir/run$k.err"; then
      local how="exit $(cat "$dir/run$k.code")"
      grep -q "^FAIL: " "$dir/run$k.out" && how="$how, $(grep -m1 '^FAIL: ' "$dir/run$k.out")"
      if [[ ",$VALUE_COPIES," == *",$label,"* ]] && grep -q "^FAIL: " "$dir/run$k.out"; then
        printf '| %s | none: a value, not a heap word | | | %s |\n' "$label" "$(program_saw "$dir" "run$k")" >>"$TABLE"
        echo "  $label: no heap word to see; the program's check: $how"
        return
      fi
      echo "  $label: run $k not caught by the verifier ($how)"
      sed -n '1,6p' "$dir/run$k.err" | sed 's/^/      /'
      printf '| %s | **missed** (run %s: %s) | | | %s |\n' "$label" "$k" "$how" "$(program_saw "$dir" "run$k")" >>"$TABLE"
      status=1
      return
    fi
    row="$(check_of "$dir" "run$k") | $(named "$dir" "run$k")"
    if [ -z "$first" ]; then
      first="$row"
    elif [ "$row" != "$first" ]; then
      echo "  $label: run $k named another check or holder: $row (run 1: $first)"
    fi
    k=$((k + 1))
  done
  echo "  $label: $first"
  printf '| %s | %s | %s |\n' "$label" "$first" "$(program_saw "$dir" run1)" >>"$TABLE"
  check="$(check_of "$dir" run1)"
  case "$check" in
    *"slot names"*)
      if ! echo "$first" | grep -q '#\|\[.*\]\|stack of fiber\|data segment'; then
        echo "  $label: caught, but the holder is not named by type and field"
        status=1
      fi
      ;;
  esac
}

# `ONLY=r1,r3g,o2`: only the copies of those directory names.
chosen() {
  [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]
}

# heap_crossings.sh's interface: label dir check-name awk-script tree file.
prove_caught() {
  local label="$1" dir="$2" check="$3" script="$4" tree="$5" file="$6"
  chosen "$dir" || return 0
  mkdir -p "$WORK/$dir/$tree"
  cp -R "$REPO/src/$tree/." "$WORK/$dir/$tree/"
  if ! awk "$script" "$REPO/src/$tree/$file" >"$WORK/$dir/$tree/$file"; then
    echo "  $label: what the copy changes is not in $tree/$file any more"
    status=1
    return
  fi
  if ! build "$WORK/$dir/b" "$REPO/bench/heap_crossings.iyi" "$WORK/$dir${PSEP}$REPO/src"; then
    echo "  $label: the patched tree did not build"
    sed -n '1,12p' "$WORK/$dir/b/build.log"
    status=1
    return
  fi
  caught "$label" "$WORK/$dir/b" "$check"
}

# heap_local.sh's interface: label dir phrase awk-script file (src/iyi).
prove_fails() {
  local label="$1" dir="$2" script="$4" file="$5"
  chosen "$dir" || return 0
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" >"$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  if ! build "$WORK/$dir/b" "$REPO/bench/heap_local.iyi" "$WORK/$dir${PSEP}$REPO/src"; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/b/build.log"
    status=1
    return
  fi
  caught "$label" "$WORK/$dir/b"
}

# sound NAME SOURCE ARGS...: no report, and the false words change nothing.
sound() {
  local name="$1" source="$2"
  shift 2
  local dir="$WORK/sound-$name"
  if ! build "$dir" "$source"; then
    echo "  $name: build failed"
    sed -n '1,12p' "$dir/build.log"
    status=1
    return
  fi
  verified "$dir" plain "$@"
  IYI_HEAP_FALSE_WORDS=1 verified "$dir" words "$@"
  local tag
  for tag in plain words; do
    if [ "$(cat "$dir/$tag.code")" != 0 ] || grep -q "heap_verify: " "$dir/$tag.err"; then
      echo "  $name ($tag): exit $(cat "$dir/$tag.code")"
      named "$dir" "$tag" >/dev/null
      sed -n '1,30p' "$dir/$tag.named" | sed 's/^/      /'
      sed -n '1,10p' "$dir/$tag.out" | sed 's/^/      /'
      status=1
      return
    fi
  done
  if ! cmp -s "$dir/plain.out" "$dir/words.out"; then
    echo "  $name: the false words changed the output"
    diff "$dir/plain.out" "$dir/words.out" | sed -n '1,10p' | sed 's/^/      /'
    status=1
    return
  fi
  echo "  $name: no report, output identical with false words ($(wc -l <"$dir/plain.out") lines)"
}

# simulated NAME SOURCE: the sound program on the one-thread schedule at
# every seed of SIM_SEEDS, stressed: exit 0, no report.
simulated() {
  local name="$1" source="$2"
  local dir="$WORK/sound-$name"
  if [ ! -x "$dir/program" ] && ! build "$dir" "$source"; then
    echo "  $name: build failed"
    sed -n '1,12p' "$dir/build.log"
    status=1
    return
  fi
  local seed
  for seed in $SIM_SEEDS; do
    SEED="$seed" WORKERS=1 verified "$dir" "sim$seed"
    if [ "$(cat "$dir/sim$seed.code")" != 0 ] || grep -q "heap_verify: " "$dir/sim$seed.err"; then
      echo "  $name (simulated, seed $seed): exit $(cat "$dir/sim$seed.code")"
      named "$dir" "sim$seed" >/dev/null
      sed -n '1,30p' "$dir/sim$seed.named" | sed 's/^/      /'
      sed -n '1,10p' "$dir/sim$seed.out" | sed 's/^/      /'
      status=1
      return
    fi
  done
  echo "  $name: simulated, seeds $SIM_SEEDS: every check holds, no report"
}

# How run TAG of DIR's program failed, as one line: the verifier's report
# named, the program's `FAIL:` line, a deadlock named, a hang, or the exit.
how_failed() {
  local dir="$1" tag="$2" code
  code="$(cat "$dir/$tag.code")"
  if [ "$code" = 86 ] && grep -q "^iyi: heap_verify: " "$dir/$tag.err"; then
    echo "the verifier: $(named "$dir" "$tag")"
  elif grep -q "^FAIL: " "$dir/$tag.out"; then
    echo "the program's check: $(grep -m1 '^FAIL: ' "$dir/$tag.out" | sed 's/^FAIL: //')"
  elif grep -q "deadlock: every fiber is blocked" "$dir/$tag.err"; then
    echo "a deadlock named (exit $code)"
  elif [ "$code" = 124 ]; then
    echo "a hang, ended at ${LIMIT:-300} s"
  elif [ "$code" != 0 ]; then
    echo "exit $code: $(grep -m1 . "$dir/$tag.err")"
  fi
}

# own_caught LABEL DIR SOURCE CHECK AWK FILE: src/iyi/FILE patched by AWK,
# SOURCE built against it and its CHECK run RUNS times (with `WORKERS` as
# set); caught when every run fails, the same way.
own_caught() {
  local label="$1" dir="$2" source="$3" check="$4" script="$5" file="$6"
  chosen "$dir" || return 0
  mkdir -p "$WORK/$dir/iyi"
  cp -R "$REPO/src/iyi/." "$WORK/$dir/iyi/"
  if ! awk "$script" "$REPO/src/iyi/$file" >"$WORK/$dir/iyi/$file"; then
    echo "  $label: what the copy changes is not in $file any more"
    status=1
    return
  fi
  if ! build "$WORK/$dir/b" "$source" "$WORK/$dir${PSEP}$REPO/src"; then
    echo "  $label: the patched runtime did not build"
    sed -n '1,12p' "$WORK/$dir/b/build.log"
    status=1
    return
  fi
  local k=1 first="" row
  while [ "$k" -le "$RUNS" ]; do
    LIMIT="$HANG" verified "$WORK/$dir/b" "run$k" "$check"
    row="$(LIMIT="$HANG" how_failed "$WORK/$dir/b" "run$k")"
    if [ -z "$row" ]; then
      echo "  $label: run $k passed: not caught"
      printf '| %s | **missed** (run %s passed) | | | |\n' "$label" "$k" >>"$TABLE"
      status=1
      return
    fi
    if [ -z "$first" ]; then
      first="$row"
    elif [ "$row" != "$first" ]; then
      echo "  $label: run $k failed another way: $row (run 1: $first)"
      status=1
    fi
    k=$((k + 1))
  done
  echo "  $label ($check${WORKERS:+, IYI_WORKERS=$WORKERS}): $first"
  printf '| %s | %s | | | |\n' "$label" "$first" >>"$TABLE"
}

# One line deleted after a marker: `del MARKER LINE` as an awk program.
del() {
  printf '/%s/ { armed = 1 } armed && /%s/ { armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' "$1" "$2"
}
# One line rewritten after a marker: `subst MARKER FROM TO`.
subst() {
  printf '/%s/ { armed = 1 } armed && sub(/%s/, "%s") { armed = 0; found = 1 } { print } END { if (!found) exit 3 }' "$1" "$2" "$3"
}
# A line added after the first line matching LINE past MARKER: `add
# MARKER LINE TEXT`.
add() {
  printf '/%s/ { armed = 1 } { print } armed && /%s/ { print "%s"; armed = 0; found = 1 } END { if (!found) exit 3 }' "$1" "$2" "$3"
}

if [ "$PART" = all ] || [ "$PART" = sound ]; then
  echo "== the sound tree, stressed (seed $SEED): no report"
  sound crossings "$REPO/bench/heap_crossings.iyi"
  sound local "$REPO/bench/heap_local.iyi"
  sound verify "$REPO/bench/heap_verify.iyi"
fi

if [ "$PART" = all ] || [ "$PART" = simulated ]; then
  echo
  echo "== the sound tree on the one-thread schedule (IYI_WORKERS=1), stressed: no report"
  simulated crossings "$REPO/bench/heap_crossings.iyi"
  simulated verify "$REPO/bench/heap_verify.iyi"
fi

if [ "$PART" = all ] || [ "$PART" = crossings ]; then
  echo
  echo "== bench/heap_crossings.sh's copies, caught by the verifier"
  # The copies as heap_crossings.sh writes them, from its `del` to its last.
  # shellcheck disable=SC1090
  source <(awk '/^# One line deleted after a marker/ { on = 1 } on && /^echo$/ { exit } on { print }' "$REPO/bench/heap_crossings.sh")
fi

if [ "$PART" = all ] || [ "$PART" = local ]; then
  echo
  echo "== bench/heap_local.sh's copies, caught by the verifier"
  # shellcheck disable=SC1090
  source <(awk '/== the checks fail when a mechanism is broken/ { on = 1; next } on && /^fi$/ { exit } on { print }' "$REPO/bench/heap_local.sh")
fi

if [ "$PART" = all ] || [ "$PART" = own ]; then
  echo
  echo "== the stress's and the simulation's own mechanisms, broken"
  # A simulated unit's fiber woken onto the pool, whose workers never
  # take it.
  WORKERS=1 own_caught "simulated unit kept home" o1 "$REPO/bench/heap_verify.iyi" kept \
    "$(del 'def self\.ready\(fiber' 'fiber\.homebound = true if IyiChaos\.kept\?\(fiber\)')" concurrency.iyi
  # A simulated crossing's glue made in the spawner's partition and never
  # published: the fiber's closure, local, held by the shared fiber.
  WORKERS=1 own_caught "simulated crossing glue shared" o2 "$REPO/bench/heap_crossings.iyi" glue \
    "$(subst 'private def chaos_task' 'task = IyiCross\.shared do' 'task = begin')" chaos.iyi
  # A chaos point's stress collection inside the publication walk, which
  # heap_partition.iyi had while the compiler did not count it as the
  # runtime's: the collection takes the walk's scratch stack from under
  # it, and what was still on it is never published.
  own_caught "no point inside a publication walk" o4 "$REPO/bench/heap_crossings.iyi" spawn \
    "$(add 'def self\.publish_walk' 'scratch_push\(s, found\)' '          {% if flag?(:heap_verify) %} IyiHeapVerify.at_point {% end %}')" heap_partition.iyi
fi

echo
echo "Seed $SEED (IYI_CHAOS), IYI_HEAP_STRESS=1, $RUNS runs each; copies run with HEAP22_PRINT_ONLY=1."
echo
echo "| copy | caught by (the verifier's check; own copies: how the run failed) | holder (heap, type / field) | target @ allocation site | the program's own check, printed and passed over |"
echo "|---|---|---|---|---|"
cat "$TABLE"
echo
if [ "$status" -eq 0 ]; then
  echo "heap_verify: the sound tree passes, and every copy is caught by name."
fi
exit "$status"
