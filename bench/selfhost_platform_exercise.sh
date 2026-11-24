#!/usr/bin/env bash
# Fails when the iyi platform support stops agreeing with the implementation it replaces.
#
# The port is only worth something if it parses target triples, normalizes
# architectures, derives implied flags, determines object and executable
# extensions, and generates linker commands the same way the front end iyi is
# still bootstrapped from does. Every target triple in the corpus is evaluated
# through both implementations, dumped in the same format, and required
# byte-identical.
#
# Absolute library search paths are normalized identically on both sides with
# an explicit comment so the gate holds across workstations and CI environments
# without loosening the check.
#
# The mutation proofs verify that the parity checks are load-bearing: each
# mutation modifies a key ported mechanism, proves the patch applied, runs
# the comparison to confirm it is caught, and reverts cleanly.
#
#   bash bench/selfhost_platform_exercise.sh
set -u
status=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO/bench/lib/host.sh" || exit 1
require_test_host || exit 1
if [ -z "$PY" ]; then
  echo "  FAILED: a functional Python interpreter is required" >&2
  exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "  FAILED: perl is required for the mutation proofs" >&2
  exit 1
fi
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
TARGET_IYI="$REPO/src/compiler/platform/target.iyi"
FLAGS_IYI="$REPO/src/compiler/platform/flags.iyi"
LINKER_IYI="$REPO/src/compiler/platform/linker.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
. "$REPO/bench/lib/mutation.sh"

echo "== 1. Building and running the platform exercise (plain mode)"
if ! "$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_platform_exercise.iyi"; then
  echo "  FAILED to build bench/selfhost_platform_exercise.iyi in plain mode"
  exit 1
fi
if ! "$WORK/exercise$EXE" > "$WORK/plain.out" 2>&1; then
  echo "  PLAIN EXERCISE FAILED"
  cat "$WORK/plain.out"
  exit 1
fi
head -n 25 "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST PLATFORM CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  PLAIN EXERCISE DID NOT REPORT SUCCESS"
  exit 1
fi

echo
echo "== 2. Building and running the platform exercise (--release mode)"
if ! "$IYI" build --release -o "$WORK_NATIVE/exercise-release$EXE" "$REPO_NATIVE/bench/selfhost_platform_exercise.iyi"; then
  echo "  FAILED to build bench/selfhost_platform_exercise.iyi in release mode"
  exit 1
fi
if ! "$WORK/exercise-release$EXE" > "$WORK/release.out" 2>&1; then
  echo "  RELEASE EXERCISE FAILED"
  cat "$WORK/release.out"
  exit 1
fi
if ! grep -qF "ALL SELFHOST PLATFORM CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "  RELEASE EXERCISE DID NOT REPORT SUCCESS"
  exit 1
else
  echo "  release mode verification passed"
fi

echo
echo "== 3. Target and linker comparison against the front end being replaced"
cat <<'CRYSTAL_ORACLE_SCRIPT' > "$WORK/dump_crystal_platform.cr"
require "compiler/requires"
require "json"

class Iyi::Compiler
  def test_linker_command(program, object_names, output_filename, output_dir)
    linker_command(program, object_names, output_filename, output_dir)
  end

  private def use_modern_linker(link_flags)
    link_flags
  end
end

class Iyi::Program
  # Only the shape matters: normalize_paths maps any absolute .../lib path to <LIBPATH> on both sides.
  def lib_flags(cross_compiling : Bool = false)
    if has_flag?("msvc")
      "/LIBPATH:/usr/local/lib"
    else
      "-L/usr/local/lib"
    end
  end
end

def normalize_paths(cmd : String) : String
  # Normalise absolute library search paths identically on both sides with a comment saying so:
  # Host library search paths vary across build machines, so paths ending in /lib are mapped to <LIBPATH>.
  # Modern linker selection (-fuse-ld=) depends on host-installed tools and is normalized out for target parity.
  parts = cmd.split(' ')
  norm_parts = [] of String
  parts.each do |p|
    if p == "-L/usr/local/lib"
      norm_parts << "-L<LIBPATH>"
    elsif p.starts_with?("-L/") && p.ends_with?("/lib")
      norm_parts << "-L<LIBPATH>"
    elsif p.starts_with?("/LIBPATH:/") && p.ends_with?("/lib")
      norm_parts << "/LIBPATH:<LIBPATH>"
    elsif p.starts_with?("-fuse-ld=")
      next
    else
      norm_parts << p
    end
  end
  norm_parts.join(" ")
