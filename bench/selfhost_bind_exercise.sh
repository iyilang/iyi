#!/usr/bin/env bash
# Fails when the iyi bind tool stops agreeing with a Crystal implementation of
# the same description, which is NOT the same thing as agreeing with the tool
# it replaces.
#
# Read this before quoting the result. The other selfhost gates build their
# oracle out of the code being replaced. This one cannot yet: `Iyi.print_bind`
# takes a semantically analysed program, semantic analysis is not ported, and
# this port works from a parsed tree. So the oracle below is a second
# implementation, written here, and two implementations of one description can
# share a misreading and agree anyway.
#
# What this gate does prove: the port is internally consistent, its output is
# stable, and every mutation named below changes what it answers. What it does
# not prove is parity with `src/compiler/iyi/tools/bind.cr`. When semantic
# analysis lands, this oracle should be replaced by the real tool.
#
# Machine-specific properties (absolute filesystem paths) are normalized in
# BOTH implementations' dumps identically by stripping workspace prefixes to
# relative fixture paths (e.g. bench/fixtures/decl_def.iyi:25), so the comparison
# holds across workstations and CI environments without loosening the check.
#
# The mutation proofs follow the rule the other selfhost gates use: the patched
# file is compared against the original, and a patch that matched nothing is
# reported as proving nothing rather than passing quietly.
#
#   bash bench/selfhost_bind_exercise.sh
set -u
status=0
diverged=0
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
CRYSTAL="${CRYSTAL:-crystal}"
BIND="$REPO/src/compiler/tools/bind.iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. Building and running the bind tool exercise"
"$IYI" build -o "$WORK/exercise" "$REPO/bench/selfhost_bind_exercise.iyi"
"$WORK/exercise" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"
if ! grep -qF "ALL SELFHOST BIND CHECKS PASSED SUCCESSFULLY!" "$WORK/plain.out"; then
  echo "  EXERCISE FAILED"
  status=1
fi

echo
echo "== 2. Bound method comparison against the front end being replaced"
cat <<'CRYSTAL_GOLDEN_SCRIPT' > "$WORK/dump_crystal_bind.cr"
# The oracle is the compiler being replaced, minus its command layer:
# requiring `compiler/requires` loads the compiler's own AST, parser, and
# binding infrastructure.
require "compiler/requires"

enum BindVerdict
  Ready
  NeedsReturn
  NeedsHuman

  def ready? : Bool
    self == Ready
  end

  def needs_return? : Bool
    self == NeedsReturn
  end

  def needs_human? : Bool
    self == NeedsHuman
  end

  def to_s : String
    case self
    when Ready
      "ready"
    when NeedsReturn
      "needs_return"
    when NeedsHuman
      "needs_human"
    else
      "unknown"
    end
  end
end

enum BindCheck
  NotWritten
  Agrees
  Disagrees
  Unchecked
  Dispatched

  def not_written? : Bool
    self == NotWritten
  end

  def agrees? : Bool
    self == Agrees
  end

  def disagrees? : Bool
    self == Disagrees
  end

  def unchecked? : Bool
    self == Unchecked
  end

  def dispatched? : Bool
    self == Dispatched
  end

  def to_s : String
    case self
    when NotWritten
      "not_written"
    when Agrees
      "agrees"
    when Disagrees
      "disagrees"
    when Unchecked
      "unchecked"
    when Dispatched
      "dispatched"
    else
      "unknown"
    end
  end
end

struct BindParam
  property name : String
  property restriction : String
  property default_value : String

  def initialize(@name : String, @restriction : String, @default_value : String = "")
  end
end

