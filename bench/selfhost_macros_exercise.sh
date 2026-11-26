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
# Section 2c checks the file methods and env against the hosted rule (macro
# confinement, methods.cr 40-243). Each case is written as a key=value file and
# expanded by the hosted oracle (--confine) and by the port (--confine) on a
# temporary layout, and the verdict and message must match. The one difference
# the port keeps by design is a macro expanded with no confinement context: it
# refuses, where hosted resolves the package from the file itself. The mutation
# proofs at the end rebuild the port on each condition and require a difference.
# Every path a native program reads is spelled the way native_path spells it, and a run that gives no
# verdict (a crash, a non-zero exit, empty output) stops the gate with exit 76: it is never identical.
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
SYNTAX_PARSER="$REPO/src/compiler/syntax/parser.iyi"
ENGINE="$REPO/src/compiler/macros/engine.iyi"
CONFINEMENT="$REPO/src/compiler/macros/confinement.iyi"
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
  "testing macro search path separators... ok" \
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
  module_at = nil
  lines.each_with_index do |line, index|
    stripped = line.strip
    if stripped.starts_with?("module ")
      module_at = index
      break
    end
    break unless stripped.empty? || stripped.starts_with?("#") || stripped.starts_with?("@[")
  end
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


# One confinement case (section 2c). The package context is the one package_macro
# in spec/compiler/macro/iyi_package_security_spec.cr builds.
def confine_case(case_path : String) : Nil
  fields = {} of String => String
  File.read(case_path).each_line do |raw|
    parts = raw.chomp.split("=", 2)
    fields[parts[0]] = parts[1] if parts.size == 2
  end
  root = fields["root"]? || ""
  dep = fields["dep"]? || ""
  Dir.cd(fields["dir"])
  program = Iyi::Program.new
  unless root.empty?
    program.filename = File.join(root, "main.iyi")
    program.iyi_root_package = {"example.test/app", root}
  end
  unless dep.empty?
    program.iyi_mod_table = [{"example.test/dep", dep}]
  end
  program.top_level_semantic_complete = true
  parser = program.new_parser("macro check\n#{fields["body"]}\nend")
  parser.filename = fields["definition"]
  parsed_macro = parser.parse.as(Iyi::Macro)
  call = Iyi::Call.new("check", [] of Iyi::ASTNode)
  call.location = Iyi::Location.new(fields["caller"], 1, 1)
  begin
    expanded = program.expand_macro(parsed_macro, call, program, program)[0].chomp
    puts "value=#{escape_s(expanded)}"
  rescue ex : Iyi::TypeException
    puts "error #{ex.gate_line}:#{ex.gate_column} message=#{escape_s(ex.message.to_s)}"
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
if args.size == 2 && args[0] == "--confine"
  confine_case(args[1])
  exit 0
end

src = File.read(filename)
parser = Iyi::Parser.new(sites ? strip_header_annotations(src) : src)
parser.filename = filename if sites
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

# The sentence a refusal fixture's port error carries: hosted's sentence for
# `system`, and the port's `is refused` for `run`, which the port refuses by name.
refusal_sentence() {
  case "$(awk '/^# refuse: / { print $3; exit }' "$1")" in
    system) echo 'is not allowed in an .iyi macro: compile-time shell commands are forbidden' ;;
    *) echo 'is refused' ;;
  esac
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
      grep -q "^error .* message=.*$(refusal_sentence "$fixture")" "$WORK/a.dump" || out_status=1
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
       grep -q "^error .* message=.*$(refusal_sentence "$fixture")" "$WORK/iyi.dump"; then
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
echo "== 2c. The file methods and env against the hosted rule: each case on a temporary layout, the same verdict"
CONF="$WORK/confine"
rm -rf "$CONF"
mkdir -p "$CONF/layout/app" "$CONF/layout/dep" "$CONF/layout/outside" "$CONF/cases" "$CONF/hosted" "$CONF/port" "$CONF/expected"
printf 'inside-app\n' > "$CONF/layout/app/inside.txt"
printf 'dep-data\n' > "$CONF/layout/dep/data.txt"
printf 'outside-secret\n' > "$CONF/layout/outside/secret.txt"
: > "$CONF/layout/app/main.iyi"
: > "$CONF/layout/dep/dep.iyi"
: > "$CONF/layout/outside/outside.iyi"
# The cases below read through two links: `escape`, to a directory outside the package, and `dangling`, to nothing.
# Git Bash on Windows answers a plain `ln -s` with a copy of a target that exists and an error for one that does not,
# so there the links are asked for as native ones (MSYS=winsymlinks:nativestrict, which fails rather than copies and
# needs the symlink privilege a CI runner's account has) and then checked to be links. Where that fails, the three
# cases that need them and the two proofs that need those cases are not run and say so (`host-limited:`, as
# bench/packages_resolve.sh does for its real-link step); everywhere a link can be made, all of them run.
CONF_LINKS=no
if [ "$HOST_OS" = windows ]; then
  if MSYS=winsymlinks:nativestrict ln -s ../outside "$CONF/layout/app/escape" 2>/dev/null &&
     MSYS=winsymlinks:nativestrict ln -s ../nowhere "$CONF/layout/app/dangling" 2>/dev/null &&
     [ -L "$CONF/layout/app/escape" ] && [ -L "$CONF/layout/app/dangling" ]; then
    CONF_LINKS=yes
  else
    rm -rf "$CONF/layout/app/escape" "$CONF/layout/app/dangling"
  fi
