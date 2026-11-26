#!/usr/bin/env bash
# Fails when the iyi command driver stops agreeing with the one it replaces.
#
# The port is only worth something if it parses argument vectors, dispatches
# commands, and reports usage and errors the same way the front end iyi is
# still bootstrapped from does. Every vector in the trimmed corpus is run
# through both implementations, dumped in the same format, and required
# byte-identical.
#
# Machine-specific properties (absolute filesystem paths, program names,
# and platform-dependent target/LLVM version banners) are normalized
# identically in both implementations' outputs so the gate holds across
# workstations and CI environments without loosening the check.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_command_exercise.sh
set -uo pipefail
status=0
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd -P)"
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
. "$REPO/bench/lib/mutation.sh"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
DRIVER="$REPO/src/compiler/command/driver.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO_NATIVE="$(native_path "$REPO")" || exit 1
WORK_NATIVE="$(native_path "$WORK")" || exit 1
export IYI_PATH="$REPO_NATIVE/src"
# No vector may connect to a daemon inherited from the caller's environment.
unset IYI_DAEMON_SOCKET CRYSTAL_DAEMON_SOCKET

echo "== 1. Building and running the command driver exercise"
if ! "$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_command_exercise.iyi" > "$WORK/build.log" 2>&1; then
  echo "  FAILED to build the command exercise"
  cat "$WORK/build.log"
  exit 1
fi
if ! "$WORK/exercise$EXE" </dev/null > "$WORK/iyi_raw.out" 2> "$WORK/iyi_run.err"; then
  echo "  FAILED to run the command exercise"
  cat "$WORK/iyi_run.err"
  exit 1
fi
if [ -s "$WORK/iyi_run.err" ]; then
  echo "  FAILED: unexpected command exercise stderr"
  cat "$WORK/iyi_run.err"
  exit 1
fi

echo
echo "== 2. Command dispatch comparison against the front end being replaced"
cat <<'HOSTED_ORACLE_SCRIPT' > "$WORK/dump_hosted_command.cr"
require "compiler/requires"
require "json"

class Iyi::Command
  class_property current_command : String = ""
  def optimization_probe
    config = create_compiler("build", defer_move_aside: true)
    puts "optimization_mode=#{config.compiler.optimization_mode}"
  end
  def threads_probe
    config = create_compiler("build", defer_move_aside: true)
    puts "n_threads=#{config.compiler.n_threads}"
  end




  def init
    Iyi::Command.current_command = "init"
    previous_def
  end

  def build
    Iyi::Command.current_command = "build"
    previous_def
  end

  def run_command(single_file = false)
    Iyi::Command.current_command = "run"
    previous_def
  end

  def env
    Iyi::Command.current_command = "env"
    previous_def
  end

  def eval
    Iyi::Command.current_command = "eval"
    previous_def
  end

  def repl
    Iyi::Command.current_command = "repl"
    previous_def
  end

  def spec
    Iyi::Command.current_command = "spec"
    previous_def
  end

  def doc
    Iyi::Command.current_command = "doc"
    previous_def
  end

  def test
    Iyi::Command.current_command = "test"
    previous_def
  end

  def get
    Iyi::Command.current_command = "get"
    previous_def
  end

  def run_sandbox
    Iyi::Command.current_command = "run"
    previous_def
  end

  def vet
    Iyi::Command.current_command = "vet"
    previous_def
  end

  def check
    Iyi::Command.current_command = "check"
    previous_def
  end

  def fix
    Iyi::Command.current_command = "fix"
    previous_def
  end

  def bind
    Iyi::Command.current_command = "bind"
    previous_def
  end

  def migrate
    Iyi::Command.current_command = "migrate"
    previous_def
  end

  def lsp
    Iyi::Command.current_command = "lsp"
    previous_def
  end

  def mcp
    Iyi::Command.current_command = "mcp"
    previous_def
  end

  def clear_cache
    Iyi::Command.current_command = "clear_cache"
    previous_def
  end

  def daemon
    Iyi::Command.current_command = "daemon"
    subcommand = options.first?
    if subcommand == "start"
      Iyi::Command.current_command = "daemon start"
    elsif subcommand == "build"
      Iyi::Command.current_command = "daemon build"
    end
    previous_def
  end

  def mod
    Iyi::Command.current_command = "mod"
    subcommand = options.first?
    if subcommand == "dump"
      Iyi::Command.current_command = "mod dump"
    elsif subcommand == "diff"
      Iyi::Command.current_command = "mod diff"
    elsif subcommand == "context"
      Iyi::Command.current_command = "mod context"
    end
    previous_def
  end

  def tool
    Iyi::Command.current_command = "tool"
    previous_def
  end

  def context
    Iyi::Command.current_command = "tool context"
    previous_def
  end

  def format
    Iyi::Command.current_command = "tool format"
    previous_def
  end

  def flags
    Iyi::Command.current_command = "tool flags"
    previous_def
  end

  def expand
    Iyi::Command.current_command = "tool expand"
    previous_def
  end

  def tool_bind
    Iyi::Command.current_command = "tool bind"
    previous_def
  end

  def hierarchy
    Iyi::Command.current_command = "tool hierarchy"
    previous_def
  end

  def dependencies
    Iyi::Command.current_command = "tool dependencies"
    previous_def
  end

  def implementations
    Iyi::Command.current_command = "tool implementations"
    previous_def
  end

  def types
    Iyi::Command.current_command = "tool types"
    previous_def
  end

  def unreachable(verb = "tool unreachable")
    Iyi::Command.current_command = verb == "vet" ? "vet" : "tool unreachable"
    previous_def(verb)
  end

  def macro_code_coverage
    Iyi::Command.current_command = "tool macro_code_coverage"
    previous_def
  end
