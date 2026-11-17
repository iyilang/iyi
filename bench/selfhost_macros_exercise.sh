#!/usr/bin/env bash
# Fails when the iyi macro engine stops agreeing with the one it replaces.
#
# Every fixture is expanded by each implementation site by site: the text each
# top-level `{% %}` and `{{ }}` site expands to, in source order, with where it
# is written. How the expansion ended (a skip, or a raise with its message and
# location) and the whole output follow. The two dumps are required
# byte-identical.
#
# A fixture whose header is `# refuse: <name>` names a macro method the port
# refuses by name. The oracle is not run on it (it would run the command); the
# port must report the refusal.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_macros_exercise.sh
set -eu
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if ! . "$REPO/bench/lib/host.sh"; then
  printf 'host-limited: unsupported test host or architecture\n' >&2
  exit 1
fi
if ! require_test_host; then
  host_limited "test host identity is unavailable or mismatched"
  exit 1
fi
if [ "$HOST_OS" = windows ] && ! command -v cygpath >/dev/null 2>&1; then
  host_limited "cygpath is required for native Windows paths"
  exit 1
fi
if [ -z "$PY" ]; then
  host_limited "a functional Python interpreter is required"
  exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
  host_limited "perl is required for the mutation proofs"
  exit 1
fi
HOST_LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}"
if [ "$HOST_OS" != windows ] && [ -z "$HOST_LLVM_CONFIG" ]; then
  host_limited "llvm-config is required to build the hosted oracle"
  exit 1
fi
IYI="$REPO/bin/iyi"
HOSTED_COMPILER="$REPO/bin/crystal"
INTERP="$REPO/src/compiler/macros/interpreter.iyi"
PARSER="$REPO/src/compiler/macros/macro_parser.iyi"
ENGINE="$REPO/src/compiler/macros/engine.iyi"
. "$REPO/bench/lib/mutation.sh"
if [ -n "${MACRO_GATE_KEEP:-}" ]; then
  WORK="$MACRO_GATE_KEEP"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
fi
WORK="$(cd "$WORK" && pwd)"
REPO_NATIVE="$(native_path "$REPO")"
WORK_NATIVE="$(native_path "$WORK")"
export IYI_PATH="$REPO_NATIVE/src"
cd "$REPO"

echo "== 1. Building and running the macro engine exercise"
"$IYI" build -o "$WORK_NATIVE/exercise$EXE" "$REPO_NATIVE/bench/selfhost_macros_exercise.iyi"
"$WORK/exercise$EXE" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST MACRO CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== Checking reported verification counts in plain mode"
for phrase in \
  "testing macro argument substitution... ok" \
  "testing macro splats and double splats... ok" \
  "testing macro control flow (if, unless, elsif, else)... ok" \
  "testing macro iteration (for over arrays, tuples, named tuples, ranges)... ok" \
  "testing macro stringification and identifier methods... ok" \
  "testing macro AST node methods... ok" \
  "testing macro fresh variable generation... ok" \
  "testing macro code and definition generation... ok" \
  "testing @type as the enclosing class's TypeNode... ok" \
  "testing that an expansion's nodes are in the calling file... ok" \
  "testing macro expansion shares normalizer counters and prelude flag... ok" \
  "ALL SELFHOST MACRO CHECKS PASSED SUCCESSFULLY!"; do
  if ! grep -qF "$phrase" "$WORK/plain.out"; then
    echo "  MISSING REPORTED CHECK: '$phrase'"
    status=1
  else
    echo "  verified report: '$phrase'"
  fi
done

echo
echo "== 2. Per-site expansion dump: the oracle and the port must print the same bytes"
cat <<'HOSTED_GOLDEN_SCRIPT' > "$WORK/dump_hosted_macro.cr"
require "compiler/requires"

# iyi: the line and column a TypeException was raised at, which the hosted
# class keeps in instance variables. The gate reads them through methods added
# here, in the oracle driver only; `CodeError` is abstract, so its own
# variables cannot be typed from here.
module Iyi
  class TypeException
    def gate_line : Int32
      @line_number || 0
    end

    def gate_column : Int32
      @column_number || 0
    end
  end
end