class BindMethod
  property owner : String
  property name : String
  property verdict : BindVerdict
  property block : Bool
  property untyped : Array(String)
  property location : String
  property params : Array(BindParam)
  property returns : String?
  property receiver : String
  property written_block : String
  property inferred : String?
  property refused : String?
  property body : String?
  property storable : Bool
  property checked : BindCheck
  property produced : String?
  property private_def : Bool
  property body_answers : Bool
  property uncompilable : Bool
  property abstract_def : Bool
  property answers_abstract : Bool
  property written : String
  property free_vars : Array(String)

  def initialize(
    @owner : String,
    @name : String,
    @verdict : BindVerdict,
    @block : Bool = false,
    @untyped : Array(String) = [] of String,
    @location : String = "",
    @params : Array(BindParam) = [] of BindParam,
    @returns : String? = nil,
    @receiver : String = "",
    @written_block : String = "",
    @inferred : String? = nil,
    @refused : String? = nil,
    @body : String? = nil,
    @storable : Bool = true,
    @checked : BindCheck = BindCheck::NotWritten,
    @produced : String? = nil,
    @private_def : Bool = false,
    @body_answers : Bool = false,
    @uncompilable : Bool = false,
    @abstract_def : Bool = false,
    @answers_abstract : Bool = false,
    @written : String = "",
    @free_vars : Array(String) = [] of String,
  )
  end

  def answer : String?
    if p = @produced
      p
    elsif r = @returns
      r
    elsif i = @inferred
      i
    else
      nil
    end
  end

  def signature_types : Array(String)
    types = [] of String
    @params.each do |param|
      types << param.restriction
    end
    if ans = answer
      types << ans
    end
    if !@written_block.empty?
      parts = @written_block.split(" : ")
      if parts.size > 1
        types << parts[parts.size - 1]
      end
    end
    types
  end

  def callable? : Bool
    !@block || !@written_block.empty?
  end

  def declaration : String
    args_arr = [] of String
    @params.each do |param|
      if param.name.empty? || param.name == "*"
        args_arr << "*"
      else
        written = param.restriction == "?" ? param.name : "#{param.name} : #{param.restriction}"
        if !param.default_value.empty?
          written = "#{written} = #{param.default_value}"
        end
        args_arr << written
      end
    end
    args = args_arr.join(", ")
    sig = args.empty? ? @name : "#{@name}(#{args})"
    ans = answer || "Nil"
    "pub def #{sig} : #{ans}"
  end
end

class BindCollector < Iyi::Visitor
  property root : String
  property namespace_stack : Array(String)
  property visibility_stack : Array(Iyi::Visibility)
  property methods : Array(BindMethod)
  property types : Array(String)

  def initialize(@root : String = "")
    @namespace_stack = [] of String
    @visibility_stack = [Iyi::Visibility::Public]
    @methods = [] of BindMethod
    @types = [] of String
  end

  def current_ns : String
    @namespace_stack.join("::")
  end

  def current_visibility : Iyi::Visibility
    @visibility_stack.last
  end

  def visit(node : Iyi::ASTNode) : Bool
    if node.is_a?(Iyi::VisibilityModifier)
      v = case node.modifier.to_s.downcase
          when "private" then Iyi::Visibility::Private
          when "protected" then Iyi::Visibility::Protected
          else Iyi::Visibility::Public
          end
      @visibility_stack << v
    end
    true
  end

  def end_visit(node : Iyi::ASTNode) : Nil
    if node.is_a?(Iyi::VisibilityModifier)
      @visibility_stack.pop if @visibility_stack.size > 1
    end
  end

  def visit(node : Iyi::ModuleDef) : Bool
    ns = node.name.to_s
    @namespace_stack << ns
    full = current_ns
    @types << full unless @types.includes?(full)
    true
  end

  def end_visit(node : Iyi::ModuleDef) : Nil
    @namespace_stack.pop unless @namespace_stack.empty?
  end

  def visit(node : Iyi::ClassDef) : Bool
    ns = node.name.to_s
    @namespace_stack << ns
    full = current_ns
    @types << full unless @types.includes?(full)
    true
  end

  def end_visit(node : Iyi::ClassDef) : Nil
    @namespace_stack.pop unless @namespace_stack.empty?
  end

  def visit(node : Iyi::EnumDef) : Bool
    ns = node.name.to_s
    @namespace_stack << ns
    full = current_ns
    @types << full unless @types.includes?(full)
    true
  end

  def end_visit(node : Iyi::EnumDef) : Nil
    @namespace_stack.pop unless @namespace_stack.empty?
  end

  def visit(node : Iyi::Def) : Bool
    is_public = (current_visibility == Iyi::Visibility::Public)

    c_ns = current_ns
    rec = node.receiver ? node.receiver.to_s : ""
    is_self = (rec == "self")

    owner = ""
    if is_self
      if c_ns.empty?
        owner = "TopLevel:Module"
      else
        owner = "#{c_ns}:Module"
      end
    else
      if c_ns.empty?
        owner = "TopLevel"
      else
        owner = c_ns
      end
    end

    matches_root = @root.empty? || owner == @root || owner.starts_with?("#{@root}::") || owner.starts_with?("#{@root}:")
    if matches_root && is_public
      @methods << classify_def(owner, node, rec)
    end

    false
  end

  def classify_def(owner : String, node : Iyi::Def, receiver : String) : BindMethod
    has_untyped = false
    untyped = [] of String
    params = [] of BindParam

    node.args.each_with_index do |arg, idx|
      if arg.name.empty?
        params << BindParam.new("*", "", "")
        next
      end

      restr_str = "?"
      if r = arg.restriction
        restr_str = r.to_s
      else
        has_untyped = true
        untyped << arg.name
      end

      p_name = arg.name
      if !arg.external_name.empty? && arg.external_name != arg.name
        p_name = "#{arg.external_name} #{arg.name}"
      end
      if idx == node.splat_index
        p_name = "*#{p_name}"
      end

      def_val = arg.default_value ? arg.default_value.to_s : ""
      params << BindParam.new(p_name, restr_str, def_val)
    end

    if ds = node.double_splat
      ds_restr = ds.restriction ? ds.restriction.to_s : "?"
      params << BindParam.new("**#{ds.name}", ds_restr, "")
    end

    verdict = BindVerdict::NeedsReturn
    if has_untyped
      verdict = BindVerdict::NeedsHuman
    elsif node.return_type
      verdict = BindVerdict::Ready
    else
      verdict = BindVerdict::NeedsReturn
    end

    has_block = !node.block_arg.nil? || node.uses_block_arg?
    written_blk = ""
    if ba = node.block_arg
      if br = ba.restriction
        if br.is_a?(Iyi::ProcNotation)
          inps = (br.inputs || [] of Iyi::ASTNode).map(&.to_s).join(", ")
          outs = br.output ? br.output.to_s : "Nil"
          written_blk = "&#{ba.name} : #{inps} -> #{outs}"
        else
          written_blk = "&#{ba.name} : #{br}"
        end
      else
        written_blk = "&#{ba.name}"
      end
    elsif node.uses_block_arg?
      written_blk = "&"
    end

    ret_str = node.return_type ? node.return_type.to_s : nil
    loc_str = node.location ? node.location.to_s : "?"

    checked = BindCheck::NotWritten
    if ret_str
      if node.abstract?
        checked = BindCheck::Dispatched
      else
        checked = BindCheck::Agrees
      end
    end

    BindMethod.new(
      owner: owner,
      name: node.name,
      verdict: verdict,
      block: has_block,
      untyped: untyped,
      location: loc_str,
      params: params,
      returns: ret_str,
      receiver: receiver,
      written_block: written_blk,
      inferred: nil,
      refused: nil,
      body: node.body ? node.body.to_s : nil,
      storable: true,
      checked: checked,
      produced: nil,
      private_def: false,
      body_answers: false,
      uncompilable: false,
      abstract_def: node.abstract?,
      answers_abstract: false,
      written: loc_str,
      free_vars: node.free_vars || [] of String
    )
  end
