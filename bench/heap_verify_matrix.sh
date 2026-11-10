#!/usr/bin/env bash
# heap22 slice S4's stress matrix: the std and runtime exercises built
# `-Dheap_partitions -Dheap_verify -Diyi_chaos` and run over chaos seeds
# with a local collection at every chaos point and every park
# (`IYI_HEAP_STRESS=1`), each seed once without and once with the false-word
# injector (`IYI_HEAP_FALSE_WORDS=1`). Odd seeds run on the simulated
# one-thread schedule (`IYI_WORKERS=1`), even seeds on the pool's threads.
#
#   bash bench/heap_verify_matrix.sh build NAME...         # one build each
#   bash bench/heap_verify_matrix.sh run NAME FIRST LAST   # seeds FIRST..LAST
#   bash bench/heap_verify_matrix.sh summary [NAME...]
#
# NAME is one of: concurrency (bench/concurrency_exercise.iyi), mutex
# (std_mutex_exercise), unit (std_unit_exercise), channel (chan_scaling's
# checked bare run), http (std_http_exercise), tls (std_tls_exercise), web
# (web_cores.iyi's pool server under bench/heap_verify_web.py, over https
# on seeds divisible by 4), crossings (heap_crossings), reach
# (heap_verify_reach: the trusted reach claims).
#
# Every run is one line of OUT/NAME/results: `seed words workers exit
# verdict detail`. The verdicts: `pass` (exit 0 and the program's line of
# success), `report` (an `iyi: heap_verify:` report: the run is kept as
# OUT/NAME/s<seed>w<words>.{out,err}), `poison` (a read of the
# poison-on-free pattern 0xdeaddeaddeaddead, or a crash), `hang` (ended at
# LIMIT seconds), `fail` (anything else). `summary` counts them.
#
# OUT defaults to $TMPDIR/heap_verify_matrix; IYI names the compiler;
# LIMIT the seconds a run may take (default 600).

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
OUT="${OUT:-${TMPDIR:-/tmp}/heap_verify_matrix}"
LIMIT="${LIMIT:-600}"
FLAGS="-Dheap_partitions -Dheap_verify -Diyi_chaos"
PY="${PYTHON:-python3}"
EXE=""
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) EXE=".exe" ;;
esac

source_of() {
  case "$1" in
    concurrency) echo bench/concurrency_exercise.iyi ;;
    mutex) echo bench/std_mutex_exercise.iyi ;;
    unit) echo bench/std_unit_exercise.iyi ;;
    channel) echo bench/chan_scaling.iyi ;;
    http) echo bench/std_http_exercise.iyi ;;
    tls) echo bench/std_tls_exercise.iyi ;;
    web) echo bench/web_cores.iyi ;;
    crossings) echo bench/heap_crossings.iyi ;;
    reach) echo bench/heap_verify_reach.iyi ;;
    *) echo "no program named $1" >&2; return 1 ;;
  esac
}

# The line a passing run prints, or empty where exit 0 is the verdict.
success_of() {
  case "$1" in
    concurrency) echo "concurrency exercise: every property held" ;;
    unit) echo "every property held" ;;
    http | tls) echo "ALL CHECKS PASSED" ;;
    crossings) echo "crossings hold" ;;
    reach) echo "trusted claims hold" ;;
    web) echo "requests answered as the reference" ;;
    *) echo "" ;;
  esac
}

build_one() {
  local name="$1" source dir
  source="$(source_of "$name")" || return 1
  dir="$OUT/$name"
  mkdir -p "$dir"
  # shellcheck disable=SC2086
  if ! IYI_DUMP_TYPE_INFO="$dir/types.json" "$IYI" build $FLAGS -o "$dir/program$EXE" "$REPO/$source" >"$dir/build.log" 2>&1; then
    echo "$name: build failed"
    tail -12 "$dir/build.log"
    return 1
  fi
  if [ "$name" = web ] && ! "$PY" "$REPO/bench/heap_verify_web.py" --program "$dir/program$EXE" --work "$dir/ref" --reference >"$dir/ref.log" 2>&1; then
    echo "web: the reference run failed: $(cat "$dir/ref.log")"
    return 1
  fi
  echo "$name: built"
}