def escape_s(s : String) : String
  res = "\""
  i = 0
  while i < s.bytesize
    case s.byte_at(i).chr
    when '\n' then res += "\\n"
    when '\r' then res += "\\r"
    when '\t' then res += "\\t"
    when '\\' then res += "\\\\"
    when '"'  then res += "\\\""
    else res += s.byte_at(i).chr.to_s
    end
    i += 1
  end
  res + "\""
end

class NodeCounter < Iyi::Visitor
  getter count = 0
  def visit(node : Iyi::ASTNode)
    @count += 1
    true
  end
end

# The hosted parser wants `module` as the first thing in a file, and the port's
# files put their `@[Unsafe(...)]` annotation above it. For the sites dump the
# annotations above the header are blanked, which keeps every line where it was.
def strip_header_annotations(src : String) : String
  lines = src.split("\n")
  module_at = lines.index { |l| l.starts_with?("module ") }
  return src unless module_at
  i = 0
  while i < module_at
    lines[i] = "" if lines[i].starts_with?("@[")
    i += 1
  end
  lines.join("\n")
end

# Finds the top-level macro sites of a whole file, as the port's MacroSiteScan does.
# Each site comes with its context, and with the qualified name and generic flag
# of the class it is written in ("" at the top of the file).
class SiteFinder < Iyi::Visitor
  def visit(node : Iyi::ASTNode) : Bool
    true
  end

  def initialize(@context : String, @sites : Array(Tuple(Iyi::ASTNode, String, String, Bool)), @type_name : String = "", @generic : Bool = false)
  end

  def visit(node : Iyi::MacroIf) : Bool
    add_site(node)
    false
  end

  def visit(node : Iyi::MacroFor) : Bool
    add_site(node)
    false
  end

  def visit(node : Iyi::MacroExpression) : Bool
    add_site(node)
    false
  end

  def visit(node : Iyi::MacroVerbatim) : Bool
    add_site(node)
    false
  end

  def visit(node : Iyi::Macro) : Bool
    scan_body("macro", node.body, @type_name, @generic)
    false
  end

  def visit(node : Iyi::Def) : Bool
    scan_body("def:#{node.name}", node.body, @type_name, @generic)
    false
  end

  def visit(node : Iyi::ClassDef) : Bool
    scan_body("class", node.body, qualified(node.name.names), generic_names?(node.type_vars))
    false
  end

  # A module is generic here: its `@type` is not a class.
  def visit(node : Iyi::ModuleDef) : Bool
    scan_body("class", node.body, qualified(node.name.names), true)
    false
  end

  def qualified(names : Array(String)) : String
    @type_name.empty? ? names.join("::") : "#{@type_name}::#{names.join("::")}"
  end

  def generic_names?(type_vars : Array(String)?) : Bool
    if tv = type_vars
      !tv.empty?
    else
      false
    end
  end

  private def add_site(node : Iyi::ASTNode) : Nil
    @sites << {node, @context, @type_name, @generic}
  end

  private def scan_body(context : String, body : Iyi::ASTNode, type_name : String, generic : Bool) : Nil
    body.accept(SiteFinder.new(context, @sites, type_name, generic))
  end
end

# Whether a site reads `@type`, `@top_level`, `@def` or `@caller`, and whether every
# read of `@type` is a call of a method the port answers from the name.
class ContextProbe < Iyi::Visitor
  getter found = false
  getter type_reads = 0
  getter type_calls = 0
  getter other_reads = false

  def visit(node : Iyi::ASTNode) : Bool
    true
  end

  def visit(node : Iyi::InstanceVar) : Bool
    if node.name == "@type"
      @found = true
      @type_reads += 1
    elsif ["@top_level", "@def", "@caller"].includes?(node.name)
      @found = true
      @other_reads = true
    end
    true
  end

  def visit(node : Iyi::Call) : Bool
    if obj = node.obj
      if obj.is_a?(Iyi::InstanceVar) && obj.name == "@type" && ["name", "stringify", "id"].includes?(node.name)
        @type_calls += 1
      end
    end
    true
  end

  def names_only? : Bool
    !@other_reads && @type_reads == @type_calls
  end
end

def line_col(node : Iyi::ASTNode) : String
  if loc = node.location
    "#{loc.line_number}:#{loc.column_number}"
  else
    "0:0"
  end
end


