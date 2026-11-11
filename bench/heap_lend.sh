#!/usr/bin/env bash
# heap22's lend protocol (design B row 15; contract sections 4 and 6, as
# amended in S6), driven: bench/heap_lend.iyi built with partitions and
# the verifier, plain and optimised, every check passing; stressed under
# chaos at a few seeds with no report; the flag-off control; then one
# broken copy per mechanism of the protocol and per stop of the walk
# through a lent graph, each caught by `-Dheap_verify` - exit 86, the
# report's holder and target named by bench/heap_verify_names.py, the
# same in every run.
#
#   bash bench/heap_lend.sh           # every part
#   bash bench/heap_lend.sh sound     # plain and optimised, verifier on
#   bash bench/heap_lend.sh stress    # IYI_HEAP_STRESS=1 under chaos, SEEDS
#   bash bench/heap_lend.sh off       # the flag-off control
#   bash bench/heap_lend.sh copies    # the broken copies
#
# Needs `make` first. `IYI` names the compiler, `RUNS` the runs of each
# copy (default 3), `SEEDS` the stress's chaos seeds (default "1 2 3"),
# `KEEP=DIR` keeps every build and run. A copy runs with
# `HEAP22_PRINT_ONLY=1`, so the program's own failed checks print and the
# verifier alone ends the run. Exits non-zero if a check fails, the
# stress reports, or a copy is missed or caught unnamed.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="${KEEP:-$(mktemp -d)}"
mkdir -p "$WORK"
PART="${1:-all}"
RUNS="${RUNS:-3}"
SEEDS="${SEEDS:-1 2 3}"
VERIFY="-Dheap_partitions -Dheap_verify"
PY="${PYTHON:-python3}"

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    PSEP=';'
    ;;
  *) PSEP=':' ;;
esac