else
  ln -s ../outside "$CONF/layout/app/escape"
  ln -s ../nowhere "$CONF/layout/app/dangling"
  CONF_LINKS=yes
fi
# Case fields are read by native programs; convert Git Bash's layout path before either driver uses it.
CONF_L="$(native_path "$(cd "$CONF/layout" && pwd -P)")"
# A native Windows path may be a drive path or a UNC share.
native_layout_check() {
  if [ "$HOST_OS" = windows ]; then
    case "$1" in
      [A-Za-z]:/*|//?*/*) ;;
      *) printf 'SETUP FAILURE: layout %s is not a native Windows path\n' "$1" >&2; return 76 ;;
    esac
  fi
  return 0
}
native_layout_check "$CONF_L" || exit $?
export IYI_MACRO_CONFINE_SET=gate-value
unset IYI_MACRO_CONFINE_UNSET
cat <<'CONFINE_CASES' > "$CONF/cases.manifest"
case app-read-inside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/app/inside.txt") }}
case app-read-outside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/outside/secret.txt") }}
case app-read-through-link
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/app/escape/secret.txt") }}
case app-read-link-dotdot
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/app/escape/../inside.txt") }}
case app-read-dotdot
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/app/../outside/secret.txt") }}
case app-read-relative-inside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("app/inside.txt") }}
case app-read-relative-dotdot
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("app/../outside/secret.txt") }}
case app-read-directory
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/app") }}
case app-read-directory-optional
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file?("@L@/app") }}
case app-library-exists
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ file_exists?("@REPO@/src/std/file.iyi") }}
case app-missing-optional-inside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file?("@L@/app/missing.txt") }}
case app-missing-optional-outside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file?("@L@/outside/missing.txt") }}
case app-missing-required-inside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/app/missing.txt") }}
case app-exists-outside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ file_exists?("@L@/outside/secret.txt") }}
case app-exists-inside
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ file_exists?("@L@/app/inside.txt") }}
case app-dangling-link
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ file_exists?("@L@/app/dangling") }}
case dep-read-inside
definition=@L@/dep/dep.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=@L@/dep
dir=@L@
body={{ read_file("@L@/dep/data.txt") }}
case dep-read-outside
definition=@L@/dep/dep.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=@L@/dep
dir=@L@
body={{ read_file("@L@/app/inside.txt") }}
case dep-library-exists
definition=@L@/dep/dep.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=@L@/dep
dir=@L@
body={{ file_exists?("@REPO@/src/std/file.iyi") }}
case outside-macro-reads-own-dir
definition=@L@/outside/outside.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ read_file("@L@/outside/secret.txt") }}
case env-root-set
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ env("IYI_MACRO_CONFINE_SET") }}
case env-root-unset
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ env("IYI_MACRO_CONFINE_UNSET").nil? }}
case env-dep
definition=@L@/dep/dep.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=@L@/dep
dir=@L@
body={{ env("IYI_MACRO_CONFINE_SET") }}
case env-outside-macro
definition=@L@/outside/outside.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ env("IYI_MACRO_CONFINE_SET") }}
case system-root
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ system("echo hi") }}
case system-dep
definition=@L@/dep/dep.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=@L@/dep
dir=@L@
body={{ system("echo hi") }}
case backtick-root
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=
dir=@L@
body={{ `echo hi` }}
case backtick-dep
definition=@L@/dep/dep.iyi
caller=@L@/app/main.iyi
root=@L@/app
dep=@L@/dep
dir=@L@
body={{ `echo hi` }}
case no-context-read
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=
dep=
dir=@L@
body={{ read_file("@L@/app/inside.txt") }}
case no-context-env
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=
dep=
dir=@L@
body={{ env("IYI_MACRO_CONFINE_SET") }}
case no-context-system
definition=@L@/app/main.iyi
caller=@L@/app/main.iyi
root=
dep=
dir=@L@
body={{ system("echo hi") }}
case no-context-system-windows-name
definition=C:\macro fixture\main.iyi
caller=C:\macro fixture\main.iyi
root=
dep=
dir=@L@
body={{ system("echo hi") }}
case no-context-backtick-windows-name
definition=C:\macro fixture\main.iyi
caller=C:\macro fixture\main.iyi
root=
dep=
dir=@L@
body={{ `echo hi` }}
CONFINE_CASES
sed -e "s#@L@#$CONF_L#g" -e "s#@REPO@#$REPO_NATIVE#g" "$CONF/cases.manifest" |
  awk -v dir="$CONF/cases" '/^case /{f=dir "/" $2 ".case"; next} {print > f}'