end

def classify(argv : Array(String)) : Nil
  Iyi::Command.current_command = ""
  cmd_first = argv.first?
  if !cmd_first || cmd_first.in?("--help", "-h") || "help".starts_with?(cmd_first)
    Iyi::Command.current_command = "help"
  elsif cmd_first.in?("--version", "-v") || "version".starts_with?(cmd_first)
    Iyi::Command.current_command = "version"
  elsif "deps".starts_with?(cmd_first)
    Iyi::Command.current_command = "deps"
  elsif "tool".starts_with?(cmd_first)
    Iyi::Command.current_command = "tool"
  elsif cmd_first == "daemon"
    Iyi::Command.current_command = "daemon"
  elsif "mod".starts_with?(cmd_first)
    Iyi::Command.current_command = "mod"
  end

end

if ARGV.first? == "--optimization-probe"
  arguments = ARGV[1..] + ["-o", "samples/iyi/hello.option-probe", "samples/iyi/hello.iyi"]
  Iyi::Command.new(arguments).optimization_probe
elsif ARGV.first? == "--threads-probe"
  arguments = ARGV[1..] + ["-o", "samples/iyi/hello.option-probe", "samples/iyi/hello.iyi"]
  Iyi::Command.new(arguments).threads_probe
elsif ARGV.first? == "--one"
  vectors = Array(Array(String)).from_json(File.read(ARGV[1]))
  argv = vectors[ARGV[2].to_i]
  command_file = ARGV[3]
  classify(argv)
  at_exit { File.write(command_file, Iyi::Command.current_command) }
  Iyi::Command.new(argv.dup).run
else
  vectors_file = ARGV[0]
  command_dir = ARGV[1]
  vectors = Array(Array(String)).from_json(File.read(vectors_file))
  executable = Process.executable_path || raise "cannot locate hosted oracle"
  vectors.each_with_index do |argv, idx|
    out_io = IO::Memory.new
    err_io = IO::Memory.new
    command_file = File.join(command_dir, "command-#{idx}")
    File.delete(command_file) if File.exists?(command_file)
    status = Process.run(executable, ["--one", vectors_file, idx.to_s, command_file],
      input: :inherit, output: out_io, error: err_io)
    raise "child did not record command for vector #{idx}" unless File.file?(command_file)
    cmd = File.read(command_file)
    out_s = out_io.to_s
    err_s = err_io.to_s
    combined = String.build do |sb|
      sb.puts out_s.strip unless out_s.strip.empty?
      sb.puts err_s.strip unless err_s.strip.empty?
    end.strip
    puts "=== VECTOR #{idx}: #{argv.inspect} ==="
    puts "command: #{cmd}"
    puts "exit: #{status.exit_code}"
    unless combined.empty?
      puts "output:"
      puts combined
    end
    puts "stdout:"
    print out_s
    puts "\nend stdout"
    puts "stderr:"
    print err_s
    puts "\nend stderr"
  end
