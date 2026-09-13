#!/usr/bin/env bash
# Fails when the iyi macro engine stops agreeing with the one it replaces.
#
# Every fixture is expanded twice, once by each implementation, dumped in one
# text form, and required byte-identical.
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
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
INTERP="$REPO/src/compiler/macros/interpreter.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the macro engine exercise"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_macros_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
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
  "ALL SELFHOST MACRO CHECKS PASSED SUCCESSFULLY!"; do
  if ! grep -qF "$phrase" "$WORK/plain.out"; then
    echo "  MISSING REPORTED CHECK: '$phrase'"
    status=1
  else
    echo "  verified report: '$phrase'"
  fi
done

echo
echo "== 2. Macro expansion AST comparison against the front end being replaced"
cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_macro.cr"
require "compiler/requires"

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

def dump_ast(node : Iyi::ASTNode?, indent : Int32 = 0) : String
  return ("  " * indent) + "nil\n" if node.nil?
  p = "  " * indent
  case node
  when Iyi::Expressions
    kw = case node.keyword
         when .none? then "none"
         when .paren? then "paren"
         when .begin? then "begin"
         else "none"
         end
    s = "#{p}Expressions keyword=#{kw}\n"
    node.expressions.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::Nop
    "#{p}Nop\n"
  when Iyi::NilLiteral
    "#{p}NilLiteral\n"
  when Iyi::BoolLiteral
    "#{p}BoolLiteral value=#{node.value}\n"
  when Iyi::NumberLiteral
    "#{p}NumberLiteral value=\"#{node.value}\" kind=#{node.kind.to_s.downcase}\n"
  when Iyi::CharLiteral
    "#{p}CharLiteral value=#{node.value.ord}\n"
  when Iyi::StringLiteral
    "#{p}StringLiteral value=#{escape_s(node.value)}\n"
  when Iyi::StringInterpolation
    s = "#{p}StringInterpolation\n"
    node.expressions.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::SymbolLiteral
    "#{p}SymbolLiteral value=#{escape_s(node.value)}\n"
  when Iyi::Var
    "#{p}Var name=#{escape_s(node.name)}\n"
  when Iyi::InstanceVar
    "#{p}InstanceVar name=#{escape_s(node.name)}\n"
  when Iyi::ClassVar
    "#{p}ClassVar name=#{escape_s(node.name)}\n"
  when Iyi::Global
    "#{p}Global name=#{escape_s(node.name)}\n"
  when Iyi::Path
    "#{p}Path names=#{node.names.join("::")} global=#{node.global?}\n"
  when Iyi::ArrayLiteral
    s = "#{p}ArrayLiteral\n"
    node.elements.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::HashLiteral
    s = "#{p}HashLiteral\n"
    node.entries.each do |entry|
      s += "#{p}  entry:\n"
      s += "#{p}    key:\n" + dump_ast(entry.key, indent + 3)
      s += "#{p}    value:\n" + dump_ast(entry.value, indent + 3)
    end
    s
  when Iyi::TupleLiteral
    s = "#{p}TupleLiteral\n"
    node.elements.each { |e| s += dump_ast(e, indent + 1) }
    s
  when Iyi::NamedTupleLiteral
    s = "#{p}NamedTupleLiteral\n"
    node.entries.each do |entry|
      s += "#{p}  entry key=#{escape_s(entry.key)}:\n" + dump_ast(entry.value, indent + 2)
    end
    s
  when Iyi::RangeLiteral
    s = "#{p}RangeLiteral exclusive=#{node.exclusive?}\n"
    s += "#{p}  from:\n" + dump_ast(node.from, indent + 2)
    s += "#{p}  to:\n" + dump_ast(node.to, indent + 2)
    s
  when Iyi::Call
    s = "#{p}Call name=#{escape_s(node.name)}\n"
    if obj = node.obj
      s += "#{p}  obj:\n" + dump_ast(obj, indent + 2)
    end
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
    if named_args = node.named_args
      s += "#{p}  named_args:\n"
      named_args.each { |na| s += dump_ast(na, indent + 2) }
    end
    if block_arg = node.block_arg
      s += "#{p}  block_arg:\n" + dump_ast(block_arg, indent + 2)
    end
    if block = node.block
      s += "#{p}  block:\n" + dump_ast(block, indent + 2)
    end
    s
  when Iyi::NamedArgument
    s = "#{p}NamedArgument name=#{escape_s(node.name)}:\n"
    s += dump_ast(node.value, indent + 1)
    s
  when Iyi::Block
    arg_names = node.args.map(&.name).join(", ")
    splat = node.splat_index ? node.splat_index.to_s : "none"
    s = "#{p}Block args=[#{arg_names}] splat=#{splat}:\n"
    s += dump_ast(node.body, indent + 1)
    s
  when Iyi::Assign
    s = "#{p}Assign\n"
    s += "#{p}  target:\n" + dump_ast(node.target, indent + 2)
    s += "#{p}  value:\n" + dump_ast(node.value, indent + 2)
    s
  when Iyi::If
    s = "#{p}If ternary=#{node.ternary?}\n"
    s += "#{p}  cond:\n" + dump_ast(node.cond, indent + 2)
    s += "#{p}  then:\n" + dump_ast(node.then, indent + 2)
    s += "#{p}  else:\n" + dump_ast(node.else, indent + 2)
    s
  when Iyi::Def
    receiver_s = node.receiver ? " receiver" : ""
    abstract_s = node.abstract? ? " abstract=true" : ""
    splat_s = node.splat_index ? " splat=#{node.splat_index}" : ""
    s = "#{p}Def name=#{escape_s(node.name)}#{receiver_s}#{abstract_s}#{splat_s}\n"
    if r = node.receiver
      s += "#{p}  receiver:\n" + dump_ast(r, indent + 2)
    end
    if !node.args.empty?
      s += "#{p}  args:\n"
      node.args.each { |a| s += dump_ast(a, indent + 2) }
    end
    if ds = node.double_splat
      s += "#{p}  double_splat:\n" + dump_ast(ds, indent + 2)
    end
    if ba = node.block_arg
      s += "#{p}  block_arg:\n" + dump_ast(ba, indent + 2)
    end
    if rt = node.return_type
      s += "#{p}  return_type:\n" + dump_ast(rt, indent + 2)
    end
    if fv = node.free_vars
      s += "#{p}  free_vars=[#{fv.join(", ")}]\n"
    end
    s += "#{p}  body:\n" + dump_ast(node.body, indent + 2)
    s
  when Iyi::Arg
    ext_s = (ext = node.external_name) && ext != node.name ? " external_name=#{escape_s(ext)}" : ""
    s = "#{p}Arg name=#{escape_s(node.name)}#{ext_s}\n"
    if rest = node.restriction
      s += "#{p}  restriction:\n" + dump_ast(rest, indent + 2)
    end
    if def_val = node.default_value
      s += "#{p}  default_value:\n" + dump_ast(def_val, indent + 2)
    end
    s
  else
    "#{p}#{node.class}\n"
  end
