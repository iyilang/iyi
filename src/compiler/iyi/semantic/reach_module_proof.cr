require "crystal/digest/md5"

module Iyi
  # iyi: each std module's claims proven once, over all of the module's code,
  # and the answer reused by every program that imports the module (SPEC.md
  # III.4.4).
  #
  # std's 80 `@[SafeReach]` claims are on state written only by its module's
  # initialiser - read-only tables, and caches each class variable's
  # initializer fills - and proving one walked every callable of the program
  # importing it: 0.24 s of a 2.1 s build of `bench/web_cores.iyi` on an
  # Apple M2 Pro, 0.21 s of `bench/std_http_exercise.iyi`'s. Every importer
  # reached the same answer about the same code, and an artifact's build
  # already asks the question that makes the answer portable: whether the
  # claim holds for every importer (`ReachProof#robust?`).
  #
  # A program that proves a std module's claims writes, beside its build
  # cache, the claims that hold for any importer, keyed by the module's
  # bytes, the bytes of every module it imports and of the prelude, the
  # compiler and the flags. A program whose key finds one takes those claims
  # as proven and walks nothing for them. A claim is written only when the
  # proof covers every function of the module, not just the ones the
  # program calls, and when nothing an importer adds can change it:
  #
  # - Every def and macro written in the module that names the state was
  #   read by the proof: a def the program never calls is read through its
  #   definition-site probe (`DefinitionTyping`), and a def no probe can
  #   call - one taking a block, say - that names the state keeps the claim
  #   out. So does one written with macro code, one whose owner is generic
  #   or a class something here inherits, and one whose parameters may hold
  #   another program's type: each of those may be typed again by an
  #   importer into a body this proof never read.
  # - Nothing but the module may name it: a class variable's type keeps
  #   every def in the module's file.
  # - The state never reaches code the importer chooses: no proc call is
  #   handed it, no def answering it takes a block, and each call it passes
  #   through (*Passage*) runs a def of the module, of a module it imports or
  #   of the prelude. The importer's own defs are asked again: one of the
  #   call's name on a subtype of its receiver that the proof did not see
  #   run (an override), or one written outside those files on the receiver
  #   or an ancestor the lookup passes before the def the proof saw (a
  #   reopening's overload), and the claim is proven again.
  #
  # Two broken copies, each caught by `bench/reach_rule.sh`:
  # `IYI_SPAWN_BROKEN=modulereach` writes a claim without asking whether the
  # proof read every def that names the state - a module function that
  # writes the table, which no probe calls, is called from a parallel unit
  # of a program built after one that wrote the module's answer - and
  # `modulepass` takes a stored claim without asking the importer's defs -
  # its subclass's override of the method the module hands the table to
  # writes it.
  class ReachProof
    # A call claimed state passes through, in the program that proved the
    # module: the method's *name*, the receiver's type as it is spelled
    # (*receiver*), the types the lookup passes through to reach the defs
    # it ran (*family*, `looked_up`), those defs (*targets*, as `def_key`
    # spells them), and the defs of its name the proving program had on
    # those types from outside the module's files (*seen*, with their
    # file's digest), which its lookup passed over.
    class Passage
      getter name : String
      getter receiver : Set(String)
      getter family : Set(String)
      getter targets : Set(String)
      getter seen : Set(String)

      def initialize(@name : String, @receiver = Set(String).new, @family = Set(String).new, @targets = Set(String).new,
                     @seen = Set(String).new)
      end
    end

    # What a stored answer says of one state: the calls it passes through,
    # and the defs naming it that the proving program never typed
    # (*dormant*, by name and `def_key`), which a program reusing the
    # answer must not have typed either.
    class Answer
      getter passages : Array(Passage)
      getter dormant : Array({String, String})

      def initialize(@passages = [] of Passage, @dormant = [] of {String, String})
      end
    end

    alias Verdict = Hash(String, Answer)

    VERDICT_FORMAT = "iyi reach verdict 2"
    VERDICT_SEPARATOR = '\u001f'

    # Each module's stored answer, by its file, once looked for: nil when
    # none was stored, which `record_module_proofs` then writes.
    @module_verdicts = {} of String => Verdict?
    @module_files = {} of String => Set(String)
    @digests = {} of String => String
    @prelude_prefixes = {} of String => String?
    # The claims the walk proved that `robust?` accepted.
    @proven_by_walk = Set(UInt64).new
    @def_index : Hash(String, Array({Type, Def}))? = nil
    @defs_by_file : Hash(String, Array(Def))? = nil
    @macros_by_file : Hash(String, Array(Macro))? = nil
    @walked_defs : Hash(String, Array(Def))? = nil
    @texts = ({} of ASTNode => String).compare_by_identity
    @type_names = ({} of Type => String).compare_by_identity
    @ancestor_names = ({} of Type => Set(String)).compare_by_identity

    # Whether a std module's stored answer proves *claim* in this program.
    private def module_proven?(claim : ReachClaim) : Bool
      file = module_file(claim)
      return false unless file
      verdict = module_verdict(file)
      return false unless verdict
      answer = verdict[state_name(claim.state)]?
      return false unless answer
      return false unless owned_in?(claim.state, file) && still_dormant?(answer.dormant)
      SPAWN_BROKEN.includes?("modulepass") || passages_clear?(answer.passages, file)
    end

    # Whether no def of *dormant* has been typed by this program: a call
    # to one would run code naming the state that the proof never read.
    private def still_dormant?(dormant : Array({String, String})) : Bool
      dormant.all? do |(name, key)|
        found = false
        def_index[name]?.try &.each do |(_, a_def)|
          next unless def_key(a_def) == key
          return false if a_def.iyi_instantiated?
          found = true
        end
        found
      end
    end

    # The std module that declares the claimed state: its file, read from
    # source by this build and not the program's own.
    private def module_file(claim : ReachClaim) : String?
      at = claim.annotation.location
      file = at.try(&.original_filename)
      return nil unless file
      return nil if file == @program.filename
      return nil unless @program.iyi_module_paths.has_key?(file)
      return nil unless @program.iyi_share_reach.std_at?(at)
      file
    end

    private def module_verdict(file : String) : Verdict?
      return @module_verdicts[file] if @module_verdicts.has_key?(file)
      @module_verdicts[file] = load_verdict(file)
    end

    # Writes, for each module whose answer was not stored, the claims this
    # program's proof shows hold for every importer. Called once every
    # claim is proven: a refused build writes nothing.
    private def record_module_proofs : Nil
      @module_verdicts.each do |file, stored|
        next if stored
        path = verdict_path(file)
        next unless path
        found = Verdict.new
        @claims.each do |claim|
          next unless @proven_by_walk.includes?(claim.state.object_id)
          next unless module_file(claim) == file
          if answer = module_answer(claim, file)
            found[state_name(claim.state)] = answer
          end
        end
        write_verdict(path, found)
      end
    end

    # What *claim*'s answer stores, when the proof covers every def of
    # *file* that names it and nothing an importer adds can reach it; nil
    # otherwise.
    private def module_answer(claim : ReachClaim, file : String) : Answer?
      state = claim.state
      return nil unless owned_in?(state, file)
      dormant = covered(state.name, file)
      return nil unless dormant
      dormant.clear if SPAWN_BROKEN.includes?("modulereach")
      passages = passages_of(state.object_id, file)
      return nil unless passages && passages_clear?(passages, file, record: true)
      Answer.new(passages, dormant)
    end

    # A def whose block is written whole (`& : Char -> Nil`), so every
    # caller's block gives it the same types.
    private def typed_block?(a_def : Def) : Bool
      notation = a_def.block_arg.try(&.restriction)
      notation.is_a?(ProcNotation) && !notation.output.nil?
    end

    # What macro code may read besides the module's bytes and the flags.
    MACRO_INPUTS = {"env(", "read_file", "run(", "system(", "`"}

    # Whether macro code in *text* - between `{%` and `%}`, or `{{` and
    # `}}` - reads one of `MACRO_INPUTS`.
    private def macro_reads?(text : String) : Bool
      [{"{%", "%}"}, {"{{", "}}"}].each do |(open, close)|
        start = 0
        while opened = text.index(open, start)
          closed = text.index(close, opened + 2) || text.size
          code = text[opened...closed]
          return true if MACRO_INPUTS.any? { |input| code.includes?(input) }
          start = closed
        end
      end
      false
    end

    # The defs written in *file* that name *token* (`TABLE`, `@@cache`)
    # and that this program never typed, by name and `def_key`, when the
    # proof read every other one as any importer would type it - on an
    # owner and parameters no importer gives another type, with a block
    # written whole if it takes one, and with no macro code that reads
    # anything the key does not hash - and no macro written there names
    # it; nil otherwise.
    private def covered(token : String, file : String) : Array({String, String})?
      walked = walked_defs
      dormant = [] of {String, String}
      (defs_by_file[file]? || [] of Def).each do |a_def|
        text = text_of(a_def)
        next unless mentions?(text, token)
        unless a_def.iyi_instantiated?
          dormant << {a_def.name, def_key(a_def)}
          next
        end
        return nil if macro_reads?(text)
        return nil if (a_def.block_arity || a_def.block_arg) && !typed_block?(a_def)
        return nil unless (owner = a_def.owner?) && steady_owner?(owner)
        instances = walked[def_key(a_def)]?
        return nil unless instances
        instances.each do |instance|
          return nil unless instance.args.all? { |arg| (type = arg.type?) && steady_type?(type, 0) }
        end
      end
      (macros_by_file[file]? || [] of Macro).each do |a_macro|
        return nil if mentions?(text_of(a_macro), token)
      end
      dormant
    end

    # Whether *text* names *token* as a word of its own.
    private def mentions?(text : String, token : String) : Bool
      start = 0
      while index = text.index(token, start)
        before = index > 0 ? text[index - 1] : ' '
        after = text[index + token.size]? || ' '
        word = ->(char : Char) { char.alphanumeric? || char == '_' || char == '@' }
        return true unless word.call(before) || word.call(after)
        start = index + 1
      end
      false
    end

    # A def's owner whose methods no importer types again for a type of
    # its own: a module, a struct nothing inherits, the program, or a class
    # this program does not inherit (a subclass of the importer's is asked
    # by `passages_clear?`).
    private def steady_owner?(owner : Type) : Bool
      type = owner.metaclass? ? owner.instance_type : owner
      case type
      when GenericType
        false
      when Program, FileModule, NonGenericModuleType, EnumType
        true
      when NonGenericClassType
        (type.struct? && !type.abstract?) || type.subclasses.empty?
      else
        false
      end
    end

    # A parameter's type no importer can hand another type through, save a
    # subclass of its own (`passages_clear?`).
    private def steady_type?(type : Type, depth : Int32) : Bool
      return false if depth > 8
      case type
      when NilType, BoolType, CharType, IntegerType, FloatType, SymbolType, EnumType, NoReturnType, VoidType,
           PointerInstanceType
        true
      when TupleInstanceType
        type.tuple_types.all? { |member| steady_type?(member, depth + 1) }
      when NamedTupleInstanceType
        type.entries.all? { |entry| steady_type?(entry.type, depth + 1) }
      when UnionType
        type.union_types.all? { |member| steady_type?(member, depth + 1) }
      when NonGenericClassType, GenericClassInstanceType
        type == @program.string || (type.struct? && !type.abstract?) || type.subclasses.empty?
      else
        false
      end
    end

    # The calls the state passes through, from each place it is named or
    # answered, through each callee it is handed to, slot by slot (the
    # demand `analyze` read); nil when one reaches code the importer may
    # choose.
    private def passages_of(key : UInt64, file : String) : Array(Passage)?
      passages = {} of {String, String} => Passage
      pending = Deque({Callable, Int32}).new
      seen = Set({Int32, Int32}).new
      @state_events[key]?.try &.each do |(callable, event)|
        return nil unless pass(callable, event, file, passages, pending, seen)
      end
      while entry = pending.shift?
        callable, slot = entry
        callable.events.each do |event|
          root = event.root
          next unless root.kind.slot? && root.slot == slot
          return nil unless pass(callable, event, file, passages, pending, seen)
        end
      end
      # A def that answers the state and takes a block may yield it to the
      # importer's block.
      @answerers.each do |callable|
        next unless state_out(callable).includes?(key)
        a_def = callable.a_def.not_nil!
        return nil if a_def.block_arity || a_def.block_arg
      end
      passages.values
    end

    private def pass(callable : Callable, event : Event, file : String, passages : Hash({String, String}, Passage),
                     pending : Deque({Callable, Int32}), seen : Set({Int32, Int32})) : Bool
      cause = event.cause
      return false if cause.proc_type
      callee = cause.callee
      return true unless callee
      target = callee.a_def
      return false unless target
      where = def_file(target)
      return false unless where && inside?(file, where)
      receivers = receiver_types(callable, event, target)
      return false unless receivers
      receivers.each do |receiver|
        passage = passages[{target.name, type_name(receiver)}] ||= Passage.new(target.name, names_of(receiver))
        looked_up(receiver, target).each { |name| passage.family << name }
        passage.targets << def_key(target)
      end
      pending << {callee, cause.slot} if seen.add?({callee.id, cause.slot})
      true
    end

    # The types a call on *receiver* looks *target*'s name up in before it
    # reaches the type that defined *target*: the receiver and its
    # ancestors in order, up to that one. A def written on one of them -
    # a reopening's overload - may be found instead; one written past it
    # cannot. All of them when the defining type is not among them.
    private def looked_up(receiver : Type, target : Def) : Set(String)
      names = names_of(receiver)
      defining = target.original_owner? || target.owner?
      wanted = defining ? names_of(defining) : Set(String).new
      return names if names.any? { |name| wanted.includes?(name) }
      receiver.ancestors.each do |ancestor|
        add_names(ancestor, names)
        return names if names_of(ancestor).any? { |name| wanted.includes?(name) }
      end
      ancestor_names(receiver).each { |name| names << name }
      names
    end

    # The type a call's method is looked up on: its receiver's, or for a
    # call without one the type of the def it is written in.
    private def receiver_types(callable : Callable, event : Event, target : Def) : Array(Type)?
      node = event.node
      return nil unless node.is_a?(Call)
      type = if obj = node.obj
               obj.type?
             elsif home = callable.a_def
               home.owner?
             else
               target.owner?
             end
      return nil unless type
      members = type.is_a?(UnionType) ? type.union_types : [type]
      members.map(&.devirtualize.as(Type))
    end

    # Whether no def of this program but the ones the proof saw can run
    # where the state passes: none of a passage's name written on a subtype
    # of its receiver that the proof did not see run, and none written
    # outside the module and what it imports on a type its lookup passes
    # through, save one the proving program had too, from the same bytes.
    # *record*, in the proving program, notes those as seen.
    private def passages_clear?(passages : Array(Passage), file : String, record : Bool = false) : Bool
      index = def_index
      passages.each do |passage|
        index[passage.name]?.try &.each do |(owner, a_def)|
          where = def_file(a_def)
          if (where.nil? || !inside?(file, where)) && passage.family.includes?(type_name(owner))
            seen = where ? "#{def_key(a_def)}@#{digest_of(where)}" : nil
            if seen && record
              passage.seen << seen
            elsif seen.nil? || !passage.seen.includes?(seen)
              return false
            end
          end
          next if passage.targets.includes?(def_key(a_def))
          if ancestor_names(owner).any? { |name| passage.receiver.includes?(name) }
            return false
          end
        end
      end
      true
    end

    # Whether only *file* may name *state*: a class variable's type and its
    # class keep every def written in it (the compiler's own, written
    # nowhere, name nothing). A constant needs nothing more than that its
    # module does not export it, which `robust?` asked.
    private def owned_in?(state : Const | MetaTypeVar, file : String) : Bool
      return true if state.is_a?(Const)
      owner = state.owner
      types = owner.is_a?(ModuleType) && !owner.is_a?(Program) ? [owner, owner.metaclass] : [owner]
      types.each do |type|
        type.defs.try &.each_value do |list|
          list.each do |entry|
            where = def_file(entry.def)
            next if where.nil? || where == file
            return false
          end
        end
      end
      true
    end

    # How a verdict names a state.
    private def state_name(state : Const | MetaTypeVar) : String
      state.is_a?(Const) ? state.to_s : "#{state.owner}.#{state.name}"
    end

    # The module *file* and every module it imports.
    private def module_files(file : String) : Set(String)
      @module_files[file] ||= begin
        files = Set{file}
        imported_by(file).each { |other| files << other }
        files
      end
    end

    # Whether *other* is a file an answer about *file* rests on: the
    # module's, one it imports, or the prelude's. A path is compared as
    # `File.expand_path` spells it: std's files are named through the
    # compiler's own `../src`, the prelude's are not.
    private def inside?(file : String, other : String) : Bool
      return true if module_files(file).includes?(other)
      prefix = prelude_prefix(file)
      !prefix.nil? && expanded(other).starts_with?(prefix)
    end

    private def expanded(path : String) : String
      @expanded[path] ||= File.expand_path(path)
    end

    @expanded = {} of String => String

    # Every file of the prelude beside *file*'s std tree, which a key
    # hashes whether or not this program's flags read it.
    private def prelude_files(file : String) : Array(String)
      prefix = prelude_prefix(file)
      return [] of String unless prefix
      @prelude_files[prefix] ||= Dir.glob(Iyi.glob_root(prefix).join("**", "*.iyi")).sort!
    end

    @prelude_files = {} of String => Array(String)

    # The prelude's directory beside the std tree *file* is in, expanded,
    # with a trailing separator.
    private def prelude_prefix(file : String) : String?
      dir = File.dirname(expanded(file))
      @prelude_prefixes.fetch(dir) do
        found = nil
        current = dir
        loop do
          if File.file?(File.join(current, "iyi", "prelude.iyi"))
            found = File.join(current, "iyi") + File::SEPARATOR
            break
          end
          parent = File.dirname(current)
          break if parent == current
          current = parent
        end
        @prelude_prefixes[dir] = found
      end
    end

    private def verdict_path(file : String) : String?
      CacheDir.instance.join("reach-#{module_key(file)}")
    rescue File::Error | IO::Error
      nil
    end

    private def module_key(file : String) : String
      text = String.build do |io|
        io << VERDICT_FORMAT << '\n' << Config.iyi_version << '\n' << compiler_stamp << '\n'
        @program.flags.to_a.sort!.join(io, ' ')
        io << '\n'
        (module_files(file).to_a.sort! + prelude_files(file)).each { |other| io << other << '\t' << digest_of(other) << '\n' }
      end
      ::Crystal::Digest::MD5.hexdigest(text)
    end

    # This compiler, as its executable's size and time: a rebuild is
    # another compiler whatever its version says.
    private def compiler_stamp : String
      path = Process.executable_path
      info = path.try { |exe| File.info?(exe) }
      info ? "#{path}:#{info.size}:#{info.modification_time.to_unix_ns}" : "unknown"
    end

    private def digest_of(file : String) : String
      @digests[file] ||= begin
        ::Crystal::Digest::MD5.hexdigest(File.read(file))
      rescue File::Error | IO::Error
        "unreadable"
      end
    end

    private def load_verdict(file : String) : Verdict?
      path = verdict_path(file)
      return nil unless path && File.file?(path)
      lines = File.read(path).split('\n')
      return nil unless lines.first? == VERDICT_FORMAT
      verdict = Verdict.new
      current = nil
      lines.each_with_index do |line, index|
        next if index.zero?
        return verdict if line == "end"
        fields = line.split('\t')
        case fields[0]?
        when "state"
          return nil unless fields.size == 2
          current = verdict[fields[1]] = Answer.new
        when "call"
          return nil unless current && fields.size == 6
          sets = fields[2, 4].map { |field| field.empty? ? Set(String).new : field.split(VERDICT_SEPARATOR).to_set }
          current.passages << Passage.new(fields[1], sets[0], sets[1], sets[2], sets[3])
        when "dormant"
          return nil unless current && fields.size == 3
          current.dormant << {fields[1], fields[2]}
        else
          return nil
        end
      end
      # Cut short: not one this compiler finished writing.
      nil
    rescue File::Error | IO::Error
      nil
    end

    private def write_verdict(path : String, verdict : Verdict) : Nil
      text = String.build do |io|
        io << VERDICT_FORMAT << '\n'
        verdict.each do |state, answer|
          io << "state\t" << state << '\n'
          answer.passages.each do |passage|
            io << "call\t" << passage.name
            {passage.receiver, passage.family, passage.targets, passage.seen}.each do |set|
              io << '\t'
              set.join(io, VERDICT_SEPARATOR)
            end
            io << '\n'
          end
          answer.dormant.each { |(name, key)| io << "dormant\t" << name << '\t' << key << '\n' }
        end
        io << "end\n"
      end
      temporary = "#{path}.#{Process.pid}.tmp"
      File.write(temporary, text)
      File.rename(temporary, path)
    rescue File::Error | IO::Error
      File.delete?(temporary) if temporary
    end

    # A def as a verdict names it, the same in every build of the same
    # bytes: where it was written (a macro's expansion by the call that
    # expanded it and its place in the expansion) and its name. Not its
    # arity: a call that leaves a default out runs a copy with fewer.
    private def def_key(a_def : Def) : String
      at = a_def.location
      place = at.try(&.expanded_location)
      "#{place.try(&.filename)}:#{place.try(&.line_number)}:#{place.try(&.column_number)}:" \
      "#{at.try(&.line_number)}:#{at.try(&.column_number)}:#{a_def.name}"
    end

    private def def_file(a_def : Def) : String?
      a_def.location.try(&.original_filename)
    end

    private def text_of(node : ASTNode) : String
      @texts[node] ||= node.to_s
    end

    private def type_name(type : Type) : String
      @type_names[type] ||= type.to_s
    end

    # A type as a passage's receiver: its name, and its generic's.
    private def names_of(type : Type) : Set(String)
      names = Set(String).new
      add_names(type, names)
      names
    end

    private def ancestor_names(type : Type) : Set(String)
      @ancestor_names[type] ||= begin
        names = Set(String).new
        type.ancestors.each { |ancestor| add_names(ancestor, names) }
        if type.metaclass? && (instance = type.instance_type) != type
          instance.ancestors.each do |ancestor|
            names << "#{type_name(ancestor)}.class"
            names << "#{type_name(ancestor.generic_type.as(Type))}.class" if ancestor.is_a?(GenericInstanceType)
          end
        end
        names
      end
    end

    private def add_names(type : Type, names : Set(String)) : Nil
      names << type_name(type)
      names << type_name(type.generic_type.as(Type)) if type.is_a?(GenericInstanceType)
    end

    # Every def of the program by name, with the type it is written on.
    private def def_index : Hash(String, Array({Type, Def}))
      @def_index ||= begin
        index = {} of String => Array({Type, Def})
        each_type do |type|
          type.defs.try &.each do |name, list|
            entries = index[name] ||= [] of {Type, Def}
            list.each { |entry| entries << {type, entry.def} }
          end
        end
        index
      end
    end

    private def defs_by_file : Hash(String, Array(Def))
      @defs_by_file ||= begin
        found = {} of String => Array(Def)
        each_type do |type|
          type.defs.try &.each_value do |list|
            list.each do |entry|
              file = def_file(entry.def)
              (found[file] ||= [] of Def) << entry.def if file
            end
          end
        end
        found
      end
    end

    private def macros_by_file : Hash(String, Array(Macro))
      @macros_by_file ||= begin
        found = {} of String => Array(Macro)
        each_type do |type|
          type.macros.try &.each_value do |list|
            list.each do |a_macro|
              file = a_macro.location.try(&.original_filename)
              (found[file] ||= [] of Macro) << a_macro if file
            end
          end
        end
        found
      end
    end

    # The defs the proof read, every typed copy of each, by `def_key`.
    private def walked_defs : Hash(String, Array(Def))
      @walked_defs ||= begin
        found = {} of String => Array(Def)
        @callables.each do |callable|
          a_def = callable.a_def
          (found[def_key(a_def)] ||= [] of Def) << a_def if a_def
        end
        found
      end
    end

    # The program, every type declared in it at any depth, and each one's
    # metaclass, which holds its class methods and macros.
    private def each_type(& : Type ->) : Nil
      stack = [@program.as(Type)]
      @program.file_modules.each_value { |file_module| stack << file_module }
      seen = Set(UInt64).new
      while type = stack.pop?
        next unless seen.add?(type.object_id)
        yield type
        stack << type.metaclass if type.is_a?(ModuleType) && !type.metaclass? && !type.is_a?(Program)
        type.types?.try &.each_value { |inner| stack << inner }
      end
    end
  end
end
