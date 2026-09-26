# iyi: `iyi fix` — apply the compiler's own suggestions to the file.
#
# The division of labour is deliberate. `check -f json` *shows* the edit
# (`suggested_edit`: file, line, column, size, replacement); `fix`
# *performs* it. Nothing here invents a repair: the only edits applied
# are the ones the semantic pass computed at the raise site — the
# Levenshtein did-you-mean, the `and`→`&&` operator hint, the III.1.7a
# participle. If the compiler did not say it, `fix` does not do it.
#
# The loop is compile → apply the one edit the error carries → compile
# again, because the front end stops at the first error and every edit
# moves the ground under later spans. One edit per round is not a
# compromise; it is the only ordering that is always right. The round
# cap exists so two suggestions that undo each other cannot ping-pong
# forever.
#
# One rewrite runs ahead of that loop, and it is the language's own
# rather than an error's: `using`, the keyword one `import` replaced, is
# written as that `import` - folded into a bare `import` of the same
# module when there is one (`Iyi::UsingRewrite`). A file written before
# the change stops parsing at its first `using`, so no compile could hand
# the edits over one at a time; the rewrite reads the file with the old
# keyword admitted and makes every one at once.
require "../lsp/analysis"
require "../tools/using_rewrite"

class Iyi::Command
  private def fix
    # Read the flag from either side of the path, the way `mod dump` does.
    # Looking for it only *before* the filename meant everything the loop
    # did not recognise fell through to the `File.file?` test below, so
    # `fix --nonesuch ok.iyi` answered `file '--nonesuch' does not exist`
    # about a flag, and a second path was dropped without a word: `fix
    # ok.iyi extra.iyi` fixed the first and exited 0.
    json_mode = false
    paths = [] of String
    while option = options.shift?
      case option
      when "--json"
        json_mode = true
      when "--help", "-h"
        puts <<-USAGE
          Usage: #{Command.program_name} fix [--json] <file or directory>...

          Apply the compiler's did-you-mean edits to <file>, recompiling
          after each one, until the file is clean or carries an error the
          compiler has no edit for. Every `using` is first written as the
          `import` that replaced it: `using X` is `import X::*`, `using
          X::{a}` is `import X::{a}`, folded into a bare `import X`. Exit 0 when the file ends clean. When
          the remaining error lives in another file of the program, the
          verb names it (`cause` in `--json`): that is the file to fix next.

          Several files, or a directory - every .iyi under it, hidden
          directories and lib/ aside - are one run: every `using` in all
          of them is rewritten first, since one file's compile reads the
          others, and then each is fixed in turn; `--json` prints one
          object per file, a line each. Exit 0 when every file ends clean.

          To see the edits without applying them, use
          `#{Command.program_name} check -f json`: the same edits travel
          there as `suggested_edit`, and the file is not touched.
          USAGE
        exit
      when .starts_with?('-')
        abort! "fix: unknown flag #{option}", :USAGE_ERROR
      else
        paths << option
      end
    end

    # `.presence`: `fix ""` is `"$FILE"` with `FILE` unset, and it answered
    # `no such file: ` - a sentence with a hole where the name goes.
    paths.reject!(&.empty?)
    if paths.empty?
      abort! "fix: which file? Usage: #{Command.program_name} fix [--json] <file or directory>...", :USAGE_ERROR
    end
    files = [] of String
    paths.each do |given|
      if File.file?(given)
        files << given
      elsif Dir.exists?(given)
        # A directory is the migration's shape: `iyi fix .` over a project
        # written before `import X::{...}` replaced `using`.
        found = fix_sources(given)
        abort! "#{given} is a directory with no .iyi file under it", :USAGE_ERROR if found.empty?
        files.concat(found)
      else
        abort! "no such file: #{given}", :USAGE_ERROR
      end
    end
    files.uniq!

    # Every `using` first, in every file: one file's compile reads the
    # modules it imports, and `fix a.iyi` stopped at the `using` in the
    # module `a` imported - a file this run did not name.
    rewrites = {} of String => Array({Int32, Int32, String, String})
    files.each do |file|
      path = File.expand_path(file)
      source = File.read(path)
      next unless source.valid_encoding?
      next unless rewritten = UsingRewrite.rewrite(source, path)
      File.write(path, rewritten[0])
      rewrites[file] = rewritten[1].map { |edit| {edit.line, edit.column, edit.from, edit.to} }
    end

    analysis = Lsp::Analysis.new
    single = files.size == 1
    clean = files.map { |file| fix_file(file, json_mode, analysis, rewrites[file]? || [] of {Int32, Int32, String, String}, single) }
    unless json_mode || single
      broken = clean.count(false)
      puts "#{files.size} files: #{rewrites.size} rewritten, #{broken == 0 ? "every one clean" : "#{broken} still reporting an error"}"
    end
    exit clean.all? ? 0 : 1
  end

  # The `.iyi` files under *dir*, hidden directories and `lib/` aside.
  private def fix_sources(dir : String) : Array(String)
    found = [] of String
    Dir.each_child(dir) do |entry|
      full = File.join(dir, entry)
      if File.directory?(full)
        next if entry.starts_with?('.') || entry == "lib"
        found.concat(fix_sources(full))
      elsif entry.ends_with?(".iyi")
        found << full
      end
    end
    found.sort!
  end

  # One file's did-you-mean loop and its report; whether it ended clean.
  # *applied* starts with the `using` rewrite's edits. *single* is a run of
  # this one file, where a file with nothing to do says so.
  private def fix_file(file : String, json_mode : Bool, analysis : Lsp::Analysis, applied : Array({Int32, Int32, String, String}), single : Bool) : Bool
    path = File.expand_path(file)
    remaining = nil
    capped = false

    # Thirty-two is a cap on the *edits*, and the verdict is always the check
    # after the last one. A file that genuinely carries more consecutive
    # fixable typos than that is not being fixed, it is being generated, and a
    # loop that long deserves a look rather than a run; the cap is also what
    # keeps two suggestions that undo each other from ping-ponging forever.
    #
    # It was written `32.times` with the verdict read from `remaining`, which
    # only the `break` paths ever set — so a run whose every round applied an
    # edit fell out of the loop with `remaining` still nil and answered
    # `"clean": true` and exit 0. Forty typos went in, thirty-two were fixed,
    # eight were left, and the one sentence this verb exists to say was the
    # wrong one. Nothing infers cleanliness from having stopped now: the loop
    # is unbounded and the *edit* count is what ends it, so the compiler is
    # asked once more after the thirty-second edit and its answer is the
    # answer.
    edit_cap = 32
    loop do
      text = File.read(path)
      unless text.valid_encoding?
        # `Lsp::Analysis` compiles with `stderr` set to an `IO::Memory`, so
        # the refusal `Compiler#parse` writes for a file of bytes that are
        # not text went into that buffer and the process exited 1 with
        # nothing on the terminal at all — a refusal with no sentence. The
        # same sentence, said where it can be read; `iyi doc` states it
        # this way too.
        abort! "file '#{file}' is not a valid iyi source file: " \
               "it holds bytes that are not UTF-8 text", :USAGE_ERROR
      end
      # Definition-site typing is the compiler's own rule now, so this
      # plain compile already reaches uncalled bodies — fix and check
      # cannot disagree about what clean means.
      _, diags = analysis.check(path, text, {} of String => String)
      if diags.empty?
        remaining = nil
        break
      end

      diag = diags.first
      # Asked with a diagnostic in hand, so a capped run names what is left
      # rather than reporting nothing at all.
      if applied.size >= edit_cap
        capped = true
        remaining = diag
        break
      end

      replacement = diag.suggestion
      unless replacement && diag.size > 0
        remaining = diag
        break
      end

      lines = text.split('\n')
      line_text = lines[diag.line - 1]?
      unless line_text
        remaining = diag
        break
      end
      chars = line_text.chars
      from = chars[diag.column - 1, diag.size].join
      if from == replacement
        # The suggestion equals what is already written: applying it
        # would change nothing and loop forever. Report and stop.
        remaining = diag
        break
      end

      lines[diag.line - 1] = chars[0, diag.column - 1].join + replacement +
                             ((chars[diag.column - 1 + diag.size..]? || [] of Char).join)
      File.write(path, lines.join('\n'))
      applied << {diag.line, diag.column, from, replacement}
    end

    # Where the remaining error actually is, when that is another file of
    # the program's own: `fix main.iyi` with the typo in `app/lib.iyi`
    # printed main's frame, `undefined method 'helperr'`, and `Did you
    # mean 'helper'?` - an edit this verb will not make, because it edits
    # the file it was named, and a sentence that reads as an invitation
    # to run it again. The deepest frame in another file is where to
    # point the verb instead - unless that file is the library's, which
    # is nobody's to fix from here and would be advice to edit the prelude.
    library = IyiPath.default_paths.map { |entry| File.expand_path(entry) }
    elsewhere = remaining.try do |diag|
      diag.related.reverse.find do |(file, _, _, _)|
        file != path && library.none? { |root| file.starts_with?(root) }
      end
    end

    if json_mode
      JSON.build(STDOUT) do |json|
        json.object do
          json.field "file", path
          json.field "applied" do
            json.array do
              applied.each do |(line, column, from, to)|
                json.object do
                  json.field "line", line
                  json.field "column", column
                  json.field "from", from
                  json.field "to", to
                end
              end
            end
          end
          json.field "clean", remaining.nil?
          if remaining
            json.field "remaining", remaining.message
          end
          # Not clean *because of the cap* rather than because the compiler has
          # no edit for what is left. The two want opposite things done about
          # them: one says look at the file, the other says run this again and
          # get thirty-two more.
          json.field "capped", true if capped
          if elsewhere
            json.field "cause" do
              json.object do
                json.field "file", elsewhere[0]
                json.field "line", elsewhere[1]
                json.field "column", elsewhere[2]
              end
            end
          end
        end
      end
      STDOUT.puts
    else
      applied.each do |(line, column, from, to)|
        puts "fixed #{file}:#{line}:#{column}: '#{from}' -> '#{to}'"
      end
      if remaining
        STDERR.puts "#{file}:#{remaining.line}:#{remaining.column}: #{remaining.message}"
        if elsewhere
          STDERR.puts "the cause is in #{Iyi.relative_filename(elsewhere[0])}:#{elsewhere[1]}:#{elsewhere[2]}, " \
                      "which this run does not edit: run `#{Command.program_name} fix #{Iyi.relative_filename(elsewhere[0])}`"
        end
        if capped
          STDERR.puts "#{applied.size} edits is this run's cap and the file still " \
                      "reports an error: run `#{Command.program_name} fix #{file}` again"
        end
      elsif applied.empty? && single
        puts "#{file}: already clean"
      end
    end

    remaining.nil?
  end
end
