require "levenshtein"
require "../types"

module Iyi
  class Type
    # iyi: which def names are worth a Levenshtein pass. Compiled once at load
    # through Iyi::Rx, the compiler's own engine, so this file is not one of
    # the reasons pcre2 stays on the link line (SPEC.md III.10).
    SuggestableDefName = Rx::Pattern.compile("\\A[a-z_]")

    def lookup_similar_path(node : Path)
      (node.global? ? program : self).lookup_similar_path(node.names)
    end

    # iyi: a private type is never reachable by a qualified name (R-2 makes
    # every type a module leaves unmarked one), so after the first segment
    # it is no answer. `App::Main::Pont` was told "Did you mean
    # 'App::Main::Point'?", `iyi fix` wrote it, and the next check said
    # `App::Main does not export App::Main::Point`.
    def lookup_similar_path(names : Array(String), lookup_in_namespace = true)
      type = self
      names.each_with_index do |name, idx|
        previous_type = type
        type = previous_type.lookup_name(name)
        break if type && idx > 0 && type.private?
        unless type
          best_match = Levenshtein.find(name.downcase) do |finder|
            previous_type.remove_alias.types?.try &.each do |type_name, candidate|
              finder.test(type_name.downcase, type_name) unless idx > 0 && candidate.private?
            end
          end

          if best_match
            return (names[0...idx] + [best_match]).join "::"
          else
            break
          end
        end
      end

      parents.try &.each do |parent|
        match = parent.lookup_similar_path(names, false)
        return match if match
      end

      lookup_in_namespace && self != program ? namespace.lookup_similar_path(names) : nil
    end

    # iyi: *outside* is the scope of a call written with a receiver other
    # than `self`, which reaches no private def and a protected one only from
    # a scope with access to it (`Call#check_visibility`). Nil, the default,
    # is a call that can reach them all. `App::Lib.helpr` was told "Did you
    # mean 'helper'?" about a def the module never marked `pub`, and `iyi
    # fix` wrote the name the next check refused.
    #
    # iyi: the type's own defs and its ancestors' are one pool. The parents
    # were asked only when the type itself had nothing near, so `1.to_S`
    # was told "Did you mean 'to_i'?" and `"007".to_S` 'to_f' - `to_s`,
    # one case away, is the parent's - and `iyi fix` turned a string
    # conversion into a float parse. A case-only difference is the answer
    # outright; otherwise the nearest wins, and of equally near names the
    # nearer type's.
    def lookup_similar_def(name, args_size, block, outside : Type? = nil)
      return nil unless SuggestableDefName.matches?(name)

      candidates = [] of Def
      iyi_similar_def_candidates(name, args_size, block, outside, candidates)
      return nil if candidates.empty?

      if same = candidates.find { |a_def| a_def.name.compare(name, case_insensitive: true) == 0 }
        return same
      end
      best_name = Levenshtein.find(name) do |finder|
        candidates.each { |a_def| finder.test(a_def.name) }
      end
      best_name ? candidates.find { |a_def| a_def.name == best_name } : nil
    end

    # The defs a call of *name* could have meant, this type's first and then
    # each ancestor's.
    def iyi_similar_def_candidates(name, args_size, block, outside : Type?, into : Array(Def)) : Nil
      defs.try &.each do |def_name, hash|
        next unless SuggestableDefName.matches?(def_name)
        hash.each do |def_with_metadata|
          # iyi: the arity the call has, anywhere in the def's range,
          # not its maximum: `ljust(width, char = ' ')` has a maximum of
          # two, `"ab".ljuts(5)` passed one, and the one def that was the
          # answer was never tested - so the sentence became "the prelude
          # is small by rule" and `iyi fix` had nothing to apply.
          fits = def_with_metadata.min_size <= args_size && args_size <= def_with_metadata.max_size
          if fits && def_with_metadata.yields == !!block && def_with_metadata.def.name != name &&
             iyi_reachable_from?(def_with_metadata.def, outside)
            into << def_with_metadata.def
          end
        end
      end

      parents.try &.each do |parent|
        parent.iyi_similar_def_candidates(name, args_size, block, outside, into)
      end
    end

    private def iyi_reachable_from?(a_def : Def, outside : Type?) : Bool
      return true unless outside
      case a_def.visibility
      when .private?   then false
      when .protected? then outside.instance_type.has_protected_access_to?(a_def.owner.instance_type)
      else                  true
      end
    end

    def lookup_similar_def_name(name, args_size, block, outside : Type? = nil)
      lookup_similar_def(name, args_size, block, outside).try &.name
    end

    def lookup_similar_instance_var_name(name)
      Levenshtein.find(name, all_instance_vars.keys.select { |key| key != name })
    end
  end

  class AliasType
    delegate lookup_similar_def, iyi_similar_def_candidates, to: aliased_type
  end

  class MetaclassType
    delegate lookup_similar_path, to: instance_type
  end

  class GenericClassInstanceMetaclassType
    delegate lookup_similar_path, to: instance_type
  end

  class GenericModuleInstanceMetaclassType
    delegate lookup_similar_path, to: instance_type
  end

  class VirtualType
    delegate lookup_similar_def, iyi_similar_def_candidates, lookup_similar_path, to: base_type
  end

  class VirtualMetaclassType
    delegate lookup_similar_path, to: instance_type
  end
end