args = ARGV.to_a
filename = ""
count = false
sites = false
host = false
target = ""
defines = [] of String
i = 0
while i < args.size
  a = args[i]
  if a == "--count"
    count = true
  elsif a == "--sites"
    sites = true
  elsif a == "--host-target"
    host = true
  elsif a == "--target"
    i += 1
    target = args[i]
  elsif a == "-D"
    i += 1
    defines << args[i]
  else
    filename = a
  end
  i += 1
end

if host
  puts Iyi::Config.host_target.to_s
  exit 0
end

src = File.read(filename)
parser = Iyi::Parser.new(sites ? strip_header_annotations(src) : src)
node = parser.parse
if sites
  program = Iyi::Program.new
  unless target.empty?
    program.codegen_target = Iyi::Codegen::Target.new(target)
  end
  defines.each { |d| program.flags << d }
  found = [] of Tuple(Iyi::ASTNode, String, String, Bool)
  node.accept(SiteFinder.new("top", found))
  found.each_with_index do |tuple, idx|
    site = tuple[0]
    context = tuple[1]
    type_name = tuple[2]
    generic = tuple[3]
    head = "site #{idx} #{site.class.name.split("::").last} #{line_col(site)} #{context}"
    probe = ContextProbe.new
    site.accept(probe)
    if context == "macro"
      puts "#{head} macro-body"
    elsif probe.found && !(probe.names_only? && !type_name.empty? && !generic)
      puts "#{head} needs-context"
    else
      scope : Iyi::Type = program
      if probe.found && !type_name.empty?
        scope = Iyi::NonGenericClassType.new(program, program, type_name, nil, false)
      end
      interp = Iyi::MacroInterpreter.new(program, scope, program, site.location, in_macro: false)
      begin
        interp.accept(site)
        puts "#{head} text=#{escape_s(interp.to_s)}"
      rescue ex : Iyi::SkipMacroException
        puts "#{head} skipped"
      rescue ex : Iyi::TypeException
        puts "#{head} error #{ex.gate_line}:#{ex.gate_column} message=#{escape_s(ex.message.to_s)}"
      end
    end
  end
  exit 0
end

the_macro : Iyi::Macro? = nil
the_call : Iyi::Call? = nil

def find_nodes(node : Iyi::ASTNode, the_macro : Iyi::Macro?, the_call : Iyi::Call?)
  case node
  when Iyi::Expressions
    node.expressions.each do |e|
      the_macro, the_call = find_nodes(e, the_macro, the_call)
    end
  when Iyi::Macro
    the_macro = node
  when Iyi::Call
    the_call = node if the_macro && the_call.nil?
  end
  {the_macro, the_call}
end

the_macro, the_call = find_nodes(node, nil, nil)
program = Iyi::Program.new
unless target.empty?
  program.codegen_target = Iyi::Codegen::Target.new(target)
end
defines.each { |d| program.flags << d }

# A fixture may bind type parameters with `# free: NAME KIND MEMBERS [splat]`
# lines (KIND is type or tuple; MEMBERS is comma-separated, no spaces). A
# splat tuple is the expansion scope, so that name becomes a tuple literal of
# type nodes, as the hosted interpreter does. A plain name is a type node.
def free_type(program, name)
  case name
  when "Int32" then program.int32
  when "Int64" then program.int64
  when "Bool" then program.bool
  when "UInt8" then program.uint8
  when "UInt64" then program.uint64
  when "Char" then program.char
  when "Float64" then program.float64
  when "Float32" then program.float32
  else raise "free-var fixture names an unknown type #{name}"
  end
end

free = {} of String => Iyi::TypeVar
path_lookup : Iyi::Type = program
src.each_line do |line|
  next unless line.starts_with?("# free: ")
  parts = line[8..].split(' ')
  name = parts[0]
  kind = parts[1]
  members = parts[2].split(',')
  splat = parts.size > 3 && parts[3] == "splat"
  typ = case kind
        when "type"
          free_type(program, members[0])
        when "tuple"
          program.tuple_of(members.map { |m| free_type(program, m) })
        else
          raise "free-var kind #{kind} is not in this driver"
        end
  free[name] = typ
  if splat && kind == "tuple"
    path_lookup = typ.as(Iyi::Type)
  end
