#!/usr/bin/env bash
# Binds a Crystal shard, builds a program against the boundary, and checks it
# prints what the same program prints built against the shard's source.
#
# `bench/samples_roundtrip.sh` asks R-1's question of iyi's own modules. This
# asks it of the other kind of artifact — one whose object code is a shard's,
# whose declarations `crystal tool bind` wrote, and whose consumer is a
# `--crystal` program. SPEC.md III.6 rule 1 names two failures for a boundary
# whose signatures are wrong: an undefined symbol, or a call that returns
# something of another type. `spec/compiler/bind_spec.cr` stops before both of
# them on purpose — it reads the declarations back and never links — so until
# this ran, nothing did.
#
#     bash bench/bind_roundtrip.sh
#
# Needs `make` (both the compiler and `iyi`). Exits non-zero if binding fails,
# if either arm fails to build or link, or if the two print differently.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the wrappers in bin are posix shell scripts, so a caller that already has
# compilers of its own names them through the environment.
CRYSTAL="${CRYSTAL:-$REPO/bin/crystal}"
IYI="${IYI:-$REPO/bin/iyi}"

# A reader that is not installed reads nothing: with no `strings` the
# evidence line below comes out empty and the gate reads straight past it,
# which is a measurement that never happened rather than one that held.
STRINGS=""
command -v strings >/dev/null 2>&1 && STRINGS=strings
WORK="$(mktemp -d)"

# A native compiler cannot resolve this shell's own path mapping: a search
# path built from the shell's `pwd` finds no prelude at all, and the sources
# written into a scratch directory named `/tmp/tmp.X` are named by a path it
# cannot read.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT)
    REPO="$(cygpath -m "$REPO")"
    WORK="$(cygpath -m "$WORK")"
    ;;
esac

