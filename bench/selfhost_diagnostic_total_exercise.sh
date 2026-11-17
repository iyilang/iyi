#!/usr/bin/env bash
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
. "$repo/bench/lib/host.sh"
require_test_host
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
repo_native="$(native_path "$repo")"
work_native="$(native_path "$work")"
export IYI_PATH="$repo_native/src"
"$repo/bin/iyi" build -o "$work_native/probe$EXE" "$repo_native/bench/diagnostic_untyped_probe.iyi" > "$work/build.log" 2>&1
if [ "$HOST_OS" = darwin ]; then
  codesign -v --strict "$work/probe$EXE"
else
  host_limited "codesign verification requires macOS"
fi
"$work/probe$EXE" > "$work/actual"
awk '/^expected argument/ { exit } { print }' "$work/actual" > "$work/untyped"
printf '%s\n' "no overload matches 'consume' with type fresh" '' 'Overloads are:' ' - consume(value : String)' > "$work/expected"
cmp "$work/expected" "$work/untyped"
"$repo/bin/iyi" run "$repo_native/bench/fixtures/diagnostic_typed_mismatch.iyi" > "$work/hosted" 2>&1 && exit 1
awk '/^Error: / { sub(/^Error: /, ""); found=1 } found { print }' "$work/hosted" > "$work/hosted.error"
awk '/^expected argument/ { found=1 } found { print }' "$work/actual" > "$work/typed.error"
cmp "$work/hosted.error" "$work/typed.error"
echo 'untyped fallback and hosted typed diagnostic: pass'
