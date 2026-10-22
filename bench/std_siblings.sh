#!/usr/bin/env bash
# Runs the std modules' own exercises - every `bench/std_<module>_exercise.sh`
# but `std_exercise.sh` itself - or one shard of them.
#
#     bash bench/std_siblings.sh          # all of them
#     bash bench/std_siblings.sh 2 4      # the second of four shards
#     bash bench/std_siblings.sh --plan 4 # which shard each goes to; runs none
#
# `bench/std_exercise.sh` runs all of them after its own sections; CI runs
# the shards side by side, because one after another they outgrew the hour
# the job had - and the sum is the same set, which the shard header line
# says so a log can be added up.
#
# The shards are dealt by weight: every sibling, heaviest first, goes to the
# shard with the least weight so far (the first such shard on a tie, and
# siblings of one weight by name, so the deal is the same everywhere). A
# weight is the seconds the sibling took on the slowest of the three
# platforms in run 39840302846 (jobs 120039255535 to 120040655672), read
# from the twelve shard logs by sibling_times.py, beside this script; a
# sibling not in WEIGHTS weighs 20, about what the 69 left out took at their
# slowest (median 22 s, mean 24 s). Shard K of N used to be every sibling
# whose sorted place left K divided by N: with the heaviest four of them
# std_a* to std_w*, that put std/http, std/big, std/websocket and
# std/autocert in shard 2, and the shard ran 60 to 80 minutes beside others
# of 16 to 40. Added up from the same logs, the most a shard carries:
#
#                  interleaved   by WEIGHTS   by the platform's own
#     Linux          4,641 s      2,580 s       2,345 s
#     darwin         4,509 s      2,875 s       2,684 s
#     Windows        4,019 s      2,936 s       2,724 s
#
# One table for every platform, though the platforms disagree (std/tls took
# 801 s on Linux and 1,864 on Windows): a deal from each platform's own
# seconds would save it 191 to 235 s more, on shards of 45 minutes, and the
# same gate moves further than that from run to run (the shard holding
# std/http took 29 to 45 minutes in four runs on Linux). Rerun
# sibling_times.py on a green run's shard logs when a gate's weight changes
# much; its `--predict 4` adds the logs up as above.
WEIGHTS="
  tls 1864   http 1632   big 988   xz 460   websocket 422
  autocert 399   acme 343   mutex 252   zip 249   math 237
  smtp 223   process 211   sse 199   zstd 195   text_scale 189
  secure_dns 188   router 160   bzip2 151   x509 149   dir 145
  compress 140   tar 140   regex 137   rsa 130   dns 122
  yaml 121   term 116   cookie 115   time 103   ocsp 99
  xml 99   p384 97   fileserver 94   toml 88   fuzz 86
  file 84   png 84   curve25519 81   csv 77   mail 76
  digest 71   complex 69   eiy 64
"
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
plan=""
if [ "${1:-}" = "--plan" ]; then
  plan=1
  shard=1
  shards="${2:-}"
else
  shard="${1:-1}"
  shards="${2:-1}"
fi
case "$shard$shards" in
  "" | *[!0-9]*)
    echo "usage: bash bench/std_siblings.sh [K N | --plan N]: K and N are numbers"
    exit 2
    ;;
esac
if [ -z "$shards" ] || [ "$shards" -lt 1 ] || [ "$shard" -lt 1 ] || [ "$shard" -gt "$shards" ]; then
  echo "usage: bash bench/std_siblings.sh [K N | --plan N]: 1 <= K <= N"
  exit 2
fi

# "K WEIGHT NAME" for every sibling, in the order they are dealt.
deal() {
  for sibling in "$REPO"/bench/std_*_exercise.sh; do
    [ -f "$sibling" ] || continue
    name="$(basename "$sibling" .sh)"
    [ "$name" = "std_exercise" ] || echo "$name"
  done | awk -v table="$WEIGHTS" '
    BEGIN { n = split(table, t); for (i = 1; i < n; i += 2) w["std_" t[i] "_exercise"] = t[i + 1] }
    { print $1, (($1 in w) ? w[$1] : 20) }' |
    LC_ALL=C sort -k2,2nr -k1,1 |
    awk -v n="$shards" '{
      k = 1
      for (i = 2; i <= n; i++) if (load[i] < load[k]) k = i
      load[k] += $2
      print k, $2, $1 }'
}
dealt="$(deal)"

if [ -n "$plan" ]; then
  echo "$dealt" | LC_ALL=C sort -s -k1,1n
  echo "$dealt" | awk -v n="$shards" '{ c[$1]++; s[$1] += $2 }
    END { for (k = 1; k <= n; k++) printf "# shard %d of %d: %d of %d siblings, %d s by the weights\n", k, n, c[k], NR, s[k] }'
  exit 0
fi
mine=" $(echo "$dealt" | awk -v k="$shard" '$1 == k { printf "%s ", $3 }')"

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
# write its own log loses its connection too. So does one that cannot open
# a connection: Windows keeps a closed TCP connection's port in TIME_WAIT
# for minutes, and the gates that serve and connect thousands of times
# could use up the ephemeral ports the runner reaches GitHub through, so
# the most connections seen in TIME_WAIT are traced as well, every ten
# seconds, where `ss` or `netstat` is there to count them.
trace=""
if [ -r /proc/meminfo ]; then
  trace="$(mktemp)"
  total=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
  echo "== memory: $total MB here; each sibling's lowest available, most swap and least disk free follow it"
else
  echo "== memory: no /proc/meminfo here, so no sibling's memory is traced"
fi
sample_memory() {
  turn=0
  waits=-1
  while :; do
    if [ $((turn % 5)) -eq 0 ]; then
      if command -v ss >/dev/null 2>&1; then
        waits=$(ss -tan state time-wait 2>/dev/null | awk 'NR > 1' | wc -l | tr -d ' ')
      elif command -v netstat >/dev/null 2>&1; then
        waits=$(netstat -an 2>/dev/null | grep -c TIME_WAIT)
      fi
    fi
    turn=$((turn + 1))
    awk '/^(MemFree|MemAvailable|SwapTotal|SwapFree):/ { v[$1] = $2 }
      END { a = ("MemAvailable:" in v) ? v["MemAvailable:"] : v["MemFree:"]
            printf "%d %d ", a / 1024, (v["SwapTotal:"] - v["SwapFree:"]) / 1024 }' /proc/meminfo >>"$trace"
    df -Pm "${TMPDIR:-/tmp}" 2>/dev/null | awk -v w="$waits" 'NR == 2 { d = $4 } END { print d + 0, w }' >>"$trace"
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
  case "$mine" in *" $(basename "$sibling" .sh) "*) ;; *) continue ;; esac
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
      NR == 1 || $4 > waits { waits = $4 }
      END { if (!NR) exit
            printf "   memory: lowest available %d MB, swap in use at most %d MB, least disk free %d MB, ", low, swap, disk
            if (waits < 0) print "no ss or netstat to count TIME_WAIT"
            else printf "at most %d connections in TIME_WAIT\n", waits }' "$trace"
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
echo "== shard $shard of $shards: $(echo $ran | wc -w | tr -d ' ') of $place sibling exercises, dealt by weight"
[ -n "$ran" ] || echo "  (none in this shard)"
exit "$status"