# Four methods, and each is a shape this boundary got wrong once.
#
# `step` writes both its types and is what a shard is supposed to look like.
#
# `wider` is the one that made this file necessary. Crystal narrows a return
# restriction to what the body produced, so this method's symbol is named
# `:String` while the restriction says `String?`. A boundary repeating the
# restriction has the consumer ask for a symbol nobody emitted, and the failure
# is `ld.lld: error: undefined symbol` at the end of a build that had no other
# complaint. What travels is the answer, and this is the case that says so.
#
# `discards` is the opposite mistake, from the first version of the check that
# found `wider`: `: Nil` throws away whatever the body produced, so a check
# reading the *body* calls this broken when it is not. It has to keep crossing.
#
# Its `IO` is the second thing this round trip found. A parameter whose type is
# abstract is emitted once, against the declaration, and a consumer passing a
# `STDOUT` used to ask for `discards<IO::FileDescriptor>` — a symbol nobody
# wrote. The declaration is the contract now and the call is keyed on it, so
# this line is the regression test for that as much as for `: Nil`.
#
# `untyped_return` writes no return type at all, which is the half of rule 1
# that was always instantiated. It is here so the two halves are checked by one
# program.
#
# `bump` reads a class variable, which is a *global*. Its global is defined in
# the main module of whatever build compiled it, and a main module is the one
# part of a build that never travels — so the method arrived as machine code
# referring to `Shard::Part::count`, a symbol nothing defined. Nothing carried
# class variables at all: not this boundary and not a `.iyimod` written from
# iyi's own source, where the same hole made R-1's claim false for any module
# that had one.
#
# `each` takes a block, and a block-taking method's machine code is the
# caller's by design (IV.1g) — the producer emits each instantiation private to
# the unit that called it, so no symbol for one leaves the artifact. Its body
# has to travel instead. It did not, for anything but a generic type, and this
# line is what said so: `undefined symbol:
# *Shard::Part#each<&Proc(Int32, Nil)>`.
cat > "$WORK/shard.cr" <<'CR'
module Shard
  extend self

  # On the module rather than on a type inside it, which is a different place
  # for the format to have to put it: a module is not a `TypeDecl`. Kemal's
  # `backtracer` is where this was found — `module Backtracer;
  # class_getter(configuration)` left `Backtracer::configuration` undefined at
  # the end of a build that had every one of that shard's types and their class
  # variables.
  @@made = 0

  class Part
    @seed : Int32
    @@count = 0

    def initialize(@seed : Int32)
    end

    def step(n : Int32) : Int32
      (n + @seed) % 1000
    end

    def wider : String?
      "part-" + @seed.to_s
    end

    def discards(io : IO) : Nil
      io << "seed=" << @seed
    end

    def untyped_return(n : Int32)
      n * @seed
    end

    def each(& : Int32 -> Nil) : Nil
      yield @seed
      yield @seed + 1
    end

    def bump : Int32
      @@count = @@count + 1
      @@count
    end

    # A union the consumer never forms, checked against a union restriction.
    # `is_a?` against a union compiles to `~match<(Char | Int32)>`, a function
    # that compares a type id against the *program's* numbering — so it is the
    # main module's and the main module does not travel. A virtual type the
    # consumer could have found for itself by taking the virtual form of every
    # class it numbers; a union it cannot, because no walk over a program
    # arrives at one its own code never wrote.
    def kind(n : Int32) : String
      v = n > 1 ? 1 : (n > 0 ? 'x' : "s")
      v.is_a?(Char | Int32) ? "small" : "other"
    end
  end

  # Inheritance, which a boundary lost entirely: `TypeDecl` had no field for
  # the `<`, so `Derived` arrived without its base *and* without the fields it
  # inherits — a subclass's own field list is only its own. The consumer said
  # `undefined method 'tag' for Shard::Derived`.
  #
  # Three separate things had to follow the edge. A method is keyed on the type
  # that *defines* it, because a boundary has one symbol per method and not one
  # per receiver. That symbol is keyed on the class's *virtual* form, because a
  # value of a class something inherits from is held as one. And a class with
  # subclasses has a second unit — `Shard::Base+` — which is where the methods
  # reached through that form are emitted, and which the artifact was not
  # carrying at all.
  class Base
    @tag : String

    def initialize(@tag : String)
    end

    def tag : String
      @tag
    end

    def describe : String
      "base:" + @tag
    end
  end

  # A second subclass, so that a method answering either of them answers the
  # base's *virtual* type rather than one concrete class. See `pick`.
  class Other < Base
    def initialize(tag : String)
      super(tag)
    end

    def describe : String
      "other:" + @tag
    end
  end

  class Derived < Base
    @extra : Int32

    def initialize(tag : String, @extra : Int32)
      super(tag)
    end

    def extra : Int32
      @extra
    end

    # Overridden, so the two halves of dispatch are both checked: the inherited
    # `tag` comes from the base's unit and this one does not.
    def describe : String
      "derived:" + @tag + ":" + @extra.to_s
    end

    # A body that names this shard's own constants the way the shard wrote them
    # — absolutely — and it has to be on a *type*, which is the path that was
    # broken. The declarations are read inside a module whose root has been
    # stripped, so `Shard::TAG` there is the module's *public* name and R-2
    # answers for it: `Shard does not export Shard::TAG`. A module function's
    # body already took this rewrite; a type's did not, and the first version
    # of this check put the method on the module and passed either way.
    #
    # It takes a block for a second reason: that is what makes the body travel
    # at all. A method whose machine code is in the artifact never has its text
    # read by anybody.
    def tagged(&)
      yield Shard::TAG + ":" + Shard::Inner::DEPTH.to_s
    end
  end

  def self.derived(tag : String, extra : Int32) : Derived
    Derived.new(tag, extra)
  end

  # An abstract class, whose concrete methods are the third thing whose body
  # has to travel — beside a generic's and a block-taker's, and for the same
  # reason each time: they are instantiated per *subclass*, and the subclass is
  # the consumer's. A shard that declares one and never subclasses it carries
  # **no machine code for it at all**, which is why `exception_page` fills with
  # 0 units and why that is not a bug.
  abstract class Sheet
    abstract def title : String

    def render : String
      "[" + title + "]"
    end
  end

  # A non-generic type nested inside a generic one. The keep file skipped a
  # generic — rightly, since `uninitialized Holder(T)` is not a thing anybody
  # can write — and skipped everything it declared along with it. Those have
  # units in the artifact all the same, so radix's keep file was empty while
  # its two error classes carried 1.3 MB each, and the only `to_s` symbols it
  # emitted were the ones its own code happened to reach: a consumer asking
  # for the declared `to_s<IO+>` found nothing.
  class Holder(T)
    @value : T
    @tag : String

    # A default, and it travels. A generic's `new` is synthesised per
    # instantiation and never carried, so its `initialize` is what a consumer
    # builds one with — and a call that leaves an argument out meets a
    # declaration that has to know it could.
    def initialize(@value : T, @tag : String = "plain")
    end

    def tag : String
      @tag
    end

    def value : T
      @value
    end

    # A public method and a *private overload of the same name*. Every
    # generic's methods travel as source, and the private one was held to a
    # test the public one passes — its unwritten parameter reads as `?`,
    # which is not a name to resolve — so `radix`'s `find(path, result,
    # node, first = false)` stayed behind and the public `find` that calls
    # it reached a consumer as `no parameter named 'first'`.
    def find(word : String) : String
      find(word, 1, deep: true)
    end

    private def find(word : String, depth : Int32, deep = false)
      deep ? "deep-#{word}-#{depth}" : word
    end

    class Note
      @text : String

      def initialize(@text : String)
      end

      # An abstract parameter, so the symbol is the declared one and not one
      # per argument type — which is what made the gap visible.
      def write(io : IO) : Nil
        io << "note:" << @text
      end
    end
  end

  def self.note(text : String) : Holder::Note
    Holder::Note.new(text)
  end

  # A nested namespace, which a boundary used to drop whole and report as a
  # "nested namespace skipped". What that cost only shows at a shard's scale:
  # `Kemal::Exceptions` holds four exception classes, each with an object-code
  # unit in the artifact, so a consumer linked their machine code and had none
  # of the classes. A module is also a type — the object code numbers one — and
  # a consumer that cannot name it cannot number it.
  module Inner
    DEPTH = 2

    class Deep
      @tag : String

      def initialize(@tag : String)
      end

      def tag : String
        @tag
      end
    end

    def self.deep(tag : String) : Deep
      Deep.new(tag)
    end
  end

  def make(seed : Int32) : Part
    @@made = @@made + 1
    Part.new(seed)
  end

  def made : Int32
    @@made
  end

  TAG = "shard"

  # A method whose answer is *two* subclasses, and the shape that made this
  # section necessary.
  #
  # Nobody wrote a return type, so the boundary infers one, and what the body
  # answers is `Base+` — the merge of two subclasses. A declaration cannot name
  # a virtual type (`Base+` is how one prints, not a name anybody writes), so
  # it crosses as `: Base`. An ordinary `def` types its call `Base+` because
  # the *body* widens it; a header has no body, so the call came out typed
  # `Base` exactly and `is_a?(Derived)` answered **false**.
  #
  # A method that *writes* `: Base` does not find this: Crystal resolves a
  # written restriction on an abstract class to `Base+` on its own. It takes an
  # inferred one, and the first version of this check wrote the restriction and
  # passed either way.
  def pick(flag : Bool)
    if flag
      Derived.new("picked", 1)
    else
      Other.new("picked")
    end
  end

  # And held in a collection, because the wrong reading also decides what a
  # generic is instantiated with.
  def collect(flag : Bool)
    [pick(flag)]
  end

  # Seven shapes a real shard has and this fixture did not. Every one of them
  # was found by *consuming* an artifact rather than by writing one: the
  # declarations read back fine and the program that imported them stopped.

  # A thread-local class variable. `@[ThreadLocal]` is not decoration - the
  # variable is reached through a function handing back a per-thread address -
  # so a consumer that declared it without the annotation writes to a
  # different global than this module's object code does. `gcry` has eleven,
  # and the link said `relocation R_X86_64_TPOFF32 cannot be used against
  # symbol` with every declaration in hand.
  @[ThreadLocal]
  @@ticks = 0

  def tick : Int32
    @@ticks = @@ticks + 1
    @@ticks
  end

  # One the shard declared `uninitialized`, which is the only other way to
  # write a class variable whose type cannot hold nil. Carried without it, a
  # consumer stops on `class variable @@buffer of Shard is not nilable ... so
  # it must have an initializer`.
  @@buffer = uninitialized StaticArray(UInt8, 4)

  def buffered : Int32
    @@buffer[0] = 7_u8
    @@buffer[0].to_i32
  end

  # And one whose default *calls* a method the shard keeps to itself. The
  # default is source the consumer runs, so what it names is what the consumer
  # has to have: `email` writes `@@log : Log = create_logger` and a program
  # that imported that boundary stopped on `undefined local variable or
  # method 'create_logger'` before a line of its own.
  @@label : String = build_label

  def label : String
    @@label
  end

  private def self.build_label : String
    "shard-label"
  end

  # A body with a character outside ASCII in it, and a call to a private
  # method after it. The search for what a travelling body calls was byte
  # arithmetic on a *character* index, so every call past the first multi-byte
  # character read as uncalled: `gcry`'s `append_hex` never travelled and a
  # consumer compiling the body that calls it said `undefined method`.
  # A module of class methods, which is `gcry`'s `StwWatchdog` in miniature:
  # a module's methods are compiled per *including* type, so their bodies
  # travel and the consumer compiles them - and then every name they call has
  # to have travelled too. The method below is called from nowhere else,
  # which is what makes this a test: one that another body also names would
  # travel anyway and the check would pass either way.
  module Notes
    def self.dashed : String
      "one — two " + dash_note
    end

    private def self.dash_note : String
      "dashed"
    end
  end

  # The shard's own `fun`, called from its own code: the machine code for one
  # is in a *main* module, which never travels, and the declaration belongs at
  # the consumer's global scope rather than inside a module - `can only declare
  # fun at lib or global scope` is what carrying it the other way said.
  def worker : Int32
    shard_worker_main(Pointer(Void).null)
    1
  end

  # Public, because a `fun` is outside every namespace and a private method
  # is not callable from there - and its body calls one that is, which is the
  # chain `gcry` has: `fun gcry_stw_watchdog_main` calls `StwWatchdog.
  # watch_loop`, whose body calls `append_hex`.
  def self.worker_note : Nil
    @@ticks = @@ticks + Notes.dashed.size
  end

  # A type from the namespace beside this one, named in this one's surface.
  def slot(index : Int32) : Sidecar::Slot
    Sidecar::Slot.new(index)
  end

  # Two macros, one taking the other *as an argument*. A macro call at the top
  # level is a declaration written compactly rather than code that runs, and
  # copying one into the initialiser handed a consumer `Shard.embed` with
  # nothing in it: `kilt` writes `Kilt.register_engine("ecr", ECR.embed)` and
  # that is what `wrong number of arguments for macro 'embed' (given 0,
  # expected 2)` was.
  macro embed(text, into)
    {{into}} << {{text}}
  end

  macro register(kind, embed_macro)
    module Shard
      def self.render_{{kind.id}}(io : IO) : Nil
        {{embed_macro.name.id}}("<{{kind.id}}>", io)
      end
    end
  end