end
# Facts name a real enum in the hosted interpreter, not a fabricated answer.
if src.each_line.any? { |line| line.starts_with?("# fact: ") }
  fact_scope = Iyi::EnumType.new(program, program, "MacroFactScope", program.int32)
  src.each_line do |line|
    next unless line.starts_with?("# fact: ")
    parts = line[8..].split(' ')
    fact_scope.add_constant(parts[0], parts[1].to_i64)
  end
  path_lookup = fact_scope
end
if src.each_line.any? { |line| line.starts_with?("# ivar: ") }
  fact_scope = Iyi::NonGenericClassType.new(program, program, "MacroFactScope", nil)
  src.each_line do |line|
    next unless line.starts_with?("# ivar: ")
    parts = line[8..].split(' ')
    fact_scope.declare_instance_var("@#{parts[0]}", free_type(program, parts[1]))
  end
  program.top_level_semantic_complete = true
  path_lookup = fact_scope
end


# The same interpreter `Program#expand_macro` builds, driven one top-level
# site at a time so each site's text can be read back. Free vars are the
# instantiated owner's type parameters (semantic_visitor.cr:2214-2215).
interp = Iyi::MacroInterpreter.new(program, path_lookup, path_lookup, the_macro.not_nil!, the_call.not_nil!, nil, in_macro: true)
interp.free_vars = free unless free.empty?
body = the_macro.not_nil!.body
nodes = [] of Iyi::ASTNode
if body.is_a?(Iyi::Expressions)
  body.expressions.each { |e| nodes << e }
else
  nodes << body
end

lines = [] of String
skipped = false
failure : {Int32, Int32, String}? = nil
nodes.each do |site|
  break if skipped || failure
  before = interp.to_s.bytesize
  begin
    interp.accept(site)
  rescue ex : Iyi::SkipMacroException
    skipped = true
    next
  rescue ex : Iyi::TypeException
    failure = {ex.gate_line, ex.gate_column, ex.message.to_s}
    next
  end
  next if site.is_a?(Iyi::MacroLiteral)
  after = interp.to_s
  text = after.byte_slice(before, after.bytesize - before)
  line = 0
  column = 0
  if loc = site.location
    line = loc.line_number
    column = loc.column_number
  end
  kind = site.class.name.split("::").last
  lines << "site #{lines.size} #{kind} #{line}:#{column} text=#{escape_s(text)}"
end

if count
  puts lines.size
else
  lines.each { |l| puts l }
  puts "skipped" if skipped
  if f = failure
    puts "error #{f[0]}:#{f[1]} message=#{escape_s(f[2])}"
  end
  puts "output text=#{escape_s(interp.to_s)}"
end
HOSTED_GOLDEN_SCRIPT

if ! LLVM_CONFIG="$HOST_LLVM_CONFIG" \
  CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/dump_hosted$EXE" "$WORK_NATIVE/dump_hosted_macro.cr"; then
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  exit 1
fi
if [ ! -x "$WORK/dump_hosted$EXE" ]; then
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  exit 1
fi

# The host triple is the hosted compiler's own. A fixture names another with a
# `# target: <triple>` line and its `-D` defines with `# define: <name>` lines.
# `# macro-sites` selects whole-program site scanning, as SiteFinder traverses
# ordinary expressions including TypeOf (hosted syntax/visitor.cr).
HOST_TRIPLE="$("$WORK/dump_hosted$EXE" --host-target)"
if [ -z "$HOST_TRIPLE" ]; then
  echo "  THE ORACLE REPORTED NO HOST TRIPLE: this gate cannot conclude anything"
  exit 1
fi
# The port's host triple is the hosted compiler's own, at run time.
PORT_HOST="$("$WORK/exercise$EXE" --host-target)"
if [ "$PORT_HOST" != "$HOST_TRIPLE" ]; then
  echo "  THE PORT'S HOST TRIPLE DIFFERS: port $PORT_HOST, hosted compiler $HOST_TRIPLE"
  status=1
fi
fixture_args() {
  awk -v host="$HOST_TRIPLE" '
    /^# target: / { t = $3 }
    /^# define: / { d = d " -D " $3 }
    /^# macro-sites$/ { sites = " --sites" }
    END { printf "--target %s%s%s", (t == "" ? host : t), d, sites }' "$1"
}