end
HOSTED_ORACLE_SCRIPT

# The child uses real exits because the base driver catches exceptions.
if ! CRYSTAL_PATH="$REPO_NATIVE/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/hosted-oracle$EXE" "$WORK_NATIVE/dump_hosted_command.cr" > "$WORK/oracle-build.log" 2>&1; then
  echo "  FAILED to build hosted command oracle"
  cat "$WORK/oracle-build.log"
  exit 1
fi

# Extract the literal corpus without changing its argument order.
if ! "$PY" - "$REPO_NATIVE/bench/selfhost_command_exercise.iyi" "$WORK_NATIVE/vectors.json" <<'PY'
import ast, json, sys

def literal(node):
    if isinstance(node, ast.List):
        return [literal(item) for item in node.elts]
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    raise ValueError(f"unexpected corpus expression: {ast.dump(node)}")

vectors = []
with open(sys.argv[1], encoding="utf-8") as source:
    for line in source:
        line = line.strip()
        if line.startswith("vectors <<"):
            expr = line[len("vectors <<"):].strip()
            vectors.append([] if expr == "[] of String" else literal(ast.parse(expr, mode="eval").body))
if len(vectors) != 250:
    raise ValueError(f"expected 250 vectors, found {len(vectors)}")
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(vectors, output)
PY
then
  echo "  FAILED to extract the command vectors"
  exit 1
fi

if ! "$WORK/hosted-oracle$EXE" "$WORK_NATIVE/vectors.json" "$WORK_NATIVE" </dev/null > "$WORK/hosted_raw.out" 2> "$WORK/hosted_run.err"; then
  echo "  FAILED to run hosted command oracle"
  cat "$WORK/hosted_run.err"
  exit 1
fi
if [ -s "$WORK/hosted_run.err" ]; then
  echo "  FAILED: unexpected hosted oracle stderr"
  cat "$WORK/hosted_run.err"
  exit 1
fi

# Exercise the hosted parser and the port directly; neither compiles or writes the source.
check_optimization() {
  local exe=$1 level spelling count=0
  for level in 0 1 2 3 s z; do
    for spelling in joined separated; do
      set -- "-O$level"
      [ "$spelling" != separated ] || set -- -O "$level"
      if ! "$WORK/hosted-oracle$EXE" --optimization-probe "$@" >"$WORK/opt.hosted" 2>"$WORK/opt.hosted.err"; then
        echo "  INVALID: hosted option probe failed for $*"
        cat "$WORK/opt.hosted.err"
        return 2
      fi
      if ! "$exe" --optimization-probe "$@" >"$WORK/opt.port" 2>"$WORK/opt.port.err"; then
        echo "  optimization probe failed for $*"
        cat "$WORK/opt.port.err"
        return 1
      fi
      if ! cmp -s "$WORK/opt.hosted" "$WORK/opt.port"; then
        echo "  optimization mismatch for $*"
        diff -u "$WORK/opt.hosted" "$WORK/opt.port"
        return 1
      fi
      count=$((count + 1))
    done
  done
  echo "  Optimization parser: $count/12 joined and separated forms match the hosted parser"
}

if ! check_optimization "$WORK/exercise$EXE"; then
  status=1