end

# A second top-level namespace, which is a boundary of its own. `pg` declares
# `PG` and `PQ` - its wire protocol - in one tree, and `PG`'s signatures name
# `PQ::Field` while its units number it: under one artifact the declarations
# land inside the wrong namespace and the object code is missing. `iyi bind`
# binds each namespace it is told about, and `tool bind` is what says which
# they are.
module Sidecar
  struct Slot
    @index : Int32

    def initialize(@index : Int32)
    end

    def index : Int32
      @index
    end

    # And back the other way, which is the shape no ordering of two artifacts
    # fixes: this body numbers a type of the namespace that names `Slot` in
    # its own signatures. `pg` is the pair in the wild - `PG` names
    # `PQ::Field`, `PQ` numbers `PG::Error` - so whichever boundary a
    # consumer reads first refers to a type the other has not declared yet.
    # A type id is a question about the *program*, and it is asked once, after
    # every import is in.
    def rebuilt : Int32
      Shard::Part.new(@index).step(0)
    end
  end
end

# The shapes a *consumer* is the only thing that exercises, each one a
# defect an application found in the same week (SPEC.md III.6).
module Shard
  # A macro on the module itself. Crystal has no `pub`, so an artifact that
  # carries one and does not mark it is a macro R-2 refuses: `Kilt does not
  # export 'render'`, from inside an expansion the consumer never wrote.
  LIMIT = 7

  macro limited(n)
    ({{ n }} > Shard::LIMIT ? Shard::LIMIT : {{ n }})
  end

  # What a module hands a type that includes it, which is a macro the
  # compiler keeps in a second place and an annotation only a macro reads.
  # `DB::Serializable` is this shape: without the hook a query mapping rows
  # into structs types `Array(NoReturn)`, and without the annotation the
  # expansion stops on `undefined constant DB::Field`.
  annotation Field
  end

  module Stamped
    def stamp : String
      "stamped"
    end
  end

  module Marked
    # A module's own `include`, which a class carried and a module did not:
    # `Kemal::HandlerInterface` includes `HTTP::Handler`, and a middleware
    # that included it was not a handler.
    include Stamped

    macro included
      def self.marked : String
        "marked"
      end
    end
  end

  # A parameter that takes a *class*: one instantiation per class the caller
  # names, so there is nothing here to measure and the body travels.
  module Mappable
    abstract def label : String
  end

  def self.build(type : Mappable.class) : String
    type.new.label
  end

  # A named argument at a boundary call. Keyed on what the call site passes,
  # a consumer asks for one symbol per exception class it happens to hold.
  class Lost < Exception
    def initialize(resource : String, cause : Exception | Nil = nil)
      super("lost #{resource}")
    end
  end

  # A module *body* that runs: the registry is filled by statements under the
  # hash they fill, and an artifact that carried the hash and not the
  # statements answered every lookup with the default.
  module Registry
    @@table = Hash(Int32, String).new("none")

    def self.at(id : Int32) : String
      @@table[id]
    end

    def self.put(id : Int32, name : String) : Nil
      @@table[id] = name
    end

    put 1, "one"
    put 2, "two"
  end

  # An enum a `fun` answers with, cased on inside a body that travels.
  #
  # The `fun`'s enum crossed as the enum's *base type* — what a C function
  # takes and answers is the integer — so the consumer compiled a `case` over
  # an `Int32`, matched no member and took the `else`. Silently: `sqlite3`
  # writes `case LibSQLite3.column_type(self, col) when Type::TEXT`, and the
  # first query a consumer ran came back `another row available`. The body
  # below is a *module*'s, so it travels (IV.1g) and the consumer is what
  # compiles the `case`.
  enum Sign : Int32
    Zero = 0
    One  = 1
    Two  = 2
  end

  module Signed
    def sign_of(value : Int32) : String
      case LibShardSign.magnitude(value)
      when Sign::One then "one"
      when Sign::Two then "two"
      else                "many"
      end
    end
  end

  class Signs
    include Signed
  end
