# Implementation of the `crystal spec` command
#
# This ends up compiling and running some or all files
# inside the `spec` directory of the current project, passing
# `--location file:line` if line numbers were specified.
#
# The spec framework is chosen by the files inside the `spec`
# directory, which usually is just `require "spec"` but could
# be anything else (for example the `minitest` shard).

# Gain access to OptionParser for spec runner to include it in the usage
# instructions.
require "spec/cli"

class Iyi::Command
  # iyi: the two fixed patterns `crystal spec` matched arguments with. They
  # were regex literals, which is pcre2 on the compiler's link line, so they
  # compile once through Iyi::Rx instead (SPEC.md III.10, Appendix B #22).
  private SPEC_FILE     = Rx::Pattern.compile("\\.cr(\\:\\d+)?\\Z")
  private SPEC_LOCATION = Rx::Pattern.compile("\\A(.+?)\\:(\\d+)\\Z")

  private def spec
    compiler = new_compiler
    link_flags = [] of String
    parse_with_iyi_opts do |opts|
      opts.banner = "Usage: crystal spec [options] [files] [-- runtime_options]\n\nOptions:"
      setup_simple_compiler_options compiler, opts

      opts.on("-h", "--help", "Show this message") do
        puts opts
        puts

        # Short flag `-p` might collied with the same parser flag (short for `--progress`),
        # so we don't show it here. It still works when passed as an explicit argument to the
        # runner process (e.g. `crystal spec -- -p`).
        runtime_options = Spec::CLI.new.build_option_parser(without_p: true)
        runtime_options.banner = "Runtime options (passed to spec runner):"
        puts runtime_options
        exit
      end

      opts.on("--link-flags FLAGS", "Additional flags to pass to the linker") do |some_link_flags|
        link_flags << some_link_flags
      end
    end

    compiler.link_flags = link_flags.join(' ') unless link_flags.empty?

    # Assume spec files end with ".cr" and optionally with a colon and a number
    # (for the target line number), or is a directory. Everything else is an option we forward.
    filenames = options.select do |option|
      SPEC_FILE.matches?(option) || Dir.exists?(option)
    end
    options.reject! { |option| filenames.includes?(option) }

    locations = [] of {String, String}

    if filenames.empty?
      target_filenames = Dir["spec/**/*_spec.cr"]
    else
      target_filenames = [] of String
      filenames.each do |filename|
        if match = SPEC_LOCATION.match(filename)
          file, line = match[1].not_nil!, match[2].not_nil!
          unless File.file?(file)
            abort! "'#{file}' is not a file", :USAGE_ERROR
          end
          target_filenames << file
          locations << {file, line}
        else
          if Dir.exists?(filename)
            filename = ::Path[filename].to_posix
            target_filenames.concat Dir["#{filename}/**/*_spec.cr"]
          elsif File.file?(filename)
            target_filenames << filename
          else
            abort! "'#{filename}' is not a file", :USAGE_ERROR
          end
        end
      end
    end

    if target_filenames.size == 1
      if locations.size == 1
        # This is in case other spec runners use `-l`, we keep compatibility
        options << "-l" << locations.first[1]
      end
    else
      locations.each do |(file, line)|
        options << "--location" << "#{file}:#{line}"
      end
    end

    unless @color
      options << "--no-color"
    end

    source_filename = File.expand_path("spec")

    source = target_filenames.join('\n') do |filename|
      %(require "./#{::Path[filename].relative_to(Dir.current).to_posix.to_s.inspect_unquoted}")
    end
    sources = [Compiler::Source.new(source_filename, source)]

    Iyi.sweep_run_leftovers
    output_filename = Iyi.temp_executable "spec"

    ENV["CRYSTAL_SPEC_COMPILER_BIN"] ||= if iyi_exec_path = Config.env("EXEC_PATH")
                                           File.join(iyi_exec_path, "crystal")
                                         else
                                           Process.executable_path
                                         end

    compiler.compile sources, output_filename
    report_warnings
    execute output_filename, options, compiler, error_on_exit: warnings_fail_on_exit?
  end
end
