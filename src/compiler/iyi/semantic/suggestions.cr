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

    def lookup_similar_path(names : Array(String), lookup_in_namespace = true)
      type = self
      names.each_with_index do |name, idx|
        previous_type = type
        type = previous_type.lookup_name(name)
        unless type
          best_match = Levenshtein.find(name.downcase) do |finder|
            previous_type.remove_alias.types?.try &.each_key do |type_name|
              finder.test(type_name.downcase, type_name)
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

    def lookup_similar_def(name, args_size, block)
      return nil unless SuggestableDefName.matches?(name)

      if (defs = self.defs)
        best_def = nil
        best_match = nil
        Levenshtein.find(name) do |finder|
          defs.each do |def_name, hash|
            if SuggestableDefName.matches?(def_name)
              hash.each do |def_with_metadata|
                # iyi: the arity the call has, anywhere in the def's range,
                # not its maximum: `ljust(width, char = ' ')` has a maximum of
                # two, `"ab".ljuts(5)` passed one, and the one def that was the
                # answer was never tested - so the sentence became "the prelude
                # is small by rule" and `iyi fix` had nothing to apply.
                fits = def_with_metadata.min_size <= args_size && args_size <= def_with_metadata.max_size
                if fits && def_with_metadata.yields == !!block && def_with_metadata.def.name != name
                  finder.test(def_name)
                  if finder.best_match != best_match
                    best_match = finder.best_match
                    best_def = def_with_metadata.def
                  end
                end
              end
            end
          end
        end
        return best_def if best_def
      end

      parents.try &.each do |parent|
        similar_def = parent.lookup_similar_def(name, args_size, block)
        return similar_def if similar_def
      end

      nil
    end

    def lookup_similar_def_name(name, args_size, block)
      lookup_similar_def(name, args_size, block).try &.name
    end

    def lookup_similar_instance_var_name(name)
      Levenshtein.find(name, all_instance_vars.keys.select { |key| key != name })
    end
  end

  class AliasType
    delegate lookup_similar_def, to: aliased_type
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
    delegate lookup_similar_def, lookup_similar_path, to: base_type
  end

  class VirtualMetaclassType
    delegate lookup_similar_path, to: instance_type
  end
end
