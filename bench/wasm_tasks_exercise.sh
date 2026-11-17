#!/usr/bin/env bash
# Exercise task behavior, JSPI shadow stacks, and their failure controls.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
IYI_CHROME="${IYI_CHROME:?set IYI_CHROME to an isolated headless Chrome executable}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-jspi.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bench" "$WORK/src/iyi/wasm"
cp "$REPO/bench/wasm_tasks_exercise.mjs" "$WORK/bench/"
cp "$REPO/src/iyi/wasm/iyi.mjs" "$WORK/src/iyi/wasm/"

# Give the broken builds a single modified source file and the real remainder.
for variant in bad-roots bad-canary; do
  mkdir -p "$WORK/src-$variant/iyi"
  for source in "$REPO"/src/iyi/*; do
    name="${source##*/}"
    if [[ "$variant:$name" == bad-roots:prelude.iyi ||
          "$variant:$name" == bad-canary:concurrency.iyi ]]; then
      continue
    fi
    ln -s "$source" "$WORK/src-$variant/iyi/$name"
  done
done
awk '
  /scan_range\(fiber.saved_sp, fiber.stack_top, visit\)/ { print "                nil"; changed++; next }
  { print }
  END { if (changed != 1) exit 1 }
' "$REPO/src/iyi/prelude.iyi" > "$WORK/src-bad-roots/iyi/prelude.iyi"
awk '
  /if Pointer\(UInt64\).new\(base\).value != WASM_STACK_CANARY/ { print "      if false"; changed++; next }
  { print }
  END { if (changed != 1) exit 1 }
' "$REPO/src/iyi/concurrency.iyi" > "$WORK/src-bad-canary/iyi/concurrency.iyi"

build_wasm() {
  local name="$1" source="$2" path="$3" command
  command="$(IYI_PATH="$path" "$IYI" build --cross-compile --target wasm32-unknown-unknown \
    "${flags[@]}" -o "$WORK/$name" "$source")"
  case "$command" in 'wasm-ld '*) ;; *) echo "unexpected link command: $command" >&2; exit 1 ;; esac
  eval "$command"
  mv "$WORK/$name" "$WORK/$name.wasm"
}

flags=()
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$IYI" build -o "$WORK/hello-native" \
  "$REPO/samples/iyi/hello.iyi" > "$WORK/hello-build.log" 2>&1
"$WORK/hello-native" > "$WORK/hello.stdout"
build_wasm hello "$REPO/samples/iyi/hello.iyi" "$REPO/src"
printf 'group do |g|\n  puts "empty"\nend\n' > "$WORK/empty-group.iyi"
printf 'sleep(1)\nputs "slept"\n' > "$WORK/sleep-only.iyi"
printf 'channel = Channel(Int32).new\nselect\nwhen value = channel.receive\n  puts "unexpected"\nwhen timeout(1)\n  puts "timeout"\nend\n' > "$WORK/select-only.iyi"
printf 'Channel(Int32).new.receive\n' > "$WORK/deadlock-only.iyi"
build_wasm empty-group "$WORK/empty-group.iyi" "$REPO/src"
build_wasm sleep-only "$WORK/sleep-only.iyi" "$REPO/src"
build_wasm select-only "$WORK/select-only.iyi" "$REPO/src"
build_wasm deadlock-only "$WORK/deadlock-only.iyi" "$REPO/src"
echo "hello module without tasks: $(wc -c < "$WORK/hello.wasm" | tr -d ' ') bytes"

for mode in plain release; do
  flags=()
  if [[ "$mode" == release ]]; then flags=(--release); fi
  PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$IYI" build "${flags[@]}" -o "$WORK/native" \
    "$REPO/bench/wasm_tasks_exercise.iyi" > "$WORK/native-build.log" 2>&1
  "$WORK/native" > "$WORK/native.stdout" 2> "$WORK/native.stderr"
  build_wasm tasks "$REPO/bench/wasm_tasks_exercise.iyi" "$REPO/src"
  build_wasm bad-roots "$REPO/bench/wasm_tasks_exercise.iyi" "$WORK/src-bad-roots:$REPO/src"
  build_wasm bad-canary "$REPO/bench/wasm_tasks_exercise.iyi" "$WORK/src-bad-canary:$REPO/src"
  echo "== tasks: $mode, Node =="
  (cd "$WORK" && node "$REPO/bench/wasm_node.mjs" "$WORK/bench/wasm_tasks_exercise.mjs")
  echo "== tasks: $mode, Chrome =="
  node "$REPO/bench/wasm_browser.mjs" --chrome "$IYI_CHROME" --root "$WORK" --script bench/wasm_tasks_exercise.mjs --timeout 120000
done

echo 'wasm task exercise: all checks passed'
