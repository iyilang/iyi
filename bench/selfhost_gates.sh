#!/usr/bin/env bash
# Runs every self-host and native compiler component gate, one after another, and prints one
# verdict line per gate. The gates share the checkout (several mutate sources
# and rebuild the compiler), so they never run in parallel.
#
#   bash bench/selfhost_gates.sh
#   SELFHOST_GATE_SHARD=2/8 bash bench/selfhost_gates.sh
#
# A shard i/n runs every n-th gate, starting with the i-th. Each CI shard has
# its own checkout; source-mutating gates still run sequentially within it.
#
# Each gate's full output goes to a log under $SELFHOST_GATE_LOGS (default: a
# fresh temporary directory), is printed in full, and is retained by CI.
# Exit status is 0 only when every gate exits 0.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${SELFHOST_GATE_LOGS:-$(mktemp -d)}"
mkdir -p "$LOGDIR"
cd "$REPO"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1

head="$(git rev-parse HEAD)" || exit 1
identity="$LOGDIR/run-${head}-${HOST_ID}-${GITHUB_RUN_ATTEMPT:-local}.txt"
{
  printf 'checked-out-head=%s\nhost=%s\n' "$head" "$HOST_ID"
  printf 'shard=%s\n' "${SELFHOST_GATE_SHARD:-all}"
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

total="${#gates[@]}"
shard="${SELFHOST_GATE_SHARD:-}"
if [ -n "$shard" ]; then
  index="${shard%%/*}"
  count="${shard##*/}"
  case "$index$count" in
    ''|*[!0-9]*)
      echo "SELFHOST_GATE_SHARD must be i/n, got '$shard'" >&2
      exit 1
      ;;
  esac
  if [ "$shard" != "$index/$count" ] || [ "$count" -lt 1 ] || [ "$index" -lt 1 ] || [ "$index" -gt "$count" ]; then
    echo "SELFHOST_GATE_SHARD requires 1 <= i <= n, got '$shard'" >&2
    exit 1
  fi
  kept=()
  position=0
  for candidate in "${gates[@]}"; do
    if [ $(( position % count )) -eq $(( index - 1 )) ]; then
      kept+=("$candidate")
    fi
    position=$(( position + 1 ))
  done
  if [ "${#kept[@]}" -eq 0 ]; then
    echo "shard $shard holds none of the $total gates" >&2
    exit 1
  fi
  gates=("${kept[@]}")
  echo "== 1. Running shard $shard: ${#gates[@]} of $total selfhost gates in order (logs: $LOGDIR)"
else
  echo "== 1. Running ${#gates[@]} selfhost gates in order (logs: $LOGDIR)"
fi
printf 'gate: %s\n' "${gates[@]##*/}"
status=0
failed=()
for gate in "${gates[@]}"; do
  name="$(basename "$gate" .sh)"
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

echo
echo "== 2. Verdicts"
passed_count=$(( ${#gates[@]} - ${#failed[@]} ))
echo "  $passed_count/${#gates[@]} gates exited 0"
if [ "${#failed[@]}" -gt 0 ]; then
  for name in "${failed[@]}"; do
    echo "  failed: $name"
  done
fi

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST GATES PASSED"
else
  echo "== SOME SELFHOST GATES FAILED"
fi
exit "$status"