is_refusal() {
  awk '/^# refuse: / { found = 1 } END { exit !found }' "$1"
}

# These are full semantic programs, not a macro definition followed by a call.
is_semantic_fixture() {
  case "$(basename "$1")" in
    macro_def_shadows_macro.iyi|macro_typenode_ancestors.iyi|macro_lookup_arity.iyi) return 0 ;;
  esac
  return 1
}

compare_all() {
  local runner="$1" fixture fixture_native out_status=0
  for fixture in "$REPO"/bench/fixtures/macro_*.iyi; do
    is_semantic_fixture "$fixture" && continue
    if ! fixture_native="$(native_path "$fixture")"; then
      echo "INVALID MUTANT: cannot convert fixture path $fixture"
      return 2
    fi
    if is_refusal "$fixture"; then
      "$runner" $(fixture_args "$fixture") "$fixture_native" > "$WORK/a.dump" 2>/dev/null || { out_status=1; continue; }
      grep -q "^error .* message=.*is refused" "$WORK/a.dump" || out_status=1
      continue
    fi
    if ! "$WORK/dump_hosted$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/b.dump" 2>"$WORK/oracle.err"; then
      echo "INVALID MUTANT: hosted oracle failed for $fixture"
      cat "$WORK/oracle.err"
      return 2
    fi
    "$runner" $(fixture_args "$fixture") "$fixture_native" > "$WORK/a.dump" 2>/dev/null || { out_status=1; continue; }
    cmp -s "$WORK/a.dump" "$WORK/b.dump" || out_status=1
  done
  return "$out_status"
}

fixture_count=0
refusal_count=0
total_sites=0
for fixture in "$REPO"/bench/fixtures/macro_*.iyi; do
  is_semantic_fixture "$fixture" && continue
  fixture_name="bench/fixtures/$(basename "$fixture")"
  fixture_native="$(native_path "$fixture")"
  fixture_count=$((fixture_count + 1))
  if is_refusal "$fixture"; then
    refusal_count=$((refusal_count + 1))
    if "$WORK/exercise$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/iyi.dump" 2>/dev/null &&
       grep -q "^error .* message=.*is refused" "$WORK/iyi.dump"; then
      echo "  $fixture_name: refused by name, as the port's contract says"
    else
      echo "  $fixture_name: NOT REFUSED"
      diverged=$((diverged + 1))
      status=1
    fi
    continue
  fi
  if ! "$WORK/exercise$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/iyi.dump" 2> "$WORK/iyi.err"; then
    echo "  $fixture_name: THE PORT FAILED: $(awk 'NR==1' "$WORK/iyi.err")"
    diverged=$((diverged + 1))
    status=1
    continue
  fi
  "$WORK/dump_hosted$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/hosted.dump"
  if ! cmp -s "$WORK/iyi.dump" "$WORK/hosted.dump"; then
    echo "  $fixture_name: DUMPS DIFFER"
    diff -u "$WORK/hosted.dump" "$WORK/iyi.dump" | head -30
    diverged=$((diverged + 1))
    status=1
  else
    nodes_count=$(grep -c '^site ' "$WORK/hosted.dump" || true)
    echo "  $fixture_name: identical ($nodes_count sites match the hosted compiler)"
    total_sites=$((total_sites + nodes_count))
  fi
done
echo "  Parity summary: $((fixture_count - diverged - refusal_count))/$((fixture_count - refusal_count)) comparable fixtures identical ($total_sites sites); $refusal_count refusal fixtures"

echo "== 2a. The table of macro methods the hosted compiler answers is the one generated from its source"
"$PY" "$REPO_NATIVE/bench/macro_method_table.py" --check || status=1

echo "== 2b. Macro sites in the prelude and the port's source: the oracle and the port must agree site by site"
SITES_DIR="$WORK/sites"
mkdir -p "$SITES_DIR"
SITES_NATIVE="$(native_path "$SITES_DIR")"
"$PY" "$REPO_NATIVE/bench/macro_sites.py" --list > "$SITES_DIR/list"
while IFS="$(printf '\t')" read -r name rel; do
  "$WORK/dump_hosted$EXE" --sites "$REPO_NATIVE/$rel" > "$SITES_DIR/$name.oracle" 2> "$SITES_DIR/$name.oracle.err" || echo "file-error oracle exit=$?" > "$SITES_DIR/$name.oracle"
  "$WORK/exercise$EXE" --sites "$REPO_NATIVE/$rel" > "$SITES_DIR/$name.port" 2> "$SITES_DIR/$name.port.err" || echo "file-error port exit=$?" > "$SITES_DIR/$name.port"