fi
check_threads() {
  local exe=$1 n spelling count=0
  for n in 1 3 17; do
    for spelling in separated equals; do
      set -- --threads "$n"
      [ "$spelling" != equals ] || set -- "--threads=$n"
      if ! "$WORK/hosted-oracle$EXE" --threads-probe "$@" >"$WORK/threads.hosted" 2>"$WORK/threads.hosted.err"; then
        echo "  INVALID: hosted thread probe failed for $*"
        cat "$WORK/threads.hosted.err"
        return 2
      fi
      if ! "$exe" --threads-probe "$@" >"$WORK/threads.port" 2>"$WORK/threads.port.err"; then
        echo "  thread probe failed for $*"
        cat "$WORK/threads.port.err"
        return 1
      fi
      if ! cmp -s "$WORK/threads.hosted" "$WORK/threads.port"; then
        echo "  thread count mismatch for $*"
        diff -u "$WORK/threads.hosted" "$WORK/threads.port"
        return 1
      fi
      count=$((count + 1))
    done
  done
  echo "  Thread parser: $count/6 forms match the hosted parser"
}

if ! check_threads "$WORK/exercise$EXE"; then
  status=1
fi


# Compare combined output with symmetric help-column normalization, then compare
# each captured stream without option-column normalization.
normalize_command() {
  REPO_POSIX="$REPO" REPO_NATIVE_ROOT="$REPO_NATIVE" \
    "$PY" - "$(native_path "$1")" "$(native_path "$2")" <<'PY'
import os, re, sys
src, dst = sys.argv[1:]
repo, native = os.environ["REPO_POSIX"], os.environ["REPO_NATIVE_ROOT"]
with open(src, encoding="utf-8") as source:
    text = source.read()
roots = {repo, native, repo.replace("/", "\\"), native.replace("/", "\\")}
roots |= {root.replace("\\", "\\\\") for root in roots}
for root in sorted(roots, key=len, reverse=True):
    text = text.replace(root, "<REPO>")
text = re.sub(r'Usage: crystal\b|Usage: iyi\b', 'Usage: <prog>', text)
text = re.sub(r'LLVM: \S+', 'LLVM: <llvm-version>', text)
text = re.sub(r'Default target: \S+', 'Default target: <default-target>', text)
parts = re.split(r'(?m)^(stdout:|end stdout|stderr:|end stderr)$', text)
in_stream = False
for index, part in enumerate(parts):
    if part in ("stdout:", "stderr:"):
        in_stream = True
    elif part in ("end stdout", "end stderr"):
        in_stream = False
    elif not in_stream:
        part = re.sub(r'\n {20,}', '  ', part)
        lines = [re.sub(r"^(\s+)(-[-a-zA-Z0-9_, =\[\]/|<>]+?)\s{2,}(\S)", r"  \2  \3", line) for line in part.splitlines()]
        parts[index] = "\n".join(lines) + ("\n" if part.endswith("\n") else "")
text = "".join(parts)
with open(dst, "w", encoding="utf-8", newline="") as output:
    output.write(text)
PY
}

normalize_command "$WORK/iyi_raw.out" "$WORK/iyi.out" || exit 1
normalize_command "$WORK/hosted_raw.out" "$WORK/hosted.out" || exit 1
if [ "$(grep -c '^=== VECTOR' "$WORK/iyi.out")" -ne 250 ] || [ "$(grep -c '^=== VECTOR' "$WORK/hosted.out")" -ne 250 ]; then
  echo "  FAILED: expected 250 command vectors from each implementation"
  exit 1
fi

if ! cmp -s "$WORK/iyi.out" "$WORK/hosted.out"; then
  echo "  COMMAND DRIVER OUTPUT DIFFERS FROM ORACLE"
  diff -u "$WORK/hosted.out" "$WORK/iyi.out" | head -30
  status=1
else
  echo "  Parity summary: 250/250 vectors match identically against the front end"
fi

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

