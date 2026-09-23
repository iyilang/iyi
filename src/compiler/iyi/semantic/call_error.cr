class Iyi::ASTNode
  def wrong_number_of_arguments(subject, given, expected)
    wrong_number_of "arguments", subject, given, expected
  end

  def wrong_number_of(elements, given, expected)
    raise wrong_number_of_message(elements, given, expected)
  end

  def wrong_number_of(elements, subject, given, expected)
    raise wrong_number_of_message(elements, subject, given, expected)
  end

  def wrong_number_of_message(elements, given, expected)
    "wrong number of #{elements} (given #{given}, expected #{expected})"
  end

  def wrong_number_of_message(elements, subject, given, expected)
    "wrong number of #{elements} for #{subject} (given #{given}, expected #{expected})"
  end
end

class Iyi::Path
  def raise_undefined_constant(type)
    private_const = type.lookup_path(self, include_private: true)
    if private_const
      # iyi: a type an iyi module left unmarked is closed by `pub` rather than
      # by Crystal's `private`, so say which word is missing (SPEC.md R-2).
      namespace = private_const.is_a?(Type) ? private_const.namespace : nil
      if namespace && namespace.iyi_unit?
        self.raise("#{namespace} does not export #{private_const}. Only what a module marks `pub` is reachable from outside it — see SPEC.md R-2")
      end

      self.raise("private constant #{private_const} referenced")
    end

    # iyi: the name is usually not missing, it is out of reach - a type a
    # module this program loaded declares, and this file has not written
    # `using` for (SPEC.md R-2b), or one its module never marked `pub`
    # (R-2). The same two answers `iyi_out_of_reach_hint` gives a call.
    if names.size == 1 && (hint = iyi_type_out_of_reach_hint(type.program, names.first))
      self.raise("undefined constant #{self}\n#{hint}")
    end

    # iyi: Crystal's name for a thing the prelude spells otherwise, for
    # someone arriving with Crystal's spelling in their fingers. First,
    # because where the table has a sentence it says more than the scan
    # below can (`Time.utc`, and that there is no `Time.now`).
    if hint = Iyi::IYI_ARRIVAL_CONSTANT_HINTS[to_s]?
      self.raise("undefined constant #{self}\n#{hint}")
    end

    # iyi: a name the standard library declares and this program never
    # imported. `Deque`, `JSON`, `Random`, `Socket` and thirty more were a
    # bare "undefined constant" while `std/<module>.iyi` had each of them
    # under `pub`; the file is read, so the hint is the tree's rather than
    # a table's. Above the spelling suggestion, because `Deque` is not a
    # misspelling of anything.
    if hint = iyi_std_declares_hint(type.program, names.first)
      self.raise("undefined constant #{self}\n#{hint}")
    end

    similar_name = type.lookup_similar_path(self)
    if similar_name
      self.raise("undefined constant #{self}\nDid you mean '#{similar_name}'?", suggestion: similar_name.to_s)
    end

    self.raise("undefined constant #{self}")
  end

  private def iyi_type_out_of_reach_hint(program, name : String) : String?
    exporting = [] of ModuleType
    hiding = [] of ModuleType
    iyi_each_unit(program) do |mod|
      next unless mod.types?.try &.has_key?(name)
      (mod.exported_name?(name) ? exporting : hiding) << mod
    end

    unless exporting.empty?
      written = exporting.map { |mod| mod.to_s.split("::").map(&.underscore).join('/') }
      return "`#{name}` is exported by #{written.map { |path| "`#{path}`" }.join(" and ")}, " \
             "and this file has not written `using`. Add `using #{written.first}::{#{name}}` " \
             "to bring it in unqualified, or write it as `#{exporting.first}::#{name}` " \
             "(SPEC.md R-2b)"
    end

    unless hiding.empty?
      written = hiding.first.to_s.split("::").map(&.underscore).join('/')
      return "`#{written}` declares `#{name}` and does not mark it `pub`, " \
             "so it is the module's own and no other module can reach it " \
             "(SPEC.md R-2)"
    end

    nil
  end

  # The `std/<module>` whose file declares `pub class|struct|module|trait|
  # enum|alias NAME` at the top level, with the two lines that bring it in.
  # Read off the search path the way an import is resolved, and only on
  # the error path. A string walk rather than a `Regex`: the compiler
  # links no pcre2 (SPEC.md III.9), and one regex here was enough to make
  # it.
  IYI_STD_DECLARERS = {"pub class ", "pub struct ", "pub module ", "pub trait ", "pub enum ", "pub alias "}

  private def iyi_std_declares_hint(program, name : String) : String?
    program.iyi_path.entries.each do |entry|
      dir = File.join(entry, "std")
      next unless Dir.exists?(dir)
      Dir.each_child(dir) do |file|
        next unless file.ends_with?(".iyi")
        path = File.join(dir, file)
        next unless File.file?(path) && iyi_declares_at_top_level?(File.read(path), name)
        written = "std/#{file.rchop(".iyi")}"
        return "`#{name}` comes with `import #{written}` and `using #{written}::{#{name}}`."
      end
    end
    nil
  end

  private def iyi_declares_at_top_level?(text : String, name : String) : Bool
    text.each_line do |line|
      next unless line.starts_with?("pub ")
      IYI_STD_DECLARERS.each do |declarer|
        next unless line.starts_with?(declarer)
        rest = line[declarer.size..]
        next unless rest.starts_with?(name)
        after = rest[name.size]?
        return true if after.nil? || !(after.alphanumeric? || after == '_')
      end
    end
    false
  end

  private def iyi_each_unit(type, &block : ModuleType ->) : Nil
    type.types?.try &.each_value do |nested|
      block.call(nested) if nested.is_a?(ModuleType) && nested.iyi_unit?
      iyi_each_unit(nested, &block)
    end
  end
end

