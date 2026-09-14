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
require "../lsp/analysis"

class Iyi::Command
  private def fix
    # Read the flag from either side of the path, the way `mod dump` does.
    # Looking for it only *before* the filename meant everything the loop
    # did not recognise fell through to the `File.file?` test below, so
    # `fix --nonesuch ok.iyi` answered `file '--nonesuch' does not exist`
    # about a flag, and a second path was dropped without a word: `fix
    # ok.iyi extra.iyi` fixed the first and exited 0.
    json_mode = false
    file = nil
    while option = options.shift?
      case option
      when "--json"
        json_mode = true
      when "--help", "-h"
        puts <<-USAGE
          Usage: #{Command.program_name} fix [--json] <file>

          Apply the compiler's did-you-mean edits to <file>, recompiling
          after each one, until the file is clean or carries an error the
          compiler has no edit for. Exit 0 when the file ends clean. When
          the remaining error lives in another file of the program, the
          verb names it (`cause` in `--json`): that is the file to fix next.

          To see the edits without applying them, use
          `#{Command.program_name} check -f json`: the same edits travel
          there as `suggested_edit`, and the file is not touched.
          USAGE
        exit
      when .starts_with?('-')
        abort! "fix: unknown flag #{option}", :USAGE_ERROR
      else
        if file
          abort! "unexpected '#{option}' after the file", :USAGE_ERROR
        end
        file = option
      end
    end

    # `.presence`: `fix ""` is `"$FILE"` with `FILE` unset, and it answered
    # `no such file: ` - a sentence with a hole where the name goes.
    file = file.presence
    unless file
      abort! "fix: which file? Usage: #{Command.program_name} fix [--json] <file>", :USAGE_ERROR
    end
    unless File.file?(file)
      # A directory is there, so "does not exist" was never true of it —
      # and this verb was the one saying `fix: file 'X' does not exist`
      # where every other says `no such file`, for the same mistake.
      abort! "#{file} is a directory, not a source file", :USAGE_ERROR if Dir.exists?(file)
      abort! "no such file: #{file}", :USAGE_ERROR
    end
    path = File.expand_path(file)

    analysis = Lsp::Analysis.new
    applied = [] of {Int32, Int32, String, String}
    remaining = nil

    # 32 rounds is not a tuning knob: a file that genuinely carries more
    # consecutive fixable typos than that is not being fixed, it is being
    # generated, and a loop that long deserves a look rather than a run.
    32.times do
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
      elsif applied.empty?
        puts "#{file}: already clean"
      end
    end

    exit remaining ? 1 : 0
  end
end