end

# A name the shard writes outside its own namespace, which is a name every
# program that requires it has. `validator` ends its file with `alias Valid =
# Validator` and an application calls `Valid.email?`.
alias Handy = Shard

# The `fun` this shard's own code calls, whose body calls back into it.
fun shard_worker_main(arg : Void*) : Void*
  Shard.worker_note
  Pointer(Void).null
end

# And the `fun` whose answer is one of the shard's own enums. `abs` is libc's:
# what it answers for -1 and 2 is 1 and 2, which are the two members named
# above. Written at the top level, where a shard writes a `lib`.
lib LibShardSign
  fun magnitude = abs(value : Int32) : ::Shard::Sign
end

# And the macro call, which declares `Shard.render_text`.
Shard.register("text", Shard.embed)
CR

printf 'require "./shard"\n' > "$WORK/entry.cr"

# The consumer calls all of it, because codegen is demand-driven: a symbol
# nobody reaches is a symbol the linker is never asked for, and a round trip
# that reaches nothing proves nothing.
cat > "$WORK/app_source.iyi" <<'IYI'
module main

require "./shard"

part = Shard::Part.new(7)
puts part.step(5)
puts part.wider
part.discards(STDOUT)
puts ""
puts part.untyped_return(3)
total = 0
part.each do |v|
  total = total + v