module Iyi
  # iyi: Crystal's spellings the prelude does not have, and what it has
  # instead. Read where an undefined constant or a top-level call is
  # reported; a name here is one somebody arriving from Crystal writes
  # first, not a list of everything the prelude lacks.
  IYI_ARRIVAL_CONSTANT_HINTS = {
    "ARGV"       => "The arguments are `Program.args`: an `Array(String)` of what followed the program's name.",
    "ENV"        => "One variable at a time: `Program.env(\"NAME\")` answers a `String?`. The whole map, `ENV[\"NAME\"]?` and `ENV.to_h`, comes with `import std/env` and `using std/env::{ENV}`.",
    "Time"       => "`Time` lives in `std/time`: write `import std/time` and `using std/time::{Time}`. The clock is `Time.utc`; there is no `Time.now`.",
    "Int32::MAX" => "There is no `Int32::MAX`: the edges are the literals, 2147483647 and -2147483648, and arithmetic past them panics rather than wrapping.",
    "Int32::MIN" => "There is no `Int32::MIN`: the edges are the literals, -2147483648 and 2147483647, and arithmetic past them panics rather than wrapping.",
    "Int64::MAX" => "There is no `Int64::MAX`: the edge is the literal, 9223372036854775807_i64, and arithmetic past it panics rather than wrapping.",
    "Int64::MIN" => "There is no `Int64::MIN`: the edge is the literal, -9223372036854775808_i64, and arithmetic past it panics rather than wrapping.",
    # The names Python, JavaScript, Rust and Java write for values and
    # containers this language has under other names. Each one arrived as
    # `undefined constant X`, which is true and says nothing about what to
    # write instead.
    "None"  => "`nil` is the spelling here, and a value that may be nil is `T?`.",
    "True"  => "`true` is lowercase here.",
    "False" => "`false` is lowercase here.",
    "List"  => "`Array(T)` is the name here: `xs : Array(Int32) = [1, 2]`.",
    "Vec"   => "`Array(T)` is the name here: `xs : Array(Int32) = [1, 2]`.",
    "Dict"  => "`Hash(K, V)` is the name here: `{\"a\" => 1}` is a `Hash(String, Int32)`.",
    "Map"   => "`Hash(K, V)` is the name here: `{\"a\" => 1}` is a `Hash(String, Int32)`.",
    "Set"   => "`Set(T)` comes with `import std/set`; it is declared at the root, so the import alone is enough to write `Set(Int32).new`.",
  }

  IYI_ARRIVAL_CALL_HINTS = {
    "p"       => "`puts value.inspect` is the spelling here; `p` comes with `import std/kernel` and `using std/kernel::{p}`.",
    "pp"      => "`puts value.inspect` is the spelling here; `pp` comes with `import std/kernel` and `using std/kernel::{pp}`.",
    "require" => "iyi has no `require`: a module is reached with `import`, and `--crystal` gives a program Crystal's library.",
    "exit"    => "There is no `exit`: a program ends when its last line runs, and a failure is a panic - `raise \"why\"`, or `assert` - which exits 1 with the sentence (SPEC.md III.1.4).",
    "gets"    => "`stdin.gets` reads a line, a `String?` that is nil at the end; there is no bare `gets`.",
    "printf"  => "`printf`, `sprintf` and `String#%` come with `import std/format` and `using std/format::{printf}`.",
    "sprintf" => "`printf`, `sprintf` and `String#%` come with `import std/format` and `using std/format::{sprintf}`.",
    "rand"    => "There is no `rand` in the prelude: `Random.new.rand(n)` comes with `import std/random` and `using std/random::{Random}`.",
    "spawn"   => "`spawn` is a group's: `group do |g| g.spawn { ... } end` (SPEC.md III.4). A task has a boundary, and the group is it.",
    "let"     => "There is no `let`: a variable is `x = 1`, and its type is the value's.",
    "var"     => "There is no `var`: a variable is `x = 1`, and its type is the value's.",
    "elif"    => "`elsif` is the spelling here.",
    "elseif"  => "`elsif` is the spelling here.",
    "println" => "`puts` is the spelling here; it ends the line.",
    "console" => "`puts` is the spelling here; there is no `console`.",
    "len"     => "`.size` is the spelling here: `xs.size`, `s.size`.",
    "str"     => "`.to_s` is the spelling here: `1.to_s`.",
    "int"     => "`.to_i` is the spelling here: `\"1\".to_i`, and it panics on what is not a number.",
    "input"   => "`stdin.gets` reads a line, a `String?` that is nil at the end; there is no `input`.",
    "null"    => "`nil` is the spelling here, and it is a type: a value that may be nil is `T?`.",
    # The words that open a failure, a container or a loop somewhere else.
    "new"   => "There is no `new` keyword: the type answers it — `Array(Int32).new`, `Point.new(1)`.",
    "throw" => "`raise \"why\"` is the spelling here, and it panics rather than unwinding to a handler (SPEC.md III.1.4).",
    "catch" => "iyi has no exceptions to catch: an error is a value the caller handles, and `!` propagates it (SPEC.md III.1, III.1.7a).",
    "range" => "A range is written `(0...3)` — `...` excludes the end, `..` includes it — and `(0...3).each do |i| ... end` iterates it.",
    "echo"  => "`puts` is the spelling here; it ends the line.",
  }

  # A method called on a receiver in Crystal's spelling, and
  # what the prelude has instead; `/` only where the receiver is an
  # integer.
  IYI_ARRIVAL_METHOD_HINTS = {
    "not_nil"     => "There is no `not_nil!`: `!` propagates an error here (SPEC.md III.1.7a). Narrow the nil first (`if x`) or give it an answer (`x || default`).",
    "try"         => "There is no `try`: narrow the nil first (`if x = a[0]?`) or give it an answer (`x || default`).",
    "/"           => "Integer division is `//` here (`7 // 2` is 3); `/` is the floats' and answers a `Float64` only for them.",
    "%"           => "`%` on a String is a format string, and it comes with `import std/format` (`printf`, `sprintf` and `String#%`).",
    "gets_to_end" => "`read_all` reads the rest of an IO here; `gets` reads a line.",
    # The spellings other languages give the methods this prelude has. The
    # sentence they drew was the library's size rule — true, and silent
    # about the name three characters away.
    "length"   => "`size` is the spelling here: `xs.size`, `s.size`.",
    "filter"   => "`select` is the spelling here: `xs.select { |x| x > 1 }`.",
    "append"   => "`<<` appends here: `xs << 2`, and it answers the collection.",
    "push"     => "`<<` appends here: `xs << 2`, and it answers the collection.",
    # Base64's names in the other library, for what this one calls plainly:
    # `encode` already writes no line breaks, and `decode` answers text.
    "strict_encode" => "`Base64.encode` writes no line breaks here - it is the other library's `strict_encode` (`import std/base64`).",
    "strict_decode" => "`Base64.decode` is the one decoder here, and it refuses what `strict_decode` refuses (`import std/base64`).",
    "decode_string" => "`Base64.decode` answers a String here - the other library's `decode_string` (`import std/base64`).",
    "toString" => "`to_s` is the spelling here: `1.to_s`.",
    "parseInt" => "`to_i` is the spelling here: `\"1\".to_i`, and it panics on what is not a number.",
    # `Array#sum` asks the element type for its zero, because an empty
    # array has no element to ask. A type that is not a number has none,
    # and the sentence a person is missing is what to use instead.
    "zero" => "A sum starts from the type's zero, and only numbers have one (`Int32.zero`). Strings are put together with `join`, and anything else with `reduce`.",
  }

  # A top-level call whose argument arrived in Crystal's unit: the type
  # it arrived as, and what the call takes.
  IYI_ARRIVAL_ARGUMENT_HINTS = {
    "sleep" => {"Float64", "`sleep` takes milliseconds, an `Int32`: `sleep 100` is a tenth of a second."},
  }
end