check_command_mutant() {
  rm -f "$WORK/mut-exercise$EXE"
  if ! "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_command_exercise.iyi" > "$WORK/mut-build.log" 2>&1 || [ ! -f "$WORK/mut-exercise$EXE" ]; then
    echo "  INVALID MUTANT: command exercise did not build"
    cat "$WORK/mut-build.log"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  if ! "$WORK/mut-exercise$EXE" </dev/null > "$WORK/iyi_mut_raw.out" 2> "$WORK/mut-run.err" || [ -s "$WORK/mut-run.err" ]; then
    echo "  INVALID MUTANT: command exercise did not run cleanly"
    cat "$WORK/mut-run.err"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  if [ "$(grep -c '^=== VECTOR' "$WORK/iyi_mut_raw.out")" -ne 250 ] ||
     ! normalize_command "$WORK/iyi_mut_raw.out" "$WORK/iyi_mut.out"; then
    echo "  INVALID MUTANT: command exercise output was incomplete"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  local diff_status=0
  diff -u "$WORK/hosted.out" "$WORK/iyi_mut.out" > "$WORK/mut-diff.log" || diff_status=$?
  if [ "$diff_status" -eq 0 ]; then
    return 0
  elif [ "$diff_status" -eq 1 ]; then
    echo "  COMMAND DRIVER OUTPUT DIFFERS FROM ORACLE"
    return 1
  fi
  echo "  INVALID MUTANT: comparison failed"
  touch "$WORK/invalid-mutant"
  return 0
}

MUTATIONS_RUN=0
check_optimization_mutant() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-opt$EXE" "$REPO_NATIVE/bench/selfhost_command_exercise.iyi" >"$WORK/mut-opt-build.log" 2>&1; then
    cat "$WORK/mut-opt-build.log"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  local rc=0
  check_optimization "$WORK/mut-opt$EXE" || rc=$?
  if [ "$rc" -eq 2 ]; then
    touch "$WORK/invalid-mutant"
    return 0
  fi
  return "$rc"
}

prove_mutation "optimization: -Oz is refused" "$DRIVER" \
  'level == "3" || level == "s" || level == "z"' \
  'level == "3" || level == "s"' \
  -- check_optimization_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
check_threads_mutant() {
  if ! "$IYI" build -o "$WORK_NATIVE/mut-threads$EXE" "$REPO_NATIVE/bench/selfhost_command_exercise.iyi" >"$WORK/mut-threads-build.log" 2>&1; then
    cat "$WORK/mut-threads-build.log"
    touch "$WORK/invalid-mutant"
    return 0
  fi
  local rc=0
  check_threads "$WORK/mut-threads$EXE" || rc=$?
  if [ "$rc" -eq 2 ]; then
    touch "$WORK/invalid-mutant"
    return 0
  fi
  return "$rc"
}

prove_mutation "threads: the parsed count is one too high" "$DRIVER" \
  '          opts.n_threads = n' \
  '          opts.n_threads = n + 1' \
  -- check_threads_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


prove_mutation "build prefix matching stops accepting prefixes" "$DRIVER" \
  'when "build".starts_with?(command)' \
  'when command == "build"' \
  -- check_command_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "format option description changes" "$DRIVER" \
  'format_desc = "Output format: #{allowed_formats[0]} (default), #{rest.join(", ")}"' \
  'format_desc = "changed format description"' \
  -- check_command_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "invalid option exit code changes from failure to success" "$DRIVER" \
  '    return opts if @exit_code
    if flag = first_unrecognised
      abort "Invalid option: #{flag}", Exit::USAGE_ERROR' \
  '    return opts if @exit_code
    if flag = first_unrecognised
      abort "Invalid option: #{flag}", Exit::OK' \
  -- check_command_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "unknown command error message changes wording" "$DRIVER" \
  'abort "unknown command: #{command}", Exit::USAGE_ERROR' \
  'abort "bad command: #{command}", Exit::USAGE_ERROR' \
  -- check_command_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "subcommand prefix matching stops accepting prefixes" "$DRIVER" \
  'when "context".starts_with?(tool_sub)' \
  'when tool_sub == "context"' \
  -- check_command_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "mod subcommand dispatch fails to recognize dump" "$DRIVER" \
  'when "dump"' \
  'when "d_u_m_p"' \
  -- check_command_mutant || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"
if [ -e "$WORK/invalid-mutant" ]; then
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST COMMAND DRIVER CHECKS PASSED"
else
  echo "== SELFHOST COMMAND DRIVER CHECKS FAILED"
fi
exit $status
