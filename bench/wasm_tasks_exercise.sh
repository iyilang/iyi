#!/usr/bin/env bash
# Gate JSPI stack switching and parked-root tracing before adding a scheduler.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
IYI_CHROME="${IYI_CHROME:?set IYI_CHROME to an isolated headless Chrome executable}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-jspi.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bench" "$WORK/src/iyi/wasm"
cp "$REPO/bench/wasm_tasks_exercise.mjs" "$WORK/bench/"
cp "$REPO/src/iyi/wasm/iyi.mjs" "$WORK/src/iyi/wasm/"

for mode in plain release; do
  flags=()
  if [[ "$mode" == release ]]; then flags=(--release); fi
  command="$("$IYI" build --cross-compile --target wasm32-unknown-unknown "${flags[@]}" -o "$WORK/tasks" "$REPO/bench/wasm_tasks_exercise.iyi")"
  case "$command" in 'wasm-ld '*) ;; *) echo "unexpected link command: $command" >&2; exit 1 ;; esac
  eval "$command --export=__stack_pointer"
  mv "$WORK/tasks" "$WORK/tasks.wasm"
  echo "== JSPI parked roots: $mode, Node =="
  (cd "$WORK" && node "$REPO/bench/wasm_node.mjs" "$WORK/bench/wasm_tasks_exercise.mjs")
  echo "== JSPI parked roots: $mode, Chrome =="
  node "$REPO/bench/wasm_browser.mjs" --chrome "$IYI_CHROME" --root "$WORK" --script bench/wasm_tasks_exercise.mjs
done

echo 'JSPI parked-root gate passed'
