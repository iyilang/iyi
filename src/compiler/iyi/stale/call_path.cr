require "./encoding"
require "./reach"
require "./roots"
require "json"

module Iyi::Stale
  struct DumpRow
    include JSON::Serializable

    getter kind : String
    getter key : String
    getter digest : String
    getter file : String?
    getter line : Int32?
    getter end_line : Int32?

    def initialize(@kind : String, @key : String, @digest : String,
                   @file : String?, @line : Int32?, @end_line : Int32?)
    end
  end

  class CallPathResult
    getter digest : Digest
    getter element_digests : Hash(String, Digest)
    getter explain : Hash(String, Digest)
    getter ambiguous_keys : Array(String)
    getter dump_rows : Array(DumpRow)

    def initialize(@digest : Digest,
                   @element_digests : Hash(String, Digest),
                   @explain : Hash(String, Digest),
                   @ambiguous_keys : Array(String),
                   @dump_rows : Array(DumpRow))
    end

    def hex_digest : String
      Stale.hex(@digest)
    end

    def ambiguous? : Bool
      !@ambiguous_keys.empty?
    end
  end

  module CallPath
    def self.canonical_type_name(type : Type) : String
      String.build do |io|
        canonical_type_name(type, io)
      end
    end

    def self.canonical_type_name(type : Type, io : IO) : Nil
      case type
      when NilType
        io << "Nil"
      when VoidType
        io << "Void"
      when BoolType
        io << "Bool"
      when CharType
        io << "Char"
      when IntegerType
        io << type.name
      when FloatType
        io << type.name
      when SymbolType
        io << "Symbol"
      when NoReturnType
        io << "NoReturn"
      when PrimitiveType
        io << type.name
      when UnionType
        # Sort members by canonical name recursively regardless of stored order
        member_names = type.union_types.map { |m| canonical_type_name(m) }.sort!
        io << '('
        member_names.each_with_index do |name, i|
          io << " | " if i > 0
          io << name
        end
        io << ')'
      when VirtualType
        canonical_type_name(type.base_type, io)
        io << '+'
      when MetaclassType, VirtualMetaclassType, GenericClassInstanceMetaclassType, GenericModuleInstanceMetaclassType
        canonical_type_name(type.instance_type, io)
        io << ".class"
      when TupleInstanceType
        io << "Tuple("
        type.tuple_types.each_with_index do |elem_type, i|
          io << ", " if i > 0
          canonical_type_name(elem_type, io)
        end
        io << ')'
      when NamedTupleInstanceType
        io << "NamedTuple("
        type.entries.each_with_index do |entry, i|
          io << ", " if i > 0
          Symbol.quote_for_named_argument(io, entry.name)
          io << ": "
          canonical_type_name(entry.type, io)
        end
        io << ')'
      when ProcInstanceType
        io << "Proc("
        type.arg_types.each do |arg_type|
          canonical_type_name(arg_type, io)
          io << ", "
        end
        canonical_type_name(type.return_type, io)
        io << ')'
      when StaticArrayInstanceType
        io << "StaticArray("
        canonical_type_name(type.element_type, io)
        io << ", "
        io << type.size
        io << ')'
      when PointerInstanceType
        io << "Pointer("
        canonical_type_name(type.element_type, io)
        io << ')'
      when GenericClassInstanceType, GenericModuleInstanceType
        io << type.generic_type.full_name
        io << '('
        type.type_vars.each_with_index do |(_, type_var), i|
          io << ", " if i > 0
          if type_var.is_a?(Var)
            canonical_type_name(type_var.type, io)
          else
            io << type_var.to_s
          end
        end
        io << ')'
      when TypeDefType
        io << type.name
      when AliasType
        io << type.full_name
      when ClassType, ModuleType, EnumType
        io << type.full_name
      else
        io << type.to_s
      end
    end

    def self.canonical_def_key(target_def : Def, owner : Type) : String
      String.build do |str|
        str << '*'
        orig_owner = target_def.original_owner? || owner
        def_owner = target_def.owner? || owner
        if def_owner.metaclass?
          str << canonical_type_name(owner.instance_type)
          if orig_owner != owner
            str << '@' << canonical_type_name(orig_owner.instance_type)
          end
          str << "::"
        elsif !def_owner.is_a?(Iyi::Program)
          str << canonical_type_name(owner)
          if orig_owner != owner
            str << '@' << canonical_type_name(orig_owner)
          end
          str << '#'
        end

        str << target_def.name.gsub('@', '.')

        next_def = target_def.next
        while next_def
          str << '\''
          next_def = next_def.next
        end

        if target_def.args.size > 0 || target_def.uses_block_arg?
          str << '<'
          if target_def.args.size > 0
            target_def.args.each_with_index do |arg, i|
              str << ", " if i > 0
              str << canonical_type_name(arg.type)
            end
          end
          if target_def.uses_block_arg?
            str << ", " if target_def.args.size > 0
            str << '&'
            str << canonical_type_name(target_def.block_arg.not_nil!.type)
          end
          str << '>'
        end

        if return_type = target_def.type?
          str << ':'
          str << canonical_type_name(return_type)
        end
      end
    end

    def self.close_type_set(initial_types : Enumerable(Type)) : Array(Type)
      seen = Set(Type).new
      queue = [] of Type
      initial_types.each do |t|
        base = t.is_a?(VirtualType) ? t.base_type : t
        queue << base
      end

      while !queue.empty?
        t = queue.pop
        base = t.is_a?(VirtualType) ? t.base_type : t
        next if seen.includes?(base)
        seen << base

        if (base.is_a?(ClassType) || base.is_a?(GenericClassInstanceType)) && (sc = base.superclass)
          queue << sc
        end

        if parents = base.parents
          parents.each do |parent|
            queue << parent
          end
        end

        if base.is_a?(InstanceVarContainer)
          base.all_instance_vars.each_value do |ivar|
            if ivar_type = ivar.type?
              queue << ivar_type
            end
          end
        end

        if base.is_a?(EnumType)
          queue << base.base_type
        end

        if base.is_a?(TupleInstanceType)
          base.tuple_types.each { |tt| queue << tt }
        elsif base.is_a?(NamedTupleInstanceType)
          base.entries.each { |entry| queue << entry.type }
        elsif base.is_a?(StaticArrayInstanceType)
          queue << base.element_type
        elsif base.is_a?(PointerInstanceType)
          queue << base.element_type
        elsif base.is_a?(ProcInstanceType)
          base.arg_types.each { |at| queue << at }
          queue << base.return_type
        elsif base.is_a?(GenericClassInstanceType) || base.is_a?(GenericModuleInstanceType)
          base.type_vars.each_value do |tv|
            queue << tv.type if tv.is_a?(Var)
          end
        end

        if base.is_a?(VirtualType)
          base.each_concrete_type do |concrete_type|
            queue << concrete_type
          end
        elsif base.is_a?(ClassType) && (base.virtual_type_made? || base.abstract?)
          if base.virtual_type_made?
            vt = base.virtual_type!
            if vt.is_a?(VirtualType)
              vt.each_concrete_type do |concrete_type|
                queue << concrete_type
              end
            end
          end
          if base.abstract?
            base.subclasses.each do |subclass|
              queue << subclass unless subclass.abstract?
            end
          end
        end

        if base.is_a?(TypeDefType)
          queue << base.typedef
        end

        if base.is_a?(UnionType)
          base.union_types.each { |m| queue << m }
        end

        if base.is_a?(AliasType)
          queue << base.aliased_type
        end
      end

      seen.to_a.sort_by { |t| canonical_type_name(t) }
    end

    def self.compute(program : Program, reach : Reach, roots : Roots) : CallPathResult
      # 1. Closed type set
      initial_types = Set(Type).new
      reach.elements.each do |elem|
        if t = elem.type
          initial_types << t
        end
        if st = elem.self_type
          initial_types << st
        end
      end

      closed_types = close_type_set(initial_types)
      type_elements = closed_types.map do |t|
        Element.new(
          ElementKind::Type,
          canonical_type_name(t),
          nil,
          t,
          nil,
          t.locations.try &.first?
        )
      end

      # Combine reach elements with closed types
      all_elements = [] of Element
      reach.elements.each do |elem|
        # Proc literals bodies are encoded in place inside their containing element,
        # not as top-level Def elements (build-spec line 213, D17)
        next if elem.node.is_a?(ProcLiteral)

        canonical_key = case elem.kind
                        when ElementKind::Def
                          if elem.node.is_a?(Def)
                            td = elem.node.as(Def)
                            canonical_def_key(td, elem.self_type || td.owner)
                          else
                            elem.key
                          end
                        when ElementKind::Type
                          if t = elem.type
                            canonical_type_name(t)
                          else
                            elem.key
                          end
                        when ElementKind::IvarInit
                          if st = elem.self_type
                            canonical_type_name(st)
                          else
                            elem.key
                          end
                        else
                          elem.key
                        end

        all_elements << Element.new(
          elem.kind,
          canonical_key,
          elem.node,
          elem.type,
          elem.self_type,
          elem.location
        )
      end

      # Add type elements if not already present
      type_elements.each do |te|
        unless all_elements.any? { |e| e.kind == ElementKind::Type && e.key == te.key }
          all_elements << te
        end
      end

      # 2. Encode each element
      element_digests = Hash(String, Digest).new
      digests_by_key = Hash(Tuple(ElementKind, String), Array(Digest)).new
      encoded_elements = [] of {Element, Digest}

      all_elements.each do |elem|
        enc_result = Stale.d(elem.kind.to_s.underscore) do |encoder|
          typed_encoder = TypedEncoder.new(program, roots, elem, encoder)
          typed_encoder.encode_element(elem)
        end
        key_tuple = {elem.kind, elem.key}
        list = (digests_by_key[key_tuple] ||= [] of Digest)
        list << enc_result

        element_digests[elem.key] = enc_result
        encoded_elements << {elem, enc_result}
      end

      # 3. Detect ambiguous keys
      ambiguous_keys = [] of String
      digests_by_key.each do |(kind, key), digests|
        if digests.size > 1 && digests.uniq.size > 1
          ambiguous_keys << key unless ambiguous_keys.includes?(key)
        end
      end

      # 4. Deduplicate unique elements by (kind, key, digest)
      unique_elements = [] of {Element, Digest}
      seen_keys = Set(Tuple(ElementKind, String, Digest)).new
      encoded_elements.each do |item|
        elem, dig = item
        tuple = {elem.kind, elem.key, dig}
        unless seen_keys.includes?(tuple)
          seen_keys << tuple
          unique_elements << item
        end
      end

      # Sort elements by (kind, key)
      unique_elements.sort_by! do |item|
        elem, _ = item
        {elem.kind.value, elem.key}
      end

      # 5. Compute CallPathFp = D("callpath", elements sorted by (kind, key))
      callpath_fp = Stale.d("callpath") do |enc|
        enc.list(unique_elements.size) do |e|
          unique_elements.each do |item|
            elem, dig = item
            e.str(elem.kind.to_s.underscore)
            e.str(elem.key)
            e.digest(dig)
          end
        end
      end

      # 6. Compute explain: per file under src, toolchain or pkg, and "*"
      elements_by_file = Hash(String, Array(Digest)).new
      dump_rows = [] of DumpRow

      unique_elements.each do |item|
        elem, dig = item
        loc = elem.location
        loc_file = loc.try(&.original_filename.to_s)
        loc_line = loc.try(&.line_number)
        loc_end_line = elem.node.try(&.end_location.try(&.line_number)) || loc_line

        dump_rows << DumpRow.new(
          kind: elem.kind.to_s.underscore,
          key: elem.key,
          digest: Stale.hex(dig),
          file: loc_file,
          line: loc_line,
          end_line: loc_end_line
        )

        file_key = "*"
        if loc && (fn = loc.filename) && fn.is_a?(String)
          mapped = roots.map(fn)
          if mapped.root == "src" || mapped.root == "toolchain" || mapped.root == "pkg"
            file_key = "#{mapped.root}:#{mapped.path}"
          end
        end

        (elements_by_file[file_key] ||= [] of Digest) << dig
      end

      explain = Hash(String, Digest).new
      elements_by_file.each do |f_key, digests|
        digests.sort! do |d1, d2|
          d1.to_slice <=> d2.to_slice
        end
        file_dig = Stale.d("explain") do |enc|
          enc.list(digests.size) do |e|
            digests.each do |d|
              e.digest(d)
            end
          end
        end
        explain[f_key] = file_dig
      end

      CallPathResult.new(callpath_fp, element_digests, explain, ambiguous_keys, dump_rows)
    end
  end

  class TypedEncoder
    getter encoder : Encoder
    getter program : Program
    getter roots : Roots
    getter current_element : Element
    getter temp_ordinals : Hash(String, Int32)

    @debug_main : File? = nil

    def initialize(@program : Program, @roots : Roots, @current_element : Element, @encoder : Encoder)
      @temp_ordinals = Hash(String, Int32).new
      @next_temp_ordinal = 0
      if @current_element.kind == ElementKind::Main
        mode = ENV["IYI_WARM"]? ? "warm" : "norm"
        @debug_main = File.open("/tmp/main_#{mode}.log", "w")
      end
    end

    def encode_element(element : Element) : Nil
      collector = TempCollector.new(self)
      if node = element.node
        if node.is_a?(Def)
          node.args.each do |a|
            register_temp_name(a.name)
            a.default_value.try &.accept(collector)
          end
          node.body.accept(collector)
        elsif element.kind == ElementKind::Main && node.is_a?(Expressions)
          active = filter_codegen_expressions(node.expressions)
          active.each { |e| e.accept(collector) }
        else
          node.accept(collector)
        end
      end

      case element.kind
      when ElementKind::Main
        if node = element.node
          encode_node(node)
        else
          @encoder.absent
        end
        @debug_main.try &.close
      when ElementKind::Def
        if node = element.node
          target_def = node.as(Def)
          self_type = element.self_type || target_def.owner
          encode_def(target_def, self_type)
        else
          @encoder.str(element.key)
        end
      when ElementKind::Fun
        if node = element.node
          fun_def = node.as(FunDef)
          @encoder.str(element.key)
          encode_node(fun_def.body)
        else
          @encoder.str(element.key)
        end
      when ElementKind::LibFun
        if node = element.node
          if node.is_a?(External)
            encode_external(node)
          elsif node.is_a?(Def)
            encode_def(node, element.self_type || node.owner)
          else
            @encoder.str(element.key)
          end
        else
          @encoder.str(element.key)
        end
      when ElementKind::Const
        @encoder.str(element.key)
        if node = element.node
          encode_node(node)
        else
          @encoder.absent
        end
      when ElementKind::ClassVar
        @encoder.str(element.key)
        if node = element.node
          encode_node(node)
        else
          @encoder.absent
        end
      when ElementKind::IvarInit
        @encoder.str(element.key)
        st = element.self_type
        if (st.is_a?(ClassType) || st.is_a?(GenericClassInstanceType)) && (initializers = st.instance_vars_initializers)
          @encoder.list(initializers.size) do
            initializers.each do |init|
              @encoder.str(init.name)
              encode_node(init.value)
            end
          end
        else
          @encoder.list(0)
        end
      when ElementKind::ObjectUnit
        @encoder.str(element.key)
      when ElementKind::Type
        if node = element.node
          encode_node(node)
        elsif type = element.type
          encode_type_element(type)
        else
          @encoder.str(element.key)
        end
      end
    end

    def encode_external(node : External) : Nil
      @encoder.str(node.name)
      @encoder.str(node.real_name)
      encode_type(node.type?)
      @encoder.list(node.args.size) do
        node.args.each do |arg|
          @encoder.str(arg.name)
          encode_type(arg.type?)
        end
      end
      @encoder.bool(node.varargs?)
    end

    private class TempCollector < Visitor
      def initialize(@encoder : TypedEncoder)
      end

      def visit(node : Var)
        @encoder.register_temp_name(node.name)
        true
      end

      def visit(node : MetaVar)
        @encoder.register_temp_name(node.name)
        true
      end

      def visit(node : MetaTypeVar)
        @encoder.register_temp_name(node.name)
        true
      end

      def visit(node : Arg)
        @encoder.register_temp_name(node.name)
        true
      end
      def visit(node : ASTNode)
        true
      end
    end

    def register_temp_name(name : String) : Nil
      if compiler_temp_name?(name)
        @temp_ordinals.put_if_absent(name) do
          ord = @next_temp_ordinal
          @next_temp_ordinal += 1
          ord
        end
      end
    end

    def encode_def(target_def : Def, self_type : Type) : Nil
      collector = TempCollector.new(self)
      target_def.args.each do |a|
        register_temp_name(a.name)
        a.default_value.try &.accept(collector)
      end
      target_def.body.accept(collector)

      @encoder.str(CallPath.canonical_type_name(target_def.owner))
      @encoder.str(CallPath.canonical_type_name(self_type))
      @encoder.list(target_def.args.size) do
        target_def.args.each do |arg|
          encode_var_name(arg.name)
          encode_type(arg.type?)
          if dv = arg.default_value
            encode_node(dv)
          else
            @encoder.absent
          end
        end
      end

      if block_arg = target_def.block_arg
        @encoder.str(block_arg.name)
        encode_type(block_arg.type?)
      else
        @encoder.absent
      end

      encode_type(target_def.type?)

      if free_vars = target_def.free_vars
        @encoder.list(free_vars.size) do
          free_vars.each do |fv|
            @encoder.str(fv)
            if (bounds = target_def.free_var_bounds) && (b = bounds[fv]?)
              encode_node(b)
            else
              @encoder.absent
            end
          end
        end
      else
        @encoder.list(0)
      end

      if vars = target_def.vars
        sorted_vars = vars.to_a.sort_by do |name, _|
          if compiler_temp_name?(name)
            ord = @temp_ordinals.put_if_absent(name) do
              val = @next_temp_ordinal
              @next_temp_ordinal += 1
              val
            end
            {1, ord, ""}
          else
            {0, 0, name}
          end
        end
        @encoder.list(sorted_vars.size) do
          sorted_vars.each do |var_name, var|
            encode_var_name(var_name)
            encode_type(var.type?)
            @encoder.bool(var.closured?)
          end
        end
      else
        @encoder.list(0)
      end

      @encoder.bool(target_def.raises?)

      if anns = target_def.annotations
        total = anns.values.sum(&.size)
        @encoder.list(total) do
          anns.each do |_ann_type, ann_list|
            ann_list.each do |ann|
              @encoder.str(ann.path.to_s)
              @encoder.list(ann.args.size) { ann.args.each { |a| encode_node(a) } }
            end
          end
        end
      else
        @encoder.list(0)
      end

      @encoder.bool(target_def.is_a?(External))
      @encoder.bool(target_def.macro_def?)
      @encoder.bool(target_def.abstract?)
      @encoder.bool(target_def.exported?)
      @encoder.bool(target_def.iyi_from_impl?)
      @encoder.bool(target_def.iyi_from_artifact?)

      encode_node(target_def.body)
    end

    def encode_type_element(type : Type) : Nil
      @encoder.tag(type.class.name.split("::").last)
      @encoder.str(CallPath.canonical_type_name(type))
      @encoder.str(type.type_desc)

      if type.is_a?(Annotatable) && (anns = type.annotations)
        total = anns.values.sum(&.size)
        @encoder.list(total) do
          anns.each do |_ann_type, ann_list|
            ann_list.each do |ann|
              @encoder.str(ann.path.to_s)
              @encoder.list(ann.args.size) { ann.args.each { |a| encode_node(a) } }
            end
          end
        end
      else
        @encoder.list(0)
      end

      if (type.is_a?(ClassType) || type.is_a?(GenericClassInstanceType)) && (sc = type.superclass)
        @encoder.str(CallPath.canonical_type_name(sc))
      else
        @encoder.absent
      end

      if parents = type.parents
        @encoder.list(parents.size) do
          parents.each do |parent|
            @encoder.str(CallPath.canonical_type_name(parent))
          end
        end
      else
        @encoder.list(0)
      end

      if type.is_a?(InstanceVarContainer)
        all_ivars = type.all_instance_vars
        @encoder.list(all_ivars.size) do
          all_ivars.each do |ivar_name, ivar|
            @encoder.str(ivar_name)
            encode_type(ivar.type?)
          end
        end
      else
        @encoder.list(0)
      end

      if type.is_a?(EnumType)
        @encoder.str(CallPath.canonical_type_name(type.base_type))
        members = type.types.compact_map { |k, v| v.is_a?(Const) ? {k, v} : nil }
        @encoder.list(members.size) do
          members.each do |(m_name, m_const)|
            @encoder.str(m_name)
            @encoder.str(m_const.value.to_s)
          end
        end
      else
        @encoder.absent
      end

      if type.is_a?(GenericClassInstanceType) || type.is_a?(GenericModuleInstanceType)
        @encoder.list(type.type_vars.size) do
          type.type_vars.each do |tv_name, tv|
            @encoder.str(tv_name)
            if tv.is_a?(Var)
              encode_type(tv.type?)
            else
              @encoder.str(tv.to_s)
            end
          end
        end
      else
        @encoder.list(0)
      end

      if type.is_a?(VirtualType)
        subtypes = [] of String
        type.each_concrete_type { |sub| subtypes << CallPath.canonical_type_name(sub) }
        subtypes.sort!
        @encoder.list(subtypes.size) do
          subtypes.each { |s| @encoder.str(s) }
        end
      else
        @encoder.list(0)
      end

      if type.is_a?(TupleInstanceType)
        @encoder.list(type.tuple_types.size) do
          type.tuple_types.each { |tt| @encoder.str(CallPath.canonical_type_name(tt)) }
        end
      else
        @encoder.list(0)
      end

      if type.is_a?(NamedTupleInstanceType)
        @encoder.list(type.entries.size) do
          type.entries.each do |entry|
            @encoder.str(entry.name)
            @encoder.str(CallPath.canonical_type_name(entry.type))
          end
        end
      else
        @encoder.list(0)
      end

      if type.is_a?(StaticArrayInstanceType)
        @encoder.str(type.size.to_s)
        @encoder.str(CallPath.canonical_type_name(type.element_type))
      else
        @encoder.absent
      end

      if type.is_a?(TypeDefType)
        @encoder.str(CallPath.canonical_type_name(type.typedef))
      else
        @encoder.absent
      end

      if type.is_a?(NonGenericClassType) && type.extern?
        @encoder.bool(type.extern_union?)
        all_ivars = type.all_instance_vars
        @encoder.list(all_ivars.size) do
          all_ivars.each do |name, ivar|
            @encoder.str(name)
            encode_type(ivar.type?)
          end
        end
      else
        @encoder.absent
      end
    end

    def encode_type(type : Type?) : Nil
      if type
        @encoder.str(CallPath.canonical_type_name(type))
      else
        @encoder.absent
      end
    end

    def encode_var_name(name : String) : Nil
      if compiler_temp_name?(name)
        ordinal = @temp_ordinals.put_if_absent(name) do
          ord = @next_temp_ordinal
          @next_temp_ordinal += 1
          ord
        end
        @encoder.str("__temp_#{ordinal}")
      else
        @encoder.str(name)
      end
    end

    def compiler_temp_name?(name : String) : Bool
      name.starts_with?("__temp_") || name.starts_with?("__probe_") || name.starts_with?("%")
    end

    def encode_node(node : ASTNode?) : Nil
      if node.nil?
        @encoder.absent
        @debug_main.try &.puts("absent")
        return
      end

      tag = node.class.name.split("::").last
      @encoder.tag(tag)
      @debug_main.try &.puts("tag:#{tag} #{node.class} => #{node.to_s.gsub('\n', ' ')[0..50]}")
      encode_type(node.type?)

      case node
      when Nop
      when NilLiteral
      when BoolLiteral
        @encoder.bool(node.value)
      when NumberLiteral
        @encoder.str(node.value)
        @encoder.str(node.kind.to_s)
      when CharLiteral
        @encoder.uint(node.value.ord.to_u64)
      when StringLiteral
        @encoder.str(node.value)
      when StringInterpolation
        @encoder.list(node.expressions.size) { node.expressions.each { |e| encode_node(e) } }
      when SymbolLiteral
        @encoder.str(node.value)
      when ArrayLiteral
        @encoder.list(node.elements.size) { node.elements.each { |e| encode_node(e) } }
        if of = node.of
          encode_node(of)
        else
          @encoder.absent
        end
      when HashLiteral
        @encoder.list(node.entries.size) do
          node.entries.each do |entry|
            encode_node(entry.key)
            encode_node(entry.value)
          end
        end
        if of = node.of
          encode_node(of.key); encode_node(of.value)
        else
          @encoder.absent
        end
      when NamedTupleLiteral
        @encoder.list(node.entries.size) do
          node.entries.each do |entry|
            @encoder.str(entry.key)
            encode_node(entry.value)
          end
        end
      when RangeLiteral
        encode_node(node.from)
        encode_node(node.to)
        @encoder.bool(node.exclusive?)
      when RegexLiteral
        encode_node(node.value)
        @encoder.uint(node.options.value.to_u64)
      when TupleLiteral
        @encoder.list(node.elements.size) { node.elements.each { |e| encode_node(e) } }
      when Var
        encode_var_name(node.name)
      when Block
        @encoder.list(node.args.size) { node.args.each { |a| encode_node(a) } }
        encode_node(node.body)
      when Call
        @encoder.str(node.name)
        if obj = node.obj
          encode_node(obj)
        else
          @encoder.absent
        end

        call_args = collect_call_args(node)
        @encoder.list(call_args.size) { call_args.each { |a| encode_node(a) } }

        if named_args = node.named_args
          @encoder.list(named_args.size) do
            named_args.each do |na|
              @encoder.str(na.name)
              encode_node(na.value)
            end
          end
        else
          @encoder.list(0)
        end

        if block = node.block
          encode_node(block)
        else
          @encoder.absent
        end

        if target_defs = node.target_defs
          @encoder.list(target_defs.size) do
            target_defs.each do |td|
              owner = node.super? ? node.scope : td.owner
              if should_inline_target?(node, td, owner)
                @encoder.tag("InlinedBody")
                encode_node(td.body)
              else
                @encoder.tag("TargetDef")
                @encoder.str(CallPath.canonical_def_key(td, owner))
              end
            end
          end
        else
          @encoder.list(0)
        end
      when NamedArgument
        @encoder.str(node.name)
        encode_node(node.value)
      when If
        @encoder.bool(node.truthy?)
        @encoder.bool(node.falsey?)
        if node.truthy?
          encode_node(node.cond)
          encode_node(node.then)
        elsif node.falsey?
          encode_node(node.cond)
          encode_node(node.else)
        else
          encode_node(node.cond)
          encode_node(node.then)
          encode_node(node.else)
        end
      when Assign
        encode_node(node.target)
        encode_node(node.value)
      when AssignWithRestriction
        encode_node(node.assign)
        encode_node(node.restriction)
      when MultiAssign
        @encoder.list(node.targets.size) { node.targets.each { |t| encode_node(t) } }
        @encoder.list(node.values.size) { node.values.each { |v| encode_node(v) } }
      when UninitializedVar
        encode_node(node.var)
        encode_node(node.declared_type)
      when TypeOf
        @encoder.list(node.expressions.size) { node.expressions.each { |e| encode_node(e) } }
      when While
        encode_node(node.cond)
        encode_node(node.body)
      when Return
        if exp = node.exp
          encode_node(exp)
        else
          @encoder.absent
        end
      when Yield
        @encoder.list(node.exps.size) { node.exps.each { |e| encode_node(e) } }
        @encoder.bool(node.has_parentheses?)
      when Break
        if exp = node.exp
          encode_node(exp)
        else
          @encoder.absent
        end
      when Next
        if exp = node.exp
          encode_node(exp)
        else
          @encoder.absent
        end
      when Expressions
        active = filter_codegen_expressions(node.expressions)
        @encoder.list(active.size) { active.each { |e| encode_node(e) } }
      when ExceptionHandler
        encode_node(node.body)
        if rescues = node.rescues
          @encoder.list(rescues.size) { rescues.each { |r| encode_node(r) } }
        else
          @encoder.list(0)
        end
        if el = node.else
          encode_node(el)
        else
          @encoder.absent
        end
        if en = node.ensure
          encode_node(en)
        else
          @encoder.absent
        end
      when Rescue
        encode_node(node.body)
        if types = node.types
          @encoder.list(types.size) { types.each { |t| encode_node(t) } }
        else
          @encoder.list(0)
        end
        if nm = node.name
          @encoder.str(nm)
        else
          @encoder.absent
        end
      when Cast
        encode_node(node.obj)
        encode_node(node.to)
        @encoder.bool(node.upcast?)
        if failable_cast?(node)
          loc_str = cast_location_string(node)
          if loc_str
            @encoder.str(loc_str)
          else
            @encoder.absent
          end
        else
          @encoder.absent
        end
      when UnaryExpression
        encode_node(node.exp)
      when IsA
        encode_node(node.obj)
        encode_node(node.const)
      when RespondsTo
        encode_node(node.obj)
        @encoder.str(node.name)
      when Primitive
        @encoder.str(node.name)
        if ex = node.extra
          encode_node(ex)
        else
          @encoder.absent
        end
      when ProcLiteral
        encode_node(node.def.body)
      when ProcPointer
        if obj = node.obj
          encode_node(obj)
        else
          @encoder.absent
        end
        @encoder.str(node.name)
        @encoder.list(node.args.size) { node.args.each { |a| encode_node(a) } }
      when ClassVar
        @encoder.str(node.name)
        @encoder.str(node.var.owner.to_s)
      when InstanceVar
        @encoder.str(node.name)
      when ReadInstanceVar
        encode_node(node.obj)
        @encoder.str(node.name)
      when Global
        @encoder.str(node.name)
      when Path
        if target_const = node.target_const
          @encoder.tag("ConstKey")
          @encoder.str(target_const.to_s)
        elsif target_type = node.target_type
          @encoder.tag("TypeKey")
          @encoder.str(CallPath.canonical_type_name(target_type))
        else
          @encoder.tag("Path")
          @encoder.str(node.to_s)
        end
      when Self
      when ExternalVar
        @encoder.str(node.name)
        if rn = node.real_name
          @encoder.str(rn)
        else
          @encoder.absent
        end
      when Asm
        @encoder.str(node.text)
        if outputs = node.outputs
          @encoder.list(outputs.size) { outputs.each { |o| encode_node(o) } }
        else
          @encoder.list(0)
        end
        if inputs = node.inputs
          @encoder.list(inputs.size) { inputs.each { |i| encode_node(i) } }
        else
          @encoder.list(0)
        end
        if clobbers = node.clobbers
          @encoder.list(clobbers.size) { clobbers.each { |c| @encoder.str(c) } }
        else
          @encoder.list(0)
        end
        @encoder.bool(node.volatile?)
        @encoder.bool(node.alignstack?)
        @encoder.bool(node.intel?)
        @encoder.bool(node.can_throw?)
      when AsmOperand
        @encoder.str(node.constraint)
        encode_node(node.exp)
      when TypeNode
        @encoder.str(CallPath.canonical_type_name(node.type))
      when FileNode
        encode_node(node.node)
      when Unreachable
      when MetaVar
        encode_var_name(node.name)
      when MetaTypeVar
        encode_var_name(node.name)
      when Arg
        encode_var_name(node.name)
        encode_type(node.type?)
        if dv = node.default_value
          encode_node(dv)
        else
          @encoder.absent
        end
        if res = node.restriction
          encode_node(res)
        else
          @encoder.absent
        end
      when Def
        if hooks = node.hook_expansions
          @encoder.list(hooks.size) { hooks.each { |h| encode_node(h) } }
        else
          @encoder.list(0)
        end
      when ClassDef
        encode_node(node.body)
      when ModuleDef
        encode_node(node.body)
      when EnumDef, LibDef
      when FunDef
        encode_node(node.body)
      when External
        @encoder.str(node.name)
        @encoder.str(node.real_name)
      when Annotation
        @encoder.str(node.path.to_s)
        @encoder.list(node.args.size) { node.args.each { |a| encode_node(a) } }
      when Generic
        encode_node(node.name)
        @encoder.list(node.type_vars.size) { node.type_vars.each { |tv| encode_node(tv) } }
      when Out
        encode_node(node.exp)
      when Metaclass
        encode_node(node.name)
      else
        @encoder.str(node.to_s)
      end
    end

    def collect_call_args(node : Call) : Array(ASTNode)
      args = node.args.dup
      if (target_defs = node.target_defs) && target_defs.size == 1
        target_def = target_defs.first
        if node.args.size < target_def.args.size
          node.args.size.upto(target_def.args.size - 1) do |index|
            arg = target_def.args[index]
            if (default_value = arg.default_value) && default_value.is_a?(MagicConstant)
              location = node.location
              end_location = node.end_location
              case default_value.name
              when .magic_line?
                args << NumberLiteral.new(MagicConstant.expand_line(location))
              when .magic_end_line?
                args << NumberLiteral.new(MagicConstant.expand_line(end_location))
              when .magic_file?
                args << StringLiteral.new(MagicConstant.expand_file(location))
              when .magic_dir?
                args << StringLiteral.new(MagicConstant.expand_dir(location))
              end
            end
          end
        end
      end
      args
    end

    def failable_cast?(node : Cast) : Bool
      return false if node.upcast?
      obj_type = node.obj.type?
      res_type = node.type?
      return false unless obj_type && res_type
      obj_type != res_type
    end

    def cast_location_string(node : Cast) : String?
      location = node.location
      return nil unless location
      if @program.iyi_abi?
        "#{location.expanded_location}:#{location.line_number}"
      else
        location.expanded_location.to_s
      end
    end

    private def flatten_expressions(node : ASTNode, result : Array(ASTNode)) : Nil
      if node.is_a?(Expressions)
        node.expressions.each { |e| flatten_expressions(e, result) }
      else
        result << node
      end
    end

    def filter_codegen_expressions(exps : Array(ASTNode)) : Array(ASTNode)
      flat = [] of ASTNode
      exps.each { |e| flatten_expressions(e, flat) }
      flat.select { |exp| node_emits_in_main?(exp) }
    end

    def node_emits_in_main?(node : ASTNode) : Bool
      case node
      when Def
        !node.hook_expansions.nil? && !node.hook_expansions.not_nil!.empty?
      when Macro, EnumDef, LibDef
        false
      when ClassDef
        if node.hook_expansions.try { |h| !h.empty? }
          true
        else
          node_emits_in_main?(node.body)
        end
      when ModuleDef
        node_emits_in_main?(node.body)
      when Expressions
        node.expressions.any? { |e| node_emits_in_main?(e) }
      when If
        if node.iyi_definition_probe?
          false
        elsif node.cond.is_a?(BoolLiteral) && !node.cond.as(BoolLiteral).value
          if els = node.else
            node_emits_in_main?(els)
          else
            false
          end
        else
          true
        end
      when Assign
        !node.target.is_a?(Path)
      when Nop
        false
      else
        true
      end
    end

    def should_inline_target?(node : Call, target_def : Def, owner : Type) : Bool
      return false if target_def.is_a?(External)
      return false if target_def.iyi_from_artifact?

      if block = node.block
        return true unless (fun_literal = block.fun_literal) && target_def.uses_block_arg?
      end

      case target_def.body
      when Nop, NilLiteral, BoolLiteral, CharLiteral, StringLiteral, NumberLiteral, SymbolLiteral
        true
      when Var
        target_def.body.as(Var).name == "self"
      when InstanceVar
        true
      else
        false
      end
    end
  end
end
