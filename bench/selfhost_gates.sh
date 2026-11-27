#!/usr/bin/env bash
# Runs every self-host and native compiler component gate, one after another, and
# prints one verdict line per gate. The gates share the checkout (several mutate
# sources and rebuild the compiler), so they never run in parallel, and a shard's
# gates run one after another too.
#
#   bash bench/selfhost_gates.sh               # every gate, in one run
#   bash bench/selfhost_gates.sh --shard 2/4   # the second of four shards
#   bash bench/selfhost_gates.sh --list        # the deal into four shards; runs none
#   bash bench/selfhost_gates.sh --list 3      # the deal into three
#
# CI runs one job per shard on each host, so no job holds every gate. The deal is
# by weight, the way bench/std_siblings.sh deals its shards: every gate, heaviest
# first, goes to the shard with the least weight so far (the first such shard on a
# tie, and gates of one weight by name), so the same gates land together everywhere.
# The weights are in bench/selfhost_gates.weights, with where each number came from.
# A gate with no weight is dealt at DEFAULT_WEIGHT and printed as unweighted, so a
# run measures it. A weight for a gate that does not exist is ignored.
#
# Each gate's full output goes to a log under $SELFHOST_GATE_LOGS (default: a fresh
# temporary directory), is printed after the gate ends, and is retained by CI.
# Exit status is 0 only when every gate it runs exits 0.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WEIGHTS="$REPO/bench/selfhost_gates.weights"
DEFAULT_SHARDS=4
DEFAULT_WEIGHT=300

mode=all
shard=0
shards=0
if [ "$#" -gt 0 ]; then
  case "$1" in
    --shard)
      if [ "$#" -ne 2 ]; then
        echo "bench/selfhost_gates.sh: --shard takes one K/N, such as --shard 2/4" >&2
        exit 2
      fi
      case "$2" in
        */*) shard="${2%%/*}"; shards="${2#*/}" ;;
        *) echo "bench/selfhost_gates.sh: --shard $2: want K/N, such as 2/4" >&2; exit 2 ;;
      esac
      case "$shard" in "" | *[!0-9]*) echo "bench/selfhost_gates.sh: --shard $2: K is not a number" >&2; exit 2 ;; esac
      case "$shards" in "" | *[!0-9]*) echo "bench/selfhost_gates.sh: --shard $2: N is not a number" >&2; exit 2 ;; esac
      if [ "$shards" -lt 1 ] || [ "$shard" -lt 1 ] || [ "$shard" -gt "$shards" ]; then
        echo "bench/selfhost_gates.sh: --shard $2: shard $shard is not in 1 to $shards" >&2
        exit 2
      fi
      mode=shard ;;
    --list)
      if [ "$#" -gt 2 ]; then
        echo "bench/selfhost_gates.sh: --list takes at most one number, the shard count N" >&2
        exit 2
      fi
      shards="${2:-$DEFAULT_SHARDS}"
      case "$shards" in "" | *[!0-9]*) echo "bench/selfhost_gates.sh: --list $shards: N is not a number" >&2; exit 2 ;; esac
      if [ "$shards" -lt 1 ]; then
        echo "bench/selfhost_gates.sh: --list $shards: N is at least 1" >&2
        exit 2
      fi
      mode=list ;;
    *)
      echo "bench/selfhost_gates.sh: unknown argument '$1' (usage: bash bench/selfhost_gates.sh [--shard K/N | --list [N]])" >&2
      exit 2 ;;
  esac
fi

gates=()
for gate in "$REPO"/bench/selfhost_*_exercise.sh; do
  [ -f "$gate" ] && gates+=("$gate")
done
for gate in "$REPO"/bench/native_*_exercise.sh; do
  [ -f "$gate" ] && gates+=("$gate")
done
if [ "${#gates[@]}" -eq 0 ]; then
  echo "== 0. no compiler component gates found"
  echo "SOME SELFHOST GATES FAILED"
  exit 1
fi

# "NAME WEIGHT [unweighted]" for every gate, heaviest first, by name on a tie.
# Then "SHARD WEIGHT NAME [unweighted]", each gate to the lightest shard so far.
deal() {
  local table
  table="$(awk '$1 ~ /^(selfhost|native)_/ && $2 ~ /^[0-9]+$/ { printf "%s %s ", $1, $2 }' "$WEIGHTS")"
  for gate in "${gates[@]}"; do
    basename "$gate" .sh
  done | awk -v table="$table" -v dflt="$DEFAULT_WEIGHT" '
    BEGIN { n = split(table, t, " "); for (i = 1; i < n; i += 2) w[t[i]] = t[i + 1] }
    { if ($1 in w) print $1, w[$1]; else print $1, dflt, "unweighted" }' |
    LC_ALL=C sort -k2,2nr -k1,1 |
    awk -v n="$shards" '{
      k = 1
      for (i = 2; i <= n; i++) if (load[i] < load[k]) k = i
      load[k] += $2
      if ($3 != "") print k, $2, $1, $3; else print k, $2, $1 }'
}