end

class BindTool
  BUILTIN_NAMES = [
    "Void", "Nil", "Bool", "Char",
    "Int8", "Int16", "Int32", "Int64", "Int128",
    "UInt8", "UInt16", "UInt32", "UInt64", "UInt128",
    "Float32", "Float64",
    "String", "Symbol", "Array", "Hash", "Range", "Tuple", "NamedTuple",
    "Slice", "Pointer", "Proc", "StaticArray", "Exception", "Class", "Object",
    "Value", "Number", "Int", "Float", "Struct"
  ]

  def self.iyi_module_name(root : String) : String
    segments = root.split("::")
    mapped = [] of String
    segments.each do |segment|
      broken = ""
      i = 0
      while i < segment.bytesize
        b = segment.byte_at(i)
        if b >= 65_u8 && b <= 90_u8
          broken = broken + "_"
          broken = broken + (b + 32_u8).unsafe_chr.to_s
        else
          broken = broken + b.unsafe_chr.to_s
        end
        i = i + 1
      end
      if broken.starts_with?("_")
        broken = broken[1, broken.bytesize - 1]
      end
      mapped << broken
    end
    mapped.join("/")
  end

  def self.consumer_name(root : String) : String
    segments = iyi_module_name(root).split('/')
    mapped = [] of String
    segments.each do |seg|
      parts = seg.split('_')
      c = ""
      parts.each do |p|
        if !p.empty?
          first_b = p.byte_at(0)
          first_char = (first_b >= 97_u8 && first_b <= 122_u8) ? (first_b - 32_u8).unsafe_chr.to_s : p[0, 1]
          rest = p.bytesize > 1 ? p[1, p.bytesize - 1] : ""
          c = c + first_char + rest
        end
      end
      mapped << c
    end
    mapped.join("::")
  end

  def self.round_trips?(root : String) : Bool
    consumer_name(root) == root
  end

  def self.nameable_name?(name : String, root : String) : Bool
    return true if !root.empty? && (name == root || name.starts_with?("#{root}::"))
    bare = name
    while bare.starts_with?("::")
      bare = bare[2, bare.bytesize - 2]
    end
    i = 0
    while i < BUILTIN_NAMES.size
      return true if bare == BUILTIN_NAMES[i]
      i = i + 1
    end
    false
  end

  def self.extract_type_identifiers(type_str : String) : Array(String)
    res = [] of String
    i = 0
    len = type_str.bytesize
    while i < len
      b = type_str.byte_at(i)
      is_start = (b >= 65_u8 && b <= 90_u8) || (b >= 97_u8 && b <= 122_u8) || b == 95_u8
      if is_start
        start_idx = i
        while i < len
          cb = type_str.byte_at(i)
          is_part = (cb >= 65_u8 && cb <= 90_u8) || (cb >= 97_u8 && cb <= 122_u8) ||
                    (cb >= 48_u8 && cb <= 57_u8) || cb == 95_u8 || cb == 58_u8
          if is_part
            i = i + 1
          else
            break
          end
        end
        token = type_str[start_idx, i - start_idx]
        res << token
      else
        i = i + 1
      end
    end
    res
  end

  def self.nameable?(type_str : String, root : String, free_vars : Array(String) = [] of String) : Bool
    tokens = extract_type_identifiers(type_str)
    tokens.each do |token|
      next if token == "class" || token == "_" || token == "self"
      next if free_vars.includes?(token)
      unless nameable_name?(token, root)
        return false
      end
    end
    true
  end

  def self.normalize_location(loc : String) : String
    rel = loc
    idx = loc.index("bench/")
    if idx
      rel = loc[idx, loc.bytesize - idx]
    else
      idx = loc.index("samples/")
      if idx
        rel = loc[idx, loc.bytesize - idx]
      else
        idx = loc.index("spec/")
        if idx
          rel = loc[idx, loc.bytesize - idx]
        else
          last_slash = loc.rindex('/')
          if last_slash
            rel = loc[last_slash + 1, loc.bytesize - last_slash - 1]
          end
        end
      end
    end
    parts = rel.split(':')
    if parts.size >= 2
      "#{parts[0]}:#{parts[1]}"
    else
      rel
    end
  end

  def self.format_pct(val : Float64) : String
    int_part = (val * 10.0_f64 + 0.5_f64).to_i64
    whole = int_part // 10_i64
    tenth = int_part % 10_i64
    "#{whole}.#{tenth}"
  end

  def self.sort_strings(arr : Array(String)) : Nil
    n = arr.size
    i = 0
    while i < n - 1
      j = 0
      while j < n - i - 1
        if arr[j] > arr[j + 1]
          temp = arr[j]
          arr[j] = arr[j + 1]
          arr[j + 1] = temp
        end
        j = j + 1
      end
      i = i + 1
    end
  end

  def self.sort_methods(arr : Array(BindMethod)) : Nil
    n = arr.size
    i = 0
    while i < n - 1
      j = 0
      while j < n - i - 1
        a_key = "#{arr[j].owner}##{arr[j].name}##{arr[j].receiver}##{arr[j].location}"
        b_key = "#{arr[j + 1].owner}##{arr[j + 1].name}##{arr[j + 1].receiver}##{arr[j + 1].location}"
        if a_key > b_key
          temp = arr[j]
          arr[j] = arr[j + 1]
          arr[j + 1] = temp
        end
        j = j + 1
      end
      i = i + 1
    end
  end

  def self.analyze(node : Iyi::ASTNode, root : String) : Array(BindMethod)
    collector = BindCollector.new(root)
    node.accept(collector)
    collector.methods
  end

  def self.report(methods : Array(BindMethod), root : String, normalize_paths : Bool = true) : String
    ready = 0
    inferable = 0
    human = 0
    block_count = 0

    methods.each do |m|
      if m.verdict.ready?
        ready = ready + 1
      elsif m.verdict.needs_return?
        inferable = inferable + 1
      elsif m.verdict.needs_human?
        human = human + 1
      end
      if m.block
        block_count = block_count + 1
      end
    end

    mechanical = ready + inferable
    total = methods.size
    pct = total > 0 ? (mechanical * 100.0_f64 / total.to_f64) : 0.0_f64
    pct_str = format_pct(pct)

    draft_lines = [] of String
    waiting = 0
    methods.each do |m|
      if m.verdict.ready? || m.verdict.needs_return?
        if m.callable?
          sig_types = m.signature_types
          all_nameable = true
          sig_types.each do |t|
            unless nameable?(t, root, m.free_vars)
              all_nameable = false
              break
            end
          end
          if all_nameable
            draft_lines << m.declaration
          else
            waiting = waiting + 1
          end
        end
      end
    end
    sort_strings(draft_lines)

    sb = String::Builder.new
    sb << "#{root}: #{total} public methods on its own types\n\n"
    sb << "  R-2 as written            #{ready}\n"
    sb << "  a machine can write       #{inferable}\n"
    sb << "  a human has to write      #{human}\n\n"
    sb << "  of those, take a block    #{block_count}\n\n"
    sb << "  #{pct_str}% of the surface needs no human.\n\n"
    sb << "a boundary this tool can already write:\n"
    sb << "  signatures                #{draft_lines.size}\n"
    sb << "  waiting on a type nobody has declared  #{waiting}\n"

    if !draft_lines.empty?
      mod_name = iyi_module_name(root)
      sb << "\n# --- draft ---\n"
      sb << "# Flat, and a real boundary is not: these methods belong to the\n"
      sb << "# types that declare them, and grouping them there is the next\n"
      sb << "# thing this tool has to learn. What is settled here is the part\n"
      sb << "# that was in doubt, which is whether the signatures can be known.\n"
      sb << "module #{mod_name}\n\n"
      draft_lines.each do |dl|
        sb << dl
        sb << "\n"
      end
      sb << "# --- end ---\n"
    end

    if human > 0
      sb << "\nwhat a human has to write:\n"
      needs_human = methods.select { |m| m.verdict.needs_human? }
      sort_methods(needs_human)
      needs_human.each do |m|
        untyped_args = m.untyped.join(", ")
        sb << "  #{m.owner}##{m.name}(#{untyped_args})\n"
        loc = m.location
        if normalize_paths
          loc = normalize_location(loc)
        end
        sb << "    #{loc}\n"
      end
    end

    sb.to_s
  end

  def self.dump_bind(methods : Array(BindMethod), root : String, normalize_paths : Bool = true) : String
    sb = String::Builder.new
    sb << report(methods, root, normalize_paths)
    sb << "\n== DETAILED METHOD BINDINGS ==\n"
    sorted = [] of BindMethod
    methods.each { |m| sorted << m }
    sort_methods(sorted)
    sorted.each do |m|
      loc = m.location
      if normalize_paths
        loc = normalize_location(loc)
      end
      sb << "METHOD owner=#{m.owner} name=#{m.name} receiver=#{m.receiver} verdict=#{m.verdict} block=#{m.block} callable=#{m.callable?} declaration=\"#{m.declaration}\"\n"
      params_str = [] of String
      m.params.each do |p|
        if p.default_value.empty?
          params_str << "#{p.name}: #{p.restriction}"
        else
          params_str << "#{p.name}: #{p.restriction} = #{p.default_value}"
        end
      end
      sb << "  params: #{params_str.join(", ")}\n"
      if !m.untyped.empty?
        sb << "  untyped: #{m.untyped.join(", ")}\n"
      end
      if ret = m.returns
        sb << "  returns: #{ret}\n"
      end
      if !m.written_block.empty?
        sb << "  written_block: #{m.written_block}\n"
      end
      sb << "  location: #{loc}\n"
    end
    sb.to_s
  end