done < "$SITES_DIR/list"
"$PY" "$REPO_NATIVE/bench/macro_sites.py" "$SITES_NATIVE" --check || status=1
echo
echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

# The shared mutation helper treats any nonzero status as caught. A failed
# build or oracle is an invalid mutant and must instead make the proof fail.
invalid_mutant() {
  echo "INVALID MUTANT: $*"
  [ "${_PM_ARMED:-0}" = 1 ]
}

build_mutant_exercise() {
  rm -f "$WORK/mut-exercise$EXE"
  if "$IYI" build -o "$WORK_NATIVE/mut-exercise$EXE" "$REPO_NATIVE/bench/selfhost_macros_exercise.iyi" > "$WORK/mut-build.log" 2>&1 &&
     [ -x "$WORK/mut-exercise$EXE" ]; then
    return 0
  fi
  cat "$WORK/mut-build.log"
  return 1
}

check_macros_still_match() {
  local rc
  if ! build_mutant_exercise; then
    invalid_mutant "macro exercise failed to build"
    return $?
  fi
  if compare_all "$WORK/mut-exercise$EXE"; then
    :
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      invalid_mutant "fixture oracle could not run"
      return $?
    fi
    return 1
  fi
  # The prelude's object file has the class-scoped sites that read `@type`
  # (`Object#to_s` among them), which no fixture reaches: their dumps must agree too.
  if ! "$WORK/dump_hosted$EXE" --sites "$REPO_NATIVE/src/iyi/object.iyi" > "$WORK/mut-sites.oracle" 2>"$WORK/oracle.err"; then
    cat "$WORK/oracle.err"
    invalid_mutant "hosted site oracle could not run"
    return $?
  fi
  "$WORK/mut-exercise$EXE" --sites "$REPO_NATIVE/src/iyi/object.iyi" > "$WORK/mut-sites.port" 2>/dev/null || return 1
  cmp -s "$WORK/mut-sites.oracle" "$WORK/mut-sites.port"
}

# This positive fixture has an inline site; macro_typeof_prelude has none.
# The two distinguish site scanning from the macro-definition/call parser.
check_typeof_sites() {
  if ! build_mutant_exercise; then
    invalid_mutant "macro exercise failed to build"
    return $?
  fi
  if ! "$WORK/dump_hosted$EXE" $(fixture_args "$REPO/bench/fixtures/macro_sites_typeof.iyi") "$REPO_NATIVE/bench/fixtures/macro_sites_typeof.iyi" > "$WORK/b.dump" 2>"$WORK/oracle.err"; then
    cat "$WORK/oracle.err"
    invalid_mutant "hosted typeof oracle could not run"
    return $?
  fi
  "$WORK/mut-exercise$EXE" $(fixture_args "$REPO/bench/fixtures/macro_sites_typeof.iyi") "$REPO_NATIVE/bench/fixtures/macro_sites_typeof.iyi" > "$WORK/a.dump" 2>/dev/null || return 1
  cmp -s "$WORK/a.dump" "$WORK/b.dump"
}

MUTATIONS_RUN=0

prove_mutation "whole-program typeof fixture bypasses site scanning" "$REPO/bench/selfhost_macros_exercise.iyi" \
  "  if sites
    print BenchSelfhostMacrosExercise.site_dump(source, flags)" \
  "  if false
    print BenchSelfhostMacrosExercise.site_dump(source, flags)" \
  -- check_typeof_sites || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "macro if condition truthiness inverted" "$INTERP" \
  "      if MacroMethods.truthy?(c)
        interpret(mi.then)" \
  "      if !MacroMethods.truthy?(c)
        interpret(mi.then)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "splat argument gathering emits empty tuple" "$INTERP" \
  "@vars[macro_arg.name] = TupleLiteral.new(splat_elems)" \
  "@vars[macro_arg.name] = TupleLiteral.new([] of ASTNode)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "macro expression output stringification suppressed" "$INTERP" \
  "val.to_s(@str)" \
  "# val.to_s(@str)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "for loop element binding corrupts loop variable" "$INTERP" \
  "@vars[mf.vars[0].name] = firsts[i]" \
  "@vars[mf.vars[0].name] = NilLiteral.new" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "fresh variable temp name prefix altered" "$INTERP" \
  "temp_name = new_temp_var_name(\"__temp_\")" \
  "temp_name = new_temp_var_name(\"__mut_\")" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