end

class NodeCounter < Iyi::Visitor
  getter count = 0
  def visit(node : Iyi::ASTNode)
    @count += 1
    true
  end
end

filename = ARGV[0]
src = File.read(filename)

parser = Iyi::Parser.new(src)
node = parser.parse

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
expanded_str, pragmas = program.expand_macro(the_macro.not_nil!, the_call.not_nil!, program, program)
expanded_ast = program.parse_macro_source(expanded_str, pragmas, the_macro.not_nil!, the_call.not_nil!, Set(String).new)

if ARGV.size > 1 && ARGV[1] == "--count"
  c = NodeCounter.new
  expanded_ast.accept(c)
  puts c.count
else
  print dump_ast(expanded_ast)
end
CRYSTAL_GOLDEN_SCRIPT

LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal" "$WORK/dump_crystal_macro.cr"
if [ ! -x "$WORK/dump_crystal" ]; then
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  exit 1
fi

compare_all() {
  runner="$1"
  out_status=0
  for fixture in "$REPO"/bench/fixtures/macro_*.iyi; do
    "$runner" "$fixture" > "$WORK/a.ast" 2>/dev/null || { out_status=1; continue; }
    "$WORK/dump_crystal" "$fixture" > "$WORK/b.ast"
    cmp -s "$WORK/a.ast" "$WORK/b.ast" || out_status=1
  done
  return $out_status
}

fixture_count=0
total_matched_nodes=0
for fixture in "$REPO"/bench/fixtures/macro_*.iyi; do
  fixture_name="bench/fixtures/$(basename "$fixture")"
  "$WORK/exercise" "$fixture" > "$WORK/iyi.ast"
  "$WORK/dump_crystal" "$fixture" > "$WORK/crystal.ast"
  if ! cmp -s "$WORK/iyi.ast" "$WORK/crystal.ast"; then
    echo "  $fixture_name: EXPANDED TREES DIFFER"
    diverged=$((diverged + 1))
    diff -u "$WORK/crystal.ast" "$WORK/iyi.ast" | head -20
    status=1
  else
    nodes_count=$("$WORK/dump_crystal" "$fixture" --count)
    echo "  $fixture_name: identical ($nodes_count expanded nodes match the front end)"
    total_matched_nodes=$((total_matched_nodes + nodes_count))
  fi
  fixture_count=$((fixture_count + 1))
done
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count fixtures expand identically ($total_matched_nodes total nodes)"

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

prove_mutation() {
  label="$1"
  old="$2"
  new="$3"
  echo "  [$label]"
  cp "$INTERP" "$INTERP.orig"
  python3 - "$INTERP" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$INTERP.orig" "$INTERP" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$INTERP.orig" "$INTERP"; rm -f "$INTERP.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_macros_exercise.iyi" >/dev/null 2>&1; then
    if compare_all "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the expanded AST outputs diverged, as they must"
    fi
  else
    echo "    caught: the mutated macro engine did not build"
  fi
  cp "$INTERP.orig" "$INTERP"; rm -f "$INTERP.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0

prove_mutation "macro if condition truthiness inverted" \
  "c = evaluate(mi.cond)
      if MacroMethods.truthy?(c)" \
  "c = evaluate(mi.cond)
      if !MacroMethods.truthy?(c)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "splat argument gathering emits empty tuple" \
  "@vars[macro_arg.name] = TupleLiteral.new(splat_elems)" \
  "@vars[macro_arg.name] = TupleLiteral.new([] of ASTNode)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "macro expression output stringification suppressed" \
  "val.to_s(@str)" \
  "# val.to_s(@str)"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "for loop element binding corrupts loop variable" \
  "@vars[var1.name] = elems[i]" \
  "@vars[var1.name] = NilLiteral.new"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

prove_mutation "fresh variable temp name prefix altered" \
  "temp_name = new_temp_var_name(\"__temp_\")" \
  "temp_name = new_temp_var_name(\"__mut_\")"
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST MACRO CHECKS PASSED"
else
  echo "== SELFHOST MACRO CHECKS FAILED"
fi
exit $status