class Iyi::Call
  # :nodoc:
  MAX_RENDERED_OVERLOADS = 20

  def raise_matches_not_found(owner, def_name, arg_types, named_args_types, matches = nil, with_autocast = false, number_autocast = true)
    obj = @obj
    with_scope = @with_scope

    # Special case: Foo+.class#new
    if owner.is_a?(VirtualMetaclassType) && def_name == "new"
      raise_matches_not_found_for_virtual_metaclass_new owner
    end

    if super?
      defs = owner.lookup_defs_without_parents(def_name)
    else
      defs = owner.lookup_defs(def_name)
    end

    # Also consider private top-level defs
    if owner.is_a?(Program)
      location = self.location
      if location && (filename = location.original_filename)
        private_defs = owner.file_module?(filename).try &.lookup_defs(def_name)
        defs.concat(private_defs) if private_defs
      end
    end

    # Another special case: `new` and `initialize` are only looked up one level,
    # so we must find the first one defined.
    new_owner = owner
    while defs.empty? && def_name.in?("initialize", "new")
      new_owner = new_owner.superclass
      if new_owner
        defs = new_owner.lookup_defs(def_name)
      else
        defs = [] of Def
        break
      end
    end

    # Also check with scope
    if with_scope
      defs.concat with_scope.lookup_defs(def_name)
    end

    # Check if it's the case of an abstract def
    check_abstract_def_error(owner, matches, defs, def_name)

    # Check if this is a `foo` call and we actually find it in the Program
    if !obj && defs.empty?
      program_defs = program.lookup_defs(def_name)
      unless program_defs.empty?
        defs = program_defs
        owner = program
      end
    end

    if defs.empty?
      raise_undefined_method(owner, def_name, obj)
    end

    # If we made a lookup without the special rule for literals,
    # and we have literals in the call, try again with that special rule.
    if !with_autocast && (args.any?(&.supports_autocast? number_autocast) ||
       named_args.try &.any? &.value.supports_autocast? number_autocast)
      ::raise RetryLookupWithLiterals.new
    end

    # If it's on an initialize method and there's a similar method name, it's probably a typo
    if def_name.in?("initialize", "new") && (similar_def = owner.instance_type.lookup_similar_def("initialize", self.args.size, block))
      inner_msg = colorize("do you maybe have a typo in this '#{similar_def.name}' method?").yellow.bold.to_s
      inner_exception = TypeException.for_node(similar_def, inner_msg)
    end

    # Check why each def can't be called with this Call (what's the error?)
    call_errors = defs.map do |a_def|
      compute_call_error_reason(owner, a_def, arg_types, named_args_types)
    end

    check_block_mismatch(call_errors, owner, def_name)
    call_errors.reject!(BlockMismatch)

    check_missing_named_arguments(call_errors, owner, defs, arg_types, inner_exception)
    check_extra_named_arguments(call_errors, owner, defs, arg_types, inner_exception)
    check_arguments_already_specified(call_errors, owner, defs, arg_types, inner_exception)
    check_wrong_number_of_arguments(call_errors, owner, defs, def_name, arg_types, named_args_types, inner_exception)
    check_extra_types_arguments_mismatch(call_errors, owner, defs, def_name, arg_types, named_args_types, inner_exception)
    check_arguments_type_mismatch(call_errors, owner, defs, def_name, arg_types, named_args_types, inner_exception)

    if args.size == 1 && args.first.type.includes_type?(program.nil)
      owner_trace = args.first.find_owner_trace(program, program.nil)
    else
      owner_trace = inner_exception
    end

    message = String.build do |msg|
      no_overload_matches_message(msg, full_name(owner, def_name), defs, args, arg_types, named_args_types)

      msg << "Overloads are:"
      append_matches(defs, arg_types, msg)

      if matches
        cover = matches.cover
        if cover.is_a?(Cover)
          missing = cover.missing

          uniq_arg_names = defs.map(&.args.map(&.name)).uniq!
          uniq_arg_names = uniq_arg_names.size == 1 ? uniq_arg_names.first : nil
          unless missing.empty?
            msg << "\nCouldn't find overloads for these types:"

            missing.first(MAX_RENDERED_OVERLOADS).each do |missing_types|
              if uniq_arg_names
                signature_names = missing_types.map_with_index do |missing_type, i|
                  if i >= arg_types.size && (named_arg = named_args_types.try &.[i - arg_types.size]?)
                    "#{named_arg.name} : #{missing_type}"
                  else
                    "#{uniq_arg_names[i]? || "_"} : #{missing_type}"
                  end
                end
                signature_args = signature_names.join ", "
              else
                signature_args = missing_types.join ", "
              end
              msg << "\n - #{full_name(owner, def_name)}(#{signature_args}"
              msg << ", &block" if block
              msg << ')'
            end

            if missing.size > MAX_RENDERED_OVERLOADS
              msg << "\nAnd #{missing.size - MAX_RENDERED_OVERLOADS} more..."
            end
          end
        end
      end
    end

    raise message, owner_trace
  end

  private def check_block_mismatch(call_errors, owner, def_name)
    return unless call_errors.all?(BlockMismatch)

    error_message =
      if block
        "'#{full_name(owner, def_name)}' is not expected to be invoked with a block, but a block was given"
      else
        "'#{full_name(owner, def_name)}' is expected to be invoked with a block, but no block was given"
      end

    # iyi: where Crystal passes a block to the same name, this library
    # pairs the method with a `_by` sibling — `sum` and `sum_by`, `min`
    # and `min_by`. Somebody who wrote the block is one word away, and
    # the pair is asked for rather than listed: a `_by` on this very
    # receiver is the answer, and a table would go stale.
    if block && !def_name.ends_with?("_by")
      paired = "#{def_name}_by"
      unless owner.lookup_defs(paired).empty?
        error_message += "\n\n`#{paired}` is the block form: this library " \
                         "spells \"the same question, answered per element\" " \
                         "with `_by` rather than with an overload (SPEC.md III.1.7a)"
      end
    end

    raise error_message
  end

  private def check_missing_named_arguments(call_errors, owner, defs, arg_types, inner_exception)
    gather_names_in_all_overloads(call_errors, MissingNamedArguments) do |call_errors, names|
      raise_no_overload_matches(self, defs, arg_types, inner_exception) do |str|
        if names.size == 1
          str << "missing argument: #{names.first}"
        else
          str << "missing arguments: #{names.join ", "}"
        end
      end
    end
  end

  private def check_extra_named_arguments(call_errors, owner, defs, arg_types, inner_exception)
    gather_names_in_all_overloads(call_errors, ExtraNamedArguments) do |call_errors, names|
      raise_no_overload_matches(self, defs, arg_types, inner_exception) do |str|
        quoted_names = names.map { |name| "'#{name}'" }

        if quoted_names.size == 1
          str << "no parameter named #{quoted_names.first}"
        else
          str << "no parameters named #{quoted_names.join ", "}"
        end

        # Show did you mean for the simplest case for now
        if names.size == 1 && call_errors.size == 1
          extra_name = names.first
          name_index = call_errors.first.names.index!(extra_name)
          similar_name = call_errors.first.similar_names[name_index]
          if similar_name
            str.puts
            str << "Did you mean '#{similar_name}'?"
          end
        end
      end
    end
  end

  private def check_arguments_already_specified(call_errors, owner, defs, arg_types, inner_exception)
    gather_names_in_all_overloads(call_errors, ArgumentsAlreadySpecified) do |call_errors, names|
      raise_no_overload_matches(self, defs, arg_types, inner_exception) do |str|
        quoted_names = names.map { |name| "'#{name}'" }

        if quoted_names.size == 1
          str << "argument for parameter #{quoted_names.first} already specified"
        else
          str << "arguments for parameters #{quoted_names.join ", "} already specified"
        end
      end
    end
  end

  private def gather_names_in_all_overloads(call_errors, error_type : T.class, &) forall T
    return unless call_errors.all?(T)

    call_errors = call_errors.map &.as(T)
    all_names = call_errors.flat_map(&.names).uniq!
    names_in_all_overloads = all_names.select do |missing_name|
      call_errors.all? &.names.includes?(missing_name)
    end
    unless names_in_all_overloads.empty?
      yield call_errors, names_in_all_overloads
    end
  end

  private def check_wrong_number_of_arguments(call_errors, owner, defs, def_name, arg_types, named_args_types, inner_exception)
    return unless call_errors.all?(WrongNumberOfArguments)

    raise_matches_not_found_named_args(owner, def_name, defs, arg_types, named_args_types, inner_exception)
  end

  private def check_extra_types_arguments_mismatch(call_errors, owner, defs, def_name, arg_types, named_args_types, inner_exception)
    call_errors = call_errors.select(ArgumentsTypeMismatch)
    return if call_errors.empty?

    call_errors = call_errors.map &.as(ArgumentsTypeMismatch)
    argument_type_mismatches = call_errors.flat_map(&.errors)

    argument_type_mismatches.select!(&.extra_types)
    return if argument_type_mismatches.empty?

    argument_type_mismatches.each do |target_error|
      index_or_name = target_error.index_or_name

      mismatches = argument_type_mismatches.select(&.index_or_name.==(index_or_name))
      expected_types = mismatches.map(&.expected_type).uniq!
      actual_type = mismatches.first.actual_type

      actual_types =
        if actual_type.is_a?(UnionType)
          actual_type.union_types
        else
          [actual_type] of Type
        end

      # It could happen that a type that's missing in one overload is actually
      # covered in another overload, and eventually all overloads are covered
      if expected_types.to_set == actual_types.to_set
        expected_types = [target_error.expected_type]
      end

      raise_argument_type_mismatch(index_or_name, actual_type, expected_types.sort_by!(&.to_s), owner, defs, def_name, arg_types, inner_exception)
    end
  end

  private def check_arguments_type_mismatch(call_errors, owner, defs, def_name, arg_types, named_args_types, inner_exception)
    call_errors = call_errors.select(ArgumentsTypeMismatch)
    return if call_errors.empty?

    call_errors = call_errors.map &.as(ArgumentsTypeMismatch)
    argument_type_mismatches = call_errors.flat_map(&.errors)

    all_indexes_or_names = argument_type_mismatches.map(&.index_or_name).uniq!
    indexes_or_names_in_all_overloads = all_indexes_or_names.select do |index_or_name|
      call_errors.all? &.errors.any? &.index_or_name.==(index_or_name)
    end

    return if indexes_or_names_in_all_overloads.empty?

    # Only show the first error. We'll still list all overloads.
    index_or_name = indexes_or_names_in_all_overloads.first

    mismatches = argument_type_mismatches.select(&.index_or_name.==(index_or_name))
    expected_types = mismatches.map(&.expected_type).uniq!.sort_by!(&.to_s)
    actual_type = mismatches.first.actual_type

    raise_argument_type_mismatch(index_or_name, actual_type, expected_types, owner, defs, def_name, arg_types, inner_exception)
  end

  private def raise_argument_type_mismatch(index_or_name, actual_type, expected_types, owner, defs, def_name, arg_types, inner_exception)
    arg =
      case index_or_name
      in Int32
        args[index_or_name]?
      in String
        named_args.try &.find(&.name.==(index_or_name))
      end

    enum_types = expected_types.select(EnumType)
    if actual_type.is_a?(SymbolType) && enum_types.size == 1
      enum_type = enum_types.first

      if arg.is_a?(SymbolLiteral)
        symbol = arg.value
      elsif arg.is_a?(NamedArgument) && (named_arg_value = arg.value).is_a?(SymbolLiteral)
        symbol = named_arg_value.value
      end
    end

    # iyi: a one-character string where a `Char` is wanted is the guess
    # every arrival from another language or a model makes about `split`,
    # `index`, `chomp` — the prelude takes a `Char` and there is exactly
    # one right spelling. Say it, and hand it over as an edit spanning the
    # literal, so `iyi fix` and the editor's quickfix apply it without a
    # round (AI_FIRST.md §5, the fourth run).
    char_fix = nil
    char_span = nil
    if arg.is_a?(StringLiteral) && arg.value.size == 1 && expected_types.size == 1 && expected_types.first.is_a?(CharType)
      char_fix = arg.value[0].inspect
      if (from = arg.location) && (to = arg.end_location) && from.line_number == to.line_number
        char_span = to.column_number - from.column_number + 1
      end
    end

    raise_no_overload_matches(arg || self, defs, arg_types, inner_exception, suggestion: char_span ? char_fix : nil, size: char_span) do |str|
      argument_description =
        case index_or_name
        in Int32
          "##{index_or_name + 1}"
        in String
          "'#{index_or_name}'"
        end

      if symbol && enum_type
        str << "expected argument #{argument_description} to '#{full_name(owner, def_name)}' to match a member of enum #{enum_type}."
        str.puts
        str.puts

        options = enum_type.types.map(&.[1].name.underscore)
        similar_name = Levenshtein.find(symbol.underscore, options)
        if similar_name
          str << "Did you mean :#{similar_name}?"
        elsif options.size <= 10
          str << "Options are: "
          to_sentence(str, options.map { |o| ":#{o}" }, " and ")
        end
      else
        str << "expected argument #{argument_description} to '#{full_name(owner, def_name)}' to be "
        to_sentence(str, expected_types, " or ")
        str << ", not #{actual_type.devirtualize}"

        if char_fix
          str.puts
          str.puts
          str << "Did you mean #{char_fix}? A one-character string is still a "
          str << "`String`; `#{def_name}` takes a `Char`, written in single quotes"
        end

        # iyi: a trait is not a class, so "not Dog" is the whole answer only if
        # the reader already knows that the way to satisfy it is an `impl`
        # written somewhere specific. R-3 says where: with the trait, or with
        # the type. Nowhere else, and the message names both.
        if wanted = expected_types.find { |type| type.is_a?(Type) && type.trait? }
          actual = actual_type.devirtualize
          str.puts
          str.puts
          str << "`#{actual}` does not implement `#{wanted}`. Write "
          str << "`impl #{wanted} for #{actual}` in the module that declares "
          str << "`#{wanted}` or in the one that declares `#{actual}` — R-3 "
          str << "allows those two and no others (SPEC.md IV.4)"
        end

        # iyi: a unit somebody arriving from Crystal has otherwise
        # (`IYI_ARRIVAL_ARGUMENT_HINTS`).
        if owner.is_a?(Program) && (hint = Iyi::IYI_ARRIVAL_ARGUMENT_HINTS[def_name]?) && actual_type.devirtualize.to_s == hint[0]
          str.puts
          str.puts
          str << hint[1]
        end
      end
    end
  end

  private def to_sentence(str : IO, elements : Array, last_connector : String)
    elements.each_with_index do |element, i|
      if i == elements.size - 1 && elements.size > 1
        str << last_connector
      elsif i > 0
        str << ", "
      end
      str << element
    end
  end

  private def raise_no_overload_matches(node, defs, arg_types, inner_exception, suggestion : String? = nil, size : Int32? = nil, &)
    error_message = String.build do |str|
      yield str

      str.puts
      str.puts
      str << "Overloads are:"
      append_matches(defs, arg_types, str)
    end

    node.raise(error_message, inner_exception, suggestion: suggestion, size: size)
  end

  record WrongNumberOfArguments
  record MissingNamedArguments, names : Array(String)
  record BlockMismatch
  record ExtraNamedArguments, names : Array(String), similar_names : Array(String?)
  record ArgumentsAlreadySpecified, names : Array(String)
  record ArgumentsTypeMismatch, errors : Array(ArgumentTypeMismatch)
  record ArgumentTypeMismatch,
    index_or_name : (Int32 | String),
    expected_type : Type | ASTNode,
    actual_type : Type,
    extra_types : Array(Type)?

  private def compute_call_error_reason(owner, a_def, arg_types, named_args_types)
    if (block && !a_def.block_arity) || (!block && a_def.block_arity)
      return BlockMismatch.new
    end

    if !named_args_types
      min_size, max_size = a_def.min_max_args_sizes
      unless min_size <= arg_types.size <= max_size
        return WrongNumberOfArguments.new
      end
    end

    missing_named_args = extract_missing_named_args(a_def, named_args)
    if missing_named_args
      return MissingNamedArguments.new(missing_named_args)
    end

    arguments_already_specified = [] of String
    extra_named_argument_names = [] of String
    extra_named_argument_similar_names = [] of String?

    named_args_types.try &.each do |named_arg|
      found_index = a_def.args.index { |arg| arg.external_name == named_arg.name }
      if found_index
        min_size = arg_types.size
        if found_index < min_size
          arguments_already_specified << named_arg.name
        end
      elsif !a_def.double_splat
        similar_name = Levenshtein.find(named_arg.name, a_def.args.select(&.default_value).map(&.external_name))

        extra_named_argument_names << named_arg.name
        extra_named_argument_similar_names << similar_name
      end
    end

    unless arguments_already_specified.empty?
      return ArgumentsAlreadySpecified.new(arguments_already_specified)
    end

    unless extra_named_argument_names.empty?
      return ExtraNamedArguments.new(extra_named_argument_names, extra_named_argument_similar_names)
    end

    # For now let's not deal with splats
    return if a_def.splat_index

    a_def_owner = a_def.owner

    # This is the actual instantiated type where the method was instantiated
    instantiated_owner = owner

    owner.ancestors.each do |ancestor|
      if a_def_owner == ancestor
        instantiated_owner = ancestor
        break
      end

      # If the method is defined in a generic uninstantiated type
      # then the method instantiation happens on the instantiated generic
      # type whose generic type is that uninstantiated one.
      if a_def_owner.is_a?(GenericType) &&
         ancestor.is_a?(GenericInstanceType) &&
         ancestor.generic_type == a_def_owner
        instantiated_owner = ancestor
        break
      end
    end

    match_context = MatchContext.new(
      instantiated_type: instantiated_owner,
      defining_type: instantiated_owner,
      def_free_vars: a_def.free_vars,
    )

    arguments_type_mismatch = [] of ArgumentTypeMismatch

    arg_types.each_with_index do |arg_type, i|
      def_arg = a_def.args[i]?
      next unless def_arg

      check_argument_type_mismatch(def_arg, i, arg_type, match_context, arguments_type_mismatch)
    end

    named_args_types.try &.each do |named_arg|
      def_arg = a_def.args.find &.external_name.==(named_arg.name)
      next unless def_arg

      check_argument_type_mismatch(def_arg, named_arg.name, named_arg.type, match_context, arguments_type_mismatch)
    end

    unless arguments_type_mismatch.empty?
      return ArgumentsTypeMismatch.new(arguments_type_mismatch)
    end

    nil
  end

  private def check_argument_type_mismatch(def_arg, index_or_name, arg_type, match_context, arguments_type_mismatch)
    restricted = arg_type.restrict(def_arg, match_context)

    arg_type = arg_type.remove_literal
    return if restricted == arg_type

    expected_type = compute_expected_type(def_arg, match_context)

    extra_types =
      if restricted
        # This was a partial match
        compute_extra_types(arg_type, expected_type)
      else
        # This wasn't a match
        nil
      end

    arguments_type_mismatch << ArgumentTypeMismatch.new(
      index_or_name: index_or_name,
      expected_type: expected_type,
      actual_type: arg_type.remove_literal,
      extra_types: extra_types,
    )
  end

  private def compute_expected_type(def_arg, match_context)
    expected_type = def_arg.type?
    unless expected_type
      restriction = def_arg.restriction
      if restriction
        expected_type = match_context.instantiated_type.lookup_type?(restriction, free_vars: match_context.bound_free_vars)
      end
    end
    expected_type ||= def_arg.restriction.not_nil!
    expected_type = expected_type.devirtualize if expected_type.is_a?(Type)
    expected_type
  end

  private def compute_extra_types(actual_type, expected_type)
    expected_types =
      if expected_type.is_a?(UnionType)
        expected_type.union_types
      elsif expected_type.is_a?(Type)
        [expected_type] of Type
      else
        return
      end

    actual_types =
      if actual_type.is_a?(UnionType)
        actual_type.union_types
      else
        [actual_type] of Type
      end

    actual_types - expected_types
  end

  private def no_overload_matches_message(io, full_name, defs, args, arg_types, named_args_types)
    if message = single_def_error_message(defs, named_args_types)
      io << message
      io << '\n'
      return
    end

    io << "no overload matches '#{full_name}'"
    unless args.empty?
      io << " with type"
      io << 's' if arg_types.size > 1 || named_args_types
      io << ' '
      arg_types.join(io, ", ")
    end

    if named_args_types
      named_args_types.each do |named_arg|
        io << ", "
        io << named_arg.name
        io << ": "
        io << named_arg.type
      end
    end

    io << '\n'
  end

  # iyi: what "undefined method" means most often in this language.
  #
  # R-2b keeps an imported module's names qualified until the file writes
  # `using`, so the commonest way to reach this error is to import a module and
  # call one of its functions the way every other language would. The compiler
  # knows the name, knows which module has it and knows whether it is `pub`;
  # "undefined local variable or method 'polite'" says none of the three.
  #
  # Nothing here fires for a Crystal program: `iyi_unit?` is false for every
  # Crystal module, so the search finds nobody and the message is unchanged.
  # A type the prelude declares: one the compiler itself declares (String,
  # Array, the numbers - no location of their own) or one whose first
  # location is under `src/iyi/`. A class the program declares has its
  # file.
  private def iyi_prelude_type?(owner) : Bool
    return false unless program.iyi_prelude?
    type = owner.is_a?(MetaclassType) ? owner.instance_type : owner
    type = type.generic_type if type.is_a?(GenericInstanceType)
    return false unless type.is_a?(NamedType)
    location = type.locations.try(&.first?)
    return true unless location
    filename = location.filename
    return false unless filename.is_a?(String)
    # The posix reading, for the platform whose paths are spelled with `\`:
    # `iyi doc` asked the same question the same way and on Windows
    # answered it wrong for every macro-written operator.
    posix = ::Path[filename].to_posix.to_s
    posix.includes?("/src/iyi/") || posix.starts_with?("src/iyi/")
  end

  # iyi: the integer tower is one module's, made by macros over a table of
  # types, so the trait walk below cannot see it: `std/int` gives `UInt32`
  # its arithmetic, every integer `<<`, `>>`, `<=>` and the `to_u32`
  # family. A port that reached for `1_u32 + x` was told the prelude is
  # small by rule and concluded `UInt32` had no methods at all. The names
  # are read off the module's text: a `def`, a `%w(...)` operator list, or
  # a quoted conversion name.
  private def iyi_std_int_hint(program, name : String, owner) : String?
    return nil unless owner.instance_type.is_a?(IntegerType)
    program.iyi_path.entries.each do |entry|
      path = File.join(entry, "std", "int.iyi")
      next unless File.file?(path)
      text = File.read(path)
      named = text.includes?("def #{name}(") || text.includes?("def #{name} ") ||
              text.includes?("\"#{name}\"") ||
              text.each_line.any? do |line|
                line.includes?("%w(") && line.split("%w(", 2)[1].split(')', 2)[0].split(' ').includes?(name)
              end
      return nil unless named
      return "`#{name}` on #{owner.instance_type} is in `std/int`, the module that makes " \
             "the whole integer tower usable: `import std/int`."
    end
    nil
  end

  # The `std/<module>` that would put `name` on this receiver, and how.
  #
  # "undefined method 'tally' for Array(Int32)" is true and useless when
  # `import std/enumerable` is the whole answer: std implements
  # `Enumerable` for the prelude's collections (R-3 lets the module that
  # owns the trait say so), and the method the person asked for is one
  # line away. The prelude-is-small note that used to be printed here
  # sent them to `iyi doc` or to `--crystal` for something the library
  # already has.
  #
  # Read off the search path the way an import is resolved, on the error
  # path only, and by walking strings rather than a `Regex`: the
  # compiler links no pcre2 (SPEC.md III.9).
  private def iyi_std_method_hint(program, name : String, owner) : String?
    bare = owner.instance_type.to_s.split('(').first
    return nil if bare.empty?

    program.iyi_path.entries.each do |entry|
      dir = File.join(entry, "std")
      next unless Dir.exists?(dir)
      Dir.each_child(dir) do |file|
        next unless file.ends_with?(".iyi")
        path = File.join(dir, file)
        next unless File.file?(path)
        text = File.read(path)
        next unless implemented = iyi_std_trait_with_method(text, name, bare)
        written = "std/#{file.rchop(".iyi")}"
        return "`#{written}` implements `#{implemented}` for #{bare} and that is where " \
               "`#{name}` is: `import #{written}` puts it on this receiver " \
               "(SPEC.md R-3)."
      end
    end
    nil
  end

  # The trait in *text* that declares `def name` and is implemented for
  # `bare` in the same file. Both halves have to be there: a trait with
  # the method and no impl for this type would name an import that
  # changes nothing.
  private def iyi_std_trait_with_method(text : String, name : String, bare : String) : String?
    # `trait` is a keyword here, so the name of the thing this walk is
    # tracking cannot be spelled the obvious way.
    enclosing = nil
    found = nil
    text.each_line do |line|
      if line.starts_with?("pub trait ")
        rest = line["pub trait ".size..]
        enclosing = rest.split('(').first.split(' ').first.strip
      elsif line.starts_with?("pub ") || line.starts_with?("class ")
        # A top-level declaration that is not a trait ends the one above.
        enclosing = nil
      end
      next unless enclosing
      stripped = line.lstrip
      next unless stripped.starts_with?("def ")
      rest = stripped["def ".size..]
      next unless rest.starts_with?(name)
      after = rest[name.size]?
      next unless after.nil? || !(after.alphanumeric? || after == '_')
      found = enclosing
      break
    end
    return nil unless declares = found

    # `impl Enumerable for Array(T)` - the line R-3 makes the owning
    # module write.
    text.each_line do |line|
      next unless line.starts_with?("impl ")
      rest = line["impl ".size..]
      next unless rest.starts_with?(declares)
      after_trait = rest[declares.size..]
      index = after_trait.index(" for ")
      next unless index
      target = after_trait[(index + 5)..].strip.split('(').first.split(' ').first
      return declares if target == bare
    end
    nil
  end

  private def iyi_out_of_reach_hint(def_name : String, obj) : String?
    return nil if obj

    exporting = [] of Type
    hiding = [] of Type
    iyi_each_unit(program) do |mod|
      next unless mod.defs.try &.has_key?(def_name)
      (mod.exported_name?(def_name) ? exporting : hiding) << mod
    end

    unless exporting.empty?
      written = exporting.map { |mod| iyi_written_path(mod) }
      qualified = "#{exporting.first}.#{def_name}"
      return "`#{def_name}` is exported by #{written.map { |path| "`#{path}`" }.join(" and ")}, " \
             "and this file has not written `using`. Add `using #{written.first}` " \
             "to bring its names in unqualified, or call it as `#{qualified}` " \
             "(SPEC.md R-2b)"
    end

    unless hiding.empty?
      written = iyi_written_path(hiding.first)
      return "`#{written}` declares `#{def_name}` and does not mark it `pub`, " \
             "so it is the module's own and no other module can reach it " \
             "(SPEC.md R-2)"
    end

    nil
  end

  # The written form of a unit's path: `App::Greeter` is `app/greeter`, which
  # is what a `using` is spelled with and what the file is called.
  private def iyi_written_path(type : Type) : String
    type.to_s.split("::").map(&.underscore).join('/')
  end

  private def iyi_each_unit(type, &block : ModuleType ->) : Nil
    type.types?.try &.each_value do |nested|
      block.call(nested) if nested.is_a?(ModuleType) && nested.iyi_unit?
      iyi_each_unit(nested, &block)
    end
  end

  # iyi: `sorted` for `sort`, `reversed` for `reverse`, `sorted_by` for
  # `sort_by` — the participle this library uses where Crystal's library
  # uses the plain verb, inflected on the verb, the first word of the name.
  #
  # Asked of the type rather than of a list, so it answers for whatever the
  # library grows next and stays quiet for a name nobody spelled that way.
  private def iyi_participle_for(def_name : String, owner) : String?
    return nil if def_name.ends_with?('=') || def_name.ends_with?('?')

    verb, sep, rest = def_name.partition('_')
    return nil if verb.empty?
    tail = sep + rest
    # `sorted`, `reversed`, `mapped`: the three ways English spells the
    # participle of a short verb.
    last = verb[-1]
    {"#{verb}ed#{tail}", "#{verb}d#{tail}", "#{verb}#{last}ed#{tail}"}.each do |candidate|
      next if candidate == def_name
      return candidate if owner.lookup_defs(candidate).any?(&.visibility.public?)
    end

    nil
  end

  # Every name the scope's `using` lines brought into unqualified reach,
  # Levenshtein'd. A selective `using m::{add}` contributes its selection;
  # a bare `using m` contributes the module's exported names. The walk is
  # the same namespace climb the call's own lookup performs (call.cr's
  # using walk), seeded the same way: `owner.instance_type`, because the
  # owner of code in a module body is the metaclass and the directive was
  # recorded on the module itself.
  IYI_PSEUDO_METHODS = %w(is_a? nil? responds_to? as as? or_panic or)

  private def lookup_similar_using_name(owner, def_name : String) : String?
    candidates = [] of String
    scope_type = owner.instance_type
    while scope_type
      # The unit's own functions are in scope for the types declared in it
      # - `shout(...)` inside `impl Greet for User` reaches the module's
      # `def shout` - so they are candidates for a call inside one of its
      # types too; `shut` went unsuggested while `shout` sat in the file.
      if scope_type.is_a?(ModuleType) && scope_type.iyi_unit?
        scope_type.defs.try &.each_key { |name| candidates << name }
      end
      if used = scope_type.using_modules?
        used.each do |using_module|
          if names = using_module.names
            candidates.concat(names)
          elsif exported = using_module.type.as?(ModuleType).try(&.exported_names)
            candidates.concat(exported)
          end
        end
      end
      break if scope_type == program
      scope_type = scope_type.is_a?(NamedType) ? scope_type.namespace : nil
    end
    candidates.uniq!
    candidates.delete(def_name)
    return nil if candidates.empty?
    Levenshtein.find(def_name, candidates)
  end

  private def raise_undefined_method(owner, def_name, obj)
    check_macro_wrong_number_of_arguments(owner, def_name)

    owner_trace = obj.try &.find_owner_trace(owner.program, owner)
    similar_name = owner.lookup_similar_def_name(def_name, self.args.size, block)
    # iyi: the name may have arrived through `using`, and those names live
    # on the scope's using list rather than on the owner — the exact miss
    # that made `addd` go unsuggested while `add` sat one edit away in
    # the file's own `using` line. Receiverless calls only: a `using`
    # name is by definition unqualified.
    similar_name ||= lookup_similar_using_name(owner, def_name) unless obj
    # iyi: the compiler's own pseudo-methods are on no type's def list, so
    # `x.i_a?(T)` was "undefined method" with nothing near it. They are
    # names a call can be a typo of like any other.
    similar_name ||= Levenshtein.find(def_name, IYI_PSEUDO_METHODS) if obj && def_name.size >= 3

    # The name that the span under this error can be *replaced with* — set
    # only where that is literally true: the suggestion names a different
    # def and the error's own span is the call's name. The ivar aside
    # below reuses `similar_name` for a different token, so the edit is
    # pinned here, not read at the end.
    suggested_edit = nil

    error_msg = String.build do |msg|
      if obj
        could_be_local_variable = false
      elsif logical_op = convert_to_logical_operator(def_name)
        similar_name = logical_op
        could_be_local_variable = false
      elsif args.size > 0 || has_parentheses?
        could_be_local_variable = false
      else
        # This check is for the case `a if a = 1`
        similar_name = parent_visitor.lookup_similar_var_name(def_name) unless similar_name
        could_be_local_variable = (similar_name != def_name)
      end

      if could_be_local_variable
        msg << "undefined local variable or method '#{def_name}'"
      else
        msg << "undefined method '#{def_name}'"
      end

      owner_name = owner.is_a?(Program) ? "top-level" : owner.to_s

      if with_scope && !obj && with_scope != owner
        msg << " for #{with_scope} (with ... yield) and #{owner_name} (current scope)"
      else
        msg << " for #{owner_name}"
      end

      if def_name == "allocate" && owner.is_a?(MetaclassType) && owner.instance_type.module?
        msg << colorize(" (modules cannot be instantiated)").yellow.bold
      end

      if obj && obj.type != owner
        msg << colorize(" (compile-time type is #{obj.type})").yellow.bold
        # iyi: a nilable receiver is the commonest shape this error takes,
        # and the sentence above names the type without saying what to
        # do; the two idioms are one line each.
        if owner.is_a?(NilType)
          receiver = obj.is_a?(Var) || obj.is_a?(InstanceVar) ? obj.to_s : "the receiver"
          narrowed = obj.is_a?(Var) ? "if #{receiver}" : "if value = #{receiver}"
          msg << '\n' << "#{receiver} can be nil here: narrow it first (`#{narrowed}`) or give the nil an answer (`#{receiver} || default`)"
        end
      end

      if similar_name
        msg << '\n'
        if similar_name == def_name
          # This check is for the case `a if a = 1`
          msg << "If you declared '#{def_name}' in a suffix if, declare it in a regular if for this to work. If the variable was declared in a macro it's not visible outside it."
        elsif similar_name.size > 1 && similar_name.ends_with?('!')
          # iyi: a name this language cannot write. `!` is not part of a name
          # here (SPEC.md III.1.7), so the nearest thing to `not_nil` in
          # Crystal's library — or to `sort` in a bound shard's — is a name no
          # call in a `.iyi` file can spell. Suggesting it was worse than
          # saying nothing: the edit travels in `check -f json` as
          # `suggested_edit`, and `iyi fix` applies those, so the answer to an
          # undefined method was a file that no longer parses.
          msg << "'#{similar_name}' is what that library calls it, and `!` cannot end a name in iyi (SPEC.md III.1.7): no call written here can spell it. Reach it through a Crystal-side method whose name this language can write."
        else
          msg << "Did you mean '#{similar_name}'?"
          suggested_edit = similar_name
        end
      end

      # iyi: the participle is there and the plain verb is not (SPEC.md
      # III.1.7a).
      #
      # `!` cannot end a name here, so the pair Crystal spells `sort` and
      # `sort!` is spelled `sorted` and `sort_in_place`. Somebody arriving from
      # Crystal writes the plain verb, and "undefined method 'sort'" is true
      # and teaches nothing. The suggestion machinery above will not reach it —
      # `sort` to `sorted` is two edits — so the rule says it instead.
      if !similar_name && (participle = iyi_participle_for(def_name, owner))
        msg << '\n' << "'#{participle}' is what this library calls it: `!` cannot end a name here, so the copy takes the participle and the one that changes the receiver says so (SPEC.md III.1.7a)"
        # The participle *is* the name to type here — as much an edit as
        # a Levenshtein hit, and the reason the rule exists.
        suggested_edit = participle
      end

      # iyi: the name is usually not missing, it is out of reach.
      if hint = iyi_out_of_reach_hint(def_name, obj)
        msg << '\n' << hint
      end

      # iyi: Crystal's spelling for something the prelude has under
      # another name (`IYI_ARRIVAL_CALL_HINTS`, `IYI_ARRIVAL_METHOD_HINTS`).
      if !obj && !similar_name && (arrival = Iyi::IYI_ARRIVAL_CALL_HINTS[def_name]?)
        msg << '\n' << arrival
      end
      # iyi: the method itself, on this integer, one import away: said
      # before a spelling that is merely near it (`to_u32` is not a typo of
      # `to_i32`) and before an arrival note meant for another receiver.
      if obj && (integers = iyi_std_int_hint(program, def_name, owner))
        msg << '\n' << integers
      elsif obj && !similar_name && (arrival = Iyi::IYI_ARRIVAL_METHOD_HINTS[def_name]?)
        fits = case def_name
               when "/" then owner.is_a?(IntegerType)
               when "%" then owner.to_s == "String"
               else          true
               end
        msg << '\n' << arrival if fits
      elsif obj && !similar_name && !participle && iyi_prelude_type?(owner)
        # iyi: a method Crystal's library has and this one does not, on a
        # type the prelude declares, with nothing near it in spelling:
        # the reader is looking at the library's size rule, not a typo —
        # unless std has the method for this very type, in which case the
        # rule is not what they need to hear and the import is.
        bare = owner.instance_type.to_s.split('(').first
        if reachable = iyi_std_method_hint(program, def_name, owner)
          msg << '\n' << reachable
        else
          msg << '\n' << "iyi's prelude has no `#{def_name}` on #{owner}: it is small by rule - a method enters when a program in the repository needs it (SPEC.md III.1). `iyi doc #{bare}` lists what it has; `iyi build --crystal` gives a program Crystal's library instead (README.md, \"The library a program has\")."
        end
      end

      # Check if it's an instance variable that was never assigned a value
      if obj.is_a?(InstanceVar)
        scope = self.scope
        ivar = scope.lookup_instance_var(obj.name)
        if ivar.dependencies.size == 1 && ivar.dependencies.first.same?(program.nil_var)
          similar_name = scope.lookup_similar_instance_var_name(ivar.name)
          if similar_name
            msg << colorize(" (#{ivar.name} was never assigned a value, did you mean #{similar_name}?)").yellow.bold
          else
            msg << colorize(" (#{ivar.name} was never assigned a value)").yellow.bold
          end
        end
      end
    end
    raise error_msg, owner_trace, suggestion: suggested_edit
  end

  private def raise_matches_not_found_named_args(owner, def_name, defs, arg_types, named_args_types, inner_exception)
    all_arguments_sizes = [] of Int32
    min_splat = Int32::MAX
    defs.each do |a_def|
      next if (block && !a_def.block_arity) || (!block && a_def.block_arity)

      min_size, max_size = a_def.min_max_args_sizes
      if max_size == Int32::MAX
        min_splat = Math.min(min_size, min_splat)
        all_arguments_sizes.push min_splat
      else
        min_size.upto(max_size) do |size|
          all_arguments_sizes.push size
        end
      end
    end
    all_arguments_sizes.uniq!.sort!

    raise(String.build do |str|
      if single_message = single_def_error_message(defs, named_args_types)
        str << single_message
        str << '\n'
      else
        str << "wrong number of arguments for '"
        str << full_name(owner, def_name)
        str << "' (given "
        str << arg_types.size
        str << ", expected "

        # If we have 2, 3, 4, show it as 2..4
        if all_arguments_sizes.size > 1 && all_arguments_sizes.last - all_arguments_sizes.first == all_arguments_sizes.size - 1
          str << all_arguments_sizes.first
          str << ".."
          str << all_arguments_sizes.last
        else
          all_arguments_sizes.join str, ", "
        end

        str << '+' if min_splat != Int32::MAX
        str << ")\n"
      end
      str << "Overloads are:"
      append_matches(defs, arg_types, str)
    end, inner: inner_exception)
  end

  def convert_to_logical_operator(def_name)
    case def_name
    when "and"; "&&"
    when "or" ; "||"
    when "not"; "!"
    else        nil
    end
  end

  def single_def_error_message(defs, named_args)
    if defs.size == 1
      missing_argument_message(defs.first, named_args)
    end
  end

  def missing_argument_message(a_def, named_args)
    missing_args = extract_missing_named_args(a_def, named_args)
    return unless missing_args

    if missing_args.size == 1
      "missing argument: #{missing_args.first}"
    else
      "missing arguments: #{missing_args.join ", "}"
    end
  end

  def extract_missing_named_args(a_def, named_args)
    splat_index = a_def.splat_index
    return if !splat_index && !named_args
    return if splat_index == a_def.args.size - 1

    # Check if some mandatory arguments are missing
    mandatory_args = BitArray.new(a_def.args.size)
    a_def.match(args) do |arg, arg_index, call_arg, call_arg_index|
      mandatory_args[arg_index] = true
    end

    named_args.try &.each do |named_arg|
      found_index = a_def.args.index { |arg| arg.external_name == named_arg.name }
      if found_index
        mandatory_args[found_index] = true
      end
    end

    missing_args = [] of String
    mandatory_args.each_with_index do |value, index|
      next if value

      arg = a_def.args[index]
      next if arg.default_value
      next if arg.external_name.empty?

      missing_args << arg.external_name
    end

    return if missing_args.size.zero?

    missing_args
  end

  def check_abstract_def_error(owner, matches, defs, def_name)
    return unless !matches || (matches.try &.empty?)
    return unless defs.all? &.abstract?

    named_args_types = NamedArgumentType.from_args(named_args)
    signature = CallSignature.new(def_name, args.map(&.type), block, named_args_types)
    defs.each do |a_def|
      context = MatchContext.new(owner, a_def.owner, def_free_vars: a_def.free_vars)
      match = signature.match(DefWithMetadata.new(a_def), context)
      next unless match

      if a_def.owner == owner
        owner.all_subclasses.each do |subclass|
          submatches = subclass.lookup_matches(signature)
          if submatches.empty?
            raise_abstract_method_must_be_implemented a_def, subclass
          end
        end
        raise_abstract_method_must_be_implemented a_def, owner
      else
        raise_abstract_method_must_be_implemented a_def, owner
      end
    end
  end

  def raise_abstract_method_must_be_implemented(a_def, owner)
    if owner.abstract?
      raise "undefined method '#{def_full_name(a_def.owner, a_def)}'"
    else
      raise "abstract `def #{def_full_name(a_def.owner, a_def)}` must be implemented by #{owner}"
    end
  end

  def append_matches(defs, arg_types, str, *, matched_def = nil, argument_name = nil)
    defs.each do |a_def|
      next if a_def.abstract?
      str << "\n - "
      append_def_full_name a_def.owner, a_def, arg_types, str
      if defs.size > 1 && a_def.same?(matched_def)
        str << colorize(" (trying this one)").blue
      end
      if a_def.args.any? { |arg| arg.default_value && arg.external_name == argument_name }
        str << colorize(" (did you mean this one?)").yellow.bold
      end
    end
  end

  def def_full_name(owner, a_def, arg_types = nil)
    Call.def_full_name(owner, a_def, arg_types)
  end

  def self.def_full_name(owner, a_def, arg_types = nil)
    String.build { |io| append_def_full_name(owner, a_def, arg_types, io) }
  end

  def append_def_full_name(owner, a_def, arg_types, str)
    Call.append_def_full_name(owner, a_def, arg_types, str)
  end

  def self.append_def_full_name(owner, a_def, arg_types, str)
    str << full_name(owner, a_def.name)
    str << '('
    printed = false
    a_def.args.each_with_index do |arg, i|
      str << ", " if printed
      str << '*' if a_def.splat_index == i

      if arg.external_name != arg.name
        str << (arg.external_name.presence || '_')
        str << ' '
      end

      str << arg.name

      if arg_type = arg.type?
        str << " : "
        str << arg_type
      elsif res = arg.restriction
        str << " : "
        if owner.is_a?(GenericClassInstanceType) && res.is_a?(Path) && res.names.size == 1 &&
           (type_var = owner.type_vars[res.names[0]]?)
          str << type_var.type
        else
          # Try to use the full name if the argument type and the call
          # argument type have the same string representation
          res_to_s = res.to_s
          if (arg_type = arg_types.try &.[i]?) && arg_type.to_s == res_to_s &&
             (matching_type = a_def.owner.lookup_type?(res))
            str << matching_type
          else
            str << res_to_s
          end
        end
      end
      if arg_default = arg.default_value
        str << " = "
        str << arg_default
      end
      printed = true
    end

    if a_def.double_splat
      str << ", " if printed
      str << "**" << a_def.double_splat
      printed = true
    end

    if a_def.block_arity
      str << ", " if printed
      str << '&'
      if block_arg = a_def.block_arg
        str << block_arg
      end
    end
    str << ')'

    if free_vars = a_def.free_vars
      str << " forall "
      free_vars.join(str, ", ")
    end
  end

  def raise_matches_not_found_for_virtual_metaclass_new(owner)
    owner.each_concrete_type do |concrete_type|
      defs = concrete_type.instance_type.lookup_defs_with_modules("initialize")
      defs = defs.select { |a_def| a_def.args.size != args.size }
      unless defs.empty?
        all_arguments_sizes = Set(Int32).new
        defs.each { |a_def| all_arguments_sizes << a_def.args.size }
        wrong_number_of_arguments "'#{concrete_type.instance_type}#initialize'", args.size, all_arguments_sizes.join(", ")
      end
    end
  end

  def check_macro_wrong_number_of_arguments(owner, def_name)
    return if (obj = self.obj) && !obj.is_a?(Path)

    macros = if obj
               owner.lookup_macros(def_name)
             else
               in_macro_target &.lookup_macros(def_name)
             end
    return unless macros.is_a?(Array(Macro))

    if msg = single_def_error_message(macros, named_args)
      raise msg
    end

    all_arguments_sizes = Set(String).new
    macros.each do |a_macro|
      named_args.try &.each do |named_arg|
        index = a_macro.args.index { |arg| arg.external_name == named_arg.name }
        if index
          if index < args.size
            raise "argument for parameter '#{named_arg.name}' already specified"
          end
        else
          raise "no parameter named '#{named_arg.name}'"
        end
      end

      plus = false

      splat_index = a_macro.splat_index
      if splat_index
        if a_macro.args[splat_index].name.empty?
          min_size = max_size = splat_index
        else
          min_size = splat_index
          max_size = a_macro.args.size
          plus = true
        end
      else
        min_size = a_macro.args.index(&.default_value) || a_macro.args.size
        max_size = a_macro.args.size
      end

      if plus
        all_arguments_sizes << "#{min_size}+"
      else
        min_size.upto(max_size) do |args_size|
          all_arguments_sizes << args_size.to_s
        end
      end
    end

    wrong_number_of_arguments "macro '#{def_name}'", args.size, all_arguments_sizes.join(", ")
  end

  def check_visibility(match)
    case match.def.visibility
    when .private?
      if obj = @obj
        if obj.is_a?(Var) && obj.name == "self"
          # Special case: private method can be called with self
          return
        end

        # iyi: a definition-typing probe (`DefinitionTyping`) is the def's
        # own site asking, not a caller outside the wall. It reaches a
        # module's unmarked function and a type's `private def` the way the
        # module's own code does, which is what typing the body at its
        # definition means (SPEC.md R-2c).
        return if iyi_synthetic?

        if name == "initialize" && parent_visitor.call.try(&.name) == "new"
          # Special case: initialize call inside automatically defined new
          return
        end

        owner = match.def.owner
        if owner.is_a?(ModuleType) && owner.iyi_unit?
          raise "#{owner} does not export '#{match.def.name}'. Only what a module marks `pub` is reachable from outside it — see SPEC.md R-2"
        end

        raise "private method '#{match.def.name}' called for #{owner}"
      end
    when .protected?
      return if iyi_synthetic?
      scope_type = scope.instance_type
      owner_type = match.def.owner.instance_type

      unless scope_type.has_protected_access_to?(owner_type)
        raise "protected method '#{match.def.name}' called for #{match.def.owner}"
      end
    when .public?
      # okay
    end
  end

  def check_recursive_splat_call(a_def, args, &)
    if a_def.splat_index
      previous_splat_types = program.splat_expansions[a_def] ||= [] of Type
      previous_splat_types.push(args.values.last.type)

      # This is just an heuristic, but if a same method is called recursively
      # 5 times or more, and the splat type keeps expanding and containing
      # previous splat types, there's a high chance it will recurse forever.
      if previous_splat_types.size >= 5 &&
         previous_splat_types.each.cons_pair.all? { |t1, t2| t2.has_in_type_vars?(t1) }
        a_def.raise "recursive splat expansion: #{previous_splat_types.join(", ")}, ..."
      end

      yield

      previous_splat_types.pop
      program.splat_expansions.delete a_def if previous_splat_types.empty?
    else
      yield
    end
  end

  def full_name(owner, def_name = name)
    Call.full_name(owner, def_name)
  end

  def self.full_name(owner, method_name = name)
    case owner
    when Program, Nil
      method_name
    when owner.program.class_type
      # Class's instance_type is Object, not Class, so we cannot treat it like
      # other metaclasses
      "#{owner}##{method_name}"
    when .metaclass?
      "#{owner.instance_type}.#{method_name}"
    else
      "#{owner}##{method_name}"
    end
  end

  def signature(io : IO) : Nil
    io << full_name(obj.try(&.type)) << '('

    first = true
    args.each do |arg|
      case {arg_type = arg.type, arg}
      when {TupleInstanceType, Splat}
        next if arg_type.tuple_types.empty?
        io << ", " unless first
        arg_type.tuple_types.join(io, ", ")
      when {NamedTupleInstanceType, DoubleSplat}
        next if arg_type.entries.empty?
        io << ", " unless first
        arg_type.entries.join(io, ", ") do |entry|
          Symbol.quote_for_named_argument(io, entry.name)
          io << ": " << entry.type
        end
      else
        io << ", " unless first
        io << arg.type
      end
      first = false
    end

    if named_args = @named_args
      io << ", " unless first
      named_args.join(io, ", ") do |named_arg|
        Symbol.quote_for_named_argument(io, named_arg.name)
        io << ": " << named_arg.value.type
      end
    end

    io << ')'
  end

  private def colorize(obj)
    program.colorize(obj)
  end
end
