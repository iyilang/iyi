#!/usr/bin/env bash
# Runs the std modules' own exercises - every `bench/std_<module>_exercise.sh`
# but `std_exercise.sh` itself - or one shard of them.
#
#     bash bench/std_siblings.sh          # all of them
#     bash bench/std_siblings.sh 2 4      # the second of four shards
#
# Shard K of N is every exercise whose place in the sorted list, counted from
# one, leaves K when divided by N, N for none: interleaved rather than cut in
# runs, so the slow ones (std/http's proofs, the crypto oracles) spread out
# instead of landing in one shard. `bench/std_exercise.sh` runs all of them
# after its own sections; CI runs the shards side by side, because one after
# another they outgrew the hour the job had - and the sum is the same set,
# which the shard header line says so a log can be added up.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
shard="${1:-1}"
shards="${2:-1}"
case "$shard$shards" in
  *[!0-9]*)
    echo "usage: bash bench/std_siblings.sh [K N]: K and N are numbers"
    exit 2
    ;;
esac
if [ "$shards" -lt 1 ] || [ "$shard" -lt 1 ] || [ "$shard" -gt "$shards" ]; then
  echo "usage: bash bench/std_siblings.sh [K N]: 1 <= K <= N"
  exit 2
fi

# Each sibling has SIBLING_MINUTES (35: std/http's, the slowest, takes 25
# on Linux) and is stopped past them, failing by name. A hang left to the
# job's own limit cancelled the job, and a cancelled job keeps no log: a
# Windows shard ran 65 minutes and said nothing of where it stopped.
limit=$(( ${SIBLING_MINUTES:-35} * 60 ))
bounded=""
command -v timeout >/dev/null 2>&1 && bounded="timeout -k 30 $limit"

# Each sibling's lowest available memory and most swap in use, read from
# /proc/meminfo every two seconds while it runs (Linux has it, and so does
# the MSYS bash the Windows jobs run this under). Windows shards have lost
# their runner ("lost communication with the server") six times (jobs
# 118492675680, 118598972995, 118855592816, 119406415714, 119550880710
# and 119648405209), and such a job keeps no log; these lines, from the
# shards that finish, say which siblings bring a runner nearest to the end
# of its memory. The first shards traced kept 7,623 MB of 16,378 free at
# their lowest (std/acme's, job 119732733162), so the free space of the
# disk the temporary files go to is traced beside it: a runner that cannot
# write its own log loses its connection too.
trace=""
if [ -r /proc/meminfo ]; then
  trace="$(mktemp)"
  total=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
  echo "== memory: $total MB here; each sibling's lowest available, most swap and least disk free follow it"
else
  echo "== memory: no /proc/meminfo here, so no sibling's memory is traced"
fi
sample_memory() {
  while :; do
    awk '/^(MemFree|MemAvailable|SwapTotal|SwapFree):/ { v[$1] = $2 }
      END { a = ("MemAvailable:" in v) ? v["MemAvailable:"] : v["MemFree:"]
            printf "%d %d ", a / 1024, (v["SwapTotal:"] - v["SwapFree:"]) / 1024 }' /proc/meminfo >>"$trace"
    df -Pm "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR == 2 { d = $4 } END { print d + 0 }' >>"$trace"
    sleep 2
  done
}

status=0
place=0
ran=""
for sibling in "$REPO"/bench/std_*_exercise.sh; do
  [ -f "$sibling" ] || continue
  [ "$(basename "$sibling")" = "std_exercise.sh" ] && continue
  place=$((place + 1))
  [ $(((place - 1) % shards + 1)) -eq "$shard" ] || continue
  ran="$ran $(basename "$sibling" .sh)"
  echo "-- running sibling: $(basename "$sibling")"
  sampler=""
  if [ -n "$trace" ]; then
    : >"$trace"
    sample_memory &
    sampler=$!
  fi
  $bounded bash "$sibling"
  code=$?
  if [ -n "$sampler" ]; then
    kill "$sampler" 2>/dev/null
    wait "$sampler" 2>/dev/null
    awk 'NR == 1 || $1 < low { low = $1 } $2 > swap { swap = $2 } NR == 1 || $3 < disk { disk = $3 }
      END { if (NR) printf "   memory: lowest available %d MB, swap in use at most %d MB, least disk free %d MB\n", low, swap, disk }' "$trace"
  fi
  if [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then
    echo "FAIL: sibling $(basename "$sibling") had not finished in $((limit / 60)) minutes, and was stopped"
    status=1
  elif [ "$code" -ne 0 ]; then
    echo "FAIL: sibling $(basename "$sibling") failed"
    status=1
  fi
done

[ -n "$trace" ] && rm -f "$trace"
echo
echo "== shard $shard of $shards: $(echo $ran | wc -w | tr -d ' ') of $place sibling exercises"
[ -n "$ran" ] || echo "  (none in this shard)"
exit "$status"