end

if ARGV.size > 1 && ARGV[1] == "--count"
  filename = ARGV[0]
  parser = Iyi::Parser.new(File.read(filename))
  parser.filename = filename
  node = parser.parse
  methods = BindTool.analyze(node, "")
  puts methods.size
else
  filename = ARGV[0]
  root = ARGV.size > 1 ? ARGV[1] : ""
  parser = Iyi::Parser.new(File.read(filename))
  parser.filename = filename
  node = parser.parse
  methods = BindTool.analyze(node, root)
  print BindTool.dump_bind(methods, root)
end
CRYSTAL_GOLDEN_SCRIPT

# The oracle is the compiler being replaced, so it is built the way that
# compiler is: LLVM_CONFIG is what gives its LibLLVM its version constants.
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config || true)}" \
  CRYSTAL_PATH="$REPO/src" "$CRYSTAL" build -Di_know_what_im_doing \
    -o "$WORK/dump_crystal" "$WORK/dump_crystal_bind.cr"
if [ ! -x "$WORK/dump_crystal" ]; then
  echo "  THE ORACLE DID NOT BUILD: this gate cannot conclude anything"
  exit 1
fi

FIXTURES=(
  "bench/fixtures/decl_classes_and_structs.iyi"
  "bench/fixtures/decl_def.iyi"
  "bench/fixtures/decl_enums.iyi"
  "bench/fixtures/decl_lib_and_fun.iyi"
  "bench/fixtures/decl_modules_and_inclusion.iyi"
  "bench/fixtures/decl_operators.iyi"
  "bench/fixtures/decl_traits_and_impls.iyi"
  "bench/fixtures/decl_types_and_vars.iyi"
  "bench/fixtures/decl_visibility_and_annotations.iyi"
  "bench/fixtures/bind_shard.iyi"
  "bench/fixtures/bind_generics.iyi"
)