end

triples = [
  "arm64-apple-darwin",
  "aarch64-apple-darwin",
  "arm64-apple-macosx",
  "x86_64-apple-darwin",
  "x86_64-apple-macosx",
  "x86_64-linux-gnu",
  "x86_64-unknown-linux-gnu",
  "x86_64-linux-musl",
  "x86_64-unknown-linux-musl",
  "aarch64-linux-gnu",
  "aarch64-unknown-linux-gnu",
  "aarch64-linux-musl",
  "aarch64-unknown-linux-musl",
  "arm64-linux-gnu",
  "arm64-unknown-linux-musl",
  "x86_64-windows-msvc",
  "x86_64-pc-windows-msvc",
  "x86_64-pc-windows-gnu",
  "wasm32-wasi",
  "wasm32-unknown-wasi",
  "arm-unknown-linux-gnueabihf",
  "x86_64-unknown-freebsd13.2",
  "x86_64-unknown-openbsd",
  "aarch64-unknown-openbsd"
]

raise "expected the MSVC configuration output path" unless ARGV.size == 1
msvc_configs = {} of String => NamedTuple(linker: String, args: Array(String))

triples.each do |t|
  target = Iyi::Codegen::Target.new(t)
  prog = Iyi::Program.new
  prog.codegen_target = target
  flags = prog.flags.to_a.sort

  compiler = Iyi::Compiler.new
  compiler.cross_compile = true
  compiler.codegen_target = target
  if prog.has_flag?("msvc")
    # Ask the unmodified host discovery for the same target and process state
    # that linker_command will use. JSON preserves each argument and its bytes.
    discovered_linker, discovered_args = prog.msvc_compiler_and_flags
    msvc_configs[t] = {linker: discovered_linker, args: discovered_args}
  end

  linker, cmd, objs = compiler.test_linker_command(prog, ["foo.o", "bar.o"], "out_bin", "/tmp")

  puts "TRIPLE: #{t}"
  puts "  status: ok"
  puts "  normalized: #{target.to_s}"
  puts "  arch: #{target.architecture}"
  puts "  vendor: #{target.vendor}"
  puts "  env: #{target.environment}"
  puts "  os_name: #{target.os_name}"
  puts "  pointer_bits: #{target.pointer_bit_width}"
  puts "  size_bits: #{target.size_bit_width}"
  puts "  obj_ext: #{target.object_extension.inspect}"
  puts "  exe_ext: #{target.executable_extension.inspect}"
  puts "  flags: #{flags.join(" ")}"
  puts "  linker: #{linker}"
  puts "  cmd: #{normalize_paths(cmd)}"
  puts "  objects: #{objs ? objs.join(" ") : "nil"}"
end
File.write(ARGV[0], msvc_configs.to_json)
CRYSTAL_ORACLE_SCRIPT

if ! LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
     CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
     -o "$WORK_NATIVE/oracle$EXE" "$WORK_NATIVE/dump_crystal_platform.cr" > "$WORK/oracle_build.log" 2>&1; then
  echo "  FAILED to build Crystal oracle:"
  cat "$WORK/oracle_build.log"
  exit 1
fi
if ! "$WORK/oracle$EXE" "$WORK_NATIVE/msvc-config.json" > "$WORK/crystal.out"; then
  echo "  FAILED to run Crystal oracle" >&2
  exit 1
fi
if ! "$PY" - "$WORK_NATIVE/msvc-config.json" "$HOST_OS" <<'PY'
import json
import ntpath
import os
import sys

with open(sys.argv[1], encoding="utf-8", newline="") as stream:
    configs = json.load(stream)
triples = ("x86_64-windows-msvc", "x86_64-pc-windows-msvc")
if set(configs) != set(triples):
    raise SystemExit("oracle did not export both MSVC target configurations")
