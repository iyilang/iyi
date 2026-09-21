# iyi: what it would take to put a Crystal shard behind an iyi boundary.
#
#   crystal tool bind -e Kemal shard_entry.cr
#
# R-2 asks every exported signature to write its types down, and Crystal infers
# instead of writing. Most of a shard's surface can be written down without a
# human: a method whose parameters carry types can be instantiated on purpose,
# and what it returns falls out of that. This says how much of a given shard is
# in that position, which is the number that decides whether a boundary is
# worth generating at all.
#
# It reads and counts, and with `--emit-bind DIR` it writes the binding as a
# `.iyimod` (`write_artifact`) plus the keep file a second build fills the
# object code from; `iyi bind` runs both steps on every shard under `lib/`.
# No `.iyi` text is written — the boundary is the artifact. Measuring first
# is the same order every other part of this project was built in.
#
# **It lives in the compiler rather than beside it**, and the reason is worth
# keeping: reading a shard means analysing the standard library it is written
# against, and the standard library asks `size_of`, which is answered from a
# data layout. A front end that links no LLVM has none, so a tool built that
# way cannot read a single real shard.
module Iyi
  # What a method is, for a boundary.
  enum BindVerdict
    # Every parameter and the return type are written. R-2 already.
    Ready
    # The parameters are written and the return type is not: a machine can
    # instantiate this and read the answer.
    NeedsReturn
    # A parameter carries no type. Nothing can guess it, so a human writes it.
    NeedsHuman
  end

  # What happened when a written return type was held against what a caller is
  # handed. III.6 rule 1 says the binding asserts and is not checked; this is
  # how much of that is still true, as a number rather than a sentence.
  enum BindCheck
    # Nothing was written, so there is nothing to check: what travels *is* what
    # instantiation answered, which is the half that was already checked.
    NotWritten
    # Written, instantiated, and the call answers what the restriction says.
    Agrees
    # Written, instantiated, and the call answers something else — `Int` where
    # a caller gets `Int32`, an abstract base where a factory hands back the
    # concrete class, a union with a member the method never produces. A
    # consumer told the written name is told something the symbol does not do.
    Disagrees
    # Written, and instantiation could not run. The restriction stands on the
    # shard's word, which is exactly what rule 1 describes.
    Unchecked
    # Abstract: there is no body to instantiate and no symbol of its own. The
    # declaration is the dispatch contract, and what a caller reaches is an
    # implementation — each of which is an ordinary method this tool checks as
    # itself. So this is not a return standing on the shard's word; it is one
    # carried by the methods underneath it, and counting it beside them said
    # the boundary was trusting something it had already verified.
    Dispatched
  end

  record BindMethod,
    owner : String,
    name : String,
    verdict : BindVerdict,
    block : Bool,
    untyped : Array(String),
    location : String,
    # Name, restriction, and the default as written — `{"tag", "String",
    # "\"none\""}`. The default travels because a caller may leave the argument
    # out: `Node(T).new("", placeholder: true)` names one parameter and skips
    # another, and a declaration without the defaults is a different method.
    params : Array({String, String, String}),
    returns : String?,
    receiver : String,
    # The block parameter as written, `&block : Context -> B`, or empty.
    written_block : String,
    # What the return type turned out to be, once the method was instantiated
    # on purpose, or the reason it could not be.
    inferred : String?,
    refused : String?,
    # A generic's method travels as source, so the source has to be here.
    body : String?,
    # Whether every parameter names a type a variable can have. `Int` is a name
    # an iyi program can write and not a type anything can hold: it is the head
    # of a family, and a method taking one is compiled once per member with a
    # symbol apiece. The compiler answers this — `can_be_stored?` — and it is
    # the same answer that decides whether the generated keep file compiles.
    storable : Bool,
    # What holding the written return type against the call answered.
    checked : BindCheck,
    # What instantiation answered, when that differs from what was written —
    # and what travels, because the symbol is named after it.
    produced : String?,
    # Whether the type keeps the method to itself.
    private_def : Bool = false,
    # Whether the method's own *body* is what answers it.
    #
    # A block whose output is written `_` means "whatever the block returns",
    # and there is no single answer to read — which is why instantiating one is
    # refused. But a block-taking method's body travels and the consumer is what
    # compiles it (IV.1g), so the consumer infers the answer the same way the
    # shard's own compiler would. `Kemal::RouteHandler#add_route` is the case,
    # and the whole DSL is written on top of it.
    #
    # The declaration then carries no return type, which is the same shape a
    # method that writes none already crosses in.
    body_answers : Bool = false,
    # Whether the *compiler* refused to instantiate it — the method does not
    # compile. It must not be declared: the keep file names what a boundary
    # declares, and one method that does not typecheck takes the whole fill
    # build down with it, leaving every declaration on disk and no machine code
    # anywhere. `openssl_ext` is the case — a `LibCrypto` call whose argument is
    # a pointer too deep, in a method the shard's own compilation never types.
    uncompilable : Bool = false,
    # Whether it is an `abstract def`. It has no body to emit and no symbol
    # behind it, so the keep file must not call one — `t0.title` on a class
    # with no subclass has no type, and codegen said so as a compiler bug
    # rather than as an error anybody could act on. What crosses is the
    # *requirement*, which is what a consumer subclassing the type has to meet.
    abstract_def : Bool = false,
    # Whether this method answers an `abstract def` an ancestor wrote.
    #
    # A method that does is one somebody else's body calls, whatever its
    # visibility: `db` writes `protected abstract def perform_exec(args :
    # Enumerable) : ExecResult` and `Statement#exec`'s body — which travels —
    # calls it, so every driver's implementation has to be declared for that
    # body to compile against. The search that finds a travelling body's
    # private callees cannot find this one: the body is in *db's* artifact and
    # the implementation is in the driver's, two boundaries that never see each
    # other's text. The requirement is the thing they do share.
    answers_abstract : Bool = false,
    # The file the shard's author wrote this method in, or empty where that is
    # nobody's file.
    #
    # A boundary carries what a shard *wrote*. `Class#name` is
    # `{{ @type.name.stringify }}` in Crystal's own `class.cr`, one
    # instantiation per type, and a shard's classes inherit it like everything
    # else — so it was crossing as a *header*, which is a promise of a symbol
    # per subclass that only the types with units behind them could keep. A
    # consumer forming `DB::PoolResourceLost(DB::Connection+)` got the header
    # and nothing to link: `undefined symbol:
    # *DB::PoolResourceLost(DB::Connection+)::name:String`. It has its own
    # `class.cr` and makes its own, which is what every other program does.
    written : String = "",
    # The names `forall` introduces, which are the method's own.
    #
    # They were never carried, so a method with one lost it twice over: the
    # `forall` clause did not travel, and the free variable failed the test
    # that asks whether every name in a signature is one the far side can
    # write. `db` writes `def query_one(query, *args_, args : Array? = nil,
    # &block : ResultSet -> U) : U forall U` — the block-taking overload the
    # whole query API is built on — and a consumer's own body called it and met
    # only the three that take a type: `'DB::Database#query_one' is not
    # expected to be invoked with a block`.
    free_vars : Array(String) = [] of String do
    # What this method answers, which is not always what the shard wrote.
    #
    # The instantiated answer wins where the two disagree, and the linker is
    # what decided that rather than an argument. A shard writing
    # `def wider : String?` over a body returning a `String` gets a symbol named
    # `*Shard::Part#wider:String`; a declaration repeating the restriction has
    # the consumer ask for `*Shard::Part#wider:(String | Nil)`, and nobody
    # emitted one. `produced` is set only where they disagree, so this reads as
    # the written type everywhere else.
    def answer : String?
      produced || returns || inferred
    end

    # Every type this signature names, so the emitter can ask whether they can
    # all be named on the other side.
    # The names this signature may use that nobody declares: the free variables
    # `forall` introduces, and — inside a generic — its type parameters, which
    # the callers add.
    def signature_types : Array(String)
      types = params.map { |(_, restriction, _)| restriction }
      if declared = answer
        types << declared
      end
      # The restriction only. `&block : Int32 -> Int32` names one type and one
      # parameter, and reading the parameter as a type made every annotated
      # block look like it mentioned something nobody declared.
      types << written_block.split(" : ", 2).last unless written_block.empty?
      types
    end

    # Whether anything outside could call this.
    #
    # A block-taking method is compiled per block *type* and the type is in the
    # symbol, so one whose block nobody annotated has no single symbol to
    # declare. `infer_return` already refuses these — but only when it runs, and
    # a method that writes its return type never reaches it. The keep file finds
    # the rest: `Time.measure` is expected to be invoked with a block.
    def callable? : Bool
      !block || !written_block.empty?
    end

    # The `pub def` an iyi module would carry. Parameters as the source wrote
    # them; the return from `answer`, which is what the source wrote only where
    # that is also what a caller is handed.
    def declaration : String
      args = params.map { |(name, restriction, _)| "#{name} : #{restriction}" }.join(", ")
      signature = args.empty? ? name : "#{name}(#{args})"
      "pub def #{signature} : #{answer || "Nil"}"
    end
  end

  # Where Crystal's own library lives, for `shard_wrote?`. Reset per run.
  @@library = ""

  # The namespace being bound, for `global_name`. Reset per run.
  @@root : String = ""

  # Bodies that name a method without being seen to call it. Reset per run.
  #
  # `responds_to?(:name)` is the one call the private-callee search cannot
  # follow, because the receiver is whatever the caller passed. `db` writes
  # `Pool(T)#checkout` — a generic, so its body travels — and it ends
  # `res.responds_to?(:before_checkout) && res.before_checkout`.
  # `Connection#before_checkout` is `protected`, so it crosses only if
  # something is seen to call it, and nothing is: `Pool` is not `Connection`'s
  # ancestor and `T` binds to it nowhere a search can read. The hook stayed
  # behind, `responds_to?` answered false in the consumer, `auto_release` was
  # never set, and no connection ever went back to the pool —
  # `DB.open("sqlite3::memory:")` got a fresh database per statement and lost
  # its table between them.
  #
  # Every body that says `responds_to?` is searched for every type, which errs
  # long the way the rest of this search does: `calls?` matches a name that is
  # actually there, and a body naming nothing of this type's costs a scan.
  @@duck_bodies : Array(String)? = nil

  # Whether this method is anybody's but the library's. See `BindMethod#written`.
  #
  # The test is where it is *not* written rather than where it is, and the
  # difference is another boundary. A method a shard inherits from Crystal's
  # own library —
  # `Class#name`, `Reference#hash` — is one the consumer has its own copy of
  # and makes for itself. A method it inherits from another *shard* is not:
  # `sqlite3`'s `ResultSet` gets `close` from `db`'s `Disposable` module, the
  # consumer has that only as a header, and `db`'s artifact cannot define it
  # because a module's method is compiled per including type and
  # `SQLite3::ResultSet` is not one of db's.
  private def self.shard_wrote?(method : BindMethod) : Bool
    return true if @@library.empty?
    return true if method.written.empty?
    !method.written.starts_with?(@@library)
  end

  # The types an iyi program already has, so a signature naming one of them
  # needs nothing from this boundary. Everything else is somebody's to declare,
  # and saying which is most of what a boundary costs.
  #
  # Asked of the program rather than written down here. The written-down version
  # claimed `Void`, `UInt32` and `Float64` — which iyi's prelude never declares —
  # and left out `Slice`, `Int`, `Tuple` and `NamedTuple`, which the compiler
  # creates for every program before any prelude is read. Those four were most
  # of what the boundary appeared to be waiting on, so the list was not merely
  # untidy: it invented the work it was being read to size.
  @@builtin = Set(String).new

  # The boundaries already written. A signature naming one of their types waits
  # on nobody: somebody has declared it, which is the whole question this asks.
  # `IO` is why this exists — it is what `JSON`, `YAML` and `URI` were all
  # waiting on, and once it has an artifact it stops being a gap.
  @@bound = Set(String).new

  # The shard's own type names, qualified. See `nameable_name?`.
  @@declared = Set(String).new

  # The class variables a module body assigns, which the initialiser carries
  # and the declaration therefore must not. See `collect_runnable`.
  @@assigned_class_vars = Set(String).new

  # The methods whose bodies travel, keyed the way `keep_type` reads them:
  # the container and the signature *as collected*, before the rewrites that
  # strip the root and map another boundary's names. `MonoBodies` is rekeyed
  # by those rewrites and the keep file is not, so the two stopped matching —
  # and a method the keep file must not call was called: `openssl_ext`'s
  # `SignatureVerifier.extract_signature`, whose body the shard's own build
  # cannot type, took the fill build down with it.
  @@travelling = Set(String).new

  # The types Crystal's library defines, which a consumer of a bound shard has.
  #
  # It has them because it must: the units number
  # `Pointer(LibUnwind::Exception)` whatever the shard does, so the consumer is
  # a `--crystal` program, and a `--crystal` program is one with Crystal's
  # library in it. The shard's own requires travel beside this, so the files the
  # prelude leaves out are there too.
  #
  # This predicate is what decides every count this tool prints, and it used to
  # ask what an *iyi-prelude* program could name — a program that cannot consume
  # one of these artifacts at all. So the surface read low: `Kemal::Route` and
  # five more were refused for naming types their actual consumer would have.
  @@crystal_types = Set(String).new

  # And the library's types a consumer cannot *name* but can hold. See
  # `nameable_value?`.
  @@crystal_private = Set(String).new

  # The shard's own top-level `fun`s, as source. Travelling bodies like any
  # other, and the consumer compiles them: see `called_privates`.
  @@top_level_fun_sources = [] of String

  # Types no file can write `uninitialized` of: an abstract struct is not a
  # value with a size - `uninitialized ::Number` is `can't use Number as the
  # type of a variable yet`, and `quartz_mailer`'s
  # `def smtp_port=(port : Number)` took the whole shard down over it. The
  # method's body travels instead, the way it does for every other shape the
  # keep file cannot stand a value up for.
  @@unwritable = Set(String).new

  # And what to call them from outside. A bound artifact's declarations sit
  # under the module the consumer imports, so `IO` is `Io::IO` there — the
  # producer's name is not the consumer's, and an artifact that referred to one
  # by the other resolved to nothing.
  @@bound_prefix = {} of String => String

  # Which module each of those names came from, and which of them this artifact
  # ended up naming. A boundary that refers to another one depends on it, and a
  # consumer should not have to work that out and write the `import` itself.
  @@bound_module = {} of String => String
  @@bound_used = Set(String).new

  # iyi: this scanner is reached by the compiler, so stdlib Regex would keep
  # pcre2 on its link line. Compile the grammar once through Iyi::Rx instead
  # of maintaining four hand-written tokenizers (SPEC.md III.10).
  private BIND_TYPE_NAME = Rx::Pattern.compile("[A-Za-z_][A-Za-z0-9_:]*")

  # Methods this run leaves out of both the artifact and the keep file, read
  # from `<artifact>.drop` beside the artifact - one key per line, in the
  # spelling the keep file's `# bind-drop:` markers use.
  #
  # What it is for is a method whose *body does not compile* when it is
  # instantiated. A shard's own build never typed it - Crystal types a body
  # when something calls it, and nothing in `ed25519` calls
  # `RistrettoPoint#==`, whose body calls an `assert_rst_point` that shard
  # never defined. The keep file calls everything, so the fill build is where
  # that surfaces, and it stopped the whole shard: `jwt` went unbound behind
  # it over one method a consumer could not have called either.
  #
  # A method that cannot compile cannot cross. Leaving it out is the same
  # verdict this tool reaches everywhere else, arrived at one build later:
  # `iyi bind` reruns with the key appended and the boundary carries the rest.
  @@drop = Set(String).new

  # How deep `Call#instantiate` may go before this tool calls it non-terminating.
  # See `Program#iyi_instantiation_limit`.
  INSTANTIATION_LIMIT = 256

  def self.print_bind(program : Program, root : String?, io : IO,
                      artifact_dir : String? = nil, bound_dir : String? = nil) : Nil
    unless root
      io.puts "tool bind needs the shard's own namespace: -e Kemal"
      return
    end

    # Deep enough that no method anybody wrote reaches it, and shallow enough
    # that the stack does not end first. What it is for is a recursion with no
    # bottom, which is a different thing from a deep one: `Log`'s
    # instantiation recurses forever, and the frames it repeats are five deep.
    program.iyi_instantiation_limit = INSTANTIATION_LIMIT

    @@library = library_root(program) || ""
    @@root = root
    @@duck_bodies = nil
    @@builtin = program.builtin_type_names
    @@crystal_private = Set(String).new
    @@crystal_types = crystal_library_types program
    @@unwritable = unwritable_types program
    @@bound_prefix = {} of String => String
    @@mono_bodies = {} of String => String
    @@bound_module = {} of String => String
    @@bound_used = Set(String).new
    @@bound = bound_dir ? bound_names(program, bound_dir, io) : Set(String).new
    @@library_names = Set(String).new
    @@declared = declared_names program, root
    @@assigned_class_vars = Set(String).new
    @@travelling = Set(String).new
    @@self_shadowed = Set(String).new
    @@drop = artifact_dir ? drop_list(artifact_dir, root) : Set(String).new
    @@top_level_fun_sources = top_level_funs program

    methods = [] of BindMethod
    collect_bind program.types?, root, methods

    # iyi: which of them cannot cross as object code (SPEC.md III.6).
    #
    # Here rather than in the build that got us this program, because the
    # instantiations this reads are the ones `collect_bind` just made: a shard
    # compiled alone types almost none of its own bodies, and `infer_return`
    # instantiates each method on purpose. The answer is read back below by
    # location — a `BindMethod` is a record of strings and holds no `Def`.
    OpenTravel.mark program

    ready = methods.count(&.verdict.ready?)
    inferable = methods.count(&.verdict.needs_return?)
    human = methods.count(&.verdict.needs_human?)

    # The shard's *other* namespaces, which are boundaries of their own.
    #
    # A boundary is rooted at one namespace and a shard need not have only
    # one: `pg` declares `PG` and `PQ`, its wire protocol, in the same tree.
    # Rooted at `PG` alone the artifact carried `PG`'s units and referred to
    # `Array(PQ::Field)`, a type the consumer had never heard of - `"p_g"
    # numbers `Array(PQ::Field)`, and this build cannot name it`. Neither half
    # can be fixed inside one artifact: the declarations belong at the
    # consumer's top level rather than under `PG`, and the object code is a
    # unit of its own.
    #
    # So they are reported, and `iyi bind` binds each of them beside this one.
    # Named on one line, in a shape a driver can read.
    others = other_namespaces program, root
    io.puts "also declares: #{others.join(", ")}" unless others.empty?
    io.puts

    io.puts "#{root}: #{methods.size} public methods on its own types"
    io.puts
    io.puts "  R-2 as written            #{ready}"
    io.puts "  a machine can write       #{inferable}"
    io.puts "  a human has to write      #{human}"
    io.puts
    io.puts "  of those, take a block    #{methods.count(&.block)}"

    unless @@drop.empty?
      io.puts
      io.puts "left out by #{iyi_module_name(root).gsub('/', '-')}.drop: #{@@drop.size}"
      io.puts "  a body that does not compile when it is instantiated cannot"
      io.puts "  cross, and the fill build is where that is found. These are"
      io.puts "  out of the declarations and out of the keep file both:"
      @@drop.to_a.sort.each { |key| io.puts "    #{key}" }
    end

    machine = methods.select(&.verdict.needs_return?)
    unless machine.empty?
      answered = machine.count { |m| m.inferred }
      io.puts
      io.puts "instantiated on purpose, to read what they return:"
      io.puts "  answered                  #{answered}"
      io.puts "  refused                   #{machine.size - answered}"
      machine.select(&.refused).group_by { |m| m.refused.not_nil! }
        .to_a.sort_by { |(_, v)| -v.size }.first(8).each do |(reason, list)|
        io.puts "    %-38s %d" % [reason[0, 38], list.size]
      end
    end

    # III.6 rule 1 as a number. The half above reads a return nobody wrote; this
    # half holds a return somebody did write against the same answer, and says
    # how much of the boundary is still standing on the shard's word.
    written = methods.reject(&.checked.not_written?)
    unless written.empty?
      disagreed = written.select(&.checked.disagrees?)
      io.puts
      io.puts "written returns, held against what a caller is handed:"
      io.puts "  agrees                    #{written.count(&.checked.agrees?)}"
      io.puts "  disagrees                 #{disagreed.size}"
      io.puts "  abstract, so dispatched   #{written.count(&.checked.dispatched?)}"
      io.puts "  could not be checked      #{written.count(&.checked.unchecked?)}"
      written.select { |m| m.checked.unchecked? && m.refused }
        .group_by { |m| m.refused.not_nil! }
        .to_a.sort_by { |(_, v)| -v.size }.first(8).each do |(reason, list)|
        io.puts "    %-38s %d" % [reason[0, 38], list.size]
      end

      unless @@flattened.empty?
        io.puts
        io.puts "  constants whose accessor name was already taken:"
        @@flattened.sort.first(8).each { |constant| io.puts "    #{constant}" }
      end

      unless disagreed.empty?
        io.puts
        io.puts "  and the ones that travel as the answer, not as written:"
        disagreed.sort_by { |m| {m.owner, m.name} }.first(12).each do |method|
          io.puts "    #{method.owner}##{method.name}"
          io.puts "      writes #{method.returns}, answers #{method.produced}"
        end
        io.puts "    ... and #{disagreed.size - 12} more" if disagreed.size > 12
      end
    end

    return if methods.empty?
    mechanical = ready + inferable
    io.puts
    io.puts "  #{(mechanical * 100.0 / methods.size).round(1)}% of the surface needs no human."

    emit_module program, methods, root, io
    write_artifact program, methods, root, artifact_dir, io if artifact_dir

    # iyi: the ones a consumer cannot call, whatever the boundary carries.
    # `!` is not part of a name here (SPEC.md III.1.7), so `sort!` is
    # spellable by nobody writing `.iyi` — the declaration travels, because
    # a body that calls it has to typecheck, and a call written by hand
    # cannot reach it. Said here because this is where somebody is looking
    # at the shard: the alternative is finding out at the call, one
    # "undefined method" at a time.
    unspellable = methods.select do |method|
      method.name.size > 1 && method.name.ends_with?('!') && !method.private_def
    end
    unless unspellable.empty?
      io.puts
      io.puts "names iyi cannot write (#{unspellable.size}):"
      unspellable.sort_by { |m| {m.owner, m.name} }.first(12).each do |method|
        io.puts "  #{method.owner}##{method.name}"
        io.puts "    #{method.location}"
      end
      io.puts "  ... and #{unspellable.size - 12} more" if unspellable.size > 12
      io.puts "  `!` cannot end a name in iyi (SPEC.md III.1.7). Each is reachable"
      io.puts "  only through a Crystal-side method with a name this language can write."
    end

    return if human.zero?

    # Named, because the count is the estimate and this is the work. Each line
    # is one signature somebody has to decide, and the parameter it is about.
    io.puts
    io.puts "what a human has to write:"
    methods.select(&.verdict.needs_human?).sort_by { |m| {m.owner, m.name} }.each do |method|
      io.puts "  #{method.owner}##{method.name}(#{method.untyped.join(", ")})"
      io.puts "    #{method.location}"
    end
  end

  # The draft boundary: what a consumer would import.
  #
  # A signature goes in when every type in it is one an iyi program can name —
  # the shard's own, or the prelude's. What is left out is left out by name,
  # because those are the types somebody has to decide about, and deciding is
  # the work this tool exists to size.
  private def self.emit_module(program : Program, methods : Array(BindMethod),
                               root : String, io : IO) : Nil
    known = methods.select { |m| m.verdict.ready? || m.inferred }
    lines = [] of String
    outside = Hash(String, Int32).new(0)
    unnameable = Hash(String, Int32).new(0)

    unheld = 0
    unblocked = 0
    waiting = 0
    never = 0
    # What is left of III.6 rule 1, counted where it is actually owed.
    #
    # The report above counts every written return that could not be held
    # against an answer, and most of those methods do not cross at all: a
    # parameter with no type, a block nobody annotated, a splat. They are
    # already refused by name further down, so counting them as unchecked risk
    # says the boundary is trusting things it never carried.
    #
    # A method that *crosses* on a written return type nobody could verify is
    # the one this rule is about, so it is counted separately and listed.
    unchecked = [] of BindMethod
    known.each do |method|
      types = method.signature_types
      foreign = types.reject { |t| nameable?(t, root) }
      unless method.storable
        unheld += 1
        next
      end
      unless method.callable?
        unblocked += 1
        next
      end
      if foreign.empty?
        lines << method.declaration
        unchecked << method if method.checked.unchecked?
      else
        # Whether anything on this signature is a type somebody could declare.
        # If nothing is, no amount of work reaches it and it does not belong in
        # the same count as the ones that are waiting for a decision.
        declarable = false
        # Named by the part that is missing rather than by the whole
        # signature, because the part is what somebody has to declare and one
        # decision unblocks every signature that mentions it.
        foreign.each do |type|
          Rx.scan(type, BIND_TYPE_NAME).each do |match|
            part = match[0].not_nil!
            next if part == "class"
            next if nameable_name?(part, root)
            # `T` is a free variable, `self` is the receiver and `_` is a block
            # nobody annotated. None is a type anybody could declare, and
            # counting them beside `IO` said there was more waiting than there
            # was — the same inflation, one layer further in.
            if declared_type? program, part
              outside[part] += 1
              declarable = true
            else
              unnameable[part] += 1
            end
          end
        end
        declarable ? (waiting += 1) : (never += 1)
      end
    end

    io.puts
    io.puts "a boundary this tool can already write:"
    io.puts "  signatures                #{lines.size}"
    io.puts "  waiting on a type nobody has declared  #{waiting}"
    if unheld > 0
      io.puts "  taking a type no variable can hold     #{unheld}"
    end
    if never > 0
      io.puts "  naming something that is not a type    #{never}"
    end
    if unblocked > 0
      io.puts "  taking a block nobody annotated        #{unblocked}"
    end
    io.puts "  crossing on a return nobody checked    #{unchecked.size}"

    unless unchecked.empty?
      io.puts
      io.puts "what is left of rule 1, by why the answer could not be read:"
      unchecked.group_by { |m| m.refused || "no reason recorded" }
        .to_a.sort_by { |(_, list)| -list.size }.each do |(reason, list)|
        # Whole, not to a column. This list is three methods across Crystal's
        # own library and each is somebody's next piece of work, so a reason
        # cut at 38 characters is the one thing it must not be.
        io.puts "  #{reason} — #{list.size}"
        list.sort_by { |m| {m.owner, m.name} }.first(3).each do |method|
          io.puts "    #{method.owner}##{method.name} : #{method.returns}"
        end
        io.puts "    ... and #{list.size - 3} more" if list.size > 3
      end
    end

    unless outside.empty?
      io.puts
      io.puts "the types that boundary is waiting on:"
      outside.to_a.sort_by { |(_, c)| -c }.first(10).each do |(name, count)|
        io.puts "  %-44s %d" % [name, count]
      end
    end

    unless unnameable.empty?
      io.puts
      io.puts "and the names that are not types anybody can declare:"
      unnameable.to_a.sort_by { |(_, c)| -c }.first(10).each do |(name, count)|
        io.puts "  %-44s %d" % [name, count]
      end
      io.puts "  A free variable, `self`, or a block nobody annotated. These"
      io.puts "  never cross, and no work makes them."
    end

    # Only the ones a declaration would actually free. A signature this tool
    # refuses for its parameters or its block is not waiting on anybody, and
    # counting it here would promise that declaring a type reaches it.
    blockable = known.select { |method| method.storable && method.callable? }
    unlocked = blocked_by(program, blockable, root)
    unless unlocked.empty?
      io.puts
      io.puts "declaring one type at a time, and what each one unlocks:"
      declared = Set(String).new
      total = 0
      unlocked.first(8).each do |name|
        declared << name
        opened = blockable.count do |method|
          foreign_names(method, root).all? { |t| declared.includes?(t) } &&
            !foreign_names(method, root).empty?
        end
        io.puts "  %-40s %+d  (%d in all)" % [name, opened - total, opened]
        total = opened
      end
    end

    return if lines.empty?

    io.puts
    io.puts "# --- draft ---"
    io.puts "# Flat, and a real boundary is not: these methods belong to the"
    io.puts "# types that declare them, and grouping them there is the next"
    io.puts "# thing this tool has to learn. What is settled here is the part"
    io.puts "# that was in doubt, which is whether the signatures can be known."
    io.puts "module #{iyi_module_name(root)}"
    io.puts
    lines.sort.each { |line| io.puts line }
    io.puts "# --- end ---"
  end

  # The files this boundary was written from, `<md5> <path>` each, sorted.
  #
  # `Program#requires` is insertion-ordered and holds the resolved path of
  # everything this build read, so the shard's own files are the ones under
  # its directory — the same rule `initialiser_source` and
  # `top_level_fun_sources` read them by. Crystal's library is not among
  # them on purpose: which compiler built the artifact is already an equality
  # on `compiler_version` (IV.5), and a checkout of the standard library is
  # not a thing a consumer edits.
  #
  # Sorted rather than in require order, because this is a cache key: two
  # binds of an unchanged checkout have to produce the same bytes.
  private def self.bind_inputs(program : Program) : Array(String)
    source = program.filename
    return [] of String unless source.is_a?(String)
    directory = directory_of(source)
    return [] of String if directory.empty?

    entries = [] of String
    program.requires.each do |path|
      next unless path.starts_with?(directory)
      next unless File.file?(path)
      entries << "#{IyiMod.digest(File.read(path))} #{File.expand_path(path)}"
    end
    entries.sort!
  end

  # The artifact itself: declarations a consumer type-checks against.
  #
  # There is nothing new in it. The two sides mangle names identically, being
  # one compiler — `Lib::Greeter.polite(String) : String` is
  # `*Lib::Greeter@Lib::Greeter::polite<String>:String` compiled from either
  # language — so a shard's object file already defines the symbols an iyi
  # consumer would call. What was missing was a `.iyimod` saying they exist.
  #
  # Module functions only for now, which is the shape that was proved end to
  # end. A method on a type needs a `TypeDecl` beside it, and that is the next
  # thing this has to learn.
  private def self.write_artifact(program : Program, methods : Array(BindMethod),
                                  root : String, dir : String, io : IO) : Nil
    # Both spellings of "on the module itself". A module written with
    # `extend self` — which is what an iyi module header desugars to, and what
    # a Crystal library writes by hand for the same reason — defines its
    # functions on the module and reaches them through the metaclass, so the
    # owner recorded here is one or the other depending on which side wrote it.
    owners = {root, "#{root}:Module"}
    signatures = [] of IyiMod::Signature
    seen = Set(String).new

    # And only a module has them. `Kemal.run` is a module function because
    # `Kemal` is a module and its own methods are reachable through it; `IO`'s
    # are not — `IO.write` is an instance method and calling it on the class is
    # an error. A class root's own surface has to travel as *its type's*
    # methods, which is work this tool has not done, so it travels as nothing
    # rather than as a declaration naming a symbol nobody emits.
    methods.each do |method|
      next unless module_root? program, root
      next unless owners.includes?(method.owner)
      next if method.private_def
      next unless method.verdict.ready? || method.inferred || method.body_answers
      # Unless the body is what crosses. A method this build could not
      # instantiate has no symbol here — which is the same thing a travelling
      # body says — and the consumer compiles it in a program that has
      # whatever this one was missing. See `body_answers`.
      next if method.uncompilable && !method.body_answers
      # `storable` asks what a method *called by symbol* needs. One whose body
      # travels is compiled by the consumer, so what its parameters are written
      # as is not this file's business — `Kemal.run(args = ARGV, &)` writes no
      # restriction on `args` and the whole of running an app is behind it.
      next unless method.storable || method.body_answers
      next unless method.callable?
      next unless method.body_answers || method.signature_types.all? { |t| nameable?(t, root, method.free_vars) }

      signature = IyiMod::Signature.new(
        name: method.name,
        # Whose method it is, which the symbol carries. A module written
        # `extend self` defines `polite` on the module and mangles
        # `*Widget@Widget::polite<String>:String`; one written `def self.polite`
        # defines it on the metaclass and mangles `*Widget::polite<String>:String`
        # — no `@`. Both were recorded as the first, so every `def self.` in a
        # shard produced a declaration the consumer called by a name nothing
        # emitted. Crystal's own library is written the second way throughout.
        receiver: method.owner == "#{root}:Module" && method.receiver.empty? ? "self" : method.receiver,
        parameters: method.params.map { |(name, restriction, default)| bind_parameter(name, restriction, default) },
        block_parameter: method.written_block,
        return_type: method.body_answers ? (method.returns || "") : (method.answer || ""),
        free_variables: method.free_vars,
        required: false,
      )
      # One declaration per *signature*, which is what tells two methods apart.
      #
      # This was one per name, and a name is what a shard's overloads share.
      # `Kemal` writes four `run`s and two `config`s; the first one seen took
      # the name and the rest were dropped, so `Kemal.config` crossed as the
      # form taking a block and a body calling it without one stopped the
      # consumer on `is expected to be invoked with a block`. Crystal's own
      # overload resolution tells them apart by their parameters, and so does
      # the declaration a consumer reads: nothing here needed collapsing.
      #
      # What the set is still for is the same method arriving twice. A module
      # written `extend self` defines its functions on both the module and its
      # metaclass, and both spellings are in `owners` above.
      key = "#{signature.receiver}##{signature.name}" \
            "(#{signature.parameters.join(", ")})#{signature.block_parameter}"
      next unless seen.add?(key)
      signatures << signature

      # And the body, where the body is what answers.
      #
      # A module function that yields has no machine code of its own — the
      # block is the consumer's, so the consumer compiles the method. Its
      # declaration crossed without one, and the consumer read a `def` nobody
      # had compiled: `Kemal.run` arrived as a name and the link ended on it.
      # Every other travelling body in this file goes over the same way; this
      # is the one place that had a collector and no `MonoBodies` line.
      #
      # And a module's own *instance* method travels for a second reason, the
      # one IV.1g gives for a module: it is compiled once per including type,
      # so there is no single symbol for the producer to emit. `module Gen`
      # writes `def next_pair` and `class Fixed` includes it; what a consumer
      # calling `Fixed#next_pair` wants is
      # `*Gen::Fixed@Gen#next_pair:Tuple(UInt32, UInt32)`, and the producer
      # emits that only for the including types *its own code* instantiated.
      # `db` has them because `db`'s code calls `close` on all three of its
      # `Disposable`s; a module whose includers the shard never uses has none,
      # and the link ended on the name.
      #
      # Only where the module does not `extend self`, which is the same
      # distinction the keep file takes: a module that does answers to these
      # itself, so the producer emits `*Gen@Gen#next_pair` and the keep file
      # keeps it alive.
      travels = method.body_answers ||
                (signature.receiver.empty? && !extends_self?(program, root))
      if travels && (body = method.body) && !body.empty?
        @@mono_bodies[IyiMod.mono_body_key(iyi_module_name(root), signature)] = travelling_body(body)
      end
    end

    # And the shard's own top-level `def`s, which are on nobody's namespace.
    #
    # Every filter the module functions take applies here for the same reason,
    # save the two that are about *being* a module function: the owner, which
    # is `Object`, and `module_root?`, which asks a question about `root` and
    # not about these. A `-> _` block is what most of them take, so most of
    # them travel as bodies — which is the whole reason the DSL could not cross
    # before there was a body to carry.
    top_level = [] of IyiMod::Signature
    top_seen = Set(String).new
    top_methods = [] of BindMethod
    collect_top_level program, top_methods
    top_methods.each do |method|
      next if method.private_def
      next unless method.verdict.ready? || method.inferred || method.body_answers
      next if method.uncompilable
      next unless method.storable || method.body_answers
      next unless method.callable?
      next unless method.body_answers || method.signature_types.all? { |t| nameable?(t, root, method.free_vars) }

      signature = IyiMod::Signature.new(
        name: method.name,
        receiver: "",
        parameters: method.params.map { |(name, restriction, default)| bind_parameter(name, restriction, default) },
        block_parameter: method.written_block,
        return_type: method.body_answers ? (method.returns || "") : (method.answer || ""),
        free_variables: method.free_vars,
        required: false,
      )
      # With its body, always, and that is what a top level *is*.
      #
      # Every other declaration here names a symbol in this artifact's object
      # code, and the object code is per type: a shard's types each have a unit
      # and the units travel. A `def` outside every namespace has no type and
      # so no unit — it is compiled into the producing program's own main
      # module, which is the one thing a boundary never carries. `render_404`
      # crossed as a header and the link ended on `undefined symbol:
      # *render_404:String`.
      #
      # So the consumer compiles them, which it can: they are ordinary source,
      # and the declarations above give them every name they use. One without a
      # body cannot cross at all, and that is honest rather than a link error.
      body = method.body
      next if body.nil? || body.empty?

      key = "#{signature.name}(#{signature.parameters.join(", ")})#{signature.block_parameter}"
      next unless top_seen.add?(key)
      top_level << signature
      @@mono_bodies[IyiMod.mono_body_key(IyiMod::TOP_LEVEL_CONTAINER, signature)] = travelling_body(body)
    end

    # And what the shard added to types it does not own.
    reopened = reopened_types program, root

    # Which are names the consumer can write, and the reason this is here
    # rather than further down. `nameable?` asks whether an iyi program can
    # name a type, and answers from the prelude, the shard's own root and the
    # boundaries beside it — three sources, and this is a fourth. `openssl_ext`
    # declares `struct EvpPKey` inside `lib LibCrypto`, Crystal's own
    # `lib_crypto.cr` does not, and `OpenSSL::PKey::PKey`'s `@pkey` field names
    # it. Counted as unnameable, the class crossed as a *handle* — no fields,
    # and `new` dropped with them, which is what keeps a handle honest — and
    # the consumer could not build a key: `expected argument #1 to
    # 'OpenSSL::PKey::RSA.new' to be IO, Int32 or String, not Bool`.
    reopened.each do |declaration|
      names = Set(String).new
      collect_known declaration, "", names
      names.each { |name| @@crystal_types << name.lchop("::") }
    end

    # The copy the consumer reads. The one above is the keep file's, and it is
    # written in the shard's own names: `Kemal::Router` is `Router` on the far
    # side and `Router` in a file compiled against the shard is nothing at all.
    top_exported = top_level

    # The private module functions those bodies call.
    #
    # `Exports#carried_functions` was written for exactly this and `tool bind`
    # never filled it: `Kemal.run` yields, so the consumer compiles its body,
    # and that body calls `setup_404` and `setup_trap_signal`, which kemal keeps
    # to itself. The consumer said `undefined local variable or method
    # 'setup_404' for Kemal:Module`. It is the same walk a type's methods
    # already take — the module is the container and its two owner spellings are
    # the pool — so it is the same call.
    carried_functions =
      if (root_module = program.types?.try &.[]?(root)) && module_root?(program, root)
        called_privates root_module, iyi_module_name(root),
          methods.group_by(&.owner), signatures
      else
        [] of IyiMod::Signature
      end

    # Before the declarations, because it decides one thing about them: a
    # class variable this text assigns must not also carry a value in its
    # declaration. See `collect_runnable`.
    initialiser = initialiser_source(program, root)

    types = type_declarations program, methods, root

    # A constant crosses as a function, and that function gets an iyi module
    # function's symbol from `extend self` — which only a module takes. So a
    # class root's constants stay behind rather than being declared with
    # nothing to link against, a failure that is invisible until link time.
    accessors =
      if module_root? program, root
        constant_accessors program, root, types
      else
        [] of {IyiMod::Signature, String}
      end

    signatures.concat accessors.map(&.[0])

    # An artifact's declarations belong to the artifact, not to the namespace
    # that produced them.
    #
    # A class root already reads that way: its own name is a declaration in the
    # file, so `MySink::Entry` resolves wherever the module lands. A module root
    # dropped that name and kept the references — `MyLib::Entry` with no `MyLib`
    # — and the consumer cannot supply it, because an iyi module path is
    # `[a-z][a-z0-9]*` and its mapping to a type name is deliberately reversible
    # (IV.6 #6). `MyLib` comes back as `Mylib`, and `JSON` is not in the image of
    # that mapping at all. So the producer's prefix comes off instead.
    #
    # Into copies, and that is the whole of the care this needs. The keep file
    # below is *Crystal*, compiled against the shard where these names are the
    # shard's own: renaming there produces `undefined constant Any` and no
    # object file at all.
    # What `<artifact>.drop` names comes out of both sides at once, which is
    # the whole reason it is applied here: the artifact and the keep file below
    # are built from these two lists, and a declaration whose object code is
    # not emitted is a link error one build later. See `@@drop`.
    unless @@drop.empty?
      signatures.reject! { |signature| @@drop.includes? drop_key(root, signature) }
      prefix = module_root?(program, root) ? "#{root}::" : ""
      types = types.map { |declaration| drop_methods declaration, prefix }
    end

    exported = signatures
    carried_types = types

    # The root's own class variables, which belong to no declaration because a
    # module is not a `TypeDecl`. `module Backtracer; class_getter(configuration)`
    # is the case that said so: every type of that shard travelled with its
    # class variables and `Backtracer::configuration` was still undefined at the
    # end of the link.
    #
    # A *class* root has one, so it takes them with it: they are already in the
    # declaration below, and writing them here as well puts a `@@` outside every
    # type — `can't use class variables at the top level`, which is what
    # `bindata` said, its root being `abstract class BinData` with a
    # `@@bit_fields`.
    root_type = program.types?.try &.[]?(root)
    root_class_vars =
      if root_type && module_root?(program, root)
        collect_class_vars(root_type)
      else
        [] of IyiMod::ClassVarDecl
      end

    if module_root? program, root
      exported = exported.map do |signature|
        rekey_body(iyi_module_name(root), signature, strip_root(signature, root)) { |body| strip_root body, root }
      end
      carried_functions = carried_functions.map do |signature|
        rekey_body(iyi_module_name(root), signature, strip_root(signature, root)) { |body| strip_root body, root }
      end
      top_exported = top_exported.map do |signature|
        # The *signature* is stripped and the body is not, and that is the one
        # place the two differ. A top-level `def` is rendered outside the
        # module — that is what makes it top-level — so a name inside its body
        # has to be the one the module is known by from out there:
        # `Kemal::Utils` rather than `Utils`, which is nothing at that level.
        rekey_body(IyiMod::TOP_LEVEL_CONTAINER, signature, strip_root(signature, root)) { |body| body }
      end
      carried_types = carried_types.map { |declaration| strip_root_declaration declaration, root }
      root_class_vars = root_class_vars.map do |class_var|
        class_var.copy_with(type: strip_root(class_var.type, root),
          value: strip_root(class_var.value, root))
      end
    end

    # A name this shard declares itself is not somebody else's, whatever the
    # boundary beside it calls its own. `radix` declares `Node` at its top
    # level, so the map says `Node` → `Radix::Node` — and kemal has a
    # `LRUCache::Node` of its own, which came out as `Radix::Node(K, V)` and
    # stopped the consumer on `wrong number of type vars`.
    mine = Set(String).new
    carried_types.each { |declaration| collect_known declaration, "", mine }
    # By the simple name, because that is what the map is keyed on and what a
    # bare reference in this shard's own source means: `Node` inside `Kemal` is
    # `Kemal::LRUCache::Node`, whatever `radix` calls its own.
    mine.each { |name| @@bound_prefix.delete(name.split("::").last) }

    # And a reference to somebody else's boundary is written the way the
    # consumer will see it.
    unless @@bound_prefix.empty?
      exported = exported.map do |signature|
        rekey_body(iyi_module_name(root), signature, map_names(signature)) { |body| map_names body }
      end
      carried_functions = carried_functions.map do |signature|
        rekey_body(iyi_module_name(root), signature, map_names(signature)) { |body| map_names body }
      end
      top_exported = top_exported.map do |signature|
        rekey_body(IyiMod::TOP_LEVEL_CONTAINER, signature, map_names(signature)) { |body| map_names body }
      end
      reopened = reopened.map { |declaration| map_names_declaration declaration }
      carried_types = carried_types.map { |declaration| map_names_declaration declaration }
      root_class_vars = root_class_vars.map do |class_var|
        class_var.copy_with(type: map_names(class_var.type), value: map_names(class_var.value))
      end
    end

    # Last, once every name is written the way the consumer will read it: a
    # declaration inside a type refers to that type absolutely.
    # Last, once every name is written the way the consumer will read it.
    carried_types = carried_types.map { |declaration| qualify_self_references declaration, @@self_shadowed }

    # The files this boundary is written from, each with what it hashed to
    # (IV.3). Without them the artifact said nothing a staleness check could
    # read: `iyi_compute_artifact_stale` looks for the one file at the
    # module path, a bound shard has none, and the empty source hash was
    # taken to mean "cannot answer" — so every consumer read the boundary as
    # current however long ago the checkout had changed, compiled against
    # last week's surface and linked last week's object code. The artifact is
    # a cache and a cache that cannot go stale is a claim.
    inputs = bind_inputs(program)

    artifact = IyiMod::Artifact.new(
      module_name: iyi_module_name(root),
      # The shard's own constants, as the assignments that make them.
      #
      # A constant travels by *name* so that its initialiser runs once, in the
      # program that will read it — but a name is only half of it, and the half
      # a bound shard was missing. Its unit refers to `Store::TABLE` and defines
      # nothing; the consumer had the name from `Constants` and no way to make
      # one, so it said `undefined constant ::Store::TABLE` and stopped.
      #
      # The text goes in the initialiser, which the reader renders last and
      # inside the module — so `TABLE = [...]` under `module store` is
      # `Store::TABLE`, in the namespace the shard wrote it in, built by the
      # consumer's own program at the time III.5 says.
      initialiser: initialiser,
      source_path: program.filename || "",
      compiler_version: IyiMod.compiler_version,
      target_triple: program.codegen_target.to_s,
      flags: program.flags.to_a.sort!,
      imports: @@bound_used.to_a.sort.map { |name| IyiMod::ImportEdge.new(name) },
      mono_bodies: @@mono_bodies.dup,
      # The root's own macros, which are the module's surface as much as its
      # defs are: `Kemal.get`, `Kemal.post` and the rest of that DSL are
      # macros on the module itself. See `declared_macros`.
      macro_bodies: root_type.try { |type| declared_macros(type) } || [] of String,
      requires: crystal_requires(program),
      # The declarations carry no `module` header when the root is a class: the
      # class is the namespace, and a header of its own name would put it one
      # level inside itself.
      class_root: !module_root?(program, root),
      module_extends_self: extends_self?(program, root),
      # False until the *second* build puts object code in it. This is the one
      # path that can leave a boundary half-written: the declarations are on
      # disk before anything has been compiled against them.
      filled: false,
      exports: IyiMod::Exports.new(exported, carried_types, [] of IyiMod::ImplRecord,
        carried_functions, root_class_vars),
      # True, and it was false here on an argument that measurement has since
      # answered. The argument was that a boundary stands *between* Crystal's
      # library and the consumer, so what crosses is handles and primitives and
      # the consumer is an ordinary iyi program. What crosses is not: the unit
      # this artifact carries is compiled under Crystal's library and numbers
      # `Pointer(LibUnwind::Exception)` whatever the shard does, because a
      # `String#+` can raise. An iyi program cannot name that type, and telling
      # it the artifact is one of its own only moved the refusal later.
      crystal_library: true,
      top_level: top_exported,
      # And the shard's own top-level `fun`s, whose source the consumer
      # compiles: their machine code is in a main module, which never
      # travels. See `IyiMod::Artifact#top_level_funs`.
      top_level_funs: @@top_level_fun_sources,
      reopened: reopened,
      inputs: inputs,
    )

    # After construction, the way `Compiler#emit_iyi_artifacts` takes them:
    # the interface hash is over the exports the record now carries. The
    # source half is over `inputs`, which is this artifact's answer to "is the
    # module still the module".
    artifact.hashes = IyiMod.hashes_for(artifact, inputs.join('\n'))

    path = File.join(dir, "#{iyi_module_name(root).gsub('/', '-')}.iyimod")
    IyiMod.write artifact, path

    keep_path = File.join(dir, "#{iyi_module_name(root).gsub('/', '-')}_keep.cr")
    File.write keep_path, keep_file(program, root, signatures, types, accessors, dir)

    unless top_exported.empty?
      io.puts
      io.puts "top-level defs, outside every namespace: #{top_exported.size}"
      io.puts "  a `def` the shard writes outside its own namespace is on"
      io.puts "  `Object`, where a boundary rooted at #{root} cannot reach it."
      io.puts "  These travel in their own section and the consumer puts them"
      io.puts "  back where they were: at its top level."
      top_exported.each { |signature| io.puts "    #{signature.name}" }
    end

    io.puts
    carried = count_methods types
    unless @@handle_types.empty?
      io.puts
      io.puts "crossed as handles, without their fields: #{@@handle_types.size}"
      io.puts "  a reference is a pointer, so a consumer that never allocates"
      io.puts "  one does not need to know what is inside it. `new` is not"
      io.puts "  exported for these, which is what keeps that true."
      # Named, because which ones matters: a body that travels and touches a
      # field of one cannot be compiled by the consumer, and the failure comes
      # out as `can't infer the type of instance variable` in a file nobody
      # wrote. A count says three; a name says which three.
      @@handle_types.to_a.sort.each do |name|
        because = @@handle_reasons[name]?
        io.puts "    #{name}#{because ? " — #{because.join(", ")}" : ""}"
      end
    end

    unless module_root? program, root
      kind = program.types?.try(&.[]?(root)).try(&.instance_type.type_desc) || "type"
      io.puts
      io.puts "#{root} is a #{kind}, so it travels as a type declaration holding"
      io.puts "everything under it, rather than as module functions. Its constants"
      io.puts "stay behind: a constant crosses as a function, and that function"
      io.puts "takes its symbol from `extend self`, which only a module has."
    end

    unless @@skipped_enums.empty?
      io.puts
      io.puts "enums, which iyi does not have: #{@@skipped_enums.uniq!.sort!.join(", ")}"
      io.puts "  Nothing declares one on the far side, so a signature naming one"
      io.puts "  cannot cross and neither can a type holding one. This is what"
      io.puts "  `JSON` waits on, through `JSON::PullParser`."
    end

    unless @@nested_namespaces.empty?
      io.puts
      io.puts "namespaces skipped whole: #{@@nested_namespaces.uniq!.sort!.join(", ")}"
      io.puts "  what they hold has to travel as nested declarations."
    end

    unless @@opaque_types.empty?
      io.puts
      io.puts "left out, because their fields name what an iyi program cannot:"
      @@opaque_types.sort.first(12).each { |name| io.puts "  #{root}::#{name}" }
      if @@opaque_types.size > 12
        io.puts "  ... and #{@@opaque_types.size - 12} more"
      end
      io.puts
      io.puts "These are the per-type decisions a boundary is made of. A type"
      io.puts "the consumer only holds can cross as a handle; one it allocates"
      io.puts "needs its fields, and its fields need their types."
    end

    io.puts "wrote #{path}: #{signatures.size} module functions, " \
            "#{count_types types} types carrying #{carried} methods"
    io.puts "wrote #{keep_path}"
    io.puts
    unless round_trips? root
      seen_as = consumer_name root
      io.puts
      io.puts "#{root} cannot be linked against, and this is the place to say so."
      io.puts "  An iyi module path is lower-case groups joined by `_`, and a"
      io.puts "  consumer names the module by camelcasing it. That mapping's image"
      io.puts "  is names like `Greeter` and `MyGreeter`; `#{root}` is not in it — it"
      io.puts "  comes back as `#{seen_as}`. Both sides mangle alike, so the producer"
      io.puts "  emits `*#{root}@#{root}::...` while the consumer asks for"
      io.puts "  `*#{seen_as}@#{seen_as}::...`, and the linker is what finds out."
      io.puts
      io.puts "  The declarations below are still true and still worth counting."
      io.puts "  What cannot happen is the last of the four steps."
      io.puts
    end

    io.puts "The artifact carries declarations and no object code yet, because"
    io.puts "the code does not exist: Crystal compiles what a program uses, and a"
    io.puts "library nobody calls compiles to nothing. The keep file above is what"
    io.puts "calls it. Two commands finish the boundary:"
    io.puts
    io.puts "  crystal build --iyi-keep #{root} --emit-bind #{dir} -o keepbin #{keep_path}"
    io.puts "  iyi build --crystal --use-iyimod #{dir} -o app app.iyi"
    io.puts
    io.puts "An *ordinary* build on the first line, not `--emit obj`. Codegen"
    io.puts "splits a program into one object per type, and the ones #{root} owns"
    io.puts "carry no runtime; `--emit obj` merges them into a single object that"
    io.puts "carries the whole of Crystal's library with it. A program can have"
    io.puts "that library once — link the merged object into a consumer that has"
    io.puts "none and the shard's constants never initialise, link it into one"
    io.puts "that has it and every runtime global is defined twice. `--emit-bind`"
    io.puts "puts the per-type units in the artifact instead, and the consumer"
    io.puts "links what the artifact carries. No `nm` and no `objcopy`."
    io.puts
    io.puts "`--crystal` on the second line is not decoration either. This unit"
    io.puts "numbers `Pointer(LibUnwind::Exception)` whatever #{root} does, because"
    io.puts "a `String#+` can raise, and an iyi program cannot name that type."
    io.puts
    io.puts "A constant crosses as the assignment that makes it, so the consumer"
    io.puts "builds it in its own program at the time III.5 says. That is what a"
    io.puts "unit needs: it refers to `#{root}::SOMETHING` and defines nothing."
    io.puts "A constant the compiler folds never needed this; one built at run"
    io.puts "time did, and used to read as null and segfault."
    io.puts "One inside a type under #{root} crosses too, written `Inner::X = ...`,"
    io.puts "which defines rather than reopens wherever the namespace exists — and"
    io.puts "the declarations above this text are what make it exist."
    io.puts
    io.puts "`--iyi-keep` is not decoration: a getter whose body is one instance"
    io.puts "variable is inlined at every call site and emits no symbol, which"
    io.puts "is right for a whole program and wrong for code somebody else will"
    io.puts "call by name. The symbols are local until that `objcopy`, and"
    io.puts "global is what a consumer links against. Nothing here goes through"
    io.puts "a C ABI: the two sides are one compiler and mangle names alike."
  end

  # The way to a shard's objects, which is the thing a boundary was missing.
  #
  # A library hands out what it has through constants — `Config::INSTANCE`,
  # one handler apiece — and a constant is storage in the shard's own object
  # rather than something a declaration can name. A function is not: it crosses
  # like any other. So this writes one per constant, on the shard's own module,
  # and the artifact declares it.
  #
  # `Kemal::Config::INSTANCE` becomes `Kemal.config_instance`, which is a name
  # a consumer can guess from the constant's own.
  private def self.constant_accessors(program : Program, root : String,
                                      types : Array(IyiMod::TypeDecl)) : Array({IyiMod::Signature, String})
    known = Set(String).new
    types.each { |declaration| collect_known declaration, "#{root}::", known }

    accessors = [] of {IyiMod::Signature, String}
    root_type = program.types?.try &.[]?(root)
    return accessors unless root_type.is_a?(NamedType)

    collect_constants root_type, root, "", "", known, accessors, Set(String).new,
      library_root(program)
    accessors
  end

  # *prefix* is the accessor's, flattened with `_`; *path* is the constant's own,
  # written with `::`.
  #
  # Two of them and not one, because the first cannot be turned back into the
  # second. Reconstructing the path by reading `_` as `::` works until a type's
  # own name has an underscore in it: `class OpenSSL::GETS_BIO` came back as
  # `OpenSSL::GETS::BIO`, and the keep file named a constant no program has.
  #
  # *taken* is the accessor names already used. Flattening loses information —
  # `A_B::C` and `A::B_C` both read `a_b_c` — and two defs of one name is a
  # broken artifact rather than a missing accessor, so the second is dropped and
  # counted.
  private def self.collect_constants(owner : NamedType, root : String, prefix : String,
                                     path : String, known : Set(String),
                                     accessors : Array({IyiMod::Signature, String}),
                                     taken : Set(String), library : String?) : Nil
    owner.types?.try &.each do |name, type|
      # An accessor for the library's own constant is a method a consumer does
      # not need: it has the constant.
      next if library_type?(type, library)

      case type
      when Const
        # A private constant cannot be handed out: an accessor reads it, and
        # reading one from outside is what its own compiler refuses. It still
        # travels in the initialiser, because *defining* it is not *reading* it
        # and the object code refers to it either way.
        next if type.private?
        answer = type.value.type?
        next unless answer

        answer = global_name(answer.devirtualize.to_s, root)
        next unless nameable?(answer, root)
        # Only a type that travelled: a name under the shard's own namespace is
        # writable only if the artifact carries it.
        next unless answer == root || !answer.starts_with?("#{root}::") || known.includes?(answer)

        accessor = "#{prefix}#{name}".downcase
        constant = "#{root}::#{path}#{name}"

        unless taken.add?(accessor)
          @@flattened << constant
          next
        end

        accessors << {
          IyiMod::Signature.new(
            name: accessor,
            # A module function, and written as one. These are synthesised
            # here rather than read off the shard — a constant is storage and a
            # declaration can name a type but not a global somebody else's
            # object file holds — so nothing else says which side of the type
            # they are on. Written without it they were instance methods of the
            # module the moment the header stopped extending itself, and
            # `Kemal.config_instance` was `undefined method ... for
            # Kemal:Module`.
            receiver: "self",
            parameters: [] of String,
            block_parameter: "",
            return_type: answer,
            free_variables: [] of String,
            required: false,
          ),
          constant,
        }
      when NamedType
        next if type.is_a?(GenericType)
        # An enum's members are `Const`s and are not constants to hand out:
        # they travel with the enum, and an accessor for one names the enum
        # from outside — which for a private enum is what the shard's own
        # compiler refuses (`private constant ... referenced`).
        next if type.is_a?(EnumType)
        next if type.private?
        collect_constants type, root, "#{prefix}#{name}_", "#{path}#{name}::",
          known, accessors, taken, library
      end
    end
  end

  # The types the shard declares, with the methods that can be written down.
  #
  # A method on a type is where most of a shard's surface lives, and it is the
  # half that could not travel while an artifact carried module functions
  # alone. What a consumer needs is what `TypeDecl` already asks for: the name,
  # the kind, the fields — a consumer allocates the type and allocating needs
  # its size — and the signatures.
  #
  # Non-generic only. A generic's methods exist once per instantiation and have
  # no symbol a producer could have emitted, so they travel as bodies rather
  # than as declarations (IV.2), and that is a different piece of work.
  # The types whose fields name something an iyi program cannot, filled in by
  # `type_declarations` and reported beside the artifact it wrote.
  @@opaque_types = [] of String

  # The reference types that crossed without their fields: a consumer holds one
  # and calls through it, and never makes one.
  @@handle_types = [] of String

  # The names under the shard's namespace that belong to the *library*, not to
  # the shard.
  #
  # A shard that reopens `OpenSSL` shares the namespace with Crystal's own
  # `OpenSSL`, so a name starting `OpenSSL::` is not necessarily one this
  # artifact carries — and it does not have to be, because a consumer under
  # `--crystal` replays the requires and has it. `prune_dangling` asks whether
  # everything a declaration names travelled, and without this it read
  # `OpenSSL::BIO` as a dangling name: `GETS_BIO`'s `@bridge_bio` field was
  # dropped, and dropping every field of a class drops its `new` with them, so
  # a consumer could not build the type openssl_ext reads a PEM through.
  @@library_names = Set(String).new

  # The types that hold a constant of their own name, by simple name. See
  # `qualify_self_references`.
  @@self_shadowed = Set(String).new

  # The namespaces skipped whole, with whatever they hold.
  @@nested_namespaces = [] of String

  # And the enums, which are skipped for a different reason worth its own line.
  @@skipped_enums = [] of String

  private def self.type_declarations(program : Program, methods : Array(BindMethod),
                                     root : String) : Array(IyiMod::TypeDecl)
    by_owner = methods.group_by(&.owner)
    declarations = [] of IyiMod::TypeDecl

    root_type = program.types?.try &.[]?(root)
    return declarations unless root_type.is_a?(NamedType)

    if module_root? program, root
      collect_declarations root_type, by_owner, root, declarations
      prune_dangling declarations, "#{root}::", root
    else
      # A class root's own methods are its type's rather than module functions,
      # so it travels as one declaration holding everything under it. The names
      # inside are then already absolute — `IO`, `IO::Memory` — which is why the
      # prefix the pruner resolves against is empty here and `IO::` there.
      declaration = declaration_for root, root_type, by_owner, root
      declarations << declaration if declaration
      prune_dangling declarations, "", root
    end
  end

  # Nothing may name a type that did not travel.
  #
  # `nameable?` answers "could an iyi program write this name", and for a type
  # under the shard's own namespace it used to answer yes on the strength of
  # the name alone. That is true only if the type is *here*: `Kemal::Router`
  # holds an `Array(Kemal::Router::RouteDefinition)` and that record is a
  # struct whose fields name `HTTP::Server::Context`, so it stays behind and
  # the artifact named a constant nobody had. Repeated to a fixed point,
  # because dropping one type can strand the field that named it.
  private def self.prune_dangling(declarations : Array(IyiMod::TypeDecl),
                                  prefix : String, root : String) : Array(IyiMod::TypeDecl)
    loop do
      known = Set(String).new
      declarations.each { |declaration| collect_known declaration, prefix, known }

      pruned = [] of IyiMod::TypeDecl
      declarations.each do |declaration|
        kept = prune_declaration declaration, prefix, known, root
        pruned << kept if kept
      end

      break declarations if pruned.size == declarations.size &&
                            pruned.sum(&.methods.size) == declarations.sum(&.methods.size) &&
                            pruned.sum(&.fields.size) == declarations.sum(&.fields.size)
      declarations = pruned
    end
  end

  private def self.collect_known(declaration : IyiMod::TypeDecl, prefix : String,
                                 known : Set(String)) : Nil
    known << "#{prefix}#{declaration.name}"
    declaration.types.each do |nested|
      collect_known nested, "#{prefix}#{declaration.name}::", known
    end
  end

  # Whether this name is the library's rather than this artifact's to declare.
  #
  # A prefix match as well as an exact one: a library namespace is skipped
  # whole, so `OpenSSL::SSL` is what was recorded and `OpenSSL::SSL::Context`
  # is what a field names. Everything under a name the library owns is the
  # library's too.
  private def self.library_name?(name : String) : Bool
    return true if @@library_names.includes?(name)
    @@library_names.any? { |known| name.starts_with?("#{known}::") }
  end

  private def self.prune_declaration(declaration : IyiMod::TypeDecl, prefix : String,
                                     known : Set(String), root : String) : IyiMod::TypeDecl?
    resolvable = ->(text : String) do
      Rx.scan(text, BIND_TYPE_NAME).all? do |match|
        part = match[0].not_nil!
        next true if part == "class"
        # The module itself is always there: it is the thing being imported.
        # A parameter's text holds its *default* as well as its type, and
        # kemal writes `limit : Int32 = Kemal.config.max_request_body_size`;
        # asked whether `Kemal` is one of the carried types the answer was no
        # — the root is not a declaration inside itself — and the method was
        # pruned. It only ever needed to cross when the body calling it
        # travelled, which is how a private helper came to be missing:
        # `undefined method 'read_body_with_limit' for Kemal::ParamParser`.
        next true if part == root
        next true unless part.starts_with?("#{root}::")
        next true if library_name?(part)
        known.includes?(part)
      end
    end

    fields = declaration.fields.select { |(_, type_name, _)| resolvable.call(type_name) }
    if fields.size != declaration.fields.size
      # A struct is its fields, so one that cannot carry them cannot travel.
      return nil unless declaration.kind == "class"
      fields = [] of {String, String, String}
    end

    # A class variable whose type this boundary drops is one the consumer
    # cannot declare, and a declaration that does not resolve is a hard error
    # at import where the thing it replaces was an undefined symbol at link.
    # Dropped, like the fields above and for the same reason: better left
    # undefined than declared wrong. What it costs is named rather than hidden
    # — the symbol comes back, and it comes back with the type that could not
    # travel written next to it.
    class_vars = declaration.class_vars.select { |class_var| resolvable.call(class_var.type) }

    methods = declaration.methods.select do |signature|
      (signature.parameters + [signature.return_type]).all? { |text| resolvable.call(text) }
    end
    methods = methods.reject { |signature| signature.name == "new" } if fields.empty? && !declaration.fields.empty?

    # And an `include` of a module this boundary did not carry. The same rule
    # as everything above — nothing may name a type that did not travel — and
    # the same cost, named rather than hidden: the type is no longer the
    # module's, which is what the include was for. `ExceptionPage` includes an
    # `ExceptionPage::Helpers` the walk never reached, and a consumer reading
    # the include stopped on `undefined constant`.
    includes = declaration.includes.select { |name| resolvable.call(name) }

    nested = [] of IyiMod::TypeDecl
    declaration.types.each do |child|
      kept = prune_declaration child, "#{prefix}#{declaration.name}::", known, root
      nested << kept if kept
    end

    # `copy_with` rather than a fresh `TypeDecl`, and that is not a style
    # choice. Listing the fields means listing them *all*, and a field added to
    # the record later is one a rebuild written this way silently drops — an
    # alias lost its right-hand side that way once, an enum lost its members,
    # and a reopened `lib` lost every `fun` in it. `copy_with` names only what
    # changes, so what is added later travels without anybody remembering to
    # carry it.
    declaration.copy_with(
      fields: fields,
      methods: methods,
      types: nested,
      class_vars: class_vars,
      includes: includes,
    )
  end

  # One level, and then the level under it.
  #
  # A nested type is not a detail: `Kemal::Router` holds an
  # `Array(Kemal::Router::RouteDefinition)`, so a consumer that has the first
  # and not the second cannot read the field it was given. `TypeDecl` carries
  # nested declarations for exactly this, and a walk that stopped at the top
  # produced an artifact naming a constant nobody had.
  private def self.collect_declarations(owner_type : NamedType, by_owner, root : String,
                                        declarations : Array(IyiMod::TypeDecl),
                                        container : String = "") : Nil
    library = library_root(owner_type.program)
    owner_type.types?.try &.each do |name, type|
      # The library's own, when the shard reopened a namespace that has some.
      # A consumer under `--crystal` replays the requires and already has them;
      # declaring one a second time is `superclass mismatch for class
      # OpenSSL::SSL::Error`, an artifact and a `require` disagreeing about the
      # same name.
      if library_type?(type, library)
        @@library_names << type.to_s
        next
      end

      # The container half of a body's key: where this declaration sits in the
      # tree a consumer renders, which is what tells `Connection::Options`'
      # bodies from `Pool::Options`'.
      declaration = declaration_for name, type, by_owner, root,
        container.empty? ? name : "#{container}::#{name}"
      declarations << declaration if declaration
    end
  end

  # One type, as a declaration — or nil, for the several reasons one cannot be.
  #
  # Split out from the walk above because the root itself needs the same answer.
  # A shard's root is a module and its own methods travel as module functions;
  # a core type's root is a class, whose methods are its type's and have to
  # travel here.
  private def self.declaration_for(name : String, type : Type, by_owner,
                                   root : String,
                                   container : String = name) : IyiMod::TypeDecl?
    # An `alias` is a name for a type rather than a type, so it is not a
    # `ModuleType` and the test below drops it. It has to travel all the same:
    # a name is exactly what a body uses. `db` writes `alias Any =
    # Union(…)` — from a macro, over the list of types a driver can bind — and
    # `Statement#exec`'s body, which travels, says `Slice(Any).empty`. A
    # consumer said `undefined constant Any`.
    #
    # The right-hand side is what the alias *resolved to* rather than the text
    # it was written as, for the reason a field's type is: this file is read
    # where the shard was not, and `Union({{*TYPES}})` is a macro nobody can
    # run again.
    # An annotation is a declaration that only a *macro* reads, and the macros
    # travel now. `db` writes `annotation Field` beside `DB::Serializable`,
    # whose `included` hook walks every instance variable asking for
    # `@[DB::Field]`; a consumer that had the hook and not the annotation
    # stopped inside the expansion, in a file it never wrote: `undefined
    # constant ::DB::Field`. It carries nothing but its name, which is all an
    # annotation is.
    if type.is_a?(AnnotationType)
      return IyiMod::TypeDecl.new(
        name: name,
        kind: "annotation",
        type_parameters: [] of String,
        assoc_types: [] of String,
        supertraits: [] of String,
        fields: [] of {String, String, String},
        methods: [] of IyiMod::Signature,
        # `pub`, because the whole of its use is outside: an annotation is
        # written on a *consumer's* field and read by a macro that travelled.
        # Unmarked it is `DB does not export DB::Field`, R-2 refusing a name
        # the boundary carried for exactly this.
        visibility: "pub",
      )
    end

    if type.is_a?(AliasType)
      return IyiMod::TypeDecl.new(
        name: name,
        kind: "alias",
        type_parameters: [] of String,
        assoc_types: [] of String,
        supertraits: [] of String,
        fields: [] of {String, String, String},
        methods: [] of IyiMod::Signature,
        # No `pub`: iyi's `pub` takes a def, a class, a struct, a trait and an
        # enum. An alias arrives declared and unmarked, which is what it is
        # when the module is read from source.
        visibility: "",
        value: type.aliased_type.devirtualize.to_s,
      )
    end

    # A constant lives in the same table as a type — `Kemal::VERSION` is in
    # here — and asking one for its instance variables is how this found out.
    return nil unless type.is_a?(ModuleType)

    # A generic travels as a declaration *and* its bodies. Its methods exist
    # once per instantiation and the instantiations belong to whoever writes
    # them — a consumer that writes `Holder(Float64)` needs a method the
    # producer never made — so what crosses is the source, rendered back into
    # the declarations the consumer parses (IV.2, `MonoBodies`). Skipping them
    # is what left `Radix` with nothing to carry, and `Radix` is what `Kemal`
    # waits on.
    # A generic *module* too, and for the same reason one level down: what it
    # holds is not parameterised by holding. `db` writes `module
    # SessionMethods(Session, Stmt)` and puts `struct UnpreparedQuery(Session,
    # Stmt)` inside it; dropping the module dropped the struct, and the object
    # code numbers the struct — `"d_b" numbers
    # `DB::SessionMethods::UnpreparedQuery(DB::Connection, DB::Statement)`, and
    # this build cannot name it`.
    if type.is_a?(GenericClassType) || type.is_a?(GenericModuleType)
      return generic_declaration name, type, by_owner, root, container
    end
    return nil if type.is_a?(GenericType)
    # A private type travels *as private*, which is a different thing from
    # travelling and a different thing from being dropped.
    #
    # Dropped was the first answer and it is wrong for a reason only the linker
    # says: `JSON::PullParser` holds an `Array(ObjectStackKind)` and its object
    # code numbers `Pointer(ObjectStackKind)`, so the consumer has to be able to
    # *number* a type it must never be able to *write*. Declaring it without
    # `pub` gives exactly that — R-2b keeps the name unreachable, and the type id
    # the object file needs exists. What must not happen is the keep file naming
    # it, which is where dropping it came from: `private constant IO::Encoder
    # referenced`. `keep_type` skips these instead.
    private_type = type.private?

    # An enum travels as itself: its members and the integer it is written on.
    #
    # It was skipped once and reported as a "namespace skipped whole", on the
    # reasoning that iyi has no `enum` — which came from finding none in the
    # prelude and was wrong about the language, which takes one. `JSON` is what
    # this was costing: `JSON::PullParser` holds an `ObjectStackKind`.
    if type.is_a?(EnumType)
      return enum_declaration name, type, private_type
    end

    # A module travels as a namespace: the declarations under it and nothing
    # else it is not asked for.
    #
    # It was dropped whole before, reported as a "nested namespace skipped", and
    # what that cost only shows at a shard's scale. `Kemal::Exceptions` holds
    # four exception classes, each with **an object-code unit in the artifact**
    # — the units travelled and the declarations did not, so a consumer linked
    # 7 MB of machine code for classes it did not have. And a module is a type:
    # `Backtracer::Backtrace::Parser` is one, the object code numbers it, and a
    # consumer that cannot name it cannot number it.
    #
    # Without `pub`, because iyi's `pub` takes a def, a class, a struct, a trait
    # and an enum — not a module. That is not a gap here: what a namespace owes
    # is that the things *inside* it can be named, and each of those carries its
    # own visibility. The module arrives declared and unmarked, which is what it
    # is when the shard is read from source.
    if type.is_a?(NonGenericModuleType)
      nested = [] of IyiMod::TypeDecl
      collect_declarations type, by_owner, root, nested, container

      return IyiMod::TypeDecl.new(
        name: name,
        kind: type.type_desc,
        type_parameters: [] of String,
        assoc_types: [] of String,
        supertraits: [] of String,
        fields: [] of {String, String, String},
        methods: collect_signatures(type, container, by_owner, root).sort_by(&.name),
        visibility: "",
        types: nested,
        class_vars: declared_class_vars(type),
        macros: declared_macros(type),
        # What it includes, which a module has for the same reason a class
        # does and was the one place this did not ask. `Kemal` writes `module
        # HandlerInterface; include HTTP::Handler`, and every middleware in an
        # application includes *that*: without the edge the consumer's own
        # class was not an `HTTP::Handler`, and `Kemal.use(middleware)` — the
        # line that installs it — said so.
        includes: included_modules(type, root),
        # And whether it extends itself, because that is how its methods are
        # called: `Backtracer::Backtrace::Parser` writes `extend self` and the
        # shard says `Parser.parse(backtrace)`. See `TypeDecl#extends_self`.
        extends_self: extends_self?(type),
      )
    end

    unless type.is_a?(ClassType)
      @@nested_namespaces << name
      return nil
    end

    @@self_shadowed << name if type.types?.try(&.[]?(name)).is_a?(Const)

    begin
      signatures = collect_signatures(type, container, by_owner, root)

      fields = split_fields(type)

      # A field is not optional the way a method is. A consumer allocates the
      # type, and allocating needs its size, so a type whose fields name the
      # standard library cannot cross as a declaration at all — it can only
      # cross as a handle the consumer never allocates, which is a decision
      # somebody has to make per type rather than a gap a tool can close.
      # The *name* that fails rather than the whole field type: a field is
      # `Kemal::LRUCache(String, Radix::Result(Kemal::Route))` and the argument
      # is about one name inside it.
      foreign_fields = fields.flat_map do |(_, type_name, _)|
        Rx.scan(type_name, BIND_TYPE_NAME).compact_map do |match|
          part = match[0].not_nil!
          next if part == "class" || part == "_"
          nameable_name?(part, root) ? nil : part
        end
      end

      # A reference type is a pointer to the consumer, so it can cross without
      # its fields as long as the consumer never allocates one: it holds what
      # the shard handed it and calls methods through it. A struct cannot —
      # its size *is* its fields — so one whose fields name the standard
      # library stays behind.
      handle = !foreign_fields.empty?
      if handle
        unless type.is_a?(ClassType) && !type.struct?
          @@opaque_types << name
          return nil
        end

        fields = [] of {String, String, String}
        signatures.reject! { |signature| signature.name == "new" }
        @@handle_types << name
        # With the name that made it one. A type crossing without its fields is
        # a decision somebody may want to argue with, and "which field" is the
        # whole of the argument.
        @@handle_reasons[name] = foreign_fields.uniq.first(3)
      end

      nested = [] of IyiMod::TypeDecl
      collect_declarations type, by_owner, root, nested, container

      IyiMod::TypeDecl.new(
        name: name,
        # `abstract` is part of what the type *is*, not decoration: a consumer
        # that reads `def title` where the shard wrote `abstract def title`
        # inherits a method with no body, and one that reads `class` where the
        # shard wrote `abstract class` is refused the requirement outright —
        # `can't define abstract def on non-abstract class`.
        kind: type.abstract? ? "abstract #{type.type_desc}" : type.type_desc,
        type_parameters: [] of String,
        assoc_types: [] of String,
        supertraits: [] of String,
        fields: fields,
        # Stable, because two definitions of one signature are ordered and
        # `previous_def` is what reads that order. `sort_by` alone is not: ties
        # come out in whatever order the sort left them.
        methods: signatures.map_with_index { |signature, index| {signature, index} }
          .sort_by { |(signature, index)| {signature.name, index} }.map(&.[0]),
        visibility: private_type ? "private" : "pub",
        types: nested,
        # The defaulted fields go here, for the reason `split_fields` gives:
        # this is the triple that renders `name : type = value`.
        class_vars: declared_class_vars(type),
        macros: declared_macros(type),
        superclass: superclass_name(type, root),
        includes: included_modules(type, root),
        extends_self: extends_self?(type),
      )
    end
  end

  # A type's fields, split into the ones with a default and the ones without.
  #
  # A field the shard wrote `@total = [] of T` has a *default*, and the
  # declaration was carrying only its type — so a consumer allocated it null
  # and the first `@total.each` read through it: `Invalid memory access` inside
  # `DB::Pool(DB::Connection+)`'s own initialisation. `reopened_declaration`
  # has carried defaults since kemal's `@store` needed one; the shard's *own*
  # types never did.
  #
  # In place, because a field's position in this list is its position in the
  # type's layout and the module's own object code was compiled against that
  # layout. Carried at the end instead — which is where `class_vars` renders —
  # `DB::Pool(T)`'s `@factory` changed offset and db's own `Database#initialize`
  # wrote a proc where the consumer read an array.
  private def self.split_fields(type : Type) : Array({String, String, String})
    fields = [] of {String, String, String}
    return fields unless type.is_a?(InstanceVarContainer)

    defaults = {} of String => String
    if type.responds_to?(:instance_vars_initializers)
      type.instance_vars_initializers.try &.each do |initializer|
        defaults[initializer.name] = initializer.written
      end
    end

    type.instance_vars.each do |field, variable|
      # Devirtualised, for the reason `infer_return` gives: `IO+` is how a
      # virtual type prints and it is a fact about this build's dispatch
      # rather than a name anybody can write.
      written = variable.type?.try(&.devirtualize.to_s) || "?"
      fields << {field, written, defaults[field]? || ""}
    end

    fields
  end

  # A type's class variables, or none where the library declares them itself.
  #
  # A boundary rooted at the library's own namespace declares that namespace's
  # type whole — `Log` is a class of Crystal's, and `tool bind -e Log` writes
  # `pub class Log` with everything on it. A consumer replays `require "log"`
  # and has the real one, so the declaration reopens it, and a class variable
  # arrives *twice*: once from the library with the initialiser that runs, and
  # once from here. One of the two wins and the artifact's is not the one that
  # runs, so `Log.setup` reached a `@@builder` nobody had built —
  # `Invalid memory access` inside `Log::Builder#clear`.
  #
  # The same rule the constants beside them already take, one field over: a
  # consumer under `--crystal` has the library's, and saying it again is worse
  # than saying nothing. The name still travels in `ClassVars`, which is what
  # makes the *global* exist for the object code to refer to — that half was
  # never the library's to provide.
  private def self.declared_class_vars(type : Type) : Array(IyiMod::ClassVarDecl)
    return [] of IyiMod::ClassVarDecl if library_type?(type, library_root(type.program))
    collect_class_vars(type)
  end

  # The macros one type declares, as source.
  #
  # III.6 rule 4 said no macro crosses, and that was a statement about what
  # the format could carry rather than about what a boundary owes: an iyi
  # module's macros have travelled in `MacroBodies` and `TypeDecl#macros`
  # since modules had either, and a shard's were written as an empty list
  # here. What that cost is a real application: `Kemal::HandlerInterface`
  # offers `only` and `exclude` as macros, every middleware in a Kemal app
  # calls one, and against the boundary they were `undefined method 'only'`.
  #
  # A macro is source and the consumer expands it, so what it names has to
  # be reachable from where it lands - the same rule a travelling body
  # takes. One that names something the shard kept to itself fails at the
  # expansion, in the consumer's own file, which is where a macro's errors
  # are anyway.
  private def self.declared_macros(type : Type) : Array(String)
    sources = [] of String
    return sources if library_type?(type, library_root(type.program))

    type.metaclass.as?(ModuleType).try &.macros.try &.each_value do |overloads|
      overloads.each do |a_macro|
        next unless shard_wrote_macro?(a_macro)
        sources << a_macro.to_s
      end
    end

    # And the hooks, which are macros the compiler keeps in a second place.
    #
    # `macro included` is not in `macros` — a name nobody calls is stored by
    # the moment that fires it — and it is how a Crystal library hands a type
    # its whole surface: `include DB::Serializable` is what defines
    # `SubmissionStruct.new(rs)` and `from_rs`, so an application that
    # included it against the boundary got `Array(NoReturn)` out of a query
    # whose rows nothing knew how to make.
    #
    # `included` and `extended` only. The other two fire on a *declaration*,
    # and every declaration this artifact carries is read back and declared
    # again on the far side: `bindata` writes `macro inherited` defining six
    # constants, `asn1` subclasses it fifteen times, and the consumer
    # re-declaring those subclasses ran the hook over constants the artifact
    # had already written down — `already initialized constant
    # ASN1::BER::AFTER_DESERIALIZE`. What a consumer's own subclass needs from
    # them is real and is not this: it is the second half of a boundary that
    # can be inherited from, which nothing here claims yet.
    type.metaclass.as?(ModuleType).try &.hooks.try &.each do |hook|
      next unless hook.kind.included? || hook.kind.extended?
      next unless shard_wrote_macro?(hook.macro)
      sources << hook.macro.to_s
    end
    sources.sort!
  end

  # Where the macro was written, by the same test a `def` takes: a shard
  # reopening `Object` must not carry the library's macros with it.
  private def self.shard_wrote_macro?(a_macro) : Bool
    filename = written_in a_macro.location
    return false unless filename
    library = @@library
    return true if library.empty?
    !filename.starts_with?(library)
  end

  # A method has as many symbols as it has ways of being called, and this emits
  # one call for each of them.
  #
  # The mangled name carries the types at the *call site*, not the types in the
  # declaration. `JSON.parse(input : String | IO)` is one declaration and at
  # least three symbols: a consumer passing a string reaches
  # `*JSON::parse<String>:JSON::Any`, one passing an `IO` reaches `<IO+>`, and
  # one passing a variable of the declared union reaches `<(IO+ | String)>`.
  # Naming only the last is what this file did, so every consumer that passed a
  # plain string linked against nothing.
  #
  # The product of the parameters' shapes, which sounds worse than it measures:
  # a union parameter is about one in twenty — 7 of `IO`'s 103, 1 of `JSON`'s 53
  # — so two in one signature is rare and the product stays small. `KEEP_CALL_CAP`
  # is there for when it is not, and it says so rather than quietly emitting the
  # declared shape alone.
  KEEP_CALL_CAP = 16

  private def self.keep_call(io : IO, owner : String, target : String,
                             signature : IyiMod::Signature, counter : Int32) : Int32
    # An `abstract def` has nothing to emit and calling one is not a thing this
    # file can do: `t0.title` on a class with no subclass has no type, and the
    # compiler said so as `BUG: … has no type` from inside codegen rather than
    # as an error anybody could act on. What a consumer needs from an abstract
    # method is the *requirement*, which travels in the declaration.
    return counter if signature.required

    # Nor is a method whose block nobody annotated.
    #
    # The call below hands every block-taking method a block, because the symbol
    # is per block *type* — but writing one needs the block's arity, and `&`
    # says nothing about it. `block_shape` read the `&` itself as a single
    # input, so `Kemal::Router#namespace(path : String, &)` was called with one
    # block parameter where the method yields none, and the fill build stopped
    # on `too many block parameters (given 1, expected maximum 0)`.
    #
    # Guessing is not the answer, and neither is a shape: there is nothing here
    # to emit. A method whose block is unwritten has no single symbol at all —
    # that is exactly why its body travels — and the consumer compiles one per
    # block it writes, from the text in `MonoBodies`.
    if written = signature.block_parameter
      return counter if !written.empty? && !written.includes?(" : ")
    end

    # A parameter with no written type is not a call this file can make.
    #
    # Such a signature is here because its *body* travels: the method yields, so
    # its machine code is the consumer's and there is no symbol to keep alive.
    # Naming it anyway means synthesising an argument of a type nobody wrote,
    # and the parameter's own name is what stands where the type would —
    # `uninitialized args`, from a file nobody wrote, which takes the whole
    # artifact down at fill time.
    return counter if signature.parameters.any? { |parameter| !parameter.includes?(" : ") }

    # Nor a signature with a free variable, for the reason a splat is not: a
    # `forall` is one method per binding, and `uninitialized T` is not a value
    # — `T` is a name the method introduces and nothing else has.
    return counter unless signature.free_variables.empty?

    # Nor is a splat, for the reason directly above and one more.
    #
    # `*args` and `**options` are a family rather than a signature: what a
    # caller passes is a tuple made at the call site and the tuple is in the
    # symbol, so there is no single one to keep alive — the body travels
    # instead. A bare `*` is not even a parameter, it marks what follows as
    # named-only, and it reached this file as a type: `a52 = uninitialized *`.
    return counter if signature.parameters.any? &.starts_with?('*')

    # The type only. A parameter is written `tag : String = "none"` now that
    # defaults travel, and `uninitialized String = "none"` is not a thing —
    # `unexpected token: "="`, from a file nobody wrote.
    declared = signature.parameters.map do |parameter|
      parameter.split(" = ").first.split(" : ").last
    end
    # Nor a parameter that takes a *class*, for the reason a `forall` is not
    # here: `def read(type : DB::Mappable.class)` is one instantiation per
    # class the caller names, the classes are the consumer's, and the body is
    # what travels. What this file would stand up is the module itself —
    # `uninitialized DB::Mappable.class`, then a call on it — and the fill
    # build stopped where the source says it must: `undefined method 'new' for
    # DB::Mappable:Module`. The driver then dropped the method to get a build,
    # and an application mapping rows into structs lost the one overload that
    # does it.
    return counter if declared.any? do |type|
                        bare = type.lchop("::")
                        bare.ends_with?(".class") || bare == "Class"
                      end

    # Nor one whose type is an abstract struct: there is no value of it to
    # stand up. See `@@unwritable`.
    return counter if declared.any? do |type|
                        Rx.scan(type, BIND_TYPE_NAME).any? do |match|
                          @@unwritable.includes?((match[0] || "").lchop("::"))
                        end
                      end

    # Nor a parameter whose type holds an `_`.
    #
    # `_` is the *absence* of a type rather than a type: `OptionParser -> _` is
    # a proc whose output is whatever the proc returns, and it is written that
    # way because nobody wrote it. `uninitialized` of one is `can't use
    # underscore as generic type argument`, and the answer is the block guard's
    # answer — a signature nobody can name a value of is a signature whose body
    # travels, and there is no symbol here to keep alive.
    return counter if declared.any? do |type|
                        Rx.scan(type, BIND_TYPE_NAME).any? { |match| match[0] == "_" }
                      end

    # Which method the lines below belong to, for the one reader that needs it:
    # `iyi bind`, when the fill build stops inside one of them. The compiler's
    # error trace names this file and a line; the marker above that line names
    # the method, which is what goes in `<artifact>.drop`. See `@@drop`.
    io << "  # bind-drop: " << drop_key(owner, signature) << "\n"

    shapes = declared.map { |type| [type] + union_members(type) }

    combinations = shapes.reduce([[] of String]) do |carried, options|
      carried.flat_map { |prefix| options.map { |option| prefix + [option] } }
    end

    if combinations.size > KEEP_CALL_CAP
      @@capped << "#{target}.#{signature.name}"
      combinations = [declared]
    end

    combinations.each do |types|
      counter = keep_one_call(io, target, signature, types, counter)
    end
    counter
  end

  # Which field name made each handle type one. See `@@handle_types`.
  @@handle_reasons = {} of String => Array(String)

  # The signatures whose shapes outran the cap, reported beside the artifact.
  @@capped = [] of String

  # Constants whose accessor name was already taken by another constant. See
  # `collect_constants`: the accessor flattens a path with `_` and two paths can
  # flatten alike.
  @@flattened = [] of String

  # `(A | B)` as `["A", "B"]`, and anything else as `[]`. Split at the top level
  # only: `(Array(A | B) | C)` is two members, not three.
  private def self.union_members(type : String) : Array(String)
    body = type.strip
    return [] of String unless body.starts_with?('(') && body.ends_with?(')')
    body = body[1...-1]

    members = [] of String
    depth = 0
    current = String::Builder.new
    body.each_char do |char|
      case char
      when '(' then depth += 1; current << char
      when ')' then depth -= 1; current << char
      when '|'
        if depth.zero?
          members << current.to_s.strip
          current = String::Builder.new
        else
          current << char
        end
      else current << char
      end
    end
    members << current.to_s.strip
    members.size > 1 ? members.reject(&.empty?) : [] of String
  end

  private def self.keep_one_call(io : IO, target : String, signature : IyiMod::Signature,
                                 types : Array(String), counter : Int32) : Int32
    args = types.map do |type|
      name = "a#{counter}"
      counter += 1
      io << "  " << name << " = uninitialized " << type << "\n"
      name
    end
    # Each call in its own `begin`, and that is not decoration.
    #
    # A statement whose type is `NoReturn` ends the block it is in:
    # `CleanupTransformer` stops collecting at one, so *every call after it* is
    # discarded. A keep file is one long list of calls, and a shard has methods
    # that only raise — `DB::Database#checkout` on an `uninitialized` receiver
    # is one — so a single such method silently took the rest of the file with
    # it. `db` was carrying two symbols for `DB::Database` where this file
    # names eight, and the two it had came from db's own code rather than from
    # here.
    #
    # It went unseen because a shard usually reaches its own methods somewhere:
    # `Kemal::Config#host_binding` has a symbol because kemal's startup message
    # reads it, not because this file asked for it. What this file adds is
    # everything a shard does *not* call itself, which is most of what a
    # consumer calls.
    #
    # `rescue` rather than an ordering trick, because which methods raise is
    # not knowable from a signature — and the file is never run, so what it
    # rescues is nothing.
    io << "  begin\n    "
    io << target
    io << '.' unless target.empty?
    io << signature.name
    io << "(" << args.join(", ") << ")" unless args.empty?

    # A block-taking method is compiled per block *type*, and the type is in
    # the symbol: `twice<Int32, &Proc(Int32, Int32)>`. So one is emitted here
    # by passing a block of the annotated type, and every consumer that writes
    # a block of that type calls the same name.
    #
    # A block whose output is written `_` has no annotated type and no single
    # symbol — its method's *body* is what travels, and the consumer compiles
    # one per block it writes. It is called here all the same, because the
    # method's callees have to be emitted, and the block it is handed returns
    # `nil`: `uninitialized _` is not a thing, and what the block returns is
    # not what this call is for.
    unless signature.block_parameter.empty?
      shape = block_shape signature.block_parameter
      return counter unless shape
      inputs, output = shape
      names = inputs.map_with_index { |_, index| "b#{counter + index}" }
      counter += inputs.size
      io << " { "
      io << "|" << names.join(", ") << "| " unless names.empty?
      if output.empty? || output == "Nil" || output == "_"
        io << "nil"
      else
        io << "r#{counter} = uninitialized " << output << "; r#{counter}"
        counter += 1
      end
      io << " }"
    end

    io << "\n  rescue\n  end"

    io << "\n"
    counter
  end

  # `&block : Int32, String -> Bool` read as its inputs and its output.
  # What a block takes and answers, or nil when neither can be read.
  #
  # A proc type is rendered *canonically* - `&block : Proc(Pointer(Void),
  # Nil)`, not `Void* -> Nil` - and splitting that on commas counted the
  # output as a second input: `Gcry.add_finalizer(a43) { |b44, b45| nil }`
  # for a block of one, and the fill build stopped on `wrong number of
  # block parameters`. A name that is neither shape (an alias that did not
  # resolve) has no arity to read, and guessing one is what this file must
  # never do: the caller skips the method, whose body travels anyway.
  private def self.block_shape(written : String) : {Array(String), String}?
    restriction = written.split(" : ", 2).last.strip
    restriction = restriction[1..-2].strip if restriction.starts_with?('(') && restriction.ends_with?(')') && balanced?(restriction[1..-2])

    if restriction.starts_with?("Proc(") && restriction.ends_with?(')')
      parts = split_top_level(restriction[5..-2])
      return nil if parts.empty?
      return {parts[0...-1], parts.last}
    end

    at = top_level_arrow(restriction)
    return nil unless at
    head = restriction[0, at].strip
    tail = restriction[(at + 2)..].strip
    {split_top_level(head).reject(&.empty?), tail}
  end

  # Whether every bracket in *text* closes, so `(A, B)` can be unwrapped
  # while `(A) -> (B)` is left alone.
  private def self.balanced?(text : String) : Bool
    depth = 0
    text.each_char do |char|
      case char
      when '(', '[', '{' then depth += 1
      when ')', ']', '}' then depth -= 1
      end
      return false if depth < 0
    end
    depth.zero?
  end

  # Where the top-level `->` is, or nil: `Proc(A, B) -> C` has one and
  # `Array(Int32)` has none.
  private def self.top_level_arrow(text : String) : Int32?
    depth = 0
    index = 0
    while index < text.size
      case text[index]
      when '(', '[', '{' then depth += 1
      when ')', ']', '}' then depth -= 1
      when '-'
        return index if depth.zero? && text[index + 1]? == '>'
      end
      index += 1
    end
    nil
  end

  # `A, Proc(B, C), D` as three, not four.
  private def self.split_top_level(text : String) : Array(String)
    parts = [] of String
    depth = 0
    from = 0
    index = 0
    while index < text.size
      case text[index]
      when '(', '[', '{' then depth += 1
      when ')', ']', '}' then depth -= 1
      when ','
        if depth.zero?
          parts << text[from...index].strip
          from = index + 1
        end
      end
      index += 1
    end
    parts << text[from..].strip
    parts.reject(&.empty?)
  end

  # A file that calls everything and is never called.
  #
  # Codegen is demand-driven, which is right for a program and wrong for a
  # library: the shard's own build emits only what its own code reaches, so a
  # method a *consumer* will call is in no object file at all. Naming them here
  # is what puts them there.
  private def self.keep_file(program : Program, root : String,
                             signatures : Array(IyiMod::Signature),
                             types : Array(IyiMod::TypeDecl),
                             accessors : Array({IyiMod::Signature, String}),
                             dir : String) : String
    # Relative, and written from where this file will sit: Crystal refuses an
    # absolute path in a `require`, and the shard is not on `IYI_PATH`.
    #
    # POSIX-form, because the next thing that happens to this path is that it
    # is read back out of a double-quoted string in a `.cr` file. On Windows
    # `relative_to?` answers `..\entry.cr`, and `\a` and `\e` are escapes
    # there, so the fill build went looking for a file called `..try.cr`.
    # `require` resolves `/` on every platform Crystal builds on.
    source = ::Path[File.expand_path(program.filename || "")]
    base = ::Path[File.expand_path(dir)]
    relative = source.relative_to?(base).try(&.to_posix.to_s) || source.to_posix.to_s
    relative = "./#{relative}" unless relative.starts_with?(".")

    String.build do |io|
      io << "# Written by `crystal tool bind`. Never called, and never edited:\n"
      io << "# it exists so that codegen emits the methods a consumer will call.\n"
      io << "require \"" << relative << "\"\n\n"
      unless accessors.empty?
        io << "# One function per constant the shard hands its objects out\n"
        io << "# through. A constant is storage; a function crosses.\n"
        io << "#\n"
        io << "# `def self.`, because that is how the declaration is written and\n"
        io << "# the two have to agree on the symbol: one spelling is\n"
        io << "# `Kemal@Kemal::x`, the other `Kemal::x`. It was `extend self`\n"
        io << "# here while an iyi module header supplied one on the far side;\n"
        io << "# now the header supplies it only where the shard wrote it, so\n"
        io << "# these say for themselves which side of the type they are on.\n"
        io << "module " << root << "\n"
        accessors.each do |(signature, constant)|
          io << "  def self." << signature.name << " : " << signature.return_type << "\n"
          io << "    " << constant << "\n"
          io << "  end\n"
        end
        io << "end\n\n"
      end

      io << "fun __bind_keep : Nil\n"
      counter = 0
      # A module's own instance methods are declared here as the module's, and
      # an iyi module header is `extend self`, so a consumer reads them on the
      # module *and* on whatever includes it. That is what an including type
      # needs and it is not a claim about the shard: `module Random` writes
      # `def new_seed` without `self.`, and `Random` answers to no such name.
      # Called in the keep file — which is compiled against the shard's own
      # source — it stopped the fill build on `undefined method 'new_seed' for
      # Random:Module`.
      #
      # So the call is skipped where the module does not extend itself. Nothing
      # is lost by skipping it: a module's method is compiled once per
      # including type, so there is no single symbol for the producer to emit
      # and the body travels instead (IV.1g, and `iyi_artifact_self_type`).
      extended = extends_self? program, root
      signatures.each do |signature|
        next if !extended && signature.receiver.empty?
        counter = keep_call(io, root, root, signature, counter)
      end
      accessors.each do |(signature, _)|
        io << "  # bind-drop: -\n"
        io << "  " << root << "." << signature.name << "\n"
      end
      prefix = module_root?(program, root) ? "#{root}::" : ""
      types.each do |declaration|
        counter = keep_type io, prefix, declaration, counter
      end
      io << "end\n"
    end
  end

  # The name one method is left out by. See `@@drop`.
  #
  # The owner is spelled as the *producer* writes it, because that is the
  # spelling the keep file's marker carries and the keep file is compiled
  # against the shard's own source.
  private def self.drop_key(owner : String, signature : IyiMod::Signature) : String
    "#{owner}#{signature.receiver.empty? ? "#" : "."}#{signature.name}" \
    "(#{signature.parameters.join(", ")})#{signature.block_parameter}"
  end

  # *declaration* without the methods `<artifact>.drop` names, through the
  # types under it: a nested type's methods are called by the keep file too.
  private def self.drop_methods(declaration : IyiMod::TypeDecl, prefix : String) : IyiMod::TypeDecl
    qualified = "#{prefix}#{declaration.name}"
    kept = declaration.methods.reject { |signature| @@drop.includes? drop_key(qualified, signature) }
    nested = declaration.types.map { |type| drop_methods type, "#{qualified}::" }
    declaration.copy_with(methods: kept, types: nested)
  end

  # The keys in `<artifact>.drop`, if a previous run left one beside the
  # artifact. Blank lines and `#` comments are a person's, and ignored.
  private def self.drop_list(dir : String, root : String) : Set(String)
    keys = Set(String).new
    path = File.join(dir, "#{iyi_module_name(root).gsub('/', '-')}.drop")
    return keys unless File.file?(path)
    File.each_line(path) do |line|
      key = line.strip
      keys << key unless key.empty? || key.starts_with?('#')
    end
    keys
  end

  # Whether the root is a module, which decides what of its own can travel.
  # Whether this module writes `extend self`, so that its own methods answer on
  # the module as well as on whatever includes it. See `write_artifact`.
  private def self.extends_self?(program : Program, root : String) : Bool
    type = program.types?.try &.[]?(root)
    return false unless type
    instance = type.instance_type
    metaclass = instance.metaclass
    return false unless metaclass.responds_to?(:ancestors)
    metaclass.ancestors.includes?(instance)
  end

  private def self.module_root?(program : Program, root : String) : Bool
    type = program.types?.try &.[]?(root)
    return false unless type
    type.instance_type.is_a?(NonGenericModuleType) || type.instance_type.is_a?(GenericModuleType)
  end

  # Every method on a declaration, and on the declarations under it.
  #
  # The walk used to stop at the top, which was invisible while the only
  # declarations were a shard's nested types and their methods went unemitted
  # quietly. A class root puts everything one level down, so stopping at the top
  # would have kept nothing at all.
  private def self.keep_type(io : IO, prefix : String,
                             declaration : IyiMod::TypeDecl, counter : Int32) : Int32
    # A private one is in the artifact so the consumer can number it, and naming
    # it here is what the shard's own compiler refuses: `private constant
    # IO::Encoder referenced`.
    return counter if declaration.visibility == "private"

    # A `lib` has nothing to keep alive and nothing to name. Its funs are C
    # symbols the system linker resolves, its types are `type` aliases and
    # structs with no methods, and `uninitialized SQLite3::LibSQLite3` is not a
    # value: `undefined constant`, from a file nobody wrote.
    return counter if declaration.kind == "lib"

    # Nor an annotation, for the plainest reason on this list: it is not a
    # type a value can have. It travels because a travelling macro reads it —
    # `DB::Serializable`'s hook asks every field for `@[DB::Field]` — and
    # `uninitialized DB::Field` is `BUG: called create_llvm_type for
    # DB::Field`, the fill build dying inside codegen.
    return counter if declaration.kind == "annotation"

    qualified = "#{prefix}#{declaration.name}"

    # A generic has no machine code of its own to keep: its methods exist once
    # per instantiation, the instantiations are the consumer's, and what
    # travels is their source. `uninitialized Holder(T)` is not a thing anybody
    # can write, which is what this file found out.
    #
    # **What it declares is another matter, and skipping that with it was the
    # bug.** `Radix::Tree(T)` holds two non-generic error classes; each has a
    # unit in the artifact and neither was ever named here, so radix's keep
    # file was empty and the only `to_s` symbols it emitted were the ones its
    # own code happened to reach — `to_s<IO::Memory>` and
    # `to_s<IO::FileDescriptor>` — while the boundary declared `io : IO` and a
    # consumer asked for `to_s<IO+>`. A nested type is not parameterised by its
    # container unless it says so, so `Radix::Tree::DuplicateError` is a name
    # anybody can write.
    if declaration.type_parameters.empty?
      receiver = "t#{counter}"
      counter += 1
      # `-`: standing a value of the type up belongs to no one method, so
      # there is nothing here for `<artifact>.drop` to leave out. A fill build
      # that stops on one of these lines is a type the keep file cannot name a
      # value of, which is this file's bug rather than the shard's.
      io << "  # bind-drop: -\n"
      io << "  " << receiver << " = uninitialized " << qualified << "\n"

      # And the class side, through a *value* of the metaclass rather than
      # through the class's name.
      #
      # The name is the concrete metaclass and a value of it is the virtual
      # one, and which of the two a call has is in the symbol: `BinData::
      # VerificationException.to_s(io)` emits `*BinData::VerificationException::
      # to_s<IO+>` where a consumer holding the class asks for `*BinData::
      # VerificationException+@BinData::VerificationException::to_s<IO+>`. A
      # consumer holds it virtually because that is what holding a class in a
      # variable is — `io << exception.class`, through `Exception+.class` — and
      # `iyi_artifact_self_type` writes the virtual form for exactly that
      # reason. So this file has to emit the form that is asked for.
      #
      # `uninitialized T.class` is how a value of a metaclass is named. For a
      # class nothing inherits from the two forms are the same type and this
      # reads as a no-op, which is why it took a shard with an exception
      # hierarchy to find it.
      metaclass = "c#{counter}"
      counter += 1
      io << "  " << metaclass << " = uninitialized " << qualified << ".class\n"

      # The path `MonoBodies` is keyed on, which is this declaration's own —
      # written relative to the module, where the calls below are written from
      # the top level.
      relative_container = @@root.empty? ? qualified : qualified.lchop("#{@@root}::")
      ordinals = {} of String => Int32

      declaration.methods.each do |signature|
        # `initialize` is not called here. It is in the declarations only where
        # `new` could not travel — a block-taking one — and then its body
        # travels with it and the consumer compiles both. Naming it in this file
        # is `protected method 'initialize' called`, which is Crystal's own
        # compiler saying the same thing: `new` is how you build one.
        next if signature.name == "initialize"

        # Not `initialize`: Crystal refuses that call from outside the type —
        # `protected method 'initialize' called` — and `new` is how you build
        # one. A generic is not kept here at all, so its `initialize` is nobody's
        # to call from this file.
        next if signature.name == "initialize"
        # Nor a private one, for the same reason and one more: its parameters
        # travel as the source wrote them, so there is not always a type to say
        # `uninitialized` of. Its symbol is in the unit already — whatever
        # travelling body calls it is what emitted it.
        next if signature.visibility == "private"

        # A method whose body travels is not called here, and this is the
        # general form of the four shapes above it.
        #
        # There is no symbol to keep alive: the consumer compiles the body
        # where it stands (IV.1g). Worse than useless, the call is a claim
        # this build cannot make — `Quartz::Composer#deliver` calls `sender`,
        # which every mailer defines and the shard itself never does, and
        # `db`'s `read(type : DB::Mappable.class)` wants a class no shard has.
        # Both are methods a *consumer* completes, and standing one up here
        # stopped the fill build on the shard's own source.
        travelling = @@travelling.includes?(
          IyiMod.mono_body_key(relative_container, signature, ordinals[IyiMod.mono_body_key("", signature)]? || 0))
        ordinals[IyiMod.mono_body_key("", signature)] =
          (ordinals[IyiMod.mono_body_key("", signature)]? || 0) + 1
        next if travelling

        # `new` through the class's *name*, and everything else on the class
        # side through the metaclass value.
        #
        # A virtual metaclass dispatches `new` to every subclass, and a
        # subclass builds itself its own way: `Shard::Derived#initialize` takes
        # two arguments where its base takes one, and `bench/bind_roundtrip.sh`
        # said `wrong number of arguments (given 1, expected 2)`. A consumer
        # calling `new` names the class it wants, so the symbol it asks for is
        # the one this spelling emits.
        target =
          if signature.receiver.empty?
            receiver
          elsif signature.name == "new"
            qualified
          else
            metaclass
          end
        counter = keep_call(io, qualified, target, signature, counter)
      end
    end

    declaration.types.each do |nested|
      counter = keep_type io, "#{qualified}::", nested, counter
    end
    counter
  end

  # Both counted through the nesting, because a class root puts every type it
  # carries one level down and a count that stopped at the top read as one.
  private def self.count_types(declarations : Array(IyiMod::TypeDecl)) : Int32
    declarations.sum { |declaration| 1 + count_types(declaration.types) }
  end

  private def self.count_methods(declarations : Array(IyiMod::TypeDecl)) : Int32
    declarations.sum { |declaration| declaration.methods.size + count_methods(declaration.types) }
  end

  # Every type the boundaries in *dir* declare, so this run can name them.
  #
  # A class root's declarations are absolute — `IO`, then `IO::Memory` under it
  # — and a module root's are relative to a name the file does not record. So
  # each is checked against the program rather than trusted: that keeps the
  # first and drops the second, instead of admitting a bare `Any` as though
  # somebody had declared it. What is dropped is counted and printed, because a
  # boundary silently contributing nothing is the failure worth seeing.
  private def self.bound_names(program : Program, dir : String, io : IO) : Set(String)
    names = Set(String).new
    paths = Dir.glob(::Path[dir].to_posix.join("*.iyimod")).sort
    return names if paths.empty?

    io.puts "boundaries already written:"
    paths.each do |path|
      begin
        artifact = IyiMod.read path
      rescue ex
        io.puts "  #{File.basename(path)}: unreadable — #{ex.message}"
        next
      end

      found = Set(String).new
      artifact.exports.types.each { |declaration| collect_known declaration, "", found }

      # The consumer reaches an imported module by the camelcase of its path,
      # which is the mapping IV.6 #6 keeps reversible. Only the top-level names
      # are recorded: everything under one is reached through it, so prefixing
      # `IO` carries `IO::Memory` with it.
      # Empty for a **class root**, whose declarations carry no module header at
      # all: the class is the namespace, so the consumer names its types
      # exactly as the artifact declares them. Prefixing anyway rewrote
      # `Carrier` to `Carrier::Carrier` in a boundary that named it.
      prefix = artifact.class_root ? "" : artifact.module_name.split('/').map(&.camelcase).join("::")

      # Asked under the root as well as bare, because whether a name needs the
      # root depends on what the root *is*.
      #
      # `-e ExceptionPage` is a class, so the artifact declares
      # `ExceptionPage` and the program has a type by that name. `-e Radix` is
      # a module, so its members are declared at the artifact's own top level —
      # `Node`, `Tree`, `Result` — and the program has no top-level `Node`. It
      # has `Radix::Node`. Asking only the bare name answered "0 of 6 this
      # program can name" for `Radix`, and `Kemal`, which names
      # `Radix::Tree` eight times, went on waiting on a boundary sitting in the
      # same directory.
      qualify = ->(name : String) { prefix.empty? ? name : "#{prefix}::#{name}" }

      kept = found.select do |name|
        declared_type?(program, name) || declared_type?(program, qualify.call(name))
      end
      # A name Crystal's own library declares is Crystal's, and no boundary
      # takes that spelling. `kilt` is a module root, so `Kilt::Exception` is
      # declared in its artifact as `Exception` — and adopting the bare name
      # rewrote `class Error < Exception` in *every shard bound after it* to
      # `class Error < Kilt::Exception`, which is a different type, in a
      # module the shard does not use. It travelled as an import edge too, so
      # a program that wanted `jwt` was handed `kilt`, `p_g` and nine more,
      # and stopped on the first of them that could not be named.
      #
      # The qualified name is recorded either way: what a consumer writes for
      # that type is `Kilt::Exception`, and that is what it can name.
      bare = kept.reject do |name|
        @@crystal_types.includes?(name) || @@builtin.includes?(name) ||
          # Nor a name *this* shard declares. A module root's declarations are
          # written with the root stripped, so `JWT::Error` and
          # `Validator::Error` are both `Error` here - and jwt's own text,
          # stripped the same way, came out saying `Validator::Error` for the
          # class beside it. A bare name a shard declares itself is the
          # shard's own, and its own types travel with it.
          name == @@root || declared_type?(program, "#{@@root}::#{name}")
      end
      names.concat bare
      # Under the root as well, because that is how the *producer* writes them.
      # `Radix` declares `Tree` and `Kemal` says `Radix::Tree`, so recording
      # only the bare name left every one of those eight signatures waiting on
      # a boundary that was carrying the type.
      kept.each { |name| names << qualify.call(name) }
      artifact.exports.types.each do |declaration|
        next unless bare.includes? declaration.name
        @@bound_prefix[declaration.name] = qualify.call(declaration.name)
        @@bound_module[declaration.name] = artifact.module_name
      end
      io.puts "  %-24s %d types, %d this program can name" % [File.basename(path), found.size, kept.size]
    end
    io.puts
    names
  end

  # Whether the program really has a type by this qualified name.
  # Every type the shard declares, qualified, gathered once. See
  # `nameable_name?`, which asks this of a bare name a restriction wrote.
  private def self.declared_names(program : Program, root : String) : Set(String)
    names = Set(String).new
    collect_declared_names program.types?, root, names
    names
  end

  private def self.collect_declared_names(table, root : String, names : Set(String)) : Nil
    table.try &.each_value do |type|
      next unless type.is_a?(NamedType)
      name = type.to_s
      # Without its parameters, which is how a restriction writes one:
      # `Radix::Tree(T)` prints its own, and `result : Result` names the type
      # rather than an instantiation of it.
      name = name[0...name.index('(')] if name.includes?('(')
      next unless name == root || name.starts_with?("#{root}::")
      names << name
      collect_declared_names type.types?, root, names
    end
  end

  private def self.declared_type?(program : Program, qualified : String) : Bool
    table = program.types?
    qualified.split("::").each do |part|
      return false unless table
      found = table[part]?
      return false unless found
      table = found.as?(NamedType).try(&.types?)
    end
    true
  end

  # iyi: the two patterns below were `gsub` with negative lookbehind, and this
  # comment used to say that lookbehind was the one thing this tree's own engine
  # would never do. That is no longer true: `Iyi::Rx` answers both senses of both
  # directions, at any length, so the capability is not the reason any more.
  #
  # They stay written by hand because of cost, not capability. A name boundary is
  # two byte comparisons at a known offset. The same question asked of the engine
  # compiles a program, sweeps a bitmap across the whole text once per assertion,
  # then runs the VM, and every one of those steps is paid on every declaration
  # the tool renames. Reaching for the stdlib `Regex` instead is the other way to
  # lose: it puts `libpcre2-8` back on the compiler's link line, which
  # `bench/dependency_floor.sh` forbids by name.
  #
  # So they read the way `process/shell.cr`, `option_parser.cr` and
  # `semantic_version.cr` read, for the same reason: by hand, over bytes. Both are
  # boundary tests, which is the part a pattern was doing and the part plain code
  # says more plainly.
  #
  # A name boundary here is ASCII: the characters that can continue an
  # identifier are `[A-Za-z0-9_]`, and `:` joins a namespace. Bytes rather than
  # chars because every byte of a multi-byte character is >= 0x80 and so is
  # never one of them.
  private def self.identifier_byte?(byte : UInt8) : Bool
    byte === 0x5F_u8 ||                       # _
      (byte >= 0x30_u8 && byte <= 0x39_u8) || # 0-9
      (byte >= 0x41_u8 && byte <= 0x5A_u8) || # A-Z
      (byte >= 0x61_u8 && byte <= 0x7A_u8)    # a-z
  end

  # True when the byte before *index* could continue a name, so a match there is
  # inside a longer one. `:` counts, which is what keeps `Other::MyLib::Entry`
  # from being read as a `MyLib::` of its own.
  private def self.after_name_byte?(text : String, index : Int32) : Bool
    return false if index == 0
    before = text.to_unsafe[index - 1]
    before === 0x3A_u8 || identifier_byte?(before) # :
  end

  # Every place *needle* appears in *text* on a name boundary, replaced by what
  # *replacement_for* answers. `nil` from the block leaves the occurrence alone.
  private def self.replace_on_boundary(text : String, needle : String,
                                       trailing_name_ends : Bool, & : -> String) : String
    return text if needle.empty? || !text.includes?(needle)

    result = String::Builder.new(text.bytesize)
    index = 0
    while index < text.bytesize
      if text.byte_index(needle, index) == index && !after_name_byte?(text, index)
        after = index + needle.bytesize
        ends_name = !trailing_name_ends ||
                    after >= text.bytesize ||
                    !identifier_byte?(text.to_unsafe[after])
        if ends_name
          result << yield
          index = after
          next
        end
      end
      result.write_byte text.to_unsafe[index]
      index += 1
    end
    result.to_s
  end

  # `MyLib::Entry` becomes `Entry`, and `MyLibOther::X` is left alone — the
  # prefix has to end at a name boundary or this renames types it never owned.
  private def self.strip_root(text : String, root : String) : String
    replace_on_boundary(text, "#{root}::", trailing_name_ends: false) { "" }
  end

  private def self.strip_root(signature : IyiMod::Signature, root : String) : IyiMod::Signature
    IyiMod::Signature.new(
      name: signature.name,
      receiver: signature.receiver,
      parameters: signature.parameters.map { |parameter| strip_root parameter, root },
      block_parameter: strip_root(signature.block_parameter, root),
      return_type: strip_root(signature.return_type, root),
      free_variables: signature.free_variables,
      required: signature.required,
    )
  end

  # *path* is the container half of a body's key — see
  # `IyiMod.render_type_declaration`. It defaults to the declaration's own
  # name, which is what a top-level one has.
  private def self.strip_root_declaration(declaration : IyiMod::TypeDecl,
                                          root : String,
                                          path : String = declaration.name) : IyiMod::TypeDecl
    # A name is read from where it is written, and everything below is written
    # *inside* this declaration: its fields, its methods, its bodies, its class
    # variables and its `fun`s are all rendered between `class X` and its `end`.
    # So the type's own name comes off them too, deepest first.
    #
    # It reads as a no-op for every public name — `Kemal::Config` written from
    # inside `ParamParser` resolves either way, because the first item of a path
    # is searched in the enclosing namespaces — and it is not one for a private
    # nested type. `private class ParamParser::LimitedBodyIO` is found only as
    # the *first* item of a path (`lookup_path_item`'s `include_private`), so
    # `ParamParser::LimitedBodyIO` is refused where `LimitedBodyIO` is the name
    # the shard itself wrote. It took a body that had just started to travel to
    # reach it: `private constant Kemal::ParamParser::LimitedBodyIO referenced`,
    # on a declaration whose own class declares it (SPEC.md III.6).
    #
    # The header line is not inside it. A superclass, an `include` and an
    # `alias`'s value are read in the enclosing scope, so they keep the root's.
    inside = "#{root}::#{declaration.name}"
    scoped = ->(text : String) { strip_root(strip_root(text, inside), root) }

    # `copy_with`, for the reason `prune_declaration` gives.
    declaration.copy_with(
      fields: declaration.fields.map { |(name, type, value)| {name, scoped.call(type), scoped.call(value)} },
      # `map_with_index` over the ordinals, because two definitions of one
      # signature are two bodies and each has to move to its own new key. The
      # pruner does not need the same care: it filters on the signature's text,
      # and two identical signatures are kept or dropped together.
      methods: begin
        ordinals = IyiMod.mono_body_ordinals(declaration.methods)
        declaration.methods.map_with_index do |signature, index|
          rekey_body(path, signature, strip_root(strip_root(signature, inside), root), ordinals[index]) do |body|
            scoped.call body
          end
        end
      end,
      # Deeper for what is inside it, because a name is read from where it is
      # written. `OpenSSL::PKey::PKeyError` stripped of the root is
      # `PKey::PKeyError`, and that declaration is rendered *inside*
      # `module PKey` — where it means `PKey::PKey::PKeyError` and resolves to
      # nothing. From in there the name is `PKeyError`.
      types: declaration.types.map do |nested|
        strip_root_declaration nested, "#{root}::#{declaration.name}", "#{path}::#{nested.name}"
      end,
      value: strip_root(declaration.value, root),
      # The value as well as the type. It is an expression that names types —
      # `@@config = Config.new` — and it is rendered inside the module the same
      # way an alias's right-hand side is.
      class_vars: declaration.class_vars.map do |class_var|
        class_var.copy_with(type: scoped.call(class_var.type),
          value: scoped.call(class_var.value))
      end,
      superclass: strip_root(declaration.superclass, root),
      includes: declaration.includes.map { |name| strip_root(name, root) },
      # A `fun` line is text and the types in it are the shard's like any
      # other: `fun open_v2 = sqlite3_open_v2(… flags : SQLite3::Flag …)` is
      # `flags : Flag` once the declaration is inside the module.
      funs: declaration.funs.map { |source| scoped.call(source) },
    )
  end

  # The text a body travels as, which for an empty method is `nil`.
  #
  # `def backtracer : Backtracer::Configuration?` with nothing in it is a hook
  # a subclass overrides, and the format cannot carry it as written: the
  # declaration renders `def backtracer\nend`, which is exactly how a *header*
  # is written, and `IyiMod::DeclarationMarker` reads a `Nop` body as a method
  # somebody else compiled. The consumer then promises a symbol the producer
  # never emitted, because a travelling method is left out of the keep file —
  # `undefined symbol: *ExceptionPage+@ExceptionPage#backtracer:Nil`,
  # referenced by the consumer's own copy of the `initialize` that calls it.
  #
  # `nil` is the same method: an empty body answers `nil`, and the declaration
  # already says `Nil`. What changes is that a parser can see it.
  private def self.travelling_body(body : String) : String
    body.blank? ? "nil" : body
  end

  # A body is found again by its signature, so rewriting one moves the other.
  #
  # `MonoBodies` is keyed on the container and the signature as written, and a
  # declaration's signatures are rewritten twice on the way out — stripped of
  # the root, then mapped to what a consumer calls another boundary's types. A
  # key left behind is a body nobody finds: the declaration arrives without one,
  # the consumer reads it as a method somebody else compiled, and the link ends
  # on `undefined symbol: *Radix::Tree(Kemal::Route)@Radix::Tree(T)#add<…>`.
  private def self.rekey_body(container : String, before : IyiMod::Signature,
                              after : IyiMod::Signature,
                              ordinal : Int32 = 0,
                              & : String -> String) : IyiMod::Signature
    old_key = IyiMod.mono_body_key(container, before, ordinal)
    new_key = IyiMod.mono_body_key(container, after, ordinal)

    # The body's *text* takes the same rewrite its signature does, and it was
    # not taking it. A body is the module's own code and names things the way
    # the module wrote them — `SQLite3::TIME_ZONE`, absolute — and the
    # declarations are read inside a module where the root has been stripped,
    # so that path is the module's *public* name and R-2 answers for it:
    # `SQLite3 does not export SQLite3::TIME_ZONE`. Stripped, it is
    # `TIME_ZONE`, which is what the shard's own file means by it.
    if body = @@mono_bodies.delete(old_key)
      @@mono_bodies[new_key] = yield body
    end
    after
  end

  # Rewrites every bound name in *text* to what the consumer calls it. The name
  # has to stand alone on both sides: `JSON` is bound, `JSONThing` is not.
  private def self.map_names(text : String) : String
    mapped = @@bound_prefix.reduce(text) do |carried, (name, qualified)|
      # Recorded where the name is *met* rather than where the text changed. A
      # class root needs no rewriting — the consumer names its types exactly as
      # it declares them — so `mapped != carried` would have said "this
      # boundary is not depended on" of every one of them, and the import edge
      # that reads off this went missing.
      replace_on_boundary(carried, name, trailing_name_ends: true) do
        @@bound_used << @@bound_module[name]
        qualified
      end
    end

    # And a name the producer already wrote in full, which the rewrite above
    # cannot see: `exception_page` writes `@frames :
    # Array(Backtracer::Backtrace::Frame)`, where `Backtrace` is part of a
    # longer name rather than a bare one, so nothing was replaced and no
    # import edge was recorded. The declaration needed none - it is already
    # the consumer's spelling - but a consumer that never loaded `backtracer`
    # stopped on `undefined constant Backtracer::Backtrace::Frame`.
    @@bound_prefix.each do |name, qualified|
      next if qualified == name
      @@bound_used << @@bound_module[name] if names_on_boundary?(mapped, qualified)
    end

    mapped
  end

  # Whether *needle* stands in *text* as a whole name, by the rule
  # `replace_on_boundary` replaces on.
  private def self.names_on_boundary?(text : String, needle : String) : Bool
    return false if needle.empty?
    index = 0
    while (found = text.byte_index(needle, index))
      after = found + needle.bytesize
      if !after_name_byte?(text, found) &&
         (after >= text.bytesize || !identifier_byte?(text.to_unsafe[after]))
        return true
      end
      index = found + 1
    end
    false
  end

  private def self.map_names(signature : IyiMod::Signature) : IyiMod::Signature
    IyiMod::Signature.new(
      name: signature.name,
      receiver: signature.receiver,
      parameters: signature.parameters.map { |parameter| map_names parameter },
      block_parameter: map_names(signature.block_parameter),
      return_type: map_names(signature.return_type),
      free_variables: signature.free_variables,
      required: signature.required,
    )
  end

  private def self.map_names_declaration(declaration : IyiMod::TypeDecl,
                                         path : String = declaration.name) : IyiMod::TypeDecl
    # `copy_with`, for the reason `prune_declaration` gives — and this is the
    # rebuild that proved it: written the other way it dropped every `fun` a
    # reopened `lib` carried, so `sqlite3`'s consumer said `undefined fun
    # 'value_text' for LibSQLite3` about a lib whose types had all arrived.
    declaration.copy_with(
      fields: declaration.fields.map { |(name, type, value)| {name, map_names(type), map_names(value)} },
      methods: begin
        ordinals = IyiMod.mono_body_ordinals(declaration.methods)
        declaration.methods.map_with_index do |signature, index|
          rekey_body(path, signature, map_names(signature), ordinals[index]) { |body| map_names body }
        end
      end,
      types: declaration.types.map { |nested| map_names_declaration nested, "#{path}::#{nested.name}" },
      value: map_names(declaration.value),
      class_vars: declaration.class_vars.map do |class_var|
        class_var.copy_with(type: map_names(class_var.type), value: map_names(class_var.value))
      end,
      superclass: map_names(declaration.superclass),
      includes: declaration.includes.map { |name| map_names(name) },
      funs: declaration.funs.map { |source| map_names(source) },
    )
  end

  # What an iyi program calls this shard, which is not a matter of taste.
  #
  # The symbol is the whole reason. Both sides mangle alike, so `Greeter.polite`
  # is `*Greeter@Greeter::polite<String>:String` compiled from either language —
  # but only if the consumer's module *is* `Greeter`, and the consumer builds
  # that name by camelcasing the module path it imported. `downcase` broke the
  # round trip for every name with an inner capital: `MyGreeter` became
  # `mygreeter` became `Mygreeter`, which mangles to a symbol the shard's object
  # file does not contain, and nothing says so until the linker does.
  #
  # `::` is `/` because that is how iyi spells a nested module (IV.6 #6), and
  # each segment is `camelcase` run backwards.
  #
  # `String#underscore` is *not* that inverse and using it was the bug this
  # replaced: it answers `json` for `JSON`, which camelcases back to `Json`.
  # `camelcase` upper-cases the first letter of every underscore group, so its
  # inverse starts a group at every upper-case letter — `j_s_o_n`, which is a
  # legal iyi path and comes back `JSON`. `HTTPServer` is `h_t_t_p_server` and
  # comes back whole; `underscore` gave `http_server` and lost it.
  # Public, because the build that fills this artifact's object code has to
  # find the file `tool bind` wrote and only this rule says where it is.
  def self.iyi_module_name(root : String) : String
    root.split("::").map do |segment|
      # By hand, for the same reason as the boundary tests above: a pattern here
      # costs the whole compiler a C library (Appendix B #22).
      broken = String::Builder.new(segment.bytesize * 2)
      segment.each_char do |character|
        if character.ascii_uppercase?
          broken << '_'
          broken << character.downcase
        else
          broken << character
        end
      end
      broken.to_s.lchop('_')
    end.join("/")
  end

  # Whether that name comes back as the name it was made from.
  #
  # Almost everything does, now that the inverse above is the real one:
  # `JSON`, `URI`, `HTTPServer`, `Base64`. What does not is a name the grammar
  # cannot spell — one already carrying an underscore, say, which would need two
  # in the path and `camelcase` reads two as one. The check stays because the
  # failure it catches is the worst-behaved kind: the mangled symbol carries
  # whichever name the side that compiled it had, so a producer writing
  # `*Foo_Bar@Foo_Bar::...` and a consumer asking for `*FooBar@FooBar::...` agree
  # on everything a compiler checks and disagree only where `ld` looks.
  private def self.round_trips?(root : String) : Bool
    consumer_name(root) == root
  end

  # What the consumer will call it, having imported the module.
  private def self.consumer_name(root : String) : String
    iyi_module_name(root).split('/').map(&.camelcase).join("::")
  end

  # `Log` written `::Log`, where leaving it bare would find something else.
  #
  # An artifact's declarations are rendered *inside* the module they belong to,
  # so a bare name is looked up there first. `Kemal::Log` is a constant and
  # `::Log` is Crystal's class, and an accessor declared to return `Log` inside
  # `module Kemal` finds the constant: *`Kemal::Log` is not a type, it's a
  # constant*. Only a top-level name can be shadowed this way, and only a name
  # of Crystal's — the shard's own are reached through the root on purpose.
  #
  # The *head* of a path, not only a bare name, and that took `db` to find. It
  # writes `def self.arg_to_log(arg) : ::Log::Metadata::Value` — with the `::`,
  # because a shard's author meets this too — and a declaration resolving that
  # to `Log::Metadata::Value` put the same shadowing one segment along:
  # `undefined constant Log::Metadata::Value`, read inside a module that has a
  # `Log` of its own. What can be shadowed is the first name in the path, so
  # that is the one asked about.
  private def self.global_name(name : String, root : String) : String
    return name if name.starts_with?("::")

    head = name.partition("::")[0]
    return name if head == root || head.empty?
    return name unless @@crystal_types.includes?(head)
    "::#{name}"
  end

  # Every type defined under Crystal's own source, by qualified name.
  #
  # Read from where each type was written rather than from a list: a list is a
  # claim that everything not in it does not matter, and this file has already
  # recorded what that costs once.
  # Every abstract struct in the program, by name: `Number`, `Int`, `Float`
  # and any the shard declares itself.
  private def self.unwritable_types(program : Program) : Set(String)
    names = Set(String).new
    collect_unwritable program.types?, "", names
    names
  end

  private def self.collect_unwritable(types : Hash(String, Type)?, prefix : String,
                                      names : Set(String)) : Nil
    return unless types
    types.each do |name, type|
      next unless type.is_a?(NamedType)
      if type.responds_to?(:abstract?) && type.abstract? && type.struct?
        names << "#{prefix}#{name}"
      end
      collect_unwritable type.types?, "#{prefix}#{name}::", names
    end
  end

  private def self.crystal_library_types(program : Program) : Set(String)
    names = Set(String).new
    library = program.requires.find(&.ends_with?("prelude.cr"))
    return names unless library
    root = File.dirname(library)

    collect_crystal_types program.types?, "", root, names
    names
  end

  private def self.collect_crystal_types(types : Hash(String, Type)?, prefix : String,
                                         root : String, names : Set(String),
                                         hidden : Bool = false) : Nil
    return unless types

    types.each do |name, type|
      next unless type.is_a?(NamedType)
      written_here = type.locations.try(&.any? { |location| location.filename.to_s.starts_with?(root) })
      next unless written_here || type.types?

      # A `private` type of the library is not a name a consumer can write.
      # `Log::ProcFormatter` is one, and `EMail`'s
      # `def self.client_log_formatter : ::Log::ProcFormatter` was carried as
      # surface because this table said the name was available: the fill build
      # then stopped on `private constant Log::ProcFormatter referenced`, and
      # the whole shard did not bind over one def nobody outside could have
      # called anyway.
      #
      # It goes in the other table instead, because a *value* of it can cross
      # even where the name cannot: `Log::Formatter.new { }` answers one, and
      # `EMail::Client::LOG_FORMATTER` is that call. See `nameable_value?`.
      inside = hidden || type.private?
      if written_here
        (inside ? @@crystal_private : names) << "#{prefix}#{name}"
      end
      collect_crystal_types type.types?, "#{prefix}#{name}::", root, names, inside
    end
  end

  # Whether a *value* of this type can exist on the far side.
  #
  # A different question from `nameable?`, which asks whether the name can be
  # written down. A constant is source the consumer runs - `LOG_FORMATTER =
  # Log::Formatter.new { }` - and what that source names is `Log::Formatter`,
  # which is public; the type it answers is `Log::ProcFormatter`, which is
  # not, and the consumer never has to write it.
  private def self.nameable_value?(name : String, root : String) : Bool
    return true if nameable?(name, root)
    return false if module_valued?(name)

    Rx.scan(name, BIND_TYPE_NAME).all? do |match|
      part = match[0].not_nil!
      next true if part == "class" || part == "_"
      bare = part.lchop("::")
      @@crystal_private.includes?(bare) || nameable_name?(part, root)
    end
  end

  # The shard's requires of *Crystal's library*, for the consumer to replay.
  #
  # A unit numbers the types its source brought in — `Radix` reaches
  # `Hash(String, HTTP::Cookie)` — and a consumer whose prelude is Crystal's
  # still does not have every file of it. So `require "http/cookie"` travels.
  #
  # Crystal's only. A require that resolved into somebody else's `lib` is
  # another shard, and another shard is another boundary: replaying it here
  # would have the consumer compile from source the very thing an artifact
  # exists to spare it. Those arrive as import edges instead.
  #
  # Told apart by where each one resolved, which is why the resolution is what
  # was recorded rather than the name alone.
  # Where Crystal's own library lives, or nil when this build has no prelude of
  # its own to measure against.
  private def self.library_root(program : Program) : String?
    library = program.requires.find(&.ends_with?("prelude.cr"))
    library ? directory_of(library) : nil
  end

  # The directory a file sits in, *with* its separator, because every
  # question below is `starts_with?` and a bare dirname answers it for the
  # wrong files too: `/x/lib/radix` is a prefix of `/x/lib/radix-tree/src`,
  # and a library root of its own neighbour. `bind_inputs`
  # would have recorded the neighbour's files as this shard's, and a
  # boundary read as stale whenever they changed.
  #
  # The separator is the one the path itself used, not `File::SEPARATOR`,
  # which is `'/'` on every platform in this library: `File.dirname` of a
  # Windows path answers `C:\x\lib\radix\src`, and `+ "/"` made that a
  # prefix of nothing at all, which puts every file of the shard *outside*
  # its own directory — the same defect the other way round.
  private def self.directory_of(file : String) : String
    directory = File.dirname(file)
    return directory if directory.ends_with?('/') || directory.ends_with?('\\')
    following = file[directory.size]?
    directory + (following == '\\' ? "\\" : "/")
  end

  # Whether a type is the *library's* rather than the shard's.
  #
  # A shard may reopen a namespace the library already has — `openssl_ext` is
  # `OpenSSL` — and a consumer under `--crystal` replays the requires and gets
  # the library's version. Declaring it a second time is how a build stops on
  # `superclass mismatch for class OpenSSL::SSL::Error`: the artifact says one
  # thing and `require "openssl"` says another about the same name.
  #
  # Asked of where it is *defined*, which is the only thing that separates the
  # two: a type the shard wrote is under the shard, and one the library wrote is
  # under the library. A type both of them touch counts as the shard's, because
  # what the shard added to it has to travel somehow.
  # The top-level namespaces the shard declares itself, other than *root*.
  #
  # Its own, by where they are written: a shard that reopens `JSON` writes
  # `module JSON` in its own file too, and that namespace is Crystal's - what
  # the shard added to it travels in `Reopened`. So a namespace counts here
  # only if *every* file that declares it is the shard's own.
  private def self.other_namespaces(program : Program, root : String) : Array(String)
    source = program.filename
    return [] of String unless source.is_a?(String)
    directory = directory_of(source)
    return [] of String if directory.empty?

    names = [] of String
    program.types?.try &.each do |name, type|
      next if name == root
      next unless type.is_a?(NamedType)
      next if type.is_a?(GenericType)
      locations = type.locations
      next unless locations && !locations.empty?
      next unless locations.all? do |location|
                    filename = location.filename
                    filename.is_a?(String) && filename.starts_with?(directory)
                  end
      # A namespace with nothing in it is nothing to bind: `PQ` holds types
      # and defs, while a bare `module Foo; end` in a shard's file holds none.
      next if (type.types?.try(&.size) || 0) == 0 && (type.as?(ModuleType).try(&.defs.try(&.size)) || 0) == 0
      names << name
    end
    names.sort!
  end

  private def self.library_type?(type : Type, root : String?) : Bool
    return false unless root
    return false unless type.responds_to?(:locations)
    locations = type.locations
    return false unless locations && !locations.empty?

    locations.all? do |location|
      filename = location.filename
      filename.is_a?(String) && filename.starts_with?(root)
    end
  end

  private def self.crystal_requires(program : Program) : Array(String)
    root = library_root(program)
    return [] of String unless root

    names = program.iyi_crystal_requires.compact_map do |name, resolved|
      name if resolved.starts_with?(root)
    end
    names.sort!.uniq!
    names
  end

  # The bodies a generic's methods travel as, keyed the way the reader looks
  # them up. Reset per run with everything else this file accumulates.
  @@mono_bodies = {} of String => String

  # A generic type: its parameters, its fields, and its methods with bodies.
  #
  # `new` is left out on purpose and the reason is already in IV.2: it is
  # synthesized from `initialize` rather than read from an artifact, so a
  # consumer makes its own — and one carried here would meet it at the linker
  # as a duplicate.
  private def self.generic_declaration(name : String, type : GenericType,
                                       by_owner, root : String,
                                       container : String = name) : IyiMod::TypeDecl?
    parameters = type.type_vars
    signatures = [] of IyiMod::Signature

    { {type.to_s, false}, {type.metaclass.to_s, true} }.each do |(owner, on_metaclass)|
      by_owner[owner]?.try &.each do |method|
        next if method.name == "new"
        # A generic's `new` is never carried — it is synthesised per
        # instantiation and the consumer makes its own — so its `initialize` is
        # what a consumer builds one with. It answers nothing to infer.
        # Every one of a generic's methods is compiled by the consumer from the
        # body below, so what one *returns* is the consumer's to infer — exactly
        # as it was the shard's own compiler's. Requiring an answer here dropped
        # `Radix::Tree(T)#add`, and a consumer holding a `@routes` had nothing
        # to call on it.
        next unless method.verdict.ready? || method.inferred || method.body
        next if method.uncompilable
        next unless method.callable?
        # A type variable is nameable inside the type that binds it, which is
        # the whole point of carrying the parameters beside the methods — and
        # the question is asked of each *name* in the type rather than of the
        # whole string. `T` passed and `(T | Nil)` did not, so
        # `Radix::Node(T)#initialize` never crossed and a consumer had no way to
        # build one.
        # The generic's parameters *and* the method's own free variables. Both
        # are names nobody declares and both are the method's to use:
        # `QueryMethods(Stmt)` binds `Stmt` and `query_one(… &block : ResultSet
        # -> U) : U forall U` binds `U`.
        bound = parameters + method.free_vars
        # `?` is what a parameter nobody wrote a type for reads as, and it is
        # not a name to resolve. Every one of a generic's methods travels as
        # source, so the consumer infers it exactly as the shard's own
        # compiler did: `radix` writes `private def find(path, result, node,
        # first = false)` and its public `find` — which travels — calls it
        # with `first: true`. Held to this test the private one never crossed
        # and the consumer stopped inside the body it was handed: `no
        # parameter named 'first'`.
        next unless method.signature_types.all? do |written|
                      written == "?" || nameable?(written, root, bound)
                    end
        # An `abstract def` is a *requirement*, and it has no body by
        # definition — `method.body` is the empty string for one, which is
        # truthy, so it came through here as a concrete method with an empty
        # body. That is not the same thing at all: an empty method answers
        # `nil`, and `db` writes `abstract def fetch_or_build_prepared_statement`
        # on `SessionMethods` for its drivers to implement. The consumer read
        # the requirement as an implementation, called it, and got a statement
        # that was never built — `Invalid memory access` in
        # `SQLite3::Statement#perform_exec`, one dispatch further on.
        #
        # It travels all the same, because a requirement is what a consumer
        # subclassing or including the type has to meet. `required` is how the
        # format says so.
        body = method.body
        next if body.nil?
        next if body.empty? && !method.abstract_def

        signature = IyiMod::Signature.new(
          name: method.name,
          receiver: on_metaclass && method.receiver.empty? ? "self" : method.receiver,
          parameters: method.params.map { |(argument, restriction, default)| bind_parameter(argument, restriction, default) },
          block_parameter: method.written_block,
          # Empty where the body is what answers: there is no single return type
          # to write for a block that returns `_`, and the consumer compiles the
          # body and reads its own. An `initialize` answers nothing either.
          return_type: method.answer || "",
          free_variables: method.free_vars,
          required: method.abstract_def,
          visibility: method.private_def ? "private" : "",
        )
        ordinal = signatures.count { |seen| IyiMod.mono_body_key("", seen) == IyiMod.mono_body_key("", signature) }
        signatures << signature
        @@mono_bodies[IyiMod.mono_body_key(container, signature, ordinal)] = travelling_body(body) unless method.abstract_def
      end
    end

    # No guard on an empty method list, and that is the point. A consumer may
    # need only to *name* this type — `Kemal` refers to
    # `Array(Radix::Node(...))` and never calls a `Node` method — and naming is
    # what a declaration is for. Dropping the empty ones is what left `Kemal`
    # waiting on a type whose methods it had no use for.
    fields = split_fields(type)

    nested = [] of IyiMod::TypeDecl
    collect_declarations type, by_owner, root, nested, container

    IyiMod::TypeDecl.new(
      name: name,
      kind: type.type_desc.lchop("generic "),
      type_parameters: parameters,
      assoc_types: [] of String,
      supertraits: [] of String,
      fields: fields,
      # Stable, for the reason the other sort of these gives.
      methods: signatures.map_with_index { |signature, index| {signature, index} }
        .sort_by { |(signature, index)| {signature.name, index} }.map(&.[0]),
      # A module takes neither word, which is the same rule the non-generic
      # ones take: `pub` marks a def, a class, a struct, a trait or an enum,
      # and what a namespace owes is that the things inside it can be named.
      visibility: type.is_a?(GenericModuleType) ? "" : (type.private? ? "private" : "pub"),
      # A generic holds types too, and leaving them behind is how
      # `Kemal::LRUCache::Node(K, V)` went missing while `LRUCache` travelled.
      types: nested,
      class_vars: declared_class_vars(type),
      # The same two edges every other declaration carries, and they were left
      # out here. `db` writes `module SessionMethods(Session, Stmt)` that
      # includes `QueryMethods(Stmt)`, and `QueryMethods` is where `exec` and
      # `query` live — the two methods the whole shard exists to offer. Without
      # the edge a consumer said `undefined method 'exec' for DB::Database`
      # about a `Database` that had every other method on it.
      superclass: superclass_name(type, root),
      includes: included_modules(type, root, parameters),
      extends_self: extends_self?(type),
    )
  end

  # Whether this module writes `extend self`.
  #
  # A module that does has its own instance methods on its metaclass as well,
  # which is what `Parser.parse` resolves through — and the metaclass says so
  # by having the module among its ancestors. Asked of the metaclass rather
  # than searched for in the source: `extend self` is one spelling of it and
  # `extend Parser` from inside `Parser` is another.
  private def self.extends_self?(type : Type) : Bool
    return false unless type.is_a?(ModuleType) && !type.is_a?(ClassType)
    !!type.metaclass.ancestors.includes?(type)
  end

  # An enum, as its members and the integer they are numbered on.
  #
  # A member is a `Const` under the enum whose value is the number the compiler
  # gave it, so this reads what is there rather than renumbering: a consumer
  # that guessed the numbering would agree with the shard's object file only by
  # luck, and the object file is what it links against.
  private def self.enum_declaration(name : String, type : EnumType,
                                    private_type : Bool) : IyiMod::TypeDecl
    members = [] of {String, String}
    type.types?.try &.each do |member, constant|
      next unless constant.is_a?(Const)
      # `None` and `All` belong to the compiler rather than to the shard: a
      # `@[Flags]` enum is given both wherever it is declared, so carrying
      # them hands the consumer its own back — "flags enum can't redefine All
      # member. None and All are autogenerated". The same rule the iyi-native
      # writer takes (`Compiler#iyi_type_declaration`).
      next if type.flags? && (member == "None" || member == "All")
      members << {member, constant.value.to_s}
    end

    IyiMod::TypeDecl.new(
      name: name,
      kind: "enum",
      type_parameters: [] of String,
      assoc_types: [] of String,
      supertraits: [] of String,
      fields: [] of {String, String, String},
      methods: [] of IyiMod::Signature,
      visibility: private_type ? "private" : "pub",
      types: [] of IyiMod::TypeDecl,
      # Written even when it is the default, because a member's number is only
      # the same number if the width is.
      value: type.base_type.to_s,
      macros: [] of String,
      members: members,
      # And the word that numbers them: without it the far side reads a plain
      # enum, its `None` and `All` are never made, and a question method asks
      # equality where the shard asked membership.
      annotations: type.flags? ? ["@[Flags]"] : [] of String,
    )
  end

  # `TABLE = ["zero", "one", "two"]`, for every constant of *root*'s own that a
  # consumer could rebuild — including the ones inside its types.
  #
  # Its own only. A unit refers to Crystal's constants too — `Int::DIGITS_BASE62`
  # is reached because `Array#[]` can raise and raising formats an integer — and
  # those belong to the library the consumer already has under `--crystal`.
  # Writing them here would define somebody else's constant twice.
  #
  # A nested one is written `Inner::X = ...`, which defines rather than reopens.
  # That was left out once on the assumption it did not, which was a guess and
  # wrong: Crystal takes a qualified assignment wherever the namespace exists,
  # and the declarations above this text are what make it exist.
  # The shard's own top-level code: its constants, and the statements beside
  # them.
  #
  # A constant was the whole of this, and a shard's top level is more than
  # constants. `sqlite3` writes `DB::register_driver "sqlite3",
  # SQLite3::Driver` at the top level of `driver.cr` — one statement, and the
  # thing the entire shard exists to do. Without it a consumer linked, ran, and
  # said `no driver was registered for the schema "sqlite3", did you maybe
  # forget to require the database driver?` — which is exactly what had
  # happened, one boundary over.
  #
  # Read back from the shard's own files rather than from the tree, because the
  # tree is not where it is any more: by the time a boundary is written these
  # statements have been typed, expanded and folded into the program's `_main`,
  # and what has to cross is what the shard *wrote*. The same argument
  # `Const#iyi_value_source` makes, one level up.
  #
  # In require order, which is the order they ran in. `Program#requires` is
  # insertion-ordered and holds the resolved path of everything this build
  # read, so the shard's own files are the ones under its directory.
  private def self.initialiser_source(program : Program, root : String) : String
    parts = [] of String
    constants = constant_source(program, root)
    parts << constants unless constants.empty?

    source = program.filename
    if source.is_a?(String)
      directory = directory_of(source)
      unless directory.empty?
        program.requires.each do |path|
          next unless path.starts_with?(directory)
          statements = top_level_statements(program, path)
          parts << statements unless statements.empty?
        end
      end
    end

    parts.join('\n')
  end

  # Whether this call names a macro rather than a method.
  #
  # Asked of the program, because the parser cannot tell them apart: both are
  # `Call` nodes and the difference is what the name was defined as.
  private def self.macro_call?(program : Program, call : Call,
                               namespace : String = "") : Bool
    owner =
      case receiver = call.obj
      when Nil
        # Where the call stands, which for one inside a `module` body is that
        # module: `getter` and `property` are macros a class body calls with
        # no receiver, and asked of the top level they are not macros at all.
        #
        # The top level is still asked, below: `record` is a macro of the
        # prelude's, written at no namespace, and a module body calls it as
        # readily as a file does. Missed, `record(Param, …)` was copied into
        # `pq`'s initialiser and declared a second `PQ::Param` on the far
        # side — one the boundary had not marked `pub`, so the shard beside
        # it stopped on `PQ does not export PQ::Param`.
        namespace_type(program, namespace) || program.as(Type)
      when Path
        found = nil.as(Type?)
        table = program.types?
        receiver.names.each do |part|
          next_type = table.try &.[]?(part)
          return false unless next_type
          found = next_type
          table = next_type.as?(NamedType).try(&.types?)
        end
        found
      else
        return false
      end
    return false unless owner

    scopes = [owner.as?(ModuleType), owner.metaclass.as?(ModuleType),
              program.as?(ModuleType)]
    # And what it inherits, because `getter` is `Object`'s and every class
    # body calls it as its own.
    if owner.responds_to?(:ancestors)
      owner.ancestors.each do |ancestor|
        scopes << ancestor.as?(ModuleType)
        scopes << ancestor.metaclass.as?(ModuleType)
      end
    end
    scopes.each do |scope|
      return true if scope.try(&.macros).try(&.has_key?(call.name))
    end
    false
  end

  # The type a path names, or nil where the shard does not declare one.
  private def self.namespace_type(program : Program, namespace : String) : Type?
    return nil if namespace.empty?
    found = nil.as(Type?)
    table = program.types?
    namespace.split("::").each do |part|
      next_type = table.try &.[]?(part)
      return nil unless next_type
      found = next_type
      table = next_type.as?(NamedType).try(&.types?)
    end
    found
  end

  # The shard's own top-level `fun`s, as source.
  #
  # Read from the files rather than from the program, because what has to
  # cross is the *text*: `External` is a `Def` by the time semantic analysis
  # is done, and rendering one back as a `fun` with its body is a translation
  # nobody needs when the file beside it says it exactly.
  private def self.top_level_funs(program : Program) : Array(String)
    source = program.filename
    return [] of String unless source.is_a?(String)
    directory = directory_of(source)
    return [] of String if directory.empty?

    funs = [] of String
    program.requires.each do |path|
      next unless path.starts_with?(directory)
      next unless File.file?(path)
      parser = program.new_parser(File.read(path))
      parser.filename = path
      flat_expressions(parser.parse).each do |node|
        funs << node.to_s if node.is_a?(FunDef)
      end
    end
    funs
  end

  # The statements one of the shard's files writes outside every declaration.
  #
  # A declaration is not one of these — a class, a module, a `def`, a `lib`, an
  # `enum`, an `alias`, a macro, an `annotation` — and neither is a `require`,
  # which `Requires` already carries, nor a constant, which `constant_source`
  # does. What is left is code, and code is what has to run.
  private def self.top_level_statements(program : Program, path : String) : String
    source = File.read(path)
    parser = program.new_parser(source)
    parser.filename = path
    nodes = parser.parse

    lines = [] of String
    collect_runnable program, nodes, "", lines
    lines.join('\n')
  rescue
    ""
  end

  # The same question one namespace in.
  #
  # A `module` body runs its statements exactly as a file does — that is what
  # `PG::Decoders` is made of: five `register_decoder BoolDecoder.new` lines
  # under a `@@decoders` hash, and the hash's *default* is the byte decoder.
  # Skipped as "a declaration, somebody else carries it", the artifact's
  # object code arrived with an empty registry and every column came back raw:
  # `In PG::ResultSet#read the column count returned a Slice(UInt8) but a
  # Int64 was expected`, from an application whose front end had compiled
  # clean.
  #
  # Written back as a reopening, absolute, so the statements run in the scope
  # that wrote them: `register_decoder` is `PG::Decoders`' own and its
  # argument names a class beside it.
  private def self.collect_runnable(program : Program, node : ASTNode,
                                    namespace : String, lines : Array(String),
                                    assigned : Array(String)? = nil,
                                    calls : Array(Bool)? = nil) : Nil
    flat_expressions(node).each do |inner|
      # Inside a declaration, a *call* is the only thing that is code.
      #
      # Everything else a body holds is the declaration's own and has already
      # travelled by its own road: a class variable's assignment and its
      # annotation are in `class_vars`, a constant is in the constants, an
      # instance variable's is a field. Copied here as well they run a second
      # time on the far side, over declarations that already exist — a
      # `@[ThreadLocal] @@buffer = uninitialized StaticArray(UInt8, 4)` read
      # back at the top level is a second, unrelated variable of the same
      # name, and `bench/bind_roundtrip.sh` answered with a segfault.
      # A class variable's assignment is the exception, and it is the reason
      # the calls beside it can run at all: `PG::Decoders` writes
      # `@@decoders = Hash(Int32, Decoder).new(ByteaDecoder.new)` and then
      # five `register_decoder` lines under it. Carried without the
      # assignment, the first call read a global nobody had filled — a
      # segfault in `__crystal_main`, before the program's own first line.
      #
      # The declaration drops its value where this happens, so the variable
      # is initialised exactly once and in the order the shard wrote.
      if !namespace.empty? && inner.is_a?(Assign) && (target = inner.target).is_a?(ClassVar)
        assigned.try &.<< "#{namespace}::#{target.name}"
        lines << inner.to_s
        next
      end

      if !namespace.empty? && !inner.is_a?(Call) && !inner.is_a?(ModuleDef) && !inner.is_a?(ClassDef)
        next
      end

      case inner
      when ModuleDef, ClassDef
        name = inner.name.to_s
        inside = namespace.empty? ? name : "#{namespace}::#{name}"
        # This root's own namespaces only. A shard's files are read once per
        # root it declares — `pg` declares `PG` and `PQ`, and both artifacts
        # are built from the same directory — so `PG::Decoders`' body reached
        # `pq`'s initialiser as well, where the name it is written with
        # resolves to nothing: `undefined constant PG::Decoders::Decoder`.
        next unless inside == @@root || inside.starts_with?("#{@@root}::") ||
                    @@root.starts_with?("#{inside}::")
        nested = [] of String
        nested_assigned = [] of String
        nested_calls = [] of Bool
        collect_runnable program, inner.body, inside, nested, nested_assigned, nested_calls
        # Only where something *runs*. A body whose whole content is a class
        # variable's assignment has nothing this text is for — the
        # declaration carries the value — and reopening the type to say it
        # again is a name R-2 refuses: `Shard does not export Shard::Part`.
        next if nested.empty? || nested_calls.empty?
        @@assigned_class_vars.concat nested_assigned
        calls.try &.<< true
        keyword =
          case inner
          when ClassDef then inner.struct? ? "struct" : "class"
          else               "module"
          end
        # Written relative to the shard's own root, because that is where
        # this text is read: the initialiser is rendered *inside* the
        # artifact's module, and an absolute `::PG::Decoders` from in there
        # declares a second type of that name at the top level — one whose
        # `@@decoders` is a different global from the one the object code
        # writes to. The root itself needs no wrapper at all; its body is
        # already the text's own scope.
        relative = inside == @@root ? "" : inside.lchop("#{@@root}::")
        lines << (relative.empty? ? nested.join('\n') : "#{keyword} #{relative}\n#{nested.join('\n')}\nend")
      when VisibilityModifier
        # `private def` and `protected getter` are declarations wearing a
        # modifier. Read as "not a declaration" — which is what falling
        # through to the last branch does — the whole method was copied into
        # the initialiser, to be defined a second time on the far side.
      when Require, Def, Macro, LibDef, EnumDef,
           Alias, AnnotationDef, Include, Extend, TypeDeclaration, Nop, FunDef
        # A declaration, or a require. Somebody else carries it.
        #
        # `FunDef` is one of them, and it took a consumer to say so: copied
        # here, gcry's top-level `fun gcry_mark_worker_main` was rendered
        # inside the module the declarations sit in - `can only declare fun at
        # lib or global scope` - and the symbol it declares is already in this
        # artifact's object code.
      when MacroExpression, MacroFor, MacroIf
        # A macro at the top level writes declarations, and the declarations it
        # wrote have already travelled — `Exports` has them, one entry per
        # method the loop produced. Carried here as well it would run a second
        # time on the far side, where the names it reads are the shard's own
        # and private: kemal writes `{% for method in HTTP_METHODS %}` and a
        # consumer said `undefined constant HTTP_METHODS`.
      when Assign
        # `TABLE = [...]` is a constant and `constant_source` has it; anything
        # else assigned at the top level is a local nobody outside can read.
      when Call
        # A call to a *macro* is a declaration written compactly, not code
        # that runs, and whatever it declared has already travelled in
        # `Exports`. `kilt` writes `Kilt.register_engine("ecr", ECR.embed)` at
        # its top level - a macro whose two arguments are unevaluated AST -
        # and copying the line into the initialiser handed a consumer
        # `ECR.embed` with nothing in it: `wrong number of arguments for macro
        # 'embed' (given 0, expected 2)`, from a file nobody wrote.
        unless macro_call?(program, inner, namespace)
          lines << inner.to_s
          calls.try &.<< true
        end
      else
        lines << inner.to_s
      end
    end
  end

  # One `Expressions` tree as a flat list. Collected rather than yielded: a
  # recursive method that yields is inlined at every level, and the compiler
  # says so — `recursive block expansion`.
  private def self.flat_expressions(node : ASTNode) : Array(ASTNode)
    found = [] of ASTNode
    pending = [node]
    until pending.empty?
      current = pending.shift
      if current.is_a?(Expressions)
        current.expressions.reverse_each { |inner| pending.unshift inner }
      else
        found << current
      end
    end
    found
  end

  private def self.constant_source(program : Program, root : String) : String
    root_type = program.types?.try &.[]?(root)
    return "" unless root_type.is_a?(NamedType)

    lines = [] of String
    collect_constant_source root_type, "", root, lines, library_root(program)
    lines.sort!
    lines.empty? ? "" : lines.join('\n')
  end

  private def self.collect_constant_source(owner : NamedType, prefix : String,
                                           root : String, lines : Array(String),
                                           library : String?) : Nil
    owner.types?.try &.each do |name, type|
      # The library's own, where the shard reopened a namespace that has some.
      # A consumer under `--crystal` replays the requires and already has it, and
      # assigning it again is `already initialized constant
      # OpenSSL::BIO::CRYSTAL_BIO`.
      next if library_type?(type, library)

      case type
      when Const
        # Not the compiler's own. A regex literal is cached in a constant named
        # `$Regex:0`, which is not a name anybody wrote and not one anybody can
        # write — the consumer makes its own when it compiles the body that
        # needed it.
        next if name.starts_with?('$')
        # A value the consumer cannot name is one it cannot rebuild, and a
        # constant it cannot rebuild is better left undefined than defined wrong.
        answer = type.value.type?.try(&.devirtualize.to_s)
        next if answer && !nameable_value?(answer, root)
        written = type.iyi_value_source
        # A constant with none is one nobody wrote — see `Const#iyi_value_source`
        # — and the node is the best answer left.
        # `pub`, because a Crystal shard has no other word for it: every
        # constant it writes is one a program requiring it can name, and R-2
        # reads an unmarked one as the module's own business. `kilt` writes
        # `ENGINES` and its `render` macro — which travels — expands to code
        # that reads it, so a consumer stopped inside an expansion it never
        # wrote: `Kilt does not export Kilt::ENGINES`.
        lines << "pub #{prefix}#{name} = #{written.empty? ? type.value.to_s : written}"
      when NamedType
        next if type.is_a?(GenericType)
        next if type.private?
        # An enum's members are its own and travel with it. Written out here
        # they would be assignments into a type that already has them.
        next if type.is_a?(EnumType)
        collect_constant_source type, "#{prefix}#{name}::", root, lines, library
      end
    end
  end

  # The signatures one type carries, both sides of it.
  #
  # A `def self.zero` is stored on the metaclass rather than on the type, so
  # walking only the type's own defs drops every class method — which is what a
  # module is mostly made of.
  private def self.collect_signatures(type : Type, name : String,
                                      by_owner, root : String) : Array(IyiMod::Signature)
    signatures = [] of IyiMod::Signature

    # An abstract class's concrete methods are the **third** thing whose body
    # has to travel, beside a generic's and a block-taker's, and for the same
    # reason each time: they are instantiated per *subclass*, and the subclass
    # is the consumer's. `abstract class ExceptionPage` fills with 0 units and
    # that is not a bug — there is no machine code, because nothing in that
    # shard subclasses it — so a consumer that writes `class Report < Sheet`
    # asked for `*Sheet+@Sheet#render` and nobody had made one.
    #
    # A *module*'s methods are the fourth, and the same sentence says it: they
    # are instantiated per *including* type, and the includer may be in another
    # boundary altogether. `db` writes `module Disposable` with a `close` in
    # it; `sqlite3`'s `ResultSet` includes it through `DB::ResultSet`, and
    # neither artifact can define `*SQLite3::ResultSet@DB::Disposable#close` —
    # db's build has no such type, and sqlite3's has the method only as a
    # header. Nobody could compile it, so nobody did.
    abstract_owner = (type.responds_to?(:abstract?) && type.abstract?) ||
                     (type.responds_to?(:module?) && type.module? && !type.metaclass?)
    { {type.to_s, false}, {type.metaclass.to_s, true} }.each do |(owner, on_metaclass)|
      by_owner[owner]?.try &.each do |method|
        # What the shard wrote, and nothing else. See `BindMethod#written`.
        next unless shard_wrote?(method)

        # A private one is decided below, once it is known which bodies travel
        # and what they call.
        next if method.private_def

        # A plain type's `initialize` travels only where its `new` could not —
        # that is, where it takes a block. Otherwise `new` is declared beside it,
        # and two ways to build one type is one too many.
        next if method.name == "initialize" && method.written_block.empty?

        next unless method.verdict.ready? || method.inferred || method.body_answers
        # A method the compiler refused to instantiate does not travel *as a
        # symbol*. The keep file names what a boundary declares, so one that
        # does not typecheck takes the whole fill build with it — every
        # declaration on disk and no machine code anywhere.
        #
        # Its body still can, and for these two shards it is the only way it
        # could: `Quartz::Composer#deliver` calls `sender`, which every mailer
        # a consumer writes defines and the shard itself never does. Measured
        # here it is `undefined method 'sender'`; compiled by the consumer,
        # against the subclass that has one, it is the method the application
        # calls. The keep file leaves a travelling body alone, so the fill
        # build never sees it.
        next if method.uncompilable && !method.body_answers
        # `storable` and the names below ask what a method *called by symbol*
        # needs, and one whose body travels is not called by symbol — the
        # consumer compiles it. The module-function collector has read them
        # this way since `Kemal.run` crossed; this one still read them as
        # unconditional, so `OpenSSL::PKey::RSA.new(encoded : String,
        # passphrase = nil)` was dropped for `passphrase` and a consumer got
        # the one overload that was left: `expected argument #1 to
        # 'OpenSSL::PKey::RSA.new' to be Int32, not String`.
        next unless method.storable || method.body_answers
        next unless method.callable?
        next unless method.body_answers || method.signature_types.all? { |t| nameable?(t, root, method.free_vars) }

        # A block-taking method's machine code is the caller's, and IV.1g is
        # explicit that this is a question about a `def` rather than about a
        # type: the producer emits each instantiation private to the unit
        # that called it, so no symbol for one ever leaves the artifact. A
        # declaration without the body is therefore a promise nothing can
        # keep, and `bench/bind_roundtrip.sh` says so in the only way that
        # settles it — `undefined symbol:
        # *Shard::Part#apply<&Proc(Int32, Int32)>`.
        #
        # So it travels the way a generic's methods already did, in
        # `MonoBodies`, and the consumer compiles its own from the block it
        # wrote. A body that is not there to carry cannot cross at all.
        #
        # And a setter, for the same reason written a third way: its answer is
        # the value it was handed, so there is no one return type and no one
        # symbol. `body_answers` is the question both cases are asking.
        #
        # And the fourth: a body whose machine code enumerates the members of
        # an open type, or which calls one that does (SPEC.md III.6). A module
        # used as a type is dispatched as a test per including type, and a
        # consumer that writes one of its own joins that set — so the producer's
        # compiled test is the answer to a question it was not asked. The
        # `abstract_owner` clause above is the half of this that was already
        # known: a method *on* a module. This is the other half — the methods
        # that call one, which is how a `First#run` compiled against two
        # includers reached a consumer's third.
        #
        # And a fifth that is about the type rather than the method: one the
        # shard keeps to itself. `keep_type` refuses to name a private
        # declaration — `private constant IO::Encoder referenced` is what
        # naming it costs — so the keep file calls nothing on it and the
        # producer emits a symbol only where its own object code happened to
        # reach one. Once the reaching body travels, nothing does:
        # `undefined symbol: *Kemal::HeadRequestHandler::NullIO::new<HTTP::
        # Server::Response>`, referenced by the consumer's own copy of
        # `HeadRequestHandler#call`. A private type's methods are the
        # consumer's to compile, all of them.
        carries_body = (!method.written_block.empty? || abstract_owner ||
                        method.body_answers || type.private? ||
                        type.program.iyi_open_travel_defs.includes?(method.location)) &&
                       !method.abstract_def

        # A block-taking `new` does not travel at all. It is synthesised from
        # `initialize` rather than written, so its body is the compiler's —
        # `_.initialize(method, path, &handler)`, with a temporary for a
        # receiver — and that is not source anybody can parse back. The
        # consumer makes its own from the `initialize` beside this, which is
        # what `new` has always done here.
        # A *synthesised* one, which is what an empty receiver says: the
        # compiler makes it from `initialize` and gives it no receiver of its
        # own. One a shard wrote itself is a method like any other, and
        # `openssl_ext` writes three.
        next if carries_body && method.name == "new" && method.receiver.empty?
        body = method.body
        next if carries_body && (body.nil? || body.empty?)

        signature = IyiMod::Signature.new(
          name: method.name,
          # `new` is synthesized from `initialize` and carries no receiver of
          # its own, so a class method would arrive on the far side as an
          # instance method with the right name and the wrong reach.
          receiver: on_metaclass && method.receiver.empty? ? "self" : method.receiver,
          parameters: method.params.map { |(argument, restriction, default)| bind_parameter(argument, restriction, default) },
          block_parameter: method.written_block,
          # Empty where the body is what answers — and *not* empty where the
          # shard wrote a return type anyway, or inherited one from a
          # requirement. A body that travels is compiled by the consumer, so a
          # written return acts as the restriction it is: Crystal narrows it to
          # what the body produced, exactly as it does for the shard.
          return_type: method.body_answers ? (method.returns || "") : method.answer.not_nil!,
          free_variables: method.free_vars,
          required: method.abstract_def,
        )
        # The ordinal is the count of identical signatures already written,
        # which is what tells a redefinition from the definition it replaced.
        # See `IyiMod.mono_body_key`.
        ordinal = signatures.count { |seen| IyiMod.mono_body_key("", seen) == IyiMod.mono_body_key("", signature) }
        signatures << signature
        if carries_body && body
          key = IyiMod.mono_body_key(name, signature, ordinal)
          @@mono_bodies[key] = travelling_body(body)
          @@travelling << key
        end
      end
    end

    # `initialize` first, because what it calls is the next line's question.
    #
    # These ran the other way round, so the body `fallback_initialize` adds was
    # never searched: `Kemal::CLI#initialize(args)` travels — its `new` is not a
    # symbol anybody can name — and its body calls `parse`, which the class
    # keeps to itself. The consumer compiled the body it was given and stopped
    # on `undefined method 'parse' for Kemal::CLI`. `fallback_initialize` asks
    # only whether `new` or `initialize` already crossed, which no private
    # method is, so nothing is owed in the other direction.
    signatures.concat fallback_initialize(type, name, by_owner, signatures)
    signatures.concat called_privates(type, name, by_owner, signatures)
    signatures
  end

  # `initialize`, where `new` could not be declared at all.
  #
  # A consumer builds one of these types by calling `new`, and `new` is
  # synthesised from `initialize` — so where the synthesised one cannot be
  # written down, the thing it was made from has to be. `radix`'s
  # `SharedKeyError#initialize(new_key, existing_key)` writes no restrictions, so
  # its `new` is not a symbol anybody can name, and a body that travels and
  # raises one met a class it could not construct.
  #
  # With its own body, because that is the whole of what the consumer needs: it
  # synthesises `new` and compiles both, exactly as the shard's own compiler
  # did. Only where `new` is absent — declaring both is two ways to build one
  # type.
  private def self.fallback_initialize(type : Type, name : String, by_owner,
                                       carried : Array(IyiMod::Signature)) : Array(IyiMod::Signature)
    added = [] of IyiMod::Signature

    # By *shape*, not by the name alone.
    #
    # "Only where `new` is absent" was the rule, and it held while the only
    # `new` was the one the compiler makes: one `initialize`, one `new`, and
    # having either meant having both. A shard writes its own. `openssl_ext`
    # writes two `def self.new` on `OpenSSL::PKey::PKey` and two `initialize`
    # beside them, and the `new` made from `initialize(is_private : Bool)` is a
    # fourth overload nobody wrote — refused here, because an abstract class
    # cannot be allocated and asking what it answers gets `no type`. The name
    # test saw two `new`s and concluded the type was covered; `RSA.new(priv)`,
    # in a body that travels, met three overloads that take a String, an IO and
    # an Int32.
    #
    # What "declaring both is two ways to build one type" was protecting
    # against is a `new` and an `initialize` of the *same parameters*, which is
    # what this asks instead.
    covered = carried.select { |signature| signature.name == "new" || signature.name == "initialize" }
      .map { |signature| signature.parameters.join(", ") }
      .to_set

    by_owner[type.to_s]?.try &.each do |method|
      next unless method.name == "initialize"
      next if method.uncompilable
      body = method.body
      next if body.nil? || body.empty?

      parameters = method.params.map { |(argument, restriction, default)| bind_parameter(argument, restriction, default) }
      next unless covered.add?(parameters.join(", "))

      signature = IyiMod::Signature.new(
        name: "initialize",
        receiver: "",
        parameters: parameters,
        block_parameter: method.written_block,
        return_type: "",
        free_variables: method.free_vars,
        required: false,
      )
      added << signature
      @@mono_bodies[IyiMod.mono_body_key(name, signature)] = travelling_body(body)
    end

    added
  end

  # The private methods a travelling body calls, and the ones those call.
  #
  # A plain type's methods are machine code in the artifact, so a consumer needs
  # no declaration for what they call — except where a *body* travels. A
  # block-taking method's does, because its machine code is the caller's, and
  # the consumer compiling it needs every name the body names.
  # `Kemal::RouteHandler#add_route` calls `add_to_radix_tree`, which the shard
  # keeps to itself, and the consumer said `undefined method`.
  #
  # Which ones is a call graph, and the bodies are text: a private method is
  # called if its name stands in one of them as a word. Reaching too far costs a
  # declaration nobody uses; reaching too short is the error above, so this errs
  # long. Transitive, because what a private body calls travels with it, and to
  # a fixed point because that recursion has to end somewhere.
  private def self.called_privates(type : Type, name : String, by_owner,
                                   carried : Array(IyiMod::Signature)) : Array(IyiMod::Signature)
    added = [] of IyiMod::Signature

    # What crossed already, by name. A body may call a method that is public
    # and still could not be declared — `Kemal.run` calls
    # `def self.display_startup_message(config, server)`, whose parameters have
    # no types, so R-2 has nothing to write down and the consumer said
    # `undefined method`. Visibility was never the question: the question is
    # whether the consumer has it, and one that could not cross is in exactly
    # the same position as one the shard keeps to itself.
    crossed = carried.map(&.name).to_set

    # And what crossed already by *signature*, which is a different question
    # and the one that stops a method crossing twice. `initialize` is protected
    # in Crystal, so the visibility test above lets it past whatever its name —
    # and `fallback_initialize` has already carried it, with its body.
    # `Kemal::CLI` ended up with two `def initialize(args)`: the first the
    # body, the second empty, and the second is the one Crystal's own rule
    # keeps. The link ended on `undefined symbol:
    # *Kemal::CLI#initialize<Array(String)>`.
    #
    # Invisible until `MonoBodies` learned ordinals — before that both
    # declarations read the same key and rendered the same body, so the
    # duplicate was a redundancy rather than a fault.
    key = ->(method : BindMethod) do
      # The parameters as they are *written*, not their names. `sqlite3` writes
      # ten `private def bind_arg(index, value : …)`, one per type it can bind,
      # and every one of them has the same two parameter names — so keyed on
      # names they were one method and nine were dropped: `expected argument #2
      # to 'SQLite3::Statement#bind_arg' to be Nil, not (Int32 | String)`, with
      # one overload listed.
      written = method.params.map do |(argument, restriction, default)|
        bind_parameter(argument, restriction, default)
      end
      "#{method.receiver}##{method.name}(#{written.join(", ")})#{method.written_block}"
    end

    already = carried.map do |signature|
      "#{signature.receiver}##{signature.name}" \
      "(#{signature.parameters.join(", ")})#{signature.block_parameter}"
    end.to_set

    pool = [] of BindMethod
    { {type.to_s, false}, {type.metaclass.to_s, true} }.each do |(owner, on_metaclass)|
      by_owner[owner]?.try &.each do |method|
        # The library's own is never this boundary's to carry, here as much as
        # in the main loop. Without the test a method dropped there came back
        # in through this door and came back `private`: the consumer said
        # `private method 'name' called for BinData::WriteError.class` about
        # `Class#name`, which its own prelude defines and makes public.
        next unless shard_wrote?(method)
        next unless method.private_def || !crossed.includes?(method.name)
        # `uncompilable` is not asked here, and asking it was wrong. It says
        # this tool could not *instantiate* the method to read its answer, and
        # what these declarations are for is a travelling body to typecheck
        # against — the consumer compiles the body, from the text beside it,
        # and never calls the method by symbol. The keep file is where an
        # uninstantiable method would do damage, and the keep file skips a
        # private one on purpose.
        #
        # `db` writes `private def perform_exec_and_release(args : Enumerable)`
        # — a restriction that is a generic module, which this tool cannot make
        # a value of — and `Statement#exec`'s body, which travels, calls it.
        # A consumer said `undefined method 'perform_exec_and_release' for
        # SQLite3::Statement`.
        next if method.abstract_def
        # An *empty* body is a body. `db` writes `protected def do_close; end`
        # on `DB::Statement` — a hook for subclasses to override, doing nothing
        # itself — and `sqlite3`'s `Statement#do_close` calls `super()`. Read as
        # "nothing to carry" it never crossed, so `super` walked past every
        # ancestor to `Object`: `undefined method 'do_close' for Object`.
        body = method.body
        next if body.nil?
        # A *synthesised* `new` never travels — an empty receiver on the
        # metaclass is what says it is one — and the reason is the same one
        # `collect_signatures` gives: its body is the compiler's, `_ =
        # allocate` and `_.initialize(…)`, and `_` is not a name anybody can
        # read back. Carried here it was `can't read from _`.
        next if on_metaclass && method.receiver.empty? && method.name == "new"

        # The receiver the far side will read, which is what `already` is keyed
        # on: a `def self.` is matched on the metaclass and carries no receiver
        # of its own.
        method = method.copy_with(receiver: "self") if on_metaclass && method.receiver.empty?
        next if already.includes?(key.call(method))
        pool << method
      end
    end
    return added if pool.empty?

    # The bodies already going over, which is where the search starts.
    reach = carried.compact_map { |signature| @@mono_bodies[IyiMod.mono_body_key(name, signature)]? }
    # And a constant's value, which is a travelling body like any other: it
    # crosses as the source that makes it, the consumer runs that source, and
    # Crystal runs it with the constant's own type as the scope. So a name it
    # calls is a name the consumer has to have. `openssl_ext` writes
    # `GETS_BIO = begin ... io_for(bio) ... end` inside `OpenSSL::GETS_BIO`,
    # and `io_for` is `private def self.`; the consumer said `undefined method
    # 'io_for' for OpenSSL::GETS_BIO.class`.
    reach.concat own_constant_sources(type)
    # And a class variable's default, and a field's. Both render as
    # `name : type = value` in the declaration, so the consumer's own compiler
    # runs that value with the type for a scope - the same position a
    # constant's value is in. `email` writes `@@log : Log = create_logger`
    # beside `private def self.create_logger`, and a program that imported the
    # boundary stopped on `undefined local variable or method
    # 'create_logger' for EMail::Client.class` before it reached a line of its
    # own.
    declared_class_vars(type).each { |class_var| reach << class_var.value unless class_var.value.empty? }
    # And the shard's top-level `fun`s, which the consumer compiles: their
    # bodies are the one text that can call into any type the shard has.
    # `gcry`'s `fun gcry_stw_watchdog_main` calls `StwWatchdog.append_hex`,
    # which that module keeps to itself, and a consumer said `undefined
    # method 'append_hex' for Gcry::StwWatchdog:Module`.
    reach.concat @@top_level_fun_sources
    split_fields(type).each { |(_, _, value)| reach << value unless value.empty? }
    # A method answering an ancestor's requirement is wanted whether or not
    # anything here travels, so the search below has to run.
    reach << "" if pool.any?(&.answers_abstract)

    # And the bodies its *ancestors* hand it, because a body that travels is
    # compiled per subclass. `db` writes `private abstract def build_statement`
    # on `PoolStatement` and a concrete one on each subclass, and the body that
    # calls it — `statement_with_retry`, which yields — travels on the
    # ancestor. Asked only of `PoolPreparedStatement`'s own bodies the search
    # found nothing to search, so the subclass's own `build_statement` stayed
    # behind: `undefined local variable or method 'build_statement' for
    # DB::PoolPreparedStatement`.
    #
    # Errs long like the rest of this: a body that names nothing private costs
    # nothing to search, and `calls?` only matches a name that is actually
    # there.
    if type.responds_to?(:ancestors)
      type.ancestors.each do |ancestor|
        { {ancestor.to_s, false}, {ancestor.metaclass.to_s, true} }.each do |(owner, _)|
          by_owner[owner]?.try &.each do |method|
            body = method.body
            reach << body if body && !body.empty?
          end
        end
      end
    end

    # And the bodies that name a method they cannot be seen to call. See
    # `@@duck_bodies`.
    reach.concat duck_bodies(by_owner)

    return added if reach.empty?

    # By *signature*, not by name, which is the same correction the module
    # functions took: a name is what a shard's overloads share. `db` writes
    # `private def self.build_database(connection_string : String)` and
    # `private def self.build_database(uri : URI)`, the first took the name and
    # the second was dropped — and the first's body calls the second.
    # `expected argument #1 to 'DB.build_database' to be String, not URI`,
    # with one overload listed.

    taken = Set(String).new
    until pool.empty?
      wanted = pool.select do |method|
        method.answers_abstract || reach.any? { |body| calls?(body, method.name) }
      end
      break if wanted.empty?

      wanted.each do |method|
        next unless taken.add?(key.call(method))
        signature = IyiMod::Signature.new(
          name: method.name,
          receiver: method.receiver,
          parameters: method.params.map { |(argument, restriction, default)| bind_parameter(argument, restriction, default) },
          block_parameter: method.written_block,
          # Not `NoReturn`, and this is the one place that distinction can be
          # drawn. A method that only ever raises answers `NoReturn` and that
          # is a true thing to write — `NullIO#read` raises
          # `NotImplementedError` and nothing overrides it. A method that
          # answers `NoReturn` because *this build* reached nothing is
          # different, and the two look identical from here: `db` writes
          # `private def self.build_driver(uri : URI)` whose body looks a
          # driver up, and a build of `db` alone has none registered.
          #
          # What separates them is whether the body travels. These do — the
          # consumer compiles them, with `sqlite3` linked and a driver
          # registered — so the answer is the consumer's to infer, and an empty
          # return type is how this file says so. Written, it was a promise the
          # consumer could falsify: `method DB.build_driver must return
          # NoReturn but it is returning SQLite3::Driver`.
          return_type: method.answer == "NoReturn" ? "" : (method.answer || ""),
          free_variables: method.free_vars,
          required: false,
          # Not `pub`, whatever the shard said. These are here for a travelling
          # body to typecheck against, and a name the consumer could write is a
          # name R-2 would have had to check.
          visibility: "private",
        )
        added << signature
        body = method.body
        if body
          @@mono_bodies[IyiMod.mono_body_key(name, signature)] = travelling_body(body)
          reach << body
        end
      end
      pool.reject! { |method| taken.includes?(key.call(method)) }
    end

    added
  end

  # The source of the constants this type holds itself.
  #
  # Its own only, and not the compiler's: a `$Regex:0` is a name nobody wrote
  # and its body is not this shard's to answer for. What this is for is the
  # search above, so it errs the same way — a value that never travels costs a
  # declaration nobody reads, and one that does and cannot call what it calls
  # stops the consumer.
  private def self.own_constant_sources(type : Type) : Array(String)
    sources = [] of String
    return sources unless type.is_a?(NamedType)

    type.types?.try &.each do |name, inner|
      next unless inner.is_a?(Const)
      next if name.starts_with?('$')
      written = inner.iyi_value_source
      sources << (written.empty? ? inner.value.to_s : written)
    end
    sources
  end

  # A `new` whose return type is the class it makes, where the shard has put
  # something else of that name inside it.
  #
  # `openssl_ext` writes `GETS_BIO = ...` inside `class OpenSSL::GETS_BIO`, so
  # inside that class the name `GETS_BIO` is the constant: Crystal's lookup
  # reads the type's own scope first and finds it there. The shard never trips
  # over this because it never writes the name — Crystal infers what `new`
  # returns. This file has to write it, R-2 asks for it, and what it wrote as
  # the answer read as the constant: `OpenSSL::GETS_BIO::GETS_BIO is not a
  # type, it is a constant`.
  #
  # `self` is the spelling that has no such problem, and on a metaclass it is
  # exactly what `new` answers. Absolute spelling is not available: `::` leaves
  # the module wrapper entirely — that is what `lib ::LibCrypto` uses it for —
  # and the wrapper's own name is not one a type path can start with.
  #
  # `new` only, and only where the whole return type is the name. A `def
  # self.make : Foo` that a subclass inherits answers `Foo` where `self` would
  # answer the subclass, and an `Array(Foo)` has no `self` to write. Both are
  # real and neither has been measured; a rule that covers what was measured is
  # the one worth having.
  private def self.qualify_self_references(declaration : IyiMod::TypeDecl,
                                           shadowed : Set(String)) : IyiMod::TypeDecl
    name = declaration.name
    nested = declaration.types.map { |inner| qualify_self_references inner, shadowed }
    return declaration.copy_with(types: nested) unless shadowed.includes?(name)

    declaration.copy_with(
      methods: declaration.methods.map do |signature|
        next signature unless signature.name == "new" && signature.receiver == "self"
        next signature unless signature.return_type == name
        signature.copy_with(return_type: "self")
      end,
      types: nested,
    )
  end

  # *text* with every whole-word *name* replaced by *replacement*.
  #
  # Whole-word, for the reason `calls?` is: `StoreTypes` inside `MyStoreTypes`
  # is a different name and rewriting it would invent one.
  private def self.replace_word(text : String, name : String, replacement : String) : String
    return text unless text.includes?(name)

    String.build do |io|
      index = 0
      while (found = text.index(name, index))
        before = found == 0 ? nil : text[found - 1]
        after = found + name.size >= text.size ? nil : text[found + name.size]
        word = (before.nil? || !(before.alphanumeric? || before == '_' || before == ':')) &&
               (after.nil? || !(after.alphanumeric? || after == '_' || after == ':'))
        io << text[index...found]
        io << (word ? replacement : name)
        index = found + name.size
      end
      io << text[index..]
    end
  end

  # Whether *body* names *method* as a word rather than as part of one.
  # Every body in the shard that says `responds_to?`. See `@@duck_bodies`.
  private def self.duck_bodies(by_owner) : Array(String)
    found = @@duck_bodies
    return found if found

    found = [] of String
    by_owner.each_value do |methods|
      methods.each do |method|
        body = method.body
        next unless body && body.includes?("responds_to?")
        found << body
      end
    end
    @@duck_bodies = found
    found
  end

  # By *byte* index, because the two lines below are byte arithmetic.
  #
  # `String#index` answers in characters, and the two agree only while the
  # text is ASCII. One em dash in a string literal and every match after it
  # was tested against the wrong bytes: `gcry`'s `StwWatchdog#report` has one,
  # so `append_hex` - called on the line after it - was read as uncalled, and
  # a consumer compiling that body said `undefined method 'append_hex'`. The
  # bug is invisible in the common case, which is why it is written down here.
  private def self.calls?(body : String, method : String) : Bool
    return false unless body.includes?(method)

    index = 0
    while (found = body.byte_index(method, index))
      after = found + method.bytesize
      before_ok = found == 0 || !identifier_byte?(body.to_unsafe[found - 1])
      after_ok = after >= body.bytesize || !identifier_byte?(body.to_unsafe[after])
      return true if before_ok && after_ok
      index = found + 1
    end
    false
  end

  # What a class inherits from, or empty for the root its kind implies.
  #
  # `Reference` for a class and `Struct` or `Value` for a struct are what every
  # one of them inherits from when nothing is written, so writing them back
  # would be noise — and `class Foo < Reference` is not how anybody declares a
  # class.
  #
  # Empty as well when the consumer could not name it. That is today's answer
  # rather than a good one: the type crosses without the edge, which is what it
  # did before this existed, and what it costs is written down in IV.2 rather
  # than hidden. Dropping the type instead would take a whole namespace with it.
  # The modules this type includes, by name.
  #
  # `parents` is the superclass and the included modules together, in the order
  # Crystal resolves them, so the superclass comes off and what is left is the
  # includes. A module the consumer cannot name is left out for the reason a
  # field's type is: a declaration may not name something nobody has.
  #
  # `Enumerable` and friends included by the *library's* own types are not this
  # type's business either — they arrive with the library, and a consumer under
  # `--crystal` has it. What matters is the include a shard writes, and
  # `include HTTP::Handler` is the one this exists for.
  #
  # *bound* is the type parameters of the generic this include is written
  # inside, which are names it may use and nobody else may — the same argument
  # the methods beside it take. `db` writes `module SessionMethods(Session,
  # Stmt)` including `QueryMethods(Stmt)`, and asked without the parameters
  # `Stmt` is a name nobody declared, so the edge was dropped and `exec` — the
  # method that shard exists to offer — was on nothing a consumer could reach.
  private def self.included_modules(type : Type, root : String,
                                    bound : Array(String)? = nil) : Array(String)
    names = [] of String
    return names unless type.responds_to?(:parents)
    parents = type.parents
    return names unless parents

    superclass = type.responds_to?(:superclass) ? type.superclass : nil
    parents.each do |parent|
      next if superclass && parent.same?(superclass)
      # A generic module's instantiation is not a `ModuleType` — it is a
      # `GenericModuleInstanceType`, which descends from `GenericInstanceType`
      # and from nothing else this test knew about. `db` writes `include
      # SessionMethods(Database, PoolStatement)` on `Database`, the include was
      # dropped, and a consumer said `undefined method 'exec' for DB::Database`
      # about the method that whole shard exists to offer.
      next unless parent.is_a?(ModuleType) || parent.is_a?(GenericModuleInstanceType)
      next if parent.is_a?(ClassType)

      name = parent.devirtualize.to_s
      next unless nameable?(name, root, bound)
      names << name unless names.includes?(name)
    end
    names
  end

  private def self.superclass_name(type : Type, root : String) : String
    return "" unless type.responds_to?(:superclass)
    superclass = type.superclass
    return "" unless superclass

    name = superclass.devirtualize.to_s
    return "" if name == "Reference" || name == "Struct" || name == "Value"
    return "" unless nameable?(name, root)
    name
  end

  # A type's own class variables, `{"@@count", "Int32", "0"}`.
  #
  # A class variable is a global, and its global is defined in the main module
  # of the build that compiled it — which for a bound shard is a build the
  # consumer never sees. The methods that read one are in the object code this
  # boundary carries, referring to it by symbol, so without the declaration the
  # link ends on `undefined symbol: Shard::Part::count`.
  #
  # Devirtualised for the reason the fields beside it are: `IO+` is how a
  # virtual type prints and not a name anybody can write back.
  #
  # Own only — `class_vars?` rather than a lookup, because looking one up walks
  # ancestors and copies what it finds onto the asking type.
  private def self.collect_class_vars(type : Type) : Array(IyiMod::ClassVarDecl)
    class_vars = [] of IyiMod::ClassVarDecl
    return class_vars unless type.responds_to?(:class_vars?)

    owner = type.devirtualize.to_s
    type.class_vars?.try &.each do |name, variable|
      initialiser = variable.iyi_initialiser_source
      written = variable.type?.try(&.devirtualize.to_s) || "?"
      # Unless the initialiser carries the assignment, in which case this one
      # would run a second time — after the statements beside it, undoing
      # them. `PG::Decoders` fills its `@@decoders` hash from five calls
      # under the assignment, and a declaration that re-ran the assignment
      # emptied the registry every consumer had just filled.
      initialiser = "" if @@assigned_class_vars.includes?("#{owner}::#{name}")
      # `@[ThreadLocal]` travels with the variable, because it decides which
      # global the object code on both sides writes to. See
      # `IyiMod::ClassVarDecl`.
      annotations = variable.thread_local? ? ["@[ThreadLocal]"] : [] of String
      # A class variable with no initialiser and a type that cannot hold `nil`
      # is one the shard declared `uninitialized`: Crystal has no third way to
      # write one, and it refuses the declaration without either. Rendered
      # without it, `gcry`'s `@@ranges = uninitialized StaticArray(RootRange,
      # MAX_RANGES)` reached a consumer as a bare type declaration and
      # stopped it - `class variable '@@ranges' of Gcry::Platform is not
      # nilable ... so it must have an initializer`.
      if initialiser.empty? && written != "?" &&
         written != "Nil" && !union_members(written).includes?("Nil")
        initialiser = "uninitialized #{written}"
      end
      class_vars << IyiMod::ClassVarDecl.new(name, written, initialiser, annotations)
    end
    class_vars
  end

  # One parameter, as the declaration writes it.
  #
  # The default is written back because leaving it out changes the method: a
  # caller may pass fewer arguments than there are parameters, or name one and
  # skip another, and a declaration missing the defaults refuses both.
  private def self.bind_parameter(name : String, restriction : String, default : String) : String
    # A bare `*` is a parameter with no name: it marks what follows as
    # named-only. Written as nothing it is `, ,` and the far side stops on
    # `unexpected token: ","`.
    return "*" if name.empty?

    # `?` is what an unresolved restriction is recorded as, and it is not a type
    # and not syntax. A method that reaches a declaration with one is a method
    # the consumer compiles from its body — a generic's, a private one's — and
    # writing the name alone is what the shard wrote.
    written = restriction == "?" ? name : "#{name} : #{restriction}"
    default.empty? ? written : "#{written} = #{default}"
  end

  # The foreign types one signature waits on.
  private def self.foreign_names(method : BindMethod, root : String) : Set(String)
    names = Set(String).new
    method.signature_types.each do |type|
      Rx.scan(type, BIND_TYPE_NAME).each do |match|
        part = match[0].not_nil!
        next if part == "class"
        names << part unless nameable_name?(part, root)
      end
    end
    names
  end

  # The order to declare them in: the one that unblocks the most first.
  #
  # Greedy rather than optimal, and the difference does not matter — what this
  # answers is "where does the work start", and the head of the list is the
  # same either way.
  private def self.blocked_by(program : Program, known : Array(BindMethod),
                              root : String) : Array(String)
    counts = Hash(String, Int32).new(0)
    known.each do |method|
      # Only what somebody could actually declare. A method waiting on a free
      # variable stays waiting, and the count above still holds it there — but
      # it does not belong on a list of work.
      foreign_names(method, root).each do |name|
        counts[name] += 1 if declared_type? program, name
      end
    end
    counts.to_a.sort_by { |(name, count)| {-count, name} }.map { |(name, _)| name }
  end

  # A type an iyi program can name: the shard's own, or one of the prelude's.
  #
  # Every name inside it, not just the one in front. `Hash(Exception.class,
  # Proc(HTTP::Server::Context, Exception, String))` begins with a type the
  # prelude has and is made almost entirely of types it does not, and reading
  # only the head counted it as writable — the measurement flattering itself.
  # *bound* is the type parameters of the generic this name is written inside,
  # which are names it may use and nobody else may.
  private def self.nameable?(name : String, root : String,
                             bound : Array(String)? = nil) : Bool
    # A module used as a *value* prints `Random::Secure:Module`, and there is
    # no source that spells it. `Random::Secure` is `module Secure; extend
    # self; include Random; end` and `Random#split` answers `(Random::PCG32 |
    # Random::Secure:Module)`; written into a declaration it stopped the
    # consumer's parser on `expecting token ')', not 'Module'`. The scan below
    # let it past because it reads `Secure` and `Module` as two names and both
    # are nameable on their own.
    #
    # One colon, not two: `Foo::Module` is a type somebody could declare.
    return false if module_valued?(name)

    Rx.scan(name, BIND_TYPE_NAME).all? do |match|
      part = match[0].not_nil!
      next true if part == "class" # `Exception.class` is read as its own name
      next true if bound && bound.includes?(part)
      # `&handler : Context -> _` names one type and one *absence* of one. The
      # scan above reads `_` as a name because a name may start with one, and
      # answering "no program can write that" dropped every method whose block
      # returns whatever the block returns — `Kemal::RouteHandler#add_route`,
      # which the whole DSL is written on top of.
      next true if part == "_"
      nameable_name?(part, root)
    end
  end

  # Whether this printed type holds a module used as a value. See `nameable?`.
  private def self.module_valued?(name : String) : Bool
    index = 0
    while (found = name.index(":Module", index))
      return true if found == 0 || name[found - 1] != ':'
      index = found + 1
    end
    false
  end

  private def self.nameable_name?(name : String, root : String) : Bool
    return true if name == root || name.starts_with?("#{root}::")
    bare = name.lchop("::")
    # The shard's own, written the way the shard wrote it. A restriction
    # naming a *generic* keeps its source text — `Radix::Tree(T)` writes
    # `private def find(path, result : Result, node : Node, first = false)`
    # and `Result(T)` resolved is a `T` nobody declares — and this file's
    # declarations are written relative to the root, so a bare `Result` is
    # the name a reader of them resolves. Asked only of the qualified form,
    # the method was dropped and the public `find` that travels called it:
    # `no parameter named 'first'`, inside a body the consumer never wrote.
    return true if @@declared.includes?("#{root}::#{bare}")
    @@builtin.includes?(bare) || @@bound.includes?(bare) || @@crystal_types.includes?(bare)
  end

  # Only the types the shard declares. A type it merely reopened belongs to
  # somebody else, and R-3 is what refuses to carry it here.
  private def self.collect_bind(types : Hash(String, Type)?, root : String,
                                methods : Array(BindMethod)) : Nil
    return unless types

    types.each_value do |type|
      next unless type.is_a?(NamedType)
      name = type.to_s
      next unless name == root || name.starts_with?("#{root}::")

      each_bind_def(type) { |a_def| methods << classify_bind(type, a_def) }
      each_bind_def(type.metaclass) { |a_def| methods << classify_bind(type.metaclass, a_def) }

      collect_bind type.types?, root, methods
    end
  end

  # The file a member was *written* in, following a macro back to its source.
  #
  # A `macro finished` block declares `@cached_route_lookup` inside kemal's own
  # `ext/context.cr`, and the location of what it declares is a `VirtualFile` —
  # the expansion — rather than that file. Asked naively, the shard's own
  # members look like nobody's: the ivar did not travel, and the consumer was
  # left to infer it from the bodies, which is `inferred to be Nil, but Nil
  # alone provides no information`. The same is true of every `def` a macro
  # writes, which for kemal is `get`, `post` and the rest of the DSL.
  #
  # `Location#expanded_location` is the walk, and it already exists for this.
  private def self.written_in(location : Location?) : String?
    return nil unless location
    location.expanded_location.try(&.filename).as?(String)
  end

  # What the shard added to types it does not own.
  #
  # A boundary carries none of the library's types on purpose — the consumer
  # replays the requires and has them, and declaring one a second time is how a
  # build stops on `superclass mismatch` — so an addition to one had nowhere to
  # go. Kemal reopens `HTTP::Server::Context` and gives it `@params` and the
  # methods that read it: the consumer said `undefined method 'params'`, and
  # the shard's own compiled code read a field the consumer never allocated,
  # which is a segfault several handlers into a request.
  #
  # What crosses is what the shard *wrote*, decided by where each member is —
  # the same test `library_type?` makes of a type, asked of its members. The
  # library's own stay behind, because the consumer has them.
  #
  # With bodies. These methods are compiled into the *library's* unit, not the
  # shard's, and a boundary carries the shard's; so there is no symbol to call
  # and the consumer compiles them, exactly as it does a top-level `def`.
  private def self.reopened_types(program : Program, root : String) : Array(IyiMod::TypeDecl)
    declarations = [] of IyiMod::TypeDecl
    source = program.filename
    return declarations unless source.is_a?(String)
    directory = directory_of(source)
    return declarations if directory.empty?

    library = library_root(program)
    return declarations unless library

    collect_reopened program.types?, directory, library, root, declarations
    declarations
  end

  private def self.collect_reopened(types : Hash(String, Type)?, directory : String,
                                    library : String, root : String,
                                    declarations : Array(IyiMod::TypeDecl)) : Nil
    return unless types

    types.each_value do |type|
      next unless type.is_a?(NamedType)
      name = type.to_s

      # The shard's own types travel as themselves; this is about everyone
      # else's. `root` is the shard's namespace and the prelude's builtins are
      # nobody's to reopen.
      unless name == root || name.starts_with?("#{root}::")
        declaration = top_level_alias(type, directory) ||
                      reopened_declaration(type, directory, library, root)
        declarations << declaration if declaration
      end

      collect_reopened type.types?, directory, library, root, declarations
    end
  end

  # A name the shard wrote outside its own namespace, which is a name a
  # program that requires it has.
  #
  # `validator` ends its file with `alias Valid = Validator`, and every call
  # in an application is written `Valid.email?`. Nothing carried it: the walk
  # that collects declarations starts at the shard's root, and this one is
  # beside it. So a boundary that had every method of the shard answered
  # `undefined constant Valid` at the first call site.
  #
  # Written `::Valid` — this is the top level and not the artifact's module —
  # and with the right-hand side resolved, for the reason every other type in
  # this file is: it is read where the shard was not.
  private def self.top_level_alias(type : Type, directory : String) : IyiMod::TypeDecl?
    return nil unless type.is_a?(AliasType)
    return nil unless type.namespace.is_a?(Program)

    written = type.locations.try(&.compact_map { |at| at.filename.as?(String) })
    return nil unless written.try(&.any?(&.starts_with?(directory)))

    # And this root's own only. A shard's files are read once per root it
    # declares, so a name written beside both — `alias Handy = Shard` in a
    # shard that also declares `Sidecar` — crossed in each artifact, and a
    # program importing both was told twice: `alias ::Handy is already
    # defined`. The alias belongs to whichever boundary carries what it
    # names.
    aliased = type.aliased_type.devirtualize.to_s
    return nil unless aliased == @@root || aliased.starts_with?("#{@@root}::")

    IyiMod::TypeDecl.new(
      name: "::#{type.to_s}",
      kind: "alias",
      type_parameters: [] of String,
      assoc_types: [] of String,
      supertraits: [] of String,
      fields: [] of {String, String, String},
      methods: [] of IyiMod::Signature,
      visibility: "",
      value: type.aliased_type.devirtualize.to_s,
    )
  end

  # One `lib` of the library's, with only what the shard put in it.
  #
  # `openssl_ext` reopens `lib LibCrypto` and adds a dozen C structs, two
  # unions and a handful of `type` aliases. A consumer said `"open_s_s_l"
  # numbers `Pointer(LibCrypto::Bignum)`, and this build cannot name it`: the
  # shard's object code refers to that type's id, the id is resolved from a
  # definition in the consumer's program, and the consumer had never heard of
  # the type.
  #
  # Types only. A `fun` is a C symbol — `BN_new` is resolved by the system
  # linker against `-lcrypto`, not by anything either side compiles — so a
  # consumer that does not call one itself needs no declaration for it. What it
  # needs is to be able to *name* the types, because naming is what numbering
  # is made of.
  private def self.reopened_lib(type : NamedType, directory : String,
                                library : String) : IyiMod::TypeDecl?
    return nil unless type.responds_to?(:locations)
    locations = type.locations
    return nil unless locations
    files = locations.compact_map { |location| location.filename.as?(String) }
    return nil unless files.any? &.starts_with?(directory)
    owned = !files.any?(&.starts_with?(library))

    # The library's half is not required, and requiring it was the bug. A
    # `lib` the shard wrote *entirely* is still a top-level name a boundary
    # rooted at `SQLite3` cannot reach — the same position kemal's `get` and
    # `post` are in, one kind of declaration over. `sqlite3` writes `lib
    # LibSQLite3` beside `module SQLite3`, and its `REGEXP_FN` is a proc whose
    # type names `LibSQLite3::SQLite3Context`; the constant was dropped as a
    # value the consumer could not name, and the consumer said `undefined
    # constant ::SQLite3::REGEXP_FN`.
    #
    # What travels is the same either way: the members written under
    # *directory*. For a `lib` the shard shares that is what it added, and for
    # one it owns outright that is all of it.
    nested = [] of IyiMod::TypeDecl
    constants = [] of {String, String}
    type.types?.try &.each do |simple, member|
      next unless member.is_a?(NamedType)
      next unless written_in(member.locations.try(&.first?)).try &.starts_with?(directory)

      case member
      when Const
        # A `lib` holds constants too, and a body that travels reads them:
        # `LibCrypto.evp_pkey_assign(pkey, LibCrypto::EVP_PKEY_RSA, …)` is in
        # `openssl_ext`'s `RSA.new`. `6` where the shard wrote `6` — see
        # `Const#iyi_value_source` for why the node is not that by now.
        written = member.iyi_value_source
        constants << {simple, written.empty? ? member.value.to_s : written}
      when TypeDefType
        nested << IyiMod::TypeDecl.new(
          name: simple, kind: "type",
          type_parameters: [] of String, assoc_types: [] of String,
          supertraits: [] of String, fields: [] of {String, String, String},
          methods: [] of IyiMod::Signature, visibility: "",
          value: member.typedef.to_s,
        )
      when EnumType
        # A `lib` takes an `enum` too, and a `fun` beside it takes one as a
        # parameter: `EC_POINT_point2oct(… form : PointConversionForm …)`. Not
        # `pub` and not `private` either, like everything else in here: a `lib`
        # is not a surface, and neither word is one its body takes.
        nested << enum_declaration(simple, member, true).copy_with(visibility: "")
      when AliasType
        # A `lib` takes both spellings and they are different things: `type` is
        # a distinct type with the same layout, `alias` is another name for the
        # same one. `openssl_ext` writes `alias PasswordCallback = (LibC::Char*,
        # LibC::Int, LibC::Int, Void*) -> LibC::Int` and calls it by name from a
        # body that travels, so a consumer without it said `undefined constant
        # LibCrypto::PasswordCallback`.
        nested << IyiMod::TypeDecl.new(
          name: simple, kind: "alias",
          type_parameters: [] of String, assoc_types: [] of String,
          supertraits: [] of String, fields: [] of {String, String, String},
          methods: [] of IyiMod::Signature, visibility: "",
          value: member.aliased_type.to_s,
        )
      else
        fields = [] of {String, String, String}
        if member.is_a?(InstanceVarContainer)
          member.instance_vars.each do |field, variable|
            # `@` off: a `lib` struct writes its fields as plain names, which is
            # what the shard wrote and what the far side has to parse back.
            fields << {field.lchop('@'), variable.type?.try(&.devirtualize.to_s) || "?", ""}
          end
        end
        next if fields.empty?
        nested << IyiMod::TypeDecl.new(
          name: simple, kind: member.type_desc,
          type_parameters: [] of String, assoc_types: [] of String,
          supertraits: [] of String, fields: fields,
          methods: [] of IyiMod::Signature, visibility: "",
        )
      end
    end

    funs = collect_funs(type, directory, type)
    return nil if nested.empty? && funs.empty? && constants.empty?

    IyiMod::TypeDecl.new(
      # `::` either way, and the *same name the producer used*, because that is
      # what a symbol is made of. A `lib` the shard owns was declared inside
      # the module for a while — which let its funs name the shard's own types
      # and put the lib inside the shard's namespace, so the producer emitted
      # `*SQLite3::Connection#to_unsafe:LibSQLite3::SQLite3` and the consumer
      # asked for `…:SQLite3::LibSQLite3::SQLite3`. The same method, two names.
      # A lib needs both things and the name is the one that cannot move.
      name: "::#{type}",
      kind: "lib",
      type_parameters: [] of String,
      assoc_types: [] of String,
      supertraits: [] of String,
      fields: [] of {String, String, String},
      methods: [] of IyiMod::Signature,
      # No `pub`: a `lib` is not a thing a consumer writes against, and this one
      # is the library's besides. It is here so the types can be named.
      visibility: "",
      types: nested,
      funs: funs,
      members: constants,
      # Only for a lib the shard owns. One the library also declares arrives
      # annotated on the consumer's side from its own `require`, and a second
      # copy would ask the linker for the same library twice.
      annotations: owned ? link_annotations(type) : [] of String,
    )
  end

  # A `lib`'s `@[Link]` annotations, written back as source.
  #
  # Rebuilt from what the compiler parsed rather than kept as text, because the
  # text is not kept: `LinkAnnotation` is what a `lib` carries. `pkg_config`
  # defaults to the library's name, so it is written only where it says
  # something the name does not.
  private def self.link_annotations(type : Type) : Array(String)
    return [] of String unless type.responds_to?(:link_annotations)

    # `written`, not `annotation`: the second is a keyword, and a statement
    # starting with it is read as a declaration — `can't define annotation
    # inside def`, from the parser rather than from anything about this code.
    (type.link_annotations || [] of LinkAnnotation).map do |written|
      parts = [] of String
      if name = written.lib
        parts << name.inspect
        pkg = written.pkg_config
        parts << "pkg_config: #{pkg.inspect}" if pkg && pkg != name
      elsif pkg = written.pkg_config
        parts << "pkg_config: #{pkg.inspect}"
      end
      written.ldflags.try { |flags| parts << "ldflags: #{flags.inspect}" }
      written.framework.try { |framework| parts << "framework: #{framework.inspect}" }
      written.wasm_import_module.try { |module_name| parts << "wasm_import_module: #{module_name.inspect}" }
      written.dll.try { |dll| parts << "dll: #{dll.inspect}" }
      parts << "static: true" if written.static?

      "@[Link(#{parts.join(", ")})]"
    end
  end

  # The `fun`s a shard added to a `lib`, as the lines that declare them.
  #
  # Written out rather than translated: see `IyiMod::TypeDecl#funs` for why
  # they travel and why they travel as text. The restrictions are the shard's
  # own words, which is right — they are rendered back inside `lib
  # ::LibCrypto`, where `Bio*` means what it meant where it was written.
  private def self.collect_funs(type : NamedType, directory : String,
                                owner : NamedType? = nil) : Array(String)
    funs = [] of String
    return funs unless type.responds_to?(:defs)

    type.defs.try &.each_value do |overloads|
      overloads.each do |entry|
        a_def = entry.def
        next unless a_def.is_a?(External)
        # An external *variable* — libc's `$errno` — is not a `fun` and does
        # not render as one.
        next if a_def.external_var?
        next unless written_in(a_def.location).try &.starts_with?(directory)

        funs << render_fun(a_def, owner)
      end
    end

    funs.sort!
    funs
  end

  # `fun bn_new = BN_new : Bignum*`, as Crystal writes one.
  #
  # The Crystal name is dropped where it is the C name already, which is what
  # the shard wrote and the only spelling with nothing redundant in it.
  private def self.render_fun(a_def : External, owner : NamedType? = nil) : String
    String.build do |io|
      io << "fun " << a_def.name
      io << " = " << a_def.real_name unless a_def.name == a_def.real_name

      unless a_def.args.empty? && !a_def.varargs?
        io << '('
        a_def.args.join(io, ", ") do |argument, inner|
          # The restriction where the node still has one, and the type it
          # resolved to where it does not. An `External`'s args come out of
          # semantic typed and, for some of them, stripped: `fun asn1_dup =
          # ASN1_dup(i2d : Void*, ...)` reached this with three empty
          # restrictions and rendered `(i2d : , ...)`.
          written = argument.restriction || argument.type?
          # A `fun` parameter may have no name — `fun backup_finish =
          # sqlite3_backup_finish(SQLite3Backup)` is how `sqlite3` writes half
          # of them — and a name is not what a C call needs. Written with the
          # colon anyway it is `unexpected token: ":"`.
          inner << argument.name << " : " unless argument.name.empty?
          inner << fun_type(written.to_s, argument.type?, owner)
        end
        io << ", ..." if a_def.varargs?
        io << ')'
      end

      if return_type = a_def.return_type
        io << " : " << fun_type(return_type.to_s, a_def.type?, owner, returns: true)
      end
    end
  end

  # One type in a `fun` signature, written so the top level can read it.
  #
  # A shard-owned `lib` is declared where the shard declared it — outside the
  # artifact's module, because its name is what the producer's symbols are made
  # of — and out there the shard's own namespace does not exist. `sqlite3`
  # writes `fun open_v2 = sqlite3_open_v2(… flags : SQLite3::Flag …)`, and a
  # top-level `lib` naming that is `undefined constant SQLite3::Flag`.
  #
  # An enum is the case that arises and it costs nothing to answer: what a C
  # function takes is the integer, and Crystal's own rule converts an enum to
  # its base type at a `fun` call without being asked — so a caller inside the
  # module goes on writing `SQLite3::Flag::ReadWrite`. Anything else the top
  # level cannot name is left as written — if that ever happens it should say
  # so at the far side rather than be guessed at here.
  #
  # **The return side is not the same answer.** What a C function *takes* is
  # the integer, and Crystal's own rule converts an enum to it without being
  # asked, so a parameter is written as the base type and a caller inside the
  # module goes on writing `SQLite3::Flag::ReadWrite`. What a `fun` *answers*
  # is read by the shard's own code as the enum it declared: `fun column_type =
  # sqlite3_column_type(…) : ::SQLite3::Type` crossing as `Int32` gave a body
  # compiled on the far side an integer, and `case column_type(self, col) when
  # Type::TEXT` then matched nothing and took the `else` — `another row
  # available`, on the first query a consumer ran through `sqlite3`.
  #
  # So the enum is named, globally. Not as written — `::SQLite3::Type` is
  # stripped of the root on the way out and would become the global `::Type` —
  # and not relative either: a shard's `lib` is declared at the top level,
  # because its name is what the producer's symbols are made of, and a name
  # looked up in there does not reach the module's own scope, so `Type` is
  # `undefined constant` and `SQLite3::Type` was too. `::` in front is the one
  # spelling that resolves from where the `lib` sits.
  # `bench/bind_roundtrip.sh` holds it: a module's body cases on
  # `LibShardSign.magnitude`, and with the base type back the two arms answer
  # `many` where they answer `one` and `two`.
  private def self.fun_type(written : String, type : Type?, owner : NamedType?,
                            returns : Bool = false) : String
    return written unless owner
    return written unless type

    inside = type.instance_type
    return written unless inside.is_a?(EnumType)
    # The lib's own enums are declared with it and resolve beside it.
    return written if inside.to_s.starts_with?("#{owner}::")

    returns ? "::#{inside}" : inside.base_type.to_s
  end

  # One library type, with only what the shard put in it.
  private def self.reopened_declaration(type : NamedType, directory : String,
                                        library : String,
                                        root : String) : IyiMod::TypeDecl?
    return nil unless type.is_a?(ClassType) || type.is_a?(ModuleType)
    return nil if type.is_a?(GenericType)

    # An enum, a `lib`, a `struct` inside one: each is a kind of type this
    # cannot reopen and none of them answers `instance_vars` — asking
    # `Number::RoundingMode` raised `BUG: doesn't implement instance_vars`,
    # which is the compiler saying the question was wrong rather than the
    # answer missing.
    return reopened_lib type, directory, library if type.is_a?(LibType)
    return nil if type.is_a?(EnumType)
    return nil if type.is_a?(TypeDefType)

    # Written in both places, which is what a reopening *is*.
    #
    # `library_type?` asks whether *every* location is the library's, because
    # it is deciding whether a type travels at all and a type both of them
    # touch counts as the shard's. This is the other half of that sentence: the
    # library declared it, the shard added to it, and what the shard added is
    # what has nowhere else to go.
    return nil unless type.responds_to?(:locations)
    locations = type.locations
    return nil unless locations
    files = locations.compact_map { |location| location.filename.as?(String) }
    return nil unless files.any? &.starts_with?(library)
    return nil unless files.any? &.starts_with?(directory)

    # A field the shard wrote `@store = {} of String => StoreTypes` has a
    # *default*, and the library's own `initialize` knows nothing about it: the
    # consumer said `this 'initialize' doesn't explicitly initialize instance
    # variable '@store'`. The default has to arrive with the field, and
    # `class_vars` is the triple that renders `name : type = value` — which for
    # a name beginning `@` is an instance variable declaration with a default,
    # exactly what the shard wrote.
    # The aliases the shard wrote inside this type, resolved.
    #
    # A default is stored as the text somebody typed, and kemal's is `{} of
    # String => StoreTypes` — where `StoreTypes` is an alias it declares inside
    # `Context` through the same `macro finished`. The consumer has no such
    # name and said `undefined constant StoreTypes`. Every other text in this
    # file is written with its names resolved for exactly this reason: it is
    # read where the shard was not.
    aliases = {} of String => String
    type.types?.try &.each do |simple, nested|
      next unless nested.is_a?(AliasType)
      next unless written_in(nested.locations.try(&.first?)).try &.starts_with?(directory)
      aliases[simple] = nested.aliased_type.devirtualize.to_s
    end

    defaults = {} of String => String
    if type.responds_to?(:instance_vars_initializers)
      type.instance_vars_initializers.try &.each do |initializer|
        written = initializer.written
        aliases.each { |simple, resolved| written = replace_word written, simple, resolved }
        defaults[initializer.name] = written
      end
    end

    fields = [] of {String, String, String}
    defaulted = [] of IyiMod::ClassVarDecl
    if type.is_a?(InstanceVarContainer)
      type.instance_vars.each do |field, variable|
        filename = written_in variable.location
        next unless filename && filename.starts_with?(directory)
        # No filter on the name. A field's type may be another boundary's —
        # `Radix::Result` is — and what makes that writable is the mapping
        # below, not this loop. Dropping one here left the consumer to infer it
        # from the bodies instead, which is `@cached_route_lookup was inferred
        # to be Nil, but Nil alone provides no information`: a field that does
        # not travel is worse than one that travels needing a name, because the
        # second says so.
        written = variable.type?.try(&.devirtualize.to_s) || "?"
        # In place, for the reason `IyiMod::TypeDecl#fields` gives: a field's
        # position in the list is its position in the layout.
        fields << {field, written, defaults[field]? || ""}
      end
    end

    methods = [] of IyiMod::Signature
    each_bind_def(type) do |a_def|
      filename = written_in a_def.location
      next unless filename && filename.starts_with?(directory)

      method = classify_bind(type, a_def)
      next if method.uncompilable
      next if method.abstract_def
      body = method.body
      next if body.nil? || body.empty?

      signature = IyiMod::Signature.new(
        name: method.name,
        receiver: method.receiver,
        parameters: method.params.map { |(argument, restriction, default)| bind_parameter(argument, restriction, default) },
        block_parameter: method.written_block,
        # Empty always: the body is here, and it is what a call is typed from.
        # A written return would be the shard's word about a body the consumer
        # is compiling for itself, which is rule 1's own question.
        return_type: "",
        free_variables: method.free_vars,
        required: false,
      )
      methods << signature
      @@mono_bodies[IyiMod.mono_body_key("::#{type}", signature)] = travelling_body(body)
    end

    return nil if fields.empty? && defaulted.empty? && methods.empty?

    IyiMod::TypeDecl.new(
      # `::`, because this is the library's type and not a name relative to
      # anything this artifact declares.
      name: "::#{type}",
      kind: type.is_a?(ModuleType) && !type.is_a?(ClassType) ? "module" : "class",
      type_parameters: [] of String,
      assoc_types: [] of String,
      supertraits: [] of String,
      fields: fields,
      methods: methods,
      class_vars: defaulted,
    )
  end

  # The shard's own top-level `def`s.
  #
  # Not under `root`, which is why the walk above cannot find them: they are on
  # `Object`, where Crystal puts a `def` written outside every namespace. Kemal
  # writes `get`, `post` and `error` there — the whole DSL — and `Kemal.run`'s
  # own body reaches one through `setup_404`.
  #
  # The shard's, decided by where they are written, which is the same test
  # `library_type?` makes of a type: a `def` under the bound file's directory
  # is the shard's, and the prelude's thousands are not. Nothing else separates
  # them, because at this point they are all on the same type.
  private def self.collect_top_level(program : Program,
                                     methods : Array(BindMethod)) : Nil
    source = program.filename
    return unless source.is_a?(String)
    directory = directory_of(source)
    return if directory.empty?

    each_bind_def(program) do |a_def|
      filename = written_in a_def.location
      next unless filename && filename.starts_with?(directory)
      # A `fun` is not a `def`. `gcry` writes `fun gcry_mark_worker_main(arg :
      # Void*)` at its top level for a raw pthread to call, and the symbol is
      # the C name in this artifact's own object code - nothing outside names
      # it, and a `def` declaration of it asks the linker for a mangled name
      # nobody emitted.
      next if a_def.is_a?(External)
      methods << classify_bind(program, a_def)
    end
  end

  private def self.each_bind_def(type : Type, & : Def ->) : Nil
    defs = type.as?(ModuleType).try &.defs
    return unless defs

    defs.each_value do |list|
      list.each do |item|
        # The definitions this one *replaced*, oldest first.
        #
        # A redefinition does not sit beside the definition it replaces:
        # `add_def` puts the old one on `previous` and the hash holds one.
        # Crystal has a word for reaching it — `previous_def` — and `db` uses
        # it: `def_around_query_or_exec` is a macro that redefines
        # `around_query_or_exec` with a body calling what it replaced. Carrying
        # only the last is a body naming something the declarations do not
        # have, and a consumer said `there is no previous definition of
        # 'around_query_or_exec'`. `MonoBodies` keys them apart by ordinal.
        chain = [item.def] of Def
        walk = item.def.previous
        while walk
          chain.unshift walk.def
          walk = walk.def.previous
        end

        chain.each do |a_def|
          # `initialize` is not public — Crystal's own rule reaches it through
          # `new` — and
          # that is fine while `new` travels. It does not when it takes a block:
          # a synthesised `new`'s body is the compiler's, with a temporary for a
          # receiver, and no consumer can parse that back. So the one a consumer
          # needs in order to make its *own* `new` crosses instead, and only in
          # that case: declaring `initialize` beside a `new` that also travels
          # would be two ways to build the same type.
          # `initialize` is not public — Crystal's own rule reaches it through
          # `new` — and
          # whether it travels is the collectors' question, not this one. A
          # generic's `new` is never carried, so its `initialize` always is; a
          # plain type's travels only where its `new` could not.
          # And the ones a type keeps to itself, which a *generic's* travelling
          # bodies call: `Node(T)#initialize` calls `compute_priority`. Whether
          # they travel is the collectors' question — only the generic path takes
          # them, because only there is every body the consumer's to compile.
          next unless a_def.visibility.public? || a_def.name == "initialize" ||
                      a_def.visibility.private? || a_def.visibility.protected?
          # A method with no location is the compiler's own — `allocate` exists
          # on every type and nobody wrote it. A boundary carries what a shard's
          # author wrote, and `new` comes back through `initialize`.
          next unless a_def.location
          yield a_def
        end
      end
    end
  end

  # The abstract `def` this one answers, in a module the type includes or a
  # class it inherits from.
  #
  # An abstract def is a written signature, which is the one thing a shard's
  # own implementation is allowed to leave out: `HTTP::Handler` writes
  # `abstract def call(context : HTTP::Server::Context)` and kemal's handlers
  # write `def call(context) : Nil`. R-2 says this already for iyi's own impls
  # — "the trait already wrote the types down, and a consumer types the call
  # from the trait rather than from here" — and the same sentence is true of a
  # Crystal module's abstract method.
  #
  # Matched on name and arity only. Anything finer would be overload resolution
  # against a signature that by construction has no overloads to resolve
  # against: an abstract def is the one shape the ancestor demands.
  private def self.abstract_ancestor_def(owner : Type, a_def : Def) : Def?
    ancestors = owner.responds_to?(:ancestors) ? owner.ancestors : nil
    return nil unless ancestors

    ancestors.each do |ancestor|
      defs = ancestor.as?(ModuleType).try &.defs
      next unless defs
      defs[a_def.name]?.try &.each do |item|
        other = item.def
        next unless other.abstract?
        next unless other.args.size == a_def.args.size
        next if other.args.any? { |arg| arg.restriction.nil? }
        return other
      end
    end
    nil
  end

  # This def, with the types its ancestor wrote where the shard wrote none.
  #
  # A copy, because the tree belongs to the program being read and the rest of
  # this tool has to keep seeing what the shard actually wrote.
  private def self.with_ancestor_types(owner : Type, a_def : Def) : Def
    missing = a_def.args.any? { |arg| arg.restriction.nil? } || a_def.return_type.nil?
    return a_def unless missing
    other = abstract_ancestor_def(owner, a_def)
    return a_def unless other

    copy = a_def.clone
    copy.location = a_def.location
    copy.args.each_with_index do |arg, index|
      arg.restriction = other.args[index].restriction.try(&.clone) if arg.restriction.nil?
    end

    # And the return, for the reason the parameters take: the requirement
    # already wrote the type down, and an override is held to it.
    # `db` writes `abstract def build_unprepared_statement(query) : Stmt` and
    # `sqlite3` writes `def build_unprepared_statement(query)`, so a
    # declaration without the return said less than the language requires:
    # `this method overrides … which has an explicit return type of Stmt.
    # Please add an explicit return type to this method as well`.
    copy.return_type = other.return_type.try(&.clone) if copy.return_type.nil?
    copy
  end

  private def self.classify_bind(owner : Type, given : Def) : BindMethod
    a_def = with_ancestor_types(owner, given)

    verdict =
      if a_def.args.any? { |arg| arg.restriction.nil? }
        BindVerdict::NeedsHuman
      elsif a_def.return_type
        BindVerdict::Ready
      else
        BindVerdict::NeedsReturn
      end

    inferred = nil
    refused = nil
    checked = BindCheck::NotWritten
    produced = nil
    written = resolve_restriction(owner, a_def.return_type)
    # The same restriction, unqualified, for the comparison below. See
    # `resolve_restriction`.
    plain = resolve_restriction(owner, a_def.return_type, qualify: false)

    uncompilable = false
    # A method whose *types* the caller brings is not measured at all: its body
    # travels, and instantiating it here asks a question with no answer — see
    # `caller_shaped?`. Recording the failure is how two of `db`'s crossed
    # nothing: `ResultSet#read(type : DB::Mappable.class)` was "uncompilable"
    # because the synthetic call handed it the module itself, and
    # `BeginTransaction#transaction(& : Transaction -> T) : T?` because the
    # synthesised block's `T` is a name only a caller binds — `undefined
    # constant ::T`. Neither failure was the shard's.
    if a_def.free_vars.try { |free| !free.empty? } ||
       a_def.args.any? { |arg| metaclass_restriction?(arg.restriction) }
      # Nothing to ask.
    elsif verdict.needs_return?
      inferred, refused, uncompilable = infer_return(owner, a_def)
    elsif verdict.needs_human? && (a_def.block_arg || a_def.block_arity)
      # A method whose body travels is not blocked by an untyped parameter.
      #
      # The verdict above is about a *declaration a consumer typechecks a call
      # against*: a parameter with no type leaves it nothing to check. A method
      # that yields is not declared that way — the consumer compiles its body,
      # and the body is what types the call, exactly as it does for the shard's
      # own callers. So the question is not the parameter's, it is the block's,
      # and asking it means asking `instantiate`, which checks the block before
      # it looks at an argument and so never trips over the missing type.
      #
      # `Kemal.run(args = ARGV, trap_signal : Bool = true, &)` is the method
      # this is about: `args` is untyped, and the whole of running a kemal app
      # is behind it.
      _, refused, uncompilable = infer_return(owner, a_def)
    elsif written
      # The other half of rule 1. A method that writes its return type was
      # copied out verbatim and never instantiated, so nothing ever held the
      # two against each other — and a written restriction is not the answer a
      # caller gets. Crystal narrows it to what the body produced: `def f :
      # String?` whose body returns a `String` types its call `String`, not
      # `String?`. A consumer told the union holds one where the object code
      # answers a bare pointer, which is rule 1's "returns something of another
      # type" exactly. So ask this half the question the other half answers.
      produced, refused, uncompilable = infer_return(owner, a_def)
      checked =
        if a_def.abstract?
          BindCheck::Dispatched
        elsif produced.nil?
          BindCheck::Unchecked
        elsif produced == plain
          BindCheck::Agrees
        else
          BindCheck::Disagrees
        end
      produced = nil unless checked.disagrees?
      if checked.dispatched?
        refused = nil
        uncompilable = false
      end
    end

    BindMethod.new(
      owner: owner.to_s,
      name: a_def.name,
      verdict: verdict,
      block: !a_def.block_arg.nil? || !a_def.block_arity.nil?,
      untyped: a_def.args.select(&.restriction.nil?).map(&.name),
      location: a_def.location.try(&.to_s) || "?",
      inferred: inferred,
      refused: refused,
      # As written, not as instantiated: see `Program#iyi_def_bodies`.
      # As written, not as instantiated: see `Program#iyi_def_bodies`.
      body: a_def.location.try { |at| owner.program.iyi_def_bodies[Program.iyi_def_body_key(at, a_def.name)]? } ||
            a_def.body.to_s,
      abstract_def: a_def.abstract?,
      answers_abstract: !a_def.abstract? && !abstract_ancestor_def(owner, a_def).nil?,
      free_vars: a_def.free_vars || [] of String,
      written: written_in(a_def.location) || "",
      # Protected counts as private here: both are names a travelling body may
      # call and a consumer may not write, and `protected def sort!` is one
      # `Radix::Node(T)#add` calls.
      private_def: a_def.visibility.private? || a_def.visibility.protected?,
      uncompilable: uncompilable,
      # Three ways of saying the same thing: nobody wrote the block's shape, so
      # what this method returns depends on the caller and the body has to
      # travel. The third is `&` — or a bare `yield` — which names no block
      # parameter at all, and which is how Crystal's own libraries are written
      # far more often than the annotated form.
      # And a fourth, which is not about blocks: the shard alone does not know
      # what the method returns.
      #
      # `db` is an interface library. `DB.open(uri)` ends in
      # `Database.new(connection_options, pool_options, &factory)`, and the
      # options come off a `DB::Driver` — abstract, with no implementor until
      # a program requires `pg` beside it. Compiled alone the call has no type
      # at all, so there is nothing to declare *and nothing to emit*: the
      # producer cannot compile that method either, and a declaration naming a
      # symbol its own object code lacks is a link error waiting for the first
      # consumer. It was dropped, and an application said
      # `'DB.open' is expected to be invoked with a block, but no block was
      # given` — the block-taking overload beside it was the only one left.
      #
      # The body is the answer for the same reason it is for a block: the
      # program that calls this has the driver, so the consumer's own compiler
      # can type what the producer's could not. If it cannot, it says so on the
      # method's own source rather than on a name that went missing.
      #
      # And a fifth, which is the same sentence about a *parameter*: the shard
      # alone does not have the type its own signature names.
      # `exception_page` writes `def self.new(context : HTTP::Server::Context,
      # exception : Exception)` and requires no `http` — the consumer of an
      # exception page is a web application, so the name is one every caller
      # has and this build has not. Instantiating it is refused here, and the
      # method was dropped: `Kemal::ExceptionPage` inherits it, `render_500`
      # calls it, and a consumer compiling that body got `wrong number of
      # arguments for 'Kemal::ExceptionPage.new' (given 2, expected 4..10)` —
      # the synthesised `new` was the only one left. The parameter travels as
      # the text the shard wrote, which is what III.6 rule 1 means by a
      # binding that asserts.
      body_answers: setter_body?(a_def) || delegating_overload?(a_def) ||
                    caller_shaped?(a_def) ||
                    (refused == "block returns `_`" ||
                     refused == "block is not annotated" ||
                     refused == "yields without a block parameter" ||
                     refused == "no type" ||
                     refused.try(&.starts_with?("cannot resolve ")) ||
                     uncompilable) && !a_def.abstract? &&
                    !a_def.body.nil? && !a_def.body.is_a?(Nop),
      # The return type is asked the same question the parameters are. `Int` is
      # the head of a family on either side of the arrow, and a method that
      # answers one has a symbol per member exactly as a method that takes one
      # does. Asking it of the arguments alone was half the question.
      storable: a_def.args.all? { |arg| storable_restriction?(owner, arg.restriction) } &&
                (a_def.return_type.nil? || storable_restriction?(owner, a_def.return_type)),
      params: bind_params(owner, a_def),
      returns: written,
      checked: checked,
      produced: produced,
      receiver: a_def.receiver.try(&.to_s) || "",
      # `&block : Context -> B` travels as written. A block whose type nobody
      # wrote cannot: R-2 asks the block for its types like everything else.
      # An unannotated block is written back as the bare `&` it was. R-2 refuses
      # an *exported* signature without one because a consumer typechecking a
      # call needs the shape — and a method whose body travels hands the
      # consumer the body instead, which is the shape. `Kemal.run` is written
      # `def self.run(…, &)` and the whole of running a kemal app is behind it.
      # Resolved, like every parameter beside it. It was the one restriction
      # that travelled as *written*, and a name written in the shard's own
      # namespace is not a name the far side reads the same way: `db`'s
      # `Database#initialize(… &factory : -> Connection)` is `-> DB::Connection`
      # once resolved, and unresolved it failed the nameability test that
      # decides whether the method crosses at all — so the one `initialize`
      # a consumer needs to build a `Database` with was dropped, and the body
      # that calls `Database.new(…, &factory)` met a `new` that takes no block.
      written_block: a_def.block_arg.try do |argument|
        if restriction = argument.restriction
          "&#{argument.name} : #{resolve_block_restriction(owner, restriction)}"
        else
          "&#{argument.name}"
        end
      end || (a_def.block_arity ? "&" : ""),
    )
  end

  # Whether what this method *is* depends on the caller, so that its body is
  # the only honest declaration of it.
  #
  # The same question a block asks, asked of the arguments. A parameter with no
  # type, a splat, a double splat: each of them says the shard did not write one
  # signature, it wrote a family, and Crystal compiles a member of that family
  # per call site with the call site's types in the symbol. So there is no one
  # symbol in the artifact for a consumer to link against, and a declaration
  # without the body is a promise nothing can keep — which is what
  # `bench/bind_roundtrip.sh` has said about blocks since blocks first crossed.
  #
  # `JWT.encode(payload, key : String, algorithm : Algorithm, **header_keys) :
  # String` is the method this is about: the whole of making a token is behind
  # it, `payload` is whatever the caller has, and `**header_keys` is whatever
  # else they thought to name. R-2 refused it and the report asked a human to
  # annotate `payload` — but there is no annotation to write. The type is the
  # caller's.
  #
  # A body that is not there cannot travel, and an abstract def has none by
  # definition.
  private def self.caller_shaped?(a_def : Def) : Bool
    return false if a_def.abstract?
    body = a_def.body
    return false if body.nil? || body.is_a?(Nop)

    # A body that reads `$~` cannot travel, so a method that needs its body to
    # cross cannot cross at all. `$~` is the match the *last regex in this
    # method* set — scoped to the method, written by the compiler, and not a
    # name anybody declares: iyi's parser refuses it outright, `$global_variables
    # are not supported`. `backtracer` writes `def parse?(line : String,
    # **options)` and reads `$~["method"]` inside it, and the double splat is
    # what makes the body the only honest declaration of the method.
    #
    # Refused rather than mangled, and the report says which method: a
    # declaration nobody can parse is worse than one that is not there.
    written = body.to_s
    return false if written.includes?("$~") || written.includes?("$?")

    # A free variable says it too, in the plainest words the language has:
    # `def read(type : T.class) : T forall T` is one method per `T`, compiled
    # at the call site with the call site's type in the symbol. `db`'s
    # `ResultSet#read` is written that way and `query_one`'s body calls it, so
    # a consumer that had the declaration and not the body could not infer what
    # the block returns.
    return true if a_def.free_vars.try { |free| !free.empty? }

    # And a parameter that takes a *class* says the same thing without a free
    # variable to say it with. `db` writes `def read(type : DB::Mappable.class)`
    # and `def read(type : Enum.class)`; which class arrives is the caller's to
    # decide, there is one instantiation per class, and every one of them is in
    # a program the producer never sees. Measured here the first is
    # `read(DB::Mappable:Module)` — the module itself, which nothing can
    # instantiate — and the tool recorded the failure and dropped the method.
    #
    # What that cost is the whole of `DB::Serializable`: `rs.read(Row)` then
    # matched `read(type : T.class) : T forall T` instead, whose body reads one
    # column and raises when it is not a `Row`, so a query mapping rows into
    # structs typed `Array(NoReturn)` and the application would not compile.
    return true if a_def.args.any? { |arg| metaclass_restriction?(arg.restriction) }

    a_def.args.any? { |arg| arg.restriction.nil? } ||
      !a_def.splat_index.nil? || !a_def.double_splat.nil?
  end

  # `Foo.class`, or the head of every metaclass there is.
  private def self.metaclass_restriction?(restriction : ASTNode?) : Bool
    return false unless restriction
    return true if restriction.is_a?(Metaclass)
    restriction.is_a?(Path) && restriction.to_s == "Class"
  end

  # The parameters as the source wrote them, stars and all.
  #
  # `*args` and `**options` are not in `Def#args` the way they read: the splat
  # is an ordinary entry the index points at, and the double splat is beside
  # the list rather than in it. Written back without their stars they are two
  # plain parameters, which is a different method — it takes a different set of
  # calls, and `JWT.encode(payload, key, algorithm)` with `**header_keys`
  # flattened away refuses the call the README makes.
  private def self.bind_params(owner : Type, a_def : Def) : Array({String, String, String})
    params = a_def.args.map_with_index do |arg, index|
      # The external name in front of the internal one where they differ. A
      # parameter may be called one thing by the caller and another inside the
      # method — `def query_one(query, *args_, as type : Class)` is written
      # `as: String` at the call site — and writing only the internal name is a
      # different method: `no overload matches 'DB::Database#query_one' with
      # types String, Int32, as: String.class`, with three overloads listed and
      # every one of them naming the parameter `type`.
      written = arg.external_name == arg.name ? arg.name : "#{arg.external_name} #{arg.name}"
      name = index == a_def.splat_index ? "*#{written}" : written
      {name, resolve_restriction(owner, arg.restriction) || "?",
       arg.default_value.try(&.to_s) || ""}
    end

    if double_splat = a_def.double_splat
      params << {"**#{double_splat.name}",
                 resolve_restriction(owner, double_splat.restriction) || "?", ""}
    end

    params
  end

  # Whether this overload's whole job is to call another of the same name.
  #
  # `Kemal.run` is written four times. Two take a block and cross because a
  # block's shape is the body's to say; the other two are
  # `def self.run(args = ARGV, trap_signal : Bool = true)`, whose body is
  # `run(nil, args: args, trap_signal: trap_signal)` — they fill in a default
  # and delegate. R-2 refuses them for `args`, and R-2's own reason does not
  # apply: a consumer typechecks a call *through* a travelling body, exactly as
  # the shard's own callers do, and this body is one line naming a method that
  # is already crossing.
  #
  # So `Kemal.run` is what a kemal program writes, rather than `Kemal.run { }`.
  #
  # Narrow on purpose. "An untyped parameter is no reason to refuse a method
  # whose body travels" is the general form of this, and it is a much larger
  # claim: it would send a body for every method a shard left untyped, each one
  # a piece of source the consumer has to compile and each one able to name
  # something that did not cross. This is the shape that shows up in a library's
  # own API — the overload that exists to be convenient — and widening it is a
  # measurement nobody has made yet.
  private def self.delegating_overload?(a_def : Def) : Bool
    return false if a_def.block_arg || a_def.block_arity
    return false if a_def.splat_index || a_def.double_splat
    return false unless a_def.args.any? { |arg| arg.restriction.nil? }

    body = a_def.body
    body = body.expressions.first? if body.is_a?(Expressions) && body.expressions.size == 1
    return false unless body.is_a?(Call)
    return false unless body.obj.nil?
    body.name == a_def.name
  end

  # Whether this is a setter whose answer is the value it was handed.
  #
  # `property thing : Thing?` writes `def thing=(@thing : Thing?)`, whose body
  # is `@thing = thing` — and an assignment's type is what was assigned, so the
  # shard's own callers get `Thing` from `config.thing = Thing.new`. A single
  # return annotation cannot say that: written `: (Thing | Nil)` it is right for
  # the declaration and wrong for every call, and `config.server ||=
  # HTTP::Server.new(…)` in `Kemal.run`'s own body came out nilable and stopped
  # the consumer on `undefined method 'each_address' for Nil`.
  #
  # R-2 says this already — "a setter answers what it was handed" is why one is
  # exempt from writing a return type. What it did not have was a way to carry
  # the answer, and that is the same way every other caller-dependent answer
  # travels: the body goes, and the consumer compiles it.
  #
  # The shape is exactly `property`'s, asked of the tree rather than of the
  # name: one parameter, and a body that is one assignment to an instance
  # variable. A setter that computes something is a method like any other.
  private def self.setter_body?(a_def : Def) : Bool
    return false unless a_def.name.ends_with?('=')
    return false unless a_def.args.size == 1
    return false if a_def.block_arg || a_def.block_arity
    body = a_def.body
    body = body.expressions.first? if body.is_a?(Expressions) && body.expressions.size == 1
    return false unless body.is_a?(Assign)
    body.target.is_a?(InstanceVar)
  end

  # The type a restriction names, rather than the text somebody typed.
  #
  # A method inside `JSON::Token` writes `kind : Kind`, and reading that as
  # written makes `Kind` a type nobody has declared — when it is
  # `JSON::Token::Kind`, the shard's own, already travelling. Every such
  # spelling inflated the count of what a boundary waits on, and inflated it in
  # one direction: *towards the core*, which is the claim the count was being
  # used to support. `self` is the same mistake with a shorter name — a method
  # returning `self` in `URI` returns `URI` and waits for nobody.
  #
  # A consumer is the other reason. It writes against this boundary from
  # outside, where `Kind` names nothing; a declaration that travels has to say
  # what it means from there.
  #
  # Resolution can fail — a free variable, `_`, a restriction this scope cannot
  # see — and then the written text stands, which is what this did for
  # everything before.
  # A block's annotation, resolved but still written as an arrow.
  #
  # `resolve_restriction` answers with the *type*, and a resolved proc type
  # prints `Proc(DB::Connection, Nil)` where the shard wrote `Connection ->
  # Nil`. Both name the same thing and only one of them is a block shape: the
  # keep file reads the arrow to know how many parameters to write, and
  # `synthesize_block` needs a `ProcNotation` to make a call out of. Handed the
  # `Proc` form, the keep file counted the output as an input and wrote
  # `{ |b115, b116| nil }` for a block that yields one — `wrong number of block
  # parameters (given 2, expected 1)`.
  #
  # So each side of the arrow is resolved on its own and the arrow is written
  # back. A bare name with no arrow is not a block shape and goes the ordinary
  # way.
  private def self.resolve_block_restriction(owner : Type, node : ASTNode) : String
    return resolve_restriction(owner, node).to_s unless node.is_a?(ProcNotation)

    inputs = (node.inputs || [] of ASTNode).map { |input| resolve_restriction(owner, input).to_s }
    output = node.output.try { |type| resolve_restriction(owner, type).to_s }
    "#{inputs.join(", ")} -> #{output}".strip
  end

  # *qualify* writes a shadowable name absolutely. Off where the answer is
  # about to be *compared* with an inferred one: an inferred type prints
  # `String` and a qualified restriction prints `::String`, and held against
  # each other those read as a disagreement — `Narrow#exact`, which writes
  # exactly what it answers, was reported as crossing on its answer instead.
  private def self.resolve_restriction(owner : Type, node : ASTNode?,
                                       qualify = true) : String?
    return nil unless node
    written = node.to_s
    return written if written == "_"
    return owner.instance_type.devirtualize.to_s if node.is_a?(Self)

    # `Foo.class` resolves to a type whose name is the compiler's own spelling
    # — `DB::Mappable:Module`, `Enum:Class` — and no source can carry that. So
    # the metaclass is written back the way it was written down, over an
    # instance name resolved like any other. `db` writes `def read(type :
    # DB::Mappable.class)`, which is how a row becomes a struct, and it
    # crossed as a parameter nothing could parse.
    if node.is_a?(Metaclass)
      inner = resolve_restriction(owner, node.name, qualify)
      return inner ? "#{inner}.class" : written
    end

    type = owner.lookup_type?(node)
    return written unless type
    # A free variable is a name this method binds, not one anybody declares.
    return written if type.is_a?(TypeParameter)

    # And a bare generic is a name too. `private def
    # perform_exec_and_release(args : Enumerable)` means "any Enumerable", and
    # the type it resolves to prints `Enumerable(T)` — with a `T` that is the
    # *method's* free variable and is declared nowhere a reader can see:
    # `undefined constant T`. What the shard wrote is what a reader can read.
    return written if type.is_a?(GenericType)

    # Written `::Log` where a bare `Log` would find the shard's own. See
    # `global_name`.
    resolved = type.devirtualize.to_s
    qualify ? global_name(resolved, @@root) : resolved
  rescue
    node.to_s
  end

  # Whether a variable could have the type this restriction names.
  private def self.storable_restriction?(owner : Type, node : ASTNode?) : Bool
    return false unless node
    type = owner.lookup_type?(node)
    return false unless type
    instance = type.instance_type
    return false if instance.is_a?(GenericClassType)
    instance.can_be_stored?
  rescue
    false
  end

  # What a caller of this method is handed.
  #
  # Not what the shard wrote, which is a different question and the one the
  # written half used to answer with its own premise: Crystal narrows a return
  # restriction to what the body produced, so this can disagree with a `def`
  # that spells its return out. Both halves ask it now.
  private def self.infer_return(owner : Type, a_def : Def) : {String?, String?, Bool}
    call, refused, uncompilable = instantiate(owner, a_def)
    return {nil, refused, uncompilable} unless call

    type = call.type?
    return {nil, "no type", false} unless type

    # `Foo+` is how a virtual type prints, and it is a fact about this build's
    # dispatch rather than a name anybody can write down. A declaration says
    # `Foo`, which is what the call site means and what parses.
    {type.devirtualize.to_s, nil, false}
  end

  # A block of the annotated shape, for a call nobody wrote.
  #
  # The arguments carry no types: a block literal takes them from the method
  # being called, which is the thing being instantiated. The body has to be of
  # the annotated output type, and `uninitialized` is how you name a value of a
  # type without building one — the same answer the keep file's text gives.
  private def self.synthesize_block(owner : Type, restriction : ASTNode) : Block?
    return nil unless restriction.is_a?(ProcNotation)

    inputs = restriction.inputs || [] of ASTNode
    args = inputs.map_with_index { |_, index| Var.new("__bind_b#{index}") }

    output = restriction.output
    body =
      if output.nil? || output.to_s == "Nil"
        NilLiteral.new
      else
        # Resolved against the owner, because the call this block goes into is
        # typed by a visitor whose scope is the *program*. `db` writes
        # `&factory : -> Connection` inside `DB`, and `uninitialized Connection`
        # visited at the top level is `undefined constant Connection` — which
        # this tool read as "the method does not compile" and dropped
        # `Database#initialize`, the one thing a consumer builds a `Database`
        # with.
        # Unqualified, because `global: true` is what makes this absolute and
        # the two together are one `::` too many: `::Int32` split on `::`
        # leaves an empty first segment, and the path printed `::::Int32`.
        written = resolve_restriction(owner, output, qualify: false) || output.to_s
        UninitializedVar.new(Var.new("__bind_block_result"), Path.new(written.split("::"), global: true))
      end

    Block.new(args, body)
  end

  # Instantiate a method nobody called, and hand back the call.
  #
  # This is the whole trick, and it is why a shard's untyped surface is not the
  # wall it looks like. Crystal types a method when something calls it, so a
  # library's own methods have no types until a program uses them — but a
  # method whose parameters are written down can be *called on purpose*, with
  # one synthesised argument per parameter, and the answer is the same answer a
  # real call would have produced.
  #
  # What it cannot do is written down beside what it can. A block is the honest
  # one: its type depends on what the caller passes, so there is no single
  # answer to read.
  # The third value says the refusal was the *compiler's* — the method does not
  # compile — as against this tool declining to ask. A method that cannot be
  # checked because its block is unannotated is fine and travels; one whose body
  # does not typecheck is not, and declaring it puts the failure in the keep
  # file, where it takes the whole artifact down with it.
  private def self.instantiate(owner : Type, a_def : Def) : {Call?, String?, Bool}
    # A block whose own type is written is not the problem; one whose output is
    # `_`, or which was never annotated, is. What such a method returns depends
    # on what the caller passes, and there is no single answer to read.
    block = nil
    if block_arg = a_def.block_arg
      restriction = block_arg.restriction
      return {nil, "block is not annotated", false} unless restriction
      return {nil, "block returns `_`", false} if restriction.to_s.includes?("_")

      # And then hand the call one, which this did not do.
      #
      # A method that takes a block is called *with* a block or it is not
      # called: `JSON::Builder#string` has an overload taking a value and one
      # taking a block, so a synthesised call with neither matched the first
      # and answered `wrong number of arguments (given 0, expected 1)`. The
      # method's own return type was then the one thing on the boundary
      # standing on the shard's word, which is the whole of what rule 1 is
      # about, over a block the annotation had already described.
      #
      # The keep file has written exactly this block as text since blocks
      # first crossed — `{ |b0| nil }`, or an `uninitialized` of the output
      # where the output is not `Nil`. This is the same block as a node.
      block = synthesize_block owner, restriction
      return {nil, "block shape not understood", false} unless block
    end
    return {nil, "yields without a block parameter", false} if a_def.block_arity && !a_def.block_arg
    return {nil, "splat", false} if a_def.splat_index || a_def.double_splat
    return {nil, "generic type", false} if owner.instance_type.is_a?(GenericType)
    return {nil, "abstract", false} if a_def.abstract?

    args = [] of ASTNode
    a_def.args.each do |arg|
      restriction = arg.restriction
      return {nil, "no restriction", false} unless restriction

      type = owner.lookup_type?(restriction)
      return {nil, "cannot resolve #{restriction}", false} unless type
      return {nil, "generic parameter", false} if type.is_a?(TypeParameter)

      # `Class` is every metaclass there is, and there is no end to them:
      # `Foo.class`, `Foo.class.class`, and so on for as long as anybody asks.
      # A real caller writes `Log.for(MyThing)` and names one; a call
      # synthesised here would hand the compiler the whole family and ask it to
      # enumerate them, which is `Log.for(type : Class)` recursing through
      # `Call#recalculate` until the stack ends. The `Program#iyi_instantiation_limit`
      # this tool sets is what turns that into a diagnosis rather than a crash;
      # this is what keeps it from being asked.
      return {nil, "unbounded receiver", false} if type == owner.program.class_type

      args << Var.new(arg.name).tap(&.set_type(type.virtual_type))
    end

    receiver = Var.new("self").tap(&.set_type(owner))
    call = Call.new(receiver, a_def.name, args, block)
    call.scope = owner
    # A block's body is code, and code is visited. A blockless call never
    # needed one and so this was never set; with a block attached the compiler
    # says so plainly — `Iyi::Call#parent_visitor cannot be nil`.
    call.parent_visitor = MainVisitor.new(owner.program)
    call.recalculate
    {call, nil, false}
  rescue ex : Iyi::CodeError
    {nil, ex.message.to_s.lines.first?.to_s, true}
  rescue ex
    {nil, ex.message.to_s.lines.first?.to_s, true}
  ensure
    # Whatever happened, this tool's next question starts from the top. An
    # instantiation that stopped part way — refused, or found not to terminate
    # — leaves the counter where it stopped, and the depth is per *question*.
    owner.program.iyi_instantiation_depth = 0
  end
end