METHODS="$REPO/src/compiler/macros/methods.iyi"
TARGET_FLAGS="$REPO/src/compiler/macros/target_flags.iyi"
prove_mutation "collection any ignores truthy results" "$INTERP" \
  "return BoolLiteral.new(any) if method == \"any?\"" \
  "return BoolLiteral.new(false) if method == \"any?\"" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "tuple map drops its elements" "$INTERP" \
  "return TupleLiteral.new(results) if tuple" \
  "return TupleLiteral.new([] of ASTNode) if tuple" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "array map drops its elements" "$INTERP" \
  "    ArrayLiteral.new(results)" \
  "    ArrayLiteral.new([] of ASTNode)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "range map drops its elements" "$INTERP" \
  "elements << NumberLiteral.new(current.to_s, kind)" \
  "elements << NumberLiteral.new(\"0\", kind)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "collection splat loses its suffix" "$METHODS" \
  "text << args[0].as(StringLiteral).value" \
  "text << \"\"" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "flag? answers from a fixed set, not the target's" "$METHODS" \
  "PlatformFlags.has_flag?(flags, name)" \
  "PlatformFlags.has_flag?([\"darwin\", \"aarch64\"], name)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "target triple ignored when building the flag set" "$TARGET_FLAGS" \
  "Target.new(triple)" \
  "Target.new(\"x86_64-unknown-linux-gnu\")" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "-D defines dropped from the flag set" "$TARGET_FLAGS" \
  "        flags << define" \
  "        flags" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "host_flag? answers from the target's set, not the host's" "$INTERP" \
  "MacroMethods.has_flag?(MacroTargetFlags.host([] of String), flag_name_of(node))" \
  "MacroMethods.has_flag?(@flags, flag_name_of(node))" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "verbatim nesting ignores for blocks" "$PARSER" \
  "tag.starts_with?(\"for \") || tag.starts_with?(\"verbatim\")" \
  "tag.starts_with?(\"verbatim\")" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "skip_file does not stop the expansion" "$INTERP" \
  "@skipped = true" \
  "@skipped = false" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "raise message altered" "$INTERP" \
  "fail_at(node, raise_message(node.args))" \
  "fail_at(node, raise_message(node.args) + \"!\")" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "@type names the wrong class" "$INTERP" \
  "type_node = TypeNode.new(@scope_name)" \
  "type_node = TypeNode.new(\"Wrong\")" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "TypeNode#name appends a character" "$METHODS" \
  "return MacroId.new(rec.as(TypeNode).name)" \
  "return MacroId.new(rec.as(TypeNode).name + \"X\")" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# TypeNode#size is the tuple or named tuple type argument count (methods.iyi).
# A constant 0 makes macro_typenode_size.iyi expand the wrong branch.
prove_mutation "TypeNode#size ignores the type arguments" "$METHODS" \
  "return NumberLiteral.new(tn.type_args.size.to_s, NumberKind::I32)" \
  "return NumberLiteral.new(\"0\", NumberKind::I32)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


# TypeNode == compares the resolved type (ast.iyi). Always-false makes
# macro_typenode_eq.iyi expand the wrong branch.
prove_mutation "TypeNode == ignores the resolved type" "$REPO/src/compiler/macros/ast.iyi" \
  "return @name == tn.name && @sized == tn.sized && same_args?(tn.type_args)" \
  "return false && @name == tn.name && @sized == tn.sized && same_args?(tn.type_args)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


# CHANNEL_WAIT is a top-level flag? if (macro_channel_wait.iyi). Inverting the
# answer expands the other branch.
prove_mutation "flag? answers the opposite of the target's set" "$REPO/src/compiler/macros/interpreter.iyi" \
  "return BoolLiteral.new(MacroMethods.has_flag?(@flags, flag_name_of(node)))" \
  "return BoolLiteral.new(!MacroMethods.has_flag?(@flags, flag_name_of(node)))" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# A free type parameter resolves to its binding (macro_free_vars.iyi). Dropping
# the lookup leaves T undefined, so the expansion is an error instead of the
# tuple literal the hosted interpreter prints.
prove_mutation "a free type parameter is not bound" "$INTERP" \
  "return resolve_free_binding(bound)" \
  "return TypeNode.new(\"unbound\")" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# ArrayLiteral#find returns the element whose block is truthy (macro_array_find.iyi).
# Always-false makes the expansion nil instead of 2.
prove_mutation "ArrayLiteral#find never matches" "$INTERP" \
  "if MacroMethods.truthy?(val)" \
  "if false && MacroMethods.truthy?(val)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# HashLiteral#[] returns the value of the matching key (macro_hash_index.iyi).
# Always nil makes the expansion nil instead of the limit string.
prove_mutation "HashLiteral#[] ignores the key" "$METHODS" \
  "return hash.entries[i].value" \
  "return NilLiteral.new" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# TypeNode#[] returns the type argument at that index (macro_typenode_index.iyi).
# Always nil makes U[0] nil instead of Int32.
prove_mutation "TypeNode#[] ignores the index" "$METHODS" \
  "return TypeNode.new(tn.type_args[idx])" \
  "return NilLiteral.new" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))