end
puts total
puts part.bump
puts part.bump
puts Shard.make(11).step(1)
puts Shard.made
puts Shard::Inner.deep("nested").tag
d = Shard.derived("hello", 42)
puts d.tag

# The abstract-return shapes. `is_a?` and `class` are the two questions a wrong
# reading answers wrongly while everything else about the program looks right.
made = Shard.pick(true)
puts made.class
puts made.is_a?(Shard::Derived)
puts made.describe
held = Shard.collect(false)
puts held[0].class
puts held[0].is_a?(Shard::Other)
puts held[0].describe

# And the body that names the shard's own constants absolutely.
d.tagged { |text| puts text }
puts d.extra
puts d.describe
class Report < Shard::Sheet
  def initialize
  end

  def title : String
    "report"
  end
end

held = Shard::Holder(Int32).new(9)
puts held.value
puts held.tag
puts Shard::Holder(String).new("s", "named").tag
puts Report.new.render
Shard.note("kept").write(STDOUT)
puts ""
puts part.kind(2)
puts part.kind(1)
puts part.kind(0)

# The enum a `fun` answers with, read inside a body the consumer compiles.
# `many` where these say `one` and `two` is the base type having crossed
# instead of the enum.
signs = Shard::Signs.new
puts signs.sign_of(-1)
puts signs.sign_of(2)
puts signs.sign_of(7)

