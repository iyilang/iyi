#!/usr/bin/env bash
# Hold the shipped freestanding hello below a budget while retaining names.
# Run by wasm-freestanding after the compiler and wasi-sdk are installed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="${IYI:-$REPO/bin/iyi}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iyi-wasm-size.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# LLVM 22 on macOS emits 25,901 bytes for this hello. Leave room for LLVM and
# linker differences, but not for the approximately 21 KB of default DWARF.
MAX_BYTES=36000

check_release() {
  node - "$1" "$MAX_BYTES" <<'JS'
const fs = require("node:fs");
const file = process.argv[2], limit = Number(process.argv[3]);
const bytes = fs.readFileSync(file);
if (bytes.length > limit) throw new Error(`size regression: ${bytes.length} bytes exceeds ${limit}`);
const module_ = new WebAssembly.Module(bytes);
if (WebAssembly.Module.customSections(module_, "name").length !== 1) throw new Error("missing function names");
for (const name of [".debug_info", ".debug_line", ".debug_abbrev", ".debug_ranges", ".debug_str"]) {
  if (WebAssembly.Module.customSections(module_, name).length) throw new Error(`unexpected DWARF section ${name}`);
}
console.log(`${file}: ${bytes.length} bytes, names present, DWARF absent`);
JS
}

check_debug() {
  node - "$1" <<'JS'
const fs = require("node:fs");
const module_ = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
if (!WebAssembly.Module.customSections(module_, "name").length ||
    !WebAssembly.Module.customSections(module_, ".debug_info").length) {
  throw new Error("names or requested debug information are missing");
}
console.log(`${process.argv[2]}: names and DWARF present`);
JS
}

build() {
  local name="$1" command
  shift
  command="$("$IYI" build --cross-compile --target wasm32-unknown-unknown "$@" \
    -o "$WORK/$name" "$REPO/samples/iyi/hello.iyi")"
  printf '%s' "$command" > "$WORK/$name.link"
  eval "$command"
}

build release --release
check_release "$WORK/release"
node - "$WORK/release" <<'JS'
const fs = require("node:fs");
const module_ = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const instance = new WebAssembly.Instance(module_, {iyi: {
  write: () => { throw new Error("stack sentinel"); },
  exit: () => { throw new Error("unexpected exit"); },
}});
let sawStack = false;
try {
  instance.exports.iyi_start();
} catch (error) {
  if (error.message !== "stack sentinel" || !error.stack.includes("iyi_start")) throw error;
  sawStack = true;
}
if (!sawStack) throw new Error("the host did not receive a named wasm stack");
console.log("host stack: iyi_start is named");
JS
"$IYI" build --target wasm32-unknown-unknown --release -o "$WORK/direct" "$REPO/samples/iyi/hello.iyi"
check_release "$WORK/direct"
build size --release -O z
check_release "$WORK/size"
build plain
check_debug "$WORK/plain"
build debug --release -d
check_debug "$WORK/debug"
build no-debug --release --no-debug
check_release "$WORK/no-debug"

# Change the command actually printed for release, once. Relink the identical
# object with no --strip-debug; merely lowering a size threshold would prove a
# test of itself rather than catch the omitted linker option.
python3 - "$WORK/release.link" "$WORK/unstripped.link" <<'PY'
from pathlib import Path
import sys
command = Path(sys.argv[1]).read_bytes()
needle = bytes.fromhex("202d2d73747269702d6465627567")
if command.count(needle) != 1:
    raise SystemExit("expected exactly one --strip-debug link flag")
Path(sys.argv[2]).write_bytes(command.replace(needle, b"", 1))
PY
cp "$WORK/release" "$WORK/release.good"
eval "$(< "$WORK/unstripped.link")"
if check_release "$WORK/release" > "$WORK/broken.log" 2>&1; then
  echo 'size gate accepted a release built without --strip-debug' >&2
  exit 1
fi
if ! grep -q 'size regression:' "$WORK/broken.log"; then
  echo 'unstripped mutation failed for a reason other than the size budget' >&2
  exit 1
fi
check_debug "$WORK/release"
mv "$WORK/release.good" "$WORK/release"
check_release "$WORK/release"
echo 'size gate: missing --strip-debug exceeded the budget as expected'