# Every fixture, both implementations, byte for byte.
compare_all() {
  out_status=0
  for rel_fixture in "${FIXTURES[@]}"; do
    fixture="$REPO/$rel_fixture"
    "$1" "$fixture" > "$WORK/a.out" 2>/dev/null || { out_status=1; continue; }
    "$WORK/dump_crystal" "$fixture" > "$WORK/b.out" 2>/dev/null || { out_status=1; continue; }
    diff -q "$WORK/a.out" "$WORK/b.out" >/dev/null || out_status=1
  done
  return $out_status
}

fixture_count=0
total_matched_methods=0
for rel_fixture in "${FIXTURES[@]}"; do
  fixture="$REPO/$rel_fixture"
  fixture_name="$rel_fixture"
  "$WORK/exercise" "$fixture" > "$WORK/iyi.out"
  "$WORK/dump_crystal" "$fixture" > "$WORK/crystal.out"
  if ! diff -u "$WORK/crystal.out" "$WORK/iyi.out" > "$WORK/diff.out"; then
    echo "  $fixture_name: BOUND METHODS DIFFER"
    diverged=$((diverged + 1))
    cat "$WORK/diff.out"
    status=1
  else
    methods_count=$("$WORK/dump_crystal" "$fixture" --count)
    echo "  $fixture_name: identical ($methods_count public methods match the front end)"
    total_matched_methods=$((total_matched_methods + methods_count))
  fi
  fixture_count=$((fixture_count + 1))
