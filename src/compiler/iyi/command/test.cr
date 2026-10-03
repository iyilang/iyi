# iyi: `iyi test` — the verify loop, with no framework to learn
# (AI_FIRST.md §2 #4).
#
# A test is a plain iyi program named `*_test.iyi`: it asserts by exiting
# non-zero, exactly the contract every gate in `bench/` already runs on,
# because this repository's own culture is the framework. No DSL, no
# matchers, no registry — a program that prints what failed and exits 1 is
# a failing test, and one that exits 0 passed. The prelude's `assert` is
# that in one word: a false condition panics with the message and the
# site, which is a program printing what failed and exiting 1.
#
#     iyi test              # every *_test.iyi under the current directory
#     iyi test dir file.iyi # these, recursing into directories
#     iyi test --json       # the run as data, for a harness
#     iyi test --affected FILE  # only tests whose imports reach FILE
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
# 60 s default), because a harness that can hang is not a harness.
class Iyi::Command
  # The longest `--timeout`: what Windows' waitable timer can count, in
  # 100 ns ticks held in an `Int64` - 922,337,203,684 s, some 29,000 years.
  # Past what the event loops' arithmetic holds a wait went wrong: 1e300
  # overflowed the span the wait becomes, and 9.3e14, 9.2e15 and 4.6e18
  # each hung a test that ends at once past a minute in one run on
  # Windows, and did not in the next.
  private MAX_TEST_WAIT = (Int64::MAX // 10_000_000 - 1).to_f

  private def test
    as_json = false
    timeout = 60.0
    paths = [] of String
    affected = [] of String

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
    paths << "." if paths.empty?

    files = [] of String
    paths.each do |path|
      # `iyi test ""` - `"$DIR"` with `DIR` unset - answered "no such file
      # or directory: ", a sentence with a hole where the name goes. No
      # path at all means the working directory on purpose; "" is not that.
      abort! "test takes paths, and '' is not one (no path at all runs the working directory)", :USAGE_ERROR if path.empty?
      if File.directory?(path)
        # The pattern is built in posix form because a backslash is an escape
        # character in a glob, not a separator: `C:\dir\**\*_test.iyi` matched
        # nothing, so `iyi test` in a directory of tests found no tests.
        # The extension in any case, so that `x_test.IYI` is refused below
        # rather than walked past: "no *_test.iyi found" in a directory of
        # one test (`Lexer.iyi_miscased?`).
        Dir.glob(Iyi.glob_root(path).join("**", "*_test.[iI][yY][iI]")) { |file| files << file }
      elsif File.file?(path)
        # As stored: `X_TEST.IYI` typed on Windows for `x_test.iyi` is it.
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
    unless affected.empty? || !manifest_changed.empty?
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

    results = files.map { |file| run_one_test(file, timeout) }
    failed = results.count { |result| result[:status] != "pass" }

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
                  json.field "output", result[:output] unless result[:output].empty?
                end
              end
            end
          end
          json.field "passed", results.size - failed
          json.field "failed", failed
          json.field "skipped", skipped
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
        end
      end
      STDOUT.puts
    else
      results.each do |result|
        next if result[:status] == "pass"
        STDOUT << result[:file] << ": " << result[:status] << '\n'
        result[:output].each_line { |line| STDOUT << "  " << line << '\n' }
      end
      unless manifest_changed.empty?
        puts "#{manifest_changed.join(", ")} changed, so every test ran: the " \
             "requirements are what every package import resolves through"
      end
      unless discount_off.empty?
        puts "#{discount_off.join(", ")} is not there, so every test ran: " \
             "a file that is gone cannot be proven untouched by anything"
      end
      tail = skipped.zero? ? "" : ", #{skipped} skipped"
      puts "#{results.size - failed} passed, #{failed} failed#{tail}" + (failed.zero? ? "" : " — a failing test prints above")
    end

    exit 1 unless failed.zero?
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

  private def run_one_test(file : String, deadline : Float64) : {file: String, status: String, seconds: Float64, output: String}
    started = Time.instant
    output = IO::Memory.new

    # With the executable's extension, which `build -o` appends to a name
    # that has none: without it the delete below asked for a name nothing
    # had, and on Windows every test left its program and its `.pdb` in
    # %TEMP%.
    binary = File.tempname("iyi-test", {{ flag?(:win32) ? ".exe" : nil }})
    begin
      build_status = Process.run(
        Process.executable_path.not_nil!,
        ["build", file, "-o", binary],
        output: output, error: output,
      )
      unless build_status.success?
        return {file: file, status: "does not build", seconds: elapsed(started), output: output.to_s}
      end

      process = Process.new(binary, output: output, error: output)
      tree = TestTree.new(process)
      running = tree
      done = ::Channel(Process::Status).new
      spawn { done.send(process.wait) }
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
        {file: file, status: verdict, seconds: elapsed(started), output: status.success? ? "" : evidence}
      when timeout(deadline.seconds)
        # The test and whatever it started: its output is copied through
        # a pipe, and `wait` waits for that pipe's end, which a child the
        # test started holds open. Only the test was killed, so a test
        # that ran `ping -n 25` answered "hung: killed at 3.0s" after 25
        # seconds, with the pings printed after the kill, and one whose
        # child never ends hung `iyi test` for good.
        tree.terminate
        done.receive
        {file: file, status: "hung: killed at #{deadline}s", seconds: elapsed(started), output: output.to_s}
      end
    ensure
      running.try &.close
      File.delete?(binary)
      # And what the link wrote beside it: MSVC's `.pdb`, and on darwin the
      # `.dwarf` dsymutil makes, which the new check found there too.
      {% if flag?(:win32) %}
        File.delete?(binary.rchop(".exe") + ".pdb")
      {% elsif flag?(:darwin) %}
        File.delete?("#{binary}.dwarf")
      {% end %}
    end
  end

  # A test's program and what it starts, ended together: on Windows a job
  # object the program is put in as soon as it runs; elsewhere the program
  # alone. [INFERENCE] A child a test starts on Linux or darwin outlives
  # the kill and holds the pipe the same way; unmeasured there.
  private class TestTree
    @process : Process
    {% if flag?(:win32) %}
      @job : LibC::HANDLE = LibC::HANDLE.null
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
      {% end %}
      @process.terminate(graceful: false)
    end

    # The job's handle, once the test is over; closing it ends nothing.
    def close : Nil
      {% if flag?(:win32) %}
        LibC.CloseHandle(@job) unless @job.null?
        @job = LibC::HANDLE.null
      {% end %}
    end
  end

  private def elapsed(started : Time::Instant) : Float64
    (Time.instant - started).total_seconds.round(3)
  end

  private def test_usage
    <<-USAGE
    Usage: #{Command.program_name} test [--json] [--timeout SECONDS] [--affected FILE]... [paths]

    Runs every `*_test.iyi` under the given paths (default: `.`). A test is
    a plain iyi program: exit 0 is a pass, anything else is a failure that
    prints its own evidence. `--json` reports the run as data.

    `--affected FILE` (repeatable) runs only the tests whose transitive
    import closure contains a named file — name every file you changed.
    The closure is read by parsing, so selection costs milliseconds; a
    deleted file turns the discount off, because nothing can prove the
    tests that imported it unaffected.
    USAGE
  end
end
