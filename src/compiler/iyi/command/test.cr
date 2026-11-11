require "../stale/runner"

# iyi: `iyi test` — the verify loop, with no framework to learn
# (AI_FIRST.md §2 #4).
#
# A test is a plain iyi program named `*_test.iyi`: it asserts by exiting
# non-zero, exactly the contract every gate in `bench/` already runs on,
# because this repository's own culture is the framework. No DSL, no
# registry — a program that prints what failed and exits 1 is a failing
# test, and one that exits 0 passed. The prelude's `assert` is that in one
# word, and `assert_eq` and its family say more of it: a failed check
# panics with the values and the site. `test "name" { }` runs named cases
# to the same exit code, so this verb still reads nothing but that.
#
#     iyi test              # every *_test.iyi under the current directory
#     iyi test dir file.iyi # these, recursing into directories
#     iyi test --json       # the run as data, for a harness
#     iyi test --affected FILE  # only tests whose imports reach FILE
#     iyi test --run TEXT   # only the named cases whose name holds TEXT
#     iyi test -p 1         # one test at a time
#
# A directory is walked as `fix` and `mod tidy` walk a module's source:
# not into a dot directory, `lib` (the installed dependencies, whose tests
# are theirs), a directory with a manifest of its own (another module), or
# a link.
#
# `--affected` is the edit loop's discount, and its rule is runtime truth,
# not a heuristic: a test is affected exactly when the changed file is in
# its transitive import closure — computed by parsing, never by compiling,
# because R-1 makes the import list syntax. Note what the rule is *not*:
# interface hashes. An edit that leaves a module's interface untouched
# still changes what a consumer's test executes, so "the surface did not
# move" exempts a consumer from *recompiling*, never from *re-running*.
# The closure is the whole answer, and it is exact.
#
# Each test builds and runs alone: one file, one process, one verdict — a
# crash, a panic and a deadlock are all failures that name their file. A
# test that neither exits nor fails is killed at the deadline (`--timeout`,
# 60 s default) with everything it started, because a harness that can
# hang is not a harness. Tests are independent programs, so half as many
# build and run at once as the machine has cores (`-p N` says otherwise), and
# the report is in file order whatever order they finished in.
#
# A named case (`test "name" { }`, testing.iyi) reports its verdict to the
# file IYI_TEST_REPORT names, so `--json` carries each case's verdict and
# its evidence as data rather than as lines in the output; IYI_TEST_RUN is
# how `--run` reaches the program.
#
# `--chaos` is for the bugs the compiler cannot rule out (SPEC.md
# III.4.17): it builds each test with `-Diyi_chaos` and runs it under the
# chaos scheduler once per seed - `--chaos-runs` of them, 100 unless told,
# from a seed drawn here, or exactly the one `--chaos=SEED` names - with
# `IYI_WORKERS=1` unless the environment sets it, so that every task runs
# on one thread and the seed alone decides the order. A test that fails
# on a seed is reported with it and stops there, and `--chaos=SEED` runs
# that schedule again.
class Iyi::Command
  # The longest `--timeout`: what Windows' waitable timer can count, in
  # 100 ns ticks held in an `Int64` - 922,337,203,684 s, some 29,000 years.
  # Past what the event loops' arithmetic holds a wait went wrong: 1e300
  # overflowed the span the wait becomes, and 9.3e14, 9.2e15 and 4.6e18
  # each hung a test that ends at once past a minute in one run on
  # Windows, and did not in the next.
  private MAX_TEST_WAIT = (Int64::MAX // 10_000_000 - 1).to_f

  # How many seeds `--chaos` runs a test under when not told.
  private CHAOS_RUNS = 100

  # One named case's verdict, as the program reported it (testing.iyi):
  # `ok`, `FAIL` or `skip`, and the panic's message or the reason to skip.
  private record TestCase, verdict : String, name : String, detail : String

  private alias TestResult = {file: String, status: String, seconds: Float64, output: String, seed: UInt64?, run: Int32, cases: Array(TestCase)}

  private def test
    as_json = false
    timeout = 60.0
    paths = [] of String
    affected = [] of String
    cached = false
    fresh = false
    explain = false
    shard = nil : String?
    import_indices = [] of String
    export_indices = [] of String
    chaos = false
    chaos_seed : UInt64? = nil
    chaos_runs : Int32? = nil
    # Half the cores: a test's build is some 200 MB and runs threads of its
    # own. 24 tests on 12 logical cores took 6.3 to 7.2 s at 12 at once, 7.4
    # to 7.6 s at 6 and 9.5 to 9.9 s at 4 (a non-release compiler), so the
    # other half bought a tenth of the time for twice the memory.
    parallel = (::System.cpu_count // 2).clamp(1, nil)
    parallel_given = false
    only : String? = nil
    verbose = false
    # What every test is built with beyond `build FILE -o BINARY`: the
    # flags a test can need to be built the way the program it tests is.
    build_flags = [] of String

    while option = options.shift?
      case option
      when "--json"
        as_json = true
      when "--timeout"
        value = options.shift?
        abort! "--timeout takes seconds", :USAGE_ERROR unless value
        timeout = value.to_f? || abort! "--timeout takes seconds, not '#{value}'", :USAGE_ERROR
        # `0` and `-1` were taken and every test came back "hung: killed
        # at -1.0s" - a verdict about the flag, printed as one about the
        # tests. A wait is a positive number of seconds, and one the clock
        # can count (`MAX_TEST_WAIT`): `1e300` overflowed the span it
        # becomes after the test was built, "Arithmetic overflow
        # (OverflowError)" and "you've found a bug in the iyi compiler", as
        # `inf` once did; `nan` is not a number of anything.
        unless timeout.finite? && timeout > 0 && timeout <= MAX_TEST_WAIT
          abort! "--timeout takes seconds to wait, and #{value} is not a wait", :USAGE_ERROR
        end
      when "--affected"
        # `.presence`: `--affected ""` is `"$FILE"` with `FILE` unset, and it
        # ran every test with " is not there" as the reason.
        value = options.shift?.presence
        abort! "--affected takes a changed file", :USAGE_ERROR unless value
        if Dir.exists?(value)
          abort! "#{value} is a directory, not a changed file", :USAGE_ERROR
        end
        affected << value
      when "--cached"
        cached = true
      when "--fresh"
        fresh = true
      when "--explain"
        explain = true
      when "--shard"
        value = options.shift?
        abort! "--shard takes K/N", :USAGE_ERROR unless value
        shard = value
      when "--import-index"
        value = options.shift?
        abort! "--import-index takes NS=FILE", :USAGE_ERROR unless value
        import_indices << value
      when "--export-index"
        value = options.shift?
        abort! "--export-index takes NS=FILE", :USAGE_ERROR unless value
        export_indices << value
      when "--chaos"
        chaos = true
      when .starts_with?("--chaos=")
        value = option.lchop("--chaos=")
        # A seed is what a failing run printed: decimal digits, all of it,
        # below 2^64. `to_u64?` alone would take a leading `+` and spaces
        # around the number, which no run prints.
        digits = !value.empty? && value.each_char.all?(&.ascii_number?)
        chaos_seed = (value.to_u64? if digits) || abort! "--chaos= takes a seed, a decimal number below 2^64, not '#{value}'", :USAGE_ERROR
        chaos = true
      when "--chaos-runs"
        value = options.shift?
        abort! "--chaos-runs takes a number of runs", :USAGE_ERROR unless value
        runs = value.to_i?
        unless runs && runs > 0
          abort! "--chaos-runs takes a number of runs, at least 1, not '#{value}'", :USAGE_ERROR
        end
        chaos_runs = runs
        chaos = true
      when "-p", "--parallel"
        value = options.shift?
        abort! "#{option} takes a number of tests to run at once", :USAGE_ERROR unless value
        count = value.to_i?
        unless count && count > 0
          abort! "#{option} takes a number of tests to run at once, at least 1, not '#{value}'", :USAGE_ERROR
        end
        parallel = count
        parallel_given = true
      when "--run"
        # Text, not a pattern: the program matches it, and the prelude
        # has no regular expressions. "" would be in every name, which is
        # `--run` with nothing to say, so it is refused like `--affected ""`.
        value = options.shift?.presence
        abort! "--run takes text a named case's name holds", :USAGE_ERROR unless value
        only = value
      when "-v", "--verbose"
        verbose = true
      when "--release"
        build_flags << "--release"
      when "-D", "--define"
        value = options.shift?.presence
        abort! "#{option} takes a flag to define", :USAGE_ERROR unless value
        build_flags << "-D#{value}"
      when .starts_with?("-D")
        build_flags << option
      when "--help", "-h"
        puts test_usage
        exit
      when .starts_with?('-')
        # A flag is a flag: this fell through to the path list and came
        # back as "no such file or directory: --nonesuch", which sends
        # the reader looking for a file they did not name.
        abort! "test: unknown flag #{option}", :USAGE_ERROR
      else
        paths << option
      end
    end
    if cached && fresh
      abort! "cannot pass both --cached and --fresh", :USAGE_ERROR
    end
    # The receipt runner (`--cached` and what goes with it) builds and runs each
    # test one way: one at a time, every named case, under its own build flags,
    # because a receipt says what one whole test did under one build. So it
    # refuses the options that would have it run another way, as `--chaos` is
    # refused below, rather than take them and do something else.
    receipts = if cached
                 "--cached"
               elsif fresh
                 "--fresh"
               elsif explain
                 "--explain"
               elsif shard
                 "--shard"
               elsif !import_indices.empty?
                 "--import-index"
               elsif !export_indices.empty?
                 "--export-index"
               end
    if receipts
      if only
        abort! "cannot pass both --run and #{receipts}: a receipt is for a test's every named case", :USAGE_ERROR
      elsif !build_flags.empty?
        abort! "cannot pass both #{build_flags.first} and #{receipts}: a receipt's build is the runner's own", :USAGE_ERROR
      elsif parallel_given
        abort! "cannot pass both -p and #{receipts}: tests with receipts run one at a time", :USAGE_ERROR
      elsif verbose
        abort! "cannot pass both -v and #{receipts}: a test answered from its receipt printed nothing to show", :USAGE_ERROR
      end
    end
    if chaos
      if cached
        abort! "cannot pass both --chaos and --cached", :USAGE_ERROR
      elsif fresh
        abort! "cannot pass both --chaos and --fresh", :USAGE_ERROR
      elsif explain
        abort! "cannot pass both --chaos and --explain", :USAGE_ERROR
      elsif shard
        abort! "cannot pass both --chaos and --shard", :USAGE_ERROR
      elsif !import_indices.empty?
        abort! "cannot pass both --chaos and --import-index", :USAGE_ERROR
      elsif !export_indices.empty?
        abort! "cannot pass both --chaos and --export-index", :USAGE_ERROR
      end
    end

    paths << "." if paths.empty?

    files = [] of String
    paths.each do |path|
      # `iyi test ""` - `"$DIR"` with `DIR` unset - answered "no such file
      # or directory: ", a sentence with a hole where the name goes. No
      # path at all means the working directory on purpose; "" is not that.
      abort! "test takes paths, and '' is not one (no path at all runs the working directory)", :USAGE_ERROR if path.empty?
      if File.directory?(path)
        # A walk, not a `**` glob: the glob went into `lib`, so a run in a
        # project ran its dependencies' tests and failed on theirs, which
        # the project cannot fix (see `test_files_under`).
        test_files_under(path, files)
      elsif File.file?(path)
        # As stored: `X_TEST.IYI` typed on Windows or a Mac for `x_test.iyi` is it.
        files << Lexer.stored_name(path)
      else
        abort! "no such file or directory: #{path}", :USAGE_ERROR
      end
    end
    # One run per file, however many ways it was spelled: the list was made
    # unique as strings, so `iyi test . app\x_test.iyi app/x_test.iyi`
    # built and ran one test three times and reported "passed":3.
    files.uniq! { |file| Iyi.file_key(File.expand_path(file)) }.sort!
    if miscased = files.find { |file| Lexer.iyi_miscased?(file) }
      abort! Lexer.iyi_miscased_sentence(miscased), :USAGE_ERROR
    end

    if files.empty?
      abort! "no *_test.iyi found. A test is a plain iyi program that exits non-zero to fail", :USAGE_ERROR
    end

    skipped = 0
    discount_off = [] of String
    # The manifest is not a module, so no test's import closure holds it —
    # and a change to it is the largest change a workspace can make: every
    # `import example.test/user/liba` resolves through the requirement it
    # names, so bumping a version moves the code under every test at once.
    # `--affected iyi.mod` answered "0 to run, 1 skipped: no test's imports
    # reach the change", which is an agent bumping a dependency and being
    # told there is nothing to run.
    manifest_changed = affected.select do |changed|
      File.basename(changed).in?(Iyi::Mod::Installer::MANIFEST, Iyi::Mod::Sum::FILE)
    end
    # A changed file no import can name is the same largest change: the
    # prelude is compiled by every test and imported by none, and a file
    # that is not a module reaches a test through a macro (`Eiy.embed`,
    # `read_file`) or while it runs. An edit to `page.eiy` was answered "0
    # to run, 1 skipped: no test's imports reach the change", and the test
    # that renders it failed under a plain `iyi test`.
    unimported = affected.select do |changed|
      File.file?(changed) && !manifest_changed.includes?(changed) && outside_every_closure?(changed)
    end
    unless affected.empty? || !manifest_changed.empty? || !unimported.empty?
      # A changed file that no longer exists cannot be proven untouched by
      # anything. The closure does see a deleted *import* now — an import
      # names a path, and the path outlives the file — but a test also
      # depends on what it reads while it runs, and a fixture that is gone
      # was never in any closure. Deletion turns the discount off.
      #
      # Out loud, though. It used to turn off in silence, so a caller who
      # mistyped a path got a full run that looked like a selective one —
      # and the selection is this flag's whole claim: exact, computed by
      # parsing. A typo and a deletion look the same from here, which is
      # the other reason to say which file it was.
      discount_off = affected.reject { |changed| File.file?(changed) }
      if discount_off.empty?
        changed = affected.map { |changed| Iyi.file_key(File.expand_path(changed)) }
        selected = files.select do |file|
          closure = test_import_closure(file)
          closure.nil? || closure.any? { |path| changed.includes?(Iyi.file_key(path)) }
        end
        skipped = files.size - selected.size
        files = selected
      end
    end

    if files.empty?
      # An empty selection is a verdict, not an error: nothing that runs
      # any changed file exists, so there is nothing to re-run.
      if as_json
        puts %({"tests": [], "passed": 0, "failed": 0, "skipped": #{skipped}})
      else
        puts "0 to run, #{skipped} skipped: no test's imports reach the change"
      end
      exit
    end
    if receipts
      runner = Iyi::Stale::Runner.new(
        files: files,
        paths: paths,
        as_json: as_json,
        timeout: timeout,
        affected: affected,
        cached: cached,
        fresh: fresh,
        explain: explain,
        shard: shard,
        import_indices: import_indices,
        export_indices: export_indices,
        skipped: skipped,
        discount_off: discount_off,
        manifest_changed: manifest_changed,
        unimported: unimported
      )
      runner.run
      return
    end

    # The seeds: the one asked for and those after it, or from a seed
    # drawn here, which the summary names so that the whole run can be
    # made again. One worker unless the environment says otherwise: on
    # more, the pool's threads are real and a seed names no schedule.
    plan : {UInt64, Int32}? = nil
    workers = ENV["IYI_WORKERS"]?.presence || "1"
    if chaos
      first = chaos_seed || Random.rand(1_u64..9_999_999_999_u64)
      plan = {first, chaos_runs || (chaos_seed ? 1 : CHAOS_RUNS)}
    end

    results = run_tests(files, parallel) { |file| run_one_test(file, timeout, plan, workers, only, build_flags, verbose) }
    failed = results.count { |result| result[:status] != "pass" }
    # `--run` with a name that matches no case ran none of them, and a run
    # that tested nothing it was asked to is not a pass: a mistyped name
    # would otherwise read as green.
    unmatched = only if only && results.all? { |result| result[:cases].empty? }

    if as_json
      JSON.build(STDOUT) do |json|
        json.object do
          json.field "tests" do
            json.array do
              results.each do |result|
                json.object do
                  json.field "file", result[:file]
                  json.field "status", result[:status]
                  json.field "seconds", result[:seconds]
                  if seed = result[:seed]
                    json.field "chaos_seed", seed
                    json.field "chaos_run", result[:run]
                  end
                  json.field "output", result[:output] unless result[:output].empty?
                  unless result[:cases].empty?
                    json.field "cases" do
                      json.array do
                        result[:cases].each do |test_case|
                          json.object do
                            json.field "name", test_case.name
                            case test_case.verdict
                            when "ok"
                              json.field "status", "pass"
                            when "skip"
                              json.field "status", "skip"
                              json.field "reason", test_case.detail
                            else
                              json.field "status", "fail"
                              json.field "message", test_case.detail
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
          json.field "passed", results.size - failed
          json.field "failed", failed
          json.field "skipped", skipped
          if plan
            json.field "chaos" do
              json.object do
                json.field "first_seed", plan[0]
                json.field "runs", plan[1]
                json.field "workers", workers
              end
            end
          end
          # The caller asked for a selective run and did not get one. In
          # data, because the caller that passes `--affected` is usually a
          # program.
          unless discount_off.empty?
            json.field "affected_not_found" do
              json.array { discount_off.each { |missing| json.scalar missing } }
            end
          end
          unless manifest_changed.empty?
            json.field "affected_manifest" do
              json.array { manifest_changed.each { |name| json.scalar name } }
            end
          end
          unless unimported.empty?
            json.field "affected_not_imported" do
              json.array { unimported.each { |name| json.scalar name } }
            end
          end
          json.field "run_matched_none", unmatched if unmatched
        end
      end
      STDOUT.puts
    else
      results.each do |result|
        next if result[:status] == "pass" && !verbose
        STDOUT << result[:file] << ": " << result[:status]
        if (seed = result[:seed]) && plan
          STDOUT << " (chaos seed " << seed << ", run " << result[:run] << " of " << plan[1] << ')'
        end
        STDOUT << '\n'
        result[:output].each_line { |line| STDOUT << "  " << line << '\n' }
        if seed = result[:seed]
          # With the flags the test was built with, or the seed reruns
          # another program.
          STDOUT << "  reproduce: " << Command.program_name << " test --chaos=" << seed
          build_flags.each { |flag| STDOUT << ' ' << flag }
          STDOUT << ' ' << result[:file] << '\n'
          if workers != "1"
            STDOUT << "  (IYI_WORKERS=" << workers << ": the pool's threads are real, and the seed does not name one schedule)\n"
          end
        end
      end
      unless manifest_changed.empty?
        puts "#{manifest_changed.join(", ")} changed, so every test ran: the " \
             "requirements are what every package import resolves through"
      end
      unless unimported.empty?
        puts "#{unimported.join(", ")} is not a module an import can name, so every test ran: " \
             "the prelude, a file a macro reads and a fixture reach a test without an import"
      end
      unless discount_off.empty?
        puts "#{discount_off.join(", ")} is not there, so every test ran: " \
             "a file that is gone cannot be proven untouched by anything"
      end
      if unmatched
        puts "no named case's name holds '#{unmatched}', so --run ran none of them"
      end
      tail = skipped.zero? ? "" : ", #{skipped} skipped"
      chaos_tail = ""
      if plan
        last = plan[0] &+ (plan[1] - 1).to_u64
        chaos_tail = plan[1] == 1 ? " — chaos seed #{plan[0]}" : " — chaos seeds #{plan[0]} to #{last}"
        chaos_tail += ", IYI_WORKERS=#{workers}" if workers != "1"
      end
      puts "#{results.size - failed} passed, #{failed} failed#{tail}#{chaos_tail}" + (failed.zero? ? "" : " — a failing test prints above")
    end

    exit 1 unless failed.zero? && unmatched.nil?
  end

  # iyi: whether no import closure can hold *path*, so no selection by
  # closure can discount anything for it: a file that is not a module
  # (`page.eiy`, a fixture, a `.cr` file), or one of the prelude's, which
  # every program compiles and no import names. `--affected
  # src/iyi/prelude.iyi` answered "0 to run, 1 skipped".
  private def outside_every_closure?(path : String) : Bool
    return true unless File.extname(path).compare(".iyi", case_insensitive: true) == 0
    key = Iyi.file_key(File.expand_path(path))
    IyiPath.default_paths.each do |entry|
      prelude = File.expand_path(File.join(entry, "iyi"))
      next unless File.file?(File.join(prelude, "prelude.iyi"))
      return !Iyi.path_under?(key, Iyi.file_key(prelude)).nil?
    end
    false
  end

  # The test's transitive import closure, as absolute paths, the test file
  # included — computed the way `mod context` reads imports: by parsing,
  # never compiling. Returns nil when the *test itself* does not parse:
  # nothing about it can be proven, so the caller must select it and let
  # its build say what is wrong. An imported file that does not parse is
  # already in the closure by path, which is all selection needs — and so
  # is one that is not there at all: an import names a path (R-1), and the
  # path stays named after the file is deleted. `check --affected` on a
  # deleted module used to answer "0 consumer(s) checked, all compile",
  # exit 0, about the one change certain to break every importer, because
  # the closure dropped what it could not open.
  private def test_import_closure(file : String) : Set(String)?
    entry = File.expand_path(file)
    # IV.6 read backwards, the rule a build applies
    # (`Compiler.entry_root_of`): a file whose path ends with its own
    # `module` header's path names the project root above both, and its
    # imports and its manifest resolve from there. A header-less script
    # keeps the entry-dir rule.
    entry_dir = closure_root_of(entry)
    table = Mod::Installer.table_for(entry_dir)
    closure = Set(String).new
    entry_imports = test_imports_of(entry)
    return nil unless entry_imports
    closure << entry
    queue = entry_imports.map do |written|
      named, _name = mod_context_names(written, entry_dir, table)
      File.expand_path(named)
    end
    while path = queue.pop?
      next unless closure.add?(path)
      (test_imports_of(path) || [] of String).each do |written|
        named, _name = mod_context_names(written, entry_dir, table)
        queue << File.expand_path(named)
      end
    end
    closure
  end

  private def test_imports_of(path : String) : Array(String)?
    parser = Parser.new(File.read(path))
    parser.filename = path
    nodes = parser.parse
    imports = [] of String
    mod_context_collect(nodes, imports)
    imports.uniq!
  rescue CodeError | IO::Error
    nil
  end

  # IV.6 read backwards, which is the build's own rule: one reading of it,
  # because a selection that placed a test differently from the build that
  # compiles it would discount the wrong tests.
  private def closure_root_of(path : String) : String
    Compiler.entry_root_of(path, File.read(path))
  rescue IO::Error
    File.dirname(path)
  end

  # The `*_test.iyi` files under *dir*, walked as `fix` and `mod tidy` walk
  # a module's source: not into a dot directory, `lib` (the installed
  # dependencies), a directory with a manifest of its own (another module,
  # whose tests it runs itself), or a link, which a junction back to its
  # own parent would make endless. The extension in any case, so that
  # `x_test.IYI` is refused by name rather than walked past: "no
  # *_test.iyi found" in a directory of one test (`Lexer.iyi_miscased?`).
  private def test_files_under(dir : String, found : Array(String)) : Nil
    Dir.each_child(dir) do |entry|
      full = File.join(dir, entry)
      if File.info?(full, follow_symlinks: false).try(&.directory?)
        next if entry.starts_with?('.') || entry == "lib"
        next if File.file?(File.join(full, Iyi::Mod::Installer::MANIFEST))
        test_files_under(full, found)
      elsif File.extname(entry).compare(".iyi", case_insensitive: true) == 0 && entry.rchop(File.extname(entry)).ends_with?("_test")
        found << full
      end
    end
  end

  # Every file through *run*, *parallel* at a time, the results in the
  # files' order. A fiber each: a test's build and its run are processes,
  # so what is waited on is the processes, and one thread waits on all of
  # them. An exception escaping a test is raised here, after the others
  # have ended, as it was raised when they ran one by one.
  private def run_tests(files : Array(String), parallel : Int32, &run : String -> TestResult) : Array(TestResult)
    slots = Array(TestResult?).new(files.size, nil)
    queue = ::Channel(Int32).new(files.size)
    files.each_index { |index| queue.send(index) }
    queue.close
    ended = ::Channel(Exception?).new
    runners = parallel.clamp(1, files.size)
    runners.times do
      spawn do
        escaped = nil
        begin
          while index = queue.receive?
            slots[index] = run.call(files[index])
          end
        rescue ex
          escaped = ex
        end
        ended.send(escaped)
      end
    end
    escaped = nil
    runners.times { ended.receive.try { |ex| escaped ||= ex } }
    escaped.try { |ex| raise ex }
    slots.map(&.not_nil!)
  end

  # The test built once, then run once - or, under `--chaos`, once per seed
  # of *chaos* (the first seed and how many) until one fails. *seed* and
  # *run* name the schedule a chaos failure came from; nil and 0 otherwise.
  # *cases* are the named cases of the run the verdict is from. A pass's
  # output is kept only when *verbose* asks for it (the last seed's, under
  # `--chaos`).
  private def run_one_test(file : String, deadline : Float64, chaos : {UInt64, Int32}?, workers : String, only : String?, build_flags : Array(String), verbose : Bool) : TestResult
    started = Time.instant
    output = IO::Memory.new

    # With the executable's extension, which `build -o` appends to a name
    # that has none: without it the delete below asked for a name nothing
    # had, and on Windows every test left its program and its `.pdb` in
    # %TEMP%.
    binary = File.tempname("iyi-test", {{ flag?(:win32) ? ".exe" : nil }})
    report = File.tempname("iyi-test-report", ".txt")
    environment = {"IYI_TEST_REPORT" => report}
    environment["IYI_TEST_RUN"] = only if only
    begin
      arguments = ["build", file, "-o", binary] + build_flags
      arguments << "-Diyi_chaos" if chaos
      build_status = Process.run(
        Process.executable_path.not_nil!,
        arguments,
        output: output, error: output,
      )
      unless build_status.success?
        return {file: file, status: "does not build", seconds: elapsed(started), output: output.to_s, seed: nil, run: 0, cases: [] of TestCase}
      end

      unless chaos
        status, evidence = run_built_test(binary, deadline, output, environment)
        evidence = "" if status == "pass" && !verbose
        return {file: file, status: status, seconds: elapsed(started), output: evidence, seed: nil, run: 0, cases: read_cases(report)}
      end

      # What the build printed is the start of every run's evidence, as it
      # is of a plain run's.
      built = output.to_s
      first, runs = chaos
      environment["IYI_WORKERS"] = workers
      cases = [] of TestCase
      last = ""
      runs.times do |index|
        seed = first &+ index.to_u64
        environment["IYI_CHAOS"] = seed.to_s
        ran = IO::Memory.new
        ran << built
        File.delete?(report)
        status, evidence = run_built_test(binary, deadline, ran, environment)
        cases = read_cases(report)
        if status == "pass"
          last = evidence if verbose
          next
        end
        return {file: file, status: status, seconds: elapsed(started), output: evidence, seed: seed, run: index + 1, cases: cases}
      end
      {file: file, status: "pass", seconds: elapsed(started), output: last, seed: nil, run: runs, cases: cases}
    ensure
      File.delete?(binary)
      File.delete?(report)
      # And what the link wrote beside it: MSVC's `.pdb`, and on darwin the
      # `.dwarf` dsymutil makes, which the new check found there too.
      {% if flag?(:win32) %}
        File.delete?(binary.rchop(".exe") + ".pdb")
      {% elsif flag?(:darwin) %}
        File.delete?("#{binary}.dwarf")
      {% end %}
    end
  end

  # The named cases a run reported (testing.iyi `IyiTestCases.tell`): a
  # header of the verdict and two byte counts, then the name and the
  # detail as they are. A program that ran no named case wrote nothing,
  # and one that died in the middle of a write left a record cut short,
  # which is dropped with what follows it.
  private def read_cases(report : String) : Array(TestCase)
    cases = [] of TestCase
    return cases unless File.exists?(report)
    File.open(report) do |io|
      while header = io.gets
        fields = header.split(' ')
        break unless fields.size == 3
        name_bytes, detail_bytes = fields[1].to_i?, fields[2].to_i?
        break unless name_bytes && detail_bytes && name_bytes >= 0 && detail_bytes >= 0
        cases << TestCase.new(fields[0], io.read_string(name_bytes), io.read_string(detail_bytes))
      end
    end
    cases
  rescue IO::Error
    cases || [] of TestCase
  end

  # One run of a built test, its output into *output*: the verdict, and
  # what it printed, with the death that ended it where one did.
  # *environment* is laid over this process's own.
  #
  # Standard output and standard error are one pipe, written in the order
  # the program wrote them. As two pipes, each copied by a fiber of its own,
  # a failed case's `FAIL - name` (stdout) landed above or below the panic
  # that failed it (stderr) as the two copies happened to be scheduled.
  private def run_built_test(binary : String, deadline : Float64, output : IO::Memory, environment : Hash(String, String)) : {String, String}
    reader, writer = IO.pipe(write_blocking: true)
    begin
      process = Process.new(binary, env: environment, output: writer, error: writer, process_group: true)
    rescue ex
      reader.close
      raise ex
    ensure
      # The child has its own copies; with this one open the pipe never ends.
      writer.close
    end
    tree = TestTree.new(process)
    begin
      done = ::Channel(Process::Status).new
      # The run ends when the program has and the pipe has: a child the test
      # started holds the pipe after the test exits, and the deadline below
      # is what ends that child.
      spawn do
        begin
          IO.copy(reader, output)
        rescue IO::Error
        end
        reader.close
        done.send(process.wait)
      end
      select
      when status = done.receive
        verdict = status.success? ? "pass" : "fail"
        # A test the kernel killed printed "fail" and nothing under it -
        # the one failure with no evidence of its own, and the one an
        # infinite recursion produces. The death is the evidence.
        evidence = output.to_s
        unless status.success? || status.exit_reason.normal?
          evidence += "\n" unless evidence.empty? || evidence.ends_with?('\n')
          evidence += Command.death_sentence(status) + "\n"
        end
        {verdict, evidence}
      when timeout(deadline.seconds)
        # The test and whatever it started: its output is copied through
        # a pipe, and the run waits for that pipe's end, which a child the
        # test started holds open. Only the test was killed, so a test
        # that ran `ping -n 25` answered "hung: killed at 3.0s" after 25
        # seconds, with the pings printed after the kill, and one whose
        # child never ends hung `iyi test` for good.
        tree.terminate
        done.receive
        {"hung: killed at #{deadline}s", output.to_s}
      end
    ensure
      tree.close
    end
  end

  # A test's program and what it starts, ended together: on Windows a job
  # object the program is put in as soon as it runs; on POSIX the process
  # group it leads from its spawn (`process_group: true`), which its
  # children are born into. A child that leaves the group (`setsid`, a
  # daemon) is out of reach, as it is out of a shell's job control.
  #
  # Leading a group of its own takes a test out of the terminal's, so ^C
  # reaches `iyi test` and not the tests: `iyi test` ends every group still
  # running before it exits on SIGINT, SIGTERM or SIGHUP, or a test that
  # hangs would outlive the run that started it (`TestTree.trap_endings`).
  class TestTree
    @process : Process
    {% if flag?(:win32) %}
      @job : LibC::HANDLE = LibC::HANDLE.null
    {% else %}
      @@running = Set(Int64).new
      @@trapped = false
    {% end %}

    def initialize(@process : Process)
      {% if flag?(:win32) %}
        job = LibC.CreateJobObjectW(Pointer(LibC::SECURITY_ATTRIBUTES).null, Pointer(UInt16).null)
        return if job.null?
        # PROCESS_TERMINATE | PROCESS_SET_QUOTA, what assigning asks for.
        handle = LibC.OpenProcess(0x0001_u32 | 0x0100_u32, 0, @process.pid.to_u32)
        if handle.null?
          LibC.CloseHandle(job)
          return
        end
        assigned = LibC.AssignProcessToJobObject(job, handle)
        LibC.CloseHandle(handle)
        if assigned == 0
          LibC.CloseHandle(job)
          return
        end
        @job = job
      {% else %}
        TestTree.trap_endings
        @@running << @process.pid
      {% end %}
    end

    def terminate : Nil
      {% if flag?(:win32) %}
        unless @job.null?
          LibC.TerminateJobObject(@job, 1)
          LibC.CloseHandle(@job)
          @job = LibC::HANDLE.null
          return
        end
      {% else %}
        # The group's id is its leader's pid. A group that is gone already
        # leaves the leader, which is killed as before.
        return if LibC.kill(-@process.pid.to_i32, Signal::KILL.value) == 0
      {% end %}
      @process.terminate(graceful: false)
    end

    # The job's handle, once the test is over; closing it ends nothing.
    def close : Nil
      {% if flag?(:win32) %}
        LibC.CloseHandle(@job) unless @job.null?
        @job = LibC::HANDLE.null
      {% else %}
        @@running.delete(@process.pid)
      {% end %}
    end

    {% unless flag?(:win32) %}
      def self.trap_endings : Nil
        return if @@trapped
        @@trapped = true
        [Signal::INT, Signal::TERM, Signal::HUP].each do |signal|
          signal.trap do
            @@running.each { |pid| LibC.kill(-pid.to_i32, Signal::KILL.value) }
            exit 128 + signal.value
          end
        end
      end
    {% end %}
  end

  private def elapsed(started : Time::Instant) : Float64
    (Time.instant - started).total_seconds.round(3)
  end

  private def test_usage
    <<-USAGE
    Usage: #{Command.program_name} test [--json] [-v] [--timeout SECONDS] [-p N] [--run TEXT] [--release] [-D FLAG]...
                                        [--affected FILE]... [--cached | --fresh] [--explain] [--shard K/N]
                                        [--import-index NS=FILE]... [--export-index NS=FILE]...
                                        [--chaos[=SEED]] [--chaos-runs N] [paths]

    Runs every `*_test.iyi` under the given paths (default: `.`), but not
    under `lib`, a dot directory or another module's directory. A test is
    a plain iyi program: exit 0 is a pass, anything else is a failure that
    prints its own evidence. `--json` reports the run as data, each named
    case (`test "name" { }`) with its verdict.

    `-p N` (`--parallel N`) builds and runs N tests at once; half as many as
    the machine has cores unless given. The report is in file order.

    `-v` (`--verbose`) shows what a passing test printed too, which is
    otherwise shown only for a failure. `--release` and `-D FLAG` build
    every test that way, as `build` takes them.

    `--run TEXT` runs only the named cases whose name holds TEXT; a test's
    code outside its named cases still runs. A run in which no case's name
    holds TEXT fails, because it tested nothing it was asked to.

    A named case written `test "name", skip: "why" do ... end` does not
    run, and says `skip - name: why`.

    `--affected FILE` (repeatable) runs only the tests whose transitive
    import closure contains a named file: name every file you changed.
    The closure is read by parsing, so selection costs milliseconds; a
    deleted file turns the discount off, because nothing can prove the
    tests that imported it unaffected.

    `--cached` reuses passing test results when code and observed inputs match.
    `--fresh` forces execution and records new receipts.
    `--explain` prints decision lines explaining hits and misses.
    `--shard K/N` runs shard K of N shards dealt round-robin.
    `--import-index NS=FILE` imports verified test receipts for namespace NS.
    `--export-index NS=FILE` exports test receipts for namespace NS (requires --fresh).
    These run each test one at a time, every named case, under the runner's
    own build, so they are not taken with `--run`, `-p`, `-v`, `--release`
    or `-D`.

    `--chaos` builds each test for the chaos scheduler and runs it once per
    seed, `--chaos-runs N` seeds (100 unless given) from one drawn at
    random: the order its tasks run in, where one is preempted, which
    `select` arm and which waiter go first all come from the seed, so a
    test that passes only because its tasks happened to run in one order
    fails on some seed. A failure names its seed, and `--chaos=SEED` runs
    that schedule again (one run, or N from SEED with `--chaos-runs`).
    Every task runs on one thread (`IYI_WORKERS=1`) unless the environment
    sets IYI_WORKERS; on more, the threads are real and a seed names no
    schedule. What a seed does not decide: when a sleep or a timeout ends,
    when I/O answers, and threads a test starts itself (SPEC.md III.4.17).
    USAGE
  end
end