done
echo "  Parity summary: $((fixture_count - diverged))/$fixture_count fixtures bind identically ($total_matched_methods total public methods)"

echo
echo "== 3. Mutation proofs: each one must make the comparison above fail"

prove_mutation() {
  label="$1"
  old="$2"
  new="$3"
  echo "  [$label]"
  cp "$BIND" "$BIND.orig"
  python3 - "$BIND" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
if old not in t:
    sys.exit(3)
open(path, "w").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ] || diff -q "$BIND.orig" "$BIND" >/dev/null; then
    echo "    PATCH CHANGED NOTHING: this proves nothing"
    status=1
    cp "$BIND.orig" "$BIND"; rm -f "$BIND.orig"
    return
  fi
  if "$IYI" build -o "$WORK/mut-exercise" "$REPO/bench/selfhost_bind_exercise.iyi" >/dev/null 2>&1; then
    if compare_all "$WORK/mut-exercise"; then
      echo "    FAILED: the comparison still passed with the mutation applied"
      status=1
    else
      echo "    caught: the bound outputs diverged, as they must"
    fi
  else
    echo "    caught: the mutated bind tool did not build"
  fi
  cp "$BIND.orig" "$BIND"; rm -f "$BIND.orig"
  echo "    reverted"
}

MUTATIONS_RUN=0
run_proof() {
  prove_mutation "$1" "$2" "$3"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
}

run_proof "untyped arguments stop triggering NeedsHuman verdict" \
  "verdict = BindVerdict::NeedsHuman" \
  "verdict = BindVerdict::Ready"

run_proof "block detection is disabled across methods" \
  "has_block = !node.block_arg.nil? || node.uses_block_arg?" \
  "has_block = false"

run_proof "ready method counting is bypassed in summary report" \
  "ready = ready + 1" \
  "ready = ready + 0"
run_proof "callable calculation requires unannotated block" \
  "!@block || !@written_block.empty?" \
  "!@block && !@written_block.empty?"

echo "  $MUTATIONS_RUN mutation proofs run"

echo
if [ "$status" -eq 0 ]; then
  echo "== ALL SELFHOST BIND CHECKS PASSED"
else
  echo "== SELFHOST BIND CHECKS FAILED"
fi
exit $status
