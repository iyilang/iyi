require "../spec_helper"
require "./spec_helper"

# iyi: `import`, which resolves against files on disk — SPEC.md R-1.
#
# `spec/compiler/semantic/iyi_spec.cr` covers everything that needs only a
# module to exist and declares it inline. What is left is what only real files
# can show: where an imported module is declared, and what happens when the
# module a build imports arrives as a `.iyimod` instead of as source.
private def with_iyi_modules(files : Hash(String, String), &)
  with_tempdir("iyi_import") do
    files.each do |path, source|
      directory = File.dirname(path)
      Dir.mkdir_p(directory) unless directory == "."
      File.write path, source
    end
    yield Dir.current
  end
end

private def semantic_iyi(entry : String, iyi_module_dir : String? = nil,
                         prelude_dir : String? = nil)
  program = Iyi::Program.new
  program.color = false
  program.filename = File.expand_path(entry)
  program.iyi_module_dir = iyi_module_dir
  # A real prelude is not loaded here, so a spec about what the prelude owns
  # says where its files are — the one fact `require`ing it would have left
  # behind (`SemanticVisitor#require_file`).
  program.iyi_prelude_dir = prelude_dir

  parser = program.new_parser(File.read(entry))
  parser.filename = program.filename
  node = program.normalize(parser.parse)
  program.semantic node

  program
end

# The same, for a program built `--crystal`: the prelude is the other
# language's, so a type a `.iyi` file reopens is one the library owns.
private def semantic_iyi_crystal(entry : String)
  program = Iyi::Program.new
  program.color = false
  program.iyi_prelude = false
  program.filename = File.expand_path(entry)

  parser = program.new_parser(File.read(entry))
  parser.filename = program.filename
  node = program.normalize(parser.parse)
  program.semantic node

  program
end

private def artifact_signature(name : String, parameters = [] of String, return_type = "")
  Iyi::IyiMod::Signature.new(name, "", parameters, "", return_type,
    [] of String, false)
end

private def exports(functions = [] of Iyi::IyiMod::Signature,
                    types = [] of Iyi::IyiMod::TypeDecl,
                    impls = [] of Iyi::IyiMod::ImplRecord)
  Iyi::IyiMod::Exports.new(functions, types, impls)
end

# Written by hand rather than by a compile, so that what a consumer is being
# fed is on the page: these specs are about what reading one does.
private def write_iyimod(dir : String, module_name : String,
                         exports = exports,
                         imports = [] of String,
                         compiler_version = Iyi::IyiMod.compiler_version)
  reference = Iyi::Program.new
  artifact = Iyi::IyiMod::Artifact.new(
    module_name: module_name,
    source_path: "#{module_name}.iyi",
    compiler_version: compiler_version,
    target_triple: reference.codegen_target.to_s,
    flags: reference.flags.to_a.sort!,
    imports: imports.map { |name| Iyi::IyiMod::ImportEdge.new(name) },
    exports: exports,
  )
  Iyi::IyiMod.write artifact, File.join(dir, "#{module_name}.iyimod")
end