dealt=""
if [ "$mode" != all ]; then
  [ -f "$WEIGHTS" ] || { echo "FAIL: the weights file $WEIGHTS is missing"; exit 1; }
  dealt="$(deal)"
  # A deal that does not hold every gate once is refused before anything runs: a
  # gate dropped from every shard would pass by never running.
  dealt_lines=$(printf '%s\n' "$dealt" | awk -v n="$shards" 'NF >= 3 && $1 >= 1 && $1 <= n' | wc -l | tr -d ' ')
  dealt_names=$(printf '%s\n' "$dealt" | awk 'NF >= 3 { print $3 }' | LC_ALL=C sort -u | wc -l | tr -d ' ')
  if [ "$dealt_lines" -ne "${#gates[@]}" ] || [ "$dealt_names" -ne "${#gates[@]}" ]; then
    echo "FAIL: the deal holds $dealt_lines lines and $dealt_names gates, not each of the ${#gates[@]} once"
    exit 1
  fi
fi

if [ "$mode" = list ]; then
  echo "# the self-host gates dealt into $shards shards by $(basename "$WEIGHTS") (SHARD WEIGHT NAME; seconds on the slowest host)"
  printf '%s\n' "$dealt" | LC_ALL=C sort -s -k1,1n
  printf '%s\n' "$dealt" | awk -v n="$shards" '{ c[$1]++; s[$1] += $2 }
    END { for (k = 1; k <= n; k++) printf "# shard %d of %d: %d of %d gates, %d s by the weights\n", k, n, c[k], NR, s[k] }'
  exit 0
fi

LOGDIR="${SELFHOST_GATE_LOGS:-$(mktemp -d)}"
mkdir -p "$LOGDIR"
cd "$REPO"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
head="$(git rev-parse HEAD)" || exit 1
identity="$LOGDIR/run-${head}-${HOST_ID}-${GITHUB_RUN_ATTEMPT:-local}.txt"
{
  printf 'checked-out-head=%s\nhost=%s\n' "$head" "$HOST_ID"
  if [ -n "${SELFHOST_SOURCE_SHA:-}" ]; then
    printf 'source-head=%s\n' "$SELFHOST_SOURCE_SHA"
  fi
  printf 'run-id=%s\nrun-attempt=%s\n' "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-local}"
} > "$identity" || exit 1
cat "$identity"
if [ "${GITHUB_ACTIONS:-}" = true ] && [ "$head" != "${GITHUB_SHA:-}" ]; then
  echo "checked-out HEAD differs from the workflow revision" >&2
  exit 1
fi


total=${#gates[@]}
mine=""
if [ "$mode" = shard ]; then
  mine=" $(printf '%s\n' "$dealt" | awk -v k="$shard" '$1 == k { printf "%s ", $3 }')"
  size=$(printf '%s\n' "$dealt" | awk -v k="$shard" '$1 == k' | wc -l | tr -d ' ')
  echo "== 1. Running shard $shard of $shards: $size of $total selfhost gates in order (logs: $LOGDIR)"
  for gate in "${gates[@]}"; do
    name="$(basename "$gate" .sh)"
    case "$mine" in *" $name "*) echo "gate: $name.sh" ;; esac
  done
  unweighted="$(printf '%s\n' "$dealt" | awk -v k="$shard" '$1 == k && $4 == "unweighted" { printf "%s ", $3 }')"
  [ -n "$unweighted" ] && echo "unweighted (dealt at $DEFAULT_WEIGHT s until a run measures them): $unweighted"
else
  echo "== 1. Running ${#gates[@]} selfhost gates in order (logs: $LOGDIR)"
  printf 'gate: %s\n' "${gates[@]##*/}"
fi

status=0
failed=()
ran=0
for gate in "${gates[@]}"; do
  name="$(basename "$gate" .sh)"
  if [ "$mode" = shard ]; then
    case "$mine" in *" $name "*) ;; *) continue ;; esac
  fi
  ran=$((ran + 1))
  log="$LOGDIR/$name.log"
  bash "$gate" > "$log" 2>&1
  rc=$?
  limited="$(grep -c '^host-limited:' "$log" || true)"
  printf '%-44s exit=%s host-limited=%s\n' "$name" "$rc" "$limited"
  [ -n "${CI:-}" ] && printf '::group::%s (%s)\n' "$name" "$HOST_ID"
  cat "$log"
  [ -n "${CI:-}" ] && echo '::endgroup::'
  if [ "$rc" -ne 0 ]; then
    status=1
    failed+=("$name")
  fi
done

if [ "$mode" = shard ] && [ "$ran" -eq 0 ]; then
  if [ "$total" -ge "$shards" ]; then
    echo "FAIL: shard $shard of $shards ran no gate of the $total"
    status=1
  else
    echo "  (none in this shard)"
  fi
fi

echo
echo "== 2. Verdicts"
passed_count=$(( ran - ${#failed[@]} ))
echo "  $passed_count/$ran gates exited 0"
if [ "${#failed[@]}" -gt 0 ]; then
  for name in "${failed[@]}"; do
    echo "  failed: $name"
  done
fi

echo
suffix=""
[ "$mode" = shard ] && suffix=" (shard $shard of $shards)"
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST GATES PASSED$suffix"
else
  echo "== SOME SELFHOST GATES FAILED$suffix"
fi
exit "$status"
