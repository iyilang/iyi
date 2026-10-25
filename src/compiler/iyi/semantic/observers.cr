require "../program"
require "../syntax/ast"
require "./effects"

module Iyi::Semantic
  module Observers
    def self.run(program : Program) : Nil
      each_module(program) do |mod|
        defs = mod.defs
        next unless defs

        candidates = [] of Def
        defs.each_value do |metadata_list|
          metadata_list.each do |item|
            a_def = item.def
            if a_def.effect && !a_def.name.starts_with?("__iyi_effect_") && !a_def.iyi_observer_wrapped?
              candidates << a_def
            end
          end
        end

        candidates.each do |a_def|
          wrap_def(program, mod, a_def)
        end
      end
    end

    def self.each_module(program : Program, &block : ModuleType -> Nil) : Nil
      visited = Set(UInt64).new
      queue = [] of ModuleType

      queue << program
      program.file_modules.each_value { |fm| queue << fm }

      if types = program.types?
        types.each_value do |type|
          queue << type if type.is_a?(ModuleType)
        end
      end

      while mod = queue.pop?
        obj_id = mod.object_id
        next if visited.includes?(obj_id)
        visited << obj_id

        yield mod

        unless mod.metaclass?
          meta = mod.metaclass
          if meta.is_a?(ModuleType) && !visited.includes?(meta.object_id)
            queue << meta
          end
        end

        if inner_types = mod.types?
          inner_types.each_value do |inner|
            queue << inner if inner.is_a?(ModuleType)
          end
        end
      end
    end

    def self.wrap_def(program : Program, owner : ModuleType, a_def : Def) : Nil
      effect = a_def.effect
      return unless effect
      return if effect.kind == EffectKind::ObservationChannel

      is_frame_only = (effect.kind == EffectKind::Stdio || effect.effect_class.internal?)
      # Validate signature per C9 and effect shape (only for non-frame-only defs)
      unless is_frame_only
        validate_signature(program, owner, a_def, effect)
      end

      original_name = a_def.name
      renamed_name = "__iyi_effect_#{original_name}"

      # Mark original def as wrapped and rename it
      a_def.name = renamed_name
      a_def.iyi_observer_wrapped = true
      a_def.exported = false

      # In owner's defs table: remove from original_name
      if defs = owner.defs
        if list = defs[original_name]?
          list.reject! { |item| item.def.same?(a_def) }
          defs.delete(original_name) if list.empty?
        end
      end

      # Add renamed def under __iyi_effect_<name>
      owner.add_def(a_def)

      # Build wrapper
      wrapper = build_wrapper(program, owner, a_def, effect, original_name, renamed_name, is_frame_only: is_frame_only)

      # Add wrapper to owner
      owner.add_def(wrapper)
    end

    def self.validate_signature(program : Program, owner : ModuleType, a_def : Def, effect : Effect) : Nil
      if a_def.block_arity || a_def.block_arg
        a_def.raise "def '#{a_def.name}' that yields cannot carry @[Effect(:#{effect.kind.symbol_name})]; annotate the non-yielding helper it calls instead"
      end

      if a_def.splat_index || a_def.double_splat
        a_def.raise "def '#{a_def.name}' that takes splats cannot carry @[Effect(:#{effect.kind.symbol_name})]; annotate the non-yielding helper it calls instead"
      end

      case effect.kind
      when EffectKind::DirList
        if a_def.name == "read" || a_def.name == "rewind" || a_def.name == "close" || a_def.args.empty?
          a_def.raise "def '#{a_def.name}' cannot carry @[Effect(:dir_list)]: mismatched signature (observer expects (path, names)); annotate the non-yielding helper it calls instead"
        end
      when EffectKind::EnvGet
        if a_def.args.empty?
          a_def.raise "def '#{a_def.name}' cannot carry @[Effect(:env_get)]: mismatched signature (observer expects (name, value?)); annotate the non-yielding helper it calls instead"
        end
      when EffectKind::FileRead, EffectKind::FileStat, EffectKind::FileExists
        if a_def.name == "lseek" || a_def.name == "two_links?" || (!has_path_arg?(a_def) && !has_path_property?(owner))
          a_def.raise "def '#{a_def.name}' cannot carry @[Effect(:#{effect.kind.symbol_name})]: mismatched signature (observer expects path parameter); annotate the non-yielding helper it calls instead"
        end
      when EffectKind::FileWrite
        if a_def.args.empty? && !has_path_property?(owner)
          a_def.raise "def '#{a_def.name}' cannot carry @[Effect(:file_write)]: mismatched signature (observer expects path parameter); annotate the non-yielding helper it calls instead"
        end
        if (op = effect.op) && (op.rename? || op.link? || op.symlink?)
          if a_def.args.size < 2
            a_def.raise "def '#{a_def.name}' cannot carry @[Effect(:file_write, :#{op.symbol_name})]: mismatched signature (observer expects two path parameters); annotate the non-yielding helper it calls instead"
          end
        end
      else
        # Other kinds: Exit, EnvAll, Cwd, Host, NotReusable kinds
      end
    end

    private def self.has_path_arg?(a_def : Def) : Bool
      return false if a_def.args.empty?
      a_def.args.any? do |arg|
        name = arg.name.downcase
        return true if name.includes?("path") || name == "filename" || name == "file" || name == "from" || name == "dir_path"
        if restr = arg.restriction
          restr_str = restr.to_s
          return true if restr_str.includes?("Path") || restr_str.includes?("String")
        end
        false
      end
    end

    private def self.has_path_property?(owner : ModuleType) : Bool
      inst_name = owner.instance_type.to_s
      inst_name == "Dir" || inst_name == "File" || inst_name.ends_with?("::Dir") || inst_name.ends_with?("::File")
    end

    def self.build_wrapper(program : Program, owner : ModuleType, a_def : Def, effect : Effect,
                           original_name : String, renamed_name : String, *, is_frame_only : Bool = false) : Def
      wrapper = Def.new(
        original_name,
        a_def.args.map(&.clone),
        nil,
        a_def.receiver.try(&.clone),
        nil,
        a_def.return_type.try(&.clone),
        a_def.macro_def?,
        nil,
        false,
        nil,
        nil,
        a_def.free_vars.try(&.dup)
      )
      wrapper.free_var_bounds = a_def.free_var_bounds.try(&.dup)
      wrapper.where_bounds = a_def.where_bounds.try(&.dup)
      wrapper.visibility = a_def.visibility
      wrapper.exported = a_def.exported?
      wrapper.location = a_def.location
      wrapper.name_location = a_def.name_location
      wrapper.end_location = a_def.end_location
      wrapper.doc = a_def.doc
      wrapper.always_inline = a_def.always_inline?
      wrapper.no_inline = a_def.no_inline?
      wrapper.naked = a_def.naked?
      wrapper.returns_twice = a_def.returns_twice?
      wrapper.iyi_observer_wrapped = true
      wrapper.set_type program.nil

      # Copy annotations except Effect
      if anns = a_def.annotations
        wrapper_anns = Hash(AnnotationType, Array(Annotation)).new
        anns.each do |ann_type, ann_list|
          next if ann_type == program.effect_annotation
          wrapper_anns[ann_type] = ann_list.map(&.clone)
        end
        wrapper.annotations = wrapper_anns unless wrapper_anns.empty?
      end

      # Inner call
      call_args = a_def.args.map do |arg|
        Var.new(arg.name).at(a_def).as(ASTNode)
      end
      call_receiver = if a_def.receiver
                        Var.new("self").at(a_def)
                      else
                        nil
                      end
      inner_call = Call.new(call_receiver, renamed_name, call_args).at(a_def)

      # Observer path: resolved reference to std/observe
      observer_path = Path.new(["Std", "Observe"], global: true).at(a_def)
      observer_path.iyi_synthetic = true
      if observe_mod = program.types["Std"]?.as?(ModuleType).try do |std|
          std.types?.try do |inner|
            inner["Observe"]?.as?(ModuleType)
          end
        end
        observer_path.target_type = observe_mod.metaclass
        observer_path.type = observe_mod.metaclass
      end
      enter_call = Call.new(observer_path, "enter_frame").at(a_def)
      enter_call.iyi_synthetic = true
      leave_call = Call.new(observer_path, "leave_frame").at(a_def)
      leave_call.iyi_synthetic = true
      if is_frame_only
        res_var = Var.new("__iyi_res").at(a_def)
        assign = Assign.new(res_var, inner_call).at(a_def)
        wrapper.body = Expressions.new([enter_call.as(ASTNode), assign.as(ASTNode), leave_call.as(ASTNode), res_var.as(ASTNode)]).at(a_def)
      elsif effect.kind == EffectKind::Exit
        # C5: exit observer before the def
        status_arg = if a_def.args.size >= 1
                       Var.new(a_def.args[0].name).at(a_def).as(ASTNode)
                     else
                       NumberLiteral.new(0).at(a_def).as(ASTNode)
                     end
        observer_call = Call.new(observer_path, "__iyi_observe_exit", [status_arg] of ASTNode).at(a_def)
        observer_call.iyi_synthetic = true

        is_outer_var = Var.new("__iyi_is_outer").at(a_def)
        assign_outer = Assign.new(is_outer_var, enter_call).at(a_def)
        if_node = If.new(is_outer_var, observer_call).at(a_def)

        wrapper.body = Expressions.new([assign_outer.as(ASTNode), if_node.as(ASTNode), inner_call.as(ASTNode)]).at(a_def)
      else
        res_var = Var.new("__iyi_res").at(a_def)
        assign_res = Assign.new(res_var, inner_call).at(a_def)

        is_outer_var = Var.new("__iyi_is_outer").at(a_def)
        assign_outer = Assign.new(is_outer_var, enter_call).at(a_def)

        observer_call = build_observer_call(program, owner, a_def, effect, observer_path, res_var)
        observer_call.iyi_synthetic = true
        if_node = If.new(is_outer_var, observer_call).at(a_def)

        wrapper.body = Expressions.new([
          assign_outer.as(ASTNode),
          assign_res.as(ASTNode),
          if_node.as(ASTNode),
          leave_call.as(ASTNode),
          res_var.as(ASTNode)
        ]).at(a_def)
      end

      wrapper
    end

    private def self.build_observer_call(program : Program, owner : ModuleType, a_def : Def,
                                         effect : Effect, observer_path : Path, res_var : Var) : Call
      case effect.kind
      when EffectKind::FileRead, EffectKind::FileStat, EffectKind::FileExists
        path_arg = extract_path_arg(owner, a_def)
        method_name = "__iyi_observe_#{effect.kind.symbol_name}"
        Call.new(observer_path, method_name, [path_arg] of ASTNode).at(a_def)

      when EffectKind::DirList
        path_arg = extract_path_arg(owner, a_def)
        Call.new(observer_path, "__iyi_observe_dir_list", [path_arg, res_var.as(ASTNode)] of ASTNode).at(a_def)

      when EffectKind::EnvGet
        name_arg = to_string_node(Var.new(a_def.args[0].name).at(a_def), a_def.args[0].restriction, a_def)
        Call.new(observer_path, "__iyi_observe_env_get", [name_arg, res_var.as(ASTNode)] of ASTNode).at(a_def)

      when EffectKind::EnvAll
        Call.new(observer_path, "__iyi_observe_env_all", [] of ASTNode).at(a_def)

      when EffectKind::Cwd
        path_arg = if a_def.args.size >= 1
                     to_string_node(Var.new(a_def.args[0].name).at(a_def), a_def.args[0].restriction, a_def)
                   else
                     to_string_node(res_var, a_def.return_type, a_def)
                   end
        Call.new(observer_path, "__iyi_observe_cwd", [path_arg] of ASTNode).at(a_def)

      when EffectKind::Host
        val_arg = if a_def.args.size >= 1
                    to_string_node(Var.new(a_def.args[0].name).at(a_def), a_def.args[0].restriction, a_def)
                  else
                    to_string_node(res_var, a_def.return_type, a_def)
                  end
        Call.new(observer_path, "__iyi_observe_host", [val_arg] of ASTNode).at(a_def)

      when EffectKind::FileWrite
        op = effect.op.not_nil!
        op_arg = SymbolLiteral.new(op.symbol_name).at(a_def).as(ASTNode)
        path_arg = extract_path_arg(owner, a_def)
        target_arg = if a_def.args.size >= 2
                       to_string_node(Var.new(a_def.args[1].name).at(a_def), a_def.args[1].restriction, a_def)
                     else
                       NilLiteral.new.at(a_def).as(ASTNode)
                     end
        Call.new(observer_path, "__iyi_observe_file_write", [op_arg, path_arg, target_arg] of ASTNode).at(a_def)

      when EffectKind::Clock, EffectKind::Entropy, EffectKind::Timer,
           EffectKind::Network, EffectKind::Process, EffectKind::Signal,
           EffectKind::RuntimeTiming, EffectKind::CodeLocation
        site = Effects.format_site(program, a_def.location)
        site_arg = StringLiteral.new(site).at(a_def).as(ASTNode)
        method_name = "__iyi_observe_#{effect.kind.symbol_name}"
        Call.new(observer_path, method_name, [site_arg] of ASTNode).at(a_def)

      else
        raise "unsupported effect kind for wrapper: #{effect.kind}"
      end
    end

    private def self.to_string_node(node : ASTNode, restriction : ASTNode?, a_def : Def) : ASTNode
      if restriction.try(&.to_s) == "String"
        node
      else
        Call.new(node, "to_s").at(a_def).as(ASTNode)
      end
    end

    private def self.extract_path_arg(owner : ModuleType, a_def : Def) : ASTNode
      path_arg = a_def.args.find { |arg|
        n = arg.name.downcase
        n.includes?("path") || n == "filename" || n == "file" || n == "from" || n == "dir_path"
      }
      path_arg ||= a_def.args.find { |arg|
        restr = arg.restriction.try(&.to_s)
        restr && (restr.includes?("String") || restr.includes?("Path"))
      }
      path_arg ||= a_def.args.first?

      if path_arg
        to_string_node(Var.new(path_arg.name).at(a_def), path_arg.restriction, a_def)
      else
        Call.new(Call.new(Var.new("self").at(a_def), "path").at(a_def), "to_s").at(a_def).as(ASTNode)
      end
    end
  end
end
