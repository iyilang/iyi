require "../syntax/ast"
require "../stale/reach"
require "../iyimod"

module Iyi
  enum EffectClass
    Observed
    Output
    NotReusable
    Internal
    TaintOnly
  end

  enum EffectKind : UInt8
    # observed (1..8)
    FileRead   = 1_u8
    FileStat   = 2_u8
    FileExists = 3_u8
    DirList    = 4_u8
    EnvGet     = 5_u8
    EnvAll     = 6_u8
    Cwd        = 7_u8
    Host       = 8_u8

    # output (16..18)
    Stdio     = 16_u8
    Exit      = 17_u8
    FileWrite = 18_u8

    # not reusable (32..39)
    Clock         = 32_u8
    Entropy       = 33_u8
    Timer         = 34_u8
    Network       = 35_u8
    Process       = 36_u8
    Signal        = 37_u8
    RuntimeTiming = 38_u8
    CodeLocation  = 39_u8
    DirStream     = 40_u8

    # taint only (48)
    SharedWrite = 48_u8

    # internal (64..72)
    Memory             = 64_u8
    Collector          = 65_u8
    Threads            = 66_u8
    Scheduler          = 67_u8
    SelfImage          = 68_u8
    Console            = 69_u8
    PanicBacktrace     = 70_u8
    TempName           = 71_u8
    ObservationChannel = 72_u8

    def effect_class : EffectClass
      case self
      when FileRead, FileStat, FileExists, DirList, EnvGet, EnvAll, Cwd, Host
        EffectClass::Observed
      when Stdio, Exit, FileWrite
        EffectClass::Output
      when Clock, Entropy, Timer, Network, Process, Signal, RuntimeTiming, CodeLocation, DirStream
        EffectClass::NotReusable
      when SharedWrite
        EffectClass::TaintOnly
      when Memory, Collector, Threads, Scheduler, SelfImage, Console, PanicBacktrace, TempName, ObservationChannel
        EffectClass::Internal
      else
        raise "unknown effect kind #{self}"
      end
    end

    def symbol_name : String
      case self
      when FileRead           then "file_read"
      when FileStat           then "file_stat"
      when FileExists         then "file_exists"
      when DirList            then "dir_list"
      when EnvGet             then "env_get"
      when EnvAll             then "env_all"
      when Cwd                then "cwd"
      when Host               then "host"
      when Stdio              then "stdio"
      when Exit               then "exit"
      when FileWrite          then "file_write"
      when Clock              then "clock"
      when Entropy            then "entropy"
      when Timer              then "timer"
      when Network            then "network"
      when Process            then "process"
      when Signal             then "signal"
      when RuntimeTiming      then "runtime_timing"
      when CodeLocation       then "code_location"
      when DirStream          then "dir_stream"
      when SharedWrite        then "shared_write"
      when Memory             then "memory"
      when Collector          then "collector"
      when Threads            then "threads"
      when Scheduler          then "scheduler"
      when SelfImage          then "self_image"
      when Console            then "console"
      when PanicBacktrace     then "panic_backtrace"
      when TempName           then "temp_name"
      when ObservationChannel then "observation_channel"
      else
        raise "unknown effect kind: #{self}"
      end
    end

    def self.from_symbol?(name : String) : EffectKind?
      case name
      when "file_read"           then FileRead
      when "file_stat"           then FileStat
      when "file_exists"         then FileExists
      when "dir_list"            then DirList
      when "env_get"             then EnvGet
      when "env_all"             then EnvAll
      when "cwd"                 then Cwd
      when "host"                then Host
      when "stdio"               then Stdio
      when "exit"                then Exit
      when "file_write"          then FileWrite
      when "clock"               then Clock
      when "entropy"             then Entropy
      when "timer"               then Timer
      when "network"             then Network
      when "process"             then Process
      when "signal"              then Signal
      when "runtime_timing"      then RuntimeTiming
      when "code_location"       then CodeLocation
      when "dir_stream"          then DirStream
      when "memory"              then Memory
      when "collector"           then Collector
      when "threads"             then Threads
      when "scheduler"           then Scheduler
      when "self_image"          then SelfImage
      when "console"             then Console
      when "panic_backtrace"     then PanicBacktrace
      when "temp_name"           then TempName
      when "observation_channel" then ObservationChannel
      else
        nil
      end
    end
  end

  enum FileWriteOp : UInt8
    Create  = 1_u8
    Delete  = 2_u8
    Rename  = 3_u8
    Mkdir   = 4_u8
    Link    = 5_u8
    Symlink = 6_u8
    Touch   = 7_u8
    Chmod   = 8_u8

    def symbol_name : String
      case self
      when Create  then "create"
      when Delete  then "delete"
      when Rename  then "rename"
      when Mkdir   then "mkdir"
      when Link    then "link"
      when Symlink then "symlink"
      when Touch   then "touch"
      when Chmod   then "chmod"
      else
        raise "unknown op: #{self}"
      end
    end

    def self.from_symbol?(name : String) : FileWriteOp?
      case name
      when "create"  then Create
      when "delete"  then Delete
      when "rename"  then Rename
      when "mkdir"   then Mkdir
      when "link"    then Link
      when "symlink" then Symlink
      when "touch"   then Touch
      when "chmod"   then Chmod
      else
        nil
      end
    end
  end

  class Effect
    getter kind : EffectKind
    getter op : FileWriteOp?

    def initialize(@kind : EffectKind, @op : FileWriteOp? = nil)
    end

    def effect_class : EffectClass
      @kind.effect_class
    end

    def observed? : Bool
      effect_class.observed?
    end

    def output? : Bool
      effect_class.output?
    end

    def not_reusable? : Bool
      effect_class.not_reusable?
    end

    def internal? : Bool
      effect_class.internal?
    end

    def taint_only? : Bool
      effect_class.taint_only?
    end

    def to_s(io : IO) : Nil
      io << "Effect(:" << @kind.symbol_name
      if op = @op
        io << ", :" << op.symbol_name
      end
      io << ")"
    end
  end

  module Effects
    record NotReusableReason,
      category : String,
      reason : String,
      site : String?

    record RG3Site,
      site : String,
      enclosing_def : String?,
      detail : String

    record ClosureResult,
      not_reusable : Array(NotReusableReason),
      rg3_sites : Array(RG3Site) do
      def clean? : Bool
        @not_reusable.empty? && @rg3_sites.empty?
      end

      def reusable? : Bool
        @not_reusable.empty?
      end

      def rg3_clean? : Bool
        @rg3_sites.empty?
      end
    end

    def self.in_runtime_library_file?(program : Program, filename : String?) : Bool
      return false unless filename
      posix = ::Path[filename].to_posix.to_s

      # 1. Under program.iyi_prelude_dir
      if dir = program.iyi_prelude_dir
        posix_dir = ::Path[dir].to_posix.to_s
        return true if posix.starts_with?("#{posix_dir}/")

        # 2. Beside iyi_prelude_dir in std/
        parent_dir = ::Path[File.dirname(dir)].to_posix.to_s
        return true if posix.starts_with?("#{parent_dir}/std/")
      end

      # 3. /std/ source where prelude.iyi exists beside it
      if index = posix.rindex("/std/")
        prelude_test = File.join(posix[0, index], "iyi", "prelude.iyi")
        return true if File.file?(prelude_test)
      end

      # 4. /iyi/ source where prelude.iyi exists
      if index = posix.rindex("/iyi/")
        prelude_test = File.join(posix[0, index], "iyi", "prelude.iyi")
        return true if File.file?(prelude_test)
      end

      # 5. .iyimod artifact of a std module resolved through toolchain std root
      if posix.ends_with?(".iyimod") && File.file?(posix)
        mod_name = program.iyi_artifact_modules[posix]? ||
                   begin
                     IyiMod.read_summary(posix).module_name
                   rescue
                     nil
                   end
        if mod_name && mod_name.starts_with?("std/")
          subpath = mod_name[4..-1]
          if dir = program.iyi_prelude_dir
            std_source = File.join(File.dirname(dir), "std", "#{subpath}.iyi")
            return true if File.file?(std_source)
          end
          program.iyi_path.entries.each do |entry|
            if File.file?(File.join(entry, "iyi", "prelude.iyi")) &&
               File.file?(File.join(entry, "std", "#{subpath}.iyi"))
              return true
            end
          end
        end
      end

      false
    end

    def self.in_runtime_library_file?(program : Program, node : ASTNode) : Bool
      loc = node.location.try(&.expanded_location) || node.location
      file = loc.try(&.read_from.as?(String)) || loc.try(&.filename.as?(String))
      in_runtime_library_file?(program, file)
    end

    def self.in_runtime_library_file?(program : Program, type : Type) : Bool
      loc = type.locations.try(&.first?)
      loc = loc.try(&.expanded_location) || loc
      file = loc.try(&.read_from.as?(String)) || loc.try(&.filename.as?(String))
      in_runtime_library_file?(program, file)
    end

    def self.validate_annotation(ann : Annotation) : Effect
      if (named = ann.named_args) && !named.empty?
        ann.raise "@[Effect] takes no named arguments"
      end

      if ann.args.empty?
        ann.raise "@[Effect] requires at least one argument specifying the effect kind"
      end

      first_arg = ann.args[0]
      unless first_arg.is_a?(SymbolLiteral)
        first_arg.raise "expected first argument of @[Effect] to be a Symbol literal"
      end

      kind_name = first_arg.value
      kind = EffectKind.from_symbol?(kind_name)
      if kind.nil? || kind == EffectKind::SharedWrite
        first_arg.raise "unknown or disallowed effect kind :#{kind_name}"
      end

      if kind == EffectKind::FileWrite
        if ann.args.size < 2
          ann.raise "@[Effect(:file_write)] requires an operation argument (create, delete, rename, mkdir, link, symlink, touch, chmod)"
        end
        if ann.args.size > 2
          ann.raise "too many arguments for @[Effect(:file_write)] (expected 2)"
        end
        second_arg = ann.args[1]
        unless second_arg.is_a?(SymbolLiteral)
          second_arg.raise "expected second argument of @[Effect(:file_write)] to be a Symbol literal"
        end
        op_name = second_arg.value
        op = FileWriteOp.from_symbol?(op_name)
        if op.nil?
          second_arg.raise "unknown file_write operation :#{op_name} (expected create, delete, rename, mkdir, link, symlink, touch, or chmod)"
        end
        Effect.new(kind, op)
      else
        if ann.args.size > 1
          ann.raise "too many arguments for @[Effect(:#{kind_name})] (expected 1)"
        end
        Effect.new(kind)
      end
    end

    # Whether a call to *a_def* gives its caller a value: anything but Nil or
    # NoReturn. An untyped def is assumed to, which errs toward opacity.
    def self.hands_value?(a_def : Def) : Bool
      type = a_def.type?
      return true unless type
      !(type.nil_type? || type.no_return?)
    end

    def self.format_site(program : Program, location : Location?) : String
      return "src:<unknown>:0" unless location
      loc = location.expanded_location || location
      raw_file = loc.read_from.as?(String) || loc.filename.as?(String)
      line = loc.line_number

      return "src:main.iyi:#{line}" if raw_file.nil? || raw_file.empty? || raw_file == "eval"

      posix = ::Path[raw_file].to_posix.to_s

      # Toolchain root
      if dir = program.iyi_prelude_dir
        posix_dir = ::Path[dir].to_posix.to_s
        if posix.starts_with?("#{posix_dir}/")
          rel = "iyi/#{posix[posix_dir.size + 1..-1]}"
          rel = rel[2..-1] if rel.starts_with?("./")
          return "toolchain:#{rel}:#{line}"
        end

        parent_dir = ::Path[File.dirname(dir)].to_posix.to_s
        std_prefix = "#{parent_dir}/std/"
        if posix.starts_with?(std_prefix)
          rel = "std/#{posix[std_prefix.size..-1]}"
          rel = rel[2..-1] if rel.starts_with?("./")
          return "toolchain:#{rel}:#{line}"
        end
      end

      if index = posix.rindex("/std/")
        prelude_test = File.join(posix[0, index], "iyi", "prelude.iyi")
        if File.file?(prelude_test)
          rel = posix[index + 1..-1]
          return "toolchain:#{rel}:#{line}"
        end
      end

      if index = posix.rindex("/iyi/")
        prelude_test = File.join(posix[0, index], "iyi", "prelude.iyi")
        if File.file?(prelude_test)
          rel = posix[index + 1..-1]
          return "toolchain:#{rel}:#{line}"
        end
      end

      if posix.ends_with?(".iyimod") && File.file?(posix)
        mod_name = program.iyi_artifact_modules[posix]? ||
                   begin
                     IyiMod.read_summary(posix).module_name
                   rescue
                     nil
                   end
        if mod_name && mod_name.starts_with?("std/")
          return "toolchain:#{mod_name}.iyi:#{line}"
        end
      end
      # Program root (src)
      entry_root = program.iyi_project_root || program.filename.try { |f| File.dirname(f) } || Dir.current
      posix_entry = ::Path[entry_root].to_posix.to_s
      if posix.starts_with?("#{posix_entry}/")
        rel = posix[posix_entry.size + 1..-1]
        rel = rel[2..-1] if rel.starts_with?("./")
        return "src:#{rel}:#{line}"
      end

      if File.exists?(raw_file)
        rel = ::Path[raw_file].relative_to(Dir.current).to_posix.to_s
        unless rel.starts_with?("..")
          rel = rel[2..-1] if rel.starts_with?("./")
          return "src:#{rel}:#{line}"
        end
      end

      # Fallback: relative path without leading ./ or abs
      if !posix.starts_with?("/")
        posix = posix[2..-1] if posix.starts_with?("./")
        "src:#{posix}:#{line}"
      else
        "abs:#{posix}:#{line}"
      end
    end

    class ClosureVisitor < Visitor
      getter not_reusable : Array(NotReusableReason)
      getter rg3_sites : Array(RG3Site)

      @program : Program
      @in_runtime_file : Bool
      @enclosing_def : Def?
      @is_enclosing_def_annotated : Bool
      @visited_nodes : Set(UInt64)

      def initialize(@program : Program,
                     @in_runtime_file : Bool,
                     @enclosing_def : Def? = nil,
                     @is_enclosing_def_annotated : Bool = false)
        @not_reusable = [] of NotReusableReason
        @rg3_sites = [] of RG3Site
        @visited_nodes = Set(UInt64).new
      end

      private def in_runtime?(node : ASTNode) : Bool
        if @in_runtime_file
          true
        elsif def_node = @enclosing_def
          Effects.in_runtime_library_file?(@program, def_node)
        else
          Effects.in_runtime_library_file?(@program, node)
        end
      end

      def visit(node : ASTNode)
        # Avoid infinite recursion or redundant traversals on identical nodes
        return false unless @visited_nodes.add?(node.object_id)
        true
      end

      def visit(node : FileNode)
        old_runtime = @in_runtime_file
        @in_runtime_file = Effects.in_runtime_library_file?(@program, node)
        node.node.accept(self)
        @in_runtime_file = old_runtime
        false
      end

      def visit(node : Asm)
        site = Effects.format_site(@program, node.location)
        if in_runtime?(node)
          unless @is_enclosing_def_annotated
            def_name = @enclosing_def.try(&.name) || @enclosing_def.try(&.to_s)
            @rg3_sites << RG3Site.new(site, def_name, "asm")
            @not_reusable << NotReusableReason.new("internal", "unclassified runtime site", site)
          end
        else
          @not_reusable << NotReusableReason.new("opaque program construct", "asm", site)
        end
        true
      end

      def visit(node : Call)
        return false unless @visited_nodes.add?(node.object_id)

        is_rt = in_runtime?(node)

        if target_defs = node.target_defs
          target_defs.each do |target_def|
            if target_def.is_a?(External) || target_def.owner.is_a?(LibType)
              next if target_def.is_a?(External) && target_def.real_name.starts_with?("llvm.")

              is_global = target_def.is_a?(External) && target_def.external_var? ||
                          target_def.body.as?(Primitive).try(&.name.in?("external_var_get", "external_var_set"))
              site = Effects.format_site(@program, node.location || target_def.location)
              if is_rt
                unless @is_enclosing_def_annotated
                  def_name = @enclosing_def.try(&.name) || @enclosing_def.try(&.to_s)
                  real_or_name = target_def.is_a?(External) ? target_def.real_name : target_def.name
                  detail = is_global ? "lib global: #{real_or_name}" : "lib fun call: #{real_or_name}"
                  @rg3_sites << RG3Site.new(site, def_name, detail)
                  @not_reusable << NotReusableReason.new("internal", "unclassified runtime site", site)
                end
              else
                what = is_global ? "lib global" : "lib call"
                @not_reusable << NotReusableReason.new("opaque program construct", what, site)
              end
            end

            unless is_rt
              if target_def.body.as?(Primitive).try(&.name) == "pointer_new"
                site = Effects.format_site(@program, node.location || target_def.location)
                @not_reusable << NotReusableReason.new("opaque program construct", "pointer_new", site)
              end

              # An internal def is opaque to a program only when it hands the
              # program a value. One that returns Nil or never returns (`raise`,
              # the collector's `enable`/`disable`/`collect`) leaves nothing a
              # verdict can read beyond what A2 already calls unspecified;
              # accessors that return machine or timing values carry a
              # not-reusable kind instead (D6).
              if Effects.in_runtime_library_file?(@program, target_def) && target_def.effect.try(&.internal?) && Effects.hands_value?(target_def)
                site = Effects.format_site(@program, node.location)
                @not_reusable << NotReusableReason.new("opaque program construct", "call to internal def: #{target_def.name}", site)
              end
            end
          end
        end

        true
      end

      def visit(node : Primitive)
        unless in_runtime?(node)
          if node.name == "pointer_new"
            site = Effects.format_site(@program, node.location)
            @not_reusable << NotReusableReason.new("opaque program construct", "pointer_new", site)
          end
        end
        true
      end

      def visit(node : ExternalVar)
        site = Effects.format_site(@program, node.location)
        if in_runtime?(node)
          unless @is_enclosing_def_annotated
            def_name = @enclosing_def.try(&.name) || @enclosing_def.try(&.to_s)
            @rg3_sites << RG3Site.new(site, def_name, "lib global: #{node.name}")
            @not_reusable << NotReusableReason.new("internal", "unclassified runtime site", site)
          end
        else
          @not_reusable << NotReusableReason.new("opaque program construct", "lib global", site)
        end
        true
      end

      def visit(node : Def)
        # Avoid recursing into nested def declarations (handled per Element)
        false
      end

      def visit(node : FunDef)
        false
      end

      def visit(node : LibDef)
        false
      end

      def visit(node : ClassDef)
        false
      end

      def visit(node : ModuleDef)
        false
      end

      def visit(node : CStructOrUnionDef)
        false
      end

      def visit(node : EnumDef)
        false
      end

      def visit(node : Alias)
        false
      end

      def visit(node : TypeDef)
        false
      end

      def visit(node : Macro)
        false
      end
    end

    def self.closure_check(program : Program, reach : Stale::Reach) : ClosureResult
      not_reusable = [] of NotReusableReason
      rg3_sites = [] of RG3Site
      visited_elements = Set(UInt64).new

      reach.elements.each do |element|
        case element.kind
        when Stale::ElementKind::Def
          node = element.node
          if node.is_a?(Def)
            next unless visited_elements.add?(node.object_id)
            in_runtime = in_runtime_library_file?(program, node)
            annotated = node.effect != nil
            if in_runtime
              unless annotated
                visitor = ClosureVisitor.new(program, in_runtime_file: true, enclosing_def: node, is_enclosing_def_annotated: false)
                node.body.accept(visitor)
                not_reusable.concat(visitor.not_reusable)
                rg3_sites.concat(visitor.rg3_sites)
              end
            else
              visitor = ClosureVisitor.new(program, in_runtime_file: false, enclosing_def: node, is_enclosing_def_annotated: false)
              node.body.accept(visitor)
              not_reusable.concat(visitor.not_reusable)
            end
          elsif node.is_a?(ProcLiteral)
            next unless visited_elements.add?(node.object_id)
            in_runtime = in_runtime_library_file?(program, node)
            visitor = ClosureVisitor.new(program, in_runtime_file: in_runtime, enclosing_def: nil, is_enclosing_def_annotated: false)
            node.def.body.accept(visitor)
            not_reusable.concat(visitor.not_reusable)
            rg3_sites.concat(visitor.rg3_sites) if in_runtime
          end
        when Stale::ElementKind::Main
          node = element.node
          if node
            next unless visited_elements.add?(node.object_id)
            visitor = ClosureVisitor.new(program, in_runtime_file: false)
            node.accept(visitor)
            not_reusable.concat(visitor.not_reusable)
          end
        when Stale::ElementKind::Const
          node = element.node
          if node
            next unless visited_elements.add?(node.object_id)
            in_runtime = in_runtime_library_file?(program, node)
            visitor = ClosureVisitor.new(program, in_runtime_file: in_runtime)
            node.accept(visitor)
            not_reusable.concat(visitor.not_reusable)
            rg3_sites.concat(visitor.rg3_sites) if in_runtime
          end
        when Stale::ElementKind::ClassVar
          node = element.node
          if node
            next unless visited_elements.add?(node.object_id)
            in_runtime = in_runtime_library_file?(program, node)
            visitor = ClosureVisitor.new(program, in_runtime_file: in_runtime)
            node.accept(visitor)
            not_reusable.concat(visitor.not_reusable)
            rg3_sites.concat(visitor.rg3_sites) if in_runtime
          end
        when Stale::ElementKind::IvarInit
          if type = element.self_type
            if type.is_a?(ClassType) || type.is_a?(GenericClassInstanceType)
              if inits = type.instance_vars_initializers
                in_runtime = in_runtime_library_file?(program, type)
                inits.each do |init|
                  next unless visited_elements.add?(init.value.object_id)
                  visitor = ClosureVisitor.new(program, in_runtime_file: in_runtime)
                  init.value.accept(visitor)
                  not_reusable.concat(visitor.not_reusable)
                  rg3_sites.concat(visitor.rg3_sites) if in_runtime
                end
              end
            end
          end
        else
          # Fun, LibFun, Type, ObjectUnit do not carry executable bodies directly
        end
      end

      # Deduplicate not_reusable and rg3_sites
      seen_nr = Set(Tuple(String, String, String?)).new
      unique_nr = [] of NotReusableReason
      not_reusable.each do |nr|
        key = {nr.category, nr.reason, nr.site}
        unless seen_nr.includes?(key)
          seen_nr << key
          unique_nr << nr
        end
      end

      seen_rg3 = Set(Tuple(String, String?, String)).new
      unique_rg3 = [] of RG3Site
      rg3_sites.each do |entry|
        key = {entry.site, entry.enclosing_def, entry.detail}
        unless seen_rg3.includes?(key)
          seen_rg3 << key
          unique_rg3 << entry
        end
      end

      ClosureResult.new(unique_nr, unique_rg3)
    end
  end
end
