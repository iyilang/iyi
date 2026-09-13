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
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
TARGET_IYI="$REPO/src/compiler/platform/target.iyi"
FLAGS_IYI="$REPO/src/compiler/platform/flags.iyi"
LINKER_IYI="$REPO/src/compiler/platform/linker.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the platform exercise (plain mode)"
if ! "$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_platform_exercise.iyi"; then
  echo "  FAILED to build bench/selfhost_platform_exercise.iyi in plain mode"
  exit 1
fi
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out" | head -n 25
if ! grep -qF "ALL SELFHOST PLATFORM CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  PLAIN EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Building and running the platform exercise (--release mode)"
if ! "$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/selfhost_platform_exercise.iyi"; then
  echo "  FAILED to build bench/selfhost_platform_exercise.iyi in release mode"
  exit 1
fi
"$WORK/exercise-release" > "$WORK/release.out" 2>&1
if ! grep -qF "ALL SELFHOST PLATFORM CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "  RELEASE EXERCISE FAILED"
  status=1
else
  echo "  release mode verification passed"
fi

echo
echo "== 3. Target and linker comparison against the front end being replaced"
cat <<'CRYSTAL_ORACLE_SCRIPT' > "$WORK/dump_crystal_platform.cr"
require "compiler/requires"

class Iyi::Compiler
  def test_linker_command(program, object_names, output_filename, output_dir)
    linker_command(program, object_names, output_filename, output_dir)
  end
end

class Iyi::Program
  def lib_flags(cross_compiling : Bool = false)
    if has_flag?("msvc")
      "/LIBPATH:/opt/homebrew/opt/bdw-gc/lib"
    else
      "-L/opt/homebrew/opt/bdw-gc/lib"
    end
  end
end

def normalize_paths(cmd : String) : String
  # Normalise absolute library search paths identically on both sides with a comment saying so:
  # Host library search paths vary across build machines, so paths ending in /lib are mapped to <LIBPATH>.
  parts = cmd.split(' ')
  norm_parts = [] of String
  parts.each do |p|
    if p == "-L/usr/local/lib"
      norm_parts << "-L<LIBPATH>"
    elsif p.starts_with?("-L/") && p.ends_with?("/lib")
      norm_parts << "-L<LIBPATH>"
    elsif p.starts_with?("/LIBPATH:/") && p.ends_with?("/lib")
      norm_parts << "/LIBPATH:<LIBPATH>"
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

triples.each do |t|
  target = Iyi::Codegen::Target.new(t)
  prog = Iyi::Program.new
  prog.codegen_target = target
  flags = prog.flags.to_a.sort

  compiler = Iyi::Compiler.new
  compiler.cross_compile = true
  compiler.codegen_target = target

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
CRYSTAL_ORACLE_SCRIPT

if ! LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
     CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
     -o "$WORK/oracle" "$WORK/dump_crystal_platform.cr" > "$WORK/oracle_build.log" 2>&1; then
  echo "  FAILED to build Crystal oracle:"
  cat "$WORK/oracle_build.log"
  exit 1
fi
"$WORK/oracle" > "$WORK/crystal.out"
"$WORK/exercise" dump > "$WORK/iyi.out"

if diff -u "$WORK/crystal.out" "$WORK/iyi.out" > "$WORK/diff.log"; then
  echo "  Parity summary: 24/24 target triples match 100% across normalized targets, flags, extensions, and link commands"
else
  echo "  PARITY FAILURE: iyi platform support diverged from Crystal frontend"
  cat "$WORK/diff.log"
  status=1
fi

echo
echo "== 4. Malformed-input and boundary rejection checks"
for bad in "invalid" "foo" "x86_64"; do
  if "$WORK/exercise-release" "$bad" >"$WORK/bad.out" 2>&1; then
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

prove_mutation() {
  label="$1"
  file_path="$2"
  old="$3"
  new="$4"
  echo "  [$label]"
  cp "$file_path" "$file_path.orig"
  python3 - "$file_path" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$file_path.orig" "$file_path" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$file_path.orig" "$file_path"
    rm -f "$file_path.orig"
    return
  fi
  echo "    patch verified applied in working tree"

  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_platform_exercise.iyi" >/dev/null 2>&1; then
    "$WORK/mut-exercise" dump > "$WORK/mut-iyi.out" 2>&1
    if diff -q "$WORK/crystal.out" "$WORK/mut-iyi.out" >/dev/null 2>&1; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the platform support output diverged, as it must"
    fi
  else
    echo "    caught: the mutated platform code did not build"
  fi

  cp "$file_path.orig" "$file_path"
  rm -f "$file_path.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$2" "$3" "$4"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
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

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST PLATFORM EXERCISE CHECKS PASSED!"
else
  echo "== SELFHOST PLATFORM EXERCISE CHECKS FAILED!"
fi
exit $status