if [ "$CONF_LINKS" != yes ]; then
  rm -f "$CONF/cases/app-read-through-link.case" "$CONF/cases/app-read-link-dotdot.case" "$CONF/cases/app-dangling-link.case"
  host_limited "skipped: no symlinks on this runner: the cases app-read-through-link, app-read-link-dotdot and app-dangling-link need a link; every runner that can make one runs them"
fi
# The layout and the repository print as <LAYOUT> and <REPO>, so the table reads the same on every run.
confine_normal() {
  sed -e "s#$CONF_L#<LAYOUT>#g" -e "s#$REPO_NATIVE#<REPO>#g"
}


# An empty file or a crashed runner is not a verdict, even if both sides do it.
confine_run() {
  local side="$1" runner="$2" case_file="$3" name="$4" rc
  if "$runner" --confine "$case_file" > "$CONF/$side/$name.raw" 2> "$CONF/$side/$name.err"; then
    :
  else
    rc=$?
    printf '  SETUP FAILURE: %s exited %s for %s; stderr follows:\n' "$side" "$rc" "$name" >&2
    cat "$CONF/$side/$name.err" >&2
    return 76
  fi
  if ! grep -Eq '^(value=|error [0-9]+:[0-9]+ message=)' "$CONF/$side/$name.raw"; then
    printf '  SETUP FAILURE: %s gave no verdict for %s; stderr follows:\n' "$side" "$name" >&2
    cat "$CONF/$side/$name.err" >&2
    return 76
  fi
  if ! confine_normal < "$CONF/$side/$name.raw" > "$CONF/$side/$name.out"; then
    printf '  SETUP FAILURE: cannot normalize %s verdict for %s; stderr follows:\n' "$side" "$name" >&2
    cat "$CONF/$side/$name.err" >&2
    return 76
  fi
}

# The guards must be able to fail on every host: a run with no verdict and a crashed run are refused with 76,
# naming the case and its stderr, and an MSYS layout is refused on Windows.
guard_silent() { return 0; }
guard_crash() { printf 'crash-marker\n' >&2; return 3; }
rc=0
confine_run port guard_silent "$CONF/cases/app-read-inside.case" guard-selftest 2> "$CONF/guard.err" || rc=$?
if [ "$rc" -ne 76 ] || ! grep -q 'guard-selftest' "$CONF/guard.err"; then
  echo "  GUARD DID NOT REFUSE A RUN WITH NO VERDICT"
  exit 1
fi
rc=0
confine_run port guard_crash "$CONF/cases/app-read-inside.case" guard-selftest 2> "$CONF/guard.err" || rc=$?
if [ "$rc" -ne 76 ] || ! grep -q 'crash-marker' "$CONF/guard.err"; then
  echo "  GUARD DID NOT REFUSE A CRASHED RUN"
  exit 1
fi
rc=0
(HOST_OS=windows; native_layout_check /c/layout) 2> /dev/null || rc=$?
if [ "$rc" -ne 76 ]; then
  echo "  LAYOUT CHECK DID NOT REFUSE AN MSYS PATH"
  exit 1