# The shapes a consumer is the only thing that can check: a class variable
# that is thread-local, one the shard left uninitialized, one whose default
# calls a private method, a body with a character outside ASCII in it, the
# shard's own `fun`, a macro-written def, and the namespace beside this one.
puts Shard.tick
puts Shard.buffered
puts Shard.label
puts Shard::Notes.dashed
puts Shard.worker
Shard.render_text(STDOUT)
puts ""
puts Shard.slot(3).index
puts Shard.slot(4).rebuilt

# And the shapes only a consumer reaches: a macro of the module's own that
# names its constant, a hook that fires on a type this program declares, the
# annotation that hook's expansion reads, a module's `include`, a parameter
# that takes a class, a named argument, a private overload sharing a public
# name, a module body's registry, and a name written outside the namespace.
puts Shard.limited(9)
puts Shard.limited(3)

pub struct Row
  include Shard::Mappable
  include Shard::Marked

  @[Shard::Field(key: "x")]
  @x : Int32 = 1

  def label : String
    "row"
  end

  # Read where a macro can read it: an annotation of the shard's own, on a
  # field of a type this program declares.
  def annotated : String
    {{ @type.instance_vars.first.annotation(Shard::Field) ? "annotated" : "bare" }}
  end
end

puts Shard.build(Row)
puts Row.marked
puts Row.new.stamp
puts Row.new.annotated
puts Shard::Lost.new("thing", cause: IO::Error.new("gone")).message
puts Shard::Holder(Int32).new(3).find("path")
puts Shard::Registry.at(2)
puts Shard::Registry.at(9)
puts Handy.made
IYI

sed 's|require "./shard"|import shard|' "$WORK/app_source.iyi" > "$WORK/app_artifact.iyi"

cd "$WORK" || exit 1
mkdir mods
status=0

# The namespace beside the root goes first, and `--use-iyimod mods` on the
# root's own run is what lets its declarations name that namespace's types.
# This is what `iyi bind` does for a shard with more than one namespace; here
# the order is written out, because this file drives `tool bind` itself.
if ! "$CRYSTAL" tool bind -e Sidecar --emit-bind mods entry.cr > sidecar.log 2>&1; then
  echo "binding the namespace beside the root failed"
  tail -12 sidecar.log
  echo "workdir $WORK"
  exit 1
fi
if ! (cd mods && "$CRYSTAL" build --iyi-keep Sidecar --emit-bind . \
        -o keepside sidecar_keep.cr > fill-sidecar.log 2>&1); then
  echo "filling the namespace beside the root failed"
  tail -12 mods/fill-sidecar.log
  echo "workdir $WORK"
  exit 1
fi

# The declarations. `--emit-bind` writes the artifact and the keep file beside
# it; the keep file is where the per-type units come from.
if ! "$CRYSTAL" tool bind -e Shard --emit-bind mods --use-iyimod mods entry.cr > bind.log 2>&1; then
  echo "binding the shard failed"
  tail -12 bind.log
  echo "workdir $WORK"
  exit 1
fi
sed -n '/written returns/,/^$/p' bind.log

# And the line a driver reads to find the namespace it has to bind beside this
# one. Without it `iyi bind` writes one artifact per shard and a consumer of
# `pg` cannot name `PQ::Field`.
printf 'the namespace beside the root, reported: '
grep -m1 '^also declares: ' bind.log || echo "MISSING"