[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT

status=0
TABLE="$WORK/table"
: >"$TABLE"

# whole LABEL NAME FLAGS [ENV...]: the program built with FLAGS, every
# check run; exit 0 and no report.
whole() {
  local label="$1" name="$2" flags="$3"
  shift 3
  # shellcheck disable=SC2086
  if ! "$IYI" build $flags -o "$WORK/$name" "$REPO/bench/heap_lend.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log" | sed 's/^/    /'
    status=1
    return
  fi
  env "$@" timeout 300 "$WORK/$name" >"$WORK/$name.out" 2>"$WORK/$name.err"
  local code=$?
  if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/$name.err"; then
    echo "  $label: exit $code"
    sed -n '1,12p' "$WORK/$name.out" "$WORK/$name.err" | sed 's/^/    /'
    status=1
    return
  fi
  echo "  $label: $(tail -1 "$WORK/$name.out")"
}

if [ "$PART" = all ] || [ "$PART" = sound ]; then
  echo "== the lend checks, verifier on ($VERIFY)"
  whole "plain" plain "$VERIFY"
  whole "optimised" release "$VERIFY --release"
fi

if [ "$PART" = all ] || [ "$PART" = stress ]; then
  echo "== stressed: a local collection at every chaos point and park, verifier on"
  for seed in $SEEDS; do
    if [ "$seed" = "$(echo "$SEEDS" | awk '{ print $1 }')" ]; then
      whole "seed $seed" stress "$VERIFY -Diyi_chaos" IYI_CHAOS="$seed" IYI_HEAP_STRESS=1
    else
      env IYI_CHAOS="$seed" IYI_HEAP_STRESS=1 timeout 300 "$WORK/stress" >"$WORK/stress-$seed.out" 2>"$WORK/stress-$seed.err"
      code=$?
      if [ "$code" -ne 0 ] || grep -q "^iyi: heap_verify: partition" "$WORK/stress-$seed.err"; then
        echo "  seed $seed: exit $code"
        sed -n '1,12p' "$WORK/stress-$seed.err" | sed 's/^/    /'
        status=1
      else
        echo "  seed $seed: $(tail -1 "$WORK/stress-$seed.out")"
      fi
    fi
  done
fi

if [ "$PART" = all ] || [ "$PART" = off ]; then
  echo "== the flag-off control"
  whole "flag off" off ""
fi

# One line deleted after a marker: `del MARKER LINE` as an awk program.
del() {
  printf '/%s/ { armed = 1 } armed && /%s/ { armed = 0; found = 1; next } { print } END { if (!found) exit 3 }' "$1" "$2"
}
# One line rewritten after a marker: `subst MARKER FROM TO`.
subst() {
  printf '/%s/ { armed = 1 } armed && sub(/%s/, "%s") { armed = 0; found = 1 } { print } END { if (!found) exit 3 }' "$1" "$2" "$3"
}

# The report of run TAG in DIR as one line, `check | holder | target`,
# its addresses masked: what must be the same in every run.
named() {
  local dir="$1" tag="$2"
  "$PY" "$REPO/bench/heap_verify_names.py" --types "$dir/types.json" --binary "$dir/program" \
    <"$dir/$tag.err" >"$dir/$tag.named" 2>/dev/null || cp "$dir/$tag.err" "$dir/$tag.named"
  awk '
    /^iyi: heap_verify: partition / && check == "" { getline; check = $0; sub(/^ +/, "", check) }
    /^  holder: / { kind = substr($0, 11) }
    /^    holder 0x/ { what = $0; sub(/^    holder 0x[0-9a-f]+ /, "", what); sub(/, [0-9]+ bytes$/, "", what) }
    /^    holder allocated at: / { made = $0; sub(/^    holder allocated at: /, "", made); what = what " made at " made }
    /^    field \+/ { field = $0; sub(/ at 0x[0-9a-f]+/, "", field); sub(/^ +/, "", field) }
    /^    word at / { field = $0; sub(/^ +/, "", field) }
    /^  target: / { intarget = 1 }
    intarget && /^    chunk / && target == "" { target = $0; sub(/^    chunk 0x[0-9a-f]+ /, "", target); sub(/, [0-9]+ bytes$/, "", target) }
    intarget && /allocated at: / && site == "" { site = $0; sub(/^ *allocated at: /, "", site) }
    END { printf "%s | %s: %s %s | %s @ %s\n", check, kind, what, field, target, site }
  ' "$dir/$tag.named" | sed -E 's/0x[0-9a-f]{6,}/0x…/g'
}

# copy LABEL DIR CHECK TREE FILE AWK: TREE/FILE (`iyi` or `std` under
# src/, or `bench` for the program itself) patched by AWK, the program
# built with the verifier against it, and CHECK run RUNS times with the
# program's checks print-only: caught when every run exits 86 with the
# same report, its holder named by type and field, a data symbol, or a
# stack.
copy() {
  local label="$1" dir="$WORK/$2" check="$3" tree="$4" file="$5" script="$6"
  mkdir -p "$dir"
  local program="$REPO/bench/heap_lend.iyi" path="$REPO/src"
  if [ "$tree" = bench ]; then
    program="$dir/heap_lend.iyi"
    if ! awk "$script" "$REPO/bench/$file" >"$program"; then
      echo "  $label: what the copy changes is not in bench/$file any more"
      status=1
      return
    fi
  else
    # Both trees, whichever the copy changes: the compiler takes a file
    # for std's only where its directory's parent holds iyi/prelude.iyi.
    cp -R "$REPO/src/iyi" "$REPO/src/std" "$dir/"
    if ! awk "$script" "$REPO/src/$tree/$file" >"$dir/$tree/$file"; then
      echo "  $label: what the copy changes is not in $tree/$file any more"
      status=1
      return
    fi
    path="$dir${PSEP}$REPO/src"
  fi
  # shellcheck disable=SC2086
  if ! env IYI_PATH="$path" IYI_DUMP_TYPE_INFO="$dir/types.json" "$IYI" build $VERIFY \
       -o "$dir/program" "$program" >"$dir/build.log" 2>&1; then
    echo "  $label: the patched tree did not build"
    sed -n '1,12p' "$dir/build.log" | sed 's/^/    /'
    status=1
    return
  fi
  local k=1 first="" row code
  while [ "$k" -le "$RUNS" ]; do
    HEAP22_PRINT_ONLY=1 timeout 120 "$dir/program" "$check" >"$dir/run$k.out" 2>"$dir/run$k.err"
    code=$?
    if [ "$code" -ne 86 ] || ! grep -q "^iyi: heap_verify: partition" "$dir/run$k.err"; then
      echo "  $label: run $k not caught by the verifier (exit $code$(grep -m1 '^FAIL: ' "$dir/run$k.out" | sed 's/^/, /'))"
      printf '| %s | %s | **missed** (run %s, exit %s) |\n' "$label" "$check" "$k" "$code" >>"$TABLE"
      status=1
      return
    fi
    row="$(named "$dir" "run$k")"
    if [ -z "$first" ]; then
      first="$row"
    elif [ "$row" != "$first" ]; then
      echo "  $label: run $k named another report: $row (run 1: $first)"
      status=1
    fi
    k=$((k + 1))
  done
  if ! echo "$first" | grep -q '#\|data segment\|stack of fiber'; then
    echo "  $label: caught, but the holder is not named: $first"
    status=1
  fi
  echo "  $label: $first"
  printf '| %s | %s | %s | %s |\n' "$label" "$check" "$first" "$(grep -m1 '^FAIL: ' "$dir/run1.out" | sed 's/^FAIL: //')" >>"$TABLE"
}

if [ "$PART" = all ] || [ "$PART" = copies ]; then
  echo "== each mechanism removed, caught by the verifier ($VERIFY, $RUNS runs each)"
  copy "lend_out publishes" c1 lend iyi heap_partition.iyi \
    "$(del 'def self\.lend_out_address' '^      lend_walk\(record, graph, LEND_PUBLISH\)$')"
  copy "the lend set roots the local mark" c2 lend iyi heap_partition.iyi \
    "$(del 'The lent graphs\.' 'lend_walk\(record, table_at\(record &\+ REC_LEND, k\), LEND_MARK\)')"
  copy "a unit's death lends out" c3 death iyi heap_partition.iyi \
    "$(del 'def self\.partition_death' 'lend_walk\(record, table_at\(lends, k\), LEND_PUBLISH\)')"
  copy "the lent root published" c4 root iyi heap_partition.iyi \
    "$(subst 'def self\.lend_walk' 'bytes = lend_meet\(s, record, id, parity, mode, graph, 0_u64, graph, true\)' 'bytes = 0_u64; scratch_push(s, lend_step(s, id, graph, true))')"
  copy "lent in at the take (a hand-back of a graph never lent)" c5 unlent bench heap_lend.iyi \
    "$(del 'def take : Slot' 'IyiHeap\.lend_in\(got\.res\)')"
  copy "a Mutex's writer publishes (the stop at born-shared types)" c6 mutex std mutex.iyi \
    "$(del 'def lock\(&block' '^    IyiCross\.publish\(block\)$')"
  copy "nothing behind another unit's chunk (the stop at foreign LOCAL)" c7 foreign bench heap_lend.iyi \
    "$(subst 'def hang_foreign' 'res\.items << item' 'foreign.item = item')"
  copy "the local mark follows a fiber's cleanups through a shared node" c8 defer iyi heap_partition.iyi \
    "$(del 'Its cleanups, node by node' '^          local_shade\(record, id, parity, node\.object_id\)$')"
  echo
  echo "| copy | check | caught by \\| holder \\| target @ allocation site | the program's own check, printed and passed over |"
  echo "|---|---|---|---|"
  cat "$TABLE"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "heap_lend: the protocol holds, and each mechanism and stop is caught by name when broken."
fi
exit "$status"