fi
if ! (HOST_OS=windows; native_layout_check 'C:/layout' && native_layout_check '//server/share/layout'); then
  echo "  LAYOUT CHECK REFUSED A NATIVE WINDOWS PATH"
  exit 1
fi
echo "  guards verified: no verdict, a crash and an MSYS layout are each refused (exit 76, the case and its stderr named)"
conf_cases=0
conf_identical=0
conf_by_design=0
conf_diverged=0
echo "  case, then the hosted oracle's verdict and the port's"
for cf in "$CONF"/cases/*.case; do
  name="$(basename "$cf" .case)"
  case_native="$(native_path "$cf")"
  conf_cases=$((conf_cases + 1))
  confine_run hosted "$WORK/dump_hosted$EXE" "$case_native" "$name" || exit $?
  confine_run port "$WORK/exercise$EXE" "$case_native" "$name" || exit $?
  case "$name" in
    no-context-read|no-context-env)
      cp "$CONF/port/$name.out" "$CONF/expected/$name.out"
      if grep -q '^error .* message="cannot determine the package of this compile-time macro at ' "$CONF/port/$name.out"; then
        conf_by_design=$((conf_by_design + 1))
        verdict="by design: no context, refused"
      else
        conf_diverged=$((conf_diverged + 1))
        status=1
        verdict="PORT DOES NOT REFUSE WITHOUT A CONTEXT"
      fi
      ;;
    *)
      cp "$CONF/hosted/$name.out" "$CONF/expected/$name.out"
      if cmp -s "$CONF/hosted/$name.out" "$CONF/port/$name.out"; then
        conf_identical=$((conf_identical + 1))
        verdict="identical"
      else
        conf_diverged=$((conf_diverged + 1))
        status=1
        verdict="DIFFERS"
        diff -u "$CONF/hosted/$name.out" "$CONF/port/$name.out" | head -n 20
      fi
      ;;
  esac
  printf '  %-34s %s\n' "$name" "$verdict"
  printf '      hosted %s\n' "$(head -n 1 "$CONF/hosted/$name.out" | cut -c1-240)"
  printf '      port   %s\n' "$(head -n 1 "$CONF/port/$name.out" | cut -c1-240)"
done
echo "  Confinement parity: $conf_identical/$((conf_cases - conf_by_design)) comparable cases identical to the hosted rule; $conf_by_design by design (no context); $conf_diverged diverged of $conf_cases cases"
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

# The confinement table on a mutant: every case's port output must match the
# output the expected table holds (the hosted rule's, or the port's refusal for
# the by-design cases).
check_confinement_still_matches() {
  local cf name case_native
  if ! build_mutant_exercise; then
    invalid_mutant "macro exercise failed to build"
    return $?
  fi
  for cf in "$CONF"/cases/*.case; do
    name="$(basename "$cf" .case)"
    case_native="$(native_path "$cf")"
    "$WORK/mut-exercise$EXE" --confine "$case_native" > "$CONF/mut.raw" 2>/dev/null || return 1
    confine_normal < "$CONF/mut.raw" > "$CONF/mut.out"
    cmp -s "$CONF/mut.out" "$CONF/expected/$name.out" || return 1
  done
  return 0
}

MUTATIONS_RUN=0

# Mutate only a scratch copy of the named list. An unrelated failure is not
# evidence that either direction of the exact-list check worked.
CENSUS_PROOF_FLOOR="$WORK/macro-sites-proof.floor"
cp "$REPO/bench/macro_sites.floor" "$CENSUS_PROOF_FLOOR"
CENSUS_PROOF_NATIVE="$(native_path "$CENSUS_PROOF_FLOOR")"
check_census_list_rejects() {
  local wanted="$1" rc=0
  "$PY" "$REPO_NATIVE/bench/macro_sites.py" "$SITES_NATIVE" --check --floor "$CENSUS_PROOF_NATIVE" > "$WORK/census-list-proof.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if [ "$rc" -eq 1 ] && grep -Fq "$wanted" "$WORK/census-list-proof.log"; then return 1; fi
  invalid_mutant "the census failed for another reason"
}
if prove_mutation "census rejects an unlisted differing site" "$CENSUS_PROOF_FLOOR" \
  "differing|src/compiler/llvm/lib_llvm.iyi|#0|MacroIf|class|error location differs|The LLVM bridge raise's message agrees, but the port reports the next column." \
  "# omitted exception" \
  -- check_census_list_rejects "unexpected differing src/compiler/llvm/lib_llvm.iyi:#0"; then
  echo "    decisive: an unlisted differing site is rejected"
else
  status=1
fi
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
if prove_mutation "census rejects a stale named exception" "$CENSUS_PROOF_FLOOR" \
  '# Named exceptions: category|file|site|kind|context|case|reason' \
  '# Named exceptions: category|file|site|kind|context|case|reason
differing|bench/fixtures/nonexistent.iyi|#0|MacroIf|class|text differs|A deliberately stale exception.' \
  -- check_census_list_rejects "missing listed differing bench/fixtures/nonexistent.iyi:#0"; then
  echo "    decisive: a listed exception that no longer occurs is rejected"
else
  status=1
fi
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# With no filename the hosted parser treats .iyi syntax as Crystal and cannot
# read the concurrency runtime. Require the census to reject that failure.
check_census_filename() {
  local rc=0 dir="$WORK/mut-census-sites" dir_native
  rm -f "$WORK/mut-hosted$EXE"
  if ! LLVM_CONFIG="$HOST_LLVM_CONFIG" CRYSTAL_PATH="$REPO_NATIVE/src" "$HOSTED_COMPILER" build -Di_know_what_im_doing \
    -o "$WORK_NATIVE/mut-hosted$EXE" "$WORK_NATIVE/dump_hosted_macro.cr" > "$WORK/mut-hosted-build.log" 2>&1; then
    invalid_mutant "the filename mutant oracle did not build"
    return $?
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$SITES_DIR"/* "$dir/"
  if "$WORK/mut-hosted$EXE" --sites "$REPO_NATIVE/src/iyi/concurrency.iyi" \
    > "$dir/src__iyi__concurrency.iyi.oracle" 2> "$dir/src__iyi__concurrency.iyi.oracle.err"; then
    return 0
  else
    rc=$?
    printf 'file-error oracle exit=%s\n' "$rc" > "$dir/src__iyi__concurrency.iyi.oracle"
  fi
  dir_native="$(native_path "$dir")" || { invalid_mutant "mutant census path is unavailable"; return $?; }
  rc=0
  "$PY" "$REPO_NATIVE/bench/macro_sites.py" "$dir_native" --check > "$WORK/census-filename-proof.log" 2>&1 || rc=$?
  if [ "$rc" -eq 1 ] &&
     grep -Fq "unexpected unreadable src/iyi/concurrency.iyi:-" "$WORK/census-filename-proof.log" &&
     grep -Fq "unexpected unpaired src/iyi/concurrency.iyi:-" "$WORK/census-filename-proof.log"; then
    return 1
  fi
  invalid_mutant "the census did not reject the unreadable concurrency file"
}
if prove_mutation "hosted census parser ignores the .iyi filename" "$WORK/dump_hosted_macro.cr" \
  'parser.filename = filename if sites' \
  'parser.filename = "" if sites' \
  -- check_census_filename; then
  echo "    decisive: the census rejects the unreadable and unpaired concurrency file"
else
  status=1
fi
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The first concurrency site includes body annotations; they are not header
# annotations and must survive both scanners.
check_census_body_annotations() {
  if ! build_mutant_exercise; then
    invalid_mutant "the header-scanner mutant did not build"
    return $?
  fi
  if ! "$WORK/mut-exercise$EXE" --sites "$REPO_NATIVE/src/iyi/concurrency.iyi" > "$WORK/body-annotations.port" 2>"$WORK/body-annotations.err"; then
    invalid_mutant "the header-scanner mutant did not run"
    return $?
  fi
  awk 'NR == 1 { print; exit }' "$SITES_DIR/src__iyi__concurrency.iyi.oracle" > "$WORK/body-annotations.oracle.first"
  awk 'NR == 1 { print; exit }' "$WORK/body-annotations.port" > "$WORK/body-annotations.port.first"
  cmp -s "$WORK/body-annotations.oracle.first" "$WORK/body-annotations.port.first"
}
if prove_mutation "census strips body annotations as headers" "$REPO/bench/selfhost_macros_exercise.iyi" \
  'elsif !line.empty? && !line.starts_with?("#") && !line.starts_with?("@[")' \
  'elsif false' \
  -- check_census_body_annotations; then
  echo "    decisive: the first concurrency macro loses its body annotations"
else
  status=1
fi
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

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
  "parser.line_number = tag_loc.line_number
          parser.column_number = tag_loc.column_number" \
  "parser.line_number = open_loc.line_number
          parser.column_number = open_loc.column_number" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "hash size counts one entry too many" "$METHODS" \
  "return NumberLiteral.new(hash.entries.size.to_s, NumberKind::I32)" \
  "return NumberLiteral.new((hash.entries.size + 1).to_s, NumberKind::I32)" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "symbols print bare whatever their text" "$METHODS" \
  "plain = false" \
  "plain = true" \
  -- check_macros_still_match || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# The hosted expansion of the Unicode fixture is the oracle for codepoint size.
check_unicode_size_matches() {
  if ! build_mutant_exercise; then
    invalid_mutant "Unicode-size mutant failed to build"
    return $?
  fi
  local fixture="$REPO/bench/fixtures/macro_unicode_methods.iyi" fixture_native
  fixture_native="$(native_path "$fixture")" || { invalid_mutant "Unicode fixture path is unavailable"; return $?; }
  if ! "$WORK/dump_hosted$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/unicode-hosted.dump" 2>"$WORK/unicode-hosted.err"; then
    invalid_mutant "Unicode hosted oracle failed"
    return $?
  fi
  if ! "$WORK/mut-exercise$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/unicode-mutant.dump" 2>"$WORK/unicode-mutant.err"; then
    invalid_mutant "Unicode mutant failed to run"
    return $?
  fi
  cmp -s "$WORK/unicode-hosted.dump" "$WORK/unicode-mutant.dump"
}
if prove_mutation "StringLiteral#size counts bytes instead of characters" "$METHODS" \
  'return NumberLiteral.new(str.value.size.to_s, NumberKind::I32)' \
  'return NumberLiteral.new(str.value.bytesize.to_s, NumberKind::I32)' \
  -- check_unicode_size_matches; then
  echo "    decisive: Unicode fixture differs from the hosted expansion when size counts bytes"
else
  status=1
fi
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
# Both sites are evaluated independently, so one refusal cannot hide the other.
# Require the mutant to differ only in the two call-name locations.
check_inline_index_locations() {
  if ! build_mutant_exercise; then
    invalid_mutant "inline-index mutant failed to build"
    return $?
  fi
  local fixture="$REPO/bench/fixtures/macro_inline_numeric_index.iyi" fixture_native
  fixture_native="$(native_path "$fixture")" || { invalid_mutant "inline-index fixture path is unavailable"; return $?; }
  if ! "$WORK/dump_hosted$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/index-hosted.dump" 2>"$WORK/index-hosted.err"; then
    invalid_mutant "inline-index hosted oracle failed"
    return $?
  fi
  if ! "$WORK/mut-exercise$EXE" $(fixture_args "$fixture") "$fixture_native" > "$WORK/index-mutant.dump" 2>"$WORK/index-mutant.err"; then
    invalid_mutant "inline-index mutant failed to run"
    return $?
  fi
  if ! awk '/^site 0 / && / error 2:13 message=/ { unicode = 1 }
            /^site 1 / && / error 3:13 message=/ { ascii = 1 }
            END { exit !(unicode && ascii) }' "$WORK/index-hosted.dump"; then
    invalid_mutant "hosted inline-index errors did not have the expected locations"
    return $?
  fi
  if cmp -s "$WORK/index-hosted.dump" "$WORK/index-mutant.dump"; then return 0; fi
  if ! awk '/^site 0 / && / error 2:6 message=/ {
              unicode = 1; sub(/ error 2:6 message=/, " error 2:13 message=")
            }
            /^site 1 / && / error 3:6 message=/ {
              ascii = 1; sub(/ error 3:6 message=/, " error 3:13 message=")
            }
            { print }
            END { exit !(unicode && ascii) }' "$WORK/index-mutant.dump" > "$WORK/index-normalized.dump"; then
    invalid_mutant "inline-index mutant did not move both errors to the receiver"
    return $?
  fi
  if ! cmp -s "$WORK/index-hosted.dump" "$WORK/index-normalized.dump"; then
    invalid_mutant "inline-index mutant changed more than the call locations"
    return $?
  fi
  return 1
}
if prove_mutation "inline indexing loses its call-name location" "$SYNTAX_PARSER" \
  '        res = Call.new(res, method_name, args, nil, nil, named_args).at(location)
        res.name_location = name_location
        res.args_in_brackets = true' \
  '        res = Call.new(res, method_name, args, nil, nil, named_args).at(location)
        res.args_in_brackets = true' \
  -- check_inline_index_locations; then
  echo "    decisive: Unicode and ASCII inline indexing report the receiver, not the hosted call location"
else
  status=1
fi
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

prove_mutation "a missing context reads from an empty package" "$INTERP" \
  "    if conf = @confinement" \
  "    if conf = @confinement || MacroConfinement.new(\"\", [] of String, \"\")" \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a macro outside every package reads from no package" "$CONFINEMENT" \
  'best = MacroConfinement.standalone_root(real_source.path) if best.empty?' \
  'best = "" if best.empty?' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "the ancestor walk stops at the first directory" "$CONFINEMENT" \
  'return false if parent == cur' \
  'return false' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "library roots are not consulted for a library read" "$CONFINEMENT" \
  '    if library' \
  '    if false' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "the standard library roots are not found" "$CONFINEMENT" \
  'roots << File.real_path(dir) if Dir.exists?(dir)' \
  'roots << File.real_path(dir) if false' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

# These two need the links of section 2c, so they run where the shell made them.
if [ "$CONF_LINKS" = yes ]; then
  prove_mutation "a link that leads nowhere is not refused" "$CONFINEMENT" \
    'if File.symlink?(full)' \
    'if false' \
    -- check_confinement_still_matches || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

  if [ "$HOST_OS" = windows ]; then
    host_limited "skipped mutation 'a dotdot after a link is applied before the link': it changes the POSIX-only path resolver"
  else
    prove_mutation "a dotdot after a link is applied before the link" "$CONFINEMENT" \
      'full = Path.new(path).absolute? ? path : File.join(@base_dir, path)' \
      'full = File.expand_path(path, @base_dir)' \
      -- check_confinement_still_matches || status=1
    MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  fi
else
  host_limited "skipped: no symlinks on this runner: the proofs 'a link that leads nowhere is not refused' and 'a dotdot after a link is applied before the link' need the link cases"
fi

if [ "$HOST_OS" = windows ]; then
  prove_mutation "relative paths ignore the base directory" "$CONFINEMENT" \
    'full = File.expand_path(path, @base_dir)' \
    'full = File.expand_path(path)' \
    -- check_confinement_still_matches || status=1
else
  prove_mutation "relative paths ignore the base directory" "$CONFINEMENT" \
    'File.join(@base_dir, path)' \
    'path' \
    -- check_confinement_still_matches || status=1
fi
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "env is allowed from any package" "$CONFINEMENT" \
  'MacroConfinement.same_file?(root, @compiling_root)' \
  'true' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "env is not checked against the compiling package" "$INTERP" \
  'return Nop.new unless env_allowed(node)' \
  'return Nop.new if false' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "system and backtick refusal sentence altered" "$INTERP" \
  'compile-time shell commands are forbidden' \
  'compile-time shell commands are refused' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "system and backtick are not refused" "$INTERP" \
  'refuse_shell(node, name)' \
  'nil' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "file_exists? does not check the path" "$INTERP" \
  'resolved = confined_path(node, name, path, true)' \
  'resolved = path' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

if [ "$HOST_OS" = windows ]; then
  prove_mutation "a directory is not refused by read_file" "$INTERP" \
    'if name == "read_file?"
            return NilLiteral.new
          end' \
    'if name == "read_file?" || File.directory?(resolved)
            return NilLiteral.new
          end' \
    -- check_confinement_still_matches || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  if prove_mutation "Win32 file errors discard the system message" "$INTERP" \
    'win32_error_text(opened.code)' \
    '"wrong system error"' \
    -- check_confinement_still_matches; then
    echo "    decisive: Windows confinement errors differ without the operating system's message"
  else
    status=1
  fi
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
else
  prove_mutation "a directory is not refused by read_file" "$INTERP" \
    'if File.directory?(resolved)' \
    'if false' \
    -- check_confinement_still_matches || status=1
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  host_limited "Win32 system-message mutation runs on Windows"
fi

prove_mutation "a macro's file is not taken from its definition" "$ENGINE" \
  'loc.filename' \
  '""' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "a parsed fixture macro carries no definition file" "$PARSER" \
  'a_macro.location = Location.new(file, 1, 1) unless file.empty?' \
  'a_macro.location = nil' \
  -- check_confinement_still_matches || status=1
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "ALL SELFHOST MACRO EXPANSION CHECKS PASSED"
else
  echo "SELFHOST MACRO EXPANSION CHECKS FAILED"
fi
exit $status