# The object code. A getter whose body is one instance variable is inlined and
# emits no symbol, which is why this build is `--iyi-keep` rather than ordinary.
if ! (cd mods && "$CRYSTAL" build --iyi-keep Shard --emit-bind . \
        -o keepbin shard_keep.cr > fill.log 2>&1); then
  echo "filling the artifact failed"
  tail -12 mods/fill.log
  echo "workdir $WORK"
  exit 1
fi

# Printed because it is the evidence: without this line the union above could
# be one the consumer forms for itself, and the gate would be checking nothing.
printf 'the nested-in-a-generic method, emitted against its declaration: '
if [ -z "$STRINGS" ]; then
  echo "no strings here, so the emitted method is not read"
elif grep -c 'Shard::Holder::Note' mods/shard_keep.cr > /dev/null; then
  "$STRINGS" -a mods/shard.iyimod | grep -oE '\*Shard::Holder::Note#write[^ ]*' | sort -u | head -1 || echo "MISSING"
else
  echo "MISSING"
fi

printf 'the union this shard matches against, carried: '
"$IYI" mod dump mods/shard.iyimod | grep -F '(Char | Int32)' | tr -d ' ' || echo "MISSING"

# `--crystal` on both arms. A bound shard's artifact says it was built against
# Crystal's standard library, because it was, and a program cannot hold one
# module of each.
for arm in source artifact; do
  build_cmd=("$IYI" build --crystal)
  if [ "$arm" = artifact ]; then
    build_cmd+=(--use-iyimod mods)
  fi
  build_cmd+=(-o "out_$arm" "app_$arm.iyi")

  if ! "${build_cmd[@]}" > "build-$arm.log" 2>&1; then
    echo "$arm: build failed"
    tail -12 "build-$arm.log"
    status=1
    continue
  fi
  "./out_$arm" > "out-$arm.txt" 2>&1
done

if [ -f out-source.txt ] && [ -f out-artifact.txt ]; then
  if diff -q out-source.txt out-artifact.txt > /dev/null; then
    echo "the boundary and the source print the same thing"
  else
    echo "OUTPUT DIFFERS"
    diff out-source.txt out-artifact.txt | head -10
    status=1
  fi
fi

# The boundary goes stale when the checkout it was written from changes.
#
# It did not, and that is what this section is for. A module compiled from
# source answers staleness with the digest of the one file at its module path
# (SPEC.md IV.3); a bound shard has no such file, so `tool bind` wrote no
# hashes at all and the reader's "an artifact from before the hashes cannot
# answer" branch reported it fresh — forever. Edit the shard, rebuild, and
# the consumer compiled against the surface the boundary had last week and
# linked the object code beside it, with nothing said. The artifact carries
# the files it was written from now, each with what it hashed to.
echo "== an edited shard makes its boundary stale"
printf '\n# a comment the boundary was not written from\n' >> shard.cr
if "$IYI" build --crystal --use-iyimod mods -o out_stale app_artifact.iyi > stale.log 2>&1; then
  echo "  the edited shard still built against the old boundary"
  status=1
elif grep -q "which \`iyi bind\` read to write it, has changed" stale.log &&
     grep -q "Rebuild the boundary with \`iyi bind\`" stale.log; then
  echo "  the consumer refuses by name, and names the verb that rebuilds it"
else
  echo "  the staleness was not named:"
  sed 's/^/    /' stale.log | head -12
  status=1
fi

# And a boundary that travelled without its checkout still builds: the files
# are asked only where they are, because an artifact handed to somebody else
# is all there is (IV.3).
mv shard.cr shard.cr.away
if "$IYI" build --crystal --use-iyimod mods -o out_travelled app_artifact.iyi > travelled.log 2>&1; then
  echo "  a boundary whose checkout is gone still builds"
else
  echo "  a boundary whose checkout is gone was refused:"
  sed 's/^/    /' travelled.log | head -12
  status=1
fi
mv shard.cr.away shard.cr

