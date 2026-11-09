require "../syntax/ast"
require "../syntax/visitor"
require "../types"

module Iyi
  # iyi: a declaration the top-level pass met that only a module marked
  # `@[Unsafe]` may write (SPEC.md III.13): an `@[Extern]` struct, an
  # `@[Primitive]` def, a type's `@[Share]` trust. *what* opens the refusal,
  # *hint* says what to write instead, *reason* is what `iyi fix` writes
  # into the mark it inserts.
  record UnsafeSite, node : ASTNode, what : String, hint : String, reason : String

  class Program
    # Every module marked `@[Unsafe("why")]` this compile knows of, by file:
    # the reason. A source mark is recorded when the file is read; an
    # artifact's when it is loaded, since a generic body that travels is
    # typed again here at its module's own locations (SPEC.md IV.1).
    getter iyi_unsafe_files = {} of String => String

    # The marks written in the sources this compile read, by file: what the
    # unneeded-mark warning and the language server's hover point at.
    getter iyi_unsafe_marks = {} of String => Annotation

    getter iyi_unsafe_sites = [] of UnsafeSite

    # The marked modules something in this compile needed the mark for.
    getter iyi_unsafe_used = Set(String).new

    # `Crystal::IYI_UNSAFE_MODULES`'s value (`define_crystal_constants`).
    property iyi_unsafe_modules_literal : StringLiteral?

    # `@[Unsafe("why")]`, first in its file: one reason, a string with
    # something in it, since the reason is what a reader of the module is
    # told about the raw memory it handles.
    def iyi_mark_unsafe_file(mark : Annotation) : Nil
      reason = mark.args.first?.as?(StringLiteral).try(&.value)
      unless mark.args.size == 1 && mark.named_args.nil? && reason && !reason.blank?
        mark.raise "a module's @[Unsafe] says why the module handles raw memory, as one string: " \
                   "`@[Unsafe(\"frames are read straight off the socket buffer\")]` (SPEC.md III.13)"
      end
      return unless file = mark.location.try(&.original_filename)
      @iyi_unsafe_files[file] = reason
      @iyi_unsafe_marks[file] = mark
    end

    # A module marked unsafe by the artifact it arrived as.
    def iyi_mark_unsafe_artifact(source_path : String, reason : String) : Nil
      @iyi_unsafe_files[source_path] = reason unless reason.empty?
    end

    # `@[Unsafe]` anywhere but first in a file: a def's caller contract,
    # `@[Unsafe(call: "index is in 0...size")]`, and nothing else.
    def iyi_check_unsafe_contract(mark : Annotation) : Nil
      contract = mark.named_args.try(&.find { |arg| arg.name == "call" }).try(&.value)
      unless mark.args.empty? && mark.named_args.try(&.size) == 1 && contract.is_a?(StringLiteral) && !contract.value.blank?
        mark.raise "@[Unsafe(\"why\")] marks a module and is the first statement of its file, above its " \
                   "`module` header; on a def it is the promise each caller keeps, " \
                   "`@[Unsafe(call: \"index is in 0...size\")]` (SPEC.md III.13)"
      end
    end

    def iyi_unsafe_site(node : ASTNode, what : String, hint : String, reason : String) : Nil
      @iyi_unsafe_sites << UnsafeSite.new(node, what, hint, reason)
    end

    # The non-std modules of this program marked unsafe, as the runtime's
    # fault message lists them (`Crystal::IYI_UNSAFE_MODULES`).
    def iyi_unsafe_modules_listed : String
      names = @iyi_unsafe_files.keys.compact_map do |file|
        UnsafeCheck.module_label_of(self, file) if iyi_own_unsafe_file?(file)
      end
      names.sort!.uniq!.join(", ")
    end

    # Whether *file* is a module marked unsafe that is not std's or the
    # prelude's: one the program's author, or a dependency's, vouches for.
    # Both sides are read as posix paths, as `iyi_written_in_prelude?`
    # reads them: on Windows the file and the prelude's directory are
    # spelled with `\` and `File::SEPARATOR` is `/`, so nothing was std's,
    # and a spawn reaching `Atomic` was said to reach unsafe code in
    # `src\iyi\atomic.iyi` (bench/spawn_eligible.sh's -f json step, nine
    # notes for seven, on tssh at 046858b9b).
    def iyi_own_unsafe_file?(file : String) : Bool
      return false unless @iyi_unsafe_files.has_key?(file)
      return true unless dir = iyi_prelude_dir
      std_root = "#{::Path[File.dirname(dir)].to_posix}/"
      !::Path[File.expand_path(file)].to_posix.to_s.starts_with?(std_root)
    end

    # The non-std unsafe modules each plain spawn's block reaches, by the
    # place of its `spawn` (`Location#to_s`): a spawn the compiler places
    # in parallel still runs there, since unsafe code is taken at its word,
    # and its note and its hint say so (SPEC.md III.4.15, III.13).
    getter iyi_spawn_unsafe = {} of String => String

    # The notes `--explain-spawn` adds beside a parallel spawn's: the unsafe
    # modules its block reaches.
    def iyi_note_unsafe_spawns : Nil
      return if @iyi_spawn_unsafe.empty?
      level = @warnings.explain_spawn
      return unless level.program? || level.all?
      seen = Set(String).new
      @iyi_spawn_sites.each do |site|
        next unless site.parallel?
        location = site.location.expanded_location || site.location
        next if !level.all? && site.std
        next unless (modules = @iyi_spawn_unsafe[location.to_s]?) && seen.add?(location.to_s)
        @warnings.add_note(location, UnsafeCheck.spawn_reaches(modules))
      end
    end
  end

  # iyi: unsafe code is code in a module that says so (SPEC.md III.13).
  #
  # An operation the compiler does not check - a value whose type is or holds
  # a `Pointer`, `uninitialized`, a `lib` and every call into one, a `fun`,
  # `asm`, `@[Primitive]`, a call to a def whose caller keeps a promise
  # (`@[Unsafe(call: "...")]`), and the trust marks `@[UnsafeReach]` and a
  # type's `@[Share]` - is allowed in a module whose first line is
  # `@[Unsafe("why")]`, and refused in every other `.iyi` file. The check
  # reads the typed program, so a `Pointer` reached through an alias, a
  # generic argument, a block parameter or a method's answer is one, where
  # the syntactic rule this replaces (`PointerFiles`, which marked a file
  # that spelled `Pointer`) saw only the name.
  #
  # It walks every typed def the program reaches, as the code generator
  # does, once each, after typing and before the cleanup, so the language
  # server's compile meets it too. What the compiler wrote for the person -
  # an array literal's `unsafe_build`, a slice literal's `pointerof`, a
  # definition-site probe's `uninitialized` - is followed for the defs it
  # calls and refused nothing. A def typed with a `Pointer` its caller
  # handed it - a generic instantiated with one, a parameter written
  # without a type - is the caller's raw memory, and the caller's module is
  # the one that has to be marked; a def whose own signature names
  # `Pointer` is its own module's.
  #
  # Off under `--crystal` and in `.cr` files, whose language has no such
  # rule.
  class UnsafeCheck < Visitor
    record Finding, line : Int32, column : Int32, size : Int32, what : String, hint : String, reason : String

    @findings = {} of String => Finding
    # The places of each module's unsafe operations, each counted once
    # however many instances of its def were typed.
    @places = Hash(String, Set({Int32, Int32})).new { |hash, file| hash[file] = Set({Int32, Int32}).new }
    @visited = Set(Def).new.compare_by_identity
    @walked_defs = Set({String, Int32, Int32}).new
    @pointer = {} of Type => Bool
    @contracts = {} of Def => String?
    @files = {} of String => Bool
    @headers = {} of String => String?
    # Inside what the compiler wrote: calls are followed, nothing refused.
    @exempt = 0
    # Inside a def typed with a `Pointer` its caller handed it.
    @borrowed = false
    @root : ASTNode?

    def initialize(@program : Program)
      @contracts.compare_by_identity
    end

    def self.run(program : Program, node : ASTNode) : Nil
      return unless program.iyi_prelude?
      new(program).run(node)
    end

    def run(node : ASTNode) : Nil
      @root = node
      node.accept self
      @program.finished_hooks.each(&.node.accept(self))
      @program.class_var_initializers.each(&.node.accept(self))
      @program.after_inference_types.each { |type| initializers_of(type) }
      check_sites
      refuse
      warn_unneeded
      @program.iyi_unsafe_modules_literal.try { |literal| literal.value = @program.iyi_unsafe_modules_listed }
    end

    # --- what the walk visits ---------------------------------------------

    # The defs in the tree are the declarations; their typed instances are
    # reached through the calls that name them.
    def visit(node : Def) : Bool
      node.hook_expansions.try &.each &.accept self
      false
    end

    def visit(node : ClassDef) : Bool
      node.hook_expansions.try &.each &.accept self
      true
    end

    def visit(node : Include | Extend) : Bool
      node.hook_expansions.try &.each &.accept self
      false
    end

    def visit(node : Macro | AnnotationDef | TypeOf) : Bool
      false
    end

    def visit(node : LibDef) : Bool
      note(node, "`lib #{node.name}` declares C functions the compiler does not check", "",
        "declares the C library `#{node.name}`")
      false
    end

    def visit(node : FunDef) : Bool
      note(node, "`fun #{node.name}` is a C function the compiler does not check", "",
        "declares the C function `#{node.name}`")
      node.external?.try(&.body).try &.accept self
      false
    end

    def visit(node : Asm) : Bool
      note(node, "`asm` is machine code the compiler does not check", "", "writes `asm`")
      true
    end

    def visit(node : UninitializedVar) : Bool
      note(node, "`uninitialized #{node.declared_type}` is a value nothing has written, and a reference read from it points anywhere",
        "give it a value, or make it nilable, ", "reads `uninitialized #{node.declared_type}`")
      false
    end

    # A definition-site probe (`DefinitionTyping`): the compiler's own call,
    # with `uninitialized` arguments, that types a def where it is written.
    def visit(node : If) : Bool
      return true unless node.iyi_definition_probe?
      exempt { node.then.accept self }
      false
    end

    # An array literal's expansion builds the array through its buffer.
    def visit(node : ArrayLiteral) : Bool
      node.elements.each &.accept self
      node.expanded.try { |expanded| exempt { expanded.accept self } }
      false
    end

    def visit(node : ExpandableNode) : Bool
      if expanded = node.expanded
        expanded.accept self
        return false
      end
      true
    end

    def visit(node : ProcLiteral) : Bool
      node.def.args.each &.accept self
      node.def.body.accept self
      false
    end

    def visit(node : ProcPointer) : Bool
      if expanded = node.expanded
        expanded.accept self
      else
        node.call?.try &.accept self
      end
      false
    end

    def visit(node : Call) : Bool
      if expanded = node.expanded
        if node.iyi_compiler_expansion?
          exempt { expanded.accept self }
        else
          expanded.accept self
        end
        return false
      end
      pointer_typed(node)
      node.target_defs.try &.each do |target|
        if target.is_a?(External)
          note(node, "`#{target.name}` is a C function the compiler does not check", "",
            "calls the C function `#{target.name}`")
        elsif contract = contract_of(target)
          note(node, "`#{target.owner}##{target.name}` promises \"#{contract}\", and its caller keeps that promise",
            contract_hint(target), "calls `#{target.name}`, whose caller keeps `#{contract}`")
        end
        spawn_reach(node) if CleanupTransformer.spawn_def?(target)
      end
      true
    end

    # The program's own unsafe modules a plain spawn's block reaches, kept
    # by the spawn's place for its note and its hint. Walked only in a
    # program that has such a module.
    private def spawn_reach(node : Call) : Nil
      return unless (block = node.block) && (location = node.name_location || node.location)
      own = @program.iyi_unsafe_files.keys.select { |file| @program.iyi_own_unsafe_file?(file) }
      return if own.empty?
      reached = ReachedFiles.new
      block.accept reached
      modules = own.select { |file| reached.files.includes?(file) }.map { |file| UnsafeCheck.module_label_of(@program, file) }
      return if modules.empty?
      @program.iyi_spawn_unsafe[(location.expanded_location || location).to_s] = modules.sort!.join(", ")
    end

    # What a spawn's note and hint add when its block reaches unsafe code.
    def self.spawn_reaches(modules : String) : String
      "spawn reaches unsafe code in #{modules}, which the compiler takes at its word (SPEC.md III.13)"
    end

    # The files of every def a block's calls reach, the block's own
    # included, through each call's targets.
    class ReachedFiles < Visitor
      getter files = Set(String).new
      @visited = Set(Def).new.compare_by_identity

      def visit(node : ASTNode) : Bool
        if (location = node.location) && (file = location.expanded_location.try(&.filename)).is_a?(String)
          @files << file
        end
        true
      end

      def visit(node : Call) : Bool
        if (location = node.location) && (file = location.expanded_location.try(&.filename)).is_a?(String)
          @files << file
        end
        node.expanded.try { |expanded| expanded.accept self; return false }
        node.target_defs.try &.each do |target|
          target.accept_children self if @visited.add?(target)
        end
        true
      end
    end

    def end_visit(node : Call) : Nil
      return if node.expanded
      node.target_defs.try &.each { |target| walk_def(target) }
    end

    def visit(node : Var | Arg | InstanceVar | ReadInstanceVar | ClassVar | Global | Cast | NilableCast | PointerOf | Path) : Bool
      pointer_typed(node)
      true
    end

    def visit(node : ASTNode) : Bool
      true
    end

    # --- typed defs ---------------------------------------------------------

    private def walk_def(target : Def) : Nil
      return unless @visited.add?(target)
      if (location = target.location) && (file = location.filename).is_a?(String)
        @walked_defs << {file, location.line_number, location.column_number}
      end
      exempt, borrowed = @exempt, @borrowed
      # A definition-site probe's witness (`DefinitionTyping`) implements a
      # trait's requirements with `uninitialized` bodies the compiler wrote,
      # so they are followed and refused nothing, like the probe that calls
      # them: `def area_of(x : Shape) : Int32` over a trait nothing
      # implemented yet was refused for the witness's `uninitialized Int32`.
      @exempt = target.owner?.try(&.to_s.starts_with?(DefinitionTyping::WITNESS_PREFIX)) ? 1 : 0
      @borrowed = borrowed?(target)
      begin
        target.accept_children self
      ensure
        @exempt, @borrowed = exempt, borrowed
      end
    end

    # Whether *target* holds a `Pointer` because its caller handed it one:
    # an instance of a generic whose argument is one, or a parameter whose
    # written type left the choice to the caller - none written, or one of
    # the def's free variables (`forall T`). A parameter whose written type
    # is a `Pointer` however it is spelled - `Pointer(UInt8)`, `UInt8*`, an
    # alias of one - is its own module's raw memory.
    private def borrowed?(target : Def) : Bool
      owner = target.owner?
      if owner.is_a?(GenericInstanceType) && !owner.is_a?(PointerInstanceType)
        return true if owner.type_vars.each_value.any? { |var| var.is_a?(Var) && (type = var.type?) && pointer_in?(type) }
      end
      free = target.free_vars
      target.args.any? do |arg|
        (type = arg.type?) && pointer_in?(type) && caller_chosen?(arg.restriction, free)
      end
    end

    private def caller_chosen?(node : ASTNode?, free : Array(String)?) : Bool
      case node
      when Nil
        true
      when Path
        !!(free && node.names.size == 1 && free.includes?(node.names.first))
      when Generic
        node.type_vars.any? { |var| caller_chosen?(var, free) }
      when Union
        node.types.any? { |type| caller_chosen?(type, free) }
      when ProcNotation
        node.inputs.try(&.any? { |input| caller_chosen?(input, free) }) || (node.output.try { |output| caller_chosen?(output, free) } || false)
      else
        false
      end
    end

    private def initializers_of(type : Type) : Nil
      case type
      when GenericClassType
        type.each_instantiated_type { |instance| initializers_of(instance) }
      when GenericClassInstanceType, ClassType
        type.instance_vars_initializers.try &.each(&.value.accept(self))
      end
    end

    # --- U1: a value whose type is or holds a Pointer ------------------------

    private def pointer_typed(node : ASTNode) : Nil
      return if @borrowed
      return unless type = node.type?
      return unless pointer_in?(type)
      case node
      when Call
        if node.name == "to_unsafe" && (receiver = node.obj.try(&.type?))
          note(node, "`#{snippet(node)}` answers `#{type}`, raw memory the compiler does not check",
            to_unsafe_hint(receiver), "reads #{article(receiver)} memory through `to_unsafe`")
        else
          note(node, "`#{snippet(node)}` answers `#{type}`, raw memory the compiler does not check", "",
            "handles `#{type}` through `#{node.name}`")
        end
      when PointerOf
        note(node, "`#{snippet(node)}` takes an address, raw memory the compiler does not check", "",
          "takes an address with `pointerof`")
      when Cast, NilableCast
        note(node, "`#{snippet(node)}` casts to `#{type}`, raw memory the compiler does not check", "",
          "casts to `#{type}`")
      when Var, Arg
        note(node, "`#{node.name}` is a `#{type}`, raw memory the compiler does not check", "",
          "holds `#{type}` in `#{node.name}`")
      when InstanceVar, ReadInstanceVar, ClassVar, Global
        note(node, "`#{snippet(node)}` is a `#{type}`, raw memory the compiler does not check", "",
          "keeps `#{type}` in `#{snippet(node)}`")
      else
        note(node, "`#{snippet(node)}` is a `#{type}`, raw memory the compiler does not check", "",
          "handles `#{type}`")
      end
    end

    # Whether a value of *type* is a `Pointer` or holds one where its type
    # says so: a union, a tuple, a proc's parameters or answer, a generic's
    # arguments. A type that keeps one in a field (`Slice`, `Array`) is not:
    # holding one is safe, and only its own module touches the field.
    def pointer_in?(type : Type) : Bool
      cached = @pointer[type]?
      return cached unless cached.nil?
      @pointer[type] = false
      @pointer[type] = holds_pointer?(type)
    end

    private def holds_pointer?(type : Type) : Bool
      case type
      when PointerInstanceType
        true
      when UnionType
        type.union_types.any? { |member| pointer_in?(member) }
      when TupleInstanceType
        type.tuple_types.any? { |member| pointer_in?(member) }
      when NamedTupleInstanceType
        type.entries.any? { |entry| pointer_in?(entry.type) }
      when ProcInstanceType
        type.arg_types.any? { |arg| pointer_in?(arg) } || pointer_in?(type.return_type)
      when GenericInstanceType
        type.type_vars.each_value.any? { |var| var.is_a?(Var) && (held = var.type?) && pointer_in?(held) }
      when TypeDefType
        pointer_in?(type.typedef)
      when AliasType
        pointer_in?(type.aliased_type)
      else
        false
      end
    end

    # The expression as a message quotes it: one line, and short.
    private def snippet(node : ASTNode) : String
      # `split` on whitespace, not a Regex, which would link pcre2 into
      # the compiler (bench/dependency_floor.sh forbids it).
      text = node.to_s.split.join(' ')
      text.size > 48 ? "#{text[0, 45]}..." : text
    end

    # What reads a value's bytes without its memory: for a string, the
    # checked byte and the read-only view (SPEC.md III.13).
    private def to_unsafe_hint(receiver : Type) : String
      if receiver == @program.string
        "read a byte with `byte_at(i)`, see the bytes with `Bytes.of(text)`, "
      else
        "index it with `[]`, which checks the index, "
      end
    end

    # "a String's", "an Array(Int32)'s".
    private def article(type : Type) : String
      name = type.to_s
      "#{name[0]?.try(&.in?('A', 'E', 'I', 'O', 'U')) ? "an" : "a"} #{name}'s"
    end

    # --- U5: caller contracts ------------------------------------------------

    # The promise a call to *target* makes its caller keep: its own
    # `@[Unsafe(call: "...")]`, or that of the abstract def it implements.
    def contract_of(target : Def) : String?
      return @contracts[target] if @contracts.has_key?(target)
      @contracts[target] = UnsafeCheck.contract_of(@program, target)
    end

    # The promise a call to *target* makes its caller keep, as the language
    # server's hover shows it too: written on *target*, or on the abstract
    # def it implements.
    def self.contract_of(program : Program, target : Def) : String?
      written_contract(program, target) || inherited_contract(program, target)
    end

    private def self.inherited_contract(program : Program, target : Def) : String?
      return nil unless owner = target.owner?
      owner.ancestors.each do |ancestor|
        ancestor.defs.try(&.[target.name]?).try &.each do |item|
          next unless item.def.abstract?
          if contract = written_contract(program, item.def)
            return contract
          end
        end
      end
      nil
    end

    def self.written_contract(program : Program, target : Def) : String?
      written = target.annotation(program.unsafe_annotation).try(&.named_args).try(&.find { |arg| arg.name == "call" }).try(&.value)
      written.as?(StringLiteral).try(&.value)
    end

    private def contract_hint(target : Def) : String
      case target.name
      when "unsafe_fetch" then "use `[]`, which checks the index, "
      when "unsafe_put"   then "use `[]=`, which checks the index, "
      else                     ""
      end
    end

    # --- U6 and the declarations the top level met ---------------------------

    private def check_sites : Nil
      @program.iyi_unsafe_sites.each do |site|
        note(site.node, site.what, site.hint, site.reason)
      end
      @program.iyi_reach_claims.each do |claim|
        next unless claim.unsafe?
        note(claim.annotation, "@[UnsafeReach] on `#{claim.label}` is the claim the compiler takes on trust",
          "say @[SafeReach(\"...\")], which the compiler proves, or make the state Share - a `Mutex`, an `Atomic`, a `List` - ",
          "trusts @[UnsafeReach] on `#{claim.label}`")
      end
    end

    # --- recording ----------------------------------------------------------

    private def exempt(&) : Nil
      @exempt += 1
      begin
        yield
      ensure
        @exempt -= 1
      end
    end

    private def note(node : ASTNode, what : String, hint : String, reason : String) : Nil
      return if @exempt > 0
      return if (node.is_a?(Call) || node.is_a?(Path)) && node.iyi_synthetic?
      written = (node.is_a?(Call) ? node.name_location : nil) || node.location
      return unless written
      at = written.expanded_location
      return unless at && (file = at.filename).is_a?(String)
      return unless checked?(file)
      if @program.iyi_unsafe_files.has_key?(file)
        @program.iyi_unsafe_used << file
        return
      end
      @places[file] << {at.line_number, at.column_number}
      size = written.filename.is_a?(String) && node.is_a?(Call) ? node.name_size : 0
      found = Finding.new(at.line_number, at.column_number, size, what, hint, "#{reason}, line #{at.line_number}")
      earlier = @findings[file]?
      if earlier.nil? || {found.line, found.column} < {earlier.line, earlier.column}
        @findings[file] = found
      end
    end

    private def checked?(file : String) : Bool
      @files.fetch(file) { @files[file] = Lexer.iyi_source?(file) }
    end

    # Each module with an unsafe operation and no mark, refused at its first
    # such operation, the entry's first, with the mark as the edit.
    private def refuse : Nil
      return if @findings.empty?
      entry = @program.filename
      errors = @findings.keys.sort_by! { |file| {file == entry ? 0 : 1, file} }.map do |file|
        found = @findings[file]
        refusal(file, found, @places[file].size).as(CodeError)
      end
      raise errors.first if errors.size == 1
      raise CodeErrors.new(errors)
    end

    private def refusal(file : String, found : Finding, count : Int32) : TypeException
      header = header_of(file)
      label = UnsafeCheck.module_label_of(@program, file)
      where = header ? "above its `module` header" : "above its first statement"
      more = count > 1 ? " (#{count - 1} more #{count == 2 ? "place in this module does" : "places in this module do"} the same)" : ""
      mark = "if this module handles raw memory, say why #{where}: `@[Unsafe(\"...\")]` (SPEC.md III.13)"
      advice = found.hint.empty? ? "I#{mark[1..]}" : "#{found.hint[0].upcase}#{found.hint[1..]}or, #{mark}"
      message = "#{found.what}, and `#{label}` is not marked unsafe#{more}. #{advice}"
      ex = TypeException.new(message, found.line, found.column, file, found.size)
      if edit = mark_edit(file, found.reason)
        ex.edit_at, ex.suggestion = edit
      end
      ex
    end

    # Where the mark goes and what is written: above the `module` header,
    # or above the first statement of a file without one, by replacing that
    # line's first character with the mark, a line break and itself.
    private def mark_edit(file : String, reason : String) : { {Int32, Int32, Int32}, String }?
      return unless text = source_of(file)
      text.each_line.with_index do |line, index|
        line = line.lchop('\uFEFF') if index == 0
        stripped = line.lstrip
        next if stripped.empty? || stripped.starts_with?('#')
        indent = line.size - stripped.size
        mark = "@[Unsafe(\"#{UnsafeCheck.reason_text(reason)}\")]"
        return { {index + 1, indent + 1, 1}, "#{mark}\n#{line[0, indent]}#{stripped[0]}" }
      end
      nil
    end

    # A reason the compiler writes, as the text of a string literal.
    def self.reason_text(reason : String) : String
      reason.gsub('"', '`').gsub('\\', '/').gsub("\#{", "#(")
    end

    private def source_of(file : String) : String?
      @program.iyi_file_override(file) || (File.read(file) if File.file?(file))
    rescue IO::Error
      nil
    end

    private def header_of(file : String) : String?
      @headers.fetch(file) do
        @headers[file] = source_of(file).try { |text| Compiler.module_header_of(text) }
      end
    end

    # How messages name the module of *file*: its header's path, or the file
    # of a script without one.
    def self.module_label_of(program : Program, file : String) : String
      program.iyi_module_paths[file]? ||
        (File.read(file).try { |text| Compiler.module_header_of(text) } if File.file?(file)) ||
        Iyi.relative_filename(file)
    rescue IO::Error
      Iyi.relative_filename(file)
    end

    # --- the mark nothing needs ----------------------------------------------

    # A marked module that did nothing unsafe in this compile is warned of,
    # when the compile typed every def it declares: a def nothing typed may
    # be the one that needs the mark. A module with a macro conditional is
    # not warned of, since `{% if flag?(:darwin) %}` hides from one target
    # the code another's compile needs the mark for (std/system_roots,
    # whose C calls are darwin's and Windows', was told on Linux to drop it).
    private def warn_unneeded : Nil
      return unless @program.warnings.level.all?
      candidates = @program.iyi_unsafe_marks.keys.reject { |file| @program.iyi_unsafe_used.includes?(file) }
      return if candidates.empty?
      untyped = Set(String).new
      declared = DeclaredDefs.new(candidates.to_set)
      @root.try &.accept(declared)
      declared.defs.each do |(file, line, column)|
        untyped << file unless @walked_defs.includes?({file, line, column})
      end
      candidates.each do |file|
        next if untyped.includes?(file)
        mark = @program.iyi_unsafe_marks[file]
        location = mark.location
        next unless location
        label = UnsafeCheck.module_label_of(@program, file)
        text = source_of(file)
        next if text.nil? || text.includes?("{%")
        line_size = text.lines[location.line_number - 1]?.try(&.size) || 0
        report = TypeException.new("`#{label}` is marked @[Unsafe] and does nothing unsafe: remove the mark, so the " \
                                   "compiler checks this module (SPEC.md III.13)",
          location.line_number, location.column_number, file, line_size - location.column_number + 2)
        report.suggestion = ""
        report.warning = true
        @program.warnings.add_report(report, location)
      end
    end

    # The defs a set of files declares, as {file, line, column}, read off the
    # tree as written: not those a macro wrote, whose bodies are the macro's.
    class DeclaredDefs < Visitor
      getter defs = [] of {String, Int32, Int32}

      def initialize(@files : Set(String))
      end

      def visit(node : Def) : Bool
        if !node.abstract? && (location = node.location) && (file = location.filename).is_a?(String) && @files.includes?(file)
          @defs << {file, location.line_number, location.column_number}
        end
        false
      end

      def visit(node : ExpandableNode) : Bool
        node.expanded.try &.accept self
        false
      end

      def visit(node : Macro | LibDef | FunDef | Call) : Bool
        false
      end

      def visit(node : ASTNode) : Bool
        true
      end
    end
  end
end
