module Iyi
  # iyi: the files a top-level pass is going to read, parsed before it asks
  # for them, on threads of their own (SPEC.md IV.7).
  #
  # The top-level visitor reads a file when it reaches the `import` or
  # `require` that names it, depth first and load-once, and parses it there:
  # parsing was most of the stage, one file after another on one core. A
  # parse is a function of the file's bytes, its name, whether docs are kept
  # and the package its module header is read under (`Parser`), and not of
  # anything the walk has done, so it can happen before the walk gets there.
  # Workers parse the files the program names, find the files *those* name,
  # and parse them in turn, while the walk does everything else.
  #
  # Nothing here decides what is read. The walk resolves every import and
  # require exactly as it did, reads the file, sets up its parser, and then
  # asks for the file (`#parse`): a worker's nodes are taken only when the
  # worker read the same bytes under the same name, package and doc setting,
  # and otherwise the walk parses the file itself, as it always did. A file
  # the workers guessed wrong is parsed for nothing; a file they did not
  # find is parsed by the walk, which then hands what it names to the
  # workers. The nodes are the same nodes either way, and the warnings a
  # worker's parse reported are added when the walk takes the file, which
  # is where its own parse would have added them.
  class ParseAhead
    # At most this many workers, whatever `--threads` allows. Measured on a
    # Linux 12 vCPU VM, release compiler, five interleaved cold builds of
    # samples/iyi/cores.iyi (best / median of `Semantic (top level)`): none
    # 0.128 / 0.142 s, two 0.081 / 0.091, four 0.082 / 0.086, eight 0.084 /
    # 0.087; warm builds of iyi-web's `examples/templates.iyi`, three each:
    # none 0.167 / 0.168, two 0.109 / 0.111, four 0.093 / 0.099, eight 0.107
    # / 0.110. The stage's processor time grows with the workers (0.13-0.14 s
    # with none, 0.17-0.19 with two, 0.19-0.22 with four, 0.23-0.24 with
    # eight, for cores.iyi) while its wall time stops falling at four.
    THREADS = 4

    private enum State
      Queued
      Parsing
      Done
      Taken
    end

    private class Entry
      property state = State::Queued
      property source : String? = nil
      property nodes : ASTNode? = nil
      property reports = [] of CodeError
      getter package : String?

      def initialize(@package : String?)
      end
    end

    # Parses ahead of *program*'s top-level pass over *node* on *threads*
    # workers, or answers nil where it cannot: one thread, a compiler built
    # without threads, or an editor's build, whose files are its buffers
    # rather than what is on disk (`Program#iyi_file_overrides`).
    def self.start(program : Program, node : ASTNode, threads : Int32) : ParseAhead?
      {% if flag?(:without_mt) || !Fiber.has_constant?(:ExecutionContext) %}
        nil
      {% else %}
        return nil if threads < 2
        return nil unless program.iyi_file_overrides.empty? && program.iyi_probes.nil?
        new(program, node, threads)
      {% end %}
    end

    # The walk and each worker are the only fiber on their thread, so a wait
    # here waits for the thread: the operating system's lock and condition
    # variables, as `Compiler#mt_run` uses, rather than `Sync`'s. Measured
    # against `Sync`'s, the stage's wall and processor time were the same.
    @mutex = Thread::Mutex.new
    @work = Thread::ConditionVariable.new
    @parsed = Thread::ConditionVariable.new
    @entries = {} of String => Entry
    @queue = Deque(String).new
    @stopped = false
    # Workers that have not ended yet.
    @running : Int32
    @wants_doc : Bool
    @mod_table : Array({String, String})
    @module_dir : String?
    @path : IyiPath

    private def initialize(@program : Program, node : ASTNode, threads : Int32)
      @running = threads
      @wants_doc = program.wants_doc?
      @mod_table = program.iyi_mod_table
      @module_dir = program.iyi_module_dir
      # Made here, on the walk's thread: it is built the first time it is asked
      # for, and the workers only read it.
      @path = program.iyi_path

      # The prelude's `require` stands where the program file does, which is
      # what it resolves against.
      found = [] of {String, String?}
      discover(node, program.filename || "", found)
      @mutex.synchronize { found.each { |(filename, package)| queue(filename, package) } }

      threads.times do |index|
        Fiber::ExecutionContext::Isolated.new("parse-#{index}") do
          work
        ensure
          @mutex.synchronize do
            @running -= 1
            @parsed.broadcast
          end
        end
      end
    end

    # *filename*'s nodes, which the walk read as *source* and set *parser*
    # up for: a worker's when it parsed the same thing, else *parser*'s.
    def parse(parser : Parser, filename : String, source : String) : ASTNode
      if nodes = take(filename, source, parser.iyi_package_name, parser.wants_doc?)
        Prof.count("parse ahead: taken")
        return nodes
      end

      Prof.count("parse ahead: parsed here")
      nodes = parser.parse
      found = [] of {String, String?}
      discover(nodes, filename, found)
      unless found.empty?
        @mutex.synchronize do
          found.each { |(file, package)| queue(file, package) }
          @work.broadcast
        end
      end
      nodes
    end

    # Ends the workers. A worker in the middle of a file finishes that file
    # first; what was queued and never asked for is dropped.
    def stop : Nil
      unused = @mutex.synchronize do
        @stopped = true
        @work.broadcast
        until @running == 0
          @parsed.wait(@mutex)
        end
        @entries.count { |_, entry| !entry.state.taken? }
      end
      Prof.count("parse ahead: unused", unused)
    end

    private def take(filename, source, package, wants_doc) : ASTNode?
      entry = @mutex.synchronize do
        return nil unless found = @entries[filename]?
        if found.state.parsing?
          Prof.span("parse ahead: wait") do
            until found.state.done?
              @parsed.wait(@mutex)
            end
          end
        end
        # Queued is taken too: the walk parses it now, rather than wait for a
        # worker to start on it.
        done = found.state.done?
        found.state = State::Taken
        return nil unless done
        found
      end

      return nil unless (nodes = entry.nodes) && entry.source == source &&
                        entry.package == package && @wants_doc == wants_doc
      @program.warnings.reports.concat(entry.reports)
      nodes
    end

    private def queue(filename : String, package : String?) : Nil
      return if @entries.has_key?(filename)
      @entries[filename] = Entry.new(package)
      @queue << filename
    end

    private def work : Nil
      pool = StringPool.new
      while entry_and_name = following
        entry, filename = entry_and_name
        found = [] of {String, String?}
        source = nodes = nil
        warnings = @program.warnings.fork
        begin
          source = File.read(filename)
          parser = Parser.new(source, pool, [Set(String).new], warnings)
          parser.filename = filename
          parser.wants_doc = @wants_doc
          parser.iyi_package_name = entry.package
          nodes = parser.parse
          discover(nodes, filename, found)
        rescue
          # The walk parses it, and says what is wrong with it, where its own
          # parse would have.
          nodes = nil
        end
        @mutex.synchronize do
          entry.source = source
          entry.nodes = nodes
          entry.reports = warnings.reports
          entry.state = State::Done
          found.each { |(file, package)| queue(file, package) }
          @parsed.broadcast
          @work.broadcast unless found.empty?
        end
      end
    end

    # The next queued file and its entry, waiting for one; nil once stopped.
    private def following : {Entry, String}?
      @mutex.synchronize do
        loop do
          return nil if @stopped
          while filename = @queue.shift?
            entry = @entries[filename]
            next unless entry.state.queued?
            entry.state = State::Parsing
            return {entry, filename}
          end
          @work.wait(@mutex)
        end
      end
    end

    # The files *node*, the nodes of *filename*, names: its requires, its
    # imports, and the requires written in its macros' text, which is where a
    # require that depends on the target stands (`{% if flag?(:linux) %}`).
    # A guess, then, for a macro's text; and an import is looked for only as
    # the program's own or the standard library's module, from the roots the
    # walk tries first (`Program#iyi_import_candidates`). A package's, an
    # artifact's and a short name's are left to the walk.
    private def discover(node : ASTNode, filename : String, found) : Nil
      case node
      when Expressions
        node.expressions.each { |child| discover(child, filename, found) }
      when ModuleDef
        discover(node.body, filename, found)
      when VisibilityModifier
        discover(node.exp, filename, found)
      when MacroIf
        discover(node.then, filename, found)
        discover(node.else, filename, found)
      when MacroLiteral
        node.value.each_line do |line|
          line = line.strip
          if line.starts_with?("require \"") && line.ends_with?('"') && line.size > 10
            required(line[9...-1], filename, found)
          end
        end
      when Require
        required(node.string, filename, found)
      when ImportDecl
        imported(node.path.join('/'), found)
      end
    end

    private def required(string : String, filename : String, found) : Nil
      @path.find(string, filename).each { |file| found << {file, nil} }
    rescue IyiPath::NotFoundError
    end

    private def imported(path : String, found) : Nil
      return if path.includes?('.') || Mod::Installer.expand(path, @mod_table) != path
      if dir = @module_dir
        return if File.file?(Iyi.native_path(File.join(dir, "#{path}.iyimod")))
      end
      file = @program.iyi_import_candidates(path, inside_package: false).find { |candidate| File.file?(candidate) }
      found << {file, @program.iyi_root_package_name_for(path, file)} if file
    end
  end
end