# The enum scope fixture checks both declaration order and member values.
prove_mutation "type constants lose their declared names" "$METHODS" \
  "facts.constants.each_key { |name| names << MacroId.new(name) }" \
  "facts.constants.each_key { |name| names << MacroId.new(\"wrong\") }" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
prove_mutation "instance variables lose their names" "$METHODS" \
  "MetaMacroVar.new(variable.name, variable.type_name)" \
  "MetaMacroVar.new(\"wrong\", variable.type_name)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))


prove_mutation "sites expanded in the program scope, not their class" "$REPO/bench/selfhost_macros_exercise.iyi" \
  "scope = ref.type_name.empty? ? \"<Program>\" : ref.type_name" \
  "scope = \"<Program>\"" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "@top_level is no longer recognised" "$INTERP" \
  "if iv.name == \"@top_level\"" \
  "if iv.name == \"@top_levelX\"" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "hash for loop binds the value to the key variable" "$INTERP" \
  "firsts << entries[i].key" \
  "firsts << entries[i].value" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "range for loop drops its inclusive end" "$INTERP" \
  "limit = rng.exclusive ? to_v : to_v + 1" \
  "limit = rng.exclusive ? to_v : to_v" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "raise location moved to the brace" "$PARSER" \
  "exp.location = tag_loc" \
  "exp.location = open_loc" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "hash size counts one entry too many" "$METHODS" \
  "return NumberLiteral.new(hash.entries.size.to_s, NumberKind::I32)" \
  "return NumberLiteral.new((hash.entries.size + 1).to_s, NumberKind::I32)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "symbols print bare whatever their text" "$METHODS" \
  "plain = false" \
  "plain = plain" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The plain exercise rebuilt on the patched engine: zero only when every unit check still passes.
check_plain_exercise_passes() {
  if ! build_mutant_exercise; then
    invalid_mutant "macro exercise failed to build"
    return $?
  fi
  if ! "$WORK/mut-exercise$EXE" > "$WORK/mut-plain.out" 2>&1; then
    if grep -qF "Assertion failed:" "$WORK/mut-plain.out"; then
      return 1
    fi
    cat "$WORK/mut-plain.out"
    invalid_mutant "macro exercise failed without an assertion"
    return $?
  fi
  grep -qF "ALL SELFHOST MACRO CHECKS PASSED SUCCESSFULLY!" "$WORK/mut-plain.out"
}

prove_mutation "a macro call's expansion is parsed with no file name" "$ENGINE" \
  "parser = Parser.new(rep.output, file)" \
  "parser = Parser.new(rep.output)" \
  -- check_plain_exercise_passes || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST MACRO EXPANSION CHECKS PASSED"
else
  echo "SELFHOST MACRO EXPANSION CHECKS FAILED"
fi
exit $status
