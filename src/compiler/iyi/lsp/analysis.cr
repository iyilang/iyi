# iyi: the analysis behind `iyi lsp` — one real compile per question.
#
# Everything here is the front end iyi already has, pointed at editor
# buffers instead of files. The buffer being asked about travels as the
# `Compiler::Source`; every *other* open buffer travels in
# `iyi_file_overrides`, the one hash the resolver and `import_file`
# consult before the disk — so an import finds what the person sees,
# saved or not. R-1 keeps the unit small enough that "recompile the
# module on every keystroke" is not a compromise, it is the design: no
# incremental state, no invalidation story, no answer a build would not
# give.
#
# Locations translate at this boundary and nowhere else: iyi speaks
# 1-indexed lines and 1-indexed codepoint columns (lexer.cr), LSP speaks
# 0-indexed lines and UTF-16 code units. The two converters below are the
# whole treaty.
require "../compiler"
require "../mod/installer"
require "../tools/context"
require "../tools/implementations"
require "./references"
require "./inlay"
require "./hierarchy"

module Iyi::Lsp
  # One diagnostic, in iyi's own units; the server converts at the edge.
  record Diag,
    line : Int32,
    column : Int32,
    size : Int32,
    message : String,
    spec : Array(String)?,
    related : Array({String, Int32, Int32, String}),
    suggestion : String? = nil

  class Analysis
    # The last result that type-checked, per *open* document. Hover and
    # definition on a buffer that currently does not compile answer from
    # here — mid-edit is the editor's normal state, and a server that
    # goes mute while you type is a server you turn off.
    #
    # Open documents only, released on close, and at most `KEEP` of
    # them — the ones compiled most recently: a `Compiler::Result` is a
    # whole typed program, tens of megabytes, and the workspace walks
    # (references, `workspace/diagnostic`) compile every file under the
    # root. Keeping those too made the server's footprint the project's
    # size times a program — a gigabyte on a medium tree — for a
    # fallback nothing asks of a file nobody has open; and an editor
    # with forty tabs is forty programs for a fallback that only matters
    # in the tab being typed in. A document past the bound simply
    # compiles again when it is next asked about.
    @last_good = {} of String => Compiler::Result
    @open = Set(String).new
    @seed = {} of String => String
    KEEP = 8

    # The directory a workspace keeps its artifacts in — see
    # `artifact_dir_of`. Not configurable, because the alternative to one
    # name is a setting every editor has to be told and no agent knows.
    ARTIFACT_DIR = "mods"

    # The last compile, keyed by exactly what determines it: the path,
    # the buffer, and the sibling buffers. One keystroke triggers
    # diagnostics, then often hover, highlight, inlay hints — the same
    # question compiled four times is the same answer computed once.
    # This is not incremental state: the key *is* the whole input, so a
    # hit can never differ from a recompile.
    @memo_key : {String, UInt64, UInt64}?
    @memo : {Compiler::Result?, Array(Diag)}?

    # Compile one buffer as its own entry, front end only. Returns the
    # typed result and no diagnostics, or nil and what went wrong.
    def check(path : String, text : String, overrides : Hash(String, String)) : {Compiler::Result?, Array(Diag)}
      key = {path, text.hash, overrides.hash}
      if @memo_key == key && (hit = @memo)
        return hit
      end
      answer = compile(path, text, overrides)
      @memo_key = key
      @memo = answer
      answer
    end

    # The server's open set, which is what `@last_good` is allowed to
    # hold. Closing releases the document's typed program.
    def open(path : String) : Nil
      @open << path
    end

    # iyi: the text a buffer was handed over with, kept until the first
    # question about that buffer needs it (`iyi/adopt`).
    #
    # A cursor question in a buffer that does not compile — which is
    # what mid-edit means, and mid-edit is where a person asks — is
    # answered from the last program that did. A fresh worker has none:
    # `Proxy` warms it on the focused file and every other buffer
    # arrives with the text and nothing behind it, so the first
    # completion in one came back empty.
    #
    # A seed rather than a compile at handover: compiling every adopted
    # buffer there put the work in front of whatever the person typed
    # next, and `bench/lsp_latency.py` measured a didChange 32 ms past
    # its 2 s budget. This pays for a buffer only when a question about
    # it actually needs the fallback, and once.
    def seed(path : String, text : String) : Nil
      @seed[path] = text
    end

    def close(path : String) : Nil
      @open.delete(path)
      @last_good.delete(path)
      @seed.delete(path)
      @memo = @memo_key = nil if @memo_key.try(&.[0]) == path
    end

    private def compile(path : String, text : String, overrides : Hash(String, String)) : {Compiler::Result?, Array(Diag)}
      table =
        begin
          Mod::Installer.table_for(File.dirname(path))
        rescue ex : Mod::ModError
          return {nil, [Diag.new(1, 1, 0, ex.message.to_s, nil, [] of {String, Int32, Int32, String})]}
        end

      compiler = Compiler.new
      compiler.prelude = "iyi/prelude"
      compiler.no_codegen = true
      compiler.no_cleanup = true # the visitors read the typed AST after
      compiler.iyi_mod_table = table
      compiler.iyi_file_overrides = overrides
      compiler.stdout = IO::Memory.new
      root = project_root_of(path, text)
      compiler.iyi_project_root = root
      compiler.stderr = IO::Memory.new

      # iyi: the artifacts, where a workspace has them. A library arrives as
      # `.iyimod` files and no source (III.7), and the server compiled
      # imports from source alone — so a workspace that *builds* with
      # `--use-iyimod mods` opened in an editor with `can't find module
      # 'app/base'` on the import line, hover and definition empty, about a
      # module the build compiles against. R-1's own reading of the server
      # is that its inner loop is what `--use-iyimod` already does (SPEC.md
      # IV, "A language server for Crystal is hard for the same reason").
      #
      # `mods` beside the project root, which is the name every example in
      # the tree writes — the README's, the SPEC's, each bench's. Read only
      # for an import that resolves to no source, so a workspace with its
      # sources present is compiled exactly as it was before this, and a
      # directory under some other name leaves the server saying what it
      # said.
      if artifacts = artifact_dir_of(root || File.dirname(path))
        compiler.use_iyimod = artifacts
        compiler.iyi_prefers_source = true
      end

      result = compiler.compile(
        Compiler::Source.new(path, text),
        File.tempname("iyi-lsp", nil))
      if @open.includes?(path)
        @last_good.delete(path)
        @last_good[path] = result
        @last_good.shift if @last_good.size > KEEP
        # The handover's text has nothing left to offer once this
        # buffer has a program of its own again.
        @seed.delete(path)
      end
      {result, [] of Diag}
    rescue ex : CodeError
      {nil, [to_diag(ex, path)]}
    rescue ex : Iyi::Error
      {nil, [Diag.new(1, 1, 0, ex.message.to_s, nil, [] of {String, Int32, Int32, String})]}
    end

    # The typed result to answer a cursor question from: this buffer's
    # compile if it passes, the last one that did otherwise — and, where
    # there is no last one because this worker has only just adopted the
    # buffer, the text it was adopted with, compiled here and once. See
    # `seed`.
    def result_for(path : String, text : String, overrides : Hash(String, String)) : Compiler::Result?
      result, _ = check(path, text, overrides)
      return result if result
      if cached = @last_good[path]?
        return cached
      end
      # Kept until one of the two compiles works: dropping it on a try
      # that failed — a sibling buffer mid-edit is enough — would spend
      # the fallback on the one question that could not use it and
      # leave the buffer silent for the rest of the session. `check`
      # memoises, so asking twice with the same inputs costs once.
      if adopted = @seed[path]?
        seeded, _ = check(path, adopted, overrides)
        if seeded
          @seed.delete(path)
          return seeded
        end
      end
      nil
    end

    def context_at(path : String, text : String, overrides : Hash(String, String), line : Int32, column : Int32) : ContextResult?
      result = result_for(path, text, overrides)
      return nil unless result
      ContextVisitor.new(Location.new(path, line, column)).process(result)
    end

    def implementations_at(path : String, text : String, overrides : Hash(String, String), line : Int32, column : Int32) : ImplementationResult?
      result = result_for(path, text, overrides)
      return nil unless result
      ImplementationsVisitor.new(Location.new(path, line, column)).process(result)
    end

    # One entry's contribution to a references answer. The target names
    # the cursor's file and position; the entry is whichever open
    # document's program we are searching — under R-1 a def's callers
    # live in the *consumers'* compiles, so the server asks this once per
    # open document and merges.
    def references_at(entry_path : String, entry_text : String, overrides : Hash(String, String), target : Location) : ReferencesVisitor?
      result = result_for(entry_path, entry_text, overrides)
      return nil unless result
      visitor = ReferencesVisitor.new(target)
      visitor.process(result) ? visitor : nil
    end

    # Completion: the names the typed graph offers at this cursor. With a
    # receiver, its type's methods, ancestors included; bare, the scope's
    # variables plus `self`'s methods. Items are {label, detail, kind} in
    # LSP's own kind numbers. The buffer mid-word rarely compiles, which
    # is why `result_for` falling back to the last good result is not a
    # convenience here but the feature: completion is a question about
    # the program as it last held together.
    def completion_at(path : String, text : String, overrides : Hash(String, String), line : Int32, column : Int32, receiver : String?) : Array({String, String, Int32})
      result = result_for(path, text, overrides)
      return [] of {String, String, Int32} unless result

      contexts = ContextVisitor.new(Location.new(path, line, column))
        .process(result).contexts
      return [] of {String, String, Int32} unless contexts

      scope = {} of String => Type
      contexts.each { |ctx| ctx.each { |name, type| scope[name] ||= type } }

      if receiver
        type = scope[receiver]?
        return [] of {String, String, Int32} unless type
        methods_of(type, kind: 2) # Method
      else
        items = scope.compact_map do |name, type|
          next if name.includes?(' ') || name.includes?('(')            # call keys
          {name, PrettyTypeNameJsonConverter.pretty_type_name(type), 6} # Variable
        end
        if self_type = scope["self"]?
          items.concat methods_of(self_type, kind: 3) # Function
        end
        items
      end
    end

    # One overload a signature-help answer offers: the label as the
    # author wrote it, each parameter's own spelling (a substring of the
    # label, which is how LSP highlights the active one), and the doc
    # comment if the def carried one.
    record Signature, label : String, params : Array(String), doc : String?

    # Signature help: every overload of `name` callable at this cursor,
    # on `receiver` if the call has one. The buffer mid-call almost never
    # compiles — the `(` just landed — so this rides `result_for`'s last
    # good result and resolves the callee by name through the scope the
    # cursor sits in, the same order a call resolves: the receiver's
    # type's defs, ancestors after, or bare, `self`'s then the module's.
    def signatures_at(path : String, text : String, overrides : Hash(String, String), line : Int32, column : Int32, receiver : String?, name : String) : Array(Signature)
      result = result_for(path, text, overrides)
      return [] of Signature unless result

      contexts = ContextVisitor.new(Location.new(path, line, column))
        .process(result).contexts
      scope = {} of String => Type
      contexts.try &.each { |ctx| ctx.each { |key, type| scope[key] ||= type } }

      defs = [] of Def
      if receiver
        if type = scope[receiver]?
          collect_defs_named(type, name, defs, include_private: false)
        elsif receiver[0]?.try(&.ascii_uppercase?) && (type = result.program.types[receiver]?)
          # `Point.new(` — a call on the type itself answers from its
          # metaclass, where `new` and the class methods live.
          collect_defs_named(type.metaclass, name, defs, include_private: false)
        end
      else
        if self_type = scope["self"]?
          collect_defs_named(self_type, name, defs, include_private: true)
        end
        collect_defs_named(result.program, name, defs, include_private: true)
      end

      # The scope's def tables miss what `using` brought into the
      # module; the typed graph does not. A call by this name that the
      # last good compile already bound knows its overloads exactly.
      if defs.empty?
        defs = CallsNamedVisitor.new(path, name).process(result)
      end

      seen = Set({String, Int32, Int32}).new
      signatures = [] of Signature
      defs.each do |a_def|
        location = a_def.location
        next unless location
        next unless seen.add?({location.filename.to_s, location.line_number, location.column_number})
        signatures << Signature.new(
          signature_of(a_def),
          a_def.args.map(&.to_s),
          a_def.doc)
      end
      signatures
    end

    # Inlay hints: the facts the typed graph holds for this span of the
    # file — inferred types of bare assignments, names of positional
    # literal arguments.
    def inlay_hints_at(path : String, text : String, overrides : Hash(String, String), from_line : Int32, to_line : Int32) : Array(InlayVisitor::Hint)
      result = result_for(path, text, overrides)
      return [] of InlayVisitor::Hint unless result
      InlayVisitor.new(path, from_line, to_line).process(result)
    end

    # Type definition: where the type of the name under the cursor is
    # declared. The name's type comes from the scope; the declaration
    # sites come off the type itself, unions fanning out to every member.
    def type_locations_at(path : String, text : String, overrides : Hash(String, String), line : Int32, column : Int32, word : String?) : Array(Location)
      return [] of Location unless word
      result = result_for(path, text, overrides)
      return [] of Location unless result

      # A type name under the cursor answers with itself.
      if word[0]?.try(&.ascii_uppercase?) && (type = result.program.types[word]?)
        return locations_of(type)
      end

      contexts = ContextVisitor.new(Location.new(path, line, column))
        .process(result).contexts
      scope = {} of String => Type
      contexts.try &.each { |ctx| ctx.each { |key, type| scope[key] ||= type } }
      if type = scope[word]?
        locations_of(type)
      else
        [] of Location
      end
    end

    # Call hierarchy's first question: which written def does the
    # cursor name — the def whose name it sits on, or the resolved
    # targets of the call it sits on. Deduped by source location.
    def hierarchy_targets_at(path : String, text : String, overrides : Hash(String, String), line : Int32, column : Int32) : Array(HierarchySite)
      result = result_for(path, text, overrides)
      return [] of HierarchySite unless result

      seen = Set({String, Int32, Int32}).new
      sites = [] of HierarchySite
      HierarchyTargetVisitor.new(Location.new(path, line, column)).process(result).each do |a_def|
        site = Lsp.site_of(a_def)
        next unless site
        sites << site if seen.add?({site.filename, site.line, site.column})
      end
      sites
    end

    # One entry's incoming edges to the def `key` names. The server
    # asks this once per open document and merges, references-style.
    def incoming_calls_at(entry_path : String, entry_text : String, overrides : Hash(String, String), key : {String, Int32, Int32}) : IncomingCallsVisitor?
      result = result_for(entry_path, entry_text, overrides)
      return nil unless result
      visitor = IncomingCallsVisitor.new(key, entry_path)
      visitor.process(result)
      visitor
    end

    # The outgoing edges of the def `key` names, from its own file's
    # compile — the body lives here, so one compile is the whole answer.
    def outgoing_calls_at(path : String, text : String, overrides : Hash(String, String), key : {String, Int32, Int32}) : OutgoingCallsVisitor?
      result = result_for(path, text, overrides)
      return nil unless result
      visitor = OutgoingCallsVisitor.new(key, path)
      visitor.process(result)
      visitor
    end

    # Implementation: the types that implement the trait under the
    # cursor. An impl became an `include` in the semantic pass, so the
    # implementors are exactly the non-trait types whose ancestors carry
    # the trait — found by walking the program's type tree, no registry.
    def implementors_at(path : String, text : String, overrides : Hash(String, String), word : String?) : Array(Location)
      return [] of Location unless word && word[0]?.try(&.ascii_uppercase?)
      result = result_for(path, text, overrides)
      return [] of Location unless result

      traits = [] of Type
      each_named_type(result.program) do |type|
        traits << type if type.trait? && type.is_a?(NamedType) && type.name == word
      end
      return [] of Location if traits.empty?

      seen = Set({String, Int32, Int32}).new
      locations = [] of Location
      each_named_type(result.program) do |type|
        next if type.trait? || type.metaclass?
        implements = type.ancestors.any? do |ancestor|
          traits.any? do |wanted|
            ancestor == wanted ||
              (ancestor.is_a?(GenericInstanceType) && ancestor.generic_type == wanted)
          end
        end
        next unless implements
        type.locations.try &.each do |location|
          next unless location.filename.is_a?(String)
          key = {location.filename.to_s, location.line_number, location.column_number}
          locations << location if seen.add?(key)
        end
      end
      locations
    end

    # One type as a hierarchy node names it: the short name, where it
    # is declared, and its LSP SymbolKind.
    record TypeSite, name : String, location : Location, kind : Int32

    # Type hierarchy's first question: the types the word under the
    # cursor names.
    def hierarchy_types_named(path : String, text : String, overrides : Hash(String, String), word : String?) : Array(TypeSite)
      return [] of TypeSite unless word && word[0]?.try(&.ascii_uppercase?)
      result = result_for(path, text, overrides)
      return [] of TypeSite unless result
      sites = [] of TypeSite
      types_named(result, word).each { |type| add_site(type, sites) }
      sites
    end

    # Supertypes: the named ancestors — the superclass chain and every
    # trait the type (or its impls) brought in, in resolution order.
    def supertypes_of(path : String, text : String, overrides : Hash(String, String), name : String) : Array(TypeSite)
      result = result_for(path, text, overrides)
      return [] of TypeSite unless result
      sites = [] of TypeSite
      types_named(result, name).each do |type|
        type.ancestors.each do |ancestor|
          if ancestor.is_a?(GenericInstanceType)
            add_site(ancestor.generic_type.as(Type), sites)
          else
            add_site(ancestor, sites)
          end
        end
      end
      sites
    end

    # Subtypes: every type whose ancestors carry the named one — the
    # implementors walk, generalised past traits to any supertype.
    def subtypes_of(path : String, text : String, overrides : Hash(String, String), name : String) : Array(TypeSite)
      result = result_for(path, text, overrides)
      return [] of TypeSite unless result

      wanted_types = types_named(result, name)
      return [] of TypeSite if wanted_types.empty?

      sites = [] of TypeSite
      each_named_type(result.program) do |type|
        next if type.metaclass?
        below = type.ancestors.any? do |ancestor|
          wanted_types.any? do |wanted|
            ancestor == wanted ||
              (ancestor.is_a?(GenericInstanceType) && ancestor.generic_type == wanted)
          end
        end
        add_site(type, sites) if below
      end
      sites
    end

    private def types_named(result : Compiler::Result, name : String) : Array(Type)
      found = [] of Type
      each_named_type(result.program) do |type|
        found << type if type.is_a?(NamedType) && type.name == name && !type.metaclass?
      end
      found
    end

    private def add_site(type : Type, into : Array(TypeSite)) : Nil
      return unless type.is_a?(NamedType)
      location = type.locations.try &.find { |candidate| candidate.filename.is_a?(String) }
      return unless location
      return if into.any? do |site|
                  site.name == type.name &&
                  site.location.filename == location.filename &&
                  site.location.line_number == location.line_number
                end
      into << TypeSite.new(type.name, location, kind_of(type))
    end

    # LSP SymbolKind, from what the type is.
    private def kind_of(type : Type) : Int32
      case type
      when .trait?    then 11 # Interface
      when EnumType   then 10
      when ClassType  then type.struct? ? 23 : 5
      when ModuleType then 2
      else                 5
      end
    end

    private def each_named_type(type : Type, &block : Type ->) : Nil
      type.types?.try &.each_value do |inner|
        block.call inner
        each_named_type(inner, &block)
      end
    end

    # A type's declaration sites, unwrapped the way a person reads the
    # name: virtual and metaclass shells off, a generic instance back to
    # the generic it instantiates, a union to all its members.
    private def locations_of(type : Type) : Array(Location)
      type = type.devirtualize
      return locations_of(type.instance_type) if type.metaclass?
      case type
      when UnionType
        type.union_types.flat_map { |member| locations_of(member) }
      when GenericInstanceType
        locations_of(type.generic_type)
      else
        (type.locations || [] of Location).select { |loc| loc.filename.is_a?(String) }
      end
    end

    # Every overload of `name` on `type`, resolution order: the type,
    # then its ancestors; a union offers what any member offers.
    private def collect_defs_named(type : Type, name : String, into : Array(Def), include_private : Bool) : Nil
      members =
        if type.is_a?(UnionType)
          type.union_types
        else
          [type] of Type
        end
      members.each do |member|
        ([member] + member.ancestors).each do |owner|
          owner.defs.try &.[name]?.try &.each do |item|
            a_def = item.def
            next if a_def.visibility.private? && !include_private
            into << a_def
          end
        end
      end
    end

    # One entry per name, nearest ancestor wins — the same order a call
    # resolves in. `initialize` is `new`'s business and compiler-internal
    # names are nobody's.
    private def methods_of(type : Type, kind : Int32) : Array({String, String, Int32})
      members =
        if type.is_a?(UnionType)
          type.union_types
        else
          [type] of Type
        end

      seen = {} of String => String
      members.each do |member|
        ([member] + member.ancestors).each do |owner|
          owner.defs.try &.each do |name, entries|
            next if name == "initialize" || name.starts_with?("__")
            next if seen.has_key?(name)
            item = entries.first?
            next unless item
            a_def = item.def
            next if a_def.visibility.private?
            seen[name] = signature_of(a_def)
          end
        end
      end
      seen.map { |name, detail| {name, detail, kind} }
    end

    # The signature as the author wrote it: arguments with their
    # restrictions, the return type if stated. Bodies stay home.
    private def signature_of(a_def : Def) : String
      String.build do |io|
        io << a_def.name
        unless a_def.args.empty?
          io << '('
          a_def.args.each_with_index do |arg, index|
            io << ", " unless index.zero?
            arg.to_s(io)
          end
          io << ')'
        end
        if return_type = a_def.return_type
          io << " : "
          return_type.to_s(io)
        end
      end
    end

    # IV.6 read backwards: a module's path is its file's path, so a file
    # whose path ends with its own header's path names the project root
    # above both — and opening `<root>/calc/parser.iyi` resolves its
    # `import calc/lexer` the way a build from `<root>` would. A file
    # whose header and path disagree, or that has no header, keeps the
    # entry-dir rule.
    # iyi: the artifact directory a workspace keeps, or nil.
    #
    # One name, probed. A flag is how a build is told, and there is no flag
    # here: what an editor sends at initialize is a root, so the directory
    # has to be found under it or not at all.
    private def artifact_dir_of(root : String) : String?
      candidate = File.join(root, ARTIFACT_DIR)
      Dir.exists?(candidate) ? candidate : nil
    end

    private def project_root_of(path : String, text : String) : String?
      header = nil
      text.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        header = line
        break
      end
      return nil unless header && header.starts_with?("module ")
      module_path = header.lchop("module ").strip
      return nil if module_path.empty? || module_path.includes?(' ')
      suffix = "/#{module_path}.iyi"
      # Asked of the posix reading, the way `Compiler.header_root_of` asks
      # the same question of a build's entry: a module path is posix by
      # grammar (R-1) and a path is the platform's, so on Windows no file
      # ever ended with its own header and the server kept the entry-dir
      # rule for every one of them. The root is sliced off the path itself,
      # so what comes back is still the platform's spelling — `to_posix`
      # swaps separator for separator and changes no length.
      return nil unless ::Path[path].to_posix.to_s.ends_with?(suffix)
      root = path[0, path.size - suffix.size]
      root.empty? ? "/" : root
    end

    # ── CodeError → Diag ─────────────────────────────────────────────────

    # The exception is a chain: outer frames are the trace ("instantiating
    # 'foo'"), the deepest frame is the cause. The diagnostic lands on the
    # deepest frame *in the edited file* — the place the person can fix —
    # with the deepest message, and the other located frames ride along as
    # related information.
    private def to_diag(ex : CodeError, path : String) : Diag
      frames = [] of {String, Int32, Int32, Int32, String, String?}
      cur : CodeError? = ex
      while cur
        line = nil
        col = 0
        size = 0
        suggestion = nil
        case cur
        when SyntaxException
          line = cur.line_number
          col = cur.column_number
          size = cur.size || 0
        when TypeException
          line = cur.line_number
          col = cur.column_number
          size = cur.size
          suggestion = cur.suggestion
        end
        if line && (msg = cur.message)
          frames << {cur.true_filename, line, col, size, msg, suggestion}
        end
        cur = cur.is_a?(TypeException) ? cur.inner : nil
      end

      deepest_message = ex.is_a?(TypeException) ? ex.deepest_error_message.to_s : ex.message.to_s

      anchor = frames.reverse.find { |(file, _, _, _, _, _)| file == path }
      unless anchor
        # Nothing in this file carries a location: the cause lives in an
        # import. Land on line 1 and say where it really is.
        #
        # The frames come with it. This used to write the far file into the
        # prose and then hand back an empty `related`, so the sentence knew
        # where the error was and the data did not, and every consumer that
        # reads structure rather than English was blind: `iyi fix` finds the
        # file to point at by looking for a frame in another file, found
        # none, and reported no cause at all. The prose and the frames are
        # the same finding and they leave together.
        message = deepest_message
        if far = frames.last?
          message += "\n(in #{far[0]}:#{far[1]})"
        end
        carried = frames.map { |(file, line, col, _, msg, _)| {file, line, col, msg} }
        return Diag.new(1, 1, 0, message, Iyi.iyi_spec_references(message), carried)
      end

      message = anchor[4]
      message += "\n#{deepest_message}" unless deepest_message == message

      related = frames.compact_map do |(file, line, col, _, msg, _)|
        next if file == anchor[0] && line == anchor[1] && col == anchor[2]
        {file, line, col, msg}
      end

      Diag.new(anchor[1], anchor[2], anchor[3], message, Iyi.iyi_spec_references(message), related, anchor[5])
    end
  end

  # Every def a call named `name` in `file` resolved to, off one typed
  # result — the source signature help falls back to when the scope's
  # tables cannot see a `using`-imported name.
  class CallsNamedVisitor < Visitor
    include TypedDefProcessor

    getter defs = [] of Def
    @target_location : Location

    def initialize(@file : String, @name : String)
      @target_location = Location.new(@file, 1, 1)
    end

    def process(result : Compiler::Result) : Array(Def)
      process_result result
      result.node.accept self
      defs
    end

    def process_typed_def(typed_def : Def) : Nil
      typed_def.accept self
    end

    def visit(node : Call)
      if node.name == @name && node.location.try(&.filename) == @file
        node.target_defs.try &.each { |target| @defs << target }
      end
      true
    end

    def visit(node)
      true
    end
  end

  # ── The location treaty: iyi columns ↔ LSP characters ─────────────────

  # LSP 0-indexed UTF-16 character → iyi 1-indexed codepoint column.
  def self.column_of(line_text : String, character : Int32) : Int32
    units = 0
    codepoints = 0
    line_text.each_char do |ch|
      break if units >= character
      units += ch.ord >= 0x10000 ? 2 : 1
      codepoints += 1
    end
    codepoints + 1
  end

  # iyi 1-indexed codepoint column → LSP 0-indexed UTF-16 character.
  def self.character_of(line_text : String, column : Int32) : Int32
    target = column - 1
    units = 0
    line_text.each_char_with_index do |ch, index|
      break if index >= target
      units += ch.ord >= 0x10000 ? 2 : 1
    end
    units
  end
end