describe "Semantic: iyi import" do
  # iyi: what the compiler says the first time somebody meets these rules.
  # Each of these used to answer with a fact about the compiler's internals —
  # an undefined constant nobody wrote, a name it could not find — rather than
  # with the rule that was broken and what to write instead.
  # iyi: R-1 says a module is loaded at most once. Two paths to the same module
  # is the ordinary shape of a graph, and a module initialised twice would run
  # its top level twice — which III.5's ordering is written to prevent.
  it "loads a module once however many paths reach it" do
    with_iyi_modules({
      "main.iyi"      => "module main\n\nimport app/left\nimport app/right\nusing app/left\n\npair\n",
      "app/left.iyi"  => "module app/left\n\nimport app/base\nusing app/base\n\npub def pair : Int32\n  value\nend\n",
      "app/right.iyi" => "module app/right\n\nimport app/base\n",
      "app/base.iyi"  => "module app/base\n\npub def value : Int32\n  41\nend\n",
    }) do
      program = semantic_iyi("main.iyi")

      # Keyed by filename, one entry per module, whichever path reached it.
      program.iyi_module_paths.values.sort.should eq ["app/base", "app/left", "app/right"]
      program.iyi_module_paths.values.count("app/base").should eq 1

      # Both importers still record the edge, because the second one adds no
      # initialiser and does constrain where the first one's may be moved to.
      importers = program.iyi_module_imports.select { |_, edges| edges.any?(&.ends_with?("app/base.iyi")) }
      importers.size.should eq 2
    end
  end

  describe "the message a rule gives the first time it is met" do
    it "tells a file that `using` a module it has not imported to import it" do
      with_iyi_modules({
        "main.iyi"    => "module app/main\n\nusing app/dep\n",
        "app/dep.iyi" => "module app/dep\n\npub def value : Int32\n  2\nend\n",
      }) do
        expect_raises(Iyi::TypeException, /needs `import app\/dep` above it/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    # `import calc/ad` beside `calc/add.iyi` is a typo, and the sentence
    # about the path rule read as if the rule were the problem.
    it "names the nearest module beside a mistyped import" do
      with_iyi_modules({
        "main.iyi"    => "module app/main\n\nimport app/dpe\n",
        "app/dep.iyi" => "module app/dep\n\npub def value : Int32\n  2\nend\n",
      }) do
        expect_raises(Iyi::TypeException, /can't find module 'app\/dpe'.*Did you mean `app\/dep`\?/m) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "says which module exports a name that is imported but not used" do
      with_iyi_modules({
        "main.iyi"    => "module app/main\n\nimport app/dep\n\nvalue\n",
        "app/dep.iyi" => "module app/dep\n\npub def value : Int32\n  2\nend\n",
      }) do
        expect_raises(Iyi::TypeException, /`value` is exported by `app\/dep`/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "says which module exports a type that is imported but not used" do
      with_iyi_modules({
        "main.iyi"    => "module app/main\n\nimport app/dep\n\nBox.new\n",
        "app/dep.iyi" => "module app/dep\n\npub struct Box\nend\n",
      }) do
        expect_raises(Iyi::TypeException, /`Box` is exported by `app\/dep`.*`using app\/dep::\{Box\}`.*`App::Dep::Box`/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "says when the type is there and was not marked `pub`" do
      with_iyi_modules({
        "main.iyi"    => "module app/main\n\nimport app/dep\nusing app/dep\n\nBox.new\n",
        "app/dep.iyi" => "module app/dep\n\nstruct Box\nend\n",
      }) do
        expect_raises(Iyi::TypeException, /declares `Box` and does not mark it `pub`/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "says when the name is there and was not marked `pub`" do
      with_iyi_modules({
        "main.iyi"    => "module app/main\n\nimport app/dep\nusing app/dep\n\nsecret\n",
        "app/dep.iyi" => "module app/dep\n\ndef secret : Int32\n  2\nend\n",
      }) do
        expect_raises(Iyi::TypeException, /does not mark it `pub`/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "refuses a library `require` and names `import` instead" do
      with_iyi_modules({
        "main.iyi" => "module app/main\n\nrequire \"json\"\n",
      }) do
        expect_raises(Iyi::TypeException, /iyi has no `require`/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "says where it looked for a module that is not there" do
      with_iyi_modules({
        "main.iyi" => "module app/main\n\nimport app/ghost\n",
      }) do
        expect_raises(Iyi::TypeException, /this one is `app\/ghost.iyi`/) do
          semantic_iyi("main.iyi")
        end
      end
    end
  end

  # An `import` written below other code used to declare the module inside the
  # importing one — `Samples::InitOrder::Boot::Registry` — which compiled,
  # because the importing file reaches it under the same name either way. The
  # first thing to look from outside was `--emit-iyimod`, which found no
  # `Boot::Registry` at the top level and wrote an artifact with no exports.
  it "declares an imported module at the top level wherever the import is written" do
    with_iyi_modules({
      "main.iyi" => <<-IYI,
        module app/main

        def own : Int32
          1
        end

        import app/dep
        IYI
      "app/dep.iyi" => <<-IYI,
        module app/dep

        pub def value : Int32
          2
        end
        IYI
    }) do
      program = semantic_iyi("main.iyi")

      program.iyi_module_type("app/dep").should_not be_nil

      importer = program.iyi_module_type("app/main").not_nil!
      importer.types?.try(&.has_key?("App")).should be_falsey
    end
  end

  describe "the import wall and a generic's own type variables (SPEC.md R-1)" do
    # The wall asks a *file* whether it imported a name it wrote. A generic's
    # methods are re-resolved against the instance, so `T` in `holder.iyi`
    # comes back as whatever the program chose — and the wall took that for a
    # name `holder.iyi` had written. Any generic instantiated with another
    # module's type was refused on the line declaring its own field.
    it "lets a generic be instantiated with a type its own file never named" do
      with_iyi_modules({
        "lib/holder.iyi" => <<-IYI,
          module lib/holder

          pub struct Holder(T)
            @value : T

            def initialize(@value : T)
            end

            pub def each(& : T -> Nil) : Nil
              yield @value
            end
          end
          IYI
        "lib/badge.iyi" => <<-IYI,
          module lib/badge

          pub struct Badge
            @name : String

            def initialize(@name : String)
            end

            pub def name : String
              @name
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import lib/holder
          import lib/badge
          using lib/holder::{Holder}
          using lib/badge::{Badge}

          kept = ""
          Holder(Badge).new(Badge.new("kept")).each do |badge|
            kept = badge.name
          end
          IYI
      }) do
        semantic_iyi("main.iyi")
      end
    end

    # And the wall still stands where a file really does write the name.
    it "still refuses a name the file did not import" do
      with_iyi_modules({
        "lib/badge.iyi" => <<-IYI,
          module lib/badge

          pub struct Badge
          end
          IYI
        "lib/peek.iyi" => <<-IYI,
          module lib/peek

          import lib/badge

          pub def peek : Lib::Badge::Badge?
            nil
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import lib/peek

          Lib::Badge::Badge
          IYI
      }) do
        expect_raises(Iyi::TypeException, /is not imported here/) do
          semantic_iyi("main.iyi")
        end
      end
    end
  end

  describe "from a .iyimod (SPEC.md IV.1)" do
    # R-1's contract, stated as a test: the source is not opened. Not opened
    # rather than not preferred — there is no `app/dep.iyi` on disk at all.
    it "compiles a module that has no source" do
      with_iyi_modules({
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          def check : Int32
            App::Dep.value
          end

          check
          IYI
      }) do |root|
        write_iyimod root, "app/dep", exports(functions: [
          artifact_signature("value", return_type: "Int32"),
        ])

        program = semantic_iyi("main.iyi", iyi_module_dir: root)
        program.iyi_module_type("app/dep").should_not be_nil
      end
    end

    # The one that tells "read the artifact" apart from "read the source and
    # happened to agree": the two disagree, and what compiles is the artifact's.
    it "reads the artifact rather than the source that is sitting next to it" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          pub def from_source : Int32
            1
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          def check : Int32
            App::Dep.from_artifact
          end

          check
          IYI
      }) do |root|
        write_iyimod root, "app/dep", exports(functions: [
          artifact_signature("from_artifact", return_type: "Int32"),
        ])

        semantic_iyi("main.iyi", iyi_module_dir: root)
      end
    end

    it "does not reach a name that only the source has" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          pub def from_source : Int32
            1
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          def check : Int32
            App::Dep.from_source
          end

          check
          IYI
      }) do |root|
        write_iyimod root, "app/dep", exports(functions: [
          artifact_signature("from_artifact", return_type: "Int32"),
        ])

        expect_raises(Iyi::TypeException, /undefined method 'from_source'/) do
          semantic_iyi("main.iyi", iyi_module_dir: root)
        end
      end
    end

    # A call is typed from the return annotation, which is the whole of what
    # the front end gets from an artifact — there is no body to type.
    it "types a call from the signature alone" do
      with_iyi_modules({
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          def check : Int32
            App::Dep.value
          end

          check
          IYI
      }) do |root|
        write_iyimod root, "app/dep", exports(functions: [
          artifact_signature("value", return_type: "String"),
        ])

        # `check` promises `Int32` and the artifact says `value` gives a
        # `String`. Nothing but the signature could have caught that.
        expect_raises(Iyi::TypeException, /must return Int32/) do
          semantic_iyi("main.iyi", iyi_module_dir: root)
        end
      end
    end

    # IV.5: rejected and rebuilt, never migrated — and never quietly swapped
    # for the source, which would make a build that asked to be compiled
    # against artifacts slower than it looks and prove nothing.
    it "refuses an artifact from another compiler" do
      with_iyi_modules({
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep
          IYI
      }) do |root|
        write_iyimod root, "app/dep", exports, compiler_version: "0.0.0+nope"

        expect_raises(Iyi::TypeException, /written by iyi 0\.0\.0\+nope/) do
          semantic_iyi("main.iyi", iyi_module_dir: root)
        end
      end
    end

    # IV.5, the other half: what two compilers have to agree on is the release
    # they are, not the commit they were built from. Written with the version
    # on the page rather than with `IyiMod.compiler_version`, because a spec
    # that asks the compiler what it is would pass however that is answered —
    # including by going back to naming a build nobody else has.
    it "reads an artifact from another build of the same release" do
      # The rule from both sides of a release, so this spec says the same thing
      # the day the version becomes a `-dev` one again: a named release is the
      # whole identity, and a version between two releases names no compiler,
      # so it keeps the build commit.
      version = Iyi::Config.iyi_version
      if version.ends_with?("-dev") && (commit = Iyi::Config.build_commit)
        Iyi::IyiMod.compiler_version.should eq "#{version}+#{commit}"
      else
        # A released version, or a build that was told no commit — this spec
        # binary is one, being compiled without the variable the Makefile sets.
        Iyi::IyiMod.compiler_version.should eq version
      end

      with_iyi_modules({
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep
          IYI
      }) do |root|
        write_iyimod root, "app/dep", exports,
          compiler_version: Iyi::IyiMod.compiler_version

        semantic_iyi("main.iyi", iyi_module_dir: root)
      end
    end

    # `pub macro` (R-2b): every macro a module writes already travels, because
    # a body that travels may call one. What `pub` adds is a name the consumer
    # may say, and these are the four answers that make up the rule.
    it "runs a macro another module exported" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          pub macro declare(name)
            def {{name.id}} : Int32
              1
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep
          using app/dep

          declare(made)
          IYI
      }) do
        semantic_iyi("main.iyi")
      end
    end

    it "runs an exported macro through the module's name" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          pub macro declare(name)
            def {{name.id}} : Int32
              1
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          App::Dep.declare(made)
          IYI
      }) do
        semantic_iyi("main.iyi")
      end
    end

    it "refuses an unexported macro by name, as it refuses an unexported def" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          macro declare(name)
            def {{name.id}} : Int32
              1
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          App::Dep.declare(made)
          IYI
      }) do
        expect_raises(Iyi::TypeException, /does not export 'declare'/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "leaves an unexported macro out of what `using` brings in" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          macro declare(name)
            def {{name.id}} : Int32
              1
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep
          using app/dep

          declare("made")
          IYI
      }) do
        # The argument is a literal so that what fails is the name of the
        # macro. `declare(made)` would be read as a call taking a variable
        # nobody declared, and fail one word earlier for a different reason.
        expect_raises(Iyi::TypeException, /undefined method 'declare'/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    # `pub` on a constant (R-2). A module's own top level travels as source, so
    # the mark travels by being written back out — there is nothing in the
    # format for it, which is why these are the whole of the rule.
    it "reads a constant another module exported" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          pub LIMIT = 42
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          App::Dep::LIMIT
          IYI
      }) do
        semantic_iyi("main.iyi")
      end
    end

    it "refuses an unmarked constant, as it refuses an unmarked def" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          SECRET = 42
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          App::Dep::SECRET
          IYI
      }) do
        expect_raises(Iyi::TypeException, /does not export App::Dep::SECRET/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    # `require` is refused in a `.iyi` file because there is nothing to
    # require: the prelude is what a program gets. That reason stops being true
    # when the prelude is Crystal's, and a program built `--crystal` has one.
    # The rules are unaffected either way: they are the language's, and a
    # prelude is a library.
    it "refuses `require` while iyi's own prelude is what a program has" do
      with_iyi_modules({
        "main.iyi" => <<-IYI,
          module app/main

          require "json"
          IYI
      }) do
        expect_raises(Iyi::TypeException, /iyi has no `require`/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    # A reopen of the other language's type can add and cannot replace
    # (SPEC.md R-3). `src/std/text.iyi` is what found it: a `private def
    # byte_slice` of its own took Crystal's public one's place, and the first
    # program that touched `Path` stopped on `private method 'byte_slice'
    # called for String`, pointing at a line in the library that had not
    # changed.
    it "refuses a `.iyi` file that replaces a method of the other language" do
      with_iyi_modules({
        "lib.cr" => <<-CR,
          class ::String
            def shout : String
              self
            end
          end
          CR
        "main.iyi" => <<-IYI,
          module app/main

          require "./lib.cr"

          class ::String
            def shout : String
              self
            end
          end
          IYI
      }) do
        expect_raises(Iyi::TypeException, /String#shout is the library's method, and this replaces it/) do
          semantic_iyi_crystal("main.iyi")
        end
      end
    end

    # And the other half of the same sentence, which is what a reopen is for.
    it "lets a `.iyi` file add a method to a type of the other language" do
      with_iyi_modules({
        "lib.cr" => <<-CR,
          class ::String
            def shout : String
              self
            end
          end
          CR
        "main.iyi" => <<-IYI,
          module app/main

          require "./lib.cr"

          class ::String
            def whisper : String
              self
            end
          end
          IYI
      }) do
        semantic_iyi_crystal("main.iyi")
      end
    end

    # The prelude's own methods are the other half of R-3, and the half a
    # library written against this fork reached first: a module reopening
    # `::Enum` with a `to_s` of its own printed `All` for a two-member flags
    # set, and `parse?("WARN")` answered nil, with one import line as the
    # whole diagnosis. The prelude here is a directory with one file in it,
    # because what the rule reads is where a definition was written.
    it "refuses a module that replaces a method of the prelude" do
      with_iyi_modules({
        "prelude/shout.iyi" => <<-IYI,
          class ::Shouter
            def shout : Int32
              1
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          require "./prelude/shout.iyi"

          class ::Shouter
            def shout : Int32
              2
            end
          end
          IYI
      }) do |dir|
        expect_raises(Iyi::TypeException, /Shouter#shout is the prelude's method, and this replaces it/) do
          semantic_iyi("main.iyi", prelude_dir: File.join(dir, "prelude"))
        end
      end
    end

    # And adding to a prelude type is still how a module extends one.
    it "lets a module add a method to a type of the prelude" do
      with_iyi_modules({
        "prelude/shout.iyi" => <<-IYI,
          class ::Shouter
            def shout : Int32
              1
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          require "./prelude/shout.iyi"

          class ::Shouter
            def whisper : Int32
              shout
            end
          end
          IYI
      }) do |dir|
        semantic_iyi("main.iyi", prelude_dir: File.join(dir, "prelude"))
      end
    end

    # The prelude extends itself: one library deciding its own surface, which
    # is how `number.iyi` writes a method `primitives.iyi` declared.
    it "lets the prelude replace its own method" do
      with_iyi_modules({
        "prelude/shout.iyi" => <<-IYI,
          class ::Shouter
            def shout : Int32
              1
            end
          end
          IYI
        "prelude/louder.iyi" => <<-IYI,
          class ::Shouter
            def shout : Int32
              2
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          require "./prelude/shout.iyi"
          require "./prelude/louder.iyi"
          IYI
      }) do |dir|
        semantic_iyi("main.iyi", prelude_dir: File.join(dir, "prelude"))
      end
    end

    # A macro is the same act and a wider one: `getter` is a declaration
    # macro, so a module that reopens `::Object` and writes its own decides
    # what every field declaration in the program means, including the ones
    # in files that never heard of it. It travels in an artifact too, so a
    # consumer can inherit it from a module whose source it never reads.
    it "refuses a module that replaces a macro of the prelude" do
      with_iyi_modules({
        "prelude/macros.iyi" => <<-IYI,
          class ::Object
            macro reader(name)
              def {{name.id}} : Int32
                1
              end
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          require "./prelude/macros.iyi"

          class ::Object
            macro reader(name)
              def {{name.id}} : Int32
                2
              end
            end
          end
          IYI
      }) do |dir|
        expect_raises(Iyi::TypeException, /Object\.reader is the prelude's macro, and this replaces it/) do
          semantic_iyi("main.iyi", prelude_dir: File.join(dir, "prelude"))
        end
      end
    end

    # A macro under a name the prelude does not have is an addition, and a
    # macro on a type the module declared is its own however it is spelled.
    it "lets a module add a macro to a type of the prelude" do
      with_iyi_modules({
        "prelude/macros.iyi" => <<-IYI,
          class ::Object
            macro reader(name)
              def {{name.id}} : Int32
                1
              end
            end
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          require "./prelude/macros.iyi"

          class ::Object
            macro writer(name)
              def {{name.id}}= (value : Int32) : Nil
              end
            end
          end

          class Holder
            macro reader(name)
              def {{name.id}} : Int32
                3
              end
            end
          end
          IYI
      }) do |dir|
        semantic_iyi("main.iyi", prelude_dir: File.join(dir, "prelude"))
      end
    end

    # A module header makes a type, and inside it that name means the module.
    # Found by writing a command-line program called `tally` that imported a
    # `Tally`: what it said was that `Tally` was not `App::Count::Tally`, at
    # the first line that used one, with nothing pointing at the `using`.
    # A module path is a file's path, so it cannot mean something different
    # depending on where it is written. Found by `samples/iyi/calc`: a module
    # called `samples/calc` importing `calc/lexer` resolved `Calc` to itself
    # and then said the module was not imported, which is a true-looking
    # sentence about the wrong thing.
    it "reads a module path from the root, not from where it is written" do
      with_iyi_modules({
        "calc/lexer.iyi" => <<-IYI,
          module calc/lexer

          pub def scan : Int32
            1
          end
          IYI
        "main.iyi" => <<-IYI,
          module samples/calc

          import calc/lexer
          using calc/lexer

          scan
          IYI
      }) do
        semantic_iyi("main.iyi")
      end
    end

    it "refuses a `using` of a name the module's own name already takes" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          pub struct Thing
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/thing

          import app/dep
          using app/dep::{Thing}
          IYI
      }) do
        expect_raises(Iyi::TypeException, /is this module's own name/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    # II.3's conflict rule, with the used module in a file rather than faked as
    # a nested type. It used to be faked, and a lexical lookup found the fake;
    # a module path is a file's path, so the lookup is global now and a fake
    # nested `App::Greeter` is not what `using app/greeter` means.
    it "lets a local definition beat a name `using` brought in" do
      with_iyi_modules({
        "app/greeter.iyi" => <<-IYI,
          module app/greeter

          pub def polite : Int32
            1
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/consumer

          import app/greeter
          using app/greeter

          def polite : Bool
            true
          end

          struct User
            def greet : Bool
              polite
            end
          end

          User.new.greet
          IYI
      }) do
        semantic_iyi("main.iyi")
      end
    end

    it "falls back to the used one when there is no local definition" do
      with_iyi_modules({
        "app/greeter.iyi" => <<-IYI,
          module app/greeter

          pub def polite : Int32
            1
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/consumer

          import app/greeter
          using app/greeter

          struct User
            def greet : Bool
              polite
            end
          end

          User.new.greet
          IYI
      }) do
        expect_raises(Iyi::TypeException, /must return Bool/) do
          semantic_iyi("main.iyi")
        end
      end
    end

    it "falls back to the source when there is no artifact" do
      with_iyi_modules({
        "app/dep.iyi" => <<-IYI,
          module app/dep

          pub def from_source : Int32
            1
          end
          IYI
        "main.iyi" => <<-IYI,
          module app/main

          import app/dep

          def check : Int32
            App::Dep.from_source
          end

          check
          IYI
      }) do |root|
        semantic_iyi("main.iyi", iyi_module_dir: root)
      end
    end
  end
end
