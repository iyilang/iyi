#!/usr/bin/env bash
# Runs every self-host and native compiler component gate, one after another, and prints one
# verdict line per gate. The gates share the checkout (several mutate sources
# and rebuild the compiler), so they never run in parallel.
#
#   bash bench/selfhost_gates.sh
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

echo "== 1. Running ${#gates[@]} selfhost gates in order (logs: $LOGDIR)"
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
