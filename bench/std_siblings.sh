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
  if ! bash "$sibling"; then
    echo "FAIL: sibling $(basename "$sibling") failed"
    status=1
  fi
done

echo
echo "== shard $shard of $shards: $(echo $ran | wc -w | tr -d ' ') of $place sibling exercises"
[ -n "$ran" ] || echo "  (none in this shard)"
exit "$status"