# And the inputs are the shard's own files, not a neighbour's whose directory
# merely begins the same way: `lib/radix/src` is a prefix of
# `lib/radix/src-extra/extra.cr`, and a bare dirname under `starts_with?`
# recorded that file as the shard's — so the boundary went stale whenever the
# neighbour changed, and the same rule decided which types were the shard's.
echo "== a neighbour directory with the same prefix is not the shard's"
NEAR="$WORK/near"
mkdir -p "$NEAR/lib/radix/src" "$NEAR/lib/radix/src-extra"
printf 'module Extra\n  def self.e\n    3\n  end\nend\n' > "$NEAR/lib/radix/src-extra/extra.cr"
printf 'require "../src-extra/extra"\n\nmodule Radix\n  def self.r\n    Extra.e\n  end\nend\n' > "$NEAR/lib/radix/src/radix.cr"
printf 'name: radix\n' > "$NEAR/lib/radix/shard.yml"
if ! (cd "$NEAR" && "$IYI" bind --lib lib --mods mods > "$NEAR/bind.log" 2>&1); then
  echo "  the shard with a neighbour did not bind:"
  sed 's/^/    /' "$NEAR/bind.log" | head -12
  status=1
elif "$IYI" mod dump "$NEAR/mods/radix.iyimod" > "$NEAR/dump.txt" 2>&1 &&
     # Either separator: the dump names its inputs the way the platform
     # writes a path, and a check that only knows `/` called a correct
     # answer the neighbour's file.
     grep -qE 'src[/\\]radix\.cr$' "$NEAR/dump.txt" &&
     ! grep -q 'src-extra' "$NEAR/dump.txt"; then
  echo "  the inputs are the shard's file and not the neighbour's"
else
  echo "  the neighbour's file was taken as the shard's:"
  grep -n 'inputs\|\.cr$' "$NEAR/dump.txt" | sed 's/^/    /' | head -8
  status=1
fi

echo "== a method whose name iyi cannot write"
# `!` is not part of a name here (SPEC.md III.1.7), so a shard's `sort!` is
# carried by the boundary — a travelling body that calls it has to typecheck
# — and spellable by nobody writing `.iyi`. It used to cross in silence, and
# the first anyone heard of it was "undefined method 'sort'" at a call, with
# the compiler suggesting `sort!` underneath: an edit that makes the file
# stop parsing. The bind says it once, where somebody is looking at the
# shard.
BANGS="$WORK/bangs"
mkdir -p "$BANGS/lib/bangs/src"
printf 'name: bangs\n' > "$BANGS/lib/bangs/shard.yml"
cat > "$BANGS/lib/bangs/src/bangs.cr" <<'CR'
module Bangs
  class Box
    @items : Array(Int32)

    def initialize(@items : Array(Int32))
    end

    def sort! : Box
      @items = @items.sort
      self
    end

    def sorted : Array(Int32)
      @items.sort
    end
  end
end
CR
if ! (cd "$BANGS" && "$IYI" bind --lib lib --mods mods > "$BANGS/bind.log" 2>&1); then
  echo "  the shard with a bang method did not bind:"
  sed 's/^/    /' "$BANGS/bind.log" | head -12
  status=1
elif grep -q "no call in iyi can spell" "$BANGS/bind.log" &&
     grep -q "Bangs::Box#sort!" "$BANGS/mods/bangs.bind.log"; then
  echo "  the bind names it, and the log names which method"
else
  echo "  a name iyi cannot write crossed without a word:"
  sed 's/^/    /' "$BANGS/bind.log" | head -8
  status=1
fi

echo "== two shards that declare the same root"
CLASH="$WORK/clash"
mkdir -p "$CLASH/lib/alpha/src" "$CLASH/lib/beta/src"
printf 'module Shared\n  def self.a\n    1\n  end\nend\n' > "$CLASH/lib/alpha/src/alpha.cr"
printf 'name: alpha\n' > "$CLASH/lib/alpha/shard.yml"
printf 'module Shared\n  def self.b\n    2\n  end\nend\n' > "$CLASH/lib/beta/src/beta.cr"
printf 'name: beta\n' > "$CLASH/lib/beta/shard.yml"
if (cd "$CLASH" && "$IYI" bind --lib lib --mods mods > "$CLASH/bind.log" 2>&1); then
  echo "  two shards named Shared both bound, so one artifact is two shards"
  sed 's/^/    /' "$CLASH/bind.log"
  status=1
elif grep -q "also declares Shared, and" "$CLASH/bind.log" &&
     [ -f "$CLASH/mods/shared.iyimod" ]; then
  echo "  the second is refused and the first still stands"
else
  echo "  the clash was not named:"
  sed 's/^/    /' "$CLASH/bind.log"
  status=1
fi

echo "workdir $WORK"
exit $status