run_one() {
  local name="$1" seed="$2" words="$3" dir workers tag code verdict detail ok
  dir="$OUT/$name"
  workers=$((seed % 2 == 1 ? 1 : 4))
  tag="s${seed}w${words}"
  ok="$(success_of "$name")"
  local -a env_words=(IYI_CHAOS="$seed" IYI_HEAP_STRESS=1)
  [ "$words" = 1 ] && env_words+=(IYI_HEAP_FALSE_WORDS=1)
  case "$name" in
    web)
      local tls=""
      [ $((seed % 4)) = 0 ] && tls="--tls"
      # shellcheck disable=SC2086
      env "${env_words[@]}" IYI_WORKERS="$workers" timeout -k 10 "$LIMIT" "$PY" "$REPO/bench/heap_verify_web.py" \
        --program "$dir/program$EXE" --work "$dir/w-$tag" --workers "$workers" --expect "$dir/ref/answers.json" $tls \
        >"$dir/$tag.out" 2>&1
      code=$?
      cp "$dir/w-$tag/server.err" "$dir/$tag.err" 2>/dev/null || : >"$dir/$tag.err"
      rm -rf "$dir/w-$tag"
      ;;
    unit)
      env "${env_words[@]}" IYI_WORKERS="$workers" timeout -k 10 "$LIMIT" "$dir/program$EXE" alone parks panic "--workers=$workers" \
        >"$dir/$tag.out" 2>"$dir/$tag.err"
      code=$?
      ;;
    *)
      env "${env_words[@]}" IYI_WORKERS="$workers" timeout -k 10 "$LIMIT" "$dir/program$EXE" \
        >"$dir/$tag.out" 2>"$dir/$tag.err"
      code=$?
      ;;
  esac
  detail=""
  if grep -q "^iyi: heap_verify: partition" "$dir/$tag.err"; then
    verdict=report
    detail="$(grep -A1 -m1 '^iyi: heap_verify: partition' "$dir/$tag.err" | tail -1 | sed 's/^ *//')"
    # The report named (types, fields, data symbols, sites) beside it.
    "$PY" "$REPO/bench/heap_verify_names.py" --types "$dir/types.json" --binary "$dir/program$EXE" \
      "$dir/$tag.err" >"$dir/$tag.named" 2>/dev/null
  elif grep -qi "deaddeaddeaddead" "$dir/$tag.err" "$dir/$tag.out"; then
    verdict=poison
    detail="$(grep -ih -m1 deaddeaddeaddead "$dir/$tag.err" "$dir/$tag.out" | head -1 | cut -c1-160)"
  elif [ "$code" = 124 ] || [ "$code" = 137 ]; then
    verdict=hang
  elif [ "$code" = 139 ] || [ "$code" = 134 ] || [ "$code" = 135 ] || grep -q "Invalid memory access\|Segmentation fault\|Access violation" "$dir/$tag.err"; then
    verdict=poison
    detail="crash: $(grep -m1 . "$dir/$tag.err" | cut -c1-160)"
  elif [ "$code" = 0 ] && { [ -z "$ok" ] || grep -q "$ok" "$dir/$tag.out"; }; then
    verdict=pass
  else
    verdict=fail
    detail="$( (grep -m1 'FAIL\|panic\|error' "$dir/$tag.out" "$dir/$tag.err" || tail -1 "$dir/$tag.err") | head -1 | cut -c1-160)"
  fi
  echo "$seed $words $workers $code $verdict $detail" >>"$dir/results"
  # Passing runs leave nothing behind.
  [ "$verdict" = pass ] && rm -f "$dir/$tag.out" "$dir/$tag.err"
  echo "$name seed $seed words $words workers $workers: $verdict $detail"
}

case "${1:-}" in
  build)
    shift
    status=0
    for name in "$@"; do build_one "$name" || status=1; done
    exit "$status"
    ;;
  run)
    name="$2"
    seed="$3"
    while [ "$seed" -le "$4" ]; do
      run_one "$name" "$seed" 0
      run_one "$name" "$seed" 1
      seed=$((seed + 1))
    done
    ;;
  summary)
    shift
    names="${*:-concurrency mutex unit channel http tls web crossings reach}"
    for name in $names; do
      [ -f "$OUT/$name/results" ] || continue
      awk -v name="$name" '
        { n++; v[$5]++; seeds[$1] = 1 }
        END {
          s = 0; for (k in seeds) s++
          printf "%s: %d runs over %d seeds: %d pass, %d report, %d poison, %d hang, %d fail\n", name, n, s, v["pass"], v["report"], v["poison"], v["hang"], v["fail"]
        }' "$OUT/$name/results"
      awk '$5 != "pass"' "$OUT/$name/results" | sed 's/^/    /'
    done
    ;;
  *)
    sed -n '2,26p' "$0"
    exit 2
    ;;
esac
