#!/usr/bin/env bash
# The sandbox story, measured — SPEC.md III.12, AI_FIRST.md §2 #8.
#
#     WASI_SDK=~/.local/opt/wasi-sdk WASMTIME=~/.wasmtime/bin/wasmtime \
#       bash bench/sandbox_story.sh
#
# The claim: an iyi program compiled for wasm32-wasi is the cheapest
# container for running code nobody trusts — generated code most of all.
# Three steps, the second and third being what a sandbox is *for*:
#
#   1. An honest program computes and prints through the boundary.
#   2. A program that tries to read the host's files dies with the refusal
#      named, and not one byte of the file in its output — under a default
#      wasmtime, which preopens nothing.
#   3. The refusal is the prelude's own, so it names iyi's rule rather
#      than a trap code: File has no wasm32 surface at all.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable for the same reason `bench/wasm32_exercise.sh` says: in CI the
# compiler here is the tarball's, because that is the one that runs beside
# wasmtime.
IYI="${IYI:-$REPO/bin/iyi}"
WASI_SDK="${WASI_SDK:-/opt/wasi-sdk}"
WASMTIME="${WASMTIME:-$HOME/.wasmtime/bin/wasmtime}"
WORK="$(mktemp -d)"

cd "$WORK" || exit 1
step() { echo "== $1"; }

for tool in "$WASI_SDK/bin/clang" "$WASMTIME"; do
  command -v "$tool" > /dev/null || { echo "missing: $tool"; exit 1; }
done
ln -sf "$WASI_SDK/bin/clang" "$WASI_SDK/bin/cc" 2>/dev/null || true
export PATH="$WASI_SDK/bin:$PATH"

build_wasm() {
  "$IYI" build --cross-compile --target wasm32-wasi -o "$1" "$1.iyi" > "$1.link" 2>&1 || { cat "$1.link"; exit 1; }
  eval "$(cat "$1.link")" || exit 1
}

step "an honest program computes through the boundary"
printf 'total = 0\nindex = 1\nwhile index <= 10\n  total = total + index\n  index = index + 1\nend\nputs total\n' > honest.iyi
build_wasm honest
"$WASMTIME" honest > honest.txt 2>&1 || { cat honest.txt; exit 1; }
grep -qx '55' honest.txt || { echo "wrong answer through the boundary:"; cat honest.txt; exit 1; }

step "a theft dies named, and empty-handed"
printf 'secret = File.read("/etc/passwd")\nputs secret\n' > theft.iyi
build_wasm theft
"$WASMTIME" theft > theft.txt 2>&1
status=$?
[ $status -ne 0 ] || { echo "the theft exited 0:"; cat theft.txt; exit 1; }
grep -q 'root:' theft.txt && { echo "the host's file leaked through:"; cat theft.txt; exit 1; }

step "the refusal is the prelude's rule, by name"
grep -q 'File is not available on wasm32-wasi' theft.txt || { echo "the refusal is unnamed:"; cat theft.txt; exit 1; }

echo "workdir $WORK"
echo "sandbox gate: every step held"
exit 0