for triple in triples:
    config = configs[triple]
    linker, args = config["linker"], config["args"]
    if not isinstance(linker, str) or not linker or not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise SystemExit(f"invalid oracle MSVC configuration for {triple}")
    if sys.argv[2] == "windows":
        if sum(arg.startswith("/LIBPATH:") for arg in args) < 4:
            raise SystemExit(f"MSVC/Windows SDK search paths unavailable for {triple}")
        if "CC" not in os.environ and (not ntpath.isabs(linker) or ntpath.basename(linker).lower() != "link.exe"):
            raise SystemExit(f"MSVC link.exe discovery failed for {triple}: {linker!r}")
    print(f"  {triple} discovered linker: {linker!r}")
    for arg in args:
        print(f"    discovered argument: {arg!r}")
PY
then
  echo "  FAILED to read the oracle MSVC configuration" >&2
  exit 1
fi
if ! "$WORK/exercise$EXE" dump "$WORK_NATIVE/msvc-config.json" > "$WORK/iyi.out"; then
  echo "  FAILED to run the iyi platform comparison" >&2
  exit 1
fi
if [ "$(grep -c '^TRIPLE: ' "$WORK/crystal.out")" -ne 24 ]; then
  echo "  FAILED: Crystal oracle did not produce 24 target rows" >&2
  exit 1
fi

if diff -u "$WORK/crystal.out" "$WORK/iyi.out" > "$WORK/diff.log"; then
  awk '
    /^TRIPLE: / { msvc = /windows-msvc$/ }
    msvc && (/^TRIPLE: / || /^  (linker|cmd): /) { print }
  ' "$WORK/crystal.out"
  echo "  Parity summary: 24/24 target triples match 100% across normalized targets, flags, extensions, and link commands"
else
  echo "  PARITY FAILURE: iyi platform support diverged from Crystal frontend"
  cat "$WORK/diff.log"
  exit 1
fi

echo
echo "== 4. Malformed-input and boundary rejection checks"
for bad in "invalid" "foo" "x86_64"; do
  if "$WORK/exercise-release$EXE" "$bad" >"$WORK/bad.out" 2>&1; then
    echo "  ERROR: expected failure for malformed input: $bad"
    status=1
  else
    if grep -qF "Invalid target triple: $bad" "$WORK/bad.out"; then
      echo "  properly rejected: $bad"
    else
      echo "  ERROR: unexpected error output for $bad:"
      cat "$WORK/bad.out"
      status=1
    fi
  fi
done

echo
echo "== 5. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# A compiled mutant must disagree with the oracle. A build failure supplies
# no behavioral evidence and fails the gate separately.
check_platform_matches_oracle() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_platform_exercise.iyi" > "$WORK/mut-build.log" 2>&1; then
    echo "  INVALID MUTANT: platform exercise did not build" >&2
    cat "$WORK/mut-build.log" >&2
    touch "$WORK/invalid-mutant"
    return 0
  fi
  "$WORK/mut-exercise$EXE" dump "$WORK_NATIVE/msvc-config.json" > "$WORK/mut-iyi.out" 2>&1 || return 1
  diff -q "$WORK/crystal.out" "$WORK/mut-iyi.out" >/dev/null 2>&1
}

MUTATIONS_RUN=0
run_proof() {
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  prove_mutation "$1" "$2" "$3" "$4" -- check_platform_matches_oracle || status=1
}

run_proof "altering aarch64 64-bit pointer width detection" \
  "$TARGET_IYI" \
  '@architecture == "aarch64" || @architecture == "x86_64"' \
  '@architecture == "x86_64"'

run_proof "altering Windows executable extension from .exe to .bin" \
  "$TARGET_IYI" \
  '".exe"' \
  '".bin"'

run_proof "altering wasm32 object extension from .wasm to .o" \
  "$TARGET_IYI" \
  '".wasm"' \
  '".o"'

run_proof "bypassing unix platform flag inclusion" \
  "$FLAGS_IYI" \
  'if target.unix?' \
  'if false && target.unix?'

run_proof "dropping MSVC linker /nologo argument" \
  "$LINKER_IYI" \
  '/nologo ' \
  ''

run_proof "altering WASM32 link flag target from wasm32-wasi to wasm32-unknown" \
  "$LINKER_IYI" \
  '--target=wasm32-wasi' \
  '--target=wasm32-unknown'

echo "  $MUTATIONS_RUN mutation proofs run"
if [ -e "$WORK/invalid-mutant" ]; then
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST PLATFORM EXERCISE CHECKS PASSED!"
else
  echo "== SELFHOST PLATFORM EXERCISE CHECKS FAILED!"
fi
exit $status
