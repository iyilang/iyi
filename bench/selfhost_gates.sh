#!/usr/bin/env bash
# Runs every bench/selfhost_*_exercise.sh, one after another, and prints one
# verdict line per gate. The gates share the checkout (several mutate sources
# and rebuild the compiler), so they never run in parallel.
#
#   bash bench/selfhost_gates.sh
#
# Each gate's full output goes to a log under $SELFHOST_GATE_LOGS (default: a
# fresh temporary directory). A failing gate's last lines are printed: twelve
# at a desk, where the log is a path away, and $SELFHOST_GATE_TAIL (default
# 200) under CI, where the runner is gone and the printed lines are all there is.
# Exit status is 0 only when every gate exits 0.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${SELFHOST_GATE_LOGS:-$(mktemp -d)}"
mkdir -p "$LOGDIR"
cd "$REPO"

gates=()
for gate in "$REPO"/bench/selfhost_*_exercise.sh; do
  [ -f "$gate" ] && gates+=("$gate")
done
if [ "${#gates[@]}" -eq 0 ]; then
  echo "== 0. no bench/selfhost_*_exercise.sh gates found"
  echo "SOME SELFHOST GATES FAILED"
  exit 1
fi

echo "== 1. Running ${#gates[@]} selfhost gates in order (logs: $LOGDIR)"
status=0
failed=()
for gate in "${gates[@]}"; do
  name="$(basename "$gate" .sh)"
  log="$LOGDIR/$name.log"
  bash "$gate" > "$log" 2>&1
  rc=$?
  printf '%-44s exit=%s\n' "$name" "$rc"
  if [ "$rc" -ne 0 ]; then
    status=1
    failed+=("$name")
    lines=12
    [ -n "${CI:-}" ] && lines="${SELFHOST_GATE_TAIL:-200}"
    echo "  last $lines lines of $log:"
    tail -n "$lines" "$log" | sed 's/^/    /'
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
